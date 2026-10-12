# NTFSDriver 技术可行性研究

研究日期：2026-10-12。依据：[PRD v1.0](PRD.md)。状态：路线评估，尚未通过实际文件系统挂载或读写验收。

## 结论与暂定路线

优先验证 **FSKit 文件系统扩展 + 成熟 NTFS 用户空间引擎**。FSKit 提供接入系统文件系统机制的公开接口；NTFS 引擎负责磁盘格式和文件操作；两者之间实现一个设备 I/O 与卷语义适配层。Apple 明确说明 FSKit 扩展运行在用户空间，并接入 Disk Arbitration、NetFS 和系统挂载工具；当前支持的 `FSUnaryFileSystem` 流程适合一个分区对应一个卷。[Apple FSKit 概览](https://developer.apple.com/documentation/fskit/)

M0 优先评估 Tuxera 的 `libntfs-3g`，同时审查已有的 FSKit 移植项目能否减少适配工作。M2 已固定并接入该库的只读路径，项目许可为 GPL-3.0-or-later，详见 [引擎接入审查](ENGINE_AUDIT.md)。尚未安装扩展或启用真实磁盘写入；原生验收仍待完成。

产品可行性最先取决于两道证据门槛：一是有效签名的扩展能够被 macOS 27.0.1 正常发现、启用和调度；二是 NTFS 测试卷能够经 Disk Arbitration 自动挂载为 `/Volumes` 下的本地卷，并在 Finder、磁盘工具和标准文件 API 中正常工作。SDK 存在、代码编译通过、人工执行一次挂载命令，均不能替代这两项验收。

## 已核对的开发环境与证据范围

以下为 2026-10-12 在开发机执行只读环境查询的结果：

| 项目 | 结果 |
| --- | --- |
| 主机 | macOS 27.0.1，Build `26A434` |
| 架构 | `arm64` |
| Swift | Apple Swift 6.4，`swiftlang-6.4.0.34.1` |
| SDK | macOS 27.0，`macosx27.0` |
| SDK 路径 | `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk` |
| FSKit 头文件 | SDK 内 `System/Library/Frameworks/FSKit.framework/Headers` |
| Xcode 模板 | 平台模板中的 `Application Extension/File System Extension.xctemplate` |

复核命令：`sw_vers`、`uname -m`、`xcrun swift --version`、`xcrun --show-sdk-path`，以及读取 SDK 的 `SDKSettings.json`。本次环境查询没有打开块设备、挂载镜像或改变扩展配置。

Apple 已公开的 DiskArbitration 源码快照为 `a542bda934211dc3c301bfdcc7f21349c4164a85`，提交说明 `DiskArbitration-535.0.10`，提交日期 2025-10-16。它可用于理解设计和制定实验，**不能假定与 macOS 27.0.1 的实际系统二进制逐行一致**。[Apple 源码提交](https://github.com/apple-oss-distributions/DiskArbitration/commit/a542bda934211dc3c301bfdcc7f21349c4164a85)

## FSKit 与本地磁盘集成

### 块设备与数据访问

`FSBlockDeviceResource` 表示真实磁盘分区，由 `fskitd` 创建实际资源并管理底层设备访问。它提供分区读写方法，但不公开底层文件描述符。因此适配已有引擎时，不能假定引擎可自行打开 `/dev/disk*`；应把引擎的设备操作接到这个资源对象。Apple 还要求使用块设备的 unary 文件系统实现 `FSManageableResourceMaintenanceOperations`，并说明块设备文件系统在通过检查前不会挂载。[块设备资源](https://developer.apple.com/documentation/fskit/fsblockdeviceresource)、[维护操作协议](https://developer.apple.com/documentation/fskit/fsmanageableresourcemaintenanceoperations)

I/O 适配必须处理设备的逻辑和物理块大小、偏移对齐、部分读写、资源撤销以及错误传播。直接 I/O 绕过内核缓冲缓存；Apple 明确禁止在同一范围混用直接 I/O 与 metadata I/O。初始只读探针统一使用直接读取；后续缓存和写入策略需要单独设计与验证，不能根据性能目标提前混用两条路径。[块设备资源与 I/O 约束](https://developer.apple.com/documentation/fskit/fsblockdeviceresource)

### 探测成功不等于可挂载

FSKit 的探测结果表达格式识别和可用性两件事：

| 返回值 | Apple 定义 | 本项目使用边界 |
| --- | --- | --- |
| `notRecognized` | 格式不属于该模块 | 明确不是 NTFS 的资源 |
| `recognized` | 已识别格式，但无法使用 | 仅完成结构识别、尚无可用卷实现的阶段 |
| `usableButLimited` | 可以使用，但能力受限 | 只有真实只读卷实现和限制处理均已验证后才考虑使用 |
| `usable` | 已准备好使用 | 卷实现与安全检查均完成后才考虑使用 |

这些语义来自 Apple 的枚举文档和本机 SDK `FSResource.h`；`usableButLimited` 不能作为“只知道 NTFS 签名”的替代返回值。[FSMatchResult](https://developer.apple.com/documentation/fskit/fsmatchresult)

首个里程碑中，合法启动扇区最多只构成 NTFS 格式和几何参数证据。Dirty Flag、NTFS 版本、`$LogFile`、Windows 休眠状态以及关键元数据一致性尚未读取时，安全状态应保持未知，不能批准写入。即使某资源返回 `recognized`，也不部署这个探针作为正式系统扩展。

### 与系统 NTFS 驱动的仲裁

Apple 的已公开 `DAProbe.c` 在 FSKit 编译分支中，明确把传统 `ntfs` 探测延后到 FSKit 模块阶段；`DASupport.m` 随后把延后的传统探针追加到 FSKit 候选之后。这为通过系统仲裁选择第三方 NTFS 扩展提供了源码依据，无需据此设计替换系统文件或反复抢占已挂载卷的守护进程。[延后原生 ntfs 探测](https://github.com/apple-oss-distributions/DiskArbitration/blob/a542bda934211dc3c301bfdcc7f21349c4164a85/diskarbitrationd/DAProbe.c#L128)、[FSKit 候选与延后探针](https://github.com/apple-oss-distributions/DiskArbitration/blob/a542bda934211dc3c301bfdcc7f21349c4164a85/diskarbitrationd/DASupport.m#L757)

该源码还显示：模块属性须声明 `FSSupportsBlockResources`，并提供 `FSMediaTypes` 和 `FSPersonalities`；Disk Arbitration 用 `FSMediaProperties` 匹配 IOMedia，并通过当前控制台用户的身份查询模块。开发阶段需要给 `FSShortName` 和 bundle identifier 独立名称，逐项核对目标 GPT、MBR 和无分区介质的实际 IOMedia 属性，避免把所有“基本数据分区”都当作 NTFS。[模块属性读取](https://github.com/apple-oss-distributions/DiskArbitration/blob/a542bda934211dc3c301bfdcc7f21349c4164a85/diskarbitrationd/DASupport.m#L522)、[用户身份与模块查询](https://github.com/apple-oss-distributions/DiskArbitration/blob/a542bda934211dc3c301bfdcc7f21349c4164a85/diskarbitrationd/DASupport.m#L839)

不能承诺“设置较小的 `FSProbeOrder` 就一定优先”。传统候选列表有数字排序，但上述 FSKit 候选路径没有相同的显式排序；其他已成功识别介质的传统驱动也可能先结束探测。第三方商业驱动共存、登录用户切换、开机尚未登录等情形，都需要目标系统实测。[传统探测列表排序](https://github.com/apple-oss-distributions/DiskArbitration/blob/a542bda934211dc3c301bfdcc7f21349c4164a85/diskarbitrationd/DASupport.m#L384)、[FSKit 候选形成过程](https://github.com/apple-oss-distributions/DiskArbitration/blob/a542bda934211dc3c301bfdcc7f21349c4164a85/diskarbitrationd/DASupport.m#L757)

从该公开源码推断，模块返回 `recognized` 会映射为 `EIO`，继续尝试后续候选；返回 `usable` 才进入可用探测流程。这是源码推断，不能用来声称编译中的探针已通过“不会干扰原生挂载”的实际验收。[FSKit 结果转换](https://github.com/apple-oss-distributions/DiskArbitration/blob/a542bda934211dc3c301bfdcc7f21349c4164a85/diskarbitrationd/DASupport.m#L1017)

### `/Volumes` 与 Finder 验收

Apple 的公开 `FSClient.mountSingleVolume` 文档说明，它完成资源加载、卷激活、挂载点创建及挂载，并将卷放入 `/Volumes/`；调用端需要额外的 `com.apple.developer.fskit.mount` entitlement。这说明存在官方标准路径，但该管理 API 的资格及运行结果需要验证，不能把它当作默认必需权限。日常自动挂载优先让系统 Disk Arbitration 调度。[单卷挂载 API](https://developer.apple.com/documentation/fskit/fsclient/mountsinglevolume(resource:bundleid:options:completionhandler:))

P0-04 的验收必须保存同一次测试的系统卷信息、挂载信息和 Finder／磁盘工具实际表现：真实本地卷身份、卷名、标准挂载位置、文件访问、正常推出。Apple 的 passthrough 样例需要手工创建目录并执行挂载，只用于理解 API 与生命周期；它不证明本项目的 NTFS 自动识别或本地磁盘体验。[官方 passthrough 样例](https://developer.apple.com/documentation/fskit/building-a-passthrough-file-system)

## 扩展、授权与发行

FSKit 使用文件系统 app extension；Apple 的入口协议是 `UnaryFileSystemExtension`，其 `fileSystem` 返回 `FSUnaryFileSystem` 与操作协议的实现。Xcode 的文件系统扩展模板配置 `EXExtensionPointIdentifier = com.apple.fskit.fsmodule`、`EXAppExtensionAttributes` 和 `FSShortName`。本机模板中块设备支持默认关闭，`FSMediaTypes` 默认为空；新建 target 并不会自动获得正确的 NTFS 自动探测配置。[扩展入口协议](https://developer.apple.com/documentation/fskit/unaryfilesystemextension)、[官方样例的工程配置](https://developer.apple.com/documentation/fskit/building-a-passthrough-file-system)

`com.apple.developer.fskit.fsmodule` 是公开的布尔 entitlement。Apple 当前 capabilities 表将 FSKit Module 标记为 Apple Developer Program 和 Developer ID 支持，免费 Apple Developer 一栏为空；不能假定公开仓库、ad hoc 签名或仅声明 entitlement 就足以完成可分发扩展。实际团队配置、签名身份、配置文件和系统加载仍需逐项验证。[公开 entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.fskit.fsmodule)、[macOS capabilities 表](https://developer.apple.com/help/account/reference/supported-capabilities-macos/)

维护者已明确不办理付费团队，当前缺少匹配本项目的授权配置文件与 Developer ID 身份。自己的扩展路线尚无已验证的加载和发行条件。已签名 macFUSE FSKit 后端可以作为另一路线调查，但它的系统行为、部分非开源组件及许可同样需要核对；详见 [当前约束与选择](SIGNING.md)。

官方样例要求用户在“系统设置 → 通用 → 登录项与扩展 → 文件系统扩展”启用模块。管理程序可以使用 `FSClient` 查询已安装模块，并读取 `FSModuleIdentity.isEnabled`；`openFileSystemExtensionsSettings()` 打开设置页面，文档没有承诺它可绕过用户授权或静默启用模块。首次安装方案应围绕可观察状态和系统授权引导设计。[官方启用流程](https://developer.apple.com/documentation/fskit/building-a-passthrough-file-system)、[已安装模块查询](https://developer.apple.com/documentation/fskit/fsclient)、[模块状态](https://developer.apple.com/documentation/fskit/fsmoduleidentity)、[打开设置页面](https://developer.apple.com/documentation/fskit/fsclient/openfilesystemextensionssettings())

面向用户的直接发行暂定为含扩展的已签名 app／安装包，采用 Developer ID、Hardened Runtime、notarization 和 stapling。Apple 的 notarization 文档要求正确签名、时间戳等条件；完成公证也仍需在干净环境验收安装、授权、升级和卸载。本阶段只准备可构建工程，不修改用户系统的扩展注册状态。[Apple 公证与分发要求](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

## 引擎与现有实现比较

| 候选 | 一手来源中的能力与许可 | 对本项目的判断 |
| --- | --- | --- |
| Tuxera `libntfs-3g` | 跨平台用户空间 NTFS 读写引擎；NTFS 组件和库为 GPL-2.0-or-later；有设备操作回调和文件／目录／属性 API | 优先评估。将库直接适配 FSKit，避免引入 FUSE 运行时。不能直接套用命令行挂载默认行为 |
| Linux `ntfs3` | Linux 内核读写驱动，包含普通／稀疏／压缩文件、日志回放和 xattr；主要源文件标记 GPL-2.0，依赖 Linux VFS、块设备与缓存接口 | 可作为行为对照；移植为用户空间库会承担大量内核语义改造，暂不作为最短实现路径 |
| libyal `libfsntfs` | 项目自称 experimental，NTFS 3.0／3.1 只读，库为 LGPL-3.0-or-later | 可评估为离线只读分析参考；不具备 P0 完整写入能力，不额外加入产品依赖 |
| `whereteam/ntfskit` | 已公开 FSKit + libntfs-3g 适配代码；驱动开源、管理 UI 另有许可；普通读写打开路径使用 RECOVER | 优先做源码审查以减少重复工作，但安全策略和逐文件许可尚不满足直接复用条件；其营销描述和自报基准不视为本项目验收 |

表中来源：[NTFS-3G README](https://github.com/tuxera/ntfs-3g/blob/7f0f841fc52cf719106c5c93bafe465004e36816/README)、[设备 API](https://github.com/tuxera/ntfs-3g/blob/7f0f841fc52cf719106c5c93bafe465004e36816/include/ntfs-3g/device.h)、[目录 API](https://github.com/tuxera/ntfs-3g/blob/7f0f841fc52cf719106c5c93bafe465004e36816/include/ntfs-3g/dir.h)、[Linux NTFS3 文档](https://docs.kernel.org/filesystems/ntfs3.html)、[Linux 内核依赖与许可](https://github.com/torvalds/linux/blob/master/fs/ntfs3/file.c)、[libfsntfs README](https://github.com/libyal/libfsntfs)、[NTFSKit 项目](https://github.com/whereteam/ntfskit)

NTFS-3G 官方最新稳定发布是 `2026.9.28`，对应 `7f0f841fc52cf719106c5c93bafe465004e36816`；发布记录包含最近的回归与内存错误修复，官方也持续公布安全公告。下一阶段应冻结选定版本、源代码／发布包校验值、构建配置和修改清单，并把安全公告核对纳入升级流程；“成熟”不能替代对畸形元数据的输入防护。[官方 2026.9.28 发布](https://github.com/tuxera/ntfs-3g/releases/tag/2026.9.28)、[官方安全公告](https://github.com/tuxera/ntfs-3g/security)

### libntfs-3g 的可适配边界

`ntfs_device_operations` 提供 `open/close/seek/read/write/pread/pwrite/sync/stat/ioctl` 回调，`ntfs_device_alloc` 接受私有状态，`ntfs_device_mount` 可以加载这种设备。上游构建也提供关闭 FUSE driver 和单独构建库的选项。技术上可把设备回调映射到 FSKit 资源，但需在 C 与 Swift 边界验证缓冲区生命周期、偏移／长度溢出、错误码以及同步语义。[设备回调定义](https://github.com/tuxera/ntfs-3g/blob/7f0f841fc52cf719106c5c93bafe465004e36816/include/ntfs-3g/device.h#L98)、[库加载入口](https://github.com/tuxera/ntfs-3g/blob/7f0f841fc52cf719106c5c93bafe465004e36816/include/ntfs-3g/volume.h#L298)、[构建选项](https://github.com/tuxera/ntfs-3g/blob/7f0f841fc52cf719106c5c93bafe465004e36816/configure.ac#L132)

低层 API 不会自动补齐 FUSE 前端负责的全部行为。FSKit 仍需正确管理 item 身份、打开引用、删除后仍打开的文件、替换重命名、目录枚举、权限和 macOS 元数据。初始引擎适配建议按卷串行化访问，待验证后再优化并发；这是本项目的保守设计选择，不是对引擎线程安全的已证实结论。

### 不能把引擎“挂载／检查”当作纯读取

上游 `volume.h` 定义 `NTFS_MNT_RDONLY`、`NTFS_MNT_FORENSIC`、`NTFS_MNT_RECOVER` 和 `NTFS_MNT_IGNORE_HIBERFILE`。`volume.c` 的读写加载流程会检查休眠文件和日志，启用 RECOVER 时可能重置未正常关闭的日志，另有把根目录 `$TXF_DATA` 变为 resident 的修改路径。因此，即使尚未调用普通文件写入，打开读写卷本身也可能修改介质。[挂载 flags](https://github.com/tuxera/ntfs-3g/blob/7f0f841fc52cf719106c5c93bafe465004e36816/include/ntfs-3g/volume.h#L60)、[读写加载与恢复分支](https://github.com/tuxera/ntfs-3g/blob/7f0f841fc52cf719106c5c93bafe465004e36816/libntfs-3g/volume.c#L1283)、[TXF 元数据修改](https://github.com/tuxera/ntfs-3g/blob/7f0f841fc52cf719106c5c93bafe465004e36816/libntfs-3g/volume.c#L850)

初始引擎实验应同时使用只读／forensic 设置、只读打开的镜像和拒绝全部写操作的设备回调，并记录是否发生写入尝试。不能只设置 FORENSIC：上游打开设备的权限由卷的 readonly 状态决定。只读加载会跳过部分读写安全检查，因此“只读打开成功”同样不能批准后续写入；休眠、dirty 和日志等证据需要显式收集。[设备打开模式](https://github.com/tuxera/ntfs-3g/blob/7f0f841fc52cf719106c5c93bafe465004e36816/libntfs-3g/volume.c#L544)、[安全检查条件](https://github.com/tuxera/ntfs-3g/blob/7f0f841fc52cf719106c5c93bafe465004e36816/libntfs-3g/volume.c#L1283)

不能自动运行 `ntfsfix`、清除 Dirty Flag、忽略休眠状态或执行日志修复来让测试通过。若需要维护操作协议，先实现不写盘的检查与准确失败；格式化和修复返回不支持，直至产品明确新增对应范围并完成安全设计。

### 已有 FSKit 移植的复用条件

本次只读审查 `ntfskit` 快照 `b7153a8dd51b895d0a87345c6ad8e95bda963ed3`：普通读写打开路径选用 `NTFS_MNT_RECOVER`，修复路径写入清除 Dirty Flag。它不能直接满足本 PRD 的默认安全政策。[普通打开 flags](https://github.com/whereteam/ntfskit/blob/b7153a8dd51b895d0a87345c6ad8e95bda963ed3/NTFSModule/bridge/ntfs_bridge.c#L134)、[修复路径](https://github.com/whereteam/ntfskit/blob/b7153a8dd51b895d0a87345c6ad8e95bda963ed3/NTFSModule/bridge/ntfs_bridge.c#L756)

该仓库许可也须逐文件核对：顶层区分 GPL 驱动与另有许可的 UI，bridge 有 GPL-2.0-or-later 声明，随附 `mkntfs/boot.c` 则写明 GPL v3-or-later。项目级标签不能代替逐文件的许可和来源记录。下一阶段只考虑审查后可安全复用的驱动部分，不把 UI、格式化或修复代码纳入默认范围。[顶层许可](https://github.com/whereteam/ntfskit/blob/b7153a8dd51b895d0a87345c6ad8e95bda963ed3/LICENSE)、[bridge 许可声明](https://github.com/whereteam/ntfskit/blob/b7153a8dd51b895d0a87345c6ad8e95bda963ed3/NTFSModule/bridge/ntfs_bridge.h#L1)、[随附 boot.c 许可声明](https://github.com/whereteam/ntfskit/blob/b7153a8dd51b895d0a87345c6ad8e95bda963ed3/NTFSModule/bridge/mkntfs/boot.c#L1)

`libntfs-3g` 本身是 GPL-2.0-or-later，仓库内的 `COPYING.LIB` 对应 fuse-lite，不能据其文件名误判 NTFS 库为 LGPL。采用该引擎时，暂定按兼容的 GPL 开源发行路径评估，同时核对所选源码、Apple 构建与发行条件；许可证决定和源码分发清单在引入依赖之前落实。[上游许可范围说明](https://github.com/tuxera/ntfs-3g/blob/7f0f841fc52cf719106c5c93bafe465004e36816/README#L33)

## 继续执行的证据门槛

| 门槛 | 必须获得的证据 | 未通过时的处理 |
| --- | --- | --- |
| G1：无写入识别与 API 编译 | 有界启动扇区／几何校验、溢出与截断测试；FSKit 类型和协议在目标 SDK 编译；安全状态保持未知 | 只继续离线解析；不返回可用卷 |
| G2：签名与系统仲裁 | 签名 app 与扩展可正常注册、用户启用状态可观测；仅用可丢弃介质验证自动探测、本地卷、`/Volumes`、Finder 与推出 | 记录系统限制，修正集成路线；不增加抢挂载守护进程掩盖失败 |
| G3：真实只读卷 | 固定引擎、拒写设备层、全镜像前后哈希一致；枚举与文件读取哈希、Unicode／ADS／xattr 样例、多个卷与卸载均正确 | 保持只读实验；错误准确返回，不尝试修复 |
| G4：受控写入 | 明确的 dirty／休眠／日志判断、不可写状态；覆盖和重命名、打开文件生命周期、同步、空间耗尽、I/O 错误和断连测试；Windows 往返与检查 | 继续拒写或只读；不能用“复制成功”替代数据完整性验收 |
| G5：可安装产品 | 干净系统上的安装授权、重启恢复、驱动冲突、睡眠唤醒、升级／卸载；目标设备基准与长期稳定性 | 保持预览／测试状态，不宣称完成 P0／P1 |

G2 至 G5 均需实际目标系统和专用测试介质；托管 CI 的编译／单元测试只能覆盖其可执行部分。所有破坏性实验局限于可丢弃镜像或专用测试盘，并保留镜像来源、系统／引擎版本、操作步骤、哈希与检查结果。正式写入之前须完成对 NTFS ADS、macOS xattr 和既有 AppleDouble 文件的兼容策略；不得自动清理 `._` 文件。
