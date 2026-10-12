// SPDX-License-Identifier: GPL-3.0-or-later
import CNTFSBridge
import Darwin
import Foundation

public protocol ReadOnlyDevice: AnyObject {
    var byteCount: UInt64 { get }
    var sectorSize: UInt32 { get }
    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int
}

public struct VolumeInformation: Sendable, Encodable {
    public let ntfsVersion: String
    public let dirtyFlag: Bool
    public let volumeFlags: UInt16
    public let bytesPerCluster: UInt32
    public let clusterCount: UInt64
    public let freeClusterCount: UInt64
    public let label: String
    public let writeAccess = "denied"
    public let volumeHealth = "unknown"
    public let hibernationState = "notChecked"
}

public struct ReadStatistics: Sendable, Encodable {
    public let backendReads: UInt64
    public let deniedBackendWrites: UInt64
}

public struct ItemInformation: Sendable {
    public let reference: UInt64
    public let size: UInt64
    public let allocatedSize: UInt64
    public let flags: UInt32
    public let linkCount: UInt32
    public let isDirectory: Bool
    public let birthTime, modifyTime, changeTime, accessTime: timespec
}

public struct DirectoryEntry: Sendable, Encodable {
    public let name: String
    public let reference: UInt64
    public let isDirectory: Bool
    public let isRegularFile: Bool
    public let nextCookie: Int64
}

public struct DirectoryPage: Sendable {
    public let entries: [DirectoryEntry]
    public let nextCookie: Int64
    public let hasMore: Bool
}

private final class DeviceContext {
    let device: any ReadOnlyDevice
    init(_ device: any ReadOnlyDevice) { self.device = device }
}

private final class EntryCollector {
    let limit: Int
    var entries: [DirectoryEntry] = []
    var stopped = false
    init(limit: Int) { self.limit = limit }
}

private let deviceRead: nd_read_callback = { context, buffer, count, offset in
    guard let context, let buffer else { errno = EINVAL; return -1 }
    let owner = Unmanaged<DeviceContext>.fromOpaque(context).takeUnretainedValue()
    do {
        let result = try owner.device.read(into: UnsafeMutableRawBufferPointer(start: buffer, count: count),
                                           at: offset)
        guard result >= 0, result <= count else { errno = EIO; return -1 }
        return result
    } catch {
        errno = (error as? POSIXError)?.code.rawValue ?? EIO
        return -1
    }
}

private let collectEntry: nd_entry_callback = { context, name, reference, type, cookie in
    guard let context, let name, let text = String(validatingCString: name) else {
        errno = EILSEQ
        return -1
    }
    let collector = Unmanaged<EntryCollector>.fromOpaque(context).takeUnretainedValue()
    if collector.entries.count == collector.limit {
        collector.stopped = true
        return 1
    }
    collector.entries.append(DirectoryEntry(name: text, reference: reference,
                                             isDirectory: type == 4, isRegularFile: type == 8,
                                             nextCookie: cookie))
    return 0
}

/// All engine calls and close are serialized. No writable device callback exists.
public final class ReadOnlyVolume: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: OpaquePointer?
    private let context: DeviceContext?

    public init(imagePath: String) throws {
        guard !imagePath.utf8.contains(0) else { throw POSIXError(.EINVAL) }
        context = nil
        var opened: OpaquePointer?
        guard nd_open_image(imagePath, &opened) == 0, let opened else { throw Self.posixError() }
        handle = opened
    }

    public init(device: any ReadOnlyDevice) throws {
        let context = DeviceContext(device)
        self.context = context
        var source = nd_source()
        source.byte_count = device.byteCount
        source.sector_size = device.sectorSize
        source.context = Unmanaged.passUnretained(context).toOpaque()
        source.read = deviceRead
        var opened: OpaquePointer?
        guard nd_open_source(source, &opened) == 0, let opened else { throw Self.posixError() }
        handle = opened
    }

    deinit {
        if let handle { _ = nd_close(handle, nil) }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private func access<T>(_ operation: (OpaquePointer) throws -> T) throws -> T {
        try lock.withLock {
            guard let handle else { throw POSIXError(.EBADF) }
            var stats = nd_io_stats()
            guard nd_get_stats(handle, &stats) == 0 else { throw Self.posixError() }
            guard stats.denied_backend_writes == 0 else { throw POSIXError(.EROFS) }
            let result = try operation(handle)
            guard nd_get_stats(handle, &stats) == 0 else { throw Self.posixError() }
            guard stats.denied_backend_writes == 0 else { throw POSIXError(.EROFS) }
            return result
        }
    }

    public func information() throws -> VolumeInformation {
        try access { handle in
            var info = nd_volume_info()
            guard nd_get_volume_info(handle, &info) == 0 else { throw Self.posixError() }
            let name = nd_volume_name(handle).flatMap { String(validatingCString: $0) } ?? ""
            return VolumeInformation(ntfsVersion: "\(info.major_version).\(info.minor_version)",
                                     dirtyFlag: info.volume_flags & 1 != 0,
                                     volumeFlags: info.volume_flags,
                                     bytesPerCluster: info.cluster_size, clusterCount: info.total_clusters,
                                     freeClusterCount: info.free_clusters, label: name)
        }
    }

    public func attributes(of reference: UInt64) throws -> ItemInformation {
        try access { handle in
            var info = nd_item_info()
            guard nd_get_item_info(handle, reference, &info) == 0 else { throw Self.posixError() }
            return ItemInformation(reference: info.reference, size: info.size,
                                   allocatedSize: info.allocated_size, flags: info.flags,
                                   linkCount: info.link_count, isDirectory: info.directory != 0,
                                   birthTime: timespec(tv_sec: Int(info.birth_seconds), tv_nsec: Int(info.birth_nanoseconds)),
                                   modifyTime: timespec(tv_sec: Int(info.modify_seconds), tv_nsec: Int(info.modify_nanoseconds)),
                                   changeTime: timespec(tv_sec: Int(info.change_seconds), tv_nsec: Int(info.change_nanoseconds)),
                                   accessTime: timespec(tv_sec: Int(info.access_seconds), tv_nsec: Int(info.access_nanoseconds)))
        }
    }

    public func lookup(_ name: String, in directory: UInt64) throws -> UInt64 {
        guard !name.isEmpty, !name.utf8.contains(0), !name.contains("/"), name.utf16.count <= 255 else {
            throw POSIXError(.EINVAL)
        }
        return try access { handle in
            var reference: UInt64 = 0
            guard nd_lookup(handle, directory, name, &reference) == 0 else { throw Self.posixError() }
            return reference
        }
    }

    public func item(atPath path: String) throws -> UInt64 {
        guard path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count <= 4096 else {
            throw POSIXError(.EINVAL)
        }
        var reference: UInt64 = 5
        for component in path.split(separator: "/") {
            guard component != ".." else { throw POSIXError(.EINVAL) }
            if component == "." { continue }
            reference = try lookup(String(component), in: reference)
        }
        return reference
    }

    public func entries(in directory: UInt64 = 5, startingAt cookie: Int64 = 0,
                        maximumCount: Int = 256) throws -> DirectoryPage {
        guard (1...4096).contains(maximumCount), cookie >= 0 else { throw POSIXError(.EINVAL) }
        return try access { handle in
            let collector = EntryCollector(limit: maximumCount)
            var position = cookie
            let result = nd_enumerate(handle, directory, &position,
                                      Unmanaged.passUnretained(collector).toOpaque(), collectEntry)
            guard result == 0 else { throw Self.posixError() }
            return DirectoryPage(entries: collector.entries, nextCookie: position, hasMore: collector.stopped)
        }
    }

    public func read(_ reference: UInt64, at offset: UInt64, count: Int) throws -> Data {
        guard (0...1024 * 1024).contains(count), offset <= UInt64(Int64.max) else {
            throw POSIXError(.EINVAL)
        }
        return try access { handle in
            var data = Data(count: count)
            let received = data.withUnsafeMutableBytes {
                nd_read_file(handle, reference, offset, $0.baseAddress, $0.count)
            }
            guard received >= 0, received <= count else { throw Self.posixError() }
            data.count = received
            return data
        }
    }

    public func statistics() throws -> ReadStatistics {
        try lock.withLock {
            guard let handle else { throw POSIXError(.EBADF) }
            var stats = nd_io_stats()
            guard nd_get_stats(handle, &stats) == 0 else { throw Self.posixError() }
            return ReadStatistics(backendReads: stats.backend_reads, deniedBackendWrites: stats.denied_backend_writes)
        }
    }

    @discardableResult
    public func close() throws -> ReadStatistics {
        try lock.withLock {
            guard let current = handle else { throw POSIXError(.EBADF) }
            handle = nil // ntfs_umount consumes the handle even when it reports an error.
            var stats = nd_io_stats()
            let result = nd_close(current, &stats)
            guard result == 0 else { throw Self.posixError() }
            return ReadStatistics(backendReads: stats.backend_reads, deniedBackendWrites: stats.denied_backend_writes)
        }
    }
}
