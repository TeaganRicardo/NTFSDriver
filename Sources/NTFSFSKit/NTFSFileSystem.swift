import FSKit
import Foundation
import NTFSCore
import NTFSReadOnly

/// Experimental unary file system. All loaded volumes are unconditionally read-only.
public final class NTFSFileSystem: FSUnaryFileSystem,
    FSUnaryFileSystemOperations, FSManageableResourceMaintenanceOperations {
    private let lock = NSRecursiveLock()
    private var loadedVolume: ReadOnlyFSVolume?
    private var loadedReader: BlockDeviceReader?
    private var generation: UUID?

    public override init() {
        super.init()
        containerStatus = .notReady(status: POSIXError(.EAGAIN))
    }

    public func probeResource(resource: FSResource,
                              replyHandler reply: @escaping (FSProbeResult?, (any Error)?) -> Void) {
        guard let device = resource as? FSBlockDeviceResource else {
            reply(.notRecognized, nil)
            return
        }
        do {
            let reader = try BlockDeviceReader(device)
            let boot = try Self.readBoot(reader)
            let engine = try ReadOnlyVolume(device: reader)
            let info = try engine.information()
            _ = try engine.attributes(of: 5)
            _ = try engine.close()
            reply(.usableButLimited(name: info.label, containerID: Self.identifier(boot)), nil)
        } catch InspectionError.notNTFS {
            reply(.notRecognized, nil)
        } catch {
            reply(nil, error)
        }
    }

    static func recognize(data: Data, resourceByteCount: UInt64) throws -> FSProbeResult {
        let boot = try BootSector(data: data, resourceByteCount: resourceByteCount)
        return .recognized(name: "", containerID: identifier(boot))
    }

    private static func readBoot(_ reader: BlockDeviceReader) throws -> BootSector {
        var data = Data(count: 512)
        _ = try data.withUnsafeMutableBytes { try reader.read(into: $0, at: 0) }
        return try BootSector(data: data, resourceByteCount: reader.byteCount)
    }

    private static func identifier(_ boot: BootSector) -> FSContainerIdentifier {
        let serial = boot.serialNumberHex
        let identifier = "4E544653-0000-0000-\(serial.prefix(4))-\(serial.suffix(12))"
        // BootSector always produces exactly sixteen hex digits.
        return FSContainerIdentifier(uuid: UUID(uuidString: identifier)!)
    }

    public func loadResource(resource: FSResource, options: FSTaskOptions,
                             replyHandler reply: @escaping (FSVolume?, (any Error)?) -> Void) {
        lock.withLock {
            guard loadedVolume == nil else { reply(nil, POSIXError(.EBUSY)); return }
            guard let device = resource as? FSBlockDeviceResource else { reply(nil, POSIXError(.ENOTSUP)); return }
            do {
                let reader = try BlockDeviceReader(device)
                let boot = try Self.readBoot(reader)
                let engine = try ReadOnlyVolume(device: reader)
                let selectedGeneration = UUID()
                let volume = try ReadOnlyFSVolume(engine: engine, identifier: Self.identifier(boot).volumeIdentifier,
                                                   lock: lock) { [weak self] active in
                    guard let self, self.generation == selectedGeneration else { return }
                    self.containerStatus = active ? .active : .ready
                }
                loadedVolume = volume
                loadedReader = reader
                generation = selectedGeneration
                containerStatus = .ready
                reply(volume, nil)
            } catch {
                containerStatus = .notReady(status: error)
                reply(nil, error)
            }
        }
    }

    public func unloadResource(resource: FSResource, options: FSTaskOptions,
                               replyHandler reply: @escaping ((any Error)?) -> Void) {
        lock.withLock {
            guard let volume = loadedVolume else { reply(nil); return }
            guard let device = resource as? FSBlockDeviceResource,
                  device.bsdName == loadedReader?.device.bsdName else { reply(POSIXError(.EINVAL)); return }
            loadedVolume = nil
            loadedReader = nil
            generation = nil
            do {
                try volume.closeEngine()
                containerStatus = .notReady(status: POSIXError(.EAGAIN))
                reply(nil)
            } catch {
                containerStatus = .notReady(status: error)
                reply(error)
            }
        }
    }

    public func startCheck(task: FSTask, options: FSTaskOptions) throws -> Progress {
        // Opening the root is not a filesystem consistency check. Never report it as fsck success.
        throw POSIXError(.ENOTSUP)
    }

    public func startFormat(task: FSTask, options: FSTaskOptions) throws -> Progress {
        throw POSIXError(.ENOTSUP)
    }
}
