<!-- SPDX-License-Identifier: GPL-2.0-only -->
<!-- Copyright (c) 2026 Osilvfe <osilvfe@gmail.com> -->

# Caihong Armada sources and licences

This experimental image is derived from the upstream
[Armada](https://github.com/armada-os/armada) stable OCI image. Armada's own
source code is distributed under GPL-2.0-or-later. Components installed by
Armada retain their individual licences and terms.

The image keeps Armada's complete gaming userspace, including Steam Client,
FEX, Proton, Gamescope and KDE Plasma. Steam Client is proprietary software
and remains subject to Valve's applicable Steam agreement and distribution
terms; its presence does not change the licence of this repository.

The Caihong kernel source is maintained at
[Osilvfe/linux](https://github.com/Osilvfe/linux). Project-authored Caihong
build scripts and utilities use the SPDX licence stated in each file. Device
firmware retains its vendor terms.
