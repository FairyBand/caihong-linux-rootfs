# Caihong SSC bundle

This directory is the release input consumed by the rootfs packager. It was
generated from the Caihong stock `vendor.img` and `odm.img` by
`external/out_tree_module-sc8547/sensors/ssc/build-bundle.sh`.

`VERSION` pins the upstream hexagonrpc source used to build `hexagonrpcd` and
`libhexagonrpc`. The `root/sensors/persist/registry` directory is a generated
first-boot seed. Runtime calibration and registry changes from a used device
are not stored here. `SHA256SUMS` covers every release input in this directory;
the installer verifies it before copying anything into a root filesystem.

The libssc-enabled `iio-sensor-proxy` and `libssc.so.2` runtime files are
extracted from the Arch Linux ARM `iio-sensor-proxy 3.9-1` and `libssc
0.4.4-1` packages. Their package SHA-256 digests are respectively
`8c37d1f1448dbc0f6381fc75315a7754e7ac9902efb341558a4c47cd4065f975`
and `c65429123ee7ec43d8feca7cb034df0cd7c2eae27ab8eaea951226c4d14a5f84`.
`iio-sensor-proxy` is GPL-3.0-only and its source is available from
<https://gitlab.freedesktop.org/hadess/iio-sensor-proxy/>. `libssc` is
GPL-3.0-or-later and its source is available from
<https://libssc.dylanvanassche.be/>.
