#!/usr/bin/env bash
# umpc.sh — Device-specific quirks for the FreeBSD installer.
#
# Dispatches on ${DEVICE_PROFILE} (generic|gpd_pocket4|surface) and applies the
# best-effort FreeBSD workarounds for each. EVERYTHING here is FreeBSD-native;
# the Void reference (../void/lib/umpc.sh) is only borrowed for the *structure*
# of the POST-INSTALL note writing — the mechanisms differ completely:
#
#   Void (Linux)                       FreeBSD (here)
#   ----------------------------       ------------------------------------------
#   fbcon=rotate kernel cmdline    ->  NO console rotation at all (kern.vt.rotate
#                                      does not exist; D34221 unmerged). Rotation
#                                      is a DESKTOP-LAYER fix only — loader/console
#                                      stay sideways on a portrait UMPC.
#   amixer Auto-Mute runit service ->  snd_hda pin/quirk via /boot/device.hints
#                                      (hint.hdaa.N...); NIDs are per-unit so we
#                                      ship a TEMPLATE + pindump instructions, we
#                                      do NOT guess (a wrong pin kills audio).
#   gpd-fan DKMS + runit service   ->  NONE on FreeBSD (no gpd-fan analogue, EC is
#                                      autonomous) — POST-INSTALL note only.
#   iio-sensor-proxy auto-rotate   ->  NONE (no IIO/MXC6655 stack) — note only.
#
# All file writes land INSIDE the target via chroot_sh / chroot_exec (paths are
# relative to the installed root). The phase runs in the OUTER process with
# LIVE_OUTPUT=1; post-install commands go through try() so a failure offers the
# recovery menu. chroot_* helpers no-op under DRY_RUN.
source "${LIB_DIR}/protection.sh"

# Where the post-install cheat-sheet lives inside the target (root-only).
readonly _QUIRK_NOTES="/root/POST-INSTALL-NOTES.txt"

# device_quirks_apply — Entry point (called by progress.sh as the "device_quirks"
# phase). Dispatch on the SMBIOS-derived profile; generic hardware is a no-op.
device_quirks_apply() {
    case "${DEVICE_PROFILE:-generic}" in
        gpd_pocket4) _quirk_gpd_pocket4 ;;
        surface)     _quirk_surface ;;
        generic|*)
            einfo "Device profile generic — no device quirks to apply"
            return 0
            ;;
    esac
}

# _quirk_note_init — Make sure the notes file exists inside the target with tight
# perms (it can carry hardware-specific hints, keep it root-only).
_quirk_note_init() {
    try "Preparing POST-INSTALL notes" \
        chroot_sh "mkdir -p /root && touch '${_QUIRK_NOTES}' && chmod 0600 '${_QUIRK_NOTES}'"
}

# _quirk_note_append — Append a here-doc block (passed on stdin) to the notes
# file inside the target. We pipe the body through chroot so the heredoc is
# expanded HERE (by us) and written verbatim THERE. Best-effort (notes are
# documentation, not load-bearing) — never fail the phase on a note write.
_quirk_note_append() {
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        einfo "[DRY-RUN] would append POST-INSTALL note block to ${_QUIRK_NOTES}"
        cat >/dev/null
        return 0
    fi
    chroot "${MOUNTPOINT}" /bin/sh -c "cat >> '${_QUIRK_NOTES}'" || \
        ewarn "Could not append POST-INSTALL note (non-fatal)"
}

# ----------------------------------------------------------------------------
# GPD Pocket 4 (Ryzen 7 8840U / Radeon 780M, portrait 1200x1920 panel)
# ----------------------------------------------------------------------------
_quirk_gpd_pocket4() {
    einfo "Applying GPD Pocket 4 quirks..."
    _quirk_note_init

    _quirk_gpd_rotation
    _quirk_gpd_audio_note
    _quirk_gpd_fan_sensor_note
}

# _quirk_gpd_rotation — Desktop-layer portrait rotation.
#
# CRITICAL FreeBSD CAVEAT: there is NO console/loader rotation. kern.vt.rotate
# does not exist (the patch D34221 was never merged), so vt(4), the loader menu
# and the bsdinstall TUI all stay LANDSCAPE on the physically-portrait panel.
# Rotation only takes effect AFTER login, inside the compositor / X server. We
# therefore (a) write autostart rotation snippets to /etc/skel so future users
# inherit them, (b) copy them into the existing user's home, and (c) drop an
# Xorg config snippet. ${PANEL_ROTATION} is the transform (90 for the Pocket 4).
_quirk_gpd_rotation() {
    local rot="${PANEL_ROTATION:-90}"
    [[ -z "${rot}" || "${rot}" == "0" ]] && { einfo "  No panel rotation requested"; return 0; }

    # Map the numeric panel rotation to each layer's idiom.
    #   sway/niri "transform":  90  | 270   (degrees, eDP-1)
    #   xrandr    "--rotate":    right | left
    local xrandr_dir
    case "${rot}" in
        90)  xrandr_dir="right" ;;
        270) xrandr_dir="left" ;;
        *)   xrandr_dir="right" ;;
    esac

    einfo "  Writing desktop-layer rotation (transform ${rot} / xrandr ${xrandr_dir})..."

    # (a) sway: output line in the default config. The on-disk desktop module
    # owns the bulk of the config; we only need our rotation line present, so we
    # APPEND it (idempotent-ish — a duplicate output line is harmless, the last
    # one wins). Skel first, so new accounts inherit it.
    try "GPD: sway rotation (skel)" chroot_sh "
        mkdir -p /etc/skel/.config/sway
        printf '%s\n' 'output eDP-1 transform ${rot}' >> /etc/skel/.config/sway/config
    "

    # (b) niri: KDL block. niri merges multiple output blocks, so a standalone
    # rotation block is safe alongside whatever the desktop module wrote.
    try "GPD: niri rotation (skel)" chroot_sh '
        mkdir -p /etc/skel/.config/niri
        cat >> /etc/skel/.config/niri/config.kdl <<NIRIROT

// GPD Pocket 4 portrait panel — desktop-layer rotation (installer)
output "eDP-1" {
    transform "'"${rot}"'"
}
NIRIROT
    '

    # (c) Xorg snippet — for X11 sessions / SDDM-on-X greeters. Xorg honours a
    # Monitor "Rotate" directive on the internal panel. NOTE: under amdgpu the
    # internal panel is "eDP" at the Xorg layer (DRM calls it eDP-1); the
    # snippet below targets the modesetting/amdgpu Monitor by its Xorg name.
    # If the greeter still renders landscape, fall back to the xrandr one-liner
    # documented in the POST-INSTALL note.
    try "GPD: Xorg rotation snippet" chroot_sh "
        mkdir -p /usr/local/etc/X11/xorg.conf.d
        cat > /usr/local/etc/X11/xorg.conf.d/90-gpd-pocket4-rotate.conf <<'XORGROT'
# GPD Pocket 4 portrait panel rotation (installer).
# FreeBSD has NO console rotation (no kern.vt.rotate) — this only affects Xorg.
Section \"Monitor\"
    Identifier \"eDP\"
    Option \"Rotate\" \"${xrandr_dir}\"
EndSection
XORGROT
    "

    # (b') Copy the skel rotation configs into the already-created user's home so
    # the very first login is rotated too (skel only seeds NEW accounts, and the
    # user was created by bsdinstall before this phase). Resolve the home dir via
    # pw inside the chroot. Best-effort; chown to the user afterwards.
    if [[ -n "${USERNAME:-}" ]]; then
        try "GPD: copy rotation config into ${USERNAME}'s home" chroot_sh "
            home=\$(pw usershow -n '${USERNAME}' 2>/dev/null | awk -F: '{print \$9}')
            [ -n \"\${home}\" ] && [ -d \"\${home}\" ] || exit 0
            for sub in sway niri; do
                if [ -d /etc/skel/.config/\${sub} ]; then
                    mkdir -p \"\${home}/.config/\${sub}\"
                    cp -f /etc/skel/.config/\${sub}/* \"\${home}/.config/\${sub}/\" 2>/dev/null || true
                fi
            done
            chown -R '${USERNAME}:${USERNAME}' \"\${home}/.config\" 2>/dev/null || true
        "
    fi

    # Document the rotation + the Plasma/xrandr manual paths.
    _quirk_note_append <<NOTE

=== GPD Pocket 4 — Display rotation (${UMPC_MODEL:-Pocket 4}) ===

The Pocket 4 panel is physically PORTRAIT (mounted sideways). On FreeBSD there
is NO console/loader rotation: kern.vt.rotate does not exist (the vt patch
D34221 was never merged). The vt(4) text console, the loader menu and the
bsdinstall TUI all render LANDSCAPE on this panel — that is expected and
unavoidable for now. Rotation is a DESKTOP-LAYER fix applied AFTER login.

What the installer configured (transform ${rot}):
  - sway:  'output eDP-1 transform ${rot}'  in ~/.config/sway/config
  - niri:  output "eDP-1" { transform "${rot}" }  in ~/.config/niri/config.kdl
  - Xorg:  /usr/local/etc/X11/xorg.conf.d/90-gpd-pocket4-rotate.conf
           (Monitor "eDP"  Option "Rotate" "${xrandr_dir}")

If you use a different session:
  - Xorg / X11 ad-hoc:  xrandr --output eDP-1 --rotate ${xrandr_dir}
        (the connector may be "eDP" or "eDP-1" — check 'xrandr -q')
  - KDE Plasma (Wayland or X11): System Settings -> Display ->
        Orientation = Portrait (or run 'kscreen-doctor output.eDP-1.rotation.right').
  - Hyprland:  monitor = eDP-1, preferred, auto, 1, transform, 1   (1 == 90deg)

If rotation comes out the wrong way, flip ${rot} to the other value
(90 <-> 270, i.e. xrandr right <-> left).
NOTE
}

# _quirk_gpd_audio_note — ALC287 (Realtek HDA) on the Pocket 4.
#
# On FreeBSD audio goes through snd_hda(4), not ALSA — there is no amixer and no
# "Auto-Mute Mode" control to disable. The Realtek ALC287 needs per-pin verb
# overrides ("hint.hdaa.N...") in /boot/device.hints to route the internal
# speakers/headphone correctly. The exact NIDs are PER-UNIT (they vary by codec
# revision and BIOS) — guessing them can silence or damage routing, so we DO NOT
# guess. Instead we drop a commented TEMPLATE into /boot/device.hints and the
# discovery procedure into the notes. The user runs pindump, reads the NIDs and
# fills the template in.
_quirk_gpd_audio_note() {
    einfo "  Writing ALC287 snd_hda template + pindump instructions..."

    # Append a COMMENTED template to /boot/device.hints (inert until uncommented
    # and filled with real NIDs — we never enable a guessed pin).
    try "GPD: ALC287 device.hints template" chroot_sh '
        cat >> /boot/device.hints <<HDAATPL

# --- GPD Pocket 4 ALC287 snd_hda pin/quirk TEMPLATE (installer) ---
# These are DISABLED placeholders. NIDs are per-unit — do NOT enable blindly.
# Discover real values first (see /root/POST-INSTALL-NOTES.txt), then uncomment
# and edit. "0" below is the device unit (dev.hdaa.0); confirm with sysctl.
#hint.hdaa.0.config="gpioconfig"
#hint.hdaa.0.nid20.config="as=1 seq=0"     # internal speaker  (example NID)
#hint.hdaa.0.nid33.config="as=2 seq=15"    # headphone jack    (example NID)
#hint.hdaa.0.gpio.config="0=set"           # amp enable, if your unit needs it
HDAATPL
    '

    _quirk_note_append <<'NOTE'

=== GPD Pocket 4 — Audio (Realtek ALC287 via snd_hda) ===

FreeBSD drives this codec with snd_hda(4), NOT ALSA, so there is no amixer and
no "Auto-Mute Mode" toggle. If the internal speakers stay silent, the codec
needs per-pin verb overrides in /boot/device.hints. The exact pin NIDs are
PER-UNIT and the installer deliberately does NOT guess them (a wrong pin can
mute or mis-route audio). A commented template was appended to
/boot/device.hints — fill it in after discovering your NIDs:

  1. Find the HDA device unit (usually 0):
       sysctl dev.hdaa | sed -n 's/^\(dev.hdaa.[0-9]*\).*/\1/p' | sort -u

  2. Dump the current pin configuration for that unit (e.g. unit 0):
       sysctl dev.hdaa.0.pindump=1
       # then read the verbose codec/pin table from the kernel log:
       dmesg | grep -i hdaa
       # live pin/association map:
       sysctl dev.hdaa.0.nid

  3. Identify the speaker / headphone NIDs from that table, then edit the
     commented "hint.hdaa.0.nidNN.config=..." lines in /boot/device.hints,
     uncomment them, and reboot. snd_hda reads device.hints at boot.

  4. Per-session mixer (FreeBSD, not ALSA):
       mixer        # show levels
       mixer vol 100
       sysctl hw.snd.default_unit       # pick the right playback device

Reference: handbook "Setting Up Sound Cards" + snd_hda(4) man page, "Pin
configuration" / device.hints section.
NOTE
}

# _quirk_gpd_fan_sensor_note — Fan control + accelerometer auto-rotate.
# Neither has a FreeBSD implementation, so this is documentation only.
_quirk_gpd_fan_sensor_note() {
    einfo "  Writing GPD fan / accelerometer POST-INSTALL note (FreeBSD: none)..."

    _quirk_note_append <<'NOTE'

=== GPD Pocket 4 — Fan control & auto-rotate (FreeBSD: NOT available) ===

Fan control:
  There is no FreeBSD equivalent of the Linux gpd-fan driver/daemon. The only
  vendor knob (acpi_ibm) does not match this EC, and the Embedded Controller
  runs its own autonomous fan curve. Result: fans work but follow the firmware
  curve (louder / more aggressive than tuned Windows/Linux). Nothing to install.
  You can at least read temperatures:
       sysctl -a | grep -iE 'temperature|hw.acpi.thermal'

Accelerometer auto-rotate (MXC6655):
  Not supported. FreeBSD has no IIO subsystem and no iio-sensor-proxy analogue,
  so the screen will NOT auto-rotate with the device. Rotation is fixed to the
  portrait transform configured above; rotate manually if you flip the device.
NOTE
}

# ----------------------------------------------------------------------------
# Microsoft Surface (best-effort; many models partially/non-functional)
# ----------------------------------------------------------------------------
_quirk_surface() {
    einfo "Applying Microsoft Surface quirks (best-effort)..."
    _quirk_note_init

    # HID-over-I2C: ig4 (Intel I2C controller) + iichid (HID transport). This is
    # the only realistic path to the integrated touchpad/touch on the I2C-HID
    # models (Surface Go family). It does NOTHING for SAM-routed keyboards on
    # Laptop/Book/Studio — those have no FreeBSD driver at all. += (append) so we
    # don't clobber an existing kld_list (e.g. amdgpu/i915kms from the gpu phase).
    try "Surface: kld_list += ig4 iichid (HID-over-I2C)" \
        chroot_exec sysrc 'kld_list+=ig4 iichid'

    # USB-HID quirk handling needs the usbhid stack enabled in the loader. This
    # lives in loader.conf (read by the loader before the kernel), NOT rc.conf.
    try "Surface: loader.conf hw.usb.usbhid.enable=1" \
        chroot_exec sysrc -f /boot/loader.conf 'hw.usb.usbhid.enable=1'

    _quirk_note_append <<NOTE

=== Microsoft Surface caveats (${SURFACE_MODEL:-Surface}) — best-effort ===

FreeBSD support for Surface hardware is partial and very model-dependent. Read
this BEFORE relying on the machine.

Keyboard / touchpad:
  - Surface Laptop 1-6, Book 3, Laptop Studio: the built-in keyboard and
    touchpad are routed through the Surface Aggregator Module (SAM). FreeBSD
    has NO SAM driver, so they are DEAD. You will need an EXTERNAL USB keyboard
    and mouse -- including DURING THIS INSTALL if you somehow got here without
    one. There is no workaround on these models today.
  - Surface Pro / Surface Go Type Cover: works -- it is plain USB-HID
    (ukbd/hkbd/hms/hmt), not SAM.

Touch / pen:
  - Pro 4+, Book, Laptop, Studio use IPTS, which needs the Linux-only iptsd
    daemon. NOT available on FreeBSD -> no touch/pen on these models.
  - Surface Go / Go 2 / Go 3 touch MAY work via I2C-HID. The installer enabled
    the I2C-HID stack:
        sysrc kld_list+="ig4 iichid"        (in /etc/rc.conf)
        hw.usb.usbhid.enable=1              (in /boot/loader.conf)
    This is low-confidence -- verify after boot:
        kldstat | grep -E 'ig4|iichid'
        usbconfig ; sysctl dev.iichid

WiFi (chip-dependent):
  - Intel AX200 / AX201 (Go 2/3, Pro 7/8): iwlwifi, but 802.11 a/b/g only.
        sysrc kld_list+=if_iwlwifi ; sysrc wlans_iwlwifi0=wlan0
  - Qualcomm QCA6174 (original Go, many Pro 4-6): ath10k is disconnected from
    the build -> NO WiFi. Use a USB Ethernet/WiFi dongle.

Also NOT working on FreeBSD: Bluetooth, the cameras, the sensors, and S0ix/S3
suspend. Treat this as a desktop-on-the-go, not a fully-functional laptop.
NOTE
}
