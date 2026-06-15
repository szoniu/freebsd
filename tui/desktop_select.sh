#!/usr/bin/env bash
# tui/desktop_select.sh — Desktop environment / Wayland compositor selection
source "${LIB_DIR}/protection.sh"

# screen_desktop_select — pick DESKTOP_TYPE and derive DISPLAY_MANAGER.
#
# The DM mapping must stay in lockstep with lib/desktop.sh's _de_default_dm():
# kde/lxqt -> sddm, gnome -> gdm (bundled), xfce/mate/cinnamon -> lightdm. The
# Wayland compositors (sway/niri/hyprland/mango) and the "none" server profile
# get NO display manager — on FreeBSD they start from a tty login via seatd
# (there is no systemd-logind), so DISPLAY_MANAGER=none here.
screen_desktop_select() {
    local current="${DESKTOP_TYPE:-kde}"

    # radiolist wants per-tag on/off state; default to KDE (X11 path is the most
    # stable FreeBSD desktop in 2026) unless a previous pass set something else.
    local t
    local -A on=()
    for t in none kde gnome xfce mate cinnamon lxqt sway niri hyprland mango; do
        on[$t]="off"
    done
    if [[ -n "${on[${current}]:-}" ]]; then
        on[${current}]="on"
    else
        on[kde]="on"
    fi

    # Descriptions carry the FreeBSD-specific caveats from DESIGN.md §4 so the
    # user sees the trade-offs inline (no separate help screen in this family).
    local choice
    choice=$(dialog_radiolist "Desktop Environment" \
        "none"     "Server (no GUI) — base system only, tty login"        "${on[none]}" \
        "kde"      "KDE Plasma + SDDM — X11 path most stable on FreeBSD"   "${on[kde]}" \
        "gnome"    "GNOME + GDM — needs procfs in fstab"                   "${on[gnome]}" \
        "xfce"     "Xfce + LightDM — lightweight, reliable"                "${on[xfce]}" \
        "mate"     "MATE + LightDM — traditional, reliable"                "${on[mate]}" \
        "cinnamon" "Cinnamon + LightDM — X11-only on FreeBSD"              "${on[cinnamon]}" \
        "lxqt"     "LXQt + SDDM — minimal Qt desktop"                      "${on[lxqt]}" \
        "sway"     "Sway (Wayland) — tty login via seatd, reliable pkg"    "${on[sway]}" \
        "niri"     "niri (Wayland scrollable) — reliable binary pkg"       "${on[niri]}" \
        "hyprland" "Hyprland (Wayland) — pkg may need ports build"         "${on[hyprland]}" \
        "mango"    "Mango (Wayland dwl-based tiling) — reliable binary pkg" "${on[mango]}") \
        || return "${TUI_BACK}"

    # Empty selection (Cancel/ESC under some backends) — go back, don't advance.
    if [[ -z "${choice}" ]]; then
        return "${TUI_BACK}"
    fi

    DESKTOP_TYPE="${choice}"

    # Derive the display manager. Keep this in lockstep with _de_default_dm()
    # in lib/desktop.sh — Wayland compositors and the server profile use no DM.
    case "${DESKTOP_TYPE}" in
        kde|lxqt)                  DISPLAY_MANAGER="sddm" ;;
        gnome)                     DISPLAY_MANAGER="gdm" ;;
        xfce|mate|cinnamon)        DISPLAY_MANAGER="lightdm" ;;
        sway|niri|hyprland|mango)  DISPLAY_MANAGER="none" ;;
        none)                      DISPLAY_MANAGER="none" ;;
        *)                         DISPLAY_MANAGER="none" ;;
    esac

    export DESKTOP_TYPE DISPLAY_MANAGER

    einfo "Desktop type: ${DESKTOP_TYPE} (display manager: ${DISPLAY_MANAGER})"
    return "${TUI_NEXT}"
}
