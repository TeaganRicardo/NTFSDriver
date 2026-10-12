import Foundation

public enum InspectionError: Error, Equatable, LocalizedError {
    case notNTFS
    case invalid(String)
    case unsupported(String)
    case notRegularFile
    case shortRead

    public var errorDescription: String? {
        switch self {
        case .notNTFS: "输入不是从 NTFS 分区引导扇区开始的原始镜像。"
        case .invalid(let reason): "NTFS 引导结构异常：\(reason)"
        case .unsupported(let reason): "当前检查器不支持：\(reason)"
        case .notRegularFile: "只接受普通分区镜像文件；拒绝设备节点和其他特殊文件。"
        case .shortRead: "读取不足，镜像或设备数据可能已截断。"
        }
    }
}

/// Structural recognition only. This does not inspect $Volume, $LogFile or hiberfil.sys.
/// Layout reference: https://github.com/tuxera/ntfs-3g/blob/7f0f841fc52cf719106c5c93bafe465004e36816/include/ntfs-3g/layout.h
public struct BootSector: Sendable, Equatable, Encodable {
    public let bytesPerSector: UInt64
    public let sectorsPerCluster: UInt64
    public let bytesPerCluster: UInt64
    public let sectorCount: UInt64
    public let declaredVolumeBytes: UInt64
    public let mftCluster: UInt64
    public let mftMirrorCluster: UInt64
    public let bytesPerMFTRecord: UInt64
    public let bytesPerIndexRecord: UInt64
    public let serialNumberHex: String

    public init(data: Data, resourceByteCount: UInt64) throws {
        guard data.count >= 512 else { throw InspectionError.shortRead }
        // Copy only the fixed header; Data slices need not have a zero startIndex.
        let header = Array(data.prefix(512))
        guard Array(header[3..<11]) == Array("NTFS    ".utf8) else {
            throw InspectionError.notNTFS
        }
        guard header[510] == 0x55, header[511] == 0xaa else {
            throw InspectionError.invalid("结束标记不是 0xAA55。")
        }
        guard [14, 15, 16, 17, 18, 19, 20, 22, 23, 32, 33, 34, 35]
            .allSatisfy({ header[$0] == 0 }) else {
            throw InspectionError.invalid("保留的 BPB 字段不是零。")
        }

        func integer(at offset: Int, bytes: Int) -> UInt64 {
            (0..<bytes).reduce(0) { $0 | (UInt64(header[offset + $1]) << ($1 * 8)) }
        }
        bytesPerSector = integer(at: 11, bytes: 2)
        guard [512, 1024, 2048, 4096].contains(bytesPerSector) else {
            throw InspectionError.unsupported("扇区大小 \(bytesPerSector)。")
        }
        let clusterCode = header[13]
        switch clusterCode {
        case 1, 2, 4, 8, 16, 32, 64, 128:
            sectorsPerCluster = UInt64(clusterCode)
        case 240...253:
            sectorsPerCluster = UInt64(1) << (256 - Int(clusterCode))
        default:
            throw InspectionError.invalid("簇大小编码无效。")
        }
        let clusterBytes = bytesPerSector * sectorsPerCluster
        bytesPerCluster = clusterBytes
        guard clusterBytes <= 2 * 1024 * 1024 else {
            throw InspectionError.unsupported("簇大小超过 2 MiB。")
        }

        sectorCount = integer(at: 40, bytes: 8)
        guard sectorCount > 0, sectorCount <= UInt64(Int64.max) else {
            throw InspectionError.invalid("卷扇区数为零或超出有符号范围。")
        }
        let (volumeBytes, overflow) = sectorCount.multipliedReportingOverflow(by: bytesPerSector)
        guard !overflow, volumeBytes <= UInt64(Int64.max) else {
            throw InspectionError.invalid("卷长度溢出。")
        }
        guard volumeBytes <= resourceByteCount else {
            throw InspectionError.invalid("声明的卷长度超过输入长度。")
        }
        declaredVolumeBytes = volumeBytes

        func recordSize(at offset: Int) throws -> UInt64 {
            let code = Int(Int8(bitPattern: header[offset]))
            let size: UInt64
            if (-16 ... -9).contains(code) {
                size = UInt64(1) << -code
            } else if [1, 2, 4, 8, 16, 32, 64].contains(code) {
                size = UInt64(code) * clusterBytes
            } else {
                throw InspectionError.unsupported("记录大小编码 \(code)。")
            }
            guard size >= 512, size <= 65536 else {
                throw InspectionError.unsupported("记录大小不在 512 字节至 64 KiB 范围内。")
            }
            return size
        }
        bytesPerMFTRecord = try recordSize(at: 64)
        bytesPerIndexRecord = try recordSize(at: 68)
        mftCluster = integer(at: 48, bytes: 8)
        mftMirrorCluster = integer(at: 56, bytes: 8)
        let clusterCount = sectorCount / sectorsPerCluster
        guard mftCluster > 0, mftMirrorCluster > 0,
              mftCluster < clusterCount, mftMirrorCluster < clusterCount,
              mftCluster != mftMirrorCluster else {
            throw InspectionError.invalid("MFT 或 MFT 镜像位置不在卷内，或位置重叠。")
        }
        for cluster in [mftCluster, mftMirrorCluster] {
            // The cluster bounds above make this multiplication overflow-safe.
            let offset = cluster * bytesPerCluster
            guard bytesPerMFTRecord <= volumeBytes - offset else {
                throw InspectionError.invalid("MFT 记录跨越卷尾。")
            }
        }
        serialNumberHex = String(format: "%016llX", integer(at: 72, bytes: 8))
    }
}
