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

    einfo "=== Laptop configuration complete ==="
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
# and desktop brightness keys work without root. devfs(8) permissions are NOT
# persistent — they must come from a ruleset applied at boot: a section in
# /etc/devfs.rules + devfs_system_ruleset in rc.conf (devfs.rules(5); the
# [localrules=10] name/number follows the Handbook convention).
_laptop_backlight() {
    einfo "Granting group video write access to /dev/backlight/* (devfs.rules)"
    try "Writing devfs backlight ruleset (localrules)" chroot_sh "$(cat <<'DEVFSSCRIPT'
if ! grep -qs 'backlight' /etc/devfs.rules 2>/dev/null; then
    printf '\n[localrules=10]\nadd path '\''backlight/*'\'' mode 0660 group video\n' >> /etc/devfs.rules
fi
sysrc devfs_system_ruleset=localrules
DEVFSSCRIPT
)"
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
    try "Enabling psm synaptics extensions (loader.conf)" \
        chroot_exec sysrc -f /boot/loader.conf hw.psm.synaptics_support=1
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
