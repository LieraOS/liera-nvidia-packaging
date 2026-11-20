#!/bin/bash
# ================================================================
#  LIERA NVIDIA BATCH BUILDER
#
#  Scans this directory for NVIDIA-Linux-x86_64-*.run installer
#  files and builds the complete Liera .deb package set for each
#  one, in version order:
#
#    * liera-nvidia-<branch>-dkms     (kernel module sources)
#    * liera-nvidia-<branch>-driver   (64-bit userspace)
#    * liera-nvidia-<branch>-32bit    (i386 compatibility libs)
#
#  Per run file it performs three steps:
#    1. Extract and TEST-COMPILE the kernel modules against the
#       newest Liera kernel source tree (fail fast before a broken
#       driver ever reaches the ISO)
#    2. Invoke build_nvidia_dkms.sh
#    3. Invoke build_nvidia_userspace.sh
#
#  Finally all built versions are synced into the Liera live-build
#  tree (includes.binary), where the Calamares lieragpu job picks
#  them up during installation.
#
#  Usage:
#     bash build_nvidia_all.sh
#
#  Optional environment overrides:
#     KERNEL_HEADERS_DEB explicit path to a linux-headers-*.deb used
#                        for the test compile (default: newest
#                        linux-headers-*-liera-*.deb found in
#                        ISO_PACKAGES_DIR)
#     ISO_PACKAGES_DIR   live-build packages.chroot directory to
#                        search for header packages
#                        (default: <scriptdir>/../../Liera/config/
#                         packages.chroot)
#     KERNEL_BUILD_DIR   kernel build dir containing linux-*/ trees,
#                        used as fallback when no headers .deb exists
#                        (default: <scriptdir>/../kernel/liera-kernel-build)
#     ISO_DRIVER_DIR     sync target inside the live-build config;
#                        "off" disables syncing
#                        (default: <scriptdir>/../../Liera/config/
#                         includes.binary/liera-drivers/nvidia)
#     SKIP_TEST_BUILD=1  skip the compile check
#     FORCE_BUILD=1      package even if the compile check fails
# ================================================================

set -e
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

KERNEL_HEADERS_DEB="${KERNEL_HEADERS_DEB:-}"
ISO_PACKAGES_DIR="${ISO_PACKAGES_DIR:-${SCRIPT_DIR}/../../Liera/config/packages.chroot}"
KERNEL_BUILD_DIR="${KERNEL_BUILD_DIR:-${SCRIPT_DIR}/../kernel/liera-kernel-build}"
ISO_DRIVER_DIR="${ISO_DRIVER_DIR:-${SCRIPT_DIR}/../../Liera/config/includes.binary/liera-drivers/nvidia}"
SKIP_TEST_BUILD="${SKIP_TEST_BUILD:-0}"
FORCE_BUILD="${FORCE_BUILD:-0}"

# Directory the extracted test-build environment lives in; cleaned
# up on exit.
TESTENV="$(mktemp -d)"
trap 'rm -rf "$TESTENV"' EXIT

echo ""
echo "========================================================"
echo "  Liera NVIDIA Batch Builder"
echo "========================================================"
echo ""

# ---------------------------------------------------------------
# Resolve what the test-compile builds AGAINST. Two sources, in
# order of fidelity:
#   1. The newest linux-headers-*liera*.deb from the live-build
#      packages.chroot — extracted into TESTENV. This mirrors
#      exactly what DKMS sees on the installed target system.
#   2. Fallback: the kernel source tree in KERNEL_BUILD_DIR. Needs
#      write access for `make modules_prepare` when Module.symvers
#      was cleaned — skipped silently if the tree is root-owned.
# ---------------------------------------------------------------
KERNEL_TREE=""   # becomes the SYSSRC path used by the test compile
if [ "$SKIP_TEST_BUILD" != "1" ]; then
    # Source 1: headers .deb (explicit override or newest in
    # ISO_PACKAGES_DIR)
    HDR_DEB="$KERNEL_HEADERS_DEB"
    if [ -z "$HDR_DEB" ] && [ -d "$ISO_PACKAGES_DIR" ]; then
        HDR_DEB="$(find "$ISO_PACKAGES_DIR" -maxdepth 1 -name 'linux-headers-*liera*.deb' | sort -V | tail -n1 || true)"
    fi
    if [ -n "$HDR_DEB" ] && [ -f "$HDR_DEB" ]; then
        echo "  Test build target: header package ${HDR_DEB##*/}"
        dpkg-deb -x "$HDR_DEB" "${TESTENV}/headers"
        KERNEL_TREE="$(find "${TESTENV}/headers/usr/src" -maxdepth 1 -type d -name 'linux-headers-*' | head -n1 || true)"
        if [ -z "$KERNEL_TREE" ]; then
            echo "  WARNING: package contains no usr/src/linux-headers-* —"
            echo "           test build will be skipped."
        fi
    fi

    # Source 2: kernel source tree fallback
    if [ -z "$KERNEL_TREE" ]; then
        SRC_TREE=""
        if [ -d "$KERNEL_BUILD_DIR" ]; then
            SRC_TREE="$(find "$KERNEL_BUILD_DIR" -maxdepth 1 -type d -name 'linux-*' | sort -V | tail -n1 || true)"
        fi
        if [ -n "$SRC_TREE" ] && [ -f "${SRC_TREE}/.config" ]; then
            echo "  Test build target: kernel tree ${SRC_TREE##*/}"
            if [ ! -f "${SRC_TREE}/Module.symvers" ]; then
                if make -C "$SRC_TREE" modules_prepare >/dev/null 2>&1; then
                    KERNEL_TREE="$SRC_TREE"
                else
                    echo "  WARNING: modules_prepare failed (tree may be"
                    echo "           root-owned) — test builds disabled."
                fi
            else
                KERNEL_TREE="$SRC_TREE"
            fi
        else
            echo "  WARNING: no usable kernel tree found —"
            echo "           test builds disabled."
        fi
    fi
else
    echo "  Test builds: disabled (SKIP_TEST_BUILD=1)"
fi
echo ""

# ---------------------------------------------------------------
# Collect all .run installers, sorted by version (580 < 595 < ...).
# ---------------------------------------------------------------
shopt -s nullglob
RUNS=( $(printf '%s\n' NVIDIA-Linux-x86_64-*.run | sort -V) )
shopt -u nullglob

if [ ${#RUNS[@]} -eq 0 ]; then
    echo "No NVIDIA-Linux-x86_64-*.run files in this directory."
    echo "Download drivers from https://www.nvidia.com/drivers"
    echo "and place the .run file(s) next to this script."
    exit 1
fi

echo "  Driver files found:"
for r in "${RUNS[@]}"; do echo "    - $r"; done
echo ""

# Track per-version results for the final summary.
declare -A RESULTS

# ---------------------------------------------------------------
# Choose the correct kernel-module source dir for a given major
# branch — the same rule build_nvidia_dkms.sh uses internally, so
# the test-compile exercises exactly what gets packaged:
#   < 590  -> kernel/      (proprietary module, Pascal path)
#   >= 590 -> kernel-open/ (GSP path, Turing and newer)
# Falls back to the other dir if the preferred one is missing.
# ---------------------------------------------------------------
pick_ksrc() {
    local extract_dir="$1" major="$2" ksrc
    if [ "$major" -ge 590 ]; then ksrc="kernel-open"; else ksrc="kernel"; fi
    if [ ! -d "${extract_dir}/${ksrc}" ]; then
        if [ "$ksrc" = "kernel-open" ]; then ksrc="kernel"; else ksrc="kernel-open"; fi
    fi
    if [ -d "${extract_dir}/${ksrc}" ]; then echo "$ksrc"; else echo ""; fi
}

# ---------------------------------------------------------------
# Main loop: per .run file -> test compile -> build both packages.
# A compile failure skips packaging for that version (unless
# FORCE_BUILD=1) and is reported in the summary.
# ---------------------------------------------------------------
for RUN in "${RUNS[@]}"; do
    VERSION="$(echo "$RUN" | grep -oP '(?<=x86_64-)[0-9]+\.[0-9]+(\.[0-9]+)?')"
    MAJOR="${VERSION%%.*}"

    echo "========================================================"
    echo "  Processing: ${RUN}  (Version ${VERSION}, Branch ${MAJOR})"
    echo "========================================================"

    if [ -n "$KERNEL_TREE" ]; then
        echo "  [TEST] Extracting for test build..."
        TESTDIR="$(mktemp -d)"
        chmod +x "${SCRIPT_DIR}/${RUN}"
        "${SCRIPT_DIR}/${RUN}" --extract-only --target "${TESTDIR}/src" >/dev/null

        KSRC="$(pick_ksrc "${TESTDIR}/src" "$MAJOR")"
        if [ -z "$KSRC" ]; then
            echo "  [TEST] ERROR: no kernel sources (kernel/ or"
            echo "         kernel-open/) found in the .run file."
            rm -rf "$TESTDIR"
            RESULTS["$VERSION"]="ERROR (no sources)"
            continue
        fi

        echo "  [TEST] Building modules from ${KSRC}/ against ${KERNEL_TREE##*/} ..."
        LOG="${SCRIPT_DIR}/nvidia-packages/test-build-${VERSION}.log"
        mkdir -p "${SCRIPT_DIR}/nvidia-packages"
        if make -C "${TESTDIR}/src/${KSRC}" \
                SYSSRC="${KERNEL_TREE}" \
                IGNORE_CC_MISMATCH=1 \
                -j"$(nproc)" modules >"$LOG" 2>&1; then
            echo "  [TEST] OK — compiles against the kernel."
        else
            echo "  [TEST] FAILED — log: ${LOG}"
            tail -n 15 "$LOG" | sed 's/^/         /'
            rm -rf "$TESTDIR"
            if [ "$FORCE_BUILD" != "1" ]; then
                RESULTS["$VERSION"]="SKIPPED (build failure)"
                continue
            fi
            echo "  [TEST] FORCE_BUILD=1 — packaging anyway."
        fi
        rm -rf "$TESTDIR"
    fi

    bash "${SCRIPT_DIR}/build_nvidia_dkms.sh" "${SCRIPT_DIR}/${RUN}"
    bash "${SCRIPT_DIR}/build_nvidia_userspace.sh" "${SCRIPT_DIR}/${RUN}"
    RESULTS["$VERSION"]="OK"
done

# ---------------------------------------------------------------
# Sync finished packages into the live-build tree. The lieragpu
# Calamares job scans this directory during installation and picks
# the right version per GPU choice — newest dir wins for
# "RTX or newer".
# ---------------------------------------------------------------
if [ "$ISO_DRIVER_DIR" != "off" ] && [ -d "$ISO_DRIVER_DIR" ]; then
    echo ""
    echo "========================================================"
    echo "  Syncing to includes.binary: ${ISO_DRIVER_DIR}"
    echo "========================================================"
    for VERSION in "${!RESULTS[@]}"; do
        [ "${RESULTS[$VERSION]}" = "OK" ] || continue
        mkdir -p "${ISO_DRIVER_DIR}/${VERSION}"
        cp "${SCRIPT_DIR}/nvidia-packages/${VERSION}/"*.deb \
           "${ISO_DRIVER_DIR}/${VERSION}/"
        echo "    ✓ ${VERSION}: $(ls "${ISO_DRIVER_DIR}/${VERSION}/" | wc -l) packages"
    done
else
    echo ""
    echo "  ISO sync disabled or target not found"
    echo "  (${ISO_DRIVER_DIR}) — packages are in ./nvidia-packages/"
fi

# ---------------------------------------------------------------
# Summary
# ---------------------------------------------------------------
echo ""
echo "========================================================"
echo "  DONE — result per version:"
echo "========================================================"
for VERSION in "${!RESULTS[@]}"; do
    echo "    ${VERSION}: ${RESULTS[$VERSION]}"
done
echo ""
ls -d "${SCRIPT_DIR}/nvidia-packages"/*/ 2>/dev/null | sed 's/^/    /'
echo ""
