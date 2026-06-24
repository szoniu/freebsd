#!/usr/bin/env bash
# system.sh — Final system touch-ups for the FreeBSD installer.
#
# Almost ALL system config (hostname, /etc/hosts, base sysrc, timezone, console
# keymap, locale login.conf class + cap_mkdb, root/user accounts, pkg + shell
# layer, boot-critical loader.conf) is already done by the chrooted setup script
# that lib/bsdinstall.sh generates and bsdinstall(8) runs. We deliberately do NOT
# duplicate any of that here — re-doing it would only risk drift between the two
# code paths. This module is the LAST install phase ("finalize"): it re-asserts a
# couple of idempotent invariants, creates a ZFS rollback safety net, re-pins the
# EFI boot entry, writes a human-readable summary, and reclaims pkg cache.
#
# Everything here runs in the OUTER process and shells into the target via the
# chroot_* helpers (which honor DRY_RUN). Nothing in this file may hard-fail the
# install — by the time we reach finalize the system is already bootable, so a
# failure in any of these niceties must degrade to a warning, never an abort.
source "${LIB_DIR}/protection.sh"

# _system_efi_loader_path — echo the on-ESP path (chroot-relative) of the FreeBSD
# UEFI loader, probing the common locations bsdinstall lays down. The ESP is
# mounted at /boot/efi inside the target (see bsdinstall_mount_target). Newer
# bsdinstall installs efi/freebsd/loader.efi; the removable fallback is
# efi/boot/bootx64.efi. Returns empty if neither is present.
_system_efi_loader_path() {
    local p
    for p in /boot/efi/efi/freebsd/loader.efi /boot/efi/efi/boot/bootx64.efi; do
        if [[ "${DRY_RUN:-0}" == "1" ]] || [[ -f "${MOUNTPOINT}${p}" ]]; then
            printf '%s\n' "${p}"
            return 0
        fi
    done
    return 0
}

# _system_reassert_login_conf — make sure the login.conf capability DB is fresh.
# The setup script already ran cap_mkdb, but a re-run / --resume that re-entered
# finalize after a hand-edit (or a setup-script hiccup) could leave login.conf.db
# stale; the system reads the .db, not the text file, so a missing/old DB means
# the user's locale class silently does nothing. cap_mkdb is fully idempotent, so
# re-running it costs nothing and guarantees the class we appended is live.
_system_reassert_login_conf() {
    try "Rebuilding login.conf capability database (cap_mkdb)" \
        chroot_sh 'cap_mkdb /etc/login.conf'
}

# _system_create_baseline_be — ZFS-only: snapshot the pristine install as a named
# boot environment. freebsd-update/pkg auto-create BEs on later upgrades, but a
# clean post-install baseline gives the user an immediate, known-good rollback
# target ("bectl activate freebsd-install-baseline" from the loader menu) before
# they ever touch the system. Creation is <1s (snapshot+clone). UFS has no bectl
# at all, so we only warn there — there is no equivalent to fabricate.
_system_create_baseline_be() {
    if [[ "${FS_PROFILE:-zfs}" != "zfs" ]]; then
        ewarn "UFS profile: bectl/boot environments unavailable — skipping baseline BE"
        return 0
    fi
    # Best-effort: a pre-existing BE of the same name (e.g. a --resume that already
    # got here) makes bectl create fail; that is harmless, so don't let it abort.
    try "Creating baseline ZFS boot environment (freebsd-install-baseline)" \
        chroot_sh 'bectl create freebsd-install-baseline 2>/dev/null || true'
}

# _system_reassert_efi_entry — re-pin a "FreeBSD" UEFI boot entry pointing at the
# on-ESP loader. bsdinstall usually creates this already, so this is belt-and-
# suspenders for firmware that dropped/reordered it. NOTE: FreeBSD efibootmgr(8)
# is NOT the Linux one — it takes the loader by FILE PATH on the mounted ESP
# (-l/--loader <path>), with -c/--create to add it and -a/--activate to mark it
# bootable; it does NOT take Linux's --disk/--part. We do not pass --bootnext or
# reshuffle BootOrder (that could strip a working dual-boot entry). Entirely
# best-effort: skip silently on BIOS boot or if no loader file is found.
_system_reassert_efi_entry() {
    if ! is_efi; then
        einfo "BIOS boot — no EFI boot entry to assert"
        return 0
    fi
    local loader
    loader="$(_system_efi_loader_path)"
    if [[ -z "${loader}" ]]; then
        ewarn "No FreeBSD loader found on the ESP — leaving the firmware boot entry as bsdinstall set it"
        return 0
    fi
    # -c create, -a activate (mark bootable), -l loader path, -L label. Wrapped so
    # a duplicate/clash just warns: bsdinstall almost certainly already added it.
    try "Re-asserting FreeBSD UEFI boot entry (efibootmgr)" \
        chroot_sh "efibootmgr --create --activate --loader ${loader} --label FreeBSD 2>/dev/null || true"
}

# _system_write_postinstall_notes — drop a plain-text summary the user can read
# after first boot. Device-specific caveats (UMPC rotation/audio, Surface SAM,
# fan control, MT7922 WiFi) are APPENDED by lib/umpc.sh's own section — we only
# seed the file + a generic header + whatever DEVICE_PROFILE tells us at a glance,
# then point at the per-device section. Written via a single heredoc piped into
# chroot_sh so it lands at /root/POST-INSTALL-NOTES.txt inside the target.
_system_write_postinstall_notes() {
    local profile="${DEVICE_PROFILE:-generic}"
    local fs="${FS_PROFILE:-zfs}"
    local de="${DESKTOP_TYPE:-none}"
    local gpu="${GPU_VENDOR:-none}"
    local priv="${PRIV_TOOL:-doas}"
    local user="${USERNAME:-}"

    # Per-profile one-liner shown in the summary; the heavy device docs come from
    # umpc.sh. Surface/UMPC blockers are surfaced here so they're impossible to miss.
    local device_note=""
    case "${profile}" in
        gpd_pocket4)
            device_note="GPD Pocket 4 (UMPC): see the 'UMPC Quirks' section below. WiFi/Bluetooth (MediaTek MT7922) has NO FreeBSD driver — use wired/USB-Ethernet."
            ;;
        surface)
            device_note="Microsoft Surface: see the 'Surface' section below. Keyboard/touchpad on Laptop/Book/Studio route through SAM (no driver) — an external USB keyboard+mouse may be required."
            ;;
        *)
            device_note="Generic profile — no device-specific quirks applied."
            ;;
    esac

    # WiFi caveat is profile-independent (set by hardware detection); the note must
    # mirror what _system_configure_wifi actually did (auto-wired intel vs left alone).
    local wifi_note="WiFi: detected driver present."
    if [[ "${WIFI_SUPPORTED:-1}" == "0" ]]; then
        wifi_note="WiFi: NO FreeBSD driver for the detected chip (${WIFI_VENDOR:-unknown} ${WIFI_DEVICE_ID:-}) — use wired/USB-Ethernet."
    elif [[ "${WIFI_VENDOR:-}" == "intel" ]]; then
        wifi_note="WiFi: if_iwlwifi + wlan0 wired into rc.conf (WPA/SYNCDHCP). Add your SSID/PSK to /etc/wpa_supplicant.conf, then 'service netif restart wlan0' (or reboot). NB: iwlwifi tops out at 802.11ac — no WiFi 6 (ax)."
    else
        wifi_note="WiFi: ${WIFI_VENDOR:-unknown} chip detected (a driver may exist) but NOT auto-configured — add the right module to kld_list + 'wlans_<dev>0=wlan0' + 'ifconfig_wlan0=\"WPA SYNCDHCP\"' by hand (FreeBSD Handbook ch. Wireless)."
    fi

    local be_note="ZFS boot environments: 'bectl list' to view, 'bectl activate freebsd-install-baseline' to roll back to the pristine install."
    [[ "${fs}" != "zfs" ]] && be_note="UFS root: boot environments (bectl) are not available on this filesystem."

    einfo "Writing /root/POST-INSTALL-NOTES.txt..."
    # Body is built on the host and fed to the target via a quoted heredoc on the
    # chroot side, so no target-side expansion happens — the values are already
    # interpolated here. try() wraps it so a write failure just warns.
    try "Writing POST-INSTALL notes" chroot_sh "$(cat <<NOTESCRIPT
umask 077
cat > /root/POST-INSTALL-NOTES.txt <<'NOTESEOF'
================================================================
 ${INSTALLER_NAME} v${INSTALLER_VERSION} — POST-INSTALL NOTES
================================================================

What was configured
-------------------
- Filesystem profile : ${fs}
- Desktop / DE       : ${de}
- Graphics (GPU)     : ${gpu}
- Privilege tool     : ${priv}
- Primary user       : ${user:-<none>}
- Device profile     : ${profile}

System notes
------------
- ${be_note}
- ${wifi_note}
- Privilege escalation uses ${priv} (members of the 'wheel' group).
- Locale is set via an /etc/login.conf class (FreeBSD has no /etc/locale.conf);
  cap_mkdb /etc/login.conf was run so the change is live.

Device
------
- ${device_note}
  (Device-specific details, if any, are appended in the section(s) below.)
NOTESEOF
NOTESCRIPT
)"
}

# _system_configure_wifi — wire a SUPPORTED WiFi chip into the target's rc.conf so
# it actually comes up on first boot. Hardware detection (lib/hardware.sh) only SETS
# WIFI_VENDOR/WIFI_SUPPORTED — nothing else turns the driver on. So a generic laptop
# with e.g. Intel iwlwifi is detected, the user is (correctly) NOT pushed to wired
# bootstrap, yet the installed system boots with NO wlan interface: WiFi silently dead
# until hand-configured. We map the vendor to its kernel module, load it via kld_list,
# build wlan0 over it, and arm WPA+SYNCDHCP. We do NOT know the user's SSID/PSK, so we
# drop a 0600 /etc/wpa_supplicant.conf TEMPLATE — the plumbing is done, the user only
# fills in credentials. Only vendors we can map UNAMBIGUOUSLY to a single module are
# auto-wired (Intel iwlwifi today); realtek/atheros are left to the POST-INSTALL note
# because the module is ambiguous (rtw88 vs rtw89, ath vs ath10k) and a wrong kld is
# worse than none. All sysrc here is idempotent, so a --resume re-run is harmless.
# Best-effort: a failure must never abort an already-bootable install.
_system_configure_wifi() {
    # Unsupported chip (e.g. MT7922): nothing to wire — notes already say "use wired".
    if [[ "${WIFI_SUPPORTED:-1}" == "0" ]]; then
        einfo "WiFi: detected chip has no FreeBSD driver — leaving rc.conf untouched (wired bootstrap)"
        return 0
    fi

    local kmod="" parent=""
    case "${WIFI_VENDOR:-}" in
        intel)
            kmod="if_iwlwifi"; parent="iwlwifi0" ;;
        *)
            ewarn "WiFi: ${WIFI_VENDOR:-unknown} chip detected but not auto-wired (driver ambiguous) — see POST-INSTALL notes"
            return 0 ;;
    esac

    einfo "WiFi: wiring ${WIFI_VENDOR} (${kmod} -> wlan0) into rc.conf..."
    # Outer heredoc is UNQUOTED so ${kmod}/${parent} interpolate on the host; the inner
    # wpa_supplicant template uses a QUOTED heredoc so its body lands verbatim.
    try "Enabling WiFi driver ${kmod} + wlan0 (WPA/DHCP)" chroot_sh "$(cat <<WIFISCRIPT
sysrc kld_list+=${kmod}
sysrc wlans_${parent}=wlan0
sysrc ifconfig_wlan0="WPA SYNCDHCP"
if [ ! -e /etc/wpa_supplicant.conf ]; then
    ( umask 077; cat > /etc/wpa_supplicant.conf <<'WPAEOF'
# wpa_supplicant.conf -- fill in your network, then bring wlan0 up:
#     service netif restart wlan0      (or just reboot)
# Scan for visible SSIDs first with:   ifconfig wlan0 up scan
#
# network={
#     ssid="YOUR_SSID"
#     psk="YOUR_PASSWORD"
# }
WPAEOF
    )
fi
WIFISCRIPT
)"
}

# _system_pkg_clean — reclaim the pkg(8) download cache on the target. The gpu/
# desktop/extras phases pulled a lot of packages; their cached tarballs are dead
# weight on a fresh install. -a all, -y yes. Best-effort: a clean failure must
# not abort an otherwise finished install.
_system_pkg_clean() {
    try "Cleaning pkg cache (pkg clean -ay)" \
        chroot_sh 'pkg clean -ay 2>/dev/null || true'
}

# system_finalize — the "finalize" install phase (last in screen_progress).
# Short, robust, best-effort: every step degrades to a warning rather than
# aborting, because the system is already bootable by the time we get here.
system_finalize() {
    einfo "Finalizing system..."

    _system_reassert_login_conf
    _system_create_baseline_be
    _system_reassert_efi_entry
    _system_configure_wifi
    _system_write_postinstall_notes
    _system_pkg_clean

    einfo "System finalization complete (see /root/POST-INSTALL-NOTES.txt on the target)"
    return 0
}
