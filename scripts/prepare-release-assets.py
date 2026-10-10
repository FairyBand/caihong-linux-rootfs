#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Osilvfe <osilvfe@gmail.com>
"""Prepare GitHub release assets, splitting the rootfs below 2 GiB."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
from pathlib import Path


PART_BYTES = 1900 * 1024 * 1024
DIRECT_BYTES = 2000 * 1024 * 1024


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(8 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def load_dependencies(path: Path) -> dict[str, str]:
    result = {}
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        key, value = line.split("=", 1)
        result[key] = value
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--release-dir", type=Path, required=True)
    parser.add_argument("--rootfs", type=Path, required=True)
    parser.add_argument("--dependencies", type=Path, required=True)
    parser.add_argument("--assets", type=Path, required=True)
    args = parser.parse_args()

    release_dir = args.release_dir.resolve()
    rootfs = args.rootfs.resolve()
    assets = args.assets.resolve()
    kernel_release = (release_dir / "KERNEL_RELEASE").read_text().strip()
    boot_manifest_path = release_dir / f"caihong-boot-{kernel_release}.img.json"
    boot_manifest = json.loads(boot_manifest_path.read_text())

    if assets.exists():
        shutil.rmtree(assets)
    assets.mkdir(parents=True)
    copied = []
    for name in (
        f"caihong-boot-{kernel_release}.img",
        f"caihong-boot-{kernel_release}.img.json",
        f"Image-{kernel_release}",
        f"sm8650-oneplus-caihong-{kernel_release}.dtb",
        f"config-{kernel_release}",
        "KERNEL_RELEASE",
        "SHA256SUMS.boot",
    ):
        target = assets / name
        shutil.copy2(release_dir / name, target)
        copied.append(target)

    rootfs_hash = sha256(rootfs)
    rootfs_assets = []
    if rootfs.stat().st_size < DIRECT_BYTES:
        target = assets / rootfs.name
        shutil.copy2(rootfs, target)
        rootfs_assets.append(target)
    else:
        with rootfs.open("rb") as source:
            index = 0
            while True:
                payload = source.read(PART_BYTES)
                if not payload:
                    break
                target = assets / f"{rootfs.name}.part-{index:02d}"
                target.write_bytes(payload)
                rootfs_assets.append(target)
                index += 1
    copied.extend(rootfs_assets)

    manifest = {
        "device": "OnePlus Pad Pro (caihong)",
        "kernel_release": kernel_release,
        "boot": boot_manifest,
        "rootfs": {
            "reconstructed_name": rootfs.name,
            "bytes": rootfs.stat().st_size,
            "sha256": rootfs_hash,
            "assets": [path.name for path in rootfs_assets],
        },
        "dependencies": load_dependencies(args.dependencies),
    }
    manifest_path = assets / "release-manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    copied.append(manifest_path)

    sums = assets / "SHA256SUMS"
    sums.write_text("".join(f"{sha256(path)}  {path.name}\n" for path in copied))
    for path in [*copied, sums]:
        if path.stat().st_size >= 2 * 1024 * 1024 * 1024:
            raise RuntimeError(f"release asset is not below 2 GiB: {path}")
    print(f"prepared {len(copied) + 1} release assets in {assets}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
