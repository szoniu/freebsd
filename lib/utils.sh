#!/usr/bin/env bash
# utils.sh — Utility functions: try (interactive recovery), countdown, dependency checks
source "${LIB_DIR}/protection.sh"

# try — Execute a command with interactive recovery on failure
# Usage: try "description" command [args...]
try() {
    local desc="$1"
    shift

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        einfo "[DRY-RUN] Would execute: $*"
        return 0
    fi

    while true; do
        einfo "Running: ${desc}"
        elog "Command: $*"

        local exit_code=0
        if [[ "${LIVE_OUTPUT:-0}" == "1" ]]; then
            # Show output on terminal AND log to file. The whole chroot phase
            # runs with LIVE_OUTPUT=1, so EVERY command goes through this pipe.
            # Capture the COMMAND's exit code via PIPESTATUS[0] — `tee`'s exit
            # (broken pipe / disk full) must not mask a real command
            # success/failure. The `if` also stops `set -e` from aborting on a
            # failed pipeline before we read PIPESTATUS.
            if "$@" 2>&1 | tee -a "${LOG_FILE}"; then
                exit_code=0
            else
                exit_code=${PIPESTATUS[0]}
            fi
        else
            "$@" >> "${LOG_FILE}" 2>&1 || exit_code=$?
        fi

        if [[ ${exit_code} -eq 0 ]]; then
            einfo "Success: ${desc}"
            return 0
        fi
        eerror "Failed (exit ${exit_code}): ${desc}"
        eerror "Command: $*"

        if [[ "${NON_INTERACTIVE:-0}" == "1" ]]; then
            die "Non-interactive mode — aborting on failure: ${desc}"
        fi

        # Restore stderr for dialog UI if it was redirected (fd 4 saved by screen_progress)
        local _stderr_redirected=0
        if { true >&4; } 2>/dev/null; then
            exec 2>&4
            _stderr_redirected=1
        fi

        local choice

        if command -v "${DIALOG_CMD:-dialog}" &>/dev/null; then
            # Full dialog UI available
            choice=$(dialog_menu "Command Failed: ${desc}" \
                "retry"    "Retry the command" \
                "shell"    "Drop to a shell (type 'exit' to return)" \
                "continue" "Skip this step and continue" \
                "log"      "View last 50 lines of log" \
                "abort"    "Abort installation") || choice="abort"
        else
            # No dialog (e.g. inside chroot) — simple text menu
            echo "" >&2
            echo "=== FAILED: ${desc} ===" >&2
            echo "  (r)etry  | (s)hell  | (c)ontinue  | (a)bort" >&2
            local _reply=""
            read -r -p "Choice [r/s/c/a]: " _reply < /dev/tty || _reply="a"
            case "${_reply}" in
                r*) choice="retry" ;;
                s*) choice="shell" ;;
                c*) choice="continue" ;;
                *)  choice="abort" ;;
            esac
        fi

        case "${choice}" in
            retry)
                ewarn "Retrying: ${desc}"
                [[ ${_stderr_redirected} -eq 1 ]] && exec 2>>"${LOG_FILE}"
                continue
                ;;
            shell)
                ewarn "Dropping to shell. Type 'exit' to return to installer."
                PS1="(freebsd-installer rescue) \w \$ " bash --norc --noprofile || true
                [[ ${_stderr_redirected} -eq 1 ]] && exec 2>>"${LOG_FILE}"
                continue
                ;;
            continue)
                ewarn "Skipping: ${desc} (user chose to continue)"
                [[ ${_stderr_redirected} -eq 1 ]] && exec 2>>"${LOG_FILE}"
                return 0
                ;;
            log)
                local _tmplog
                _tmplog=$(mktemp) && tail -50 "${LOG_FILE}" > "${_tmplog}" 2>/dev/null
                dialog_textbox "Log (last 50 lines)" "${_tmplog}" || true
                rm -f "${_tmplog}" 2>/dev/null
                [[ ${_stderr_redirected} -eq 1 ]] && exec 2>>"${LOG_FILE}"
                continue
                ;;
            abort)
                die "Aborted by user after failure: ${desc}"
                ;;
        esac
    done
}

# countdown — Display a countdown timer
# Usage: countdown <seconds> <message>
countdown() {
    local seconds="${1:-${COUNTDOWN_DEFAULT}}"
    local msg="${2:-Continuing in}"

    if [[ "${NON_INTERACTIVE:-0}" == "1" ]]; then
        return 0
    fi

    local i
    for ((i = seconds; i > 0; i--)); do
        printf "\r%s %d seconds... " "${msg}" "${i}" >&2
        sleep 1
    done
    printf "\r%s\n" "$(printf '%-60s' '')" >&2
}

# check_dependencies — Verify required tools are available
check_dependencies() {
    local -a missing=()
    local dep

    local -a required_deps=(
        bash
        bsdinstall
        gpart
        zpool
        kenv
        pciconf
        sysctl
        mount
        umount
        chroot
        pkg
        fetch
    )

    for dep in "${required_deps[@]}"; do
        if ! command -v "${dep}" &>/dev/null; then
            missing+=("${dep}")
        fi
    done

    # TUI backend: bsddialog (FreeBSD base) or bundled gum or dialog/whiptail
    if ! command -v bsddialog &>/dev/null && ! command -v gum &>/dev/null \
        && ! command -v dialog &>/dev/null && ! command -v whiptail &>/dev/null; then
        missing+=("bsddialog|gum|dialog")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        eerror "Missing required dependencies:"
        local m
        for m in "${missing[@]}"; do
            eerror "  - ${m}"
        done
        return 1
    fi

    einfo "All dependencies satisfied"
    return 0
}

# is_efi — Check if booted in UEFI mode (FreeBSD: machdep.bootmethod = UEFI|BIOS)
is_efi() {
    [[ "$(sysctl -n machdep.bootmethod 2>/dev/null)" == "UEFI" ]]
}

# is_root — Check if running as root
is_root() {
    [[ "$(id -u)" -eq 0 ]]
}

# is_supported_arch — This installer targets amd64. bsdinstall, the bundled
# amd64 gum binary and the pkg sets are amd64-only. ARM64 Surface (Snapdragon X
# — Surface Pro 11th / Laptop 7th) is out of scope: it would WIPE THE DISK then
# fail on the first amd64 chroot exec. Refuse before anything destructive.
# NOT bypassable: an amd64 install cannot succeed on aarch64.
is_supported_arch() {
    case "$(uname -m 2>/dev/null)" in
        x86_64|amd64) return 0 ;;
        *) return 1 ;;
    esac
}

# ensure_dns — Add a fallback nameserver if DNS fails but a raw IP works.
# FreeBSD ping uses -t (overall timeout, seconds), not Linux's -W.
ensure_dns() {
    if ! ping -c 1 -t 3 pkg.FreeBSD.org &>/dev/null && ! ping -c 1 -t 3 freebsd.org &>/dev/null; then
        if ping -c 1 -t 3 1.1.1.1 &>/dev/null || ping -c 1 -t 3 8.8.8.8 &>/dev/null; then
            ewarn "DNS resolution failed, adding fallback nameserver 1.1.1.1"
            if ! grep -q '1.1.1.1' /etc/resolv.conf 2>/dev/null; then
                echo "nameserver 1.1.1.1" >> /etc/resolv.conf
            fi
        fi
    fi
}

# has_network — Check basic network connectivity
has_network() {
    ping -c 1 -t 3 pkg.FreeBSD.org &>/dev/null || \
    ping -c 1 -t 3 freebsd.org &>/dev/null || \
    ping -c 1 -t 3 1.1.1.1 &>/dev/null
}

# checkpoint_set — Mark a phase as completed
# Optional 2nd arg is stored as the checkpoint file's content so a later
# resume can tell *what* was done, not just *that* it was done (e.g. which
# kernel type was built — see checkpoint_validate "kernel").
checkpoint_set() {
    local name="$1"
    local meta="${2:-}"
    mkdir -p "${CHECKPOINT_DIR}"
    if [[ -n "${meta}" ]]; then
        printf '%s\n' "${meta}" > "${CHECKPOINT_DIR}/${name}"
    else
        touch "${CHECKPOINT_DIR}/${name}"
    fi
    einfo "Checkpoint set: ${name}"
}

# checkpoint_reached — Check if a phase is already completed
checkpoint_reached() {
    local name="$1"
    [[ -f "${CHECKPOINT_DIR}/${name}" ]]
}

# checkpoint_clear — Remove all checkpoints
checkpoint_clear() {
    rm -rf "${CHECKPOINT_DIR}"
    einfo "All checkpoints cleared"
}

# checkpoint_validate — Check if a checkpoint's artifact actually exists
# Returns 0 if checkpoint is valid, 1 if it should be re-run
checkpoint_validate() {
    local name="$1"
    case "${name}" in
        preflight)
            return 1 ;;  # always re-run (fast)
        disks)
            [[ -b "${ROOT_PARTITION:-}" ]] && mountpoint -q "${MOUNTPOINT}" 2>/dev/null ;;
        rootfs_extract)
            [[ -f "${MOUNTPOINT}/usr/bin/xbps-install" ]] ;;
        xbps_preconfig)
            [[ -d "${MOUNTPOINT}/etc/xbps.d/" ]] ;;
        rootfs_download|rootfs_verify)
            ls "${MOUNTPOINT}"/void-x86_64-ROOTFS-*.tar.xz &>/dev/null 2>&1 ;;
        chroot)
            [[ -f "${MOUNTPOINT}${CHECKPOINT_DIR_SUFFIX}/finalize" ]] ;;
        kernel)
            # A vmlinuz must exist on the target...
            if ! ls "${MOUNTPOINT}/boot/vmlinuz-"* &>/dev/null 2>&1 && \
               ! ls /boot/vmlinuz-* &>/dev/null 2>&1; then
                return 1
            fi
            # ...and it must be the kernel type the user wants *now*. The
            # checkpoint file records the type it was built for; if the user
            # switched (e.g. mainline -> lts -> surface-patched on a re-run or
            # --resume) the recorded type won't match KERNEL_TYPE, so the
            # phase must re-run instead of silently keeping the old kernel.
            local recorded
            recorded=$(cat "${CHECKPOINT_DIR}/kernel" 2>/dev/null) || true
            recorded="${recorded//[[:space:]]/}"
            [[ -z "${recorded}" ]] && return 0  # legacy checkpoint (no type) — trust it
            [[ "${recorded}" == "${KERNEL_TYPE:-mainline}" ]] ;;
        *)
            return 0 ;;  # trust checkpoint for the rest
    esac
}

# checkpoint_migrate_to_target — Move checkpoints from /tmp to target disk
# Called after mounting filesystems so checkpoints survive reformat
checkpoint_migrate_to_target() {
    local target_dir="${MOUNTPOINT}${CHECKPOINT_DIR_SUFFIX}"
    [[ "${CHECKPOINT_DIR}" == "${target_dir}" ]] && return 0
    mkdir -p "${target_dir}"
    [[ -d "${CHECKPOINT_DIR}" ]] && cp -a "${CHECKPOINT_DIR}/"* "${target_dir}/" 2>/dev/null || true
    rm -rf "${CHECKPOINT_DIR}"
    CHECKPOINT_DIR="${target_dir}"
    export CHECKPOINT_DIR
}

# --- Resume from disk ---

# RESUME_FOUND_PARTITION — partition where resume data was found
RESUME_FOUND_PARTITION=""
# RESUME_FOUND_FSTYPE — filesystem type of that partition
RESUME_FOUND_FSTYPE=""
# RESUME_HAS_CONFIG — whether config file was found alongside checkpoints
RESUME_HAS_CONFIG=0

# _scan_partition_for_resume — Check a single partition for resume data
# Usage: _scan_partition_for_resume /dev/sdX2 ext4
# Sets: _SCAN_HAS_CHECKPOINTS, _SCAN_HAS_CONFIG, _SCAN_MOUNTPOINT
# try_resume_from_disk — Look for a saved installer config on the target.
# Returns 0 = config recovered, 2 = nothing found. v0.1 does NOT infer config
# from an installed system the way the Linux family does; within-session resume
# via /tmp checkpoints (screen_progress) covers crash-and-rerun. Full cross-reboot
# disk-scan inference is a TODO.
try_resume_from_disk() {
    RESUME_FOUND_PARTITION=""
    RESUME_FOUND_FSTYPE=""
    export RESUME_FOUND_PARTITION RESUME_FOUND_FSTYPE
    # Same-session config in /tmp?
    if [[ -f "${CONFIG_FILE}" ]]; then
        RESUME_FOUND_PARTITION="${CONFIG_FILE}"
        return 0
    fi
    # Try importing each visible ZFS pool read-only and reading our saved config.
    local pool cfg probe="/tmp/freebsd-installer-resume-probe"
    for pool in $(zpool import 2>/dev/null | awk '/^[[:space:]]*pool:/{print $2}'); do
        mkdir -p "${probe}" 2>/dev/null || true
        if zpool import -fN -o readonly=on -R "${probe}" "${pool}" 2>/dev/null; then
            cfg="${probe}/var/db/freebsd-installer/$(basename "${CONFIG_FILE}")"
            if [[ -f "${cfg}" ]]; then
                cp -f "${cfg}" "${CONFIG_FILE}" 2>/dev/null || true
                RESUME_FOUND_PARTITION="${pool}"
            fi
            zpool export "${pool}" 2>/dev/null || true
            [[ -f "${CONFIG_FILE}" ]] && return 0
        fi
    done
    return 2
}

bytes_to_human() {
    local bytes="$1"
    if ((bytes >= 1073741824)); then
        printf "%.1f GiB" "$(echo "scale=1; ${bytes}/1073741824" | bc)"
    elif ((bytes >= 1048576)); then
        printf "%.1f MiB" "$(echo "scale=1; ${bytes}/1048576" | bc)"
    elif ((bytes >= 1024)); then
        printf "%.1f KiB" "$(echo "scale=1; ${bytes}/1024" | bc)"
    else
        printf "%d B" "${bytes}"
    fi
}

# get_cpu_count — Number of CPUs
get_cpu_count() {
    nproc 2>/dev/null || echo 4
}

# generate_password_hash — Create SHA-512 password hash
generate_password_hash() {
    local password="$1"
    openssl passwd -6 -stdin <<< "${password}" 2>/dev/null || \
    mkpasswd -m sha-512 --stdin <<< "${password}" 2>/dev/null || \
    { eerror "Cannot generate password hash: neither openssl nor mkpasswd available"; return 1; }
}
