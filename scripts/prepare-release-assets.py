#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Osilvfe <osilvfe@gmail.com>
"""Prepare installable GitHub release assets and release notes."""

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


def write_release_notes(
    path: Path,
    kernel_release: str,
    assets: list[Path],
    rootfs: Path,
    rootfs_assets: list[Path],
    dependencies: dict[str, str],
) -> None:
    checksums = "".join(f"{sha256(asset)}  {asset.name}\n" for asset in assets)
    source_lines = []
    for component in ("LINUX", "LIBCAMERA", "PLASMA_CAMERA", "QBOOTCTL", "MKBOOTIMG"):
        repository = dependencies.get(f"{component}_REPOSITORY")
        reference = dependencies.get(f"{component}_REF")
        commit = dependencies.get(f"{component}_COMMIT")
        if repository and reference and commit:
            source_lines.append(
                f"- `{component.lower().replace('_', '-')}`: `{commit}` "
                f"(`{reference}`, {repository})"
            )

    if len(rootfs_assets) == 1 and rootfs_assets[0].name == rootfs.name:
        rootfs_instructions = f"Use `{rootfs.name}` directly."
    else:
        parts = " ".join(asset.name for asset in rootfs_assets)
        rootfs_instructions = (
            "GitHub limits each Release asset to less than 2 GiB, so the rootfs "
            "is split without recompression. Reconstruct it in part-number order:\n\n"
            "```sh\n"
            f"cat {parts} > {rootfs.name}\n"
            "```"
        )

    path.write_text(
        f"""Caihong Linux release for the OnePlus Pad Pro.

The two Android boot image v2 files contain only Linux `{kernel_release}` and the
Caihong DTB; they do not contain a ramdisk. Choose the `linux` image for dual boot
or the `userdata` image for a single-system installation.

## Rootfs

{rootfs_instructions}

Reconstructed rootfs SHA-256:

```text
{sha256(rootfs)}  {rootfs.name}
```

## Asset SHA-256

```text
{checksums}```

## Resolved source revisions

{chr(10).join(source_lines)}
"""
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--release-dir", type=Path, required=True)
    parser.add_argument("--rootfs", type=Path, required=True)
    parser.add_argument("--dependencies", type=Path, required=True)
    parser.add_argument("--assets", type=Path, required=True)
    parser.add_argument("--notes", type=Path, required=True)
    args = parser.parse_args()

    release_dir = args.release_dir.resolve()
    rootfs = args.rootfs.resolve()
    assets = args.assets.resolve()
    kernel_release = (release_dir / "KERNEL_RELEASE").read_text().strip()
    boot_manifests = {
        root: json.loads(
            (release_dir / f"caihong-boot-{root}-{kernel_release}.img.json").read_text()
        )
        for root in ("linux", "userdata")
    }
    for root, manifest in boot_manifests.items():
        if manifest.get("root_partlabel") != root:
            raise RuntimeError(f"boot manifest root mismatch for {root}")
    kernel_package_name = (release_dir / "LINUX_CAIHONG_PACKAGE").read_text().strip()
    kernel_package = release_dir / kernel_package_name

    if assets.exists():
        shutil.rmtree(assets)
    assets.mkdir(parents=True)
    copied = []
    for name in (
        f"caihong-boot-linux-{kernel_release}.img",
        f"caihong-boot-userdata-{kernel_release}.img",
        kernel_package_name,
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

    dependencies = load_dependencies(args.dependencies)
    manifest = {
        "device": "OnePlus Pad Pro (caihong)",
        "kernel_release": kernel_release,
        "boot": boot_manifests,
        "pacman_package": {
            "name": kernel_package_name,
            "bytes": kernel_package.stat().st_size,
            "sha256": sha256(kernel_package),
        },
        "rootfs": {
            "reconstructed_name": rootfs.name,
            "bytes": rootfs.stat().st_size,
            "sha256": rootfs_hash,
            "assets": [path.name for path in rootfs_assets],
        },
        "dependencies": dependencies,
    }
    manifest_path = release_dir / "release-manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    sums = release_dir / "SHA256SUMS"
    sums.write_text("".join(f"{sha256(path)}  {path.name}\n" for path in copied))
    write_release_notes(
        args.notes.resolve(),
        kernel_release,
        copied,
        rootfs,
        rootfs_assets,
        dependencies,
    )
    for path in copied:
        if path.stat().st_size >= 2 * 1024 * 1024 * 1024:
            raise RuntimeError(f"release asset is not below 2 GiB: {path}")
    print(f"prepared {len(copied)} installable release assets in {assets}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
