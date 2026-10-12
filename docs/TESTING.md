# 可丢弃镜像与只读回归

测试入口为 `./scripts/check.sh`，在独立临时目录完成来源校验、XCTest、Release 构建与 CLI 帮助检查。需要 macOS 27 / Apple Silicon 和完整 Xcode；不需要 FSKit 配置文件或付费开发者团队。

## 已保存的输入

`Tests/NTFSDriverTests/Fixtures/readonly.ntfs.gz` 是 64 MiB 的完整原始 NTFS 分区镜像，经 gzip 压缩。没有分区表或 DMG 容器。镜像标签 NTFSDriverTest，扇区 512 字节，簇 4096 字节；由 NTFS-3G 2026.9.28 固定提交的 `mkntfs` 和 `ntfscp` 创建。

解压后 SHA-256 为 `b2d5146341cfe073465f324249e10cb788f424b8e04124ce7f0458da0aed4224`。图像与数据清单见 Fixtures/manifest.json；测试先验证镜像哈希，再进行访问。每个测试解压至新建临时普通文件，结束后清理。

| 文件 | 数据来源 | 字节数 | SHA-256 |
| --- | --- | ---: | --- |
| Alpha.bin | 0 至 255 的字节序列重复 8193 次 | 2097408 | `ad4707187ce2c9c3d16909bd20eb1c440fa9d2717bff5b836db2d32f997da4d2` |
| 中文🦊.txt | UTF-8 测试文字与尾部换行，内容见创建脚本 | 54 | `c0e6b9ab8557c94bf9d37202845a86341c7561c292670a456dd42321ecaf5444` |
| empty.txt | 空文件 | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |

测试数据由本项目生成；镜像内的上游 NTFS boot code 对应源码保存在 `Tests/FixtureSource/boot.c` 与 boot.h，许可见文件头与根目录 LICENSE。

## 重建语义等价镜像

完整上游源码按 `Vendor/NTFS3G/UPSTREAM.json` 中提交与归档 SHA-256 获取，核对后在临时目录运行 autogen/configure/make。工具构建使用：

```sh
./autogen.sh
./configure --disable-ntfs-3g --disable-mount-helper --disable-crypto --disable-nfconv --disable-shared --enable-static
make -j4
```

需要 autoconf、automake、libtool 与编译工具；这些只用于重建 fixture，日常项目编译与测试使用随仓库保存的源码和镜像。将上述完整源码目录中的 ntfsprogs 传给本项目脚本：

```sh
./scripts/create-fixture.sh /path/to/pinned-upstream/ntfsprogs
```

脚本仅在自己创建的私有临时目录里新建镜像，不能指定生产设备或已有文件作为输出。所有格式化与写入只作用于该新文件。生成后的数据内容与文件哈希应相同；卷序列号、工具复制时间等元数据可能变化，**不保证重建后的整镜像与已保存 fixture 逐字节相同**。保存新 fixture 时必须记录新的整镜像哈希并保留数据预期，不能未经校验替换基准。

## 当前覆盖与限制

M1 的 14 项测试覆盖引导结构、几何和溢出、特殊文件与符号链接拒绝、CLI JSON 和 FSKit 结构识别。M2 增加 9 项测试，覆盖真实镜像名称与文件内容、分页、EOF、错误与大小边界、两个独立卷反复开关、16 个并发任务共享一个卷、CLI hash/list、真实设备拒写回调、短读与注入 EIO、损坏 MFT，以及物理块对齐计划。各镜像操作核对前后 SHA-256，关闭后访问必须失败。

本批没有系统挂载，没有测试 Finder、磁盘工具、自动插盘或 Windows 往返；没有测试写入恢复、长时间负载、压缩稀疏/EFS/reparse 特性矩阵、热拔盘和实际 FSKit 进程崩溃。只读回归通过不能替代这些验收。当前不允许写入，不修改 Dirty Flag 或休眠状态。
