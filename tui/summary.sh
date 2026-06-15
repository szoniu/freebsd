#!/usr/bin/env bash
# tui/summary.sh — Full summary + typed-YES confirmation + countdown (FreeBSD)
#
# Last wizard screen before the destructive install. It:
#   1. runs validate_config() — the pre-install safety gate (lib/config.sh); any
#      error returns the user to the previous screen with the list shown.
#   2. renders a complete review of every CONFIG_VAR the wizard set, translated
#      to FreeBSD terms (FS_PROFILE zfs/ufs + bectl, GELI root, .eli swap,
#      kld_list GPU plan + AMD Phoenix firmware flavors, seatd-based Wayland
#      DEs with no DM, login.conf locale class, vt .kbd keymap, device profile).
#   3. surfaces blocking hardware caveats inline (MT7922 WiFi has NO FreeBSD
#      driver -> WIFI_SUPPORTED=0; GPD Pocket 4 has no console rotation).
#   4. makes the whole-disk wipe explicit and requires the user to TYPE "YES"
#      (empty/Cancel -> TUI_BACK) followed by an abortable countdown.
#
# v0.1 is whole-disk auto-partition only (PARTITION_SCHEME=auto): there is no
# dual-boot/shrink/ESP-reuse path the Void sibling had, so the "preserved OS"
# branch is intentionally dropped — disk_select already gates any detected OS
# behind a typed ERASE.
source "${LIB_DIR}/protection.sh"

screen_summary() {
    # --- Pre-install validation -------------------------------------------
    # validate_config prints "- <error>" lines to stdout and returns non-zero
    # when the config is unusable. On failure show them and bounce back; the
    # ewarn advisories (e.g. UFS has no boot environments) do not fail it.
    local validation_errors
    validation_errors=$(validate_config) || {
        dialog_msgbox "Configuration Errors" \
            "Fix these issues before proceeding:\n\n${validation_errors}"
        return "${TUI_BACK}"
    }

    # --- Build the review text --------------------------------------------
    local summary=""
    summary+="=== Installation Summary ===\n\n"

    # Disk / filesystem. FS_PROFILE drives the whole partition+boot story:
    # zfs -> single-disk stripe pool + bectl boot environments; ufs -> plain
    # GPT + UFS root (no bectl). TARGET_DISK is stored bare (nda0) — show the
    # /dev/ form for readability.
    summary+="Target disk:  /dev/${TARGET_DISK:-?}\n"
    summary+="Partitioning: ${PARTITION_SCHEME:-auto} (whole-disk wipe)\n"
    summary+="Boot mode:    ${BOOT_TYPE:-auto}\n"
    if [[ "${FS_PROFILE:-zfs}" == "zfs" ]]; then
        summary+="Filesystem:   ZFS (pool ${ZFS_POOL_NAME:-${ZFS_POOL_NAME_DEFAULT:-zroot}}, ${ZFS_VDEV_TYPE:-stripe} vdev)\n"
        summary+="Boot envs:    bectl (snapshots + rollback)\n"
    else
        summary+="Filesystem:   UFS (soft-updates+journal, no bectl)\n"
    fi
    if [[ "${GELI_ROOT:-0}" == "1" ]]; then
        summary+="Encryption:   GELI full-disk (verify boot-unlock on this HW)\n"
    else
        summary+="Encryption:   none (root not encrypted)\n"
    fi

    # Swap: a dedicated freebsd-swap partition (optionally .eli one-time key) or
    # none. There is no zram/swapfile path on FreeBSD in this installer.
    if [[ "${SWAP_TYPE:-none}" == "partition" ]]; then
        summary+="Swap:         partition (${SWAP_SIZE_MIB:-?} MiB"
        if [[ "${SWAP_ENCRYPTION:-0}" == "1" ]]; then
            summary+=", encrypted .eli"
        fi
        summary+=")\n"
    else
        summary+="Swap:         none\n"
    fi
    summary+="\n"

    # System identity / localization.
    summary+="Hostname:     ${HOSTNAME:-freebsd}\n"
    summary+="Timezone:     ${TIMEZONE:-UTC}\n"
    summary+="Locale:       ${LOCALE:-en_US.UTF-8} (login.conf class: ${LOCALE_CLASS:-english})\n"
    summary+="Keymap:       ${KEYMAP:-us.kbd}\n"
    summary+="\n"

    # GPU + driver plan. The install applies it as
    #   pkg install ${DRM_PKG} ${GPU_FW_FLAVORS}; sysrc kld_list+=${GPU_KMOD}
    # (amdgpu/i915kms NEVER via loader.conf). NVIDIA is the exception:
    # nvidia-driver/nvidia-modeset, no DRM metaport, X11-only (no Wayland).
    if [[ "${HYBRID_GPU:-no}" == "yes" ]]; then
        summary+="GPU:          ${IGPU_DEVICE_NAME:-?} + ${DGPU_DEVICE_NAME:-?} (hybrid)\n"
    else
        summary+="GPU:          ${GPU_DEVICE_NAME:-${GPU_VENDOR:-unknown}} (${GPU_VENDOR:-unknown})\n"
    fi
    summary+="Driver:       kld_list+=${GPU_KMOD:-none}  pkg: ${DRM_PKG:-none}\n"
    if [[ -n "${GPU_FW_FLAVORS:-}" ]]; then
        summary+="GPU firmware: ${GPU_FW_FLAVORS}\n"
    fi
    summary+="\n"

    # Desktop + display manager. Wayland compositors (sway/niri/hyprland) and the
    # "none" server profile have NO display manager on FreeBSD — they start from a
    # tty login via seatd (there is no systemd-logind). DISPLAY_MANAGER reflects
    # that (it is "none" for those).
    if [[ "${DESKTOP_TYPE:-none}" == "none" ]]; then
        summary+="Desktop:      none (server / tty login)\n"
    else
        summary+="Desktop:      ${DESKTOP_TYPE}"
        if [[ -n "${DISPLAY_MANAGER:-}" && "${DISPLAY_MANAGER}" != "none" ]]; then
            summary+=" + ${DISPLAY_MANAGER}"
        else
            summary+=" (seatd, tty login)"
        fi
        summary+=" + PipeWire (user service)\n"
    fi
    [[ -n "${DESKTOP_EXTRAS:-}" ]] && summary+="DE apps:      ${DESKTOP_EXTRAS}\n"
    [[ "${ENABLE_HYPRLAND:-no}" == "yes" ]] && summary+="Hyprland:     ecosystem enabled\n"
    [[ "${ENABLE_NOCTALIA:-no}" == "yes" ]] && summary+="Noctalia:     ${NOCTALIA_COMPOSITOR:-hyprland} compositor\n"
    [[ "${ENABLE_GAMING:-no}" == "yes" ]] && summary+="Gaming:       Steam / wine / gamescope\n"
    [[ -n "${EXTRA_PACKAGES:-}" ]] && summary+="Extra pkgs:   ${EXTRA_PACKAGES}\n"
    summary+="\n"

    # User account + privilege tool. Only hashes are stored; nothing here echoes
    # a password. Groups default to wheel,operator,video (FreeBSD convention).
    summary+="Username:     ${USERNAME:-user}"
    [[ -n "${FULLNAME:-}" ]] && summary+=" (${FULLNAME})"
    summary+="\n"
    summary+="Groups:       ${USER_GROUPS:-wheel,operator,video}\n"
    summary+="Priv tool:    ${PRIV_TOOL:-doas}\n"

    # Device profile + opt-in peripheral tools (only show what is relevant).
    if [[ "${DEVICE_PROFILE:-generic}" != "generic" ]]; then
        summary+="\nDevice:       ${DEVICE_PROFILE}"
        if [[ "${UMPC_DETECTED:-0}" == "1" ]]; then
            summary+=" (${UMPC_VENDOR:-?} ${UMPC_MODEL:-UMPC})"
        elif [[ "${SURFACE_DETECTED:-0}" == "1" ]]; then
            summary+=" (${SURFACE_MODEL:-Surface})"
        fi
        summary+="\n"
        [[ -n "${PANEL_ROTATION:-}" ]] && summary+="Panel rotate: ${PANEL_ROTATION} (desktop layer; no console rotation)\n"
    fi
    [[ "${ENABLE_IPTSD:-no}" == "yes" ]] && summary+="Surface tools: iptsd touchscreen\n"

    # Show the full review. ESC/Cancel here = go back to revise.
    dialog_msgbox "Installation Summary" "${summary}" || return "${TUI_BACK}"

    # --- Blocking hardware caveats ----------------------------------------
    # MT7922 (GPD Pocket 4 and others) has NO FreeBSD driver: WIFI_SUPPORTED=0
    # means no wireless on the installed system. Warn loudly before the wipe so
    # the user knows to plan a wired/USB path — this is not fatal but it is a
    # surprise on a laptop. (See DESIGN.md device caveats.)
    if [[ "${WIFI_SUPPORTED:-1}" == "0" ]]; then
        local wifi_warn=""
        wifi_warn+="!!! WiFi NOT SUPPORTED !!!\n\n"
        wifi_warn+="Detected WiFi chip"
        [[ -n "${WIFI_VENDOR:-}" ]] && wifi_warn+=" (${WIFI_VENDOR}"
        [[ -n "${WIFI_DEVICE_ID:-}" ]] && wifi_warn+=" ${WIFI_DEVICE_ID}"
        [[ -n "${WIFI_VENDOR:-}" || -n "${WIFI_DEVICE_ID:-}" ]] && wifi_warn+=")"
        wifi_warn+=" has NO FreeBSD driver.\n\n"
        wifi_warn+="The installed system will have NO wireless networking.\n"
        wifi_warn+="Plan on a wired Ethernet or USB tether for first boot and\n"
        wifi_warn+="package installation.\n\n"
        wifi_warn+="Continue anyway?"
        dialog_yesno "WiFi Unsupported" "${wifi_warn}" || return "${TUI_BACK}"
    fi

    # --- Destructive confirmation (typed YES) -----------------------------
    # v0.1 is whole-disk auto only: this WIPES the entire target disk. Require an
    # explicit typed YES — a yes/no is too easy to fat-finger before a wipe.
    local warning=""
    warning+="!!! WARNING: DATA DESTRUCTION !!!\n\n"
    warning+="The following disk will be COMPLETELY ERASED:\n\n"
    warning+="  /dev/${TARGET_DISK:-?}\n\n"
    warning+="ALL existing partitions, operating systems and data on this disk\n"
    warning+="will be permanently lost. This action CANNOT be undone.\n\n"
    warning+="Type YES (all caps) in the next dialog to confirm."
    dialog_msgbox "WARNING" "${warning}" || return "${TUI_BACK}"

    # Empty/Cancel -> TUI_BACK; anything other than exactly "YES" -> back too.
    local confirmation
    confirmation=$(dialog_inputbox "Confirm Installation" \
        "Type YES (all caps) to confirm and begin the installation:" \
        "") || return "${TUI_BACK}"

    if [[ "${confirmation}" != "YES" ]]; then
        dialog_msgbox "Cancelled" \
            "Installation not confirmed. You typed: '${confirmation}'\n\nReturning to the summary." || true
        return "${TUI_BACK}"
    fi

    # --- Countdown --------------------------------------------------------
    # A last abortable pause (Ctrl+C) before the install phase begins. Feed a
    # percentage stream into dialog_gauge so it works across all backends.
    einfo "Installation starting in ${COUNTDOWN_DEFAULT} seconds..."
    (
        local i
        for (( i = COUNTDOWN_DEFAULT; i > 0; i-- )); do
            echo "$(( (COUNTDOWN_DEFAULT - i) * 100 / COUNTDOWN_DEFAULT ))"
            sleep 1
        done
        echo "100"
    ) | dialog_gauge "Starting Installation" \
        "Installation will begin in ${COUNTDOWN_DEFAULT} seconds...\nPress Ctrl+C to abort."

    return "${TUI_NEXT}"
}
