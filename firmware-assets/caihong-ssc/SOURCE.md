# Caihong SSC bundle

This directory is the release input consumed by the rootfs packager. It was
generated from the Caihong stock `vendor.img` and `odm.img` by
`external/out_tree_module-sc8547/sensors/ssc/build-bundle.sh`.

`VERSION` pins the upstream hexagonrpc source used to build `hexagonrpcd` and
`libhexagonrpc`. The `root/sensors/persist/registry` directory is a generated
first-boot seed. Runtime calibration and registry changes from a used device
are not stored here. `SHA256SUMS` covers every release input in this directory;
the installer verifies it before copying anything into a root filesystem.
