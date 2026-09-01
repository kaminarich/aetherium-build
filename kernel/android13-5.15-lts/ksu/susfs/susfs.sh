#!/usr/bin/env bash

# ======================================================
# 🧬 SuSFS — shared apply logic (any KSU fork, android13-5.15-lts)
# ======================================================
# Repo: https://gitlab.com/simonpunk/susfs4ksu
# Ported from the android14-6.1-lts variant of this script.
#
# Only ReSukiSU is supported on 5.15 for now: pershoot's KernelSU-Next
# susfs fork (the KSUNEXT pairing) only maintains android14-6.1
# branches, and no SukiSU-Ultra integration exists for this version
# yet (no sukisu.sh beside this file).
if [ "$KERNEL_VARIANT" = "SUKISU" ]; then
    error "SuSFS+SukiSU is not supported on kernel 5.15 yet (no sukisu.sh integration) — build without SuSFS or use ReSukiSU."
elif [ "$KERNEL_VARIANT" = "KSUNEXT" ]; then
    error "SuSFS+KernelSU-Next is not supported on kernel 5.15 (pershoot's susfs fork has no 5.15 branch) — build without SuSFS or use ReSukiSU."
fi

SUSFS_REF="${SUSFS_RESUKISU_REF:-}"
SUSFS_REPO="https://gitlab.com/simonpunk/susfs4ksu.git"
SUSFS_BRANCH="gki-android13-5.15"

KSU_DIR="${KSU_DIR:-${KERNEL_SRC}/KernelSU}"
SUSFS_DIR="/tmp/susfs4ksu"
PATCHER_DIR="${LUMINAIRE_PATCH_DIR}/kernel/android13-5.15-lts/ksu/susfs"

log "Cloning SuSFS (${SUSFS_BRANCH})..."
[ -d "$SUSFS_DIR" ] && rm -rf "$SUSFS_DIR"
git config --global http.connectTimeout 30
git config --global http.lowSpeedLimit 1000
git config --global http.lowSpeedTime 30
if [ -n "${SUSFS_REF:-}" ]; then
    log "Pinning SuSFS to ${SUSFS_REF}"
    mkdir -p "$SUSFS_DIR"
    (
        cd "$SUSFS_DIR"
        git init -q
        git remote add origin "$SUSFS_REPO"
        run_quiet git fetch --depth=1 origin "$SUSFS_REF" && git checkout -q FETCH_HEAD
    ) || {
        warn "SuSFS: server doesn't support fetching bare SHA — falling back to full clone"
        rm -rf "$SUSFS_DIR"
        retry 3 run_quiet git clone -q -b "$SUSFS_BRANCH" "$SUSFS_REPO" "$SUSFS_DIR" \
            || error "SuSFS: full clone fallback failed after 3 attempts!"
        (cd "$SUSFS_DIR" && git checkout -q "$SUSFS_REF") \
            || error "SuSFS: ${SUSFS_REF} not found on ${SUSFS_BRANCH} even after full clone!"
    }
else
    retry 3 run_quiet git clone -q --depth=1 -b "$SUSFS_BRANCH" "$SUSFS_REPO" "$SUSFS_DIR" \
        || error "SuSFS clone failed after 3 attempts!"
fi

log "Copying SuSFS source files..."
cp "${SUSFS_DIR}/kernel_patches/fs/susfs.c"                  "${KERNEL_SRC}/fs/susfs.c"
cp "${SUSFS_DIR}/kernel_patches/include/linux/susfs.h"       "${KERNEL_SRC}/include/linux/susfs.h"
cp "${SUSFS_DIR}/kernel_patches/include/linux/susfs_def.h"   "${KERNEL_SRC}/include/linux/susfs_def.h"
log "SuSFS source files copied ✅"

log "Applying SuSFS kernel patch..."
KERNEL_PATCH="${SUSFS_DIR}/kernel_patches/50_add_susfs_in_gki-android13-5.15.patch"
if [ ! -f "$KERNEL_PATCH" ]; then
    # Don't return/exit here — a missing/renamed patch file upstream must
    # not skip the Kconfig injection and CONFIG_KSU_SUSFS enablement
    # further down. fix_namespace.py's own anchor-missing check will still
    # catch it hard if the underlying source structure changed too.
    warn "SuSFS kernel patch not found at ${KERNEL_PATCH} — skipping patch step, continuing with Kconfig/config setup"
elif patch -p1 --fuzz=3 --dry-run --reverse -d "$KERNEL_SRC" < "$KERNEL_PATCH" > /dev/null 2>&1; then
    log "SuSFS kernel patch already applied, skipping."
else
    # Pre-patch: this tree carries #include <trace/hooks/blk.h> after
    # "internal.h" in fs/namespace.c (ACK vendor hook), but the 5.15 SuSFS
    # patch's context was written without it. Remove it temporarily so the
    # patch can match, then restore after. Same dance the 6.1 script does
    # for sublevel >= 157.
    BLK_REMOVED=0
    if grep -q '^#include <trace/hooks/blk\.h>$' "${KERNEL_SRC}/fs/namespace.c"; then
        log "Pre-patch: removing blk.h from namespace.c for context match..."
        sed -i '/^#include <trace\/hooks\/blk\.h>$/d' "${KERNEL_SRC}/fs/namespace.c"
        BLK_REMOVED=1
    fi

    patch -p1 --fuzz=3 --forward -d "$KERNEL_SRC" < "$KERNEL_PATCH" \
        && log "SuSFS kernel patch applied ✅" \
        || warn "SuSFS kernel patch: some hunks failed — continuing"

    # Post-patch: restore blk.h if it was removed and patch didn't re-add it
    if [ "$BLK_REMOVED" -eq 1 ] && ! grep -qF '#include <trace/hooks/blk.h>' "${KERNEL_SRC}/fs/namespace.c"; then
        log "Post-patch: restoring blk.h to namespace.c..."
        sed -i '/^#include "internal\.h"$/a #include <trace\/hooks\/blk.h>' "${KERNEL_SRC}/fs/namespace.c"
        grep -qF '#include <trace/hooks/blk.h>' "${KERNEL_SRC}/fs/namespace.c" \
            || error "SuSFS: failed to restore blk.h include in namespace.c — internal.h anchor may have changed upstream!"
    fi

    # Cleanup any leftover .rej files
    find "$KERNEL_SRC" -name "*.rej" -delete 2>/dev/null || true
fi

log "Fixing namespace.c susfs declarations (safety fallback)..."
python3 "${PATCHER_DIR}/fix_namespace.py" "${KERNEL_SRC}/fs/namespace.c" \
    || error "SuSFS: namespace.c fix failed!"
log "namespace.c fixed ✅"

rm -rf "$SUSFS_DIR"

log "Ensuring KSU_SUSFS Kconfig declarations exist..."
KSU_KCONFIG="${KSU_DIR}/kernel/Kconfig"
if [ -f "$KSU_KCONFIG" ] && grep -q "^config KSU_SUSFS$" "$KSU_KCONFIG"; then
    log "KSU_SUSFS already declared by this fork, skipping injection."
else
    python3 "${PATCHER_DIR}/kconfig_inject.py" "$KSU_KCONFIG" \
        || error "SuSFS: Kconfig inject failed!"
    log "KSU_SUSFS Kconfig injected ✅"
fi

log "Enabling SuSFS configs..."
if ! grep -q "^CONFIG_KSU_SUSFS=y" "${KERNEL_SRC}/arch/arm64/configs/gki_defconfig"; then
    cat >> "${KERNEL_SRC}/arch/arm64/configs/gki_defconfig" << 'CONFIGS'
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SUS_OVERLAYFS=y
CONFIG_KSU_SUSFS_TRY_UMOUNT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_SUS_MAP=y
CONFIG_KSU_SUSFS_SUS_SU=y
CONFIGS
fi
log "SuSFS configs enabled ✅"

log "SuSFS integrated ✅"
