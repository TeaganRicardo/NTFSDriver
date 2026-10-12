// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Maps an engine byte read to one bounded, aligned direct-I/O transfer.
public struct BlockReadPlan: Sendable {
    public let transferOffset: UInt64
    public let transferCount: Int
    public let copyOffset: Int
    public let copyCount: Int

    public init(offset: UInt64, count: Int, byteCount: UInt64, physicalBlockSize block: UInt64) throws {
        guard (0...1024 * 1024).contains(count), block >= 512, block <= 65536,
              block.nonzeroBitCount == 1, byteCount <= UInt64(Int64.max),
              offset <= byteCount, UInt64(count) <= byteCount - offset else {
            throw POSIXError(.EINVAL)
        }
        transferOffset = offset / block * block
        copyOffset = Int(offset - transferOffset)
        copyCount = count
        if count == 0 { transferCount = 0; return }
        let end = offset + UInt64(count)
        let roundedEnd = (end + block - 1) / block * block
        guard roundedEnd <= byteCount else { throw POSIXError(.EIO) }
        transferCount = Int(roundedEnd - transferOffset)
    }
}
