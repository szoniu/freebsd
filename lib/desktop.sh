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
#     be in the group guarding seatd's socket — that is `video` (seatd_group,
#     default video). There is NO `_seatd` group; `pw groupmod _seatd` errors
#     "unknown group". elogind and seatd conflict — we always pick seatd.
#   - "X11 desktop" is not the same as "no Wayland session". Plasma 6.6 installs
#     /usr/local/share/wayland-sessions/plasma.desktop alongside the X11 one, so
#     KDE needs seatd too — see _de_ships_wayland_session() below.
#   - Services are rc.conf knobs set with `sysrc NAME_enable=YES` (no symlink
#     farm like runit, no `systemctl enable`).
#   - PipeWire is a USER service on FreeBSD — there is NO pipewire_enable rc knob;
#     it autostarts per-session (XDG), so we only install the packages.
#   - GNOME/Cinnamon/LXQt/MATE need `proc /proc procfs rw 0 0` in the target
#     /etc/fstab or they misbehave (process listing, session bookkeeping).
#   - Display managers: ly (KDE), SDDM (LXQt), GDM (GNOME), LightDM (Xfce/MATE/
#     Cinnamon). Wayland tiling compositors (sway/niri/hyprland/mango) have NO
#     display manager — they start from a tty login (seatd-backed).
#   - SDDM CANNOT start a Wayland session on FreeBSD. It builds the target
#     console name as a LETTER ('a' + n - 1) while FreeBSD numbers VTs in hex
#     (ttyv0..ttyv9, ttyva, ttyvb) — so VT12 is /dev/ttyvb and SDDM looks for
#     /dev/ttyvl, fails to jump, and the compositor never gets DRM master. X11
#     is unaffected because there SDDM launches `Xorg vt9` and Xorg handles the
#     console itself. KDE therefore gets `ly`, which starts the session on the
#     SAME console it already runs on and sidesteps the bug entirely (issue #22).
#   - ly is NOT an rc.d service on FreeBSD. It hooks into getty: an entry in
#     /etc/gettytab plus a rewritten ttyv1 line in /etc/ttys. `sysrc ly_enable`
#     does nothing. The port ships its own setup script for this.
source "${LIB_DIR}/protection.sh"

# _de_default_dm — default display manager for a desktop type (DESIGN.md §4).
# Empty string = no display manager (tty login, Wayland tiling compositors).
_de_default_dm() {
    case "$1" in
        kde)              echo "ly" ;;    # SDDM cannot launch Wayland here — see header
        lxqt)             echo "sddm" ;;  # X11-only session; SDDM's VT bug never triggers
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

# _de_ships_wayland_session — TRUE for desktops that expose a Wayland session
# even though _de_is_wayland() classifies them as X11 (because they ship a
# display manager). Plasma 6.6 on 15.1 installs plasma.desktop into
# /usr/local/share/wayland-sessions, and kwin_wayland cannot take DRM master
# without libseat — so a KDE install that skipped seat management gave
#
#     kwin_wayland_drm: No suitable DRM devices have been found
#
# and the session died the moment it was picked. Field-found on the X1 Titanium
# (issue #21): after install, seatd was neither installed nor enabled.
#
# Deliberately separate from _de_is_wayland(): that helper answers "is this a
# DM-less tty-login compositor?", which drives Xorg-vs-wayland package choice
# and pam_xdg. Widening it would wrongly drop Xorg from KDE. This is the same
# split the devfs input rule below already had to make.
_de_ships_wayland_session() {
    case "$1" in
        kde|gnome) return 0 ;;
        *)         return 1 ;;
    esac
}

# _de_needs_seat — anything that can run a Wayland session needs seatd.
_de_needs_seat() {
    _de_is_wayland "$1" || _de_ships_wayland_session "$1"
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
    einfo "Installing PipeWire (user service — no rc.conf enable, starts per-session)"
    try "Installing PipeWire stack" \
        chroot_pkg pipewire wireplumber pipewire-spa-oss

    # ...and something has to actually START it (issue #25). The packages were
    # going in correctly all along; what was missing is the launch. On FreeBSD
    # there is no pipewire_enable rc knob and no systemd user unit, so the only
    # mechanism left is XDG autostart — which the port does not appear to ship.
    # Symptom when nothing starts it: the session log fills with
    # "received error while creating the stream ... Could not connect to PipeWire"
    # and audio/screencast are dead even though the codec was detected fine.
    #
    # Written idempotently (create only when absent) so this is correct either
    # way: if a future version of the port does ship an autostart entry, we
    # leave it alone instead of fighting it. Same approach the Void and Gentoo
    # siblings already take for their init systems.
    #
    # /usr/local/etc/xdg is FreeBSD's system XDG_CONFIG_DIRS root.
    einfo "Ensuring PipeWire XDG autostart (no rc knob, no systemd user units)"
    try "Installing PipeWire autostart entries" chroot_sh '
mkdir -p /usr/local/etc/xdg/autostart
if [ ! -e /usr/local/etc/xdg/autostart/pipewire.desktop ]; then
    cat > /usr/local/etc/xdg/autostart/pipewire.desktop <<PWEOF
[Desktop Entry]
Type=Application
Name=PipeWire Media System
Exec=/usr/local/bin/pipewire
Terminal=false
NoDisplay=true
X-GNOME-Autostart-Phase=Initialization
PWEOF
fi
if [ ! -e /usr/local/etc/xdg/autostart/wireplumber.desktop ]; then
    cat > /usr/local/etc/xdg/autostart/wireplumber.desktop <<WPEOF
[Desktop Entry]
Type=Application
Name=WirePlumber Session Manager
Exec=/usr/local/bin/wireplumber
Terminal=false
NoDisplay=true
X-GNOME-Autostart-Phase=Applications
WPEOF
fi
'
}

# _setup_ly — wire ly into getty on the target (it has no rc.d service).
#
# The port ships its own setup script (`@sample etc/ly/setup.sh.sample`, which
# pkg materialises as /usr/local/etc/ly/setup.sh). Prefer it: it is the
# vendor-supported path and will follow upstream if the wiring ever changes.
# Then VERIFY the result rather than trusting the exit status, and fall back to
# the wiring documented in issue #22 if ttyv1 is still on a plain getty.
#
# Deliberately does NOT write config.ini. pkg already drops one from
# config.ini.sample, and the dotfiles wizard later REPLACES that file with a
# symlink into the dotfiles repo (docs/ly-config.md). An installer-authored
# config would either be clobbered or would silently block that symlink.
_setup_ly() {
    einfo "Wiring ly into getty (no rc.d service on FreeBSD)"
    try "Running the ly port setup script" chroot_sh '
if [ -f /usr/local/etc/ly/setup.sh ]; then
    sh /usr/local/etc/ly/setup.sh || echo "ly setup.sh returned non-zero — verifying by hand"
elif [ -f /usr/local/etc/ly/setup.sh.sample ]; then
    sh /usr/local/etc/ly/setup.sh.sample || echo "ly setup.sh.sample returned non-zero — verifying by hand"
else
    echo "no ly setup script shipped by the port — using the documented wiring"
fi

# Verify, then repair. grep for an active Ly getty on ttyv1.
if grep -Eq "^ttyv1[[:space:]].*getty[[:space:]]+Ly" /etc/ttys; then
    echo "ly already wired on ttyv1"
    exit 0
fi

# gettytab entry (idempotent).
if ! grep -q "^Ly|" /etc/gettytab 2>/dev/null; then
    printf "\nLy|Ly Display Manager:\\\n\t:lo=/usr/local/bin/ly_wrapper:al=root:\n" >> /etc/gettytab
fi

# Point ttyv1 at it, keeping a backup of the original line.
cp -n /etc/ttys /etc/ttys.orig 2>/dev/null || true
sed -i "" -E "s|^ttyv1[[:space:]]+"[^"]*"([[:space:]]+.*)|ttyv1	"/usr/libexec/getty Ly"\1|" /etc/ttys

if grep -Eq "^ttyv1[[:space:]].*getty[[:space:]]+Ly" /etc/ttys; then
    echo "ly wired on ttyv1 (fallback path)"
else
    echo "WARNING: could not wire ly on ttyv1 — log in on a tty and run /usr/local/etc/ly/setup.sh"
fi
'
}

# _install_network_gui — a desktop with no way to join a WiFi network is not a
# desktop (issue #24). FreeBSD has no NetworkManager, so Plasma ships no network
# module: after install the only route to WiFi was hand-editing
# /etc/wpa_supplicant.conf from a console.
#
# wifimgr, not networkmgr: networkmgr is a GTK **tray icon** (Gtk.StatusIcon),
# and Plasma-Wayland exposes no StatusIcon host — it would simply never appear.
# It also pulls in `sudo`, which collides with a PRIV_TOOL=doas install. wifimgr
# is a plain GTK3 window with its own .desktop entry, so it shows up in the
# launcher under either session.
_install_network_gui() {
    einfo "Installing a GUI network manager (wifimgr)"
    chroot_pkg wifimgr || \
        ewarn "wifimgr not installed — WiFi will have to be configured via /etc/wpa_supplicant.conf"
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
        # ...plus seatd when the DE also ships a Wayland session (KDE/GNOME).
        # Xorg does its own VT/DRM handling, so X11 never needed this; the
        # Wayland session sitting in the same menu does.
        if _de_ships_wayland_session "${desktop}"; then
            einfo "${desktop} also ships a Wayland session — adding seatd"
            try "Installing seat backend (seatd + wayland)" \
                chroot_pkg seatd wayland
        fi
    fi

    # --- the desktop environment + display manager -----------------------------
    # Xfce's LightDM greeter is a separate package; pull it in alongside the DM.
    local -a dm_pkgs=()
    case "${dm}" in
        ly)      dm_pkgs=(x11/ly) ;;
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

    # --- Wayland session userland (tty compositors) -----------------------------
    # The compositor pkgs are BARE — no terminal, launcher, notifications,
    # screenshot tools, lock, wallpaper, portals or fonts — so the first session
    # would be unusable (DAILY-DRIVER-AUDIT "Poprawki — instalator" #2). Install
    # the standard set best-effort, one pkg at a time (mirroring the gaming
    # loop): the binary catalog may lack some, and a single miss must not abort
    # the desktop phase. Portals are per-compositor: niri implements the GNOME
    # portal interfaces (+ needs xwayland-satellite for X11 apps); the wlroots
    # family (mango/sway) uses xdg-desktop-portal-wlr for screencast/screenshot;
    # Hyprland ships its own backend (xdg-desktop-portal-hyprland).
    if _de_is_wayland "${desktop}"; then
        local -a wl_pkgs=(
            foot fuzzel mako grim slurp swaylock swaybg
            xdg-desktop-portal xdg-user-dirs
            noto-basic dejavu
        )
        case "${desktop}" in
            niri)       wl_pkgs+=(xdg-desktop-portal-gnome xwayland-satellite) ;;
            mango|sway) wl_pkgs+=(xdg-desktop-portal-wlr) ;;
            hyprland)   wl_pkgs+=(xdg-desktop-portal-hyprland) ;;
        esac
        einfo "Installing Wayland session userland: ${wl_pkgs[*]}"
        local wl_pkg
        for wl_pkg in "${wl_pkgs[@]}"; do
            if ! chroot_pkg "${wl_pkg}"; then
                ewarn "Wayland package '${wl_pkg}' not available in pkg — install it from ports on the target"
            fi
        done
    fi

    # --- enable services in rc.conf -------------------------------------------
    # dbus everywhere; seatd for Wayland; the display manager when there is one.
    einfo "Enabling desktop services (sysrc)"
    try "Enabling dbus" \
        chroot_sh "sysrc dbus_enable=YES"

    if _de_needs_seat "${desktop}"; then
        try "Enabling seatd" \
            chroot_sh "sysrc seatd_enable=YES"
    fi

    if [[ "${dm}" == "ly" ]]; then
        _setup_ly
    elif [[ -n "${dm}" ]]; then
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
    if _de_needs_seat "${desktop}" && [[ -n "${USERNAME:-}" ]]; then
        try "Granting ${USERNAME} seat access (group video)" \
            chroot_sh "sysrc seatd_group=video; pw groupmod video -m ${USERNAME}"
    fi

    # --- input device access ---------------------------------------------------
    # /dev/input/event* is 0600 root:wheel by default, so libinput running as the
    # user cannot open ANY input device: the compositor comes up and renders, but
    # the keyboard and touchpad are dead and there is no cursor — with no error
    # to go on. seatd does not hand these out on FreeBSD; the grant has to come
    # from devfs.rules. (kern.evdev.rcpt_mask already defaults to 12 on 15.1, so
    # permissions are the whole problem.)
    #
    # Applied to EVERY desktop, not just _de_is_wayland: this was field-found on
    # KDE, which that helper classifies as X11 because it ships a display
    # manager — yet Plasma exposes a Wayland session too. The user is already in
    # `video` (the gpu phase adds them), so no extra group juggling.
    if [[ "${desktop}" != "none" ]]; then
        einfo "Granting group video access to /dev/input/* (devfs.rules)"
        chroot_devfs_rule_add "input/*" 0660 video
    fi

    # --- XDG_RUNTIME_DIR for tty-started Wayland sessions -----------------------
    # These compositors have NO display manager: the session starts from a tty
    # login, and nothing creates /var/run/user/<uid> — so the very first
    # compositor start fails on a missing XDG_RUNTIME_DIR (DAILY-DRIVER-AUDIT
    # BLOCKER #1). pam_xdg(8) is in BASE on 14.x/15.x (field-tested on the
    # ProBook 15.1 — the README documents the same recipe against
    # /usr/local/etc/pam.d/sddm for the KDE case). tty logins go through the
    # BASE login(1) service, whose PAM policy is /etc/pam.d/login (ports keep
    # theirs under /usr/local/etc/pam.d/ — not this one). Idempotent: grep
    # before append; degrade to a note if pam_xdg is somehow absent.
    if _de_is_wayland "${desktop}"; then
        try "Enabling pam_xdg for tty logins (XDG_RUNTIME_DIR)" \
            chroot_sh 'if [ ! -e /usr/lib/pam_xdg.so.6 ] && [ ! -e /usr/lib/pam_xdg.so ]; then echo "pam_xdg not found in base — create XDG_RUNTIME_DIR manually (see POST-INSTALL notes)"; exit 0; fi; grep -q pam_xdg /etc/pam.d/login || printf "session\t\toptional\tpam_xdg.so\n" >> /etc/pam.d/login'
    fi

    # --- audio ----------------------------------------------------------------
    _install_pipewire

    # --- network GUI ----------------------------------------------------------
    _install_network_gui

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
