# Caihong firmware bundle

This directory contains runtime firmware selected for the OnePlus Pad Pro
(`caihong`) root filesystem. Device-specific Qualcomm, Awinic, Novatek and
WCN7850 payloads were extracted from the matching stock firmware image; they
are not covered by this repository's GPL-2.0-only license. The AudioReach
topology is regenerated from `external/audioreach-topology` during the rootfs
build.

The `bps-striping-bggr10-nv12-*` tables were generated for the validated
camera modes with the matching stock Qualcomm BPS striping library. They are
runtime inputs for the mainline Camera ICP/BPS driver and remain subject to
the vendor firmware terms.

`SHA256SUMS` records every binary release input. The build verifies this file
before embedding early GPU firmware or copying the runtime firmware tree.

The WCN7850 variant deliberately uses
`WLAN.HMT.1.1.c7-00108-QCAHMTSWPL_V1.0_V2.0_SILICONZ_UPSTREAM-3`. The stock
HMT 2.0 payload can reach QMI on this kernel baseline, but times out waiting
for the WMI unified-ready event and must not be substituted independently of
the WLAN driver.
