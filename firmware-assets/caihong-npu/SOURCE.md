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

The bundle is intentionally used only when `caihong-npu-info --self-test` is
requested. The normal information command does not create a DSP process.
