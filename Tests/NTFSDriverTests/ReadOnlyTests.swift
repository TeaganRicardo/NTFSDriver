// SPDX-License-Identifier: GPL-3.0-or-later
import CNTFSBridge
import CryptoKit
import Darwin
import Foundation
import FSKit
import NTFSReadOnly
@testable import NTFSFSKit
import XCTest

final class ReadOnlyTests: XCTestCase {
    private final class FragmentedDevice: ReadOnlyDevice {
        let data: Data
        let maximumRead: Int
        let failAfter: Int?
        var reads = 0
        var byteCount: UInt64 { UInt64(data.count) }
        var sectorSize: UInt32 { 512 }
        init(data: Data, maximumRead: Int = 97, failAfter: Int? = nil) {
            self.data = data; self.maximumRead = maximumRead; self.failAfter = failAfter
        }
        func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
            reads += 1
            if let failAfter, reads > failAfter { throw POSIXError(.EIO) }
            let count = min(buffer.count, maximumRead, data.count - Int(offset))
            if count == 0 { return 0 }
            data.withUnsafeBytes { bytes in
                buffer.baseAddress!.copyMemory(from: bytes.baseAddress!.advanced(by: Int(offset)), byteCount: count)
            }
            return count
        }
    }
    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("test.ntfs")
        FileManager.default.createFile(atPath: image.path, contents: nil)
        let output = try FileHandle(forWritingTo: image)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-dc", Bundle.module.url(forResource: "readonly.ntfs", withExtension: "gz", subdirectory: "Fixtures")!.path]
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        try output.close()
        XCTAssertEqual(process.terminationStatus, 0)
        return image
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func manifest() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "manifest", withExtension: "json", subdirectory: "Fixtures"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testFullImageNamesPaginationAndHashesRemainUnchanged() throws {
        let image = try fixture()
        let manifest = try manifest()
        let before = digest(try Data(contentsOf: image))
        XCTAssertEqual(before, manifest["imageSHA256"] as? String)
        let volume = try ReadOnlyVolume(imagePath: image.path)
        let info = try volume.information()
        XCTAssertEqual(info.ntfsVersion, "3.1")
        XCTAssertEqual(info.label, "NTFSDriverTest")
        XCTAssertFalse(info.dirtyFlag)
        XCTAssertEqual(info.writeAccess, "denied")
        XCTAssertEqual(info.volumeHealth, "unknown")
        XCTAssertGreaterThan(info.freeClusterCount, 0)
        XCTAssertLessThan(info.freeClusterCount, info.clusterCount)
        var names: [String] = []
        var cookie: Int64 = 0
        for _ in 0..<20 {
            let page = try volume.entries(startingAt: cookie, maximumCount: 1)
            names.append(contentsOf: page.entries.map(\.name))
            if !page.hasMore { break }
            XCTAssertGreaterThan(page.nextCookie, cookie)
            cookie = page.nextCookie
        }
        XCTAssertEqual(Set(names), Set([".", "..", "Alpha.bin", "empty.txt", "中文🦊.txt"]))
        XCTAssertEqual(names.count, 5)
        XCTAssertEqual(try volume.lookup(".", in: 5) & 0x0000ffffffffffff, 5)
        XCTAssertEqual(try volume.lookup("..", in: 5) & 0x0000ffffffffffff, 5)
        let expected = try XCTUnwrap(manifest["files"] as? [String: [String: Any]])
        for (name, details) in expected {
            let reference = try volume.item(atPath: "/" + name)
            let attributes = try volume.attributes(of: reference)
            XCTAssertFalse(attributes.isDirectory)
            XCTAssertEqual(attributes.size, (details["bytes"] as? NSNumber)?.uint64Value)
            var data = Data()
            var offset: UInt64 = 0
            while offset < attributes.size {
                let part = try volume.read(reference, at: offset, count: Int(min(4097, attributes.size - offset)))
                XCTAssertFalse(part.isEmpty)
                data.append(part)
                offset += UInt64(part.count)
            }
            XCTAssertEqual(digest(data), details["sha256"] as? String)
            XCTAssertTrue(try volume.read(reference, at: attributes.size + 1, count: 1).isEmpty)
        }
        let nested = try volume.item(atPath: "/$Extend")
        XCTAssertTrue(try volume.attributes(of: nested).isDirectory)
        XCTAssertTrue(try volume.entries(in: nested).entries.contains { $0.name == "." })
        XCTAssertEqual(try volume.lookup("..", in: nested) & 0x0000ffffffffffff, 5)
        let stats = try volume.close()
        XCTAssertGreaterThan(stats.backendReads, 0)
        XCTAssertEqual(stats.deniedBackendWrites, 0)
        XCTAssertEqual(before, digest(try Data(contentsOf: image)))
        XCTAssertThrowsError(try volume.information())
        XCTAssertThrowsError(try volume.close())
    }

    func testReadErrorsAndBoundsAreReturnedWithoutWrites() throws {
        let image = try fixture()
        let before = digest(try Data(contentsOf: image))
        let volume = try ReadOnlyVolume(imagePath: image.path)
        let file = try volume.item(atPath: "/Alpha.bin")
        for path in ["relative", "/../Alpha.bin", "/missing", "/bad\0name", "/alpha.bin"] {
            XCTAssertThrowsError(try volume.item(atPath: path), path)
        }
        XCTAssertThrowsError(try volume.read(5, at: 0, count: 1))
        XCTAssertThrowsError(try volume.read(file, at: UInt64(Int64.max), count: 10))
        XCTAssertThrowsError(try volume.read(file, at: 0, count: 1024 * 1024 + 1))
        XCTAssertThrowsError(try volume.entries(startingAt: -1))
        XCTAssertThrowsError(try volume.entries(maximumCount: 0))
        XCTAssertThrowsError(try volume.entries(in: file))
        XCTAssertThrowsError(try volume.lookup(".", in: file)) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .ENOTDIR)
        }
        XCTAssertEqual(try volume.close().deniedBackendWrites, 0)
        XCTAssertEqual(before, digest(try Data(contentsOf: image)))
        XCTAssertThrowsError(try ReadOnlyVolume(imagePath: "/dev/null"))
        XCTAssertThrowsError(try ReadOnlyVolume(imagePath: image.deletingLastPathComponent().path))
        let link = image.deletingLastPathComponent().appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: image)
        XCTAssertThrowsError(try ReadOnlyVolume(imagePath: link.path))
    }

    func testRepeatedOpenAndIndependentVolumes() throws {
        let image = try fixture()
        let before = digest(try Data(contentsOf: image))
        for _ in 0..<20 {
            let first = try ReadOnlyVolume(imagePath: image.path)
            let second = try ReadOnlyVolume(imagePath: image.path)
            XCTAssertEqual(try first.entries().entries.count, 5)
            XCTAssertEqual(try first.close().deniedBackendWrites, 0)
            let reference = try second.item(atPath: "/中文🦊.txt")
            XCTAssertEqual(try second.read(reference, at: 0, count: 4096).count, 54)
            XCTAssertEqual(try second.close().deniedBackendWrites, 0)
        }
        XCTAssertEqual(before, digest(try Data(contentsOf: image)))
    }

    @MainActor
    func testConcurrentReadsShareOneSerializedVolume() async throws {
        let image = try fixture()
        let before = digest(try Data(contentsOf: image))
        let volume = try ReadOnlyVolume(imagePath: image.path)
        let results = try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    let reference = try volume.item(atPath: "/中文🦊.txt")
                    _ = try volume.entries(maximumCount: 2)
                    return try volume.read(reference, at: 0, count: 512)
                }
            }
            var results: [Data] = []
            for try await result in group { results.append(result) }
            return results
        }
        XCTAssertEqual(results.count, 16)
        XCTAssertTrue(results.allSatisfy { $0 == results.first })
        XCTAssertEqual(results.first?.count, 54)
        XCTAssertEqual(try volume.close().deniedBackendWrites, 0)
        XCTAssertEqual(before, digest(try Data(contentsOf: image)))
    }

    func testReaderCLIReportsHashesAndErrorsAsJSON() throws {
        let image = try fixture()
        let before = digest(try Data(contentsOf: image))
        let binary = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("ntfs-read")
        func run(_ arguments: [String]) throws -> (Int32, [String: Any]) {
            let process = Process()
            let output = Pipe()
            process.executableURL = binary
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationReason, .exit)
            return (process.terminationStatus, try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]))
        }
        let (status, report) = try run(["hash", image.path, "/Alpha.bin"])
        XCTAssertEqual(status, 0)
        let expected = try XCTUnwrap((try manifest()["files"] as? [String: [String: Any]])?["Alpha.bin"])
        XCTAssertEqual(report["sha256"] as? String, expected["sha256"] as? String)
        XCTAssertEqual((report["bytes"] as? NSNumber)?.uint64Value, 2_097_408)
        XCTAssertEqual((report["io"] as? [String: Any])?["deniedBackendWrites"] as? Int, 0)
        let (listStatus, list) = try run(["list", image.path])
        XCTAssertEqual(listStatus, 0)
        XCTAssertEqual((list["entries"] as? [[String: Any]])?.count, 5)
        let (badStatus, error) = try run(["hash", image.path, "/missing"])
        XCTAssertEqual(badStatus, 1)
        XCTAssertEqual(error["status"] as? String, "error")
        XCTAssertEqual(error["operation"] as? String, "lookupFile")
        XCTAssertEqual(before, digest(try Data(contentsOf: image)))
    }

    func testRealWriteGuardCallbacksRejectAllMutations() {
        XCTAssertEqual(nd_verify_write_guards(), 0)
    }

    func testCallbackDeviceHandlesPartialReadsAndIOFailures() throws {
        let image = try fixture()
        let data = try Data(contentsOf: image)
        let device = FragmentedDevice(data: data)
        let volume = try ReadOnlyVolume(device: device)
        let reference = try volume.item(atPath: "/中文🦊.txt")
        XCTAssertEqual(try volume.read(reference, at: 0, count: 512).count, 54)
        XCTAssertGreaterThan(device.reads, 100)
        XCTAssertEqual(try volume.close().deniedBackendWrites, 0)
        for device in [FragmentedDevice(data: data, maximumRead: 0), FragmentedDevice(data: data, failAfter: 3)] {
            XCTAssertThrowsError(try ReadOnlyVolume(device: device))
        }
        XCTAssertEqual(digest(data), digest(try Data(contentsOf: image)))
    }

    func testMalformedMFTIsRejectedWithoutRepair() throws {
        let image = try fixture()
        let handle = try FileHandle(forWritingTo: image)
        try handle.seek(toOffset: 4 * 4096)
        try handle.write(contentsOf: Data("BAAD".utf8))
        try handle.close()
        let before = digest(try Data(contentsOf: image))
        XCTAssertThrowsError(try ReadOnlyVolume(imagePath: image.path))
        XCTAssertEqual(before, digest(try Data(contentsOf: image)))
    }

    func testMalformedFreeSpaceBitmapIsRejectedWithoutRepair() throws {
        let image = try fixture()
        let handle = try FileHandle(forWritingTo: image)
        // Fixed fixture: $Bitmap's 2048 bytes are at LCN 2055, for only 16383 clusters.
        try handle.seek(toOffset: 2055 * 4096)
        try handle.write(contentsOf: Data(count: 2048))
        try handle.close()
        let before = digest(try Data(contentsOf: image))
        XCTAssertThrowsError(try ReadOnlyVolume(imagePath: image.path)) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .EIO)
        }
        XCTAssertEqual(before, digest(try Data(contentsOf: image)))
    }

    func testParentIdentityWhenAncestorIsNotCached() throws {
        let image = try fixture()
        let before = digest(try Data(contentsOf: image))
        let engine = try ReadOnlyVolume(imagePath: image.path)
        let volume = try ReadOnlyFSVolume(engine: engine, identifier: FSVolume.Identifier(uuid: UUID()),
                                         lock: NSRecursiveLock(), stateChanged: { _ in })
        // Reclaim removes the ancestor from the cache. Exercise that same cache-miss state
        // without synthesizing FSKit's private kernel/user-space reference counters.
        _ = try volume.resolveLookup(name: "$Extend", directory: 5, parent: 5)
        let childReference = try engine.item(atPath: "/$Extend")
        let (_, attributes) = try volume.resolveLookup(name: "..", directory: childReference, parent: 5)
        XCTAssertEqual(attributes.fileID, .rootDirectory)
        XCTAssertEqual(attributes.parentID, .rootDirectory)
        try volume.closeEngine()
        XCTAssertEqual(before, digest(try Data(contentsOf: image)))
    }

    func testAlignedReadPlanAndOverflowBoundaries() throws {
        let first = try BlockReadPlan(offset: 511, count: 1, byteCount: 65536, physicalBlockSize: 4096)
        XCTAssertEqual(first.transferOffset, 0)
        XCTAssertEqual(first.transferCount, 4096)
        XCTAssertEqual(first.copyOffset, 511)
        let crossing = try BlockReadPlan(offset: 4090, count: 16, byteCount: 65536, physicalBlockSize: 4096)
        XCTAssertEqual(crossing.transferCount, 8192)
        for (offset, count, capacity, block): (UInt64, Int, UInt64, UInt64) in [
            (.max, 10, 65536, 4096), (0, -1, 65536, 4096),
            (65530, 10, 65536, 4096), (0, 10, 65536, 513),
            (0, 1024 * 1024 + 1, 65536, 4096), (512, 1, 513, 4096),
        ] {
            XCTAssertThrowsError(try BlockReadPlan(offset: offset, count: count, byteCount: capacity, physicalBlockSize: block))
        }
    }
}
