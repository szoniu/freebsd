#!/usr/bin/env bash
# chroot.sh — Run commands inside the freshly installed system at ${MOUNTPOINT}.
# The target is mounted by bsdinstall_mount_target (devfs + resolv.conf already
# in place). Unlike the Linux family there is NO installer re-invocation inside
# the chroot: our post-install phases run in the OUTER process and shell out via
# these helpers. pkg/sysrc/pw all exist in the installed base, so chroot works.
source "${LIB_DIR}/protection.sh"

# chroot_exec — run a command (argv form) inside the target.
chroot_exec() {
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        einfo "[DRY-RUN] chroot ${MOUNTPOINT}: $*"
        return 0
    fi
    chroot "${MOUNTPOINT}" "$@"
}

# chroot_sh — run a /bin/sh -c script inside the target (pipes, redirects,
# sysrc sequences). Pass the script as a single string.
chroot_sh() {
    local script="$1"
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        einfo "[DRY-RUN] chroot ${MOUNTPOINT} sh -c: ${script}"
        return 0
    fi
    chroot "${MOUNTPOINT}" /bin/sh -c "${script}"
}

# chroot_loader_conf_set — set a /boot/loader.conf tunable on the target WITHOUT
# sysrc. sysrc(8) validates the variable name as a shell identifier and refuses
# anything with a dot ("name contains characters not allowed in shell"), even
# though dotted knobs are exactly what loader.conf is made of — that killed 4 of
# our 5 loader.conf writes (vfs.zfs.arc_max, hw.psm.synaptics_support,
# hw.usb.usbhid.enable, hw.nvidiadrm.modeset). Undotted names like zfs_load do
# work through sysrc and are left alone.
#
# Idempotent by rewrite, not by append-if-missing: any existing line for the same
# knob is dropped and the new one appended, so a --resume (or a changed value
# between runs) leaves exactly one line instead of accumulating duplicates.
# The name's dots are escaped before they reach grep, otherwise `.` would match
# any character and a knob like hw.psm.x could delete an unrelated hw_psm_x line.
chroot_loader_conf_set() {
    local name="$1" value="$2"
    # Full `if`, not `[[ ... ]] && return` — as a standalone statement the latter
    # returns 1 whenever the test is false, which trips set -e (CLAUDE.md).
    if [[ -z "${name}" ]]; then
        return 0
    fi
    local esc="${name//./\\.}"
    try "loader.conf: ${name}=${value}" \
        chroot_sh "f=/boot/loader.conf; touch \"\$f\"; \
grep -v '^${esc}=' \"\$f\" > \"\$f.new\" 2>/dev/null || true; \
printf '%s=\"%s\"\\n' '${name}' '${value}' >> \"\$f.new\"; \
mv \"\$f.new\" \"\$f\""
}

# chroot_pkg — pkg install -y inside the target (non-interactive).
chroot_pkg() {
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        einfo "[DRY-RUN] chroot pkg install -y $*"
        return 0
    fi
    # env -u: strip the live-bootstrap pkg redirect (README sets PKG_DBDIR/
    # PKG_CACHEDIR onto a tmpfs so the small live /var doesn't overflow). If it
    # leaked into the chroot, the TARGET's package DB would land at a nonstandard
    # path and a freshly booted system would see zero installed packages.
    chroot "${MOUNTPOINT}" env -u PKG_DBDIR -u PKG_CACHEDIR -u TMPDIR ASSUME_ALWAYS_YES=yes pkg install -y "$@"
}

# chroot_teardown — unmount devfs + ESP and export the pool. Best-effort,
# idempotent; called from the EXIT trap and at the end of run_post_install.
chroot_teardown() {
    [[ "${DRY_RUN:-0}" == "1" ]] && { einfo "[DRY-RUN] would teardown target mounts"; return 0; }
    umount -f "${MOUNTPOINT}/dev" 2>/dev/null || true
    umount -f "${MOUNTPOINT}/boot/efi" 2>/dev/null || true
    if [[ "${FS_PROFILE:-zfs}" == "zfs" ]]; then
        zpool export "${ZFS_POOL_NAME:-${ZFS_POOL_NAME_DEFAULT}}" 2>/dev/null || true
    else
        umount -f "${MOUNTPOINT}" 2>/dev/null || true
    fi
}
