#!/bin/sh
set -eu
if [ "$#" -ne 1 ]; then
    printf '用法：build-fuse-preview.sh <macFUSE 官方包展开的 Payload 或用户空间 SDK 根目录>\n' >&2
    exit 64
fi
sdk_dir=$(CDPATH= cd -- "$1" && pwd)
repository_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if ! git -C "$repository_dir" diff --quiet || ! git -C "$repository_dir" diff --cached --quiet ||
   [ -n "$(git -C "$repository_dir" ls-files --others --exclude-standard)" ]; then
    printf '请先提交工作区变更，再构建绑定源码提交的实验程序。\n' >&2
    exit 1
fi
source_commit=$(git -C "$repository_dir" rev-parse HEAD)
build_dir=$(mktemp -d /tmp/ntfsdriver-fuse-build.XXXXXX)
output_dir=$(mktemp -d /tmp/ntfsdriver-fuse-preview.XXXXXX)
trap 'rm -rf -- "$build_dir"' EXIT
python3 "$repository_dir/scripts/verify-vendor.py"
codesign --verify --strict "$sdk_dir/usr/local/lib/libfuse.2.dylib"
codesign --verify --strict "$sdk_dir/Library/Filesystems/macfuse.fs/Contents/Frameworks/MFMount.framework"
swift build --package-path "$repository_dir" --scratch-path "$build_dir" -c release --target CNTFSBridge
binary_dir=$(swift build --package-path "$repository_dir" --scratch-path "$build_dir" -c release --show-bin-path)
clang -D_FILE_OFFSET_BITS=64 -D_DARWIN_USE_64_BIT_INODE -I "$sdk_dir/usr/local/include" \
    -I "$repository_dir/Sources/CNTFSBridge/include" "$repository_dir/Experiments/macFUSE/ReadOnly.c" \
    "$binary_dir/CNTFSBridge.o" "$binary_dir/CNTFSEngine.o" "$sdk_dir/usr/local/lib/libfuse.2.dylib" \
    -o "$output_dir/ntfs-fuse-readonly"
test "$(git -C "$repository_dir" rev-parse HEAD)" = "$source_commit"
git -C "$repository_dir" diff --quiet
git -C "$repository_dir" diff --cached --quiet
test -z "$(git -C "$repository_dir" ls-files --others --exclude-standard)"
printf '%s\n' "$source_commit" > "$output_dir/SourceCommit.txt"
printf '只读 FSKit/FUSE 实验程序：\n%s\n运行时需使用同一 SDK 的 DYLD_LIBRARY_PATH 与 DYLD_FRAMEWORK_PATH；不安装 KEXT。\n' "$output_dir/ntfs-fuse-readonly"
