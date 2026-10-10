# Caihong firmware bundle

This directory contains runtime firmware selected for the OnePlus Pad Pro
(`caihong`) root filesystem. Device-specific Qualcomm, Awinic, Novatek and
WCN7850 payloads were extracted from the matching stock firmware image; they
are not covered by this repository's GPL-2.0-only license. The AudioReach
topology is regenerated from `external/audioreach-topology` during the rootfs
build.

`SHA256SUMS` records every binary release input. The build verifies this file
before embedding early GPU firmware or copying the runtime firmware tree.
