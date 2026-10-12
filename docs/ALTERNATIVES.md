# 无自有付费开发者团队的 NTFS 本地卷候选

核对日期：2026-10-12。目标环境：Apple Silicon / macOS 27.0.1。维护者不办理付费 Apple Developer 账号；保持免费开源、SIP 与 Full Security、不使用第三方 KEXT、本地 `/Volumes` 卷和默认保护数据的要求。

本调查只读取官方文档、维护者源码、官方发行页面与 App Store 商品页面。没有安装、注册或启用候选扩展，没有购买应用，没有挂载真实磁盘，也没有联系外部维护者。macFUSE 的实际运行实验单独记录，以下表格不将静态研究计为挂载通过。

## 2026-10-12 原生体验方向修订

以 [原生体验基准](NATIVE_EXPERIENCE_REFERENCE.md) 与 [实施计划](PLAN.md) 为准：**xntfs direct FSKit + libntfs-3g 是技术主标杆；Paragon 18 是用户体验标杆。** 这里的“主标杆”是公开源码/API 的复用与技术验证优先级，并**不**表示签名可直接复用、许可证已允许复制、成品性能优于商业软件，或物理 USB 自动挂载已通过本项目实测。

此前在没有自有签名身份的条件下优先尝试 macFUSE 已签名 FSKit 通道。该实验确实证明模块能加载，并能把只读镜像放在 `/Volumes` 供普通文件访问；但返回的是合成虚拟 DADisk，系统只读属性、真实 NTFS 设备身份及标准退出没有通过，公开 5.4.0 接口也未提供经核实的物理卷绑定方式。**不继续把 macFUSE 虚拟盘包装成“原生 NTFS 卷”来开发。** 保留实验作为证据和候选发布新接口时的回归用例。

xntfs 的公开源代码已展示直接 `FSBlockDeviceResource` / `FSMediaTypes` / 系统 Disk Arbitration 路线，也有发行渠道及维护者 macOS 27 测试。但这并未解决 NTFSDriver 自有 `com.apple.developer.fskit.fsmodule` 的授权签名；缺乏真正发布方仍然阻断实机执行。xntfs App Store 发行包收费，不能当作本项目免费、可修改的 signed SDK。已有源码是否可直接复制还受 **GPL-2.0-only 与本项目 GPL-3.0-or-later 的兼容性**限制，逐文件确认前只作行为/架构参照。

| 候选 | 价值 | 当前判断 |
| --- | --- | --- |
| HuanchuanTech/xntfs | 可审查的系统自动挂载、真实物理卷 FSKit 适配与 libntfs-3g 薄桥 | **主工程参考**；需另解签名、授权和 GPL 兼容 |
| Paragon NTFS 18 | macOS 27 商业成熟 UX | **主体验基准**；其公开 KEXT / Reduced Security 路线不可采用 |
| Tuxera NTFS for Mac 2027 | 商业完整版 NTFS 驱动与跨平台兼容参考 | 借鉴验收，不采用 KEXT；仅继续复用其开源 ntfs-3g 引擎 |
| whereteam/NTFSKit | FSKit 内部结构、ADS、索引、读写处理示例 | 可交叉审阅，但默认 RECOVER、dirty 修复与当前政策冲突 |
| macFUSE 5.4.0 FSKit | 不具自有签名时已经跑通的已签名用户空间通道 | **正式路线暂停**；除非未来公开、可分发签名版本解决真实物理磁盘身份、只读及正常推出 |
| 其他具有效签名的发行主体 | 最可能解决独立扩展的合法签名门禁 | **G0**；未有实际合作，不能列为已交付 |

以上修订不抹去下文此前对各候选的静态审查及日期。下文描述的当时获取条件、测试范围与源码限制仍应作为历史证据阅读。

## xntfs：有发行渠道，安全实现仍需按实际包验证

本次源码冻结在 `a51ff493281e363e999903b34026daaa6a8d577f`；`v1.0.9` 标签指向同一提交。GitHub releases API 返回空列表，但仓库 README 指向真实 App Store 页面。直接读取英国官方页面 HTML，版本历史的 `datetime` 为 **2026-10-09**、版本 **1.0.9**，结构化商品信息为 **GBP 0.99**。网页抓取缓存中的 1.0.2 不能作为当前版本。商店页面证明发行渠道和标价，不证明本机已验证其签名、配置文件、源码对应哈希或运行状态。[固定版本 README](https://github.com/HuanchuanTech/xntfs/blob/a51ff493281e363e999903b34026daaa6a8d577f/README.md)、[固定标签](https://github.com/HuanchuanTech/xntfs/tree/v1.0.9)、[官方英国商品页面](https://apps.apple.com/gb/app/xntfs/id6782636021?mt=12)、[GitHub releases API](https://api.github.com/repos/HuanchuanTech/xntfs/releases)

源码为 app + FSKit extension，使用 NTFS-3G；`FSMediaTypes` 匹配 Windows_NTFS、Microsoft Basic Data 与无分区介质，声明块资源和路径资源，关闭 server URL 资源，没有 SMB/NFS 接入。自动挂载由系统仲裁处理，宿主用于管理。仓库根 `LICENSE` 是 GNU GPLv2 正文，未见完整 UI 专有许可拆分；若移植代码，仍需逐文件和引擎许可核对。[Info.plist](https://github.com/HuanchuanTech/xntfs/blob/a51ff493281e363e999903b34026daaa6a8d577f/ntfs3g/Info.plist)、[LICENSE](https://github.com/HuanchuanTech/xntfs/blob/a51ff493281e363e999903b34026daaa6a8d577f/LICENSE)

源码中的保护机制如下：

- 探测与 quick preflight 使用 `NTFS_MNT_RDONLY | NTFS_MNT_FORENSIC`；preflight 明确检查 dirty/chkdsk flag、休眠与日志状态。没有在该路径执行日志恢复或清 dirty。
- `startCheck` 只接受 quick check；完整检查和修复返回 `ENOTSUP`，提示使用 Windows 检查。
- 普通 mount 使用 `NTFS_MNT_MAY_RDONLY`，显式只读时加 `NTFS_MNT_RDONLY`，没有 `RECOVER` 或忽略休眠参数。底层写回调检查 backend 的 `writable`，只读返回 `EROFS`。
- load 先用只读 backend 读取；activate 才根据挂载选项换成允许写入的 backend。宿主默认物理设备可写、镜像只读；默认设置不是对所有介质安全性的证据。

这些是静态源码事实，不是本项目测试结果。[C mount/probe/preflight](https://github.com/HuanchuanTech/xntfs/blob/a51ff493281e363e999903b34026daaa6a8d577f/ntfs3g/bridge/ntfs_fskit.c#L480)、[维护操作](https://github.com/HuanchuanTech/xntfs/blob/a51ff493281e363e999903b34026daaa6a8d577f/ntfs3g/ntfs3gFileSystem.swift#L243)、[底层写门禁](https://github.com/HuanchuanTech/xntfs/blob/a51ff493281e363e999903b34026daaa6a8d577f/ntfs3g/bridge/ntfs_device_fskit.m#L193)、[只读决策与 load](https://github.com/HuanchuanTech/xntfs/blob/a51ff493281e363e999903b34026daaa6a8d577f/ntfs3g/ntfs3gFileSystem.swift#L33)

**仍有必须验证的门槛：** dirty gate 位于 `startCheck(-q)` 调用的 `quickCheck`；activate 转成可写 backend 时自身没有再调用 quick preflight。仅有 `MAY_RDONLY` 不能替代 dirty flag 检查：固定 NTFS-3G 引擎的普通 mount 路径检查休眠和日志，但不在该处拒绝 dirty flag 本身。因此，需要用可丢弃 dirty 镜像验证直接 FSClient/显式挂载是否也经过门禁，不能宣称所有接入路径均符合 P0-10。[activate](https://github.com/HuanchuanTech/xntfs/blob/a51ff493281e363e999903b34026daaa6a8d577f/ntfs3g/ntfs3gVolume.swift#L220)、[上游 mount 实现](https://github.com/tuxera/ntfs-3g/blob/7f0f841fc52cf719106c5c93bafe465004e36816/libntfs-3g/volume.c#L1283)

维护者的 macOS 27 实测记录中，dirty 镜像 quick check 失败后系统尝试 repair，收到 `ENOTSUP`，没有可写挂载；`diskutil mount readOnly` 在该场景也失败，直接指定 FSKit 类型只读挂载则成功。文档明确说这不是自动只读降级的证明。需要将这些第三方记录与我们的目标机实测区分。[维护者固定版本验证记录](https://github.com/HuanchuanTech/xntfs/blob/a51ff493281e363e999903b34026daaa6a8d577f/docs/fskit-feature-alignment.md#L100)

即使取得已签名 xntfs，也只能执行其现有逻辑。修改扩展、移植我们的拒写策略或更换模块身份会需要重新签名和授权；它不像 macFUSE 的公开 FUSE 接口那样提供已证实的通用文件系统接入边界。这是根据其固定 NTFS 引擎架构作出的判断，仍未测试外部进程调用能力。[架构 README](https://github.com/HuanchuanTech/xntfs/blob/a51ff493281e363e999903b34026daaa6a8d577f/README.md#L14)

## NTFSKit：开源驱动不等于已有免费签名包

源码冻结在 `b7153a8dd51b895d0a87345c6ad8e95bda963ed3`。官方 repo 没有 GitHub release；官方 Pro 页面当前只有邮件预约，写明尚在公证审查、发售后发送下载链接，没有公开 DMG/PKG 下载地址。没有发送预约邮件。本次因此没有得到可以验证签名、entitlement 或实际卷行为的发行包；不能把 README 中的自动读写说明计为已存在的可复用签名包。[GitHub releases API](https://api.github.com/repos/whereteam/ntfskit/releases)、[官方销售页面](https://whereteam.com/ntfskit/buy)

根 `LICENSE` 将 `NTFSModule/` 和 `fsbundle/` 列为 GPLv2，将完整 `App/` UI 列为专有。实际公开树中还有 `App-OSS/NTFSKitApp.swift`，该最小 host 标注 GPL-2.0-or-later，注释说明完整 Pro app 在另一个仓库。不能笼统称整个产品全开源或 UI 全闭源。其 `bridge/mkntfs/boot.c` 标注 GPLv3-or-later，与根许可概述的 GPLv2 wording 需要逐文件澄清，当前不复制代码。[许可概述](https://github.com/whereteam/ntfskit/blob/b7153a8dd51b895d0a87345c6ad8e95bda963ed3/LICENSE)、[最小 host](https://github.com/whereteam/ntfskit/blob/b7153a8dd51b895d0a87345c6ad8e95bda963ed3/App-OSS/NTFSKitApp.swift#L1)、[boot.c](https://github.com/whereteam/ntfskit/blob/b7153a8dd51b895d0a87345c6ad8e95bda963ed3/NTFSModule/bridge/mkntfs/boot.c#L13)

普通可写 `nk_mount_io`/`nk_mount` 直接传 `NTFS_MNT_RECOVER`。`nk_fsck` 修复模式也使用 RECOVER，并在 dirty 时显式执行 `ntfs_volume_write_flags(... & ~VOLUME_IS_DIRTY)`。Swift `startCheck` 把没有 `-n` 且资源可写的检查视为 repair；因此系统维护调用可能进入修复路径。这与本项目“不自动修复、不擅自清 dirty、状态不明确拒写”冲突。[bridge mount](https://github.com/whereteam/ntfskit/blob/b7153a8dd51b895d0a87345c6ad8e95bda963ed3/NTFSModule/bridge/ntfs_bridge.c#L125)、[bridge fsck](https://github.com/whereteam/ntfskit/blob/b7153a8dd51b895d0a87345c6ad8e95bda963ed3/NTFSModule/bridge/ntfs_bridge.c#L762)、[系统检查调用](https://github.com/whereteam/ntfskit/blob/b7153a8dd51b895d0a87345c6ad8e95bda963ed3/NTFSModule/NTFSFileSystem.swift#L201)

不能照搬其注释中“journal replay”的保证：构建脚本指定 NTFS-3G `2026.7.7`，固定上游源码的 RECOVER 分支实际可调用 `ntfs_logfile_reset`，将日志内容填为 `0xff` 标为空；这不是完整事务日志回放验证。没有静态找到自动删除休眠文件的路径，但这个有限检查不足以证明所有异常卷数据安全。[引擎构建脚本](https://github.com/whereteam/ntfskit/blob/b7153a8dd51b895d0a87345c6ad8e95bda963ed3/scripts/fetch-deps.sh#L6)、[固定上游 RECOVER 路径](https://github.com/tuxera/ntfs-3g/blob/d327833ec1d5eb1358b6f2c37139f10a3460944d/libntfs-3g/volume.c#L1283)、[日志 reset 定义](https://github.com/tuxera/ntfs-3g/blob/d327833ec1d5eb1358b6f2c37139f10a3460944d/libntfs-3g/volume.c#L1675)

## 为什么个人使用也受到签名限制

限制针对**运行的扩展具有什么系统能力**。FSKit 扩展声明 `com.apple.developer.fskit.fsmodule`，系统会验证受保护 entitlement；普通 ad hoc 签名只能证明当前文件的签名结构，不能自行授权这个能力。配置文件把 app identity、证书和被允许的能力绑定起来。我们的 ad hoc 原型被 AMFI 拒绝的本机证据见 [SIGNING.md](SIGNING.md)。[FSKit entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.fskit.fsmodule)、[Apple macOS 签名安全说明](https://support.apple.com/en-ca/guide/security/sec3ad8e6e53/web)、[配置文件的授权作用](https://developer.apple.com/help/account/provisioning-profiles/provisioning-profile-updates)

“为什么必须属于付费团队”是 Apple 当前能力开放政策：官方 macOS capabilities 表中，FSKit Module 在 ADP 和 Developer ID 列有勾，免费 Apple Developer 列为空。本次读取 HTML 核对了图标，未把纯文本提取丢失勾选误读为三栏相同。Personal Team 能测试一部分个人设备 app，但并不包含所有 advanced capabilities。[Apple 能力表](https://developer.apple.com/help/account/reference/supported-capabilities-macos/)、[Personal Team 与高级能力](https://developer.apple.com/help/account/basics/about-your-developer-account/)

系统不会因软件“只给本人使用”就跳过这个权限验证；开发构建也仍是一个请求 FSKit 能力的扩展。**用户本人不必付费，也不必所有参与开发的人各买会员**：复用合法已签名扩展时，由原发布方的团队提供其授权；或由实际已有团队签我们的扩展。修改原组件后不能继续把原签名作为修改版的授权。Apple 文档支持权限验证机制和当前 membership 边界，但没有解释为什么收费是该安全机制的必要条件；这里不推测 Apple 的商业动机。[签名完整性](https://support.apple.com/en-ca/guide/security/sec3ad8e6e53/web)、[签名团队资源与加入团队](https://developer.apple.com/help/account/basics/about-your-developer-account/)

## 下一步验收门槛

1. 完成 macFUSE 已签名 FSKit 后端在本机的注册、用户启用与实际进程加载验证；记录全路径、版本和签名，确认只走 FSKit 后端。
2. 将本项目只读逻辑通过公开 FUSE API 接入，先只接受可丢弃镜像。测试底层拒写、镜像整体哈希不变、MNT_LOCAL/MNT_RDONLY、`/Volumes`、Finder/磁盘工具识别与标准文件 API。
3. 单独验证自动识别、系统仲裁与推出；不能用常驻抢挂载脚本、修改系统文件或反复管理员授权弥补失败。
4. 在免费安装和依赖分发许可满足后再决定正式架构。xntfs 的付费现成 app 可以说明“普通用户无需开发者账号”，不能自动满足本项目免费产品目标；不在未获购买指令时下单。
5. 没有通过只读原生验收前，不开放写入。dirty、休眠、日志未知、底层 I/O 失败都需要独立门禁和可丢弃介质测试；现成签名不会替代数据安全验证。

SMB/NFS、FUSE-T 网络共享、修改隐藏 NTFS 写入开关、第三方 KEXT、安全等级降级、自动 `remove_hiberfile` 与抢挂载守护进程不作为正式替代路线。没有候选通过时保持 M2 原生验收待完成，准确报告阻碍，不将离线读取或来源研究计为产品达标。
