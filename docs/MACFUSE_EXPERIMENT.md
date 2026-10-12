# macFUSE 已签名 FSKit 后端实验

日期：2026-10-12。目标：在维护者没有付费开发者团队的情况下，用公开 FUSE API 接入已有签名的 FSKit 模块，验证只读数据路径和原生集成边界。环境为 macOS 27.0.1 / arm64、macFUSE 5.4.0。

## 结论

**签名授权路线已经跑通，完整产品集成尚未通过。** 普通、没有 FSKit entitlement 的本项目 C 程序，能够通过 macFUSE 用户态 FUSE 库连接该发布方的已签名本地 FSKit 模块；测试镜像以 `/Volumes` 下的本地 `fskit` 挂载提供文件访问。三个文件哈希、EOF、拒写、引擎关闭和整镜像不变性通过。

当前后端用一个 4 KiB 的合成磁盘节点代表这个文件系统。磁盘工具没有识别其文件系统卷，Foundation 的 `volumeIsReadOnly` 也返回 false，尽管实际写入返回 EROFS。`diskutil unmount` 失败，标准 `umount` 成功。另一个只读实验给出实际附加 NTFS 镜像设备的 `fsname`，仍生成合成节点，没有把挂载绑定到那个原始 NTFS 卷；macOS 用户态库还拒绝 Linux 风格的 `blkdev` 选项。不能据此计为 P0-04、自动识别、系统仲裁或 Finder/磁盘工具正常推出验收完成。

签名本身可以复用，但签名复用不补齐设备身份、系统元数据或数据安全。正式路线仍需解决这些集成缺口及依赖许可，不能直接发布本原型为日常驱动。

## 实际部署与授权

官方 5.4.0 DMG SHA-256：`861814f0ac7fa8f6547ea40cdd49a36ac84bcc7d34f38a1fa74e8cf68b0401c5`。本机保存的用户空间 SDK 根目录为 `/Users/gao/Applications/NTFSDriver Dependencies/macFUSE-5.4.0`，仅包含宿主、原始 FSKit 模块、MFMount.framework、用户态 libfuse/头文件、必要元数据与许可文件。SDK 内没有 `.kext`。

宿主 app 位于 `Library/Filesystems/macfuse.fs/Contents/Resources/macfuse.app`，app、两个 `.appex` 与签名／配置文件均保持上游字节。MFMount.framework 与 libfuse.2.dylib 的 strict 签名检查通过。没有修改或重新签名发布方扩展。没有运行完整官方 pkg 安装器，因为其 payload 同时带传统 KEXT。

通过本机 LaunchServices 单 app 注册和官方 `macfuse install --components file-system-extensions` 登记。挂载需要的原始已签名用户空间 daemon 由官方组件安装流程部署到 `/Library/PrivilegedHelperTools/io.macfuse.app.launchservice.daemon`，对应 launch daemon 使用发布方的 mach service；用户已确认这些模块与辅助进程的授权。没有调用 kernel-extension 子命令，没有调整 SIP 或启动安全。SIP 查询仍为 enabled；本轮未独立核验机器此前的 Full Security 状态。

临时解包 app 与稳定 app 一度产生重复登记，随后只撤销本实验的旧 app 路径并重新登记稳定路径；没有重置整个 LaunchServices、PluginKit 或 FSKit 数据库。两个扩展的稳定登记均指向上述 SDK，用户启用状态保留。

## 开关点击无效的原因与处理

在系统设置 → 通用 → 登录项与扩展 → **按应用** 中，macFUSE 开关无法开启。维护者确认该路径使用 Apple 的 LoginItems-Settings 组件，可能因缺少 FSKit 所需的私有连接授权被拒绝；**按类别** 使用另一个 Apple 组件，维护者建议优先采用这条系统界面路径。[维护者的诊断与建议](https://github.com/macfuse/macfuse/issues/1194)

本机通过 **按类别 → 文件系统扩展** 将 macFUSE (local) 和 macFUSE 两个开关成功置为 on，系统保存的启用列表也包含两项。随后日志明确记录本地模块进程启动、发现服务端、建立 channel 和连接成功。没有直接写内部 enabledModules.plist，没有重启全局 fskitd，也没有用 PluginKit 的选择标记替代 FSKit 实际授权。

普通 ad hoc 状态工具的 `FSClient.installedExtensions` 仍仅返回四个 Apple 模块；不能把该工具的结果用作“macFUSE 没有被加载”的结论。实际已签名 helper/模块的加载日志与成功文件访问提供了更强的运行证据。这里不把诊断工具为何看不到第三方模块的猜测当作已确认的 API 规则。

## 只读原型

源码为 `Experiments/macFUSE/ReadOnly.c`。它复用已有 `CNTFSBridge` 与固定 NTFS-3G；普通文件仍由 O_RDONLY / O_NOFOLLOW 打开，设备写回调拒绝。FUSE 回调只实现查找、属性、枚举、打开、读取与空间统计，修改入口拒绝，单线程 loop 保持引擎串行访问。发现底层拒写计数后拒绝后续读取；明确关闭消费句柄并报告错误。

macFUSE 官方说明 FSKit 后端即使读取也以读写模式打开文件，因此 FUSE 文件层允许其强制的 O_RDWR；这没有改变磁盘 I/O 的只读打开和拒写回调。O_WRONLY、创建、截断、追加请求拒绝。挂载固定选择 `backend=fskit`，没有 KEXT 后端回退或任意用户挂载选项。[后端限制](https://github.com/macfuse/macfuse/wiki/FUSE-Backends)

原型仅接受普通文件镜像，要求挂载路径使用 `/Volumes/NTFSDriverReadOnlyTest-` 前缀且尚不存在。该程序是开发实验，不提供安装器、自动挂载或生产磁盘操作。当前不保留失败的设备绑定参数；需要新的、已验证的公开接入方式后再实现。

FUSE 读取以已知文件大小确定 EOF，并按最多 1 MiB 的引擎请求循环填满上层读取。中途短读继续，提前空读或后续错误返回错误；不能把上游正数短读当成 EOF，否则 FUSE 会把剩余部分补零。`scripts/check.sh` 同时验证超 1 MiB 请求、连续短读、中途 I/O 错误、提前空读、真实 EOF 和返回值边界。

## 重现步骤

先从官方包获取上述用户空间组件，验证官方归档和原始签名，并使用系统设置的按类别入口启用。完整包静态核验与限制见 [SIGNING.md](SIGNING.md)，候选比较见 [ALTERNATIVES.md](ALTERNATIVES.md)。组件安装／系统授权不是下面构建脚本的隐式动作。

提交源码后构建实验程序：

```sh
./scripts/build-fuse-preview.sh '/Users/gao/Applications/NTFSDriver Dependencies/macFUSE-5.4.0'
```

脚本核验引擎来源和两项用户态库签名，在临时目录构建 Release C 对象与客户端，记录 SourceCommit.txt。库不随仓库 vendoring，也没有上传 linked binary；最终依赖分发许可尚未验收。

仅从保存的 fixture 解压到新建临时普通文件，核对 manifest 中的整镜像 SHA-256。使用新的测试挂载名称运行；以下 binary/image 路径需替换成实际构建与解压结果：

```sh
MACFUSE_SDK='/Users/gao/Applications/NTFSDriver Dependencies/macFUSE-5.4.0'
DYLD_LIBRARY_PATH="$MACFUSE_SDK/usr/local/lib" \
DYLD_FRAMEWORK_PATH="$MACFUSE_SDK/Library/Filesystems/macfuse.fs/Contents/Frameworks" \
  /tmp/actual-build/ntfs-fuse-readonly /tmp/actual-fixture/test.ntfs \
  /Volumes/NTFSDriverReadOnlyTest-unique
```

DYLD 路径用于本项目普通开发程序加载未经修改的用户态库，不修改已签名扩展。libfuse/MFMount 的绝对 install name 指向系统标准安装目录，临时 SDK 没有往该目录部署整包。若需要常规发行，应另行设计并验证标准的依赖安装与链接流程。

## 本机证据

| 检查 | 观察 |
| --- | --- |
| `/sbin/mount` | `macfuse, local, ... fskit, mounted by gao`，路径在 `/Volumes` |
| Foundation 卷属性 | `volumeIsLocal = true`，`volumeIsReadOnly = false`，格式描述 Unknown (macfuse) |
| 文件 | Alpha.bin 2097408 字节、中文🦊.txt 54 字节、empty.txt 0 字节；三项 SHA-256 与 manifest 一致 |
| EOF | 三项在文件末尾之后 pread 32 字节均返回 0 |
| 修改拒绝 | 创建、写入、mkdir、rename、unlink 均返回 EROFS（30） |
| 源镜像 | 操作及关闭后均为 `b2d5146341cfe073465f324249e10cb788f424b8e04124ce7f0458da0aed4224` |
| 关闭 | 引擎显式 close = 0，deniedBackendWrites = 0；该计数不包括 FUSE 层已拒绝的修改请求 |
| 磁盘工具 | 合成节点 4096 字节、File System None，未呈现正常 NTFS 文件系统卷 |
| 推出路径 | diskutil unmount 失败；umount 成功，客户端退出 0；测试附加镜像正常推出 |

一次没有处理 FUSE 请求的原始 MFMount 探针建立连接后没有完成关闭，在有界超时后终止；其待挂载子进程终止后，专用 4 KiB 虚拟设备需要强制推出。后续有完整 FUSE loop 的客户端正常关闭。此记录不能外推为已有生产卷故障，也说明通道建立不等于完整文件系统生命周期通过。

Finder UI 验收仍待完成：本轮电脑操作工具报告用户正在使用 Finder，未继续抢占操作；标准文件 API 的读取成功不能替代 Finder 侧栏与正常推出证据。没有对生产盘文件执行读写、卸载、修复或格式化。

下一步仍需明确真实设备资源与 Disk Arbitration 的公开绑定方式、正确的只读卷属性、Finder/磁盘工具集成和推出；同时评估组件许可。已有签名的固定 NTFS 驱动也要按实际包验证，不能修改其代码后继续依赖原签名。
