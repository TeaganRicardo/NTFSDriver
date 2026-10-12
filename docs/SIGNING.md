# 无付费开发者团队的系统集成路线

核对日期：2026-10-12。项目维护者没有付费 Apple Developer 团队或 FSKit 配置文件，也不计划办理。这是后续计划的约束，不将购买账号作为默认前置步骤。

## 已确认的限制

Apple 的 macOS capabilities 表在 FSKit Module 一行标记 Apple Developer Program 和 Developer ID 支持，免费 Apple Developer 一栏为空。页面中的勾选图标不出现在部分纯文本提取结果里；本次同时核对了 HTML 表格中两项 yes 与第三项空单元格。[Apple 能力表](https://developer.apple.com/help/account/reference/supported-capabilities-macos/)

自己实现的 FSKit 扩展声明 `com.apple.developer.fskit.fsmodule`。声明 entitlement、生成 ad hoc 签名、`codesign --verify` 通过，是工程构建证据；这些结果不能证明系统已授权运行扩展。[Apple FSKit entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.fskit.fsmodule)

当前未找到匹配本项目 Bundle ID 的配置文件，本机无 Developer ID 发行身份。仅有 Apple Development 身份不能证明它对应可使用 FSKit 的团队。

本机最小启动验证已经确认 ad hoc 包受到限制：在 macOS 27.0.1 / arm64，直接执行冻结提交 `e2863d4af117facb399466090e5c1174f2ee1b9d` 预览包中的 NTFSModule，进程返回 SIGKILL（-9）。AMFI 日志给出 AppleMobileFileIntegrityError Code=-424：`The file is adhoc signed but contains restricted entitlements`，同时记录代码签名验证失败和系统策略不允许启动。该包声明 app-sandbox 与 fskit.fsmodule，没有配置文件。`codesign --verify --strict --deep` 在启动前通过，却不能替代运行授权。

本次没有注册扩展、传入磁盘资源或进行 NTFS 挂载。结果证明当前 ad hoc 可执行文件不能启动，不代替持有效配置文件的扩展或已有签名组件的系统加载测试。

这直接影响自己的扩展加载、系统仲裁、Finder/磁盘工具本地卷、自动挂载、推出、重启恢复，以及 Developer ID 公证发行验收。它不影响 Swift/C 开发、源码公开、普通文件镜像读取、引擎适配、测试或离线读写研究。正常使用已签名软件的最终用户不需要购买开发者账号；此限制作用于扩展开发和发布方。

## 可继续调查的路线

| 路线 | 对本项目的意义 | 尚需确认 |
| --- | --- | --- |
| 复用 macFUSE 已签名的 FSKit 后端 | 通过官方提供的用户空间后端接入本地卷；不需要维护者自己签 FSKit 模块 | 目标系统加载、只读门禁、本地卷身份、自动识别、性能与许可；目前没有完成这些验收 |
| 由已有团队的开源维护者构建并发布本项目扩展 | 可保留自己的 FSKit 适配和开源代码，维护者本人不需购买团队 | 必须有实际愿意维护签名、配置文件和发行的发布方；当前没有这类安排 |
| 保留离线工具 | 当前可实际开发和验证的功能；共享 NTFS 引擎仍可用于将来的原生方案 | 不满足 PRD 的 Finder 自动本地卷体验，不能作为产品已完成的证据 |

macFUSE 默认后端使用 KEXT，必须显式选用 `backend=fskit` 才是本项目可考虑的模式。官方说明 FSKit 后端无需 KEXT 或调整启动安全设置，发布版本已签名、公证。这条路线与 FUSE-T 的网络共享挂载不同，值得单独验证。[官方后端说明](https://github.com/macfuse/macfuse/wiki/FUSE-Backends)、[安装与安全说明](https://github.com/macfuse/macfuse/wiki/Getting-Started)

截至核对时，macFUSE 最新发行版为 5.4.0。其公开 issue #1192 仍开放，报告包含 macOS 27.0 正式版中已注册模块未被 FSKit 枚举的情况；后续也有 macOS 26.7.1 用户报告恢复。这些是具体环境的故障与恢复报告，不能推断本机 27.0.1 必然成功或失败。[5.4.0 发行](https://github.com/macfuse/macfuse/releases/tag/macfuse-5.4.0)、[issue #1192 与讨论](https://github.com/macfuse/macfuse/issues/1192)

本机还下载并核对了官方 5.4.0 DMG，SHA-256 为 `861814f0ac7fa8f6547ea40cdd49a36ac84bcc7d34f38a1fa74e8cf68b0401c5`，与发行清单相符。仅只读打开 DMG 并将 pkg 展开至临时目录，没有执行安装脚本或注册组件。`macfuse-local.appex` 通过 strict 签名检查，带 Developer ID 身份；其内嵌配置文件明确授权 FSKit Module，并匹配该发布方的模块 Bundle ID。这证明候选包具备我们当前缺少的签名材料，不证明它已经在本机加载或满足本地卷需求。该配置文件不能移用于本项目的 Bundle ID。检查后已推出安装介质。

官方还列出 FSKit 后端的打开模式、通知 API、挂载选项和性能限制。macFUSE 有部分非开源组件，不能因为用户态 FUSE 库开源，就将整体视为完全开源依赖；最终复用和分发许可需核对。[后端限制](https://github.com/macfuse/macfuse/wiki/FUSE-Backends)、[开源状态](https://github.com/macfuse/macfuse/wiki/Open-Source-Status)

## 当前执行决定

完成并审查 M2 的离线只读引擎、镜像回归与可编译扩展原型；保持原生挂载验收未完成。下一次系统集成工作先验证可复用的签名组件及其许可，不继续把自己的发行签名视为已具备的条件。若没有符合 PRD 的可用接入路线，应明确报告这一产品阻碍，再决定是否调整产品目标。

所有路线继续遵守 SIP、Full Security、不安装第三方 KEXT和本地卷要求。关闭安全设置或将盘模拟为网络共享不会解决本项目的验收门槛。
