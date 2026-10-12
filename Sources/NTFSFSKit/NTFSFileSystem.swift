import FSKit
import Foundation
import NTFSCore

/// M1 adapter: recognize only. Not packaged or registered as an installed extension.
public final class NTFSFileSystem: FSUnaryFileSystem,
    FSUnaryFileSystemOperations, FSManageableResourceMaintenanceOperations {

    public func probeResource(resource: FSResource,
                              replyHandler reply: @escaping (FSProbeResult?, (any Error)?) -> Void) {
        guard let device = resource as? FSBlockDeviceResource else {
            reply(.notRecognized, nil)
            return
        }
        do {
            guard !device.isRevoked else { throw POSIXError(.ENXIO) }
            let block = device.blockSize
            let physical = device.physicalBlockSize
            guard block >= 512, block <= 65536, block.nonzeroBitCount == 1,
                  physical >= block, physical <= 65536, physical.nonzeroBitCount == 1 else {
                throw InspectionError.unsupported("FSKit 设备块大小或对齐要求。")
            }
            let (capacity, overflow) = block.multipliedReportingOverflow(by: device.blockCount)
            guard !overflow, capacity <= UInt64(Int64.max), capacity >= physical else {
                throw InspectionError.invalid("FSKit 设备容量异常。")
            }
            var data = Data(count: Int(physical))
            let count = try data.withUnsafeMutableBytes { buffer in
                try device.read(into: buffer, startingAt: 0, length: buffer.count)
            }
            guard count == data.count else { throw InspectionError.shortRead }
            guard !device.isRevoked else { throw POSIXError(.ENXIO) }
            reply(try Self.recognize(data: data, resourceByteCount: capacity), nil)
        } catch InspectionError.notNTFS {
            reply(.notRecognized, nil)
        } catch {
            reply(nil, error)
        }
    }

    static func recognize(data: Data, resourceByteCount: UInt64) throws -> FSProbeResult {
        let boot = try BootSector(data: data, resourceByteCount: resourceByteCount)
        let serial = boot.serialNumberHex
        let identifier = "4E544653-0000-0000-\(serial.prefix(4))-\(serial.suffix(12))"
        guard let uuid = UUID(uuidString: identifier) else {
            throw InspectionError.invalid("卷序列号无法生成探测标识。")
        }
        // Recognized is deliberately not usable: no engine or health check exists yet.
        return .recognized(name: "", containerID: FSContainerIdentifier(uuid: uuid))
    }

    public func loadResource(resource: FSResource, options: FSTaskOptions,
                             replyHandler reply: @escaping (FSVolume?, (any Error)?) -> Void) {
        let error = POSIXError(.ENOTSUP)
        containerStatus = .notReady(status: error)
        reply(nil, error)
    }

    public func unloadResource(resource: FSResource, options: FSTaskOptions,
                               replyHandler reply: @escaping ((any Error)?) -> Void) {
        containerStatus = .notReady(status: POSIXError(.ENOTSUP))
        reply(nil)
    }

    public func startCheck(task: FSTask, options: FSTaskOptions) throws -> Progress {
        throw POSIXError(.ENOTSUP)
    }

    public func startFormat(task: FSTask, options: FSTaskOptions) throws -> Progress {
        throw POSIXError(.ENOTSUP)
    }
}
