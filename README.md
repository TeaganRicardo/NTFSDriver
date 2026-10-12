# NTFSDriver

面向 Apple Silicon 和 macOS 27 的原生 NTFS 读写支持工具。目标是让用户完成一次安装与必要的系统授权后，即可在 Finder 和其他 macOS 应用中直接访问 NTFS 本地磁盘卷。

**当前状态：M1 已合入主分支；M2 已实现真实 NTFS 分区镜像的只读枚举、读取与哈希验证，以及可编译的 FSKit 卷和扩展打包原型。系统加载、Finder 本地卷和自动挂载尚未验证，写入始终被拒绝。当前没有可日常使用的驱动。**

## 产品需求

完整需求见 [产品需求文档 PRD v1.0](docs/PRD.md)，版本日期为 2026-10-12。

目标平台为 Apple Silicon / macOS 27，初始开发与验证环境为 macOS 27.0.1。

开发顺序与退出条件见 [开发与验收计划](docs/PLAN.md)；官方接口、引擎候选和待验证项见 [技术可行性研究](docs/FEASIBILITY.md)。

项目维护者不办理付费 Apple Developer 账号。自己的 FSKit 扩展目前缺少授权配置文件与发行签名；已有签名组件的复用也尚未验证。具体影响和路线见 [签名与系统集成限制](docs/SIGNING.md)。开发、离线读取与测试无需这类账号；原生挂载验收不能由离线结果代替。

## 核心目标

- NTFS 卷自动识别并挂载到标准的 `/Volumes` 路径，支持多个卷独立运行。
- Finder、磁盘工具及系统文件访问 API 将其识别为正常的本地磁盘卷。
- 正常卷支持常规文件与目录读写，并支持刷新待写入数据和安全推出。
- 日常使用无需打开管理程序、执行终端命令或重复授权。
- 保持 SIP 和 Full Security，不依赖第三方 KEXT。
- 提供免费的开源软件，不设置订阅、授权验证或付费功能。

## 技术与安全边界

原型采用 Apple FSKit 与固定版本的开源 `libntfs-3g`，使用自定义只读设备回调，不依赖 FUSE 运行时。引擎来源、关闭的恢复路径和生命周期审查见 [引擎接入审查](docs/ENGINE_AUDIT.md)。最终系统接入与发行路线仍待验证。

文件系统状态不明确、存在 Windows 休眠状态或其他完整性风险时，应拒绝写入，必要时提供只读访问。不得擅自清除 Dirty Flag、修改休眠状态、执行有数据损失风险的自动修复，或自动清理既有的 `._` 文件与迁移元数据。

所有破坏性测试必须使用专用测试磁盘或可丢弃的磁盘镜像，并通过哈希或等效方式验证数据完整性。

## 开发与验证

需要 Apple Silicon、macOS 27 和完整 Xcode；当前工程使用 Swift 6 与 C。NTFS-3G 源码已随仓库固定保存，无需下载 Swift 包或安装 NTFS 挂载工具。

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

读取完整的可丢弃分区镜像并输出 JSON：

```sh
swift run --scratch-path /tmp/ntfsdriver-local ntfs-read list /path/to/disposable-partition.img
swift run --scratch-path /tmp/ntfsdriver-local ntfs-read hash /path/to/disposable-partition.img /Alpha.bin
```

工具仅打开普通文件；不访问设备节点、不进行系统挂载。当前按原始名称精确匹配，不支持完整 Windows 大小写语义、xattr/ADS 或 reparse point 访问。报告 Dirty Flag，但整体健康仍为 unknown，休眠状态尚未检查；读取成功不构成写入许可。测试镜像与重建步骤见 [测试说明](docs/TESTING.md)。

提交全部源码后，可执行 `./scripts/build-preview.sh` 构建包含 `.appex` 的临时宿主 app。该包使用 ad hoc 签名，仅用于工程检查；它没有获准加载到 FSKit，也不是发行安装包。媒体自动匹配配置保持为空，不启用 NTFS 自动接管。FSKit 适配器只有在引擎打开与根目录访问成功后才返回 `usableButLimited`，所有修改入口返回只读错误；检查与格式化不提供修复能力。

## 开源许可证

项目自有代码采用 [GPL-3.0-or-later](LICENSE)。第三方文件保留原有许可，详见 [第三方代码说明](THIRD_PARTY.md)。正式发行还需完成最终组成、对应源码和签名公证验收。
