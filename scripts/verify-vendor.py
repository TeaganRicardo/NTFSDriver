#!/usr/bin/env python3
"""Verify the exact pinned upstream inventory without fetching or modifying it."""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parent.parent / "Vendor" / "NTFS3G"
manifest = json.loads((root / "UPSTREAM.json").read_text())
expected = set(manifest["files"]) | set(manifest["localFiles"])
actual = {str(path.relative_to(root)) for path in root.rglob("*") if path.is_file()}
if actual != expected:
    raise SystemExit(f"Vendor inventory mismatch: missing={expected - actual}, extra={actual - expected}")
for name, digest in manifest["files"].items():
    path = root / name
    if path.is_symlink() or not path.resolve().is_relative_to(root.resolve()):
        raise SystemExit(f"Unsafe vendor path: {name}")
    if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
        raise SystemExit(f"Upstream checksum mismatch: {name}")
print(f"Verified {len(manifest['files'])} unmodified NTFS-3G files at {manifest['commit']}")
