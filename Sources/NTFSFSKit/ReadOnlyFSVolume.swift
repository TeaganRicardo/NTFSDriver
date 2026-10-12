// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import FSKit
import Foundation
import NTFSReadOnly

private final class ReadOnlyItem: FSItem {
    let reference: UInt64
    let parent: UInt64
    let owner: UUID
    init(reference: UInt64, parent: UInt64, owner: UUID) {
        self.reference = reference
        self.parent = parent
        self.owner = owner
    }
}

/// Experimental macOS 27 handler. The engine and every mutation path remain read-only.
final class ReadOnlyFSVolume: FSVolume, FSVolume.Handler, FSVolume.ReadWriteHandler {
    private let engine: ReadOnlyVolume
    private let info: VolumeInformation
    private let lock: NSRecursiveLock
    private let owner = UUID()
    private var items: [UInt64: ReadOnlyItem] = [:]
    private let stateChanged: (Bool) -> Void
    private var active = false

    init(engine: ReadOnlyVolume, identifier: FSVolume.Identifier, lock: NSRecursiveLock,
         stateChanged: @escaping (Bool) -> Void) throws {
        self.engine = engine
        info = try engine.information()
        self.lock = lock
        self.stateChanged = stateChanged
        super.init(volumeID: identifier, volumeName: FSFileName(string: info.label))
    }

    var maximumLinkCount: Int { 1 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }
    var maximumXattrSize: Int { 0 }
    var maximumXattrSizeInBits: Int { 0 }
    var maximumFileSize: UInt64 { UInt64(Int64.max) }
    var maximumFileSizeInBits: Int { 63 }
    var requestedMountOptions: FSVolume.MountOptions { .readOnly }

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let result = FSVolume.SupportedCapabilities()
        result.caseFormat = .sensitive
        result.supports64BitObjectIDs = true
        result.supportsHiddenFiles = true
        result.doesNotSupportSettingFilePermissions = true
        result.doesNotSupportImmutableFiles = true
        return result
    }

    var volumeStatistics: FSStatFSResult {
        let result = FSStatFSResult(fileSystemTypeName: "ntfsdriverro")
        result.blockSize = Int(info.bytesPerCluster)
        result.ioSize = 1024 * 1024
        result.totalBlocks = info.clusterCount
        result.freeBlocks = info.freeClusterCount
        result.availableBlocks = 0
        result.usedBlocks = info.clusterCount - info.freeClusterCount
        return result
    }

    private func key(_ reference: UInt64) -> UInt64 { reference & 0x0000ffffffffffff }
    private func itemID(_ reference: UInt64) -> FSItem.Identifier {
        key(reference) == 5 ? .rootDirectory : FSItem.Identifier(key(reference) + 3)
    }

    private func item(_ reference: UInt64, parent: UInt64) -> ReadOnlyItem {
        let number = key(reference)
        if let existing = items[number] { return existing }
        let result = ReadOnlyItem(reference: reference, parent: parent, owner: owner)
        items[number] = result
        return result
    }

    private func checked(_ value: FSItem) throws -> ReadOnlyItem {
        guard let value = value as? ReadOnlyItem, value.owner == owner, active else {
            throw POSIXError(.ESTALE)
        }
        return value
    }

    private func replyResult<T>(_ result: T?, to reply: (T?, (any Error)?) -> Void) {
        guard let result else { reply(nil, POSIXError(.EIO)); return }
        reply(result, nil)
    }

    private func attributes(_ reference: UInt64, parent: UInt64) throws -> FSItem.Attributes {
        let info = try engine.attributes(of: reference)
        let result = FSItem.Attributes()
        // Expose unsupported reparse entries without making the entire directory unreadable.
        result.type = info.flags & 0x400 != 0 ? .unknown : (info.isDirectory ? .directory : .file)
        result.mode = info.isDirectory ? 0o555 : 0o444
        result.linkCount = info.linkCount
        result.uid = getuid()
        result.gid = getgid()
        result.flags = info.flags & 2 != 0 ? UInt32(UF_HIDDEN) : 0
        result.size = info.size
        result.allocSize = info.allocatedSize
        result.fileID = itemID(info.reference)
        result.parentID = itemID(parent)
        result.birthTime = info.birthTime
        result.modifyTime = info.modifyTime
        result.changeTime = info.changeTime
        result.accessTime = info.accessTime
        result.supportsLimitedXAttrs = true
        return result
    }

    func activateVolume(options: FSTaskOptions,
                        replyHandler reply: @escaping (FSActivateResult?, (any Error)?) -> Void) {
        lock.withLock {
            do {
                let root = try engine.attributes(of: 5)
                guard let result = FSActivateResult(rootItem: item(root.reference, parent: root.reference)) else {
                    throw POSIXError(.EIO)
                }
                active = true
                stateChanged(true)
                reply(result, nil)
            } catch { reply(nil, error) }
        }
    }

    func deactivateVolume(options: FSDeactivateOptions,
                          replyHandler reply: @escaping ((any Error)?) -> Void) {
        lock.withLock {
            active = false
            items.removeAll()
            stateChanged(false)
            reply(nil)
        }
    }

    func mount(options: FSTaskOptions, replyHandler reply: @escaping ((any Error)?) -> Void) {
        lock.withLock { reply(active ? nil : POSIXError(.EAGAIN)) }
    }

    func unmount(replyHandler reply: @escaping () -> Void) { reply() }

    func synchronize(flags: FSSyncFlags, replyHandler reply: @escaping ((any Error)?) -> Void) {
        lock.withLock {
            do {
                guard try engine.statistics().deniedBackendWrites == 0 else { throw POSIXError(.EROFS) }
                reply(nil)
            } catch { reply(error) }
        }
    }

    func lookupItem(named name: FSFileName, in directory: FSItem, context: FSContext,
                    replyHandler reply: @escaping (FSLookupItemResult?, (any Error)?) -> Void) {
        lock.withLock {
            do {
                let parent = try checked(directory)
                guard let text = name.string else { throw POSIXError(.EILSEQ) }
                let reference = try engine.lookup(text, in: parent.reference)
                let value = item(reference, parent: text == "." ? parent.parent : parent.reference)
                let attributes = try attributes(reference, parent: value.parent)
                replyResult(FSLookupItemResult(foundItem: value, itemName: name, itemAttributes: attributes), to: reply)
            } catch { reply(nil, error) }
        }
    }

    func reclaimItem(_ value: FSItem, replyHandler reply: @escaping ((any Error)?) -> Void) {
        lock.withLock {
            guard let value = value as? ReadOnlyItem, value.owner == owner else { reply(POSIXError(.EINVAL)); return }
            _ = value.tryReclaim { self.items.removeValue(forKey: self.key(value.reference)) }
            reply(nil)
        }
    }

    func getAttributes(_ request: FSItem.GetAttributesRequest, of value: FSItem, context: FSContext,
                       replyHandler reply: @escaping (FSGetAttributesResult?, (any Error)?) -> Void) {
        lock.withLock {
            do {
                let value = try checked(value)
                replyResult(FSGetAttributesResult(attributes: try attributes(value.reference, parent: value.parent)), to: reply)
            } catch { reply(nil, error) }
        }
    }

    func enumerateDirectory(_ value: FSItem, startingAt cookie: FSDirectoryCookie,
                            verifier: FSDirectoryVerifier, attributes request: FSItem.GetAttributesRequest?,
                            packer: FSDirectoryEntryPacker, context: FSContext,
                            replyHandler reply: @escaping (FSEnumerateDirectoryResult?, (any Error)?) -> Void) {
        lock.withLock {
            do {
                let directory = try checked(value)
                guard verifier.rawValue == 0 || verifier.rawValue == 1,
                      cookie.rawValue <= UInt64(Int64.max) else { throw POSIXError(.EINVAL) }
                var position = Int64(cookie.rawValue)
                while true {
                    let page = try engine.entries(in: directory.reference, startingAt: position)
                    for entry in page.entries {
                        if request != nil && (entry.name == "." || entry.name == "..") { continue }
                        let itemAttributes = request == nil ? nil : try attributes(entry.reference, parent: directory.reference)
                        guard packer.packEntry(name: FSFileName(string: entry.name),
                                                itemType: entry.isDirectory ? .directory : (entry.isRegularFile ? .file : .unknown),
                                                itemID: itemID(entry.reference), nextCookie: FSDirectoryCookie(rawValue: UInt64(entry.nextCookie)),
                                                attributes: itemAttributes) else {
                            replyResult(FSEnumerateDirectoryResult(verifier: 1), to: reply)
                            return
                        }
                    }
                    if !page.hasMore { break }
                    guard page.nextCookie > position else { throw POSIXError(.EIO) }
                    position = page.nextCookie
                }
                replyResult(FSEnumerateDirectoryResult(verifier: 1), to: reply)
            } catch { reply(nil, error) }
        }
    }

    func read(from value: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer,
              replyHandler reply: @escaping (FSReadFileResult?, (any Error)?) -> Void) {
        lock.withLock {
            do {
                let value = try checked(value)
                guard offset >= 0, length >= 0 else { throw POSIXError(.EINVAL) }
                let info = try engine.attributes(of: value.reference)
                var received = 0
                try buffer.withUnsafeMutableBytes { target in
                    guard length <= target.count else { throw POSIXError(.EINVAL) }
                    while received < length, UInt64(offset) + UInt64(received) < info.size {
                        let data = try engine.read(value.reference, at: UInt64(offset) + UInt64(received),
                                                    count: Int(min(UInt64(min(1024 * 1024, length - received)),
                                                                   info.size - UInt64(offset) - UInt64(received))))
                        guard !data.isEmpty else { throw POSIXError(.EIO) }
                        data.withUnsafeBytes { source in
                            target.baseAddress!.advanced(by: received).copyMemory(from: source.baseAddress!,
                                                                                  byteCount: source.count)
                        }
                        received += data.count
                    }
                }
                replyResult(FSReadFileResult(bytesRead: received, itemAttributes: try attributes(value.reference, parent: value.parent)), to: reply)
            } catch { reply(nil, error) }
        }
    }

    func closeEngine() throws {
        lock.withLock { active = false; items.removeAll() }
        _ = try engine.close()
    }

    // Every mutating entry point fails before reaching the engine.
    func createItem(named: FSFileName, type: FSItem.ItemType, in: FSItem,
                    attributes: FSItem.SetAttributesRequest, context: FSContext,
                    replyHandler reply: @escaping (FSCreateItemResult?, (any Error)?) -> Void) { reply(nil, POSIXError(.EROFS)) }
    func createSymbolicLink(named: FSFileName, in: FSItem, attributes: FSItem.SetAttributesRequest,
                            linkContents: FSFileName, context: FSContext,
                            replyHandler reply: @escaping (FSCreateSymlinkResult?, (any Error)?) -> Void) { reply(nil, POSIXError(.EROFS)) }
    func createLink(to: FSItem, named: FSFileName, in: FSItem, context: FSContext,
                    replyHandler reply: @escaping (FSCreateLinkResult?, (any Error)?) -> Void) { reply(nil, POSIXError(.EROFS)) }
    func renameItem(_ item: FSItem, inDirectory: FSItem, named: FSFileName, to: FSFileName,
                    inDirectory destination: FSItem, overItem: FSItem?, context: FSContext,
                    replyHandler reply: @escaping (FSRenameItemResult?, (any Error)?) -> Void) { reply(nil, POSIXError(.EROFS)) }
    func removeItem(_ item: FSItem, named: FSFileName, from: FSItem, context: FSContext,
                    replyHandler reply: @escaping (FSRemoveItemResult?, (any Error)?) -> Void) { reply(nil, POSIXError(.EROFS)) }
    func setAttributes(_ attributes: FSItem.SetAttributesRequest, on: FSItem, context: FSContext,
                       replyHandler reply: @escaping (FSSetAttributesResult?, (any Error)?) -> Void) { reply(nil, POSIXError(.EROFS)) }
    func write(contents: Data, to: FSItem, at: off_t,
               replyHandler reply: @escaping (FSWriteFileResult?, (any Error)?) -> Void) { reply(nil, POSIXError(.EROFS)) }
    func readSymbolicLink(_ item: FSItem, context: FSContext,
                          replyHandler reply: @escaping (FSReadSymlinkResult?, (any Error)?) -> Void) { reply(nil, POSIXError(.ENOTSUP)) }
}
