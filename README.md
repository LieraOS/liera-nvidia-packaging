# LieraOS NVIDIA Driver Packaging

Build tooling for the proprietary NVIDIA driver packages shipped by
Liera: it turns NVIDIA's official `.run` installers into clean
`.deb` packages that integrate properly into Debian-based systems —
DKMS kernel module sources, GLVND/Mesa-friendly userspace, multiarch
(32-bit) compatibility libraries and Secure Boot preparation.

The scripts need only a Debian-ish userspace (`dpkg-deb`, `dkms`)
and work on any comparable system. The documented defaults reflect
the Liera build layout and can be redirected through environment
variables.

> **Status: experimental.** These scripts and the packages they
> produce are a work in progress and may need further adjustment.
> They are tested only on Liera, the Debian-based distribution,
> with the Liera kernel — not on other Debian-based distributions
> or their kernels. Use at your own risk.

## Two kernel-module paths

Every `.run` installer ships one of two module source trees — the
scripts detect which one is present and package it:

| Module path | Used by | Status here |
|---|---|---|
| `kernel/` (proprietary) | driver branches for pre-GSP hardware | **Verified on real hardware** — GTX 1060 6GB on the current Liera kernel: DKMS build, boot, Wayland session, GL all working |
| `kernel-open/` (GSP) | driver branches for Turing and newer | **Packages build cleanly but are UNTESTED on real hardware** — see [Help wanted](#help-wanted-turing-testers) |

The test-compile step in `build_nvidia_all.sh` only verifies that
the kernel modules **compile** against the target kernel headers.
It says nothing about runtime behaviour — module loading, display
output, Wayland, suspend. That distinction matters.

## What gets built

Per `.run` file — any number of driver versions side by side:

| Package | Contents |
|---|---|
| `liera-nvidia-<BR>-dkms` | kernel module sources + dkms.conf (5 modules: nvidia, modeset, drm, uvm, peermem), nouveau blacklist, GSP firmware where present, MOK/Secure Boot preparation, DRM-ready ordering unit |
| `liera-nvidia-<BR>-driver` | 64-bit vendor libraries, Vulkan/EGL/OpenCL ICDs, GBM backend, VDPAU, Xorg driver + modules, tools (nvidia-smi, nvidia-settings, …), systemd suspend/resume units, udev devnode rule |
| `liera-nvidia-<BR>-32bit` | i386 compatibility libraries (Steam/Wine) |

Output lands in `nvidia-packages/<VERSION>/`.

## Usage

1. Download `.run` installer(s) from <https://www.nvidia.com/drivers>
   and place them **next to the scripts**. They are not downloaded
   automatically — NVIDIA's licence does not allow redistributing
   them (~400 MB each), so they are provided by the user only.
2. Run the batch builder:

   ```bash
   bash build_nvidia_all.sh
   ```

   It processes every `NVIDIA-Linux-x86_64-*.run` found, in version
   order:

   1. **Test-compile** the kernel modules against a kernel-headers
      `.deb` — the exact headers DKMS will see on the target
      system. A failing compile skips packaging for that version;
      log: `nvidia-packages/test-build-<VERSION>.log`.
   2. `build_nvidia_dkms.sh` → the DKMS package.
   3. `build_nvidia_userspace.sh` → driver + 32-bit packages.
   4. Optionally sync the results into an ISO/driver directory
      (`ISO_DRIVER_DIR`).

   Both sub-scripts can also be run individually with a `.run`
   file as argument.

## Environment variables

| Variable | Purpose | Default |
|---|---|---|
| `KERNEL_HEADERS_DEB` | explicit path to a `linux-headers-*.deb` for the test compile | newest `linux-headers-*liera*.deb` found in `ISO_PACKAGES_DIR` |
| `ISO_PACKAGES_DIR` | directory searched for header packages | a `packages.chroot` directory relative to the checkout |
| `KERNEL_BUILD_DIR` | fallback: kernel build tree containing `linux-*/` | a `liera-kernel-build` directory relative to the checkout |
| `ISO_DRIVER_DIR` | sync target for the built `.deb` files; `"off"` disables syncing | a live-build `includes.binary` directory relative to the checkout |
| `SKIP_TEST_BUILD=1` | skip the compile check entirely | off |
| `FORCE_BUILD=1` | package even if the compile check fails | off |

The path defaults match the Liera build checkout. If no suitable
kernel headers are found, the script warns and continues without
the test-compile — nothing breaks, but you lose the pre-flight
check. Point the variables at your own headers and output dir, or
set `ISO_DRIVER_DIR=off`, to run fully standalone.

## Design decisions

- **Module path detection:** the scripts package whichever source
  tree the `.run` ships — `kernel/` on branches that still carry
  the proprietary module sources, `kernel-open/` where NVIDIA has
  moved to the open, GSP-firmware-based modules — with automatic
  fallback to the other directory on layout changes.
- **GLVND discipline:** the packages ship *vendor implementations
  only*. NVIDIA's dispatcher copies (`libGL.so`, `libEGL.so`, …)
  are skipped — they would collide with Debian's
  `libgl1`/`libegl1`/`libglvnd0` at file level and break the
  system GL. NVIDIA registers through the loader metadata instead.
- **Mutual exclusion:** every branch package `Provides` +
  `Conflicts` on the virtual names `liera-nvidia-dkms` /
  `liera-nvidia-driver`, so two generations can never be installed
  in parallel without hardcoding branch lists. All packages also
  conflict with the complete Debian NVIDIA stack including the
  `nvidia-alternative`/diversion mechanism.
- **Kernel independence:** DKMS recompiles the modules for every
  installed kernel with matching headers — the packages themselves
  are kernel-version-agnostic. New kernel series can still break
  the compile (upstream API changes); that is what the test-build
  step exists for.

## Secure Boot

The DKMS package prepares MOK signing in its `postinst` (key under
`/var/lib/dkms/mok.key`, enrollment queued via `mokutil`, one-time
password `liera` at the blue shim screen). Full Secure Boot
operation additionally requires a signed shim/bootloader and a
signed kernel — tracked in `TODO.md`.

## Help wanted: Turing+ testers

Packages for the `kernel-open`/GSP path build correctly but have
never run on real hardware here. If you have a Turing-or-newer
NVIDIA GPU, the checklist is short:

```bash
sudo apt install ./liera-nvidia-*-dkms_*.deb ./liera-nvidia-*-driver_*.deb
dkms status            # module should show 'installed' for your kernel
# reboot, then:
nvidia-smi             # GPU should be listed
lsmod | grep nvidia    # modules loaded
```

Plus: does the Wayland session come up, does Vulkan work
(`vulkaninfo`), does suspend/resume survive? Reports of what works
and what breaks — ideally with GPU model, kernel version and
`dkms status` output — are the most valuable contribution right
now.

Second most valuable: compile-testing `kernel-open/` against
different kernel versions (no GPU needed at all — see
`KERNEL_HEADERS_DEB`/`KERNEL_BUILD_DIR` above).

## License

GPL-3.0-or-later — see `LICENSE`. This covers the build scripts.
The NVIDIA driver binaries themselves remain proprietary and are
subject to NVIDIA's licence; they are downloaded by the user and
never redistributed through this repository.

[Deutsche Version](README_de.md)
