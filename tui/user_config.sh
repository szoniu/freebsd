#!/usr/bin/env bash
# tui/user_config.sh — Root password, regular user, groups, privilege tool.
#
# FreeBSD translation of the Void user screen:
#   * Groups default to wheel,operator,video — the FreeBSD convention. `wheel`
#     gates su(1)/doas; `operator` grants raw-device read (gpart/camcontrol,
#     shutdown); `video` is the seat/DRM render group used by seatd + amdgpu.
#     (No audio/input/storage/network groups — those are Linux-isms; FreeBSD
#     handles audio via devfs perms and networking without a group.)
#   * Privilege escalation is a choice: doas (default, in base-adjacent pkg,
#     minimal) or sudo. The pkg + config wiring happens later in the desktop/
#     extras phase; here we only record PRIV_TOOL.
#   * Passwords are hashed with generate_password_hash ($6$ SHA-512) and only
#     the HASH is stored/exported — never the plaintext. The hash is later fed
#     to `pw usermod -H 0` / the bsdinstall script via stdin, never argv.
source "${LIB_DIR}/protection.sh"

# _valid_username — FreeBSD/pw(8) sane-username gate: lowercase, must start with
# a letter, then letters/digits/_/- (no leading digit, no uppercase, no spaces).
# Mirrors the conservative subset pw(8) accepts cleanly across the family.
_valid_username() {
    [[ "$1" =~ ^[a-z][a-z0-9_-]*$ ]]
}

screen_user_config() {
    # --- Root password (with confirmation loop) ---
    local root_pass1 root_pass2
    while true; do
        root_pass1=$(dialog_passwordbox "Root Password" \
            "Enter root password:") || return "${TUI_BACK}"

        if [[ -z "${root_pass1}" ]]; then
            dialog_msgbox "Error" "Password cannot be empty."
            continue
        fi

        root_pass2=$(dialog_passwordbox "Root Password" \
            "Confirm root password:") || return "${TUI_BACK}"

        if [[ "${root_pass1}" != "${root_pass2}" ]]; then
            dialog_msgbox "Error" "Passwords do not match. Try again."
            continue
        fi

        break
    done

    ROOT_PASSWORD_HASH=$(generate_password_hash "${root_pass1}")
    export ROOT_PASSWORD_HASH

    # --- Regular user: login name (validated) ---
    local username
    while true; do
        username=$(dialog_inputbox "Username" \
            "Enter the login name for the regular user (lowercase, starts with a letter):" \
            "${USERNAME:-user}") || return "${TUI_BACK}"

        if [[ -z "${username}" ]]; then
            dialog_msgbox "Error" "Username cannot be empty."
            continue
        fi

        if ! _valid_username "${username}"; then
            dialog_msgbox "Error" \
                "Invalid username '${username}'.\n\nUse lowercase letters, digits, '_' or '-', and start with a letter."
            continue
        fi

        break
    done

    USERNAME="${username}"
    export USERNAME

    # --- Full name (GECOS, optional) ---
    local fullname
    fullname=$(dialog_inputbox "Full Name" \
        "Enter the full name for ${USERNAME} (optional):" \
        "${FULLNAME:-}") || return "${TUI_BACK}"
    FULLNAME="${fullname}"
    export FULLNAME

    # --- User password (with confirmation loop) ---
    local user_pass1 user_pass2
    while true; do
        user_pass1=$(dialog_passwordbox "User Password" \
            "Enter password for ${USERNAME}:") || return "${TUI_BACK}"

        if [[ -z "${user_pass1}" ]]; then
            dialog_msgbox "Error" "Password cannot be empty."
            continue
        fi

        user_pass2=$(dialog_passwordbox "User Password" \
            "Confirm password for ${USERNAME}:") || return "${TUI_BACK}"

        if [[ "${user_pass1}" != "${user_pass2}" ]]; then
            dialog_msgbox "Error" "Passwords do not match. Try again."
            continue
        fi

        break
    done

    USER_PASSWORD_HASH=$(generate_password_hash "${user_pass1}")
    export USER_PASSWORD_HASH

    # --- Supplementary groups (FreeBSD defaults: wheel,operator,video) ---
    local groups
    groups=$(dialog_inputbox "User Groups" \
        "Supplementary groups for ${USERNAME} (comma-separated):" \
        "${USER_GROUPS:-wheel,operator,video}") || return "${TUI_BACK}"
    USER_GROUPS="${groups}"
    export USER_GROUPS

    # --- Privilege escalation tool ---
    # doas is the FreeBSD default: small, simple config (/usr/local/etc/doas.conf),
    # the pattern the rest of the family assumes. sudo offered for muscle-memory.
    local on_doas="off" on_sudo="off"
    case "${PRIV_TOOL:-doas}" in
        sudo) on_sudo="on" ;;
        *)    on_doas="on" ;;
    esac

    local priv
    priv=$(dialog_radiolist "Privilege Escalation Tool" \
        "doas" "doas — minimal, simple config (default)" "${on_doas}" \
        "sudo" "sudo — full-featured, sudoers" "${on_sudo}") \
        || return "${TUI_BACK}"

    if [[ -z "${priv}" ]]; then
        return "${TUI_BACK}"
    fi

    PRIV_TOOL="${priv}"
    export PRIV_TOOL

    einfo "User: ${USERNAME} (${FULLNAME:-no full name}), groups: ${USER_GROUPS}, priv: ${PRIV_TOOL}"
    return "${TUI_NEXT}"
}
