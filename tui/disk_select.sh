#!/usr/bin/env bash
# tui/disk_select.sh — Disk selection (whole-disk auto only for v0.1)
#
# v0.1 supports whole-disk auto-partition ONLY. The destructive wipe +
# partition layout is owned by lib/bsdinstall.sh: bsdinstall's auto-ZFS
# (ZFSBOOT_DISKS) and our wipe helper both take a BARE device name
# (e.g. nda0) — never a /dev/ path — because gpart, sysctl kern.disks and
# ZFSBOOT_DISKS all speak bare GEOM provider names. So TARGET_DISK is stored
# bare here, matching the entries in AVAILABLE_DISKS.
#
# Dual-boot (shrink an existing OS, reuse the ESP) is a documented TODO — the
# Linux family ships an sfdisk-based shrink wizard, but FreeBSD has no in-base
# online shrinker for NTFS/ext4 and gpart's whole-disk wipe is the only safe
# v0.1 path. We therefore force PARTITION_SCHEME=auto and gate the destructive
# choice behind a typed ERASE confirmation whenever any OS is detected.
source "${LIB_DIR}/protection.sh"

# _disk_holds_detected_os — does the chosen bare disk own any partition that
# detect_installed_oses() flagged? DETECTED_OSES keys are partition devices in
# /dev/<prov> form (gpart providers: nda0p1, ada0s2, ...). A partition belongs
# to disk <d> when its name is "<d>p<N>" or "<d>s<N>". Echoes the first matched
# "OS-name @ /dev/part" line; empty output => no OS on this disk.
_disk_holds_detected_os() {
    local disk="$1" part osname
    for part in "${!DETECTED_OSES[@]}"; do
        # strip /dev/, then require the disk base followed by a p<N>/s<N> suffix
        local prov="${part#/dev/}"
        case "${prov}" in
            "${disk}"p[0-9]*|"${disk}"s[0-9]*)
                osname="${DETECTED_OSES[${part}]}"
                echo "${osname} @ ${part}"
                return 0
                ;;
        esac
    done
    return 0
}

screen_disk_select() {
    # --- Build the target-disk menu (PAIRS) from hardware detection ----------
    # get_disk_list_for_dialog emits "/dev/<name>\n<desc>\n" pairs; read them
    # into an args array so dialog_menu gets tag/desc pairs with NO prompt arg.
    local -a disk_items=()
    local tag desc
    while IFS= read -r tag && IFS= read -r desc; do
        [[ -z "${tag}" ]] && continue
        disk_items+=("${tag}" "${desc}")
    done < <(get_disk_list_for_dialog || true)

    if [[ ${#disk_items[@]} -eq 0 ]]; then
        dialog_msgbox "No Disks" \
            "No suitable installation disks were detected.\n\n\
The live medium is excluded automatically. Attach a target disk\n\
(NVMe/SATA/USB) and restart the installer.\n\n\
Cannot continue."
        return "${TUI_ABORT}"
    fi

    # --- Select target disk --------------------------------------------------
    # dialog Cancel -> non-zero -> treated as TUI_BACK.
    local selected
    selected=$(dialog_menu "Select Target Disk" "${disk_items[@]}") \
        || return "${TUI_BACK}"
    [[ -z "${selected}" ]] && return "${TUI_BACK}"

    # Menu tags carry the /dev/ prefix for readability; store TARGET_DISK BARE
    # (nda0) so gpart / ZFSBOOT_DISKS / our wipe helper consume it directly.
    local disk="${selected#/dev/}"

    # --- Partition scheme: whole-disk auto only (v0.1) -----------------------
    PARTITION_SCHEME="auto"
    export PARTITION_SCHEME

    # --- ERASE gate when this disk (or any disk) holds a detected OS ----------
    # Require a typed ERASE if EITHER the global OS scan found anything, OR the
    # chosen disk specifically owns a flagged partition. detect_installed_oses
    # also seeds DETECTED_OSES_SERIALIZED, so honor a non-empty serialized map
    # even if the live assoc array was not repopulated (e.g. preset reload).
    local os_on_disk=""
    if [[ -v DETECTED_OSES && ${#DETECTED_OSES[@]} -gt 0 ]]; then
        os_on_disk=$(_disk_holds_detected_os "${disk}")
    fi

    local oses_present=0
    if [[ -n "${os_on_disk}" ]]; then
        oses_present=1
    elif [[ -n "${DETECTED_OSES_SERIALIZED:-}" ]]; then
        oses_present=1
    elif [[ -v DETECTED_OSES && ${#DETECTED_OSES[@]} -gt 0 ]]; then
        oses_present=1
    fi

    if [[ "${oses_present}" == "1" ]]; then
        # Build a human-readable list of what dies (best-effort).
        local os_list=""
        if [[ -v DETECTED_OSES && ${#DETECTED_OSES[@]} -gt 0 ]]; then
            local p
            for p in "${!DETECTED_OSES[@]}"; do
                os_list+="  ${p}: ${DETECTED_OSES[${p}]}\n"
            done
        elif [[ -n "${DETECTED_OSES_SERIALIZED:-}" ]]; then
            local IFS='|' entry part name
            for entry in ${DETECTED_OSES_SERIALIZED}; do
                part="${entry%%=*}"; name="${entry#*=}"
                [[ -z "${part}" || -z "${name}" ]] && continue
                os_list+="  ${part}: ${name}\n"
            done
        fi

        local pointed=""
        [[ -n "${os_on_disk}" ]] && pointed="\nThe selected disk holds: ${os_on_disk}\n"

        dialog_msgbox "WARNING: Existing OS Detected" \
            "!!! DANGER !!!\n\n\
Auto-partitioning will WIPE THE ENTIRE DISK /dev/${disk} and\n\
PERMANENTLY DESTROY every operating system and all data on it.\n\
${pointed}\n\
Detected operating systems on this machine:\n\
${os_list}\n\
v0.1 does NOT support dual-boot (shrink/ESP reuse is a TODO).\n\
Whole-disk install is the only option.\n\n\
Type ERASE in the next dialog to confirm the wipe." || true

        local confirm
        confirm=$(dialog_inputbox "Confirm Wipe" \
            "Type ERASE to confirm destruction of ALL data on /dev/${disk}:" \
            "") || return "${TUI_BACK}"

        # Cancel/empty/anything-but-ERASE -> abort the choice, go back.
        if [[ "${confirm}" != "ERASE" ]]; then
            dialog_msgbox "Cancelled" \
                "Wipe not confirmed. You typed: '${confirm}'\n\n\
Returning to disk selection." || true
            return "${TUI_BACK}"
        fi
    else
        # No OS detected: still a destructive whole-disk operation — confirm.
        dialog_yesno "WARNING: Data Destruction" \
            "Auto-partitioning will DESTROY ALL DATA on:\n\n  /dev/${disk}\n\nAre you sure?" \
            || return "${TUI_BACK}"
    fi

    TARGET_DISK="${disk}"
    export TARGET_DISK

    einfo "Disk: ${TARGET_DISK} (scheme: ${PARTITION_SCHEME}, whole-disk wipe)"
    return "${TUI_NEXT}"
}
