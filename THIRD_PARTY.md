# 第三方代码与许可证

项目自有代码采用 GPL-3.0-or-later；完整许可证见 [LICENSE](LICENSE)。第三方代码保留各文件原有版权与许可证声明。

## NTFS-3G

- 上游：[Tuxera NTFS-3G](https://github.com/tuxera/ntfs-3g)。
- 版本：2026.9.28。
- 固定提交：`7f0f841fc52cf719106c5c93bafe465004e36816`。
- vendored 范围：`libntfs-3g` 源码、NTFS 头文件和版权／许可证文件，不包含 FUSE 驱动或 FUSE 运行时。
- 库许可证：GPL-2.0-or-later。`COPYING.LIB` 属于上游 fuse-lite，保留原始分发信息，不表示 NTFS 库采用 LGPL。
- 来源归档与逐文件 SHA-256：`Vendor/NTFS3G/UPSTREAM.json`。

上游源文件保持原样。`include/ntfs-3g/config.h` 是在 macOS 27.0.1 / arm64 上生成的本地构建配置，关闭 FUSE、crypto、nfconv 与动态库；`EngineShim.h` 和 `module.modulemap` 是本项目的 SwiftPM 接入文件。该配置仅验证了当前目标环境。

配置生成参数：`--disable-ntfs-3g --disable-mount-helper --disable-crypto --disable-nfconv --disable-shared --enable-static`。产品通过自定义设备回调使用该库，始终采用 READONLY 与 FORENSIC，不使用默认设备打开或恢复路径。

## 测试镜像来源

测试用 `mkntfs`、`ntfscp` 从相同固定提交在临时目录构建，不随宿主 app 或文件系统扩展分发。工具中的 `mkntfs.c`、`ntfscp.c` 为 GPL-2.0-or-later；`mkntfs` 链接的 `boot.c` 为 GPL-3.0-or-later。生成的可丢弃测试镜像包含该 boot code，项目保存 GPL v3 许可证，并记录镜像创建步骤与测试数据来源。

发布前仍需核对最终源码／二进制组成、版权与许可证清单、对应源码和构建说明。开发构建成功不代表已完成正式发行的许可证与签名验收。

## macFUSE 实验的外部组件

`Experiments/macFUSE/ReadOnly.c` 通过外部用户态 FUSE 2 库与 MFMount.framework 接入 macFUSE 5.4.0 的已签名 FSKit 模块。这些库、头文件、app 和二进制模块没有加入仓库，也没有随本项目发布。构建与个人使用实验从核对过的官方包读取组件，保留其原有版权和许可。

FUSE 用户态库和 MFMount.h 的 LGPL 说明不代表整个 macFUSE 产品都开源；官方产品有部分非开源组件，发行许可另有非商业捆绑等限制。此处不将实验连接成功视为正式依赖分发许可已经通过。来源与运行边界见 [macFUSE 实验](docs/MACFUSE_EXPERIMENT.md)、[官方开源状态与许可入口](https://github.com/macfuse/macfuse/wiki/Open-Source-Status)。
