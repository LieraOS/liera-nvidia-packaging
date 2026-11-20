# LieraOS NVIDIA Driver Packaging

Builds clean `.deb` packages from official NVIDIA `.run` installers
that integrate properly into Debian-based systems: DKMS kernel
module sources, GLVND/Mesa-friendly userspace, multiarch (32-bit)
compatibility libraries, and Secure Boot preparation.

Developed for [LieraOS](https://github.com/LieraOS) — a Wayland-first
gaming distribution — but the scripts only require a Debian-ish
userspace (`dpkg-deb`, `dkms`) and work standalone.

## Verification status — read this first

| Driver branch | Module path | Status |
|---|---|---|
| **580.x** (Pascal, GTX 10xx and older) | proprietary `kernel/` | **Verified on real hardware** — GTX 1060 6GB, self-built kernel 7.3.x: DKMS build, boot, Wayland session, GL all working |
| **595.x** (Turing and newer, RTX) | `kernel-open/` (GSP) | **Packages build cleanly but are UNTESTED on real hardware** — no RTX card available to the maintainer. See "Help wanted" below |

The test-compile step in `build_nvidia_all.sh` only verifies that the
kernel modules **compile** against the target kernel headers. It says
nothing about runtime behaviour — module loading, display output,
Wayland, suspend. That distinction matters.

If you own Turing/RTX hardware: feedback, test reports and fixes are
explicitly welcome — see [Help wanted](#help-wanted-rtxtesters).

## What gets built

Per `.run` file (any number of versions side by side):

| Package | Contents |
|---|---|
| `liera-nvidia-<BR>-dkms` | kernel module sources + dkms.conf (5 modules: nvidia, modeset, drm, uvm, peermem), nouveau blacklist, GSP firmware, MOK/Secure Boot preparation, DRM-ready ordering unit |
| `liera-nvidia-<BR>-driver` | 64-bit vendor libraries, Vulkan/EGL/OpenCL ICDs, GBM backend, VDPAU, Xorg driver + modules, tools (nvidia-smi, nvidia-settings, …), systemd suspend/resume units, udev devnode rule |
| `liera-nvidia-<BR>-32bit` | i386 compatibility libraries (Steam/Wine) |

Output lands in `nvidia-packages/<VERSION>/`.

## Usage

1. Download `.run` installer(s) from <https://www.nvidia.com/drivers>
   and place them **next to the scripts** — they are deliberately not
   downloaded automatically and must never be committed (NVIDIA
   licence, ~400 MB each; `.gitignore` covers them).
2. Run the batch builder:

   ```bash
   bash build_nvidia_all.sh
   ```

   It processes every `NVIDIA-Linux-x86_64-*.run` found, in version
   order:

   1. **Test-compile** the kernel modules against the newest
      `linux-headers-*liera*.deb` found in `ISO_PACKAGES_DIR`
      (exactly what DKMS sees on an installed Liera system).
      A failing compile skips packaging for that version —
      log: `nvidia-packages/test-build-<VERSION>.log`.
   2. `build_nvidia_dkms.sh` → the DKMS package.
   3. `build_nvidia_userspace.sh` → driver + 32-bit packages.
   4. Sync all built versions into the live-build tree
      (`includes.binary`), where the Calamares `lieragpu` job
      picks them up during installation.

   Both sub-scripts can also be run individually with a `.run`
   file as argument.

## Environment variables

| Variable | Purpose | Default |
|---|---|---|
| `KERNEL_HEADERS_DEB` | explicit path to a `linux-headers-*.deb` for the test compile | newest `linux-headers-*liera*.deb` in `ISO_PACKAGES_DIR` |
| `ISO_PACKAGES_DIR` | directory searched for header packages | `<scriptdir>/../../Liera/config/packages.chroot` |
| `KERNEL_BUILD_DIR` | fallback: kernel build tree containing `linux-*/` | `<scriptdir>/../kernel/liera-kernel-build` |
| `ISO_DRIVER_DIR` | sync target inside the live-build config; `"off"` disables syncing | `<scriptdir>/../../Liera/config/includes.binary/liera-drivers/nvidia` |
| `SKIP_TEST_BUILD=1` | skip the compile check entirely | off |
| `FORCE_BUILD=1` | package even if the compile check fails | off |

**Note on the defaults:** the `../../Liera/...` paths assume these
scripts live next to the LieraOS live-build tree (e.g. in a `tools/`
directory of a sibling checkout). If they are not found, the script
simply warns and continues without test-compile/sync — nothing
breaks, but you lose the pre-flight check. Point the variables at
your own kernel headers / output dir to restore full behaviour
outside the LieraOS layout.

## Design decisions

- **Branch detection:** `< 590` → proprietary `kernel/` (Pascal
  path), `>= 590` → `kernel-open/` (GSP path, Turing+). Automatic
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
password `liera` at the blue shim screen). Full Secure Boot operation
additionally requires a signed shim/bootloader and a signed kernel —
tracked in `TODO.md`.

## Help wanted: RTX/Turing+ testers

The 595-branch packages (`kernel-open`/GSP path) build correctly but
have never run on real hardware. If you have a Turing-or-newer
NVIDIA GPU, the checklist is short:

```bash
sudo apt install ./liera-nvidia-595-dkms_*.deb ./liera-nvidia-595-driver_*.deb
dkms status            # module should show 'installed' for your kernel
# reboot, then:
nvidia-smi             # GPU should be listed
lsmod | grep nvidia    # modules loaded
```

Plus: does the Wayland session come up, does Vulkan work
(`vulkaninfo`), does suspend/resume survive? Reports of what works
and what breaks — ideally with GPU model, kernel version and
`dkms status` output — are the most valuable contribution right now.

Second most valuable: compile-testing `kernel-open/` against
different kernel versions (no GPU needed at all — see
`KERNEL_HEADERS_DEB`/`KERNEL_BUILD_DIR` above).

## License

GPL-3.0-or-later — see `LICENSE`. This covers the build scripts.
The NVIDIA driver binaries themselves remain proprietary and are
subject to NVIDIA's licence; they are downloaded by the user and
never redistributed through this repository.
