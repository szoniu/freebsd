#!/usr/bin/env bash
# tui/preset_load.sh — Optional preset loading screen
source "${LIB_DIR}/protection.sh"

# screen_preset_load — Skip / load-from-file / browse a saved preset
# Returns: TUI_NEXT (0), TUI_BACK (1), TUI_ABORT (2)
screen_preset_load() {
    local choice
    choice=$(dialog_menu "Load Preset" \
        "skip"   "Start fresh configuration" \
        "file"   "Load preset from file" \
        "browse" "Browse example presets") || return "${TUI_BACK}"

    case "${choice}" in
        skip)
            return "${TUI_NEXT}"
            ;;
        file)
            # Default to the newest preset we can find. /root on the live
            # memstick is writable, so a previously exported preset typically
            # lands there or in the repo's presets/ dir. The pipeline gets
            # || true because `ls` exits non-zero when no glob matches and that
            # would otherwise trip set -o pipefail.
            local default_preset=""
            local latest
            latest=$(ls -t "${SCRIPT_DIR}/presets/"custom-*.conf /root/freebsd-preset*.conf 2>/dev/null | head -1) || true
            if [[ -n "${latest}" ]]; then
                default_preset="${latest}"
            fi
            : "${default_preset:=${SCRIPT_DIR}/presets/custom.conf}"

            local file
            file=$(dialog_inputbox "Preset File" \
                "Enter the path to your preset file:" \
                "${default_preset}") || return "${TUI_BACK}"

            if [[ ! -f "${file}" ]]; then
                dialog_msgbox "Error" "File not found: ${file}"
                return "${TUI_BACK}"
            fi

            preset_import "${file}"

            _preset_offer_skip "Preset loaded from: ${file}"
            return "${TUI_NEXT}"
            ;;
        browse)
            local -a presets=()
            local f
            for f in "${SCRIPT_DIR}/presets/"*.conf; do
                [[ -f "${f}" ]] || continue
                presets+=("${f}" "$(basename "${f}")")
            done

            if [[ ${#presets[@]} -eq 0 ]]; then
                dialog_msgbox "No Presets" "No example presets found in ${SCRIPT_DIR}/presets/"
                return "${TUI_BACK}"
            fi

            local selected
            selected=$(dialog_menu "Select Preset" "${presets[@]}") || return "${TUI_BACK}"

            preset_import "${selected}"

            _preset_offer_skip "Preset loaded: $(basename "${selected}")"
            return "${TUI_NEXT}"
            ;;
    esac
}

# _preset_offer_skip — After a successful import, ask whether to fast-forward.
# run_wizard() honors _PRESET_SKIP_TO_USER: it still runs through disk_select
# (TARGET_DISK / ESP_PARTITION / ROOT_PARTITION are hardware-specific and are
# NOT carried in a preset — see PRESET_HW_VARS in lib/preset.sh) and then jumps
# straight to screen_summary. Everything else (users, packages, desktop,
# locale, kernel) comes from the imported preset.
_preset_offer_skip() {
    local loaded_msg="$1"
    local skip_rc=0
    dialog_yesno "Preset Loaded" \
        "${loaded_msg}\n\nSkip to disk selection + summary?\n\nChoose 'No' to review all settings." \
        || skip_rc=$?
    if [[ ${skip_rc} -eq 0 ]]; then
        _PRESET_SKIP_TO_USER=1
        export _PRESET_SKIP_TO_USER
    fi
}
