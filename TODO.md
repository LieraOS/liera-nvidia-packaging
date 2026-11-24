# TODO — NVIDIA packaging & driver integration

## Open

- [ ] **RTX/Turing+ verification (top priority):** the
      `kernel-open`/GSP-path packages build cleanly but have never
      run on real hardware. Needed: install on a Turing-or-newer GPU,
      `dkms status`, `nvidia-smi`, Wayland session, Vulkan
      (`vulkaninfo`), suspend/resume. Reports welcome — see README
      "Help wanted".
- [ ] Pascal coverage beyond the maintainer's own machine:
      Vulkan/VDPAU/OpenCL, Steam/32-bit path, suspend/resume,
      hibernate.
- [ ] Calamares end-to-end test of the GPU selection (`lieragpu` job):
      explicit Pascal, explicit newer, auto with/without NVIDIA,
      skipped.
- [ ] Secure Boot project: signed shim + signed Liera kernel
      (MODULE_SIG), embed Liera certificate; afterwards optionally
      precompiled signed NVIDIA modules instead of DKMS
      (Ubuntu model: zero interaction).
- [ ] MOK enrollment UX for beginners: hint dialog at first login
      (password, shim screen walkthrough).
- [ ] CI compile-check: build `kernel/` and `kernel-open/` against
      several kernel header versions automatically (no GPU needed)
      — e.g. GitHub Actions pulling the `.run` at run time.
- [ ] Hardware-report issue template for test submissions
      (GPU model, branch, kernel, `dkms status`, works/broken).
- [ ] New NVIDIA versions: drop the `.run` next to the scripts +
      `bash build_nvidia_all.sh` — ISO sync happens automatically
      when `ISO_DRIVER_DIR` is set.

## Done

- [x] Batch builder `build_nvidia_all.sh` (all .run -> .deb per version)
- [x] Module-source detection in the DKMS script (proprietary
      kernel/ vs kernel-open/ GSP path, with fallback)
- [x] Test-compile against linux-headers-*liera*.deb before packaging
- [x] Mutual conflicts between branches (Provides/Conflicts trick,
      no hardcoded version lists)
- [x] Conflicts against the complete Debian NVIDIA layer incl.
      nvidia-alternative/glx-diversions
- [x] `libnvidia-egl-wayland1` as hard Depends + on the live image
- [x] MOK/Secure Boot preparation in postinst
- [x] GPU generation detection in the lieragpu job (PCI device ID
      threshold 0x1e02, class 0x03xxx filtered)
- [x] 32-bit Depends `libc6` instead of `libc6-i386` (clean multiarch)
- [x] **Verified on real Pascal hardware:** GTX 1060 6GB on the
      current LieraOS kernel — DKMS build, boot, Wayland session,
      GL working (the proprietary-`kernel/` package set installed
      from this pipeline)
- [x] English script output + bilingual docs for publication
