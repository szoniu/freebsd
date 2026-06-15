#!/usr/bin/env bash
# config.sh — Save/load configuration using ${VAR@Q} quoting
source "${LIB_DIR}/protection.sh"

# config_save — Serialize all CONFIG_VARS to a sourceable bash file
config_save() {
    local file="${1:-${CONFIG_FILE}}"
    local dir
    dir="$(dirname "${file}")"
    mkdir -p "${dir}"

    # Restrict permissions — file contains password hashes
    (
        umask 077
        {
            echo "#!/usr/bin/env bash"
            echo "# Void TUI Installer configuration"
            echo "# Generated: $(date -Iseconds)"
            echo "# Version: ${INSTALLER_VERSION}"
            echo ""

            local var
            for var in "${CONFIG_VARS[@]}"; do
                if [[ -n "${!var+x}" ]]; then
                    # Use ${VAR@Q} for safe quoting
                    echo "${var}=${!var@Q}"
                fi
            done
        } > "${file}"
    )

    einfo "Configuration saved to ${file}"
}

# config_load — Load configuration from file
config_load() {
    local file="${1:-${CONFIG_FILE}}"

    if [[ ! -f "${file}" ]]; then
        eerror "Configuration file not found: ${file}"
        return 1
    fi

    # Build a filtered file with only known CONFIG_VARS assignments
    local safe_file
    safe_file=$(mktemp "${TMPDIR:-/tmp}/void-config-safe.XXXXXX")

    local line_num=0
    while IFS= read -r line; do
        (( line_num++ )) || true
        # Pass through comments and empty lines
        if [[ "${line}" =~ ^[[:space:]]*# ]] || [[ "${line}" =~ ^[[:space:]]*$ ]] || [[ "${line}" =~ ^#! ]]; then
            echo "${line}" >> "${safe_file}"
            continue
        fi

        # Must be a known variable assignment
        local var_name
        var_name="${line%%=*}"
        var_name="${var_name%%[[:space:]]*}"

        local found=0
        local known_var
        for known_var in "${CONFIG_VARS[@]}"; do
            if [[ "${var_name}" == "${known_var}" ]]; then
                found=1
                break
            fi
        done

        if [[ ${found} -eq 0 ]]; then
            ewarn "Unknown variable at line ${line_num}: ${var_name} (skipping)"
            continue
        fi
        echo "${line}" >> "${safe_file}"
    done < "${file}"

    # Source the filtered file (only known variables)
    # shellcheck disable=SC1090
    source "${safe_file}"
    rm -f "${safe_file}"

    einfo "Configuration loaded from ${file}"
}

# config_get — Get a config variable value (for external scripts)
config_get() {
    local var="$1"
    echo "${!var:-}"
}

# config_set — Set a config variable
config_set() {
    local var="$1" value="$2"

    # Validate variable name is in CONFIG_VARS
    local found=0
    local known_var
    for known_var in "${CONFIG_VARS[@]}"; do
        if [[ "${var}" == "${known_var}" ]]; then
            found=1
            break
        fi
    done

    if [[ ${found} -eq 0 ]]; then
        ewarn "Setting unknown config variable: ${var}"
    fi

    printf -v "${var}" '%s' "${value}"
    # Intentional indirect export of the variable *named* by ${var}.
    # shellcheck disable=SC2163
    export "${var}"
}

# config_dump — Print current configuration to stdout
config_dump() {
    local var
    for var in "${CONFIG_VARS[@]}"; do
        if [[ -n "${!var+x}" ]]; then
            echo "${var}=${!var@Q}"
        fi
    done
}

# config_diff — Compare two config files, showing differences
config_diff() {
    local file1="$1" file2="$2"
    diff --unified=0 \
        <(sort "${file1}" | grep -v '^#' | grep -v '^$') \
        <(sort "${file2}" | grep -v '^#' | grep -v '^$') || true
}

# validate_config — Check configuration consistency before installation
# Prints error messages to stdout. Returns 0 if valid, 1 if errors found.
# Non-fatal advisories (e.g. UFS has no boot environments) are emitted with
# ewarn and do NOT count toward the failure return code.
validate_config() {
    local -a errors=()

    # --- Required variables (must be non-empty) ---
    # FreeBSD set: no KERNEL_TYPE (single GENERIC kernel), no MIRROR_URL (dist
    # sets ship on the install media). FS_PROFILE replaces Void's FILESYSTEM.
    local -a required=(
        TARGET_DISK FS_PROFILE HOSTNAME TIMEZONE LOCALE
        USERNAME ROOT_PASSWORD_HASH USER_PASSWORD_HASH
    )
    local var
    for var in "${required[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            errors+=("${var} is required but not set")
        fi
    done

    # --- Enum validation (only check if non-empty) ---
    # Filesystem profile drives the whole partition/boot story: zfs gets a pool
    # + boot environments, ufs is a plain GPT+UFS root.
    if [[ -n "${FS_PROFILE:-}" ]] && \
       [[ "${FS_PROFILE}" != "zfs" && "${FS_PROFILE}" != "ufs" ]]; then
        errors+=("FS_PROFILE='${FS_PROFILE}' — must be zfs or ufs")
    fi

    if [[ -n "${PARTITION_SCHEME:-}" ]] && \
       [[ "${PARTITION_SCHEME}" != "auto" && "${PARTITION_SCHEME}" != "dual-boot" && "${PARTITION_SCHEME}" != "manual" ]]; then
        errors+=("PARTITION_SCHEME='${PARTITION_SCHEME}' — must be auto, dual-boot, or manual")
    fi

    # FreeBSD has no zram/swap-file path in this installer: swap is either a
    # GPT freebsd-swap partition (optionally .eli-encrypted) or nothing.
    if [[ -n "${SWAP_TYPE:-}" ]] && \
       [[ "${SWAP_TYPE}" != "partition" && "${SWAP_TYPE}" != "none" ]]; then
        errors+=("SWAP_TYPE='${SWAP_TYPE}' — must be partition or none")
    fi

    # BOOT_TYPE maps to machdep.bootmethod / loader install. 'auto' lets the
    # installer pick from is_efi at install time.
    if [[ -n "${BOOT_TYPE:-}" ]] && \
       [[ "${BOOT_TYPE}" != "UEFI" && "${BOOT_TYPE}" != "BIOS" && "${BOOT_TYPE}" != "BIOS+UEFI" && "${BOOT_TYPE}" != "auto" ]]; then
        errors+=("BOOT_TYPE='${BOOT_TYPE}' — must be UEFI, BIOS, BIOS+UEFI, or auto")
    fi

    if [[ -n "${DESKTOP_TYPE:-}" ]]; then
        case "${DESKTOP_TYPE}" in
            none|kde|gnome|xfce|mate|cinnamon|lxqt|sway|niri|hyprland|mango) ;;
            *)
                errors+=("DESKTOP_TYPE='${DESKTOP_TYPE}' — must be one of none, kde, gnome, xfce, mate, cinnamon, lxqt, sway, niri, hyprland, mango")
                ;;
        esac
    fi

    # Display manager: only sddm/gdm/lightdm/none are wired (desktop.sh enables
    # ${dm}_enable). A garbage value would `sysrc <garbage>_enable=YES`.
    if [[ -n "${DISPLAY_MANAGER:-}" ]] && \
       [[ "${DISPLAY_MANAGER}" != "sddm" && "${DISPLAY_MANAGER}" != "gdm" && "${DISPLAY_MANAGER}" != "lightdm" && "${DISPLAY_MANAGER}" != "none" ]]; then
        errors+=("DISPLAY_MANAGER='${DISPLAY_MANAGER}' — must be sddm, gdm, lightdm, or none")
    fi

    if [[ -n "${GPU_VENDOR:-}" ]] && \
       [[ "${GPU_VENDOR}" != "amd" && "${GPU_VENDOR}" != "intel" && "${GPU_VENDOR}" != "nvidia" && "${GPU_VENDOR}" != "none" && "${GPU_VENDOR}" != "unknown" ]]; then
        errors+=("GPU_VENDOR='${GPU_VENDOR}' — must be amd, intel, nvidia, none, or unknown")
    fi

    # Privilege escalation tool: FreeBSD ships doas in base since 14, sudo is a pkg.
    if [[ -n "${PRIV_TOOL:-}" ]] && \
       [[ "${PRIV_TOOL}" != "doas" && "${PRIV_TOOL}" != "sudo" ]]; then
        errors+=("PRIV_TOOL='${PRIV_TOOL}' — must be doas or sudo")
    fi

    if [[ -n "${NOCTALIA_COMPOSITOR:-}" ]] && \
       [[ "${NOCTALIA_COMPOSITOR}" != "hyprland" && "${NOCTALIA_COMPOSITOR}" != "niri" && "${NOCTALIA_COMPOSITOR}" != "sway" ]]; then
        errors+=("NOCTALIA_COMPOSITOR='${NOCTALIA_COMPOSITOR}' — must be hyprland, niri, or sway")
    fi

    # --- Format validation ---
    # Hostname: RFC 1123 (goes into /etc/rc.conf hostname= and /etc/hosts)
    if [[ -n "${HOSTNAME:-}" ]] && \
       [[ ! "${HOSTNAME}" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
        errors+=("HOSTNAME='${HOSTNAME}' — invalid (RFC 1123: alphanumeric + hyphens, 1-63 chars)")
    fi

    # Locale: xx_XX.UTF-8 (used to derive the /etc/login.conf class via cap_mkdb)
    if [[ -n "${LOCALE:-}" ]] && \
       [[ ! "${LOCALE}" =~ ^[a-z]{2}_[A-Z]{2}\.UTF-8$ ]]; then
        errors+=("LOCALE='${LOCALE}' — must match xx_XX.UTF-8 format")
    fi

    # Integer / boolean knobs that flow into the generated bsdinstall script. A
    # hand-edited config must not push "4G" (rejected by vfs.zfs.arc_max) or a
    # non-numeric swap size into loader.conf / the PARTITIONS line.
    if [[ -n "${ARC_MAX_BYTES:-}" ]] && [[ ! "${ARC_MAX_BYTES}" =~ ^[0-9]+$ ]]; then
        errors+=("ARC_MAX_BYTES='${ARC_MAX_BYTES}' — must be an integer byte count (vfs.zfs.arc_max is in BYTES, never '4G')")
    fi
    if [[ -n "${SWAP_SIZE_MIB:-}" ]] && [[ ! "${SWAP_SIZE_MIB}" =~ ^[0-9]+$ ]]; then
        errors+=("SWAP_SIZE_MIB='${SWAP_SIZE_MIB}' — must be an integer (MiB)")
    fi
    if [[ -n "${SWAP_ENCRYPTION:-}" ]] && \
       [[ "${SWAP_ENCRYPTION}" != "0" && "${SWAP_ENCRYPTION}" != "1" ]]; then
        errors+=("SWAP_ENCRYPTION='${SWAP_ENCRYPTION}' — must be 0 or 1")
    fi
    if [[ -n "${GELI_ROOT:-}" ]] && \
       [[ "${GELI_ROOT}" != "0" && "${GELI_ROOT}" != "1" ]]; then
        errors+=("GELI_ROOT='${GELI_ROOT}' — must be 0 or 1")
    fi

    # --- Block device checks (skip in DRY_RUN) ---
    # FreeBSD disks are /dev/nda0, /dev/ada0, ... — character devices, not block
    # devices, so test -c (not -b). TARGET_DISK may be stored bare (nda0) or
    # fully-qualified (/dev/nda0); normalize before the existence test.
    if [[ "${DRY_RUN:-0}" != "1" ]]; then
        if [[ -n "${TARGET_DISK:-}" && "${PARTITION_SCHEME:-auto}" != "manual" ]]; then
            local target_dev="${TARGET_DISK}"
            [[ "${target_dev}" != /dev/* ]] && target_dev="/dev/${target_dev}"
            if [[ ! -c "${target_dev}" ]]; then
                errors+=("TARGET_DISK='${TARGET_DISK}' — device ${target_dev} does not exist")
            fi
        fi

        if [[ "${PARTITION_SCHEME:-}" == "dual-boot" && "${ESP_REUSE:-no}" == "yes" ]] && \
           [[ -n "${ESP_PARTITION:-}" ]]; then
            local esp_dev="${ESP_PARTITION}"
            [[ "${esp_dev}" != /dev/* ]] && esp_dev="/dev/${esp_dev}"
            if [[ ! -c "${esp_dev}" ]]; then
                errors+=("ESP_PARTITION='${ESP_PARTITION}' — device ${esp_dev} does not exist")
            fi
        fi
    fi

    # --- Cross-field logic ---
    # A freebsd-swap partition with no size is meaningless. Guard the arithmetic
    # behind an integer test so a non-numeric SWAP_SIZE_MIB doesn't hit `(( ))`
    # under set -u (the bad-value case is already reported by the format check).
    if [[ "${SWAP_TYPE:-}" == "partition" ]] && \
       { [[ -z "${SWAP_SIZE_MIB:-}" ]] || [[ ! "${SWAP_SIZE_MIB}" =~ ^[0-9]+$ ]] || (( SWAP_SIZE_MIB <= 0 )); }; then
        errors+=("SWAP_TYPE=partition requires SWAP_SIZE_MIB > 0")
    fi

    if [[ "${PARTITION_SCHEME:-}" == "dual-boot" ]] && \
       [[ -z "${ESP_PARTITION:-}" ]]; then
        errors+=("PARTITION_SCHEME=dual-boot requires ESP_PARTITION to be set")
    fi

    # --- Output ---
    if [[ ${#errors[@]} -gt 0 ]]; then
        local err
        for err in "${errors[@]}"; do
            echo "- ${err}"
        done
        return 1
    fi

    # --- Non-fatal advisories (emitted only when config is otherwise valid) ---
    # UFS has no boot environments: freebsd-update/pkg won't auto-snapshot, and
    # bectl is unavailable for one-shot rollback. Warn but do not fail.
    if [[ "${FS_PROFILE:-}" == "ufs" ]]; then
        ewarn "FS_PROFILE=ufs: bectl boot environments are unavailable (no automatic pre-upgrade snapshots / one-shot rollback). Choose zfs if you want them."
    fi

    return 0
}
