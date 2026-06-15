#!/usr/bin/env bash
# tui/filesystem_select.sh — Root filesystem profile: ZFS (bectl) / UFS, + GELI
source "${LIB_DIR}/protection.sh"

# screen_filesystem_select — Choose the root filesystem profile and optional
# full-disk GELI encryption.
#
# FreeBSD has no ext4/btrfs/xfs split like the Linux siblings; the meaningful
# choice here is the bsdinstall *profile*:
#   zfs — root-on-ZFS (single-disk stripe vdev). Boot environments via bectl:
#         freebsd-update/pkg auto-snapshot before changes, rollback from the
#         loader menu. This is the recommended default.
#   ufs — single UFS root (soft-updates + journaling). Lower overhead, but NO
#         bectl / no boot environments / no snapshots.
#
# GELI_ROOT is full-disk geli encryption of the root pool/partition. It is OFF
# by default: boot-time unlock is not guaranteed on the quirky GPD Pocket 4 /
# Surface UEFI firmwares this installer targets, and a lost passphrase is
# unrecoverable. Treat it as opt-in for users who have tested it on the machine.
screen_filesystem_select() {
    local current="${FS_PROFILE:-zfs}"
    local on_zfs="off" on_ufs="off"
    case "${current}" in
        zfs) on_zfs="on" ;;
        ufs) on_ufs="on" ;;
        *)   on_zfs="on" ;;   # unknown/empty -> default to ZFS
    esac

    local choice
    choice=$(dialog_radiolist "Root Filesystem" \
        "zfs" "ZFS — boot environments via bectl, snapshots (recommended)" "${on_zfs}" \
        "ufs" "UFS — lower overhead, no bectl / no boot environments" "${on_ufs}") \
        || return "${TUI_BACK}"

    if [[ -z "${choice}" ]]; then
        return "${TUI_BACK}"
    fi

    FS_PROFILE="${choice}"
    export FS_PROFILE

    # ZFS vdev: this installer partitions a single target disk, so the pool is a
    # one-disk stripe (mirror/raidz need multiple disks we don't enumerate here).
    # For UFS there is no pool — clear the field so a stale value from a previous
    # ZFS pass / preset isn't carried into a UFS install.
    if [[ "${FS_PROFILE}" == "zfs" ]]; then
        ZFS_VDEV_TYPE="stripe"
    else
        ZFS_VDEV_TYPE=""
    fi
    export ZFS_VDEV_TYPE

    # Full-disk GELI encryption — opt-in. dialog_yesno returns 0=Yes, 1=No, and
    # 128 on ESC/abort (gum backend). Default is No; treat an explicit abort as
    # Back so the wizard doesn't silently fall through to an unencrypted install.
    local geli_rc=0
    dialog_yesno "Full-Disk Encryption (GELI)" \
        "Encrypt the entire root disk with GELI?\n\n\
This protects data at rest, but on this hardware:\n\n\
  - Boot-time unlock is NOT guaranteed on the quirky GPD Pocket 4 /\n\
    Surface UEFI firmware — TEST it before relying on it.\n\
  - A lost passphrase is UNRECOVERABLE: there is no backdoor or reset.\n\n\
Recommended: No, unless you have verified GELI boot-unlock on this\n\
exact machine.\n\n\
Enable GELI full-disk encryption?" || geli_rc=$?

    case "${geli_rc}" in
        0)
            GELI_ROOT=1
            ewarn "GELI full-disk encryption ENABLED — verify boot-unlock on this hardware"
            ;;
        128)
            # ESC/abort on the dialog — go back rather than assume an answer.
            return "${TUI_BACK}"
            ;;
        *)
            GELI_ROOT=0
            ;;
    esac
    export GELI_ROOT

    einfo "Filesystem: ${FS_PROFILE} (vdev=${ZFS_VDEV_TYPE:-n/a}, geli=${GELI_ROOT})"
    return "${TUI_NEXT}"
}
