#!/bin/sh
set -eu

repository_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_dir=$(mktemp -d /tmp/ntfsdriver-check.XXXXXX)
trap 'rm -rf -- "$build_dir"' EXIT

# Keep signed XCTest products outside Documents, where Finder metadata can break signing.
python3 "$repository_dir/scripts/verify-vendor.py"
swift test --package-path "$repository_dir" --scratch-path "$build_dir"
swift build --package-path "$repository_dir" --scratch-path "$build_dir" -c release
swift build --package-path "$repository_dir" --scratch-path "$build_dir" -c release --target NTFSFSKit
binary_dir=$(swift build --package-path "$repository_dir" --scratch-path "$build_dir" -c release --show-bin-path)
"$binary_dir/ntfs-inspect" --help
"$binary_dir/ntfs-read" --help
