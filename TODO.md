# Caihong Linux TODO

## High priority

- [x] Fix `vkmark`: it can enumerate the Adreno 750 GPU but does not start the
  benchmark. Root cause: with GNOME at 2.5x scale, `wl_output.scale` reports 3
  and vkmark sets `wl_surface.set_buffer_scale(3)` on an 800x600 (or 2120-tall
  fullscreen) buffer, which mutter rejects as a protocol error; Mesa's explicit
  sync acquire then blocks forever. Use a size divisible by 3 (for example
  `vkmark -s 900x600`) or `--winsys headless`.
- [x] Enable hardware video encoding/decoding in OBS Studio. The Iris codec
  works (`qcom_iris` + `videocc_sm8550`, OEM-signed `vpu33_4v.mbn`, shipped in
  `caihong-firmware` 0.1.0-101). The Copr `ffmpeg-free-1:8.1.3-1.fc44.caihong1`
  fixes the padded-height `__memcpy_generic()` crash and the missing extradata,
  and enables the h264/hevc V4L2 M2M decoders. The Copr package
  `obs-studio-plugin-v4l2m2m` adds "V4L2 M2M H.264/HEVC (Hardware)" to the
  Advanced output mode encoder list (Simple mode has a hard-coded list).
  Verified on the device: 1080p30 MKV recording and RTMP streaming with both
  codecs, and every packet decodes with a software decoder. `ffmpeg-free` has
  no software h264/hevc decoder (only the `noopenh264` stub), so h264 decoding
  always uses Iris.
- [ ] Investigate UFS `OCS error from controller = 4` bursts with full
  register dumps. They appear during heavy writes (for example a large
  systemd-coredump) and were already present before the Iris change.
- [ ] Fix USB and charging recovery after automatic suspend: after waking with
  the power key, external USB devices receive no power, USB charging is not
  detected, the status bar does not show charging, and the battery level stops
  decreasing.
- [ ] Add a working automatic-brightness enable/disable switch and restore the
  full manual brightness range.
- [ ] Fix front and back camera capture. OBS can enumerate both devices, but
  both produce black frames, and the upstream ISP software does not resolve it.

## Medium priority

- [ ] Reduce the approximately one-second delay when waking the display with
  the power key.

## Low priority

- [ ] Make the OnePlus Pencil Pro appear in GNOME `Graphics Tablets` and
  preserve pressure/tilt configuration. Add a libwacom tablet description and
  matching udev hwdb entry, then verify `libwacom-list-local-devices`, GNOME
  Settings, and pressure events on the device.
- [ ] Investigate the pen connection delay after magnetic attachment and the
  Bluetooth HID versus NT36532E tablet input split. This involves the kernel
  event and transport path and is lower priority than the desktop usability
  issues above.
- [ ] Fix the Iris encoder kernel issues found by OBS hardware encoding:
  - Iris passes `V4L2_CID_MPEG_VIDEO_GOP_SIZE` unchanged to
    `HFI_PROP_MAX_GOP_FRAMES`, and the firmware counts that value as P-frames
    after the I-frame. A 2 s interval at 30 fps therefore gives a keyframe
    every 61 frames instead of 60. The driver default `2 * DEFAULT_FPS - 1`
    already expects this. Translate the value in
    `drivers/media/platform/qcom/iris`, or check how upstream handles it.
  - The encoded streams have no VUI colour description (no
    `video_signal_type`), so the colour space and range are unspecified. Pass
    the OUTPUT queue colorimetry to the firmware.
  - Bitrate control mode (CBR/VBR) cannot be selected through FFmpeg's
    v4l2m2m wrapper. Check that `V4L2_CID_MPEG_VIDEO_BITRATE_MODE` works and
    consider exposing it in the plugin.
