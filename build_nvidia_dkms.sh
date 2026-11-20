#!/bin/bash
# ================================================================
#  LIERA NVIDIA DRIVER PACKAGE BUILDER (DKMS)
#
#  Builds a lean .deb package from NVIDIA's official .run installer
#  that ships the driver SOURCE CODE + dkms.conf. DKMS recompiles
#  the kernel module automatically for EVERY future kernel
#  installation -- no manual rebuild per kernel version needed.
#
#  BRANCH DETECTION — the script picks the matching source kind
#  from the .run installer automatically:
#    kernel/       -> proprietary kernel module (Pascal-compatible)
#    kernel-open/  -> NVIDIA's open modules (require GSP firmware,
#                     i.e. TURING OR NEWER — non-functional on Pascal!)
#  Branch <  590: kernel/      (Pascal path — e.g. the 580 branch)
#  Branch >= 590: kernel-open/ (Turing+ path; Pascal is no longer
#                 supported there anyway, and NVIDIA only maintains
#                 the open modules on those branches)
#  If the preferred directory is missing (changed layout) the
#  script falls back to the other one automatically.
#
#  IMPORTANT: This script only builds the driver PACKAGE. It
#  installs NOTHING on this system.
#
#  Usage:
#     bash build_nvidia_dkms.sh /path/to/NVIDIA-Linux-x86_64-580.159.04.run
#
#  Result: liera-nvidia-580-dkms_580.159.04-1_amd64.deb
#  lands in ./nvidia-packages/<VERSION>/ — the shared output
#  directory for ALL NVIDIA packages of that version (the
#  userspace packages from build_nvidia_userspace.sh land in
#  the same folder).
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

# Extract version from file name, e.g.
# NVIDIA-Linux-x86_64-580.159.04.run -> 580.159.04
NVVERSION="$(basename "$RUNFILE" | grep -oP '(?<=x86_64-)[0-9]+\.[0-9]+(\.[0-9]+)?')"
if [ -z "$NVVERSION" ]; then
    echo "ERROR: could not read the version number from the file name."
    echo "        Expected pattern: NVIDIA-Linux-x86_64-VERSION.run"
    exit 1
fi

PKG_NAME="liera-nvidia-${NVVERSION%%.*}-dkms"   # e.g. liera-nvidia-580-dkms
PKG_REVISION="1"
WORKDIR="$(pwd)/nvidia-dkms-build"
# Shared output directory: all .debs of one driver version
# (DKMS + userspace + 32bit) are collected under
# nvidia-packages/<version>/ — a single place that can be copied
# into a repo or onto the Liera ISO wholesale.
OUTDIR="$(pwd)/nvidia-packages/${NVVERSION}"

echo ""
echo "========================================================"
echo "  Liera NVIDIA DKMS package builder -- ${NVVERSION}"
echo "========================================================"
echo ""
echo "  Source:  $RUNFILE"
echo "  Package: ${PKG_NAME} v${NVVERSION}-${PKG_REVISION}"
echo ""

for cmd in dpkg-deb realpath; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: '$cmd' is missing. sudo apt install dpkg-dev"
        exit 1
    fi
done

rm -rf "$WORKDIR"
mkdir -p "$WORKDIR" "$OUTDIR"
cd "$WORKDIR"

# ---------------------------------------------------------------
# STEP 1: extract only the kernel module sources
# ---------------------------------------------------------------
# --extract-only unpacks the .run archive WITHOUT starting the
# interactive nvidia-installer. From it we need exactly one kernel
# source directory, selected by branch (see header comment).
#
# kernel/ and kernel-open/ must never be copied together: the file
# names are identical and would overwrite each other.
echo "[1/5] Extracting driver sources..."
chmod +x "$RUNFILE"
"$RUNFILE" --extract-only --target extracted >/dev/null

# Pick the source directory by branch (see header comment):
# < 590 = proprietary kernel/, >= 590 = kernel-open/.
# Falls back to the other directory if the preferred one is
# missing — keeps the script robust against layout changes.
NVMAJOR="${NVVERSION%%.*}"
if [ "$NVMAJOR" -ge 590 ]; then
    KSRC_NAME="kernel-open"
else
    KSRC_NAME="kernel"
fi
if [ ! -d "extracted/${KSRC_NAME}" ]; then
    if [ "$KSRC_NAME" = "kernel-open" ]; then
        FALLBACK="kernel"
    else
        FALLBACK="kernel-open"
    fi
    echo "      Note: ${KSRC_NAME}/ missing, using ${FALLBACK}/ instead."
    KSRC_NAME="$FALLBACK"
fi
if [ ! -d "extracted/${KSRC_NAME}" ]; then
    echo "ERROR: neither extracted/kernel/ nor extracted/kernel-open/"
    echo "        found -- unexpected .run file layout, possibly a"
    echo "        different NVIDIA version with a changed structure."
    exit 1
fi
echo "      Using sources from: extracted/${KSRC_NAME}/"

SRC_DIR_NAME="${PKG_NAME}-${NVVERSION}"
SRC_DIR="${WORKDIR}/dkms-src/usr/src/${SRC_DIR_NAME}"
mkdir -p "$SRC_DIR"
cp -r extracted/${KSRC_NAME}/* "$SRC_DIR/"

echo "      ✓ Sources in: usr/src/${SRC_DIR_NAME}/"

# ---------------------------------------------------------------
# STEP 2: generate dkms.conf — build the module list dynamically
# so optional modules (e.g. nvidia-peermem) are only registered
# when their sources are actually present in the .run. Otherwise
# DKMS would fail on the missing directory during the build.
# ---------------------------------------------------------------
echo "[2/5] Generating dkms.conf..."

DKMS_CONF="${SRC_DIR}/dkms.conf"
cat > "$DKMS_CONF" << EOF
PACKAGE_NAME="${PKG_NAME}"
PACKAGE_VERSION="${NVVERSION}"

EOF

# /updates/dkms as destination: depmod prioritizes modules from
# updates/ over those from kernel/ — the DKMS modules therefore
# reliably win over any in-tree drivers that might exist.
MODULE_IDX=0
for mod in nvidia nvidia-modeset nvidia-drm nvidia-uvm nvidia-peermem; do
    # nvidia.c sits directly in the source root; the other modules
    # have their own subdirectories — both are covered here.
    if [ -f "${SRC_DIR}/${mod}.c" ] || [ -d "${SRC_DIR}/${mod}" ]; then
        cat >> "$DKMS_CONF" << EOF
BUILT_MODULE_NAME[${MODULE_IDX}]="${mod}"
BUILT_MODULE_LOCATION[${MODULE_IDX}]="."
DEST_MODULE_LOCATION[${MODULE_IDX}]="/updates/dkms"

EOF
        MODULE_IDX=$((MODULE_IDX + 1))
    else
        echo "      Note: ${mod} not in sources — omitted from dkms.conf."
    fi
done

# IMPORTANT: 'make' must be quoted. DKMS prepends KERNELRELEASE=<ver>
# to an unquoted make call — the NVIDIA Makefile reads that as
# "invoked by Kbuild" and runs `include $(src)/Kbuild` with an
# empty $(src) -> "/Kbuild not found".
# (Upstream comment: extracted/kernel-open/dkms.conf)
# REMAKE_INITRD is deprecated in dkms >= 3.x — the initramfs refresh
# is done by the postinst itself via update-initramfs.
cat >> "$DKMS_CONF" << 'EOF'
MAKE[0]="'make' -j$(nproc) NV_EXCLUDE_BUILD_MODULES='' KERNEL_UNAME=${kernelver} IGNORE_CC_MISMATCH=1 SYSSRC=${kernel_source_dir} modules"
CLEAN="'make' NV_EXCLUDE_BUILD_MODULES='' KERNEL_UNAME=${kernelver} SYSSRC=${kernel_source_dir} clean"

AUTOINSTALL="yes"
EOF

echo "      ✓ dkms.conf: ${MODULE_IDX} modules registered."

# ---------------------------------------------------------------
# STEP 3: debian/ control structure
# ---------------------------------------------------------------
echo "[3/5] Creating Debian package structure..."
PKGROOT="${WORKDIR}/pkgroot"
mkdir -p "${PKGROOT}/DEBIAN"
mkdir -p "${PKGROOT}/usr/src"
mkdir -p "${PKGROOT}/etc/modprobe.d"
cp -r "${WORKDIR}/dkms-src/usr/src/${SRC_DIR_NAME}" "${PKGROOT}/usr/src/"

# Bundle GSP firmware if the .run ships it. Pascal does not need
# it — but the same 580 branch also covers newer cards, where the
# package then works completely.
if [ -d "extracted/firmware" ]; then
    mkdir -p "${PKGROOT}/lib/firmware/nvidia/${NVVERSION}"
    cp extracted/firmware/*.bin "${PKGROOT}/lib/firmware/nvidia/${NVVERSION}/" 2>/dev/null || true
    echo "      ✓ GSP firmware bundled (lib/firmware/nvidia/${NVVERSION}/)."
fi

# nouveau blacklist + NVIDIA module options:
# Without this file nouveau (an in-kernel module) binds the GPU at
# boot first, and the nvidia module never gets a chance.
# modeset=1 + fbdev=1: KMS + clean console framebuffer on nvidia.
# Load kernel modules early and in parallel (modules-load.d) —
# runs with coldplug, not serially in front of the display manager.
mkdir -p "${PKGROOT}/etc/modules-load.d"
cat > "${PKGROOT}/etc/modules-load.d/liera-nvidia.conf" << 'EOF'
nvidia
nvidia-modeset
nvidia-drm
EOF

# Ordering unit: waits for the nvidia DRM device before a display
# manager starts (lightdm would otherwise start ~3s before
# nvidia-drm -> race: screen stays dark). nvidia-modprobe is
# instant when the module is already bound via modules-load.d.
mkdir -p "${PKGROOT}/etc/systemd/system"
cat > "${PKGROOT}/etc/systemd/system/liera-nvidia-drm.service" << 'EOF'
[Unit]
Description=NVIDIA DRM device ready before display manager
Before=display-manager.service lightdm.service
After=systemd-modules-load.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/nvidia-modprobe
TimeoutStartSec=20

[Install]
WantedBy=display-manager.service
EOF

cat > "${PKGROOT}/etc/modprobe.d/liera-nvidia.conf" << 'EOF'
# Liera NVIDIA driver
# disable nouveau so the proprietary module can bind the GPU
blacklist nouveau
options nouveau modeset=0

# KMS + early framebuffer for nvidia-drm
options nvidia-drm modeset=1
options nvidia-drm fbdev=1
EOF

# Note on Provides/Conflicts: the virtual package
# "liera-nvidia-dkms" is provided by ALL branch DKMS packages and
# declared as a conflict at the same time — a 580 DKMS package can
# never be installed next to a 595 one, without hardcoding the
# branch list ("mutually exclusive providers"). Debian control
# files themselves do not allow # comments — the explanation
# therefore lives here in the script.
cat > "${PKGROOT}/DEBIAN/control" << EOF
Package: ${PKG_NAME}
Version: ${NVVERSION}-${PKG_REVISION}
Section: non-free/kernel
Priority: optional
Architecture: amd64
Maintainer: Liera Linux <liera@liera>
Depends: dkms (>= 2.2.0.3), kmod, mokutil
Recommends: initramfs-tools
Provides: liera-nvidia-dkms
Conflicts: nvidia-kernel-dkms, nvidia-driver, nvidia-open-kernel-dkms, nvidia-legacy-340xx-driver, nvidia-legacy-390xx-driver, nvidia-tesla-driver, nvidia-kernel-common, nvidia-alternative, nvidia-installer-cleanup, glx-alternative-nvidia, glx-diversions, liera-nvidia-dkms
Description: NVIDIA driver (${NVVERSION}, branch ${NVMAJOR}) as DKMS source package
 NVIDIA driver of the ${NVMAJOR} branch. Rebuilds itself via DKMS
 automatically for every installed kernel.
 Contains the kernel module sources (branch < 590: proprietary
 kernel/, branch >= 590: kernel-open with GSP firmware).
 Disables nouveau at boot.
 .
 Source: NVIDIA-Linux-x86_64-${NVVERSION}.run (official installer)
EOF

# postinst: registers the module with DKMS. `dkms autoinstall`
# then builds and installs for ALL installed kernels that have
# matching headers — not just the running one. For future kernel
# updates DKMS handles this automatically via its own kernel hooks.
cat > "${PKGROOT}/DEBIAN/postinst" << EOF
#!/bin/bash
set -e

# ---------------------------------------------------------------
# Secure Boot preparation (MOK signing)
# Under Secure Boot the kernel only loads signed modules. DKMS
# signs during the build automatically once /var/lib/dkms/mok.key
# exists — we make sure the key is present and queue the
# enrollment request in the UEFI queue.
# On systems without Secure Boot nothing happens here.
# ---------------------------------------------------------------
SB_ACTIVE=0
if command -v mokutil >/dev/null 2>&1 && \
   mokutil --sb-state 2>/dev/null | grep -qi "enabled"; then
    SB_ACTIVE=1
    echo "Secure Boot is enabled — preparing MOK signing..."

    # Ensure the MOK key pair exists (self-signed certificate —
    # the same procedure DKMS uses internally)
    if [ ! -f /var/lib/dkms/mok.key ]; then
        mkdir -p /var/lib/dkms
        openssl req -new -x509 -newkey rsa:2048 -nodes -days 36500 \
            -keyout /var/lib/dkms/mok.key \
            -out /var/lib/dkms/mok.pub \
            -subj "/CN=Liera DKMS MOK/" 2>/dev/null || true
    fi

    # Queue enrollment in the UEFI queue: on the next reboot the
    # blue shim screen appears, the user selects "Enroll MOK" and
    # enters the one-time password.
    # One-time password: "liera" — only asked during enrollment,
    # never stored permanently.
    if [ -f /var/lib/dkms/mok.pub ]; then
        echo -e "liera\nliera" | mokutil --import /var/lib/dkms/mok.pub || true
        echo "NOTE: The MOK screen will appear on the next reboot."
        echo "         There: Enroll MOK -> Continue -> Yes -> Password: liera"
    fi
fi

systemctl enable liera-nvidia-drm.service 2>/dev/null || true
dkms add -m ${PKG_NAME} -v ${NVVERSION} --force || true
dkms autoinstall || {
    echo "WARNING: DKMS build failed."
    echo "         Check with: dkms status"
    echo "         Log: /var/lib/dkms/${PKG_NAME}/${NVVERSION}/build/make.log"
    echo "         If no kernel headers are installed:"
    echo "         install headers first, then 'dkms autoinstall'."
}
# Rebuild the initramfs so the nouveau blacklist also takes
# effect inside the initramfs and nouveau is not preloaded there.
if command -v update-initramfs >/dev/null 2>&1; then
    update-initramfs -u || true
fi
exit 0
EOF
chmod 755 "${PKGROOT}/DEBIAN/postinst"

# prerm: unregister cleanly before the package is removed
cat > "${PKGROOT}/DEBIAN/prerm" << EOF
#!/bin/bash
set -e
systemctl disable liera-nvidia-drm.service 2>/dev/null || true
dkms remove -m ${PKG_NAME} -v ${NVVERSION} --all || true
if command -v update-initramfs >/dev/null 2>&1; then
    update-initramfs -u || true
fi
exit 0
EOF
chmod 755 "${PKGROOT}/DEBIAN/prerm"

echo "      ✓ Package structure at ${PKGROOT}/"

# ---------------------------------------------------------------
# STEP 4: build the .deb
# ---------------------------------------------------------------
echo "[4/5] Building .deb package..."
DEBFILE="${PKG_NAME}_${NVVERSION}-${PKG_REVISION}_amd64.deb"
dpkg-deb --build --root-owner-group "$PKGROOT" "${WORKDIR}/${DEBFILE}"

# ---------------------------------------------------------------
# STEP 5: deliver the result
# ---------------------------------------------------------------
echo "[5/5] Copying finished package..."
cp "${WORKDIR}/${DEBFILE}" "${OUTDIR}/"

echo ""
echo "========================================================"
echo "  ✓ Done: ${OUTDIR}/${DEBFILE}"
echo "========================================================"
echo ""
echo "  The package registers the driver sources with DKMS and"
echo "  builds the modules for all installed kernels that have"
echo "  matching headers (dkms autoinstall)."
echo ""
echo "  Package contents:"
echo "    - kernel module sources (branch-aware: kernel/ or kernel-open/)"
echo "    - nouveau blacklist + nvidia-drm modeset/fbdev"
echo "    - GSP firmware (if present in the .run)"
echo ""
echo "  Test in VM/chroot:"
echo "     sudo dpkg -i ${OUTDIR}/${DEBFILE}"
echo "     dkms status                      # should show 'installed'"
echo "     lsmod | grep nvidia              # after reboot"
echo ""
echo "  Userspace components come from build_nvidia_userspace.sh"
echo "  (same version!), not from this package."
echo ""
