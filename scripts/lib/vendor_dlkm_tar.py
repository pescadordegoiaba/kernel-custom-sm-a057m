#!/usr/bin/env python3
"""Create a deterministic vendor_dlkm tar stream with Android SELinux xattrs."""

from __future__ import annotations

import argparse
import os
import tarfile
from pathlib import Path


def selinux_context(relative_path: str) -> str:
    if relative_path == "etc" or relative_path.startswith("etc/"):
        return "u:object_r:vendor_configs_file:s0"
    return "u:object_r:vendor_file:s0"


def add_path(
    archive: tarfile.TarFile, root: Path, path: Path, timestamp: int
) -> None:
    relative = path.relative_to(root)
    archive_name = "." if not relative.parts else relative.as_posix()
    stat_result = path.lstat()

    info = tarfile.TarInfo(archive_name)
    info.uid = 0
    info.gid = 0
    info.uname = "root"
    info.gname = "root"
    info.mode = stat_result.st_mode & 0o7777
    info.mtime = timestamp
    info.pax_headers = {
        "SCHILY.xattr.security.selinux": selinux_context(
            "" if archive_name == "." else archive_name
        )
    }

    if path.is_dir():
        info.type = tarfile.DIRTYPE
        info.size = 0
        archive.addfile(info)
        return

    if path.is_symlink():
        info.type = tarfile.SYMTYPE
        info.linkname = os.readlink(path)
        info.size = 0
        archive.addfile(info)
        return

    if path.is_file():
        info.type = tarfile.REGTYPE
        info.size = stat_result.st_size
        with path.open("rb") as source:
            archive.addfile(info, source)
        return

    raise ValueError(f"Unsupported file type: {path}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--timestamp", type=int, default=1640995200)
    args = parser.parse_args()

    source = args.source.resolve()
    if not source.is_dir():
        raise SystemExit(f"Source directory not found: {source}")

    paths = [source]
    paths.extend(sorted(source.rglob("*"), key=lambda item: item.relative_to(source).as_posix()))

    with tarfile.open(args.output, mode="w", format=tarfile.PAX_FORMAT) as archive:
        for path in paths:
            add_path(archive, source, path, args.timestamp)


if __name__ == "__main__":
    main()
