// SPDX-License-Identifier: GPL-3.0-or-later
import FSKit
import Foundation
import NTFSReadOnly

final class BlockDeviceReader: ReadOnlyDevice {
    let device: FSBlockDeviceResource
    let byteCount: UInt64
    let sectorSize: UInt32
    let physicalBlockSize: UInt64

    init(_ device: FSBlockDeviceResource) throws {
        guard !device.isRevoked else { throw POSIXError(.ENXIO) }
        let block = device.blockSize
        let physical = device.physicalBlockSize
        let (capacity, overflow) = block.multipliedReportingOverflow(by: device.blockCount)
        guard block >= 512, block <= 4096, block.nonzeroBitCount == 1,
              physical >= block, physical <= 65536, physical.nonzeroBitCount == 1,
              !overflow, capacity <= UInt64(Int64.max), capacity >= physical else {
            throw POSIXError(.ENOTSUP)
        }
        self.device = device
        byteCount = capacity
        sectorSize = UInt32(block)
        physicalBlockSize = physical
    }

    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        guard !device.isRevoked else { throw POSIXError(.ENXIO) }
        let plan = try BlockReadPlan(offset: offset, count: buffer.count,
                                     byteCount: byteCount, physicalBlockSize: physicalBlockSize)
        if plan.copyCount == 0 { return 0 }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: plan.transferCount,
                                                        alignment: Int(physicalBlockSize))
        defer { storage.deallocate() }
        let transfer = UnsafeMutableRawBufferPointer(start: storage, count: plan.transferCount)
        let received = try device.read(into: transfer, startingAt: off_t(plan.transferOffset), length: transfer.count)
        guard received == transfer.count else { throw POSIXError(.EIO) }
        guard !device.isRevoked else { throw POSIXError(.ENXIO) }
        buffer.copyMemory(from: UnsafeRawBufferPointer(start: storage.advanced(by: plan.copyOffset),
                                                       count: plan.copyCount))
        return plan.copyCount
    }
}
