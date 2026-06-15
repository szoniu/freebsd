#!/usr/bin/env bash
# tui/swap_config.sh — Swap configuration: dedicated freebsd-swap partition | none
#
# FreeBSD has NO zram analogue and we never offer swapfile-on-ZFS or a zvol
# default (corruption/deadlock risk — see DESIGN.md). The only sane choices are
# a dedicated GPT freebsd-swap partition (default) or no swap at all. Encrypted
# swap is a freebsd-swap partition flagged `.eli`: geli auto-attaches it at boot
# with a fresh random one-time key (no key management, cheap) — but that random
# key is regenerated every boot, so it is INCOMPATIBLE with hibernation.
source "${LIB_DIR}/protection.sh"

screen_swap_config() {
    # --- Swap type (partition | none) ---
    local current="${SWAP_TYPE:-partition}"
    # In manual mode, pre-select "partition" if the user already pointed us at one.
    if [[ -n "${SWAP_PARTITION:-}" && -z "${SWAP_TYPE:-}" ]]; then
        current="partition"
    fi
    local on_partition="off" on_none="off"
    case "${current}" in
        partition) on_partition="on" ;;
        none)      on_none="on" ;;
        *)         on_partition="on" ;;
    esac

    local choice
    choice=$(dialog_radiolist "Swap Configuration" \
        "partition" "Dedicated freebsd-swap partition (recommended)" "${on_partition}" \
        "none"      "No swap — not recommended for low-RAM systems" "${on_none}") \
        || return "${TUI_BACK}"

    if [[ -z "${choice}" ]]; then
        return "${TUI_BACK}"
    fi

    SWAP_TYPE="${choice}"
    export SWAP_TYPE

    if [[ "${SWAP_TYPE}" == "none" ]]; then
        SWAP_SIZE_MIB=""
        SWAP_ENCRYPTION="0"
        export SWAP_SIZE_MIB SWAP_ENCRYPTION
        einfo "Swap: none"
        return "${TUI_NEXT}"
    fi

    # --- Swap size (MiB) ---
    # UMPCs (GPD Pocket 4 etc.) carry plenty of RAM but want a roomy swap for
    # hibernation-free large workloads — bump the suggested default to 8 GiB.
    local default_size="${SWAP_SIZE_MIB:-${SWAP_DEFAULT_SIZE_MIB}}"
    if [[ -z "${SWAP_SIZE_MIB:-}" && "${UMPC_DETECTED:-0}" == "1" ]]; then
        default_size="8192"
    fi

    local size
    size=$(dialog_inputbox "Swap Partition Size" \
        "Enter the swap partition size in MiB:" \
        "${default_size}") || return "${TUI_BACK}"
    if [[ -z "${size}" ]]; then
        return "${TUI_BACK}"
    fi
    SWAP_SIZE_MIB="${size}"
    export SWAP_SIZE_MIB

    # --- Encrypted swap (geli one-time key -> swapN.eli) ---
    # Default YES: cheap, zero key management (fresh random key per boot), and it
    # keeps leaked memory pages off disk. Note the hibernation incompatibility.
    # 0=Yes, 1=No, 128=ESC/abort (gum). Map ESC to BACK like the sibling screens
    # (filesystem_select / extra_packages) so an accidental ESC doesn't silently
    # mean "unencrypted".
    local enc_rc=0
    dialog_yesno "Encrypted Swap" \
        "Encrypt the swap partition?\n\n\
geli attaches it at boot with a fresh random one-time key — no passphrase, no\n\
key management, and any data paged out is unreadable after reboot.\n\n\
Note: incompatible with hibernation (the key changes every boot).\n\n\
Recommended: Yes." || enc_rc=$?
    case "${enc_rc}" in
        0) SWAP_ENCRYPTION="1" ;;
        1) SWAP_ENCRYPTION="0" ;;
        *) return "${TUI_BACK}" ;;
    esac
    export SWAP_ENCRYPTION

    einfo "Swap: ${SWAP_TYPE} (${SWAP_SIZE_MIB} MiB, encryption=${SWAP_ENCRYPTION})"
    return "${TUI_NEXT}"
}
