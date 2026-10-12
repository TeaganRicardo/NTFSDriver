# M2 只读引擎接入审查

日期：2026-10-12。范围是固定上游源码与本项目只读桥接，不是完整 NTFS 正确性审计，也不构成写入或实际挂载验收。

## 来源与构建

选择 Tuxera NTFS-3G 2026.9.28，提交 `7f0f841fc52cf719106c5c93bafe465004e36816`。保存 75 个未修改的上游源文件、头文件与许可文件，归档来源与逐文件 SHA-256 见 `Vendor/NTFS3G/UPSTREAM.json`。`scripts/verify-vendor.py` 验证哈希及完整文件清单，构建检查会执行它。[上游固定提交](https://github.com/tuxera/ntfs-3g/tree/7f0f841fc52cf719106c5c93bafe465004e36816)

上游 Tuxera 归档下载遇到 TLS 连接失败后，使用同一固定提交的 GitHub codeload；没有关闭证书验证。GitHub 归档与 Tuxera 发布归档的哈希不同，不将两者混为同一个包。

本地 `config.h` 来自 macOS 27.0.1 / arm64 的 configure 输出，关闭 FUSE 驱动、mount helper、crypto、nfconv 和动态库。原始 `unix_io.c` 随库保留，但产品不调用默认 `ntfs_mount` 打开设备；入口仅为自定义设备 `ntfs_device_mount`。构建仍会产生上游 C 转换与 packed-member 等警告；当前编译成功不代表这些代码经过本项目全量审计。

## 写入和恢复边界

桥接始终使用 `NTFS_MNT_RDONLY | NTFS_MNT_FORENSIC`。不启用 RECOVER，不清日志，不清 Dirty Flag，不删除休眠文件，不自动修复。[上游挂载实现](https://github.com/tuxera/ntfs-3g/blob/7f0f841fc52cf719106c5c93bafe465004e36816/libntfs-3g/volume.c)

自定义设备只暴露读取能力。打开时拒绝任何写入访问模式及创建、截断、追加标记；`write` 与 `pwrite` 一律返回 EROFS。普通文件镜像的底层文件描述符仅 O_RDONLY；FSKit 资源适配仅调用读取 API。上层 FSKit 创建、修改、删除、重命名及链接入口在到达引擎前返回 EROFS。

`deniedBackendWrites` 只统计到达设备桥接的写请求与写模式打开。引擎自身在更上层拒绝的写操作不计入这个数值。因此零计数不是“所有引擎函数均无写意图”的证明；它结合只读底层、输入前后哈希与无恢复配置用于验证当前只读路径。计数一旦非零，后续正常访问拒绝，显式关闭也报告错误。[引擎读写保护](https://github.com/tuxera/ntfs-3g/blob/7f0f841fc52cf719106c5c93bafe465004e36816/libntfs-3g/device.c)

上游 READONLY / FORENSIC 路径跳过可写打开时的日志与 Windows 休眠检查。读取成功不能证明卷健康或可写。报告中 Dirty Flag 来源已知，`volumeHealth = unknown`、`hibernationState = notChecked`、`writeAccess = denied`；M3 必须另行实现和验证写入门禁。

## 生命周期、错误和名称

固定版本 `ntfs_umount` 的实现会在失败时也释放卷与设备，不能依赖其旧注释“失败后仍可重试”。Swift 在调用前清空句柄，关闭错误不会导致二次释放。设备 context 保持至同步关闭完成，跨 C/Swift 缓冲区仅在其有效作用域内使用。

每个卷的所有引擎访问与关闭由锁串行化；多卷分别拥有独立设备和句柄。FSKit 的加载、活动状态、item 缓存、回收与卸载使用同一锁与代际标识，卸载后原 item 失效。此设计及离线并发测试不替代 FSKit 守护进程、休眠或热拔盘验收。

设备读取检查偏移、长度、容量与整数溢出，每次最多 1 MiB，允许引擎处理短读。FSKit 块读取按物理扇区对齐，检查实际传输量和资源撤销，不混用元数据缓存。EOF、I/O 错误、闭合句柄以及不支持的文件访问按错误返回。

当前保存精确文件名与大小写；不对名称自动归一化。固定版本的 `ntfs_inode_lookup_by_mbsname` 在缺少可选 lookup cache 时存在空字符串指针路径，桥接直接转换 UTF-16 并调用 `ntfs_inode_lookup_by_name`，不修改上游。[目录与名称实现](https://github.com/tuxera/ntfs-3g/blob/7f0f841fc52cf719106c5c93bafe465004e36816/libntfs-3g/dir.c)

支持普通文件读取与目录分页；枚举过滤 DOS 短名称别名和 NTFS 内部元数据。精确路径仍可用于测试已知系统目录。EFS 和 reparse point 内容拒绝访问；未知目录条目不伪称普通文件。完整 Windows 大小写语义、ADS/xattr/Finder 元数据、POSIX ACL、链接与特殊文件仍需后续实现。未迁移或清理任何 `._` 文件。

## 验收范围

完整镜像由固定上游工具在新建临时普通文件内创建，数据哈希、分页、Unicode、空文件、EOF、短读、注入 I/O 故障、损坏 MFT、并发及反复打开／关闭均有回归。具体输入与重建步骤见 [测试说明](TESTING.md)。这些测试没有系统挂载卷，也没有在生产磁盘上执行操作。

FSKit Handler、块资源、宿主和扩展在 macOS 27 SDK 下编译；打包原型使用 ad hoc 签名，媒体匹配为空。签名授权限制见 [系统集成路线](SIGNING.md)。只有完成真实系统加载和本地卷证据，才能关闭 M2 的原生验收项。
