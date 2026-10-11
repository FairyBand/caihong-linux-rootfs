#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Osilvfe <osilvfe@gmail.com>
"""Prepare installable GitHub release assets and release notes."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import struct
from pathlib import Path


PART_BYTES = 1900 * 1024 * 1024
DIRECT_BYTES = 2000 * 1024 * 1024
COPY_BYTES = 8 * 1024 * 1024
SPARSE_HEADER = struct.Struct("<I4H4I")
SPARSE_CHUNK_HEADER = struct.Struct("<2H2I")
SPARSE_MAGIC = 0xED26FF3A
SPARSE_CHUNK_RAW = 0xCAC1
SPARSE_CHUNK_FILL = 0xCAC2
SPARSE_CHUNK_DONT_CARE = 0xCAC3
SPARSE_CHUNK_CRC32 = 0xCAC4


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


def inspect_android_sparse(path: Path) -> dict[str, int | str]:
    """Validate an Android sparse image and return release metadata."""
    with path.open("rb") as source:
        header = source.read(SPARSE_HEADER.size)
        if len(header) != SPARSE_HEADER.size:
            raise RuntimeError(f"truncated Android sparse header: {path}")
        (
            magic,
            major,
            minor,
            file_header_bytes,
            chunk_header_bytes,
            block_bytes,
            total_blocks,
            total_chunks,
            _checksum,
        ) = SPARSE_HEADER.unpack(header)
        if magic != SPARSE_MAGIC or major != 1:
            raise RuntimeError(f"unsupported Android sparse image: {path}")
        if file_header_bytes < SPARSE_HEADER.size:
            raise RuntimeError(f"invalid Android sparse file header size: {path}")
        if chunk_header_bytes < SPARSE_CHUNK_HEADER.size:
            raise RuntimeError(f"invalid Android sparse chunk header size: {path}")
        if block_bytes == 0 or block_bytes % 4:
            raise RuntimeError(f"invalid Android sparse block size: {path}")
        source.seek(file_header_bytes)

        output_blocks = 0
        for _ in range(total_chunks):
            chunk_header = source.read(chunk_header_bytes)
            if len(chunk_header) != chunk_header_bytes:
                raise RuntimeError(f"truncated Android sparse chunk header: {path}")
            chunk_type, _reserved, chunk_blocks, total_bytes = (
                SPARSE_CHUNK_HEADER.unpack_from(chunk_header)
            )
            if total_bytes < chunk_header_bytes:
                raise RuntimeError(f"invalid Android sparse chunk size: {path}")
            payload_bytes = total_bytes - chunk_header_bytes
            expected_payload = {
                SPARSE_CHUNK_RAW: chunk_blocks * block_bytes,
                SPARSE_CHUNK_FILL: 4,
                SPARSE_CHUNK_DONT_CARE: 0,
                SPARSE_CHUNK_CRC32: 4,
            }.get(chunk_type)
            if expected_payload is None or payload_bytes != expected_payload:
                raise RuntimeError(f"invalid Android sparse chunk payload: {path}")
            source.seek(payload_bytes, 1)
            output_blocks += chunk_blocks

        if output_blocks != total_blocks or source.tell() != path.stat().st_size:
            raise RuntimeError(f"inconsistent Android sparse image length: {path}")

    return {
        "format": "android-sparse-ext4",
        "sparse_version": f"{major}.{minor}",
        "block_bytes": block_bytes,
        "logical_bytes": total_blocks * block_bytes,
        "filesystem_label": "linux",
    }


def copy_part(source, target: Path, limit: int) -> int:
    copied = 0
    with target.open("wb") as destination:
        while copied < limit:
            block = source.read(min(COPY_BYTES, limit - copied))
            if not block:
                break
            destination.write(block)
            copied += len(block)
    return copied


def write_release_notes(
    path: Path,
    kernel_release: str,
    assets: list[Path],
    rootfs: Path,
    rootfs_assets: list[Path],
    dependencies: dict[str, str],
    rootfs_metadata: dict[str, int | str],
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
        reconstruction = f"Use `{rootfs.name}` directly."
    else:
        parts = " ".join(asset.name for asset in rootfs_assets)
        reconstruction = (
            "GitHub limits each Release asset to less than 2 GiB, so the rootfs "
            "is split without recompression. Reconstruct it in part-number order:\n\n"
            "```sh\n"
            f"cat {parts} > {rootfs.name}\n"
            "```"
        )

    if rootfs_metadata["format"] == "android-sparse-ext4":
        rootfs_instructions = (
            f"{reconstruction}\n\n"
            "The reconstructed file is an Android sparse ext4 image and can be "
            "flashed directly. Select `linux` for dual boot or `userdata` for a "
            "single-system installation:\n\n"
            "```sh\n"
            "ROOT_PARTITION=linux\n"
            f"fastboot flash \"$ROOT_PARTITION\" {rootfs.name}\n"
            "```\n\n"
            f"Its logical filesystem size is {rootfs_metadata['logical_bytes']} bytes."
        )
    else:
        rootfs_instructions = reconstruction

    path.write_text(
        f"""Caihong Linux release for the OnePlus Pad Pro.

The two Android boot image v2 files contain only Linux `{kernel_release}` and the
Caihong DTB; they do not contain a ramdisk. Choose the `linux` image for dual boot
or the `userdata` image for a single-system installation.

## Required DTBO step

Erase only the DTBO partition for the slot selected for Linux before flashing
its boot image. Keep the Android slot's DTBO intact.

```sh
LINUX_SLOT=b
fastboot erase "dtbo_${{LINUX_SLOT}}"
fastboot flash "boot_${{LINUX_SLOT}}" caihong-boot-linux-{kernel_release}.img
```

## Rootfs

{rootfs_instructions}

Complete rootfs image SHA-256:

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
    if not rootfs.name.endswith(".ext4.sparse.img"):
        raise RuntimeError("release rootfs must be an .ext4.sparse.img file")
    rootfs_metadata = inspect_android_sparse(rootfs)
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
                target = assets / f"{rootfs.name}.part-{index:02d}"
                copied_bytes = copy_part(source, target, PART_BYTES)
                if copied_bytes == 0:
                    target.unlink()
                    break
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
            **rootfs_metadata,
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
        rootfs_metadata,
    )
    for path in copied:
        if path.stat().st_size >= 2 * 1024 * 1024 * 1024:
            raise RuntimeError(f"release asset is not below 2 GiB: {path}")
    print(f"prepared {len(copied)} installable release assets in {assets}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
