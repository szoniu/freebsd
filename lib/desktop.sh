#!/usr/bin/env bash
# desktop.sh — Desktop environment + extras for FreeBSD.
#
# Runs in the OUTER process during the "desktop"/"extras" checkpoint phases and
# shells into the freshly installed system via chroot_pkg/chroot_sh (both already
# honor DRY_RUN). The GPU layer (drm-kmod, firmware flavors, kld_list, `video`
# group) is owned by gpu_install() in the prior "gpu" phase — we DON'T touch it
# here; desktop_install() only adds the X11/Wayland session prereqs on top.
#
# Key FreeBSD facts (DESIGN.md §3/§4), all different from the Linux siblings:
#   - No systemd-logind / elogind: Wayland sessions use seatd, and the user must
#     be in the `_seatd` group (`pw groupmod _seatd -m USER`) or the compositor
#     fails to acquire a seat. elogind and seatd conflict — we always pick seatd.
#   - Services are rc.conf knobs set with `sysrc NAME_enable=YES` (no symlink
#     farm like runit, no `systemctl enable`).
#   - PipeWire is a USER service on FreeBSD — there is NO pipewire_enable rc knob;
#     it autostarts per-session (XDG), so we only install the packages.
#   - GNOME/Cinnamon/LXQt/MATE need `proc /proc procfs rw 0 0` in the target
#     /etc/fstab or they misbehave (process listing, session bookkeeping).
#   - Display managers: SDDM (KDE/LXQt), GDM (GNOME), LightDM (Xfce/MATE/Cinnamon).
#     Wayland tiling compositors (sway/niri/hyprland/mango) have NO display
#     manager — they start from a tty login (seatd-backed).
source "${LIB_DIR}/protection.sh"

# _de_default_dm — default display manager for a desktop type (DESIGN.md §4).
# Empty string = no display manager (tty login, Wayland tiling compositors).
_de_default_dm() {
    case "$1" in
        kde|lxqt)         echo "sddm" ;;
        gnome)            echo "gdm" ;;
        xfce|mate|cinnamon) echo "lightdm" ;;
        *)                echo "" ;;   # sway/niri/hyprland: none
    esac
}

# _de_packages — DE meta-package(s) for a desktop type (DESIGN.md §4).
_de_packages() {
    case "$1" in
        kde)      echo "x11/kde" ;;
        gnome)    echo "x11/gnome" ;;
        xfce)     echo "x11-wm/xfce4" ;;
        mate)     echo "x11/mate" ;;
        cinnamon) echo "x11/cinnamon" ;;
        lxqt)     echo "x11-wm/lxqt" ;;
        sway)     echo "x11-wm/sway" ;;
        niri)     echo "x11-wm/niri" ;;
        hyprland) echo "x11-wm/hyprland" ;;
        mango)    echo "x11-wm/mango" ;;
        *)        echo "" ;;
    esac
}

# _de_is_wayland — Wayland tiling compositors use seatd + tty login (no DM, no
# Xorg). Everything else is an X11 desktop driven by a display manager.
_de_is_wayland() {
    case "$1" in
        sway|niri|hyprland|mango) return 0 ;;
        *)                        return 1 ;;
    esac
}

# _de_needs_procfs — these desktops need procfs mounted at /proc (DESIGN.md §4).
_de_needs_procfs() {
    case "$1" in
        gnome|cinnamon|lxqt|mate) return 0 ;;
        *)                        return 1 ;;
    esac
}

# _ensure_target_procfs — add `proc /proc procfs rw 0 0` to the TARGET's
# /etc/fstab, idempotently. GNOME/Cinnamon/LXQt/MATE expect a live /proc; the
# auto-ZFS/UFS bsdinstall fstab does not include it. Done via chroot_sh so the
# grep+append run against the installed system (and so DRY_RUN no-ops it).
_ensure_target_procfs() {
    einfo "Ensuring procfs entry in target /etc/fstab"
    try "Adding procfs to /etc/fstab" \
        chroot_sh "grep -q '[[:space:]]/proc[[:space:]]' /etc/fstab || printf 'proc\t\t/proc\t\tprocfs\trw\t0\t0\n' >> /etc/fstab"
}

# _install_pipewire — PipeWire is a USER service on FreeBSD (no rc.conf knob; it
# autostarts per-session via XDG). We only install the packages here.
_install_pipewire() {
    einfo "Installing PipeWire (user service — no rc.conf enable, autostarts per-session)"
    try "Installing PipeWire stack" \
        chroot_pkg pipewire wireplumber pipewire-spa-oss
}

# desktop_install — install the selected desktop environment + display manager.
# DESKTOP_TYPE=none -> server install, nothing to do.
desktop_install() {
    local desktop="${DESKTOP_TYPE:-none}"

    if [[ "${desktop}" == "none" ]]; then
        einfo "Desktop type 'none' — server install, skipping desktop layer"
        return 0
    fi

    einfo "=== Desktop installation: ${desktop} ==="

    local de_pkgs dm
    de_pkgs="$(_de_packages "${desktop}")"
    if [[ -z "${de_pkgs}" ]]; then
        ewarn "Unknown desktop type '${desktop}' — skipping desktop install"
        return 0
    fi

    # Display manager: honor an explicit DISPLAY_MANAGER choice, else the
    # per-DE default. "none" means tty login (always the case for Wayland
    # tiling compositors, which have no DM).
    dm="${DISPLAY_MANAGER:-}"
    if [[ -z "${dm}" || "${dm}" == "none" ]]; then
        dm="$(_de_default_dm "${desktop}")"
    fi

    # --- session prerequisites -------------------------------------------------
    # dbus is needed everywhere. Wayland tiling compositors need `wayland seatd`
    # (NOT Xorg); X11 desktops need `xorg`. drm-kmod + the `video` group are
    # already handled by the GPU phase.
    if _de_is_wayland "${desktop}"; then
        einfo "Installing Wayland session prereqs (wayland + seatd + dbus)"
        try "Installing Wayland prereqs" \
            chroot_pkg wayland seatd dbus
    else
        einfo "Installing X11 session prereqs (xorg + dbus)"
        try "Installing Xorg prereqs" \
            chroot_pkg xorg dbus
    fi

    # --- the desktop environment + display manager -----------------------------
    # Xfce's LightDM greeter is a separate package; pull it in alongside the DM.
    local -a dm_pkgs=()
    case "${dm}" in
        sddm)    dm_pkgs=(x11/sddm) ;;
        gdm)     dm_pkgs=(gdm) ;;
        lightdm) dm_pkgs=(lightdm lightdm-gtk-greeter) ;;
        "")      dm_pkgs=() ;;  # tty login (sway/niri/hyprland)
    esac

    # Install the DE. Hyprland's binary pkg is inconsistent across 14/15 amd64
    # (DESIGN.md §3) — keep it best-effort so a missing binary doesn't abort the
    # whole desktop phase, and point the user at the ports build.
    if [[ "${desktop}" == "hyprland" ]]; then
        if ! chroot_pkg ${de_pkgs}; then
            ewarn "Hyprland binary pkg '${de_pkgs}' unavailable — build it from ports: 'cd /usr/ports/${de_pkgs} && make install clean' on the target"
        fi
    else
        try "Installing ${desktop} (${de_pkgs})" \
            chroot_pkg ${de_pkgs}
    fi

    if [[ ${#dm_pkgs[@]} -gt 0 ]]; then
        try "Installing display manager (${dm})" \
            chroot_pkg "${dm_pkgs[@]}"
    fi

    # procfs for GNOME/Cinnamon/LXQt/MATE.
    if _de_needs_procfs "${desktop}"; then
        _ensure_target_procfs
    fi

    # --- enable services in rc.conf -------------------------------------------
    # dbus everywhere; seatd for Wayland; the display manager when there is one.
    einfo "Enabling desktop services (sysrc)"
    try "Enabling dbus" \
        chroot_sh "sysrc dbus_enable=YES"

    if _de_is_wayland "${desktop}"; then
        try "Enabling seatd" \
            chroot_sh "sysrc seatd_enable=YES"
    fi

    if [[ -n "${dm}" ]]; then
        try "Enabling ${dm}" \
            chroot_sh "sysrc ${dm}_enable=YES"
    fi

    # --- seat access for Wayland ----------------------------------------------
    # On FreeBSD there is no logind; the compositor acquires its seat through
    # seatd. Modern seatd guards its socket with `seatd_group` (default: video) —
    # there is NO `_seatd` group (a stale assumption: `pw groupmod _seatd` errors
    # "unknown group" and breaks the step). Pin the group to `video` and ensure
    # the user is in it (DESIGN.md §6 — the single most-forgotten step; the
    # compositor fails silently without seat access).
    if _de_is_wayland "${desktop}" && [[ -n "${USERNAME:-}" ]]; then
        try "Granting ${USERNAME} seat access (group video)" \
            chroot_sh "sysrc seatd_group=video; pw groupmod video -m ${USERNAME}"
    fi

    # --- audio ----------------------------------------------------------------
    _install_pipewire

    einfo "=== Desktop installation complete (${desktop}, DM: ${dm:-none/tty}) ==="
}

# install_extras — extra packages + optional community shells/gaming.
# Runs in the "extras" checkpoint phase. Everything is best-effort: a missing
# pkg warns and continues rather than aborting the install.
install_extras() {
    einfo "=== Installing extras ==="

    # --- user-chosen extra packages (space-separated list) --------------------
    if [[ -n "${EXTRA_PACKAGES:-}" ]]; then
        einfo "Installing extra packages: ${EXTRA_PACKAGES}"
        # Word-split intentionally: EXTRA_PACKAGES is a space-separated list.
        try "Installing extra packages" \
            chroot_pkg ${EXTRA_PACKAGES}
    else
        einfo "No extra packages selected"
    fi

    # --- Noctalia Wayland shell -----------------------------------------------
    # Pulls in the chosen compositor (niri/sway/hyprland) plus a best-effort
    # noctalia/quickshell from pkg. Compositor value is matched case-insensitively
    # (the TUI may emit "Hyprland"); fall back to niri (reliable binary pkg).
    if [[ "${ENABLE_NOCTALIA:-no}" == "yes" ]]; then
        local compositor="${NOCTALIA_COMPOSITOR:-niri}"
        compositor="$(printf '%s' "${compositor}" | tr '[:upper:]' '[:lower:]')"

        local comp_pkg=""
        case "${compositor}" in
            niri)     comp_pkg="x11-wm/niri" ;;
            sway)     comp_pkg="x11-wm/sway" ;;
            hyprland) comp_pkg="x11-wm/hyprland" ;;
            *)
                ewarn "Unknown Noctalia compositor '${compositor}', defaulting to niri"
                comp_pkg="x11-wm/niri"
                ;;
        esac

        einfo "Installing Noctalia compositor: ${comp_pkg}"
        # seatd is the seat backend for any standalone Wayland compositor; make
        # sure it's present + enabled + the user is in the group, in case the
        # main desktop wasn't a Wayland one (e.g. KDE + Noctalia on the side).
        try "Installing Wayland seat backend (seatd dbus wayland)" \
            chroot_pkg seatd dbus wayland
        try "Enabling seatd" \
            chroot_sh "sysrc seatd_enable=YES"
        if [[ -n "${USERNAME:-}" ]]; then
            try "Granting ${USERNAME} seat access (group video)" \
                chroot_sh "sysrc seatd_group=video; pw groupmod video -m ${USERNAME}"
        fi

        # Compositor binary pkg may be missing (esp. hyprland) — best-effort.
        if ! chroot_pkg ${comp_pkg}; then
            ewarn "Compositor pkg '${comp_pkg}' unavailable — build it from ports on the target"
        fi

        # noctalia-shell / quickshell are community/ports-tier — may not be in
        # the binary pkg repo yet. Warn instead of aborting if absent.
        if ! chroot_pkg noctalia-shell; then
            ewarn "noctalia-shell not in pkg — install from the Noctalia ports/repo on the target"
        fi
        if ! chroot_pkg quickshell; then
            ewarn "quickshell not in pkg — Noctalia needs it; build from ports on the target"
        fi
    fi

    # --- gaming ---------------------------------------------------------------
    # FreeBSD gaming support is LIMITED. `wine` is a NATIVE FreeBSD build (no
    # Linux ABI needed); Steam is the Linux binary via `linux-steam-utils`, which
    # runs on the Linuxulator. Install what's available, warn loudly on each miss.
    if [[ "${ENABLE_GAMING:-no}" == "yes" ]]; then
        ewarn "Gaming on FreeBSD is limited — Steam (linux-steam-utils) runs via the Linuxulator and may need manual setup; wine is native"
        local pkg
        for pkg in linux-steam-utils wine gamescope mangohud; do
            if ! chroot_pkg "${pkg}"; then
                ewarn "Gaming package '${pkg}' not available on FreeBSD pkg — skipping"
            fi
        done
    fi

    einfo "=== Extras complete ==="
}
