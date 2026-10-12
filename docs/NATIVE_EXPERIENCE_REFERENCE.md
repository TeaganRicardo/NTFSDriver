# 原生 NTFS 体验：竞品证据与实现基准

调查日期：2026-10-12。目标平台：Apple Silicon、macOS 27.0.1。本文使用厂商文档、Apple 公开 API、开源仓库的实际代码与维护者测试记录；未购买或安装 Paragon、Tuxera 或 xntfs 的商业发行包，也未将第三方自述视为本机验收。

## 决策

**技术主标杆：[HuanchuanTech/xntfs](https://github.com/HuanchuanTech/xntfs)**。其已公开的 FSKit + `libntfs-3g` 路线，能把 NTFS 物理块设备交给 FSKit 的 `FSBlockDeviceResource`，交由系统 Disk Arbitration 按 `FSMediaTypes` 探测、选择、挂载，而不要求常驻 GUI、KEXT 或 macFUSE。参见 [xntfs README](https://github.com/HuanchuanTech/xntfs/blob/main/README_CN.md)、[扩展配置](https://github.com/HuanchuanTech/xntfs/blob/main/ntfs3g/Info.plist)、[Apple FSKit](https://developer.apple.com/documentation/fskit/)。

**体验标杆：[Paragon NTFS for Mac](https://paragon-software.zendesk.com/hc/en-us/articles/29003988155409-NTFS-For-Mac-Supported-OS-Versions)**。目标是其用户熟悉的「安装一次、连接即出现本地磁盘、原生文件操作与安全推出」体验，不复制其内核扩展架构。官方列出 Paragon 18.0.24+ 支持 macOS 27，但其 [Apple Silicon 安全设置说明](https://paragon-software.zendesk.com/hc/en-us/articles/26812065365777--Reduced-Security-and-Products-for-Mac-by-Paragon-Software) 仍要求 Reduced Security 以使用 KEXT；未取得证据表明版本 18 已改变此要求。

**不可省略的现实限制**：本项目维护者不办理付费 Apple Developer 账号，自签 FSKit 模块缺少授权配置文件。真实可运行的本项目 FSKit 扩展及免费发行必须有**确实可执行的签名/发行主体**，或者有另一条已签名、开放且满足物理卷验收的受支持接入边界。目前均未落实。参考 xntfs 不自动解决这个问题。[Apple 能力表](https://developer.apple.com/help/account/reference/supported-capabilities-macos/)、[xntfs 签名说明](https://github.com/HuanchuanTech/xntfs/blob/main/README_CN.md)、本仓库 [SIGNING.md](SIGNING.md)。

## 按目标约束比较，而不是宣传式总体排名

| 软件/路线 | 已知架构与 macOS 27 状态 | 对「像系统原生支持 NTFS」的贡献 | 是否适合作为本项目主路线 |
| --- | --- | --- | --- |
| **xntfs** | FSKit 扩展 + `libntfs-3g`；直接块设备资源、`FSMediaTypes`、系统自动挂载；开发者记录 macOS 27 实机镜像及已附加分区测试；App Store 有发行版 | 直接提供符合系统卷模型的实现范例，开源可审查；无需 KEXT 或常驻助手 | **技术主标杆**，但其签名不可复用于修改版；未独立验证本机真实 USB 插盘 |
| **Paragon NTFS 18** | 厂商列出 macOS 27 支持；Apple Silicon 的公开驱动说明要求 KEXT + Reduced Security | 成熟面向用户的磁盘读写、安装和管理体验可作验收基准 | **体验标杆**，其技术路线违反 Full Security / 无 KEXT 的既定要求 |
| **Tuxera NTFS for Mac 2027** | 官方版本日志列出 macOS 27；部署说明明确安装内核扩展 | 商用完整读写与运维参考 | 不采用其 KEXT 架构；复用的是单独开源的 `libntfs-3g` |
| **whereteam/NTFSKit** | 开源 FSKit + NTFS-3G 代码，宣称系统自动识别及元数据兼容；本项目未取得可核验签名发行包 | FSKit 操作映射、ADS/xattr 设计可作交叉参考 | 其普通写挂载采用 `NTFS_MNT_RECOVER`、维护路径可清 dirty，与当前禁止自动修复的政策冲突 |
| **macFUSE 5.4 FSKit** | 本机已签名模块+普通用户客户端可通过 `/Volumes` 提供可读虚拟本地卷 | 在缺少自有签名的情况下证明一条运行通道 | **不是正式接入路线**：合成 4KiB DADisk 不能代表原始 NTFS 分区，系统只读标识与标准推出未通过 |

来源：[Paragon 支持表](https://paragon-software.zendesk.com/hc/en-us/articles/29003988155409-NTFS-For-Mac-Supported-OS-Versions)、[Paragon 启动安全](https://paragon-software.zendesk.com/hc/en-us/articles/26812065365777--Reduced-Security-and-Products-for-Mac-by-Paragon-Software)、[Tuxera 发行说明](https://macsupport.tuxera.com/hc/en-gb/articles/4406039424146-Release-notes)、[Tuxera 部署](https://macsupport.tuxera.com/hc/en-gb/articles/360021071460-How-do-I-license-and-deploy-NTFS-for-Mac-in-an-organization-or-for-multiple-users)、[NTFSKit 源码](https://github.com/whereteam/ntfskit)、本仓库 [ALTERNATIVES.md](ALTERNATIVES.md)、[MACFUSE_EXPERIMENT.md](MACFUSE_EXPERIMENT.md)。不存在跨产品、同一硬件条件下的独立性能/可靠性排名；上表只对**与本项目约束的适配度**排序。

## xntfs 已解决的工程问题：逐层复用

| 现成证据位置 | 对本项目意味着什么 | 决策 |
| --- | --- | --- |
| [`ntfs3g/Info.plist`](https://github.com/HuanchuanTech/xntfs/blob/main/ntfs3g/Info.plist) | `FSSupportsBlockResources`、针对 `Windows_NTFS` / Microsoft Basic Data GUID / partitionless 的 `FSMediaTypes`、`FSProbeOrder`。由系统仲裁，不由私有守护进程抢挂载 | 审核选择顺序与误识别风险，单独测试；在本项目完成签名/物理设备验证前**不得**在现有扩展启用媒体接管 |
| [`ntfs3gFileSystem.swift`](https://github.com/HuanchuanTech/xntfs/blob/main/ntfs3g/ntfs3gFileSystem.swift) | `probeResource` / `loadResource` / `activate` / `startCheck` 的职责边界，load 先只读、activate 后决策写权限 | 建立统一安全状态机；显式 FSClient 挂载与自动挂载**均须**执行相同安全预检 |
| [`ntfs_device_fskit.m`](https://github.com/HuanchuanTech/xntfs/blob/main/ntfs3g/bridge/ntfs_device_fskit.m) | FSBlockDeviceResource 真实块设备 I/O、扇区对齐、局部写的 read-modify-write | 与现有只读 `BlockDeviceReader` 比较，独立验证边界、同步和故障语义，**不重写 NTFS 引擎** |
| [`ntfs3gVolume.swift`](https://github.com/HuanchuanTech/xntfs/blob/main/ntfs3g/ntfs3gVolume.swift) | FSVolume Operations、item/inode 身份、锁与生命周期 | 填补本项目 FSKit 函数覆盖缺口，保留已验证的卷级锁和句柄生命周期设计 |
| [`ntfs_fskit.h`](https://github.com/HuanchuanTech/xntfs/blob/main/ntfs3g/bridge/ntfs_fskit.h) | libntfs 的薄 C API，Swift/ObjC 不直接暴露 libntfs 类型 | 延伸现有 `CNTFSBridge`，避免平行引入第二套 NTFS 核心 |
| [macOS 27 验证记录](https://github.com/HuanchuanTech/xntfs/blob/main/docs/macos27-support.md) | `FSClient`/Disk Arbitration 操作、实际 `statfs` 只读/读写标志、镜像和附加分区持久性；挂载前后身份检查 | 转成独立可复现的本项目验收用例。记录明确**未针对这些新改动复测真实物理 USB** |
| [能力对齐与验证](https://github.com/HuanchuanTech/xntfs/blob/main/docs/fskit-feature-alignment.md) | 打开文件后 unlink/replace、预分配、稀疏查询、时间戳、标签/ADS、symlink、错误处理；某些版本仍有 allocation 显示缺口 | 作为行为/测试清单，逐项通过测试后才能声明兼容 |
| [控制层](https://github.com/HuanchuanTech/xntfs/blob/main/xntfs/Services/MountService.swift) | 应用只做查询/操作/诊断；自动挂载不依赖进程存活 | 管理 App 可选、无驻留；不要让 GUI 变成挂载的基础设施 |

**许可证约束**：`xntfs` 根目录附有 GPLv2 正文；不能仅凭这份正文认定每个实现文件都以 `GPL-2.0-or-later` 授权。NTFSDriver 自有代码使用 `GPL-3.0-or-later`；如果第三方文件仅 `GPL-2.0-only`，直接合并进 GPLv3 组合发行通常存在不兼容问题。**在逐文件确认权利与兼容性之前不复制 xntfs/NTFSKit 实现代码**；可使用公开 API、功能规格与独立编写的兼容性测试。需复用时先明确是否获得 GPL-2.0-or-later 或额外授权，并保留归属、许可证、修改来源。[xntfs LICENSE](https://github.com/HuanchuanTech/xntfs/blob/main/LICENSE)、[GNU 许可兼容说明](https://www.gnu.org/licenses/gpl-faq.html#AllCompatibility)。

## 工程边界与缺陷不能照抄

1. **原生身份比「目录可访问」重要**：必须由原始物理 `DADisk`/BSD 分区资源产生本地卷，保留合理的卷名、卷容量、UUID、Finder 可见性和标准退出。合成虚拟卷即使有 `MNT_LOCAL` 也不计入完成。
2. **安全不因成功挂载而自动成立**：对 dirty、Windows 休眠/Fast Startup、日志异常、元数据未知以及 I/O 故障分别明确判断；不自动执行 `RECOVER`、`ntfsfix`、清 dirty 或删除 `hiberfil.sys`。只读正常加载不等于可写许可。
3. **系统反馈必须和实际权限一致**：检查 `statfs(MNT_RDONLY)`、Foundation 卷读写属性、试写 `EROFS`、完整镜像哈希，不能只看 Swift 层布尔值。
4. **文件生命周期独立验收**：大文件、海量小文件、opened-unlinked、覆盖重命名、硬链接/符号链接、ADS/xattr/AppleDouble、原子替换、空间不足/断连/休眠唤醒，不能仅验证 create/read/write。
5. **评估资源局限**：部分 FSKit 回调与内核接口能力不同；对不支持操作明确失败而非伪装成功。xntfs 已记录 macOS 15 allocation 更新问题、macOS 27 部分 xattr 大小限制；本项目聚焦 27，仍应独立复测。
6. **签名与发布是前置可行性问题**：付费 Apple Developer 账号不是默认可指派给用户的事项；授权签名缺失时只能继续离线代码与模拟测试，不得以 ad hoc 打包、已签名第三方模块、降级安全策略、KEXT 或私有授权绕行谎称可安装。

## REA 在本轮调查中的作用和边界

本机经 RDC 发现 npm 缓存有 REA 6.4.0；未有全局 `rea` 命令，Ghidra provider 未配置（缺 `GHIDRA_INSTALL_DIR` 及相应工具链）。通过已缓存 CLI 对**现有本机、原厂未修改**的 macFUSE 5.4.0 `macfuse-local` Mach-O 做了静态 `inspect-macho`、`inspect-native-dispatch-metadata` 和 `trace-dylib-resolution`；对象 SHA-256 为 `41f526620f0ece172dad37b332ecc9f13ef98daa0e03c194d0daf57b55e08b98`。其中恢复了 `FSUnaryFileSystem` 的 `probeResource:replyHandler:`、`loadResource:options:replyHandler:` 等 ObjC 元数据；这只是静态结构证据，不能证明它支持真实 NTFS 设备身份，也不能替代实机测试。Paragon/Tuxera 可执行文件未在本机提供，未对其进行逆向。

**优先研究公开源代码，再在确有接口未知且合法授权时用 REA 定向验证二进制。** 逆向本身不能突破 Apple 的 FSKit 签名能力限制。

## 约束与验收记录

本轮仅调查公开代码、官网及已经存在的本机只读组件。没有购买软件、安装驱动、挂载或修改生产磁盘、启动受限扩展、调整 SIP/启动安全、复制受限代码，也没有为其他账号获取签名材料。

新的实施与验收分阶段计划见 [PLAN.md](PLAN.md)。
