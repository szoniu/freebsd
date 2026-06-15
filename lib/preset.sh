#!/usr/bin/env bash
# preset.sh — Export/import presets with hardware overlay
source "${LIB_DIR}/protection.sh"

# Hardware-specific variables that should be re-detected, not imported
readonly -a PRESET_HW_VARS=(
    GPU_VENDOR
    GPU_DEVICE_ID
    GPU_DEVICE_NAME
    GPU_DRIVER
    GPU_USE_NVIDIA_OPEN
    TARGET_DISK
    ESP_PARTITION
    ROOT_PARTITION
    SWAP_PARTITION
    ESP_REUSE
)

# preset_export — Save configuration as a portable preset
preset_export() {
    local file="$1"
    local dir
    dir="$(dirname "${file}")"
    mkdir -p "${dir}"

    # The preset carries the portable config INCLUDING the $6$ password hashes
    # (the preset-skip flow in run_wizard reuses them, skipping user_config), so
    # write it 0600 like config_save — never world-readable.
    (
        umask 077
        {
        echo "#!/usr/bin/env bash"
        echo "# Void TUI Installer Preset"
        echo "# Exported: $(date -Iseconds)"
        echo "# Version: ${INSTALLER_VERSION}"
        echo "# Host: $(hostname 2>/dev/null || echo unknown)"
        echo "#"
        echo "# Hardware-specific values (will be re-detected on import):"
        local hw_var
        for hw_var in "${PRESET_HW_VARS[@]}"; do
            if [[ -n "${!hw_var+x}" ]]; then
                echo "# ${hw_var}=${!hw_var@Q}"
            fi
        done
        echo ""
        echo "# --- Portable configuration ---"

        local var
        for var in "${CONFIG_VARS[@]}"; do
            # Skip hardware-specific vars
            local is_hw=0
            for hw_var in "${PRESET_HW_VARS[@]}"; do
                if [[ "${var}" == "${hw_var}" ]]; then
                    is_hw=1
                    break
                fi
            done
            [[ ${is_hw} -eq 1 ]] && continue

            if [[ -n "${!var+x}" ]]; then
                echo "${var}=${!var@Q}"
            fi
        done
        } > "${file}"
    )

    einfo "Preset exported to ${file}"
}

# preset_import — Load a preset and re-detect hardware
preset_import() {
    local file="$1"

    if [[ ! -f "${file}" ]]; then
        eerror "Preset file not found: ${file}"
        return 1
    fi

    # Save current hardware values
    local -A saved_hw=()
    local hw_var
    for hw_var in "${PRESET_HW_VARS[@]}"; do
        if [[ -n "${!hw_var+x}" ]]; then
            saved_hw["${hw_var}"]="${!hw_var}"
        fi
    done

    # Load preset (only non-hardware values)
    config_load "${file}"

    # Restore hardware values (re-detected values take priority)
    for hw_var in "${PRESET_HW_VARS[@]}"; do
        if [[ -n "${saved_hw[${hw_var}]+x}" ]]; then
            printf -v "${hw_var}" '%s' "${saved_hw[${hw_var}]}"
            # Intentional indirect export of the variable *named* by ${hw_var}.
            # shellcheck disable=SC2163
            export "${hw_var}"
        fi
    done

    einfo "Preset imported from ${file}"
    einfo "Hardware-specific values preserved from current detection"
}

# preset_compare — Compare preset with current config, return differences
preset_compare() {
    local file="$1"
    local -A preset_vals=()

    # Source preset into a subshell to get unquoted values
    local safe_file
    safe_file=$(mktemp "${TMPDIR:-/tmp}/void-preset-cmp.XXXXXX")

    # Filter to known vars only (same logic as config_load)
    local line var_name
    while IFS= read -r line; do
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line}" || "${line}" =~ ^[[:space:]]*$ ]] && continue
        [[ "${line}" =~ ^#! ]] && continue
        var_name="${line%%=*}"
        var_name="${var_name%%[[:space:]]*}"
        local found=0
        local known_var
        for known_var in "${CONFIG_VARS[@]}"; do
            [[ "${var_name}" == "${known_var}" ]] && { found=1; break; }
        done
        [[ ${found} -eq 1 ]] && echo "${line}" >> "${safe_file}"
    done < "${file}"

    # Source to get unquoted values, then compare
    local var
    (
        # shellcheck disable=SC1090
        source "${safe_file}" 2>/dev/null
        for var in "${CONFIG_VARS[@]}"; do
            echo "${var}=${!var:-}"
        done
    ) | while IFS='=' read -r key value; do
        local current="${!key:-}"
        if [[ "${current}" != "${value}" ]]; then
            echo "DIFF: ${key}: preset='${value}' current='${current}'"
        fi
    done

    rm -f "${safe_file}"
}
