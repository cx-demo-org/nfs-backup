#!/usr/bin/env python3
"""Create and compare deterministic POSIX-aware manifests for the NFS lab.

The manifest is a verification sidecar for the tar archive; it is not a backup by itself.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
import sys
from pathlib import Path
from typing import Any


def sha256_file(path: Path) -> str:
    """Hash a file in bounded chunks so large files do not consume equivalent RAM."""
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def create_manifest(root: Path) -> list[dict[str, Any]]:
    """Walk one tree without following symlinks and record content plus required POSIX metadata."""
    root = root.resolve(strict=True)
    entries: list[dict[str, Any]] = []
    inode_first_path: dict[tuple[int, int], str] = {}

    # Sorting makes output stable across runs and machines for meaningful diffs.
    for current, dirnames, filenames in os.walk(root, topdown=True, followlinks=False):
        dirnames.sort()
        filenames.sort()
        current_path = Path(current)
        names = list(dirnames) + filenames
        for name in names:
            path = current_path / name
            relative = path.relative_to(root).as_posix()
            if relative == ".snapshots":
                # Azure Files exposes this synthetic control directory in the restored share too; it is not user backup data.
                continue
            # lstat inspects a symlink itself instead of following it to the target.
            info = path.lstat()
            mode = stat.S_IMODE(info.st_mode)
            entry: dict[str, Any] = {
                "path": relative,
                "uid": info.st_uid,
                "gid": info.st_gid,
                "mode": mode,
                "mtime_ns": info.st_mtime_ns,
            }

            if stat.S_ISDIR(info.st_mode):
                # Directories are entries too, so empty directories are validated.
                entry["type"] = "directory"
            elif stat.S_ISLNK(info.st_mode):
                # Store the link target string; do not hash the target file in place of the link.
                entry["type"] = "symlink"
                entry["target"] = os.readlink(path)
            elif stat.S_ISREG(info.st_mode):
                # Hash file bytes and use inode identity to represent repeated hardlink paths.
                entry["type"] = "file"
                entry["size"] = info.st_size
                entry["sha256"] = sha256_file(path)
                inode_key = (info.st_dev, info.st_ino)
                if info.st_nlink > 1:
                    first = inode_first_path.setdefault(inode_key, relative)
                    if first != relative:
                        entry["hardlink_to"] = first
            else:
                entry["type"] = "special"
                entry["device"] = info.st_rdev

            entries.append(entry)

    entries.sort(key=lambda item: item["path"])
    return entries


def write_manifest(root: Path, output: Path) -> None:
    """Write stable JSON and print concise aggregate counts for command logs."""
    manifest = create_manifest(root)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    total_bytes = sum(entry.get("size", 0) for entry in manifest if entry["type"] == "file")
    print(f"MANIFEST_ENTRIES={len(manifest)}")
    print(f"MANIFEST_FILES={sum(entry['type'] == 'file' for entry in manifest)}")
    print(f"MANIFEST_BYTES={total_bytes}")


def compare_manifests(expected_path: Path, actual_path: Path) -> int:
    """Return nonzero if any path, content digest, type, or recorded metadata differs."""
    expected = json.loads(expected_path.read_text(encoding="utf-8"))
    actual = json.loads(actual_path.read_text(encoding="utf-8"))
    expected_by_path = {entry["path"]: entry for entry in expected}
    actual_by_path = {entry["path"]: entry for entry in actual}
    errors: list[str] = []

    # Report missing and unexpected paths separately before comparing shared paths field by field.
    for relative in sorted(expected_by_path.keys() - actual_by_path.keys()):
        errors.append(f"MISSING {relative}")
    for relative in sorted(actual_by_path.keys() - expected_by_path.keys()):
        errors.append(f"EXTRA {relative}")
    for relative in sorted(expected_by_path.keys() & actual_by_path.keys()):
        left = expected_by_path[relative]
        right = actual_by_path[relative]
        if left != right:
            for key in sorted(left.keys() | right.keys()):
                if left.get(key) != right.get(key):
                    errors.append(f"MISMATCH {relative} field={key}: expected={left.get(key)!r} actual={right.get(key)!r}")

    if errors:
        # Bound console output for huge trees while retaining the complete mismatch count.
        for error in errors[:200]:
            print(error, file=sys.stderr)
        if len(errors) > 200:
            print(f"... plus {len(errors) - 200} more mismatches", file=sys.stderr)
        print(f"MANIFEST_COMPARE=FAIL mismatches={len(errors)}")
        return 1

    total_bytes = sum(entry.get("size", 0) for entry in expected if entry["type"] == "file")
    print(f"MANIFEST_COMPARE=PASS entries={len(expected)} bytes={total_bytes}")
    return 0


def main() -> int:
    """Parse create/compare subcommands and return a shell-friendly status code."""
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    create = commands.add_parser("create", help="Create a file-tree manifest")
    create.add_argument("--root", type=Path, required=True)
    create.add_argument("--output", type=Path, required=True)
    compare = commands.add_parser("compare", help="Compare two manifests exactly")
    compare.add_argument("--expected", type=Path, required=True)
    compare.add_argument("--actual", type=Path, required=True)
    args = parser.parse_args()

    if args.command == "create":
        write_manifest(args.root, args.output)
        return 0
    return compare_manifests(args.expected, args.actual)


if __name__ == "__main__":
    raise SystemExit(main())
