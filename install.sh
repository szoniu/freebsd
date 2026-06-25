#!/usr/bin/env bash
# install.sh — Main entry point for the FreeBSD TUI Installer
#
# Usage:
#   ./install.sh              — Full install (TUI wizard + install)
#   ./install.sh --configure  — Run only the TUI wizard (generate config)
#   ./install.sh --install    — Run only the install (using existing config)
#   ./install.sh --resume     — Resume an interrupted install (checkpoints)
#   ./install.sh --dry-run    — Wizard + simulate install (no destructive ops)
#
# Single-process model: bsdinstall(8) does the destructive base install; our
# post-install phases run in THIS process and shell into the target via chroot_*.
set -Eeuo pipefail
shopt -s inherit_errexit

_err_handler() {
    local rc=$1 line=$2 src=$3 func=$4
    if { true >&4; } 2>/dev/null; then exec 2>&4; fi
    echo "[ERR] ${src}:${line} (${func}) exit=${rc}" >&2
    echo "[ERR] ${src}:${line} (${func}) exit=${rc}" >> "${LOG_FILE:-/tmp/freebsd-installer.log}"
}
trap '_err_handler $? ${LINENO} "${BASH_SOURCE[0]:-?}" "${FUNCNAME[0]:-main}"' ERR

export _FREEBSD_INSTALLER=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR
export LIB_DIR="${SCRIPT_DIR}/lib"
export TUI_DIR="${SCRIPT_DIR}/tui"
export DATA_DIR="${SCRIPT_DIR}/data"

# --- Library modules ---
source "${LIB_DIR}/constants.sh"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/utils.sh"
source "${LIB_DIR}/dialog.sh"
source "${LIB_DIR}/config.sh"
source "${LIB_DIR}/hardware.sh"
source "${LIB_DIR}/bsdinstall.sh"
source "${LIB_DIR}/chroot.sh"
source "${LIB_DIR}/gpu.sh"
source "${LIB_DIR}/desktop.sh"
source "${LIB_DIR}/system.sh"
source "${LIB_DIR}/umpc.sh"
source "${LIB_DIR}/hooks.sh"
source "${LIB_DIR}/preset.sh"

# --- TUI screens ---
source "${TUI_DIR}/welcome.sh"
source "${TUI_DIR}/preset_load.sh"
source "${TUI_DIR}/hw_detect.sh"
source "${TUI_DIR}/disk_select.sh"
source "${TUI_DIR}/filesystem_select.sh"
source "${TUI_DIR}/swap_config.sh"
source "${TUI_DIR}/network_config.sh"
source "${TUI_DIR}/locale_config.sh"
source "${TUI_DIR}/gpu_config.sh"
source "${TUI_DIR}/desktop_select.sh"
source "${TUI_DIR}/user_config.sh"
source "${TUI_DIR}/extra_packages.sh"
source "${TUI_DIR}/preset_save.sh"
source "${TUI_DIR}/summary.sh"
source "${TUI_DIR}/progress.sh"

# --- Cleanup trap ---
cleanup() {
    local rc=$?
    stty echo </dev/tty 2>/dev/null || true
    if { true >&4; } 2>/dev/null; then exec 2>&4; exec 4>&-; fi
    if [[ "${_NO_TEARDOWN:-0}" != "1" ]]; then
        chroot_teardown 2>/dev/null || true
    fi
    if [[ ${rc} -ne 0 ]]; then
        eerror "Installer exited with code ${rc}"
        eerror "Log file: ${LOG_FILE}"
    fi
    return ${rc}
}
trap cleanup EXIT
trap 'trap - EXIT; cleanup; exit 130' INT
trap 'trap - EXIT; cleanup; exit 143' TERM

# --- Arguments ---
MODE="full"
DRY_RUN=0
FORCE=0
NON_INTERACTIVE=0
export DRY_RUN FORCE NON_INTERACTIVE

usage() {
    cat <<'EOF'
FreeBSD TUI Installer

Usage:
  install.sh [OPTIONS] [COMMAND]

Commands:
  (default)       Full install (wizard + install)
  --configure     Run only the TUI configuration wizard
  --install       Run only the install phase (requires config)
  --resume        Resume an interrupted install (scan for checkpoints)

Options:
  --config FILE   Use the specified config file
  --dry-run       Simulate install without destructive operations
  --force         Continue past failed prerequisite checks
  --non-interactive  Abort on any error (no recovery menu)
  --help          Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --configure) MODE="configure"; shift ;;
        --install)   MODE="install"; shift ;;
        --resume)    MODE="resume"; shift ;;
        --config)
            [[ $# -lt 2 ]] && die "--config requires a file argument"
            CONFIG_FILE="$2"; shift 2 ;;
        --dry-run)   DRY_RUN=1; shift ;;
        --force)     FORCE=1; shift ;;
        --non-interactive) NON_INTERACTIVE=1; shift ;;
        --help|-h)   usage; exit 0 ;;
        *) eerror "Unknown argument: $1"; usage; exit 1 ;;
    esac
done

# finalize_config — fill derived defaults before save/install.
finalize_config() {
    : "${FS_PROFILE:=zfs}"
    : "${ZFS_POOL_NAME:=${ZFS_POOL_NAME_DEFAULT}}"
    : "${ZFS_VDEV_TYPE:=${ZFS_VDEV_TYPE_DEFAULT}}"
    : "${ZFS_POOL_OPTS:=${ZFS_POOL_OPTS_DEFAULT}}"
    : "${PRIV_TOOL:=doas}"
    : "${TIMEZONE:=UTC}"
    : "${LOCALE:=en_US.UTF-8}"
    : "${LOCALE_CLASS:=english}"
    : "${SWAP_TYPE:=partition}"
    : "${SWAP_SIZE_MIB:=${SWAP_DEFAULT_SIZE_MIB}}"
    : "${BOOT_TYPE:=auto}"
    : "${DRM_PKG:=${DRM_KMOD_PKG}}"
    # Cap the ZFS ARC on low-RAM boxes (<=16 GiB): physmem/3 in BYTES.
    if [[ -z "${ARC_MAX_BYTES:-}" && "${RAM_MIB:-0}" -gt 0 && "${RAM_MIB}" -le 16384 && "${FS_PROFILE}" == "zfs" ]]; then
        ARC_MAX_BYTES=$(( ${RAM_BYTES:-0} / 3 ))
    fi
    export FS_PROFILE ZFS_POOL_NAME ZFS_VDEV_TYPE ZFS_POOL_OPTS PRIV_TOOL TIMEZONE LOCALE \
           LOCALE_CLASS SWAP_TYPE SWAP_SIZE_MIB BOOT_TYPE DRM_PKG ARC_MAX_BYTES
}

# run_configuration_wizard — launch all TUI screens.
run_configuration_wizard() {
    init_dialog
    register_wizard_screens \
        screen_welcome \
        screen_preset_load \
        screen_hw_detect \
        screen_disk_select \
        screen_filesystem_select \
        screen_swap_config \
        screen_network_config \
        screen_locale_config \
        screen_gpu_config \
        screen_desktop_select \
        screen_user_config \
        screen_extra_packages \
        screen_preset_save \
        screen_summary
    run_wizard
    finalize_config
    config_save "${CONFIG_FILE}"
    einfo "Configuration complete. Saved to ${CONFIG_FILE}"
}

# preflight_checks — verify readiness.
preflight_checks() {
    einfo "Running preflight checks..."
    if [[ "${DRY_RUN}" != "1" ]]; then
        is_root || die "Must run as root"
        is_supported_arch || die "Unsupported architecture ($(uname -m)). This installer is amd64-only (ARM64 Surface is out of scope)."
        ensure_dns
        if ! has_network; then
            if [[ "${FORCE}" == "1" ]]; then ewarn "No network (forced)"
            else die "Network connectivity required — bootstrap via wired/USB-Ethernet on devices without a working WiFi driver"; fi
        fi
        # Mini-memstick / no offline base: a FULL memstick ships base.txz/kernel.txz
        # in ${DIST_DIR}; a mini-memstick ships only MANIFEST. When base.txz is
        # absent, bsdinstall must FETCH the dist set over the network (the generated
        # preamble pins BSDINSTALL_DISTSITE so this stays non-interactive). Warn up
        # front rather than failing late at distextract ("Failed to open kernel.txz").
        if [[ ! -s "${DIST_DIR}/base.txz" ]]; then
            ewarn "No offline base in ${DIST_DIR} (mini-memstick?) — base.txz/kernel.txz will be fetched from download.freebsd.org. A FULL memstick avoids this; ensure wired connectivity."
        fi
        if ! check_dependencies; then
            if [[ "${FORCE}" == "1" ]]; then ewarn "Missing deps (forced)"
            else die "Missing dependencies"; fi
        fi
    fi
    einfo "Preflight checks passed"
}

# run_post_install — save config to target, unmount, offer reboot.
run_post_install() {
    einfo "=== Post-installation ==="
    if [[ "${DRY_RUN}" != "1" ]]; then
        # Persist config to the target for cross-reboot --resume.
        mkdir -p "${MOUNTPOINT}/var/db/freebsd-installer" 2>/dev/null || true
        cp -f "${CONFIG_FILE}" "${MOUNTPOINT}/var/db/freebsd-installer/$(basename "${CONFIG_FILE}")" 2>/dev/null || true
    fi
    chroot_teardown
    if dialog_yesno "Reboot" "Installation complete. Reboot now?"; then
        einfo "Rebooting..."
        if [[ "${DRY_RUN}" != "1" ]]; then reboot; else einfo "[DRY-RUN] Would reboot"; fi
    else
        einfo "You can reboot manually when ready. Log: ${LOG_FILE}"
    fi
}

# --- Entry point ---
main() {
    # bash auto-populates and exports HOSTNAME from the LIVE medium's hostname.
    # That ambient value would otherwise satisfy the "HOSTNAME required" check and
    # silently leak the installer medium's name into the target. Clear it so
    # HOSTNAME is only ever set by screen_network_config (wizard) or a loaded
    # config; a missing one is then caught by validate_config.
    unset HOSTNAME

    init_logging
    einfo "========================================="
    einfo "${INSTALLER_NAME} v${INSTALLER_VERSION}"
    einfo "========================================="
    einfo "Mode: ${MODE}"
    [[ "${DRY_RUN}" == "1" ]] && ewarn "DRY-RUN mode enabled"

    case "${MODE}" in
        full)
            run_configuration_wizard
            screen_progress
            run_post_install
            ;;
        configure)
            run_configuration_wizard
            ;;
        install)
            config_load "${CONFIG_FILE}"
            deserialize_detected_oses
            finalize_config
            init_dialog
            screen_progress
            run_post_install
            ;;
        resume)
            local rc=0
            try_resume_from_disk || rc=$?
            init_dialog
            case ${rc} in
                0)
                    config_load "${CONFIG_FILE}"
                    deserialize_detected_oses
                    finalize_config
                    dialog_msgbox "Resume" "Recovered configuration. Resuming from the last checkpoint..."
                    screen_progress
                    run_post_install
                    ;;
                *)
                    dialog_msgbox "Resume: Nothing Found" "No saved installation found. Starting a full install."
                    run_configuration_wizard
                    screen_progress
                    run_post_install
                    ;;
            esac
            ;;
        *) die "Unknown mode: ${MODE}" ;;
    esac
    einfo "Done."
}

main "$@"
