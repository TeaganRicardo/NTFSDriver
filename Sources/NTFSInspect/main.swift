import Darwin
import Foundation
import NTFSCore

struct ErrorReport: Encodable {
    let status = "error"
    let message: String
}

func emit<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(value))
    FileHandle.standardOutput.write(Data([10]))
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--help"] || arguments == ["-h"] {
    print("""
    用法：ntfs-inspect <原始 NTFS 分区镜像文件>
    只读取普通文件的引导头并输出 JSON；不会挂载、修复或写入。
    不接受设备节点、末级符号链接、完整磁盘镜像或 DMG 容器。
    引导结构识别成功不表示卷健康或可以安全写入。
    """)
    exit(0)
}
guard arguments.count == 1 else {
    FileHandle.standardError.write(Data("用法：ntfs-inspect <分区镜像文件>；详见 --help。\n".utf8))
    exit(64)
}
do {
    try emit(inspectPartitionImage(atPath: arguments[0]))
} catch {
    try? emit(ErrorReport(message: error.localizedDescription))
    exit(1)
}
