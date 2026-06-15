#!/usr/bin/env bash
# tui/network_config.sh — System hostname
source "${LIB_DIR}/protection.sh"

# screen_network_config — Prompt for the system hostname (RFC 1123 label).
# Returns: TUI_NEXT (0), TUI_BACK (1), TUI_ABORT (2)
#
# Networking itself is NOT configured here: the generated bsdinstall setup
# script enables DHCP on the first NIC via `sysrc ifconfig_DEFAULT=DHCP`
# (wildcard — works for any single interface, see docs/DESIGN.md). The only
# value this screen owns is HOSTNAME, which the setup script writes with
# `sysrc hostname="${HOSTNAME}"`. There is no mirror/repo picker on FreeBSD:
# the install sets (kernel.txz/base.txz) ship on the live memstick/DVD in
# /usr/freebsd-dist and distextract uses them with no network.
screen_network_config() {
    # RFC 1123 single-label hostname: 1–63 chars, alphanumerics and hyphens,
    # must not start or end with a hyphen. The unanchored class allows an
    # internal hyphen run but the leading/trailing anchors forbid edge hyphens.
    # (We accept a bare label, not an FQDN — FreeBSD's hostname is just the
    # label; domain resolution comes from DHCP/resolv.conf.)
    local hostname_re='^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$'

    local hostname
    while true; do
        hostname=$(dialog_inputbox "Hostname" \
            "Enter the system hostname (RFC 1123, e.g. freebsd):" \
            "${HOSTNAME:-freebsd}") || return "${TUI_BACK}"

        # Trim surrounding whitespace that a stray space could introduce.
        hostname="${hostname#"${hostname%%[![:space:]]*}"}"
        hostname="${hostname%"${hostname##*[![:space:]]}"}"

        if [[ -z "${hostname}" ]]; then
            dialog_msgbox "Invalid Hostname" \
                "The hostname cannot be empty." || return "${TUI_BACK}"
            continue
        fi

        if [[ ! "${hostname}" =~ ${hostname_re} ]]; then
            dialog_msgbox "Invalid Hostname" \
"\"${hostname}\" is not a valid hostname.

A hostname must:
  * be 1 to 63 characters long
  * contain only letters, digits, and hyphens (-)
  * not start or end with a hyphen" || return "${TUI_BACK}"
            continue
        fi

        # Valid — accept it.
        break
    done

    HOSTNAME="${hostname}"
    export HOSTNAME

    einfo "Hostname: ${HOSTNAME}"
    return "${TUI_NEXT}"
}
