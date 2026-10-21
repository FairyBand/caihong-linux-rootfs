# Caihong NPU self-test bundle

`libcdsprpc.so.1.0.0`, `libcalculator.so`, and
`dsp/v75/libcalculator_skel.so` are built or taken from Qualcomm's official
[FastRPC repository](https://github.com/qualcomm/fastrpc) at commit
`a56e9d4de3614a8d8f4b0e15ff561350c4b686e3`.
They are covered by the BSD-3-Clause terms reproduced in `LICENSE.fastrpc`.
The runtime library is a GNU/Linux AArch64 cross-build with the upstream
kernel interface enabled; the calculator pair is Qualcomm's v75 FastRPC test.

`dsp/v75/fastrpc_shell_unsigned_3` was extracted from the matching Caihong
stock CDSP firmware. It is device firmware and is not covered by the
repository's GPL license or the FastRPC BSD license. Its SHA-256 identifies
the exact stock payload used for the verified unsigned protection-domain
session.

The QAIRT/QNN HTP runtime comes from Qualcomm's official
[`geniex-qairt-plugin`](https://github.com/qualcomm/geniex-qairt-plugin)
repository at commit `e6d55652c174f5669608abaf04d529faa631f834`. The bundled Linux AArch64
runtime reports version `v2.45.0.260326`. Its `libQnnHtp.so`,
`libQnnHtpPrepare.so`, `libQnnHtpV75Stub.so`, and Hexagon v75 skel are subject
to the Qualcomm AI Runtime SDK EULA, as recorded in
`qnn/THIRD_PARTY_NOTICES.md`; they are not covered by this repository's GPL
license or the plugin's BSD license. The accompanying
`LICENSE.geniex-qairt-plugin` covers the upstream plugin code itself.

`dsp/v75/libc++.so.1` and `dsp/v75/libc++abi.so.1` were extracted from the
same Caihong stock CDSP firmware as the unsigned PD shell. They satisfy the
v75 QNN skel's DSP-side dependencies and remain stock firmware payloads.

`qnn/bin/caihong-npu-htp-self-test` is built from
`tools/caihong-npu-htp-self-test.c`. It creates a QNN ElementWiseAdd graph,
executes 1024 float32 elements on the HTP backend, and validates every output
with a bounded tolerance. Rebuild it with
`scripts/build-caihong-npu-htp-self-test.sh` and official QAIRT QNN headers.

These bundles are used only when `caihong-npu-info --self-test` or
`caihong-npu-info --htp-self-test` is requested. The normal information
command does not create a DSP process or a QNN graph.
