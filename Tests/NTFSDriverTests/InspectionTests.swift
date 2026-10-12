import CryptoKit
import Darwin
import Foundation
import FSKit
import NTFSCore
@testable import NTFSFSKit
import XCTest

final class InspectionTests: XCTestCase {
    private let capacity: UInt64 = 128 * 512

    private func header() -> Data {
        var data = Data(repeating: 0, count: 512)
        data.replaceSubrange(3..<11, with: "NTFS    ".utf8)
        put(512, at: 11, bytes: 2, in: &data)
        data[13] = 8
        put(128, at: 40, bytes: 8, in: &data)
        put(4, at: 48, bytes: 8, in: &data)
        put(8, at: 56, bytes: 8, in: &data)
        data[64] = UInt8(bitPattern: -10)
        data[68] = UInt8(bitPattern: -12)
        put(0xfedcba9876543210, at: 72, bytes: 8, in: &data)
        data[510] = 0x55
        data[511] = 0xaa
        return data
    }

    private func put(_ value: UInt64, at offset: Int, bytes: Int, in data: inout Data) {
        for index in 0..<bytes {
            data[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8))
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeImage(at url: URL) throws {
        try header().write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        // NTFS's backup boot sector commonly lies after the declared sector count.
        try handle.truncate(atOffset: capacity + 512)
    }

    func testSupportedSectorSizesAndGeometry() throws {
        for sectorSize: UInt64 in [512, 1024, 2048, 4096] {
            var data = header()
            put(sectorSize, at: 11, bytes: 2, in: &data)
            let boot = try BootSector(data: data, resourceByteCount: 128 * sectorSize + sectorSize)
            XCTAssertEqual(boot.bytesPerSector, sectorSize)
            XCTAssertEqual(boot.bytesPerCluster, sectorSize * 8)
            XCTAssertEqual(boot.bytesPerMFTRecord, 1024)
            XCTAssertEqual(boot.bytesPerIndexRecord, 4096)
            XCTAssertEqual(boot.mftCluster, 4)
            XCTAssertEqual(boot.mftMirrorCluster, 8)
            XCTAssertEqual(boot.serialNumberHex, "FEDCBA9876543210")
        }
    }

    func testDataSliceDoesNotAssumeZeroBasedIndices() throws {
        let prefix = Data(repeating: 0xff, count: 17)
        let sliced = (prefix + header()).dropFirst(17)
        XCTAssertEqual(try BootSector(data: sliced, resourceByteCount: capacity),
                       try BootSector(data: header(), resourceByteCount: capacity))
    }

    func testLargeClusterAndPositiveRecordEncoding() throws {
        var data = header()
        data[13] = 244 // 2^12 sectors per cluster.
        put(65536, at: 40, bytes: 8, in: &data)
        let boot = try BootSector(data: data, resourceByteCount: 65536 * 512)
        XCTAssertEqual(boot.bytesPerCluster, 2 * 1024 * 1024)
        data = header()
        data[64] = 1
        XCTAssertEqual(try BootSector(data: data, resourceByteCount: capacity).bytesPerMFTRecord, 4096)
    }

    func testShortAndNonNTFSHeadersAreRejected() {
        for count in 0..<512 {
            XCTAssertThrowsError(try BootSector(data: header().prefix(count), resourceByteCount: capacity))
        }
        var data = header()
        data[3] = 0
        XCTAssertThrowsError(try BootSector(data: data, resourceByteCount: capacity)) {
            XCTAssertEqual($0 as? InspectionError, .notNTFS)
        }
    }

    func testInvalidReservedFieldsAndSignatureAreRejected() {
        for offset in [14, 15, 16, 17, 18, 19, 20, 22, 23, 32, 33, 34, 35,
                       37, 39, 65, 66, 67, 69, 70, 71, 510, 511] {
            var data = header()
            data[offset] ^= 1
            XCTAssertThrowsError(try BootSector(data: data, resourceByteCount: capacity), "offset \(offset)")
        }
    }

    func testUnsupportedGeometryAndRecordCodesAreRejected() {
        for sectorSize: UInt64 in [0, 256, 513, 8192] {
            var data = header()
            put(sectorSize, at: 11, bytes: 2, in: &data)
            XCTAssertThrowsError(try BootSector(data: data, resourceByteCount: capacity))
        }
        for code: UInt8 in [0, 3, 129, 239, 254, 255, 240] {
            var data = header()
            data[13] = code
            XCTAssertThrowsError(try BootSector(data: data, resourceByteCount: capacity))
        }
        for code: UInt8 in [0, 3, 127, 128, 238, 248, 255] {
            for offset in [64, 68] {
                var data = header()
                data[offset] = code
                XCTAssertThrowsError(try BootSector(data: data, resourceByteCount: capacity))
            }
        }
    }

    func testCapacityAndSignedOverflowAreRejected() {
        XCTAssertThrowsError(try BootSector(data: header(), resourceByteCount: capacity - 1))
        for sectorCount: UInt64 in [0, UInt64.max, UInt64(Int64.max), UInt64(Int64.max) / 512 + 1] {
            var data = header()
            put(sectorCount, at: 40, bytes: 8, in: &data)
            XCTAssertThrowsError(try BootSector(data: data, resourceByteCount: .max))
        }
    }

    func testMFTLocationsAndRecordEndAreBounded() {
        for offset in [48, 56] {
            for location: UInt64 in [0, 16, UInt64.max] {
                var data = header()
                put(location, at: offset, bytes: 8, in: &data)
                XCTAssertThrowsError(try BootSector(data: data, resourceByteCount: capacity))
            }
        }
        var data = header()
        put(4, at: 56, bytes: 8, in: &data)
        XCTAssertThrowsError(try BootSector(data: data, resourceByteCount: capacity))
        data = header()
        data[64] = UInt8(bitPattern: -16)
        put(15, at: 48, bytes: 8, in: &data)
        XCTAssertThrowsError(try BootSector(data: data, resourceByteCount: capacity))
    }

    func testMutatingEachHeaderByteCannotCrashParser() {
        for offset in 0..<512 {
            var data = header()
            data[offset] ^= 0xff
            _ = try? BootSector(data: data, resourceByteCount: capacity)
        }
    }

    func testInspectionLeavesImageHashUnchangedAndDeniesWrites() throws {
        let image = try temporaryDirectory().appendingPathComponent("test.ntfs")
        try makeImage(at: image)
        let before = SHA256.hash(data: try Data(contentsOf: image))
        let report = try inspectPartitionImage(atPath: image.path)
        let after = SHA256.hash(data: try Data(contentsOf: image))
        XCTAssertEqual(before, after)
        XCTAssertEqual(report.writeAccess, "denied")
        XCTAssertEqual(report.volumeHealth, "unknown")
        XCTAssertEqual(report.blockers.count, 4)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        XCTAssertEqual(json["writeAccess"] as? String, "denied")
    }

    func testDeviceDirectoryFIFOAndSymlinkAreRejected() throws {
        let directory = try temporaryDirectory()
        let image = directory.appendingPathComponent("test.ntfs")
        try makeImage(at: image)
        let link = directory.appendingPathComponent("link.ntfs")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: image)
        let fifo = directory.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        for path in [directory.path, link.path, fifo.path, "/dev/null", "/dev/zero", "missing.ntfs", "bad\0path"] {
            XCTAssertThrowsError(try inspectPartitionImage(atPath: path), path)
        }
    }

    func testTruncatedImageIsRejected() throws {
        let image = try temporaryDirectory().appendingPathComponent("short.ntfs")
        try header().write(to: image)
        XCTAssertThrowsError(try inspectPartitionImage(atPath: image.path))
        try Data().write(to: image)
        XCTAssertThrowsError(try inspectPartitionImage(atPath: image.path))
    }

    func testFSKitRecognitionIsNeverUsableAndIdentityIsStable() throws {
        let first = try NTFSFileSystem.recognize(data: header(), resourceByteCount: capacity)
        let second = try NTFSFileSystem.recognize(data: header(), resourceByteCount: capacity)
        XCTAssertEqual(first.result, .recognized)
        XCTAssertEqual(first.name, "")
        XCTAssertEqual(first.containerID, second.containerID)
        XCTAssertNotNil(first.containerID)
        XCTAssertThrowsError(try NTFSFileSystem.recognize(data: header(), resourceByteCount: 512))
    }

    func testCLIJSONExitCodesAndImageHash() throws {
        let binary = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("ntfs-inspect")
        func run(_ arguments: [String]) throws -> (Int32, Data) {
            let process = Process()
            let output = Pipe()
            let errors = Pipe()
            process.executableURL = binary
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            _ = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationReason, .exit)
            return (process.terminationStatus, data)
        }
        let image = try temporaryDirectory().appendingPathComponent("cli.ntfs")
        try makeImage(at: image)
        let before = SHA256.hash(data: try Data(contentsOf: image))
        let (status, data) = try run([image.path])
        XCTAssertEqual(status, 0)
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(report["writeAccess"] as? String, "denied")
        XCTAssertEqual(report["volumeHealth"] as? String, "unknown")
        XCTAssertEqual(before, SHA256.hash(data: try Data(contentsOf: image)))
        let (badStatus, badData) = try run(["/dev/null"])
        XCTAssertEqual(badStatus, 1)
        let error = try XCTUnwrap(JSONSerialization.jsonObject(with: badData) as? [String: Any])
        XCTAssertEqual(error["status"] as? String, "error")
        XCTAssertEqual(try run([]).0, 64)
        XCTAssertEqual(try run(["--help"]).0, 0)
    }
}
