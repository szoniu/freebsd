#!/usr/bin/env bash
# gpu.sh — Graphics driver configuration on the mounted target (${MOUNTPOINT}).
#
# Runs in the OUTER process (no installer re-invocation inside the chroot —
# unlike the Linux family). Everything that touches the target goes through the
# chroot_* helpers (chroot_pkg / chroot_sh), which already honor DRY_RUN. Every
# fallible step is wrapped in try() so a pkg/firmware failure pops the recovery
# menu instead of aborting the whole install.
#
# FreeBSD-specific facts this module encodes (see DESIGN.md §3 "Graphics matrix"):
#   - DRM kmods (amdgpu/i915kms) load via `kld_list` in rc.conf, NEVER in
#     loader.conf — loading drm-kmod from loader.conf panics early boot
#     (drm-kmod #100). NVIDIA is the ONE exception that DOES use loader.conf,
#     and only for the modeset tunable (hw.nvidiadrm.modeset=1), not to load
#     the kmod.
#   - AMD Phoenix (Radeon 780M / gfx1103) needs the six explicit
#     ${AMD_PHOENIX_FW_FLAVORS}; a missing/wrong flavor PANICS the kernel at
#     amdgpu attach. detect_gpu() already resolved the right GPU_FW_FLAVORS.
#   - `kld_list` is a `+=` accumulator (WiFi, i2c-HID etc. may already have
#     appended to it before us) — we read it and append our token only if
#     absent, so we never clobber a prior entry or duplicate our own.
#   - The target user must be in the `video` group to reach /dev/dri.
source "${LIB_DIR}/protection.sh"

# _gpu_kld_list_append — idempotently append a token to rc.conf kld_list on the
# target. kld_list is space-separated and accumulated with `+=` across modules;
# a second `sysrc kld_list+=X` would happily add a duplicate, and a bare
# `sysrc kld_list=X` would clobber prior entries. So: read the current value
# inside the chroot, and only `+=` when the token is not already a whole-word
# member. The whole read-test-append runs as one /bin/sh script inside the
# target so it operates on the target's rc.conf, not the live medium's.
_gpu_kld_list_append() {
    local token="$1"
    [[ -z "${token}" ]] && return 0
    # ${token} is a fixed kmod name (amdgpu/i915kms/nvidia-modeset) — safe to
    # interpolate. `sysrc -n` prints the bare value (empty if unset). The `case`
    # word-match guards against substring false positives and against re-adding.
    try "Append ${token} to kld_list (idempotent)" \
        chroot_sh "cur=\$(sysrc -n kld_list 2>/dev/null || echo ''); \
case \" \${cur} \" in \
  *\" ${token} \"*) echo \"kld_list already contains ${token}\" ;; \
  *) sysrc kld_list+=\"${token}\" ;; \
esac"
}

# _gpu_write_amdgpu_freeze_note — GPD Pocket 4 only. On SOME FreeBSD 14.3 builds
# amdgpu in kld_list froze boot (DESIGN.md §3 / §5); the documented recovery is
# to drop the kld_list entry and `kldload amdgpu` AFTER reaching multi-user. We
# still set kld_list (the common case works and gives a graphical login out of
# the box) but leave the user a breadcrumb on the installed system. Written via
# chroot_sh so the note lands on the TARGET's /root, not the live medium, and so
# DRY_RUN is honored.
_gpu_write_amdgpu_freeze_note() {
    try "Write GPD Pocket 4 amdgpu boot-freeze fallback note" \
        chroot_sh 'notes=/root/POST-INSTALL-NOTES.txt
mkdir -p /root
touch "${notes}"; chmod 0600 "${notes}"
cat >> "${notes}" << "NOTEEOF"

=== GPU: amdgpu boot-freeze fallback (GPD Pocket 4) ===

The installer set `kld_list+="amdgpu"` in /etc/rc.conf so the 780M (Phoenix
gfx1103) comes up with KMS at boot. This is the working path on most builds.

HOWEVER: on some FreeBSD 14.3 kernels, loading amdgpu via kld_list has been
observed to FREEZE the boot before multi-user. If the machine hangs at boot
with a black/static screen after this install:

  1. Boot the loader menu, pick "Escape to loader prompt", then:
       set kld_list=""
       boot -s
     (or at the boot menu choose single-user mode).
  2. Once at the shell, neutralize the boot-time load:
       sysrc -x kld_list            # or: sysrc kld_list=""   to drop all
     then reboot to multi-user.
  3. Load amdgpu MANUALLY after you have a console, instead of at boot:
       kldload amdgpu
     If that works, make it persistent WITHOUT blocking boot by loading it
     late (e.g. from /etc/rc.local) rather than kld_list:
       echo "kldload amdgpu" >> /etc/rc.local
       chmod +x /etc/rc.local

NEVER move amdgpu into /boot/loader.conf — loading drm-kmod that early panics
the kernel (drm-kmod #100). kld_list (rc.conf) or a late kldload are the only
supported options.
NOTEEOF'
}

# gpu_install — Configure graphics on the target by ${GPU_VENDOR}.
# Called from the "gpu" install phase (tui/progress.sh -> _run_phase "gpu").
gpu_install() {
    local vendor="${GPU_VENDOR:-unknown}"
    einfo "=== Graphics configuration (vendor=${vendor}) ==="

    case "${vendor}" in
        amd)
            # drm-kmod metaport (auto-matches the running kernel's DRM version)
            # + the resolved firmware flavors. For Phoenix this is the six
            # split-packages; a missing/wrong one PANICS amdgpu at attach, so
            # install them in the SAME pkg transaction as drm-kmod. Word-split
            # of GPU_FW_FLAVORS is intentional (space-separated flavor list).
            # shellcheck disable=SC2086
            try "Install AMD DRM driver (${DRM_PKG} + firmware flavors)" \
                chroot_pkg "${DRM_PKG}" ${GPU_FW_FLAVORS}
            # Load amdgpu at boot via rc.conf kld_list — NEVER loader.conf.
            _gpu_kld_list_append "amdgpu"
            # GPD Pocket 4: kld_list+=amdgpu froze boot on some 14.3 builds.
            # We still set it (works on most), but document the kldload fallback.
            if [[ "${DEVICE_PROFILE:-generic}" == "gpd_pocket4" ]]; then
                ewarn "GPD Pocket 4: amdgpu via kld_list froze boot on some 14.3 builds — see POST-INSTALL note"
                _gpu_write_amdgpu_freeze_note
            fi
            ;;
        intel)
            # Intel iGPU: drm-kmod + GuC/HuC/DMC firmware, loaded via i915kms in
            # kld_list. There is NO single `gpu-firmware-intel-kmod` package (that
            # port is flavorized per generation); detect resolved GPU_FW_FLAVORS to
            # the vendor-agnostic `gpu-firmware-kmod` meta, which pulls all Intel
            # firmware flavors. Word-split is intentional. (Discrete Arc panics —
            # not handled.)
            # shellcheck disable=SC2086
            try "Install Intel DRM driver (${DRM_PKG} + firmware)" \
                chroot_pkg "${DRM_PKG}" ${GPU_FW_FLAVORS:-gpu-firmware-kmod}
            _gpu_kld_list_append "i915kms"
            ;;
        nvidia)
            # NVIDIA proprietary stack. nvidia-driver pulls the kmod; we still
            # add nvidia-modeset to kld_list so KMS comes up at boot. This is the
            # ONE vendor that uses loader.conf — and only for the modeset tunable
            # (hw.nvidiadrm.modeset=1), not to load the module. No Wayland.
            try "Install NVIDIA driver" chroot_pkg nvidia-driver
            try "Enable NVIDIA DRM modeset (loader.conf)" \
                chroot_sh "sysrc -f /boot/loader.conf hw.nvidiadrm.modeset=1"
            _gpu_kld_list_append "nvidia-modeset"
            ;;
        none|unknown|"")
            # No GPU resolved (or detection failed). Install the drm-kmod
            # metaport best-effort so a later manual `kldload` has the kmods
            # available, but don't touch kld_list (we don't know which to load).
            ewarn "GPU vendor '${vendor}' — installing ${DRM_KMOD_PKG} best-effort, no kld configured"
            try "Install DRM metaport (best-effort)" chroot_pkg "${DRM_KMOD_PKG}"
            ;;
        *)
            ewarn "Unhandled GPU vendor '${vendor}' — installing ${DRM_KMOD_PKG} best-effort"
            try "Install DRM metaport (best-effort)" chroot_pkg "${DRM_KMOD_PKG}"
            ;;
    esac

    # ALWAYS: put the target user in the `video` group so it can open /dev/dri/*
    # (required by Mesa/KMS clients regardless of vendor). `pw groupmod -m` adds
    # the member without disturbing existing members. Skip if no user was created.
    if [[ -n "${USERNAME:-}" ]]; then
        try "Add ${USERNAME} to video group" \
            chroot_sh "pw groupmod video -m ${USERNAME}"
    else
        ewarn "No USERNAME set — skipping 'video' group membership"
    fi

    einfo "=== Graphics configuration complete ==="
}
