#!/bin/bash
# ================================================================
#  LIERA NVIDIA USERSPACE DRIVER PACKAGE BUILDER
#
#  Builds TWO .deb packages from NVIDIA's official .run installer:
#
#    1. liera-nvidia-<NV>-driver   -- 64-bit userspace (Xorg, Wayland/
#       GBM, OpenGL/EGL/Vulkan ICDs, nvidia-smi, nvidia-settings)
#    2. liera-nvidia-<NV>-32bit    -- 32-bit compatibility libs
#       (Steam/Wine/legacy games)
#
#  KEY DESIGN PRINCIPLE:
#  This package does NOT replace Debian's libglvnd/Mesa dispatchers.
#  NVIDIA registers itself through the loader metadata as intended:
#    - Vulkan:  nvidia_icd.json        -> /usr/share/vulkan/icd.d/
#    - EGL:     10_nvidia.json         -> /usr/share/glvnd/egl_vendor.d/
#    - OpenCL:  nvidia.icd             -> /etc/OpenCL/vendors/
#    - VDPAU:   libvdpau_nvidia        -> <libdir>/vdpau/
#    - GBM:     libnvidia-egl-gbm      -> <libdir>/gbm/
#  The GLVND dispatchers shipped by NVIDIA (libGL/libEGL/libGLX/
#  libOpenGL/libGLESv*/libGLdispatch/libvdpau.so/libOpenCL) are NOT
#  put into the package — they would collide at file level with the
#  Debian packages libgl1/libegl1/libglvnd0 and break the system GL.
#
#  Prerequisite: build_nvidia_dkms.sh has already been run for the
#  same version (kernel module package separate, see there).
#
#  Usage:
#     bash build_nvidia_userspace.sh /path/to/NVIDIA-Linux-x86_64-580.159.04.run
#
#  Result in ./nvidia-packages/<VERSION>/ — the shared output
#  directory for ALL NVIDIA packages of that version (the DKMS
#  package from build_nvidia_dkms.sh lands there too):
#     liera-nvidia-580-dkms_580.159.04-1_amd64.deb
#     liera-nvidia-580-driver_580.159.04-1_amd64.deb
#     liera-nvidia-580-32bit_580.159.04-1_i386.deb
# ================================================================

set -e
set -u

if [ $# -ne 1 ]; then
    echo "Usage: bash $0 /path/to/NVIDIA-Linux-x86_64-580.159.04.run"
    exit 1
fi

RUNFILE="$(realpath "$1")"
if [ ! -f "$RUNFILE" ]; then
    echo "ERROR: $RUNFILE not found."
    exit 1
fi

NVVERSION="$(basename "$RUNFILE" | grep -oP '(?<=x86_64-)[0-9]+\.[0-9]+(\.[0-9]+)?')"
if [ -z "$NVVERSION" ]; then
    echo "ERROR: could not read the version number from the file name."
    echo "        Expected pattern: NVIDIA-Linux-x86_64-VERSION.run"
    exit 1
fi

NVMAJOR="${NVVERSION%%.*}"
DRIVER_PKG="liera-nvidia-${NVMAJOR}-driver"
BIT32_PKG="liera-nvidia-${NVMAJOR}-32bit"
DKMS_PKG="liera-nvidia-${NVMAJOR}-dkms"
PKG_REVISION="1"
WORKDIR="$(pwd)/nvidia-userspace-build"
# Shared output directory with build_nvidia_dkms.sh:
# all .debs of one driver version are collected under
# nvidia-packages/<version>/.
OUTDIR="$(pwd)/nvidia-packages/${NVVERSION}"

# Libraries NVIDIA ships in the .run that Debian already provides
# via libglvnd/Mesa/ocl-icd/vdpau loader — they would create file
# collisions there. Skipped during copying.
is_glvnd_dispatcher() {
    # Only the bare dispatcher names — NOT the vendor implementations.
    # libGLESv1_CM_nvidia.so / libGLESv2_nvidia.so are NVIDIA-owned and
    # belong INSIDE the package (GLVND forwards to them).
    case "$(basename "$1")" in
        libGL.so*|libGLX.so*|libEGL.so|libEGL.so.[0-9]*|libOpenGL.so*|\
        libGLESv1_CM.so*|libGLESv2.so*|\
        libGLdispatch.so*|libvdpau.so*|libvdpau_trace.so*|libOpenCL.so*|\
        libnvidia-egl-wayland.so*)
            return 0 ;;
        *)  return 1 ;;
    esac
}

echo ""
echo "========================================================"
echo "  Liera NVIDIA userspace package builder -- ${NVVERSION}"
echo "========================================================"
echo ""

for cmd in dpkg-deb realpath find; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: '$cmd' is missing. sudo apt install dpkg-dev findutils"
        exit 1
    fi
done

rm -rf "$WORKDIR"
mkdir -p "$WORKDIR" "$OUTDIR"
cd "$WORKDIR"

# ---------------------------------------------------------------
# STEP 1: extract the .run file
# ---------------------------------------------------------------
echo "[1/6] Extracting .run file..."
chmod +x "$RUNFILE"
"$RUNFILE" --extract-only --target extracted >/dev/null
cd extracted

if [ ! -f "nvidia-installer" ]; then
    echo "ERROR: extracted/nvidia-installer not found -- unexpected layout."
    exit 1
fi

# ---------------------------------------------------------------
# STEP 2: auto-detect 32-bit files
# ---------------------------------------------------------------
echo "[2/6] Detecting 32-bit compatibility files..."

if [ ! -f ".manifest" ]; then
    echo "ERROR: .manifest not found -- cannot reliably detect"
    echo "        32-bit files. Aborting instead of guessing."
    exit 1
fi

mapfile -t COMPAT32_FILES < <(grep -i "compat32" .manifest | awk '{print $1}' | sort -u)
echo "      ${#COMPAT32_FILES[@]} 32-bit entries found in manifest."

if [ "${#COMPAT32_FILES[@]}" -eq 0 ]; then
    echo "      WARNING: no compat32 entries found in manifest."
    echo "      ${BIT32_PKG} may be built EMPTY."
fi

# ---------------------------------------------------------------
# STEP 3: package structure for -driver
# ---------------------------------------------------------------
echo "[3/6] Building structure for ${DRIVER_PKG}..."
DRIVER_ROOT="${WORKDIR}/driver-pkgroot"
LIBDIR="${DRIVER_ROOT}/usr/lib/x86_64-linux-gnu"
mkdir -p "${DRIVER_ROOT}/DEBIAN"
mkdir -p "$LIBDIR"
mkdir -p "${LIBDIR}/vdpau"          # VDPAU drivers must go into the subdirectory
mkdir -p "${LIBDIR}/gbm"            # GBM backend for Wayland
mkdir -p "${DRIVER_ROOT}/usr/bin"
mkdir -p "${DRIVER_ROOT}/usr/share/man/man1"
mkdir -p "${DRIVER_ROOT}/usr/share/vulkan/icd.d"
mkdir -p "${DRIVER_ROOT}/usr/share/vulkan/implicit_layer.d"
mkdir -p "${DRIVER_ROOT}/usr/share/glvnd/egl_vendor.d"
mkdir -p "${DRIVER_ROOT}/etc/OpenCL/vendors"
mkdir -p "${DRIVER_ROOT}/usr/lib/xorg/modules/drivers"
mkdir -p "${DRIVER_ROOT}/usr/lib/xorg/modules/extensions"
mkdir -p "${DRIVER_ROOT}/usr/lib/systemd/system"

# 64-bit libraries — with special destinations for VDPAU/GBM/Xorg
# modules and skipping the GLVND dispatchers (file conflict with
# Debian). -type f AND -type l: NVIDIA ships SONAME symlinks;
# without them the linker cannot find the library.
find . -maxdepth 1 -name "*.so*" \( -type f -o -type l \) | while read -r f; do
    fname="$(basename "$f")"
    if printf '%s\n' "${COMPAT32_FILES[@]}" | grep -qx "$fname" 2>/dev/null; then
        continue  # goes into the 32bit package
    fi
    if is_glvnd_dispatcher "$fname"; then
        echo "      - skipped (GLVND dispatcher, comes from Debian): $fname"
        continue
    fi
    case "$fname" in
        libvdpau_nvidia*)      cp -P "$f" "${LIBDIR}/vdpau/" ;;
        libnvidia-egl-gbm*)    cp -P "$f" "${LIBDIR}/gbm/" ;;
        libglxserver_nvidia*)  cp -P "$f" "${DRIVER_ROOT}/usr/lib/xorg/modules/extensions/" ;;
        *)                     cp -P "$f" "${LIBDIR}/" ;;
    esac
done

# Xorg driver module
[ -f "./nvidia_drv.so" ] && cp "./nvidia_drv.so" "${DRIVER_ROOT}/usr/lib/xorg/modules/drivers/"

# nvidia_drv.so loads the GLX server by unversioned name
for glxserver in "${DRIVER_ROOT}"/usr/lib/xorg/modules/extensions/libglxserver_nvidia.so.*; do
    [ -f "$glxserver" ] && ln -sf "$(basename "$glxserver")" \
        "${DRIVER_ROOT}/usr/lib/xorg/modules/extensions/libglxserver_nvidia.so"
done

# --- Loader metadata: without these files Vulkan/EGL/OpenCL will
# never find the NVIDIA driver, even if all libraries exist ---
[ -f "./nvidia_icd.x86_64.json" ] && cp "./nvidia_icd.x86_64.json" "${DRIVER_ROOT}/usr/share/vulkan/icd.d/"
[ -f "./nvidia_icd.json" ]        && cp "./nvidia_icd.json" "${DRIVER_ROOT}/usr/share/vulkan/icd.d/"
[ -f "./nvidia_layers.json" ]     && cp "./nvidia_layers.json" "${DRIVER_ROOT}/usr/share/vulkan/implicit_layer.d/"
[ -f "./10_nvidia.json" ]         && cp "./10_nvidia.json" "${DRIVER_ROOT}/usr/share/glvnd/egl_vendor.d/"
[ -f "./nvidia.icd" ]             && cp "./nvidia.icd" "${DRIVER_ROOT}/etc/OpenCL/vendors/"

# EGL External Platform: GBM (wlroots/labwc!) and Wayland/X11 platforms.
# Without 15_nvidia_gbm.json EGL cannot find an NVIDIA vendor on the
# GBM device -> compositor falls back to Mesa, EGLImage fails, black
# screen. 10_nvidia_wayland.json is deliberately NOT shipped: it
# belongs to libnvidia-egl-wayland, which intentionally comes from
# Debian's libnvidia-egl-wayland1 — Debian already ships that JSON;
# shipping it twice would abort installation as a file conflict.
mkdir -p "${DRIVER_ROOT}/usr/share/egl/egl_external_platform.d"
for j in 15_nvidia_gbm.json 09_nvidia_wayland2.json \
         20_nvidia_xcb.json 20_nvidia_xlib.json; do
    [ -f "./${j}" ] && cp "./${j}" "${DRIVER_ROOT}/usr/share/egl/egl_external_platform.d/"
done

# The GBM JSON dlopens "libnvidia-egl-gbm.so.1" from the normal search
# path -> the .so.1 symlink goes into the main dir, not gbm/.
for gbm_lib in "${DRIVER_ROOT}"/usr/lib/x86_64-linux-gnu/gbm/libnvidia-egl-gbm.so.*.*; do
    [ -f "$gbm_lib" ] && ln -sf "gbm/$(basename "$gbm_lib")" \
        "${DRIVER_ROOT}/usr/lib/x86_64-linux-gnu/libnvidia-egl-gbm.so.1"
done

# GBM backend for wlroots & co: Mesa's libgbm loads a backend named
# <kerneldriver>_gbm.so from <libdir>/gbm/ per DRM node. For
# nvidia-drm that is "nvidia-drm_gbm.so" -> libnvidia-allocator.so.1
# (NVIDIA manifest).
for alloc_lib in "${DRIVER_ROOT}"/usr/lib/x86_64-linux-gnu/libnvidia-allocator.so.*.*; do
    [ -f "$alloc_lib" ] || continue
    ln -sf "$(basename "$alloc_lib")" \
        "${DRIVER_ROOT}/usr/lib/x86_64-linux-gnu/libnvidia-allocator.so.1"
    ln -sf "../libnvidia-allocator.so.1" \
        "${DRIVER_ROOT}/usr/lib/x86_64-linux-gnu/gbm/nvidia-drm_gbm.so"
done

# Tools + man pages
for tool in nvidia-smi nvidia-settings nvidia-xconfig nvidia-debugdump \
            nvidia-cuda-mps-control nvidia-cuda-mps-server \
            nvidia-persistenced nvidia-powerd nvidia-bug-report.sh \
            nvidia-sleep.sh; do
    # Newer .run payloads keep nvidia-sleep.sh under systemd/ —
    # without it nvidia-suspend.service dies with 203/EXEC and the
    # GPU state is lost on suspend (compositor crash on resume).
    if [ -f "./${tool}" ]; then
        cp "./${tool}" "${DRIVER_ROOT}/usr/bin/" 2>/dev/null || true
    elif [ -f "./systemd/${tool}" ]; then
        cp "./systemd/${tool}" "${DRIVER_ROOT}/usr/bin/" 2>/dev/null || true
    fi
done

# nvidia-modprobe: setuid-root helper that creates the
# /dev/nvidia* device nodes (the kernel module does NOT do this
# itself). Without it nvidia-smi/CUDA fail — "couldn't communicate
# with the NVIDIA driver".
if [ -f "./nvidia-modprobe" ]; then
    cp "./nvidia-modprobe" "${DRIVER_ROOT}/usr/bin/"
    chmod 4755 "${DRIVER_ROOT}/usr/bin/nvidia-modprobe"
else
    echo "      WARNING: nvidia-modprobe missing in the extraction."
fi

# udev rule: create device nodes automatically as soon as the
# driver binds an NVIDIA display device (PCI class 0x03*, vendor
# 0x10de). nvidia-modprobe loads the module on demand itself and
# creates /dev/nvidia0, /dev/nvidiactl etc.
mkdir -p "${DRIVER_ROOT}/usr/lib/udev/rules.d"
cat > "${DRIVER_ROOT}/usr/lib/udev/rules.d/71-nvidia-devnodes.rules" << 'EOF'
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x03*", RUN+="/usr/bin/nvidia-modprobe"
EOF
find . -maxdepth 1 -name "*.1.gz" -exec cp {} "${DRIVER_ROOT}/usr/share/man/man1/" \; 2>/dev/null || true
# Man pages may also live in a subdirectory
[ -d "./man" ] && find ./man -name "*.gz" -exec cp {} "${DRIVER_ROOT}/usr/share/man/man1/" \; 2>/dev/null || true

# Xorg Device section: without it autoconfig falls back to
# modesetting/nouveau -> glamor fails on nvidia-drm -> llvmpipe.
# With this directive Xorg takes nvidia_drv.so and gets real GLX.
mkdir -p "${DRIVER_ROOT}/etc/X11/xorg.conf.d"
cat > "${DRIVER_ROOT}/etc/X11/xorg.conf.d/20-nvidia.conf" << 'EOF'
Section "Device"
    Identifier "nvidia"
    Driver     "nvidia"
EndSection
EOF

# systemd units for suspend/resume/powerd (in the .run partly as
# files, partly in the systemd/ subdirectory)
for unit in nvidia-suspend.service nvidia-resume.service \
            nvidia-hibernate.service nvidia-powerd.service; do
    [ -f "./${unit}" ] && cp "./${unit}" "${DRIVER_ROOT}/usr/lib/systemd/system/" 2>/dev/null || true
done
[ -d "./systemd" ] && find ./systemd -name "*.service" -exec cp {} "${DRIVER_ROOT}/usr/lib/systemd/system/" \; 2>/dev/null || true

echo "      ✓ ${DRIVER_ROOT} populated."

cat > "${DRIVER_ROOT}/DEBIAN/control" << EOF
Package: ${DRIVER_PKG}
Version: ${NVVERSION}-${PKG_REVISION}
Section: non-free/x11
Priority: optional
Architecture: amd64
Multi-Arch: foreign
Maintainer: Liera Linux <liera@liera>
Depends: ${DKMS_PKG} (= ${NVVERSION}-${PKG_REVISION}), libc6, libx11-6, libxext6, libxcb1, libglvnd0, libgl1, libglx0, libegl1, libopengl0, libgles2, libvulkan1, libvdpau1, ocl-icd-libopencl1, libwayland-client0, libnvidia-egl-wayland1
Recommends: ${BIT32_PKG} (= ${NVVERSION}-${PKG_REVISION})
Provides: liera-nvidia-driver
Conflicts: nvidia-driver, nvidia-kernel-dkms, xserver-xorg-video-nvidia, nvidia-open, nvidia-legacy-340xx-driver, nvidia-legacy-390xx-driver, nvidia-tesla-driver, nvidia-kernel-common, nvidia-alternative, nvidia-installer-cleanup, glx-alternative-nvidia, glx-diversions, liera-nvidia-driver
Description: NVIDIA graphics driver (${NVVERSION}) -- userspace
 Contains the Xorg driver, Wayland/GBM support, OpenGL/EGL/Vulkan
 libraries with ICD registration (GLVND/Vulkan loader/OpenCL) plus
 nvidia-smi and nvidia-settings.
 .
 Recommends ${BIT32_PKG} for 32-bit games/Steam/Wine compatibility --
 installed by default but removable independently.
 .
 Source: NVIDIA-Linux-x86_64-${NVVERSION}.run (official installer)
EOF

# postinst: SONAME safety net — if the .run extraction lost a
# symlink it is reconstructed from the ELF SONAME.
cat > "${DRIVER_ROOT}/DEBIAN/postinst" << 'EOF'
#!/bin/bash
set -e
LIBDIR="/usr/lib/x86_64-linux-gnu"
if command -v readelf >/dev/null 2>&1; then
    for f in "${LIBDIR}"/libnvidia-*.so.* "${LIBDIR}"/libcuda.so.* "${LIBDIR}"/libnvcuvid.so.*; do
        [ -f "$f" ] || continue
        soname="$(readelf -d "$f" 2>/dev/null | grep -oP '(?<=Library soname: \[)[^\]]+')"
        [ -z "$soname" ] && continue
        base="$(basename "$f")"
        [ "$soname" != "$base" ] && ln -sf "$base" "${LIBDIR}/${soname}" 2>/dev/null || true
    done
fi
ldconfig
exit 0
EOF
chmod 755 "${DRIVER_ROOT}/DEBIAN/postinst"

cat > "${DRIVER_ROOT}/DEBIAN/postrm" << 'EOF'
#!/bin/bash
set -e
# Clean up self-created symlinks on removal
if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
    find /usr/lib/x86_64-linux-gnu -xtype l -lname '*nvidia*' -delete 2>/dev/null || true
    find /usr/lib/x86_64-linux-gnu -xtype l -lname '*cuda*' -delete 2>/dev/null || true
fi
ldconfig
exit 0
EOF
chmod 755 "${DRIVER_ROOT}/DEBIAN/postrm"

# ---------------------------------------------------------------
# STEP 4: package structure for -32bit
# ---------------------------------------------------------------
echo "[4/6] Building structure for ${BIT32_PKG}..."
BIT32_ROOT="${WORKDIR}/bit32-pkgroot"
BIT32_LIBDIR="${BIT32_ROOT}/usr/lib/i386-linux-gnu"
mkdir -p "${BIT32_ROOT}/DEBIAN"
mkdir -p "$BIT32_LIBDIR"
mkdir -p "${BIT32_LIBDIR}/vdpau"
mkdir -p "${BIT32_LIBDIR}/gbm"

# The whole 32/ subdirectory is the source of truth for compat32
# content. Same filter rules as the 64-bit package: skip GLVND
# dispatchers (come from Debian :i386), VDPAU/GBM into their
# subdirectories, JSON metadata into icd.d.
if [ -d "./32" ]; then
    find ./32 -mindepth 1 -maxdepth 1 \( -type f -o -type l \) | while read -r f; do
        fname="$(basename "$f")"
        if is_glvnd_dispatcher "$fname"; then
            continue
        fi
        case "$fname" in
            libvdpau_nvidia*)   cp -P "$f" "${BIT32_LIBDIR}/vdpau/" ;;
            libnvidia-egl-gbm*) cp -P "$f" "${BIT32_LIBDIR}/gbm/" ;;
            *.json)             mkdir -p "${BIT32_ROOT}/usr/share/vulkan/icd.d"
                                cp "$f" "${BIT32_ROOT}/usr/share/vulkan/icd.d/" ;;
            *)                  cp -P "$f" "${BIT32_LIBDIR}/" ;;
        esac
    done
else
    echo "      WARNING: no 32/ subdirectory found in the extraction."
fi

FOUND_32BIT_FILES=$(find "${BIT32_LIBDIR}" \( -type f -o -type l \) 2>/dev/null | wc -l)
echo "      ✓ ${FOUND_32BIT_FILES} files/symlinks packed into ${BIT32_PKG}."

cat > "${BIT32_ROOT}/DEBIAN/control" << EOF
Package: ${BIT32_PKG}
Version: ${NVVERSION}-${PKG_REVISION}
Section: non-free/libs
Priority: optional
Architecture: i386
Maintainer: Liera Linux <liera@liera>
Depends: ${DRIVER_PKG} (= ${NVVERSION}-${PKG_REVISION}), libc6
Description: NVIDIA driver (${NVVERSION}) -- 32-bit compatibility
 32-bit OpenGL/EGL/Vulkan libraries for NVIDIA GPUs.
 Required for 32-bit games under Steam and Wine.
 .
 Can be removed independently from the rest of the driver
 (apt remove ${BIT32_PKG}) if no 32-bit applications are used.
EOF

cat > "${BIT32_ROOT}/DEBIAN/postinst" << 'EOF'
#!/bin/bash
set -e

# Same SONAME safety net as the 64-bit package
LIBDIR="/usr/lib/i386-linux-gnu"
if ! command -v readelf >/dev/null 2>&1; then
    echo "WARNING: readelf is missing (package binutils) -- symlinks cannot"
    echo "         be created safely. Please 'apt install binutils' and"
    echo "         then run 'dpkg --configure -a' again."
else
    for f in "${LIBDIR}"/*.so.*; do
        [ -f "$f" ] || continue
        soname="$(readelf -d "$f" 2>/dev/null | grep -oP '(?<=Library soname: \[)[^\]]+')"
        [ -z "$soname" ] && continue
        base="$(basename "$f")"
        [ "$soname" != "$base" ] && ln -sf "$base" "${LIBDIR}/${soname}" 2>/dev/null || true
        bare="${soname%.so.*}.so"
        [ ! -e "${LIBDIR}/${bare}" ] && ln -sf "$soname" "${LIBDIR}/${bare}" 2>/dev/null || true
    done
fi

ldconfig
exit 0
EOF
chmod 755 "${BIT32_ROOT}/DEBIAN/postinst"

cat > "${BIT32_ROOT}/DEBIAN/postrm" << 'EOF'
#!/bin/bash
set -e
if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
    find /usr/lib/i386-linux-gnu -xtype l -lname '*nvidia*' -delete 2>/dev/null || true
fi
ldconfig
exit 0
EOF
chmod 755 "${BIT32_ROOT}/DEBIAN/postrm"

# ---------------------------------------------------------------
# STEP 5: build both .deb packages
# ---------------------------------------------------------------
echo "[5/6] Building .deb packages..."
DRIVER_DEB="${DRIVER_PKG}_${NVVERSION}-${PKG_REVISION}_amd64.deb"
BIT32_DEB="${BIT32_PKG}_${NVVERSION}-${PKG_REVISION}_i386.deb"

dpkg-deb --build --root-owner-group "$DRIVER_ROOT" "${WORKDIR}/${DRIVER_DEB}"

if [ "$FOUND_32BIT_FILES" -gt 0 ]; then
    dpkg-deb --build --root-owner-group "$BIT32_ROOT" "${WORKDIR}/${BIT32_DEB}"
else
    echo "      ${BIT32_PKG} will NOT be built (no 32-bit files found)."
fi

# ---------------------------------------------------------------
# STEP 6: deliver the results
# ---------------------------------------------------------------
echo "[6/6] Copying finished packages..."
cp "${WORKDIR}/${DRIVER_DEB}" "${OUTDIR}/"
[ -f "${WORKDIR}/${BIT32_DEB}" ] && cp "${WORKDIR}/${BIT32_DEB}" "${OUTDIR}/"

echo ""
echo "========================================================"
echo "  ✓ Done."
echo "========================================================"
echo ""
ls -lh "${OUTDIR}"/*.deb
echo ""
echo "  Check contents BEFORE production use:"
echo "     dpkg -c ${OUTDIR}/${DRIVER_DEB} | less"
echo "  Expected entries include:"
echo "     usr/share/vulkan/icd.d/nvidia_icd*.json"
echo "     usr/share/glvnd/egl_vendor.d/10_nvidia.json"
echo "     usr/lib/x86_64-linux-gnu/vdpau/libvdpau_nvidia.so*"
echo "     usr/lib/x86_64-linux-gnu/gbm/libnvidia-egl-gbm.so*"
echo ""
echo "  Installation order (in VM/chroot):"
echo "     1. liera-nvidia-${NVMAJOR}-dkms   (kernel module)"
echo "     2. ${DRIVER_DEB}"
echo "     3. ${BIT32_DEB:-"(if present)"}"
echo ""
echo "  Multiarch for item 3:"
echo "     sudo dpkg --add-architecture i386 && sudo apt update"
echo ""
