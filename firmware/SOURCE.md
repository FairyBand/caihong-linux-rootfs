# Caihong firmware bundle

This directory contains runtime firmware selected for the OnePlus Pad Pro
(`caihong`) root filesystem. Device-specific Qualcomm, Awinic, Novatek and
WCN7850 payloads were extracted from the matching stock firmware image; they
are not covered by this repository's GPL-2.0-only license. The AudioReach
topology is regenerated from `external/audioreach-topology` during the rootfs
build.

The board-specific `vpu33_4v.mbn` is selected by the Caihong device tree for
the Qualcomm Iris video codec; the generic SM8650 VPU image is not compatible
with this device's signed firmware layout.

The `bps-striping-bggr10-nv12-*` tables were generated for the validated
camera modes with the matching stock Qualcomm BPS striping library. They are
runtime inputs for the mainline Camera ICP/BPS driver and remain subject to
the vendor firmware terms.

`CAMERA_ICP.mbn` is the matching monolithic stock Camera ICP firmware image.
The Camera ICP remoteproc driver authenticates it through Qualcomm PAS before
the BPS hardware pipeline is exposed to libcamera.

`SHA256SUMS` records every binary release input. The build verifies this file
before embedding early GPU firmware or copying the runtime firmware tree.

The WCN7850 variant deliberately uses
`WLAN.HMT.1.1.c7-00108-QCAHMTSWPL_V1.0_V2.0_SILICONZ_UPSTREAM-3`. The stock
HMT 2.0 payload can reach QMI on this kernel baseline, but times out waiting
for the WMI unified-ready event and must not be substituted independently of
the WLAN driver.
