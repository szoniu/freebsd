#!/usr/bin/env bash
# laptop.sh — Generic laptop layer for the FreeBSD installer (the "laptop" phase).
#
# Runs in the OUTER process AFTER device_quirks and BEFORE extras, gated on the
# ACPI battery count (BATTERY_DETECTED, lib/hardware.sh) — unlike lib/umpc.sh it
# is NOT tied to a SMBIOS device profile, so any laptop benefits. It wires the
# pieces a daily-driver laptop needs that neither bsdinstall nor the desktop
# phase touch (docs/DAILY-DRIVER-AUDIT.md "Poprawki — instalator" #3/#4/#5/#7):
#
#   - powerd: adaptive CPU frequency scaling + deeper Cx idle states
#   - suspend: S3 ONLY — FreeBSD has no s0ix/s2idle (targeted at 15.2), so we
#     probe hw.acpi.supported_sleep_state ON THE LIVE SYSTEM (same hardware) and
#     either wire the lid switch to S3 or leave a LOUD "no suspend" note
#   - backlight: devfs.rules ruleset so the video group can write
#     /dev/backlight/* (backlight(8) without root)
#   - touchpad: the I2C-HID stack (ig4 + iichid) — safe everywhere, the modules
#     simply do not attach without matching hardware; plus psm(4) synaptics
#     extensions for PS/2 touchpads
#   - ThinkPad: acpi_ibm (hotkeys/fan/LED) when SMBIOS says LENOVO + ThinkPad
#   - wired-over-WiFi: dhclient knows nothing about interface metrics, so the
#     default route belongs to whichever interface got its lease LAST
#
# Everything lands on the target via chroot_* (DRY_RUN-aware) wrapped in try();
# kld_list appends reuse the idempotent _gpu_kld_list_append (lib/gpu.sh) and
# POST-INSTALL notes reuse the _quirk_note_* helpers (lib/umpc.sh).
source "${LIB_DIR}/protection.sh"

# laptop_setup_apply — entry point (called by progress.sh as the "laptop" phase).
laptop_setup_apply() {
    if [[ "${BATTERY_DETECTED:-0}" == "0" ]]; then
        einfo "No ACPI battery detected — skipping laptop phase (desktop/VM)"
        return 0
    fi

    einfo "=== Laptop configuration (${BATTERY_DETECTED} battery unit(s)) ==="
    _quirk_note_init

    _laptop_powerd
    _laptop_suspend
    _laptop_backlight
    _laptop_touchpad
    _laptop_thinkpad
    _laptop_wired_priority

    einfo "=== Laptop configuration complete ==="
}

# _laptop_wired_priority — make Ethernet win over WiFi (issue #27).
#
# dhclient(8) on FreeBSD has no notion of interface metrics: the default route
# is simply whatever the LAST lease installed. On a laptop with the cable in and
# a known WiFi network in range, that is a coin flip resolved anew on every
# boot — and when WiFi wins, traffic leaves over the slower link. The nastier
# half is DNS: `dhclient wlan0` rewrites /etc/resolv.conf with the wireless
# network's servers, and if those are unreachable from the wired network every
# lookup burns a timeout. The user-visible symptom is "the internet is crawling",
# with a link that tests perfectly fine.
#
# Field-observed on the X1 Titanium: `default ... UGS wlan0` while ue0 held an
# address and an active link but no default route. After the fix ping 1.1.1.1
# went from 100% loss to 1.5 ms.
#
# TWO layers, because neither covers the other's case: devd(8) reacts to
# cable hotplug, but at BOOT it races netif, which brings both interfaces up
# almost simultaneously. The dhclient exit hook is what makes boot deterministic.
#
# Interface names are resolved AT RUNTIME, never baked in here. The issue
# proposed detecting the wired NIC at install time, but the machine that found
# this bug was on `ue0` — USB Ethernet, i.e. a dongle that is not present during
# a PCI scan and can be swapped for a different one later. Enumerating at run
# time also means a docking station that appears as `cdce0` works with no
# reinstall.
_laptop_wired_priority() {
    einfo "Wiring Ethernet priority over WiFi (dhclient has no route metrics)"

    # devd: cable in -> drop wlan0; cable out -> bring it back. The subsystem
    # match is a regex over interface names, covering the usual wired drivers
    # (USB dongles first: ue/cdce/axge/ure, then on-board em/igb/igc/re/bge/msk).
    try "devd rule: wired link toggles wlan0" chroot_sh '
mkdir -p /usr/local/etc/devd
cat > /usr/local/etc/devd/wired-priority.conf <<DEVDEOF
# Installed by the FreeBSD TUI installer (laptop phase) — see issue #27.
# dhclient has no interface metrics, so a wired link must actively displace
# WiFi. Delete this file (and reload devd) to let both links coexist.
notify 10 {
    match "system"    "IFNET";
    match "subsystem" "(ue|cdce|axge|ure|em|igb|igc|re|bge|msk|alc)[0-9]+";
    match "type"      "LINK_UP";
    action "service netif stop wlan0 || true";
};

notify 10 {
    match "system"    "IFNET";
    match "subsystem" "(ue|cdce|axge|ure|em|igb|igc|re|bge|msk|alc)[0-9]+";
    match "type"      "LINK_DOWN";
    action "service netif start wlan0 || true";
};
DEVDEOF
'

    # dhclient exit hook: if a WiFi lease lands while a wired interface is up
    # and addressed, hand the default route and resolv.conf back to the cable.
    # Non-destructive on purpose — wlan0 keeps its address, so services reachable
    # only over WiFi keep working; just the OUTBOUND path moves to the cable.
    #
    # Quoting note, because this bit is a trap: the script is a SINGLE-quoted
    # bash string (nothing expands here) containing a QUOTED heredoc delimiter
    # (nothing expands in the target /bin/sh either), so every $ below belongs to
    # the hook at run time and reaches the file verbatim. The first draft used a
    # double-quoted string with backslash escapes and bash expanded $interface
    # while BUILDING the string — under `set -u` that is an "unbound variable"
    # abort, and without it would have silently written an empty case label.
    # Consequence of the quoted form: no single quotes inside the body.
    try "dhclient exit hook: restore wired default route + DNS" chroot_sh 'cat > /etc/dhclient-exit-hooks <<"HOOKEOF"
# Installed by the FreeBSD TUI installer (laptop phase) — see issue #27.
# dhclient sets the default route from whichever lease arrived last. At boot
# that races; this puts the cable back in front. Wired interfaces are
# enumerated at run time so a swapped USB-Ethernet dongle still works.
case "$interface" in
wlan*)
	for _if in $(ifconfig -l 2>/dev/null); do
		case "$_if" in
			lo*|wlan*|bridge*|tap*|tun*|vlan*|pflog*|pfsync*|epair*) continue ;;
		esac
		ifconfig "$_if" 2>/dev/null | grep -q "status: active" || continue
		ifconfig "$_if" 2>/dev/null | grep -q "inet " || continue

		_lease=/var/db/dhclient.leases.$_if
		[ -f "$_lease" ] || continue

		_gw=$(grep "option routers" "$_lease" 2>/dev/null | tail -1 | sed -e "s/.*routers //" -e "s/;//")
		_dns=$(grep "option domain-name-servers" "$_lease" 2>/dev/null | tail -1 | sed -e "s/.*servers //" -e "s/;//")

		if [ -n "$_gw" ]; then
			route delete default >/dev/null 2>&1
			route add default "$_gw" >/dev/null 2>&1
			logger -t dhclient-exit-hooks "wlan lease: default route restored via $_if ($_gw)"
		fi
		if [ -n "$_dns" ]; then
			echo "$_dns" | tr "," "\n" | sed -e "s/^/nameserver /" > /etc/resolv.conf
		fi
		break
	done
	;;
esac
HOOKEOF
chmod 644 /etc/dhclient-exit-hooks'

    _quirk_note_append <<'WIREDNOTE'

--- Ethernet has priority over WiFi ---
Plugging a cable stops wlan0 (devd rule: /usr/local/etc/devd/wired-priority.conf),
and a WiFi lease taken while the cable is up hands the default route and DNS back
to the wired interface (/etc/dhclient-exit-hooks).

This is deliberate, not a fault. dhclient(8) has no interface metrics, so without
it the default route belongs to whichever lease arrived last — traffic then leaves
over the slower link, and /etc/resolv.conf gets the wireless network's DNS servers.
If those are unreachable from the wired network, every lookup waits for a timeout
and the connection merely FEELS broken.

To let both links coexist: delete both files, then 'service devd restart'.

WIREDNOTE
}

# _laptop_powerd — adaptive CPU frequency + deeper idle states (DESIGN.md §6
# planned powerd for laptops but _emit_setup_script never emitted it).
# hiadaptive on AC (favors performance), adaptive on battery. Cx: C2 on AC
# keeps latency low, Cmax on battery saves the most power.
_laptop_powerd() {
    einfo "Enabling powerd (adaptive CPU frequency scaling)"
    try "Enabling powerd (-a hiadaptive -b adaptive)" \
        chroot_sh 'sysrc powerd_enable=YES powerd_flags="-a hiadaptive -b adaptive"'
    try "Setting Cx idle states (AC: C2, battery: Cmax)" \
        chroot_sh 'sysrc performance_cx_lowest=C2 economy_cx_lowest=Cmax'
}

# _laptop_suspend — S3-or-nothing. FreeBSD has NO s0ix/s2idle (modern-standby
# laptops often ship without S3; s2idle is targeted at 15.2). We probe the LIVE
# system's sysctl — the installer runs on the exact hardware being installed —
# and only wire the lid switch when S3 is actually offered AND a desktop was
# selected: on a headless install (DESKTOP_TYPE=none) a lid-triggered suspend
# would take the box off the network, so we only note that S3 exists. Never
# guess: waking a machine that suspended into an unsupported state needs a
# power cycle.
_laptop_suspend() {
    local states
    states=$(sysctl -n hw.acpi.supported_sleep_state 2>/dev/null) || states=""

    if [[ " ${states} " == *" S3 "* ]]; then
        if [[ "${DESKTOP_TYPE:-none}" == "none" ]]; then
            einfo "Suspend: S3 supported (${states}) — server install (no desktop), NOT wiring the lid switch"
            _quirk_note_append <<NOTE

=== Laptop — Suspend (S3 available, lid switch NOT wired) ===

This machine reports S3 in hw.acpi.supported_sleep_state (${states}), but this
is a server install (no desktop): the installer did NOT wire the lid switch —
closing the lid keeps the machine running (a lid-triggered suspend would take
it off the network). Manual suspend stays available:

  acpiconf -s 3

To make the lid suspend to RAM anyway:
  echo 'hw.acpi.lid_switch_state=S3' >> /etc/sysctl.conf
NOTE
            return 0
        fi

        einfo "Suspend: S3 supported (${states}) — wiring lid switch to S3"
        try "Setting hw.acpi.lid_switch_state=S3 (sysctl.conf)" \
            chroot_sh "grep -q '^hw.acpi.lid_switch_state=' /etc/sysctl.conf 2>/dev/null || echo 'hw.acpi.lid_switch_state=S3' >> /etc/sysctl.conf"
        # Let the operator group suspend without root: acpiconf(8) needs WRITE
        # access to /dev/acpi (root-only by default). devfs.conf(5) 'own'/'perm'
        # lines are enough here — /dev/acpi exists from boot, so the one-shot
        # rc.d/devfs pass applies them and no devfs.rules ruleset is needed.
        # This is what lets a desktop power menu run 'acpiconf -s 3' as the user.
        try "Granting group operator access to /dev/acpi (devfs.conf)" \
            chroot_sh "grep -q '^own[[:space:]]*acpi[[:space:]]' /etc/devfs.conf 2>/dev/null || printf '\n# freebsd-installer: let group operator suspend without root (acpiconf -s 3)\nown\tacpi\troot:operator\nperm\tacpi\t0660\n' >> /etc/devfs.conf"
        _quirk_note_append <<NOTE

=== Laptop — Suspend (S3 available) ===

This machine reports S3 in hw.acpi.supported_sleep_state (${states}). The
installer set hw.acpi.lid_switch_state=S3 in /etc/sysctl.conf, so closing the
lid suspends to RAM. Manual suspend:

  acpiconf -s 3

/dev/acpi is owned root:operator mode 0660 (set via /etc/devfs.conf), so
members of the 'operator' group can run 'acpiconf -s 3' without root — this is
what desktop power menus use.

Verify a full suspend/resume cycle early (screen, keyboard, WiFi). Intel WiFi
(iwlwifi) often needs a bounce after resume:  service netif restart wlan0
There is NO hibernation on FreeBSD. To disable lid suspend:
  sysctl hw.acpi.lid_switch_state=NONE   (and edit /etc/sysctl.conf)
NOTE
    else
        ewarn "Suspend: no S3 in hw.acpi.supported_sleep_state ('${states:-none}') — suspend UNAVAILABLE on this machine"
        _quirk_note_append <<NOTE

=== Laptop — Suspend NOT AVAILABLE (no S3) ===

hw.acpi.supported_sleep_state reports '${states:-none}' — no S3 (suspend to
RAM). FreeBSD does NOT support s0ix/modern standby ("s2idle" support is in
progress upstream, targeted around 15.2), so THIS MACHINE CANNOT SUSPEND:
closing the lid only blanks the screen; the battery keeps draining.

Some firmwares hide S3 behind a BIOS switch — check Setup for a "Sleep State"
option (e.g. ThinkPad: Config -> Power -> Sleep State = "Linux", may require a
BIOS update), then re-check:  sysctl hw.acpi.supported_sleep_state
If S3 appears, enable the lid switch:
  echo 'hw.acpi.lid_switch_state=S3' >> /etc/sysctl.conf
NOTE
    fi
}

# _laptop_backlight — let the video group drive /dev/backlight/* so backlight(8)
# and desktop brightness keys work without root. The persistence mechanics
# (devfs.rules + devfs_system_ruleset) live in chroot_devfs_rule_add, which the
# desktop phase also uses for input/* — sharing it keeps both rules in ONE
# [localrules=10] section instead of writing a second, ambiguous header.
_laptop_backlight() {
    einfo "Granting group video write access to /dev/backlight/* (devfs.rules)"
    chroot_devfs_rule_add "backlight/*" 0660 video
}

# _laptop_touchpad — enable the I2C-HID stack. Modern "Windows Precision"
# touchpads hang off an Intel I2C controller (ig4) speaking HID-over-I2C
# (iichid); this is THE path to full multitouch + libinput gestures (a PS/2 psm
# touchpad degrades to basic motion). Safe generically: the modules do not
# attach when no matching device exists (previously Surface-only, lib/umpc.sh).
# The psm synaptics hint improves PS/2 fallback and is inert otherwise.
_laptop_touchpad() {
    einfo "Enabling I2C touchpad stack (ig4 + iichid; modules are inert without the hardware)"
    _gpu_kld_list_append "ig4"
    _gpu_kld_list_append "iichid"
    chroot_loader_conf_set "hw.psm.synaptics_support" "1"
}

# _laptop_thinkpad — acpi_ibm(4) gives ThinkPads their hotkeys, fan readouts and
# LEDs. Detect via SMBIOS: maker contains LENOVO; the "ThinkPad ..." string
# lives in smbios.system.product on some generations and in .version on others
# (product is often just the machine type, e.g. "20UN..."), so check both.
_laptop_thinkpad() {
    local maker product version
    maker=$(kenv -q smbios.system.maker 2>/dev/null) || maker=""
    product=$(kenv -q smbios.system.product 2>/dev/null) || product=""
    version=$(kenv -q smbios.system.version 2>/dev/null) || version=""

    if [[ "${maker}" == *LENOVO* ]] && [[ "${product}" == *ThinkPad* || "${version}" == *ThinkPad* ]]; then
        einfo "ThinkPad detected (${version:-${product}}) — enabling acpi_ibm (hotkeys/fan)"
        _gpu_kld_list_append "acpi_ibm"
        _quirk_note_append <<NOTE

=== Laptop — ThinkPad extras (acpi_ibm) ===

acpi_ibm(4) was added to kld_list: Fn hotkeys, fan speed readout
(sysctl dev.acpi_ibm) and LED control. Note for recent generations: S3 suspend
may be hidden behind BIOS Config -> Power -> Sleep State = "Linux" (see the
Suspend section above for this machine's verdict).
NOTE
    fi
    return 0
}
