#!/usr/bin/python3.10
"""Install already hash-verified wheels without network or a pip bootstrap."""

from __future__ import annotations

import pathlib
import shutil
import sys
import zipfile


def safe_relative_path(name: str) -> pathlib.PurePosixPath:
    path = pathlib.PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts:
        raise RuntimeError(f"unsafe wheel member: {name}")
    return path


def target_relative_path(path: pathlib.PurePosixPath) -> pathlib.PurePosixPath | None:
    data_index = next((index for index, part in enumerate(path.parts) if part.endswith(".data")), None)
    if data_index is None:
        return path
    if len(path.parts) <= data_index + 2 or path.parts[data_index + 1] not in {"purelib", "platlib"}:
        return None
    return pathlib.PurePosixPath(*path.parts[data_index + 2 :])


def install_wheel(wheel: pathlib.Path, target: pathlib.Path) -> None:
    with zipfile.ZipFile(wheel) as archive:
        for member in archive.infolist():
            source_path = safe_relative_path(member.filename)
            relative = target_relative_path(source_path)
            if relative is None or not relative.parts:
                continue
            destination = target.joinpath(*relative.parts)
            destination.resolve().relative_to(target.resolve())
            if member.is_dir():
                destination.mkdir(parents=True, exist_ok=True)
                continue
            destination.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(member) as source, destination.open("wb") as output:
                shutil.copyfileobj(source, output)


def main() -> int:
    if len(sys.argv) != 3:
        raise RuntimeError("usage: install-python-wheels.py WHEEL_ROOT TARGET")
    wheel_root = pathlib.Path(sys.argv[1]).resolve(strict=True)
    target = pathlib.Path(sys.argv[2])
    target.mkdir(parents=True, exist_ok=True)
    wheels = sorted(wheel_root.glob("*.whl"))
    if not wheels:
        raise RuntimeError("no wheels found")
    for wheel in wheels:
        install_wheel(wheel, target)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
