#!/usr/bin/env bash
# progress.sh — screen_progress: execute install phases with checkpoints.
#
# v0.1 shows scrolling output (LIVE_OUTPUT=1 + einfo) rather than a gauge —
# on real-hardware test runs, visible command output beats a progress bar.
# Every phase is gated by a checkpoint so a crash + re-run skips finished work.
source "${LIB_DIR}/protection.sh"

# _run_phase <checkpoint> <description> <function...>
_run_phase() {
    local cp="$1" desc="$2"; shift 2
    if checkpoint_reached "${cp}"; then
        einfo "Skipping: ${desc} (checkpoint reached)"
        return 0
    fi
    einfo ""
    einfo "=== Phase: ${desc} ==="
    maybe_exec "before_${cp}"
    "$@"
    maybe_exec "after_${cp}"
    checkpoint_set "${cp}"
}

# _phase_bsdinstall — destructive base install via bsdinstall(8).
_phase_bsdinstall() {
    bsdinstall_run
}

# _phase_mount_target — re-mount the installed system + migrate checkpoints onto
# it so a reformat clears them automatically.
_phase_mount_target() {
    bsdinstall_mount_target
    checkpoint_migrate_to_target 2>/dev/null || true
}

# screen_progress — run all install phases.
screen_progress() {
    # Pre-install safety gate. validate_config guards the destructive bsdinstall
    # phase, but the wizard runs it only in screen_summary — the `install` and
    # `resume` modes skip the wizard entirely (install.sh), so a bad/hand-edited
    # config would otherwise reach the wipe unchecked. Re-validate here so EVERY
    # entry path is gated; validate_config is read-only and idempotent, so the
    # full-mode double-check (summary already ran it) is harmless.
    local _verr
    if ! _verr=$(validate_config); then
        eerror "Configuration is invalid — refusing to start the destructive install:"
        printf '%s\n' "${_verr}" >&2
        if [[ -n "${DIALOG_CMD:-}" ]]; then
            dialog_msgbox "Configuration Errors" \
                "Cannot start the installation — fix these first:\n\n${_verr}" || true
        fi
        die "Invalid configuration — aborting before any destructive operation"
    fi

    # Within-session resume: offer to continue if any checkpoint exists.
    local completed=0 cp
    for cp in "${CHECKPOINTS[@]}"; do
        checkpoint_reached "${cp}" && completed=$(( completed + 1 )) || true
    done
    if (( completed > 0 )); then
        if dialog_yesno "Resume installation" \
            "Found ${completed} completed phase(s) from a previous run.\n\nResume from where it left off? (Choosing No clears progress and starts over — the disk will be wiped again.)"; then
            einfo "Resuming — ${completed} phase(s) already done"
        else
            rm -rf "${CHECKPOINT_DIR}" 2>/dev/null || true
            einfo "Cleared checkpoints — starting over"
        fi
    fi

    # Stream command output to the terminal (and the log) during the long phases.
    export LIVE_OUTPUT=1

    _run_phase "preflight"     "Preflight checks"               preflight_checks
    _run_phase "bsdinstall"    "Installing FreeBSD base system" _phase_bsdinstall
    _run_phase "mount_target"  "Mounting the installed system"  _phase_mount_target
    _run_phase "gpu"           "Graphics drivers"               gpu_install
    _run_phase "desktop"       "Desktop environment"            desktop_install
    _run_phase "device_quirks" "Device quirks"                  device_quirks_apply
    _run_phase "extras"        "Extra packages"                 install_extras
    _run_phase "finalize"      "Finalizing"                     system_finalize

    unset LIVE_OUTPUT
    einfo ""
    einfo "=== All phases complete ==="
    return 0
}
