import Darwin
import Foundation

public struct InspectionReport: Encodable, Sendable {
    public let status = "structurallyRecognized"
    public let format = "NTFS"
    public let writeAccess = "denied"
    public let volumeHealth = "unknown"
    public let blockers = [
        "ntfsEngineNotIntegrated",
        "dirtyFlagNotChecked",
        "windowsHibernationNotChecked",
        "metadataAndJournalNotValidated",
    ]
    public let geometry: BootSector

    public init(geometry: BootSector) {
        self.geometry = geometry
    }
}

/// Reads a bounded header through a read-only descriptor. Never opens raw disks.
public func inspectPartitionImage(atPath path: String) throws -> InspectionReport {
    guard !path.utf8.contains(0) else { throw InspectionError.invalid("路径含有 NUL。") }
    let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { throw currentPOSIXError() }
    defer { close(descriptor) }

    var info = stat()
    guard fstat(descriptor, &info) == 0 else { throw currentPOSIXError() }
    guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
        throw InspectionError.notRegularFile
    }
    guard info.st_size >= 512 else { throw InspectionError.shortRead }
    var data = Data(count: 512)
    try data.withUnsafeMutableBytes { buffer in
        var received = 0
        while received < buffer.count {
            let count = pread(descriptor, buffer.baseAddress!.advanced(by: received),
                              buffer.count - received, off_t(received))
            if count < 0 {
                if errno == EINTR { continue }
                throw currentPOSIXError()
            }
            guard count > 0 else { throw InspectionError.shortRead }
            received += count
        }
    }
    return InspectionReport(geometry: try BootSector(data: data,
                                                    resourceByteCount: UInt64(info.st_size)))
}

private func currentPOSIXError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}
