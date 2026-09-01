#!/usr/bin/env bash

# ======================================================
# 🩹 CORE — binder / cpufreq stable catch-up
# ======================================================
# Lote 3: real fixes cherry-picked from mainline (torvalds/linux — the ACK
# GitHub mirror was confirmed stale vs what this kernel source actually
# syncs from), covering drivers/android/ (Binder) and drivers/cpufreq/.
# Same methodology as lote 1/2: verified with a real `git apply --check`
# against this tree, hand-adapted where the raw diff didn't apply as-is.
#
# Included (see lote3_binder_cpufreq.patch):
#   Binder:
#   - use same_thread_group() instead of ->group_leader in binder_mmap()
#   - use current_euid() for transaction sender identity instead of
#     task_euid(proc->tsk) (security-relevant: proc->tsk's EUID can go
#     stale after setuid(); Jann Horn, Google security team)
#   - don't abuse current->group_leader in binder_open()/binder_alloc_init()
#     (use current->tgid + get_task_struct() return value directly)
#
#   cpufreq:
#   - fix hotplug/suspend race during reboot (cpufreq_suspend() runs
#     without freeze_processes() on the kernel_restart() path, so CPU
#     hotplug can race it and free governor_data underneath — real NULL
#     deref) + related freq_qos_update_request() ordering fix in
#     cpufreq_online(), same commit
#   - fix re-boost not being reapplied to a CPU that came back online
#     while boost-all was active
#   - fix data races on per-CPU idle/nice baselines between sysfs
#     (update_lock) and the dbs work handler (update_mutex) — relevant
#     since ondemand/conservative are both active on purpose here
#   - fix cci_dev reference leak on mediatek-cpufreq probe failure
#     (relevant on any probe deferral during boot)
#   - fix stale prev_cpu_nice baseline when ignore_nice_load is toggled
#     via sysfs while dbs_update() is running concurrently (same
#     idle/nice family as the data-race fix above)
#
# Already confirmed fixed in this tree, nothing to do (found while
# verifying, not applied here — listed for the record):
#   - binder: "invalid inc weak" check already removed
#   - binder: %pK already replaced with %p in all 4 target call sites
#   - cpufreq: double-free in cpufreq_dbs_governor_init() error path
#     already fixed (kobject_put + goto, no double gov->exit())
#   - cpufreq: negative idle_time handling already fixed (idle_time
#     clamped to 0 at the source, no leftover (int) casts)
#
# Regenerated for LuminaireKernel-6.1 @ v6.1.180+: two fixes from the
# original bundle arrived via the linux-stable merges (v6.1.178 →
# v6.1.183) and their hunks were removed since they no longer apply in
# either direction:
#   - binder.c: binder_free_transaction() target_thread pinning
#     (spin_lock(&t->lock) + tmp_ref) and its dec_tmpref unpin
#   - cpufreq.c: cpufreq_suspend() cpus_read_lock()/cpus_read_unlock()
#     hotplug-race protection
# All remaining fixes are mainline backports that stable does not carry,
# verified to still be absent and to apply cleanly at v6.1.183.
#
# Skipped, feature-base not present in this tree (nothing to backport
# onto):
#   - binder: secctx size caching fix (depends on lsm_context refactor
#     this tree doesn't have)
#   - binder: UAF in binder_netlink_report() (binder_netlink.c/.h don't
#     exist here — feature never backported)
#   - cpufreq: NULL deref in cpufreq_online() on set_boost (the boost
#     mirroring logic this bug lives in doesn't exist in this tree's
#     cpufreq_online() at all)
#
# Deliberately NOT bundled — flagged by the batch author as needing
# dedicated investigation before applying, not ready:
#   - binder: UAF in binder_free_transaction() / binder_thread_release()
#     (f223d27a / 114a116a) — mainline already guards the relevant read
#     with spin_lock(&t->lock), a protection this tree's equivalent code
#     doesn't have. The lock's origin commit hasn't been traced yet, so
#     applying just these two would give a false sense of safety without
#     the real prerequisite. Top priority for the next batch, not this one.

PATCH_FILE="$(dirname "${BASH_SOURCE[0]}")/lote3_binder_cpufreq.patch"

# These catch-up patches were written, verified, and hand-adapted against the
# android14-6.1 tree only — running them against any other kernel version
# would just fail the apply check (or worse, fuzz onto wrong code).
if [ "${KERNEL_VERSION:-}" != "6.1" ]; then
    log "binder_cpufreq_catchup: skipped — lote3 (binder/cpufreq) patches are 6.1-only (this build is ${KERNEL_VERSION})."
    return 0 2>/dev/null || exit 0
fi


log "🩹 Applying binder/cpufreq stable catch-up (lote 3)..."
cd "${KERNEL_SRC}"

if git apply --check --reverse "$PATCH_FILE" > /dev/null 2>&1; then
    log "binder/cpufreq stable catch-up: already applied, skipping."
elif git apply --check "$PATCH_FILE" > /dev/null 2>&1; then
    git apply "$PATCH_FILE" || error "binder/cpufreq stable catch-up: apply failed!"
    log "binder/cpufreq stable catch-up: applied ✅"
else
    error "binder/cpufreq stable catch-up: does not apply cleanly — kernel source may have changed since this was written, needs re-verification!"
fi

cd "${ROOT_DIR}"

log "binder/cpufreq stable catch-up integrated ✅"
