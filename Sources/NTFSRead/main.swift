// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Darwin
import Foundation
import NTFSReadOnly

struct ListReport: Encodable {
    let volume: VolumeInformation
    let entries: [DirectoryEntry]
    let io: ReadStatistics
}
struct HashReport: Encodable {
    let volume: VolumeInformation
    let bytes: UInt64
    let sha256: String
    let io: ReadStatistics
}
struct ErrorReport: Encodable { let status = "error"; let operation: String; let message: String }

func emit<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(value))
    FileHandle.standardOutput.write(Data([10]))
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--help"] {
    print("""
    用法：ntfs-read list <原始分区镜像> [目录路径]
          ntfs-read hash <原始分区镜像> <文件路径>
    使用固定 NTFS 引擎只读枚举或读取；不挂载、不修复、不修改镜像。
    文件路径为镜像内的绝对路径，当前按原始名称精确匹配。
    """)
    exit(0)
}
guard (arguments.first == "list" && (2...3).contains(arguments.count)) ||
      (arguments.first == "hash" && arguments.count == 3) else {
    FileHandle.standardError.write(Data("用法错误；详见 ntfs-read --help。\n".utf8))
    exit(64)
}
var operation = "openImage"
do {
    let volume = try ReadOnlyVolume(imagePath: arguments[1])
    // Explicit close before reporting success; deinit is only a fallback on failure.
    operation = "volumeInformation"
    let info = try volume.information()
    if arguments[0] == "list" {
        operation = "lookupDirectory"
        let directory = try volume.item(atPath: arguments.count == 3 ? arguments[2] : "/")
        var entries: [DirectoryEntry] = []
        var cookie: Int64 = 0
        operation = "enumerateDirectory"
        while true {
            let page = try volume.entries(in: directory, startingAt: cookie)
            entries.append(contentsOf: page.entries)
            guard entries.count <= 100_000 else { throw POSIXError(.EOVERFLOW) }
            if !page.hasMore { break }
            guard page.nextCookie > cookie else { throw POSIXError(.EIO) }
            cookie = page.nextCookie
        }
        operation = "closeVolume"
        let io = try volume.close()
        try emit(ListReport(volume: info, entries: entries, io: io))
    } else {
        operation = "lookupFile"
        let reference = try volume.item(atPath: arguments[2])
        operation = "fileAttributes"
        let attributes = try volume.attributes(of: reference)
        guard !attributes.isDirectory else { throw POSIXError(.EISDIR) }
        var hash = SHA256()
        var offset: UInt64 = 0
        operation = "readFile"
        while offset < attributes.size {
            let data = try volume.read(reference, at: offset,
                                       count: Int(min(1024 * 1024, attributes.size - offset)))
            guard !data.isEmpty else { throw POSIXError(.EIO) }
            hash.update(data: data)
            offset += UInt64(data.count)
        }
        operation = "closeVolume"
        let io = try volume.close()
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        try emit(HashReport(volume: info, bytes: offset, sha256: digest, io: io))
    }
} catch {
    try? emit(ErrorReport(operation: operation, message: error.localizedDescription))
    exit(1)
}
