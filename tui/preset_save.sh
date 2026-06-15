#!/usr/bin/env bash
# tui/preset_save.sh — Optional preset export for the FreeBSD TUI installer
source "${LIB_DIR}/protection.sh"

# screen_preset_save — Offer to export the chosen config as a reusable preset.
# Hardware-specific values (TARGET_DISK, ESP_PARTITION, GPU_*, ...) are stripped
# by preset_export() so the file is portable across machines — see PRESET_HW_VARS
# in lib/preset.sh. Declining the export is "next", not "back": the user is past
# every configuration screen, so there is nothing to revise by going forward.
# Returns: TUI_NEXT (0), TUI_BACK (1), TUI_ABORT (2)
screen_preset_save() {
    # dialog_yesno: 0=Yes, 1=No, 128=ESC/abort (gum backend). Distinguish a
    # deliberate "No" (skip the export, proceed) from an ESC (go back a screen)
    # — a bare `|| return` would conflate the two.
    local yn_rc=0
    dialog_yesno "Save Preset" \
        "Would you like to export your configuration as a reusable preset?\n\n\
This lets you replay the same choices on another machine. Hardware-specific\n\
values (target disk, GPU, partitions) are stripped — they are re-detected on\n\
import." || yn_rc=$?
    case "${yn_rc}" in
        0) ;;                          # Yes — fall through and export
        1) return "${TUI_NEXT}" ;;     # No — skip export, proceed to summary
        *) return "${TUI_BACK}" ;;     # ESC/abort — step back
    esac

    # Default lands in /root (writable on the live memstick) with the same
    # freebsd-preset* naming that screen_preset_load globs for on the next run.
    local file
    file=$(dialog_inputbox "Preset File" \
        "Enter the path to save the preset:" \
        "/root/freebsd-preset-$(date +%Y%m%d).conf") || return "${TUI_BACK}"

    if [[ -z "${file}" ]]; then
        dialog_msgbox "Save Preset" "No path given — skipping preset export."
        return "${TUI_NEXT}"
    fi

    preset_export "${file}"
    einfo "Configuration preset saved to ${file}"

    dialog_msgbox "Preset Saved" \
        "Configuration preset saved to:\n  ${file}\n\n\
Replay it on another machine with:\n\
  ./install.sh --configure   (then choose 'Load preset')"

    return "${TUI_NEXT}"
}
