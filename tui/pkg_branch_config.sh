#!/usr/bin/env bash
# tui/pkg_branch_config.sh — pkg repository branch: quarterly | latest
#
# FreeBSD ships two package branches built from the same ports tree:
#   quarterly — a branch cut every three months that only takes security and
#               build fixes; what the base /etc/pkg/FreeBSD.conf points at.
#   latest    — rebuilt continuously from ports HEAD.
# For a desktop/daily driver the gap is real: measured on 15.1 (X1 Titanium,
# 2026-10), quarterly held hyprland 0.55.4 and mesa 26.1.3 while latest had
# 0.56.2 and 26.2.2 — the whole Wayland stack a minor version behind. For a
# server the stability of quarterly is the point, so the default depends on
# whether a desktop was selected.
#
# The choice is applied by _emit_pkg_repo_conf (lib/bsdinstall.sh), which writes
# BOTH repos (FreeBSD-ports and FreeBSD-ports-kmods) — never one without the other.
source "${LIB_DIR}/protection.sh"

screen_pkg_branch_config() {
    # A value from a preset (or from going Back and Forward again) wins; otherwise
    # derive the default from the desktop choice made on the previous screen.
    local current="${PKG_BRANCH:-}"
    if [[ -z "${current}" ]]; then
        if [[ "${DESKTOP_TYPE:-none}" == "none" ]]; then
            current="quarterly"
        else
            current="latest"
        fi
    fi

    local on_quarterly="off" on_latest="off"
    case "${current}" in
        latest) on_latest="on" ;;
        *)      on_quarterly="on" ;;
    esac

    local choice
    choice=$(dialog_radiolist "Package Branch" \
        "latest"    "Rolling, rebuilt from ports HEAD (recommended for a desktop)" "${on_latest}" \
        "quarterly" "Cut every 3 months, fixes only (recommended for a server)"    "${on_quarterly}") \
        || return "${TUI_BACK}"

    if [[ -z "${choice}" ]]; then
        return "${TUI_BACK}"
    fi

    PKG_BRANCH="${choice}"
    export PKG_BRANCH
    einfo "pkg branch: ${PKG_BRANCH} (ports + ports-kmods)"
    return "${TUI_NEXT}"
}
