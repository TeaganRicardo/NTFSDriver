#!/bin/sh
set -eu
if [ "$#" -ne 1 ] || [ ! -x "$1/mkntfs" ] || [ ! -x "$1/ntfscp" ]; then
    printf '用法：create-fixture.sh <固定版本 ntfsprogs 工具目录>\n' >&2
    exit 64
fi
tools_dir=$(CDPATH= cd -- "$1" && pwd)
fixture_dir=$(mktemp -d /tmp/ntfsdriver-fixture.XXXXXX)
python3 - "$fixture_dir" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
with (root / "test.ntfs").open("xb") as image:
    image.truncate(64 * 1024 * 1024)
(root / "Alpha.bin").write_bytes(bytes(range(256)) * 8193)
(root / "unicode.txt").write_text("NTFSDriver 中文与 emoji 文件内容：测试 🦊\n", encoding="utf-8")
(root / "empty.txt").write_bytes(b"")
PY
# -F is restricted to this newly created ordinary file in a private temporary directory.
"$tools_dir/mkntfs" -F -Q -T -s 512 -c 4096 -L NTFSDriverTest "$fixture_dir/test.ntfs"
"$tools_dir/ntfscp" "$fixture_dir/test.ntfs" "$fixture_dir/Alpha.bin" /Alpha.bin
"$tools_dir/ntfscp" "$fixture_dir/test.ntfs" "$fixture_dir/unicode.txt" '/中文🦊.txt'
"$tools_dir/ntfscp" "$fixture_dir/test.ntfs" "$fixture_dir/empty.txt" /empty.txt
printf '已创建可丢弃测试镜像：\n%s\n' "$fixture_dir/test.ntfs"
