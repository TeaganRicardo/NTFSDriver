# NTFSDriver

面向 Apple Silicon 和 macOS 27 的原生 NTFS 读写支持工具。目标是让用户完成一次安装与必要的系统授权后，即可在 Finder 和其他 macOS 应用中直接访问 NTFS 本地磁盘卷。

**当前状态：M0 可行性研究与 M1 安全识别基础已完成，实现了分区镜像诊断工具和可编译的 FSKit 探测适配器。尚未提供可安装、可挂载或可读写文件的驱动。**

## 产品需求

完整需求见 [产品需求文档 PRD v1.0](docs/PRD.md)，版本日期为 2026-10-12。

目标平台为 Apple Silicon / macOS 27，初始开发与验证环境为 macOS 27.0.1。

开发顺序与退出条件见 [开发与验收计划](docs/PLAN.md)；官方接口、引擎候选和待验证项见 [技术可行性研究](docs/FEASIBILITY.md)。

## 核心目标

- NTFS 卷自动识别并挂载到标准的 `/Volumes` 路径，支持多个卷独立运行。
- Finder、磁盘工具及系统文件访问 API 将其识别为正常的本地磁盘卷。
- 正常卷支持常规文件与目录读写，并支持刷新待写入数据和安全推出。
- 日常使用无需打开管理程序、执行终端命令或重复授权。
- 保持 SIP 和 Full Security，不依赖第三方 KEXT。
- 提供免费的开源软件，不设置订阅、授权验证或付费功能。

## 技术与安全边界

优先评估 Apple 公开提供的 FSKit 等系统接口，并评估复用成熟开源 NTFS 引擎的可行性。具体架构与第三方依赖尚未确定。

文件系统状态不明确、存在 Windows 休眠状态或其他完整性风险时，应拒绝写入，必要时提供只读访问。不得擅自清除 Dirty Flag、修改休眠状态、执行有数据损失风险的自动修复，或自动清理既有的 `._` 文件与迁移元数据。

所有破坏性测试必须使用专用测试磁盘或可丢弃的磁盘镜像，并通过哈希或等效方式验证数据完整性。

## 开发与验证

需要 Apple Silicon、macOS 27 和完整 Xcode；当前工程使用 Swift 6，无第三方包依赖。

执行自动测试和 Release 构建：

```sh
./scripts/check.sh
```

脚本在临时目录构建并清理产物，避免 Documents 目录的 Finder 元数据导致 XCTest 签名失败。

开发者可以检查可丢弃的原始 NTFS 分区镜像：

```sh
swift run --scratch-path /tmp/ntfsdriver-local ntfs-inspect /path/to/disposable-partition.img
```

工具只读取普通文件的引导头并输出 JSON，拒绝设备节点和末级符号链接。输入必须从分区引导扇区开始；不解析完整磁盘分区表或 DMG 容器。识别成功仅说明引导结构在支持范围内，输出仍保持 `writeAccess: denied` 和 `volumeHealth: unknown`。

`NTFSFSKit` 当前是协议适配库，尚未打包为 `.appex` 或注册到系统。探测最多返回 `recognized`；卷加载、检查和格式化均返回不支持。Finder、本地卷、自动挂载、Windows 互操作与安全写入验收安排在后续阶段。

## 开源许可证

开源许可证待确定。引入第三方 NTFS 引擎或其他组件前，需要确认其许可证与项目分发方式的兼容性。
