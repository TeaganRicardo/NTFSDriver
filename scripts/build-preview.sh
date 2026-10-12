#!/bin/sh
set -eu
repository_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if ! git -C "$repository_dir" diff --quiet || ! git -C "$repository_dir" diff --cached --quiet ||
   [ -n "$(git -C "$repository_dir" ls-files --others --exclude-standard)" ]; then
    printf '请先提交工作区变更，再构建绑定源码提交的预览包。\n' >&2
    exit 1
fi
source_commit=$(git -C "$repository_dir" rev-parse HEAD)
python3 "$repository_dir/scripts/verify-vendor.py"
build_dir=$(mktemp -d /tmp/ntfsdriver-preview-build.XXXXXX)
output_dir=$(mktemp -d /tmp/ntfsdriver-preview.XXXXXX)
trap 'rm -rf -- "$build_dir"' EXIT

swift build --package-path "$repository_dir" --scratch-path "$build_dir" -c release
binary_dir=$(swift build --package-path "$repository_dir" --scratch-path "$build_dir" -c release --show-bin-path)
app="$output_dir/NTFSDriver Preview.app"
extension="$app/Contents/Extensions/NTFSModule.appex"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$extension/Contents/MacOS"
cp -X "$binary_dir/NTFSManager" "$app/Contents/MacOS/"
cp -X "$binary_dir/NTFSModule" "$extension/Contents/MacOS/"
cp -X "$repository_dir/Packaging/AppInfo.plist" "$app/Contents/Info.plist"
cp -X "$repository_dir/Packaging/ExtensionInfo.plist" "$extension/Contents/Info.plist"
cp -X "$repository_dir/LICENSE" "$app/Contents/Resources/LICENSE"
cp -X "$repository_dir/THIRD_PARTY.md" "$app/Contents/Resources/THIRD_PARTY.md"
printf '%s\n' "$source_commit" > "$app/Contents/Resources/SourceCommit.txt"
test "$(git -C "$repository_dir" rev-parse HEAD)" = "$source_commit"
git -C "$repository_dir" diff --quiet
git -C "$repository_dir" diff --cached --quiet
test -z "$(git -C "$repository_dir" ls-files --others --exclude-standard)"
codesign --force --sign - --entitlements "$repository_dir/Packaging/Extension.entitlements" "$extension"
codesign --force --sign - "$app"
codesign --verify --strict --deep --verbose=2 "$app"
printf '开发预览已构建（ad hoc 签名，系统加载与配置文件尚未验证）：\n%s\n' "$app"
