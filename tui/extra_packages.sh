#!/usr/bin/env bash
# tui/extra_packages.sh — Extra pkg, optional Wayland shell (Noctalia), gaming.
#
# FreeBSD translation of the Void extra-packages screen. The Linux original is a
# big checklist of distro-specific extras (flatpak, v4l-utils, fprintd, bolt,
# ModemManager, asusctl, nonfree-repo, ...). On FreeBSD none of that applies:
#   * pkg has a single repo — there is NO "nonfree" split, so no nonfree toggle.
#   * Peripheral daemons (fingerprint/thunderbolt/WWAN/IIO) have no FreeBSD
#     equivalents worth wiring here; webcam is webcamd, handled elsewhere.
#   * Surface iptsd is Linux-only (DESIGN.md device caveats) — not offered.
# What remains, per the locked contract, is the small portable core:
#   1. A free-form EXTRA_PACKAGES line (any pkg origin/name, space-separated).
#   2. Noctalia — a Quickshell-based Wayland shell — with a compositor choice.
#   3. Gaming (Steam/wine/gamescope), flagged limited/experimental on FreeBSD.
#
# We only RECORD the choices here (ENABLE_NOCTALIA / NOCTALIA_COMPOSITOR /
# ENABLE_GAMING / EXTRA_PACKAGES); the actual pkg install runs later in the
# `extras` phase via chroot_pkg, which already honors DRY_RUN.
source "${LIB_DIR}/protection.sh"

screen_extra_packages() {
    # --- Step 1: free-form extra packages ---------------------------------
    # No checklist of canned extras: on FreeBSD the user just names pkg origins
    # or short names. Default empty (sane default = install nothing extra).
    local extra
    extra=$(dialog_inputbox "Extra Packages" \
        "Additional pkg to install (space-separated, optional).\n\nExamples: git neovim htop fastfetch tmux\n\nLeave empty to skip." \
        "${EXTRA_PACKAGES:-}") || return "${TUI_BACK}"

    # Squeeze stray whitespace so the later `pkg install ${EXTRA_PACKAGES}`
    # word-split is clean and the summary reads tidily.
    extra=$(printf '%s' "${extra}" | tr -s '[:space:]' ' ')
    extra="${extra# }"; extra="${extra% }"
    EXTRA_PACKAGES="${extra}"
    export EXTRA_PACKAGES

    # --- Step 2: Noctalia Wayland shell -----------------------------------
    # Noctalia (Quickshell shell) needs a Wayland compositor underneath it.
    # dialog_yesno returns 0=yes, 1=no; the gum backend may also return 128 on
    # a phantom/real ESC. Capture the rc explicitly: a plain "No" (1) is a valid
    # answer and must NOT be confused with TUI_BACK — only an ESC/abort goes back.
    ENABLE_NOCTALIA="no"
    NOCTALIA_COMPOSITOR="${NOCTALIA_COMPOSITOR:-niri}"
    local yn_rc=0
    dialog_yesno "Noctalia Wayland Shell" \
        "Install Noctalia, a Quickshell-based Wayland shell?\n\nNoctalia runs on top of a Wayland compositor — you'll pick one next." \
        || yn_rc=$?
    case "${yn_rc}" in
        0)
            ENABLE_NOCTALIA="yes"
            # Compositor for Noctalia. Defaults to niri: per DESIGN.md it ships
            # as a reliable binary pkg on 14/15 amd64. sway is also reliable;
            # Hyprland's binary pkg is inconsistent (may need a ports build),
            # so it is offered but not the default.
            local on_niri="off" on_sway="off" on_hypr="off"
            case "${NOCTALIA_COMPOSITOR}" in
                sway)     on_sway="on" ;;
                hyprland) on_hypr="on" ;;
                *)        on_niri="on" ;;
            esac
            local compositor
            compositor=$(dialog_radiolist "Noctalia Compositor" \
                "niri"     "Scrollable-tiling Wayland compositor (reliable pkg)" "${on_niri}" \
                "sway"     "i3-compatible Wayland compositor (reliable)"         "${on_sway}" \
                "hyprland" "Dynamic tiling (binary pkg may need ports build)"    "${on_hypr}") \
                || return "${TUI_BACK}"
            [[ -z "${compositor}" ]] && return "${TUI_BACK}"
            NOCTALIA_COMPOSITOR="${compositor}"
            ;;
        1)
            ENABLE_NOCTALIA="no"
            ;;
        *)
            # ESC / abort on the yes/no — treat as going back a screen.
            return "${TUI_BACK}"
            ;;
    esac
    export ENABLE_NOCTALIA NOCTALIA_COMPOSITOR

    # --- Step 3: gaming stack ---------------------------------------------
    # Steam/wine/gamescope on FreeBSD is the Linux-binary-compat path and is
    # genuinely rough: warn loudly so the user opts in with eyes open.
    ENABLE_GAMING="no"
    yn_rc=0
    dialog_yesno "Gaming (experimental)" \
        "Install a gaming stack (Steam, wine, gamescope)?\n\nWARNING: gaming support on FreeBSD is LIMITED and EXPERIMENTAL — it relies on the Linux binary-compat layer, many titles will not run, and anti-cheat is unsupported. Only enable this if you intend to tinker." \
        || yn_rc=$?
    case "${yn_rc}" in
        0) ENABLE_GAMING="yes" ;;
        1) ENABLE_GAMING="no" ;;
        *) return "${TUI_BACK}" ;;
    esac
    export ENABLE_GAMING

    einfo "Extra packages: ${EXTRA_PACKAGES:-none}"
    if [[ "${ENABLE_NOCTALIA}" == "yes" ]]; then
        einfo "Noctalia Wayland shell: enabled (compositor: ${NOCTALIA_COMPOSITOR})"
    fi
    [[ "${ENABLE_GAMING}" == "yes" ]] && einfo "Gaming stack: enabled (experimental)"

    return "${TUI_NEXT}"
}
