#!/bin/sh
# tests/live-hw-check.sh — READ-ONLY pre-install hardware diagnostics for
# FreeBSD live media (memstick). Answers "how well will FreeBSD run on THIS
# laptop?" BEFORE anything destructive: CPU/RAM, GPU, WiFi (per-chipset
# verdict), S3 suspend, battery, audio (incl. the Intel SOF/DMIC trap),
# I2C touchpad path, Thunderbolt/USB4, target disks.
#
# POSIX /bin/sh ON PURPOSE — the live memstick has NO bash, and this script is
# meant to run before any pkg bootstrap (see docs/LIVE-USB-CHECKLIST.md).
#
# Guarantees:
#   - NO destructive actions (no writes outside stdout, no sysctl sets).
#   - NO kernel module loading unless you explicitly pass --probe-kmods
#     (then it kldloads ig4+iichid to probe the I2C touchpad path; loading a
#     kmod is a system modification, hence opt-in).
#
# Usage (as root on the live system):
#   sh live-hw-check.sh [--probe-kmods]
#
# Exit status: 0 = no FAIL verdicts, 1 = at least one FAIL.
set -u

PROBE_KMODS=0
case "${1:-}" in
    --probe-kmods) PROBE_KMODS=1 ;;
    -h|--help)
        echo "usage: sh live-hw-check.sh [--probe-kmods]"
        echo "  --probe-kmods  also kldload ig4+iichid to probe the I2C touchpad (opt-in)"
        exit 0
        ;;
    "") : ;;
    *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
esac

if [ "$(uname -s 2>/dev/null || true)" != "FreeBSD" ]; then
    echo "This diagnostic is for FreeBSD live media only (uname -s != FreeBSD)." >&2
    exit 2
fi

PASS_N=0
FAIL_N=0
WARN_N=0
FAIL_LIST=""
WARN_LIST=""

section() { printf '\n=== %s ===\n' "$1"; }
pass() { PASS_N=$((PASS_N + 1)); printf '  [PASS] %s\n' "$1"; }
info() { printf '  [INFO] %s\n' "$1"; }
warn() {
    WARN_N=$((WARN_N + 1)); printf '  [WARN] %s\n' "$1"
    WARN_LIST="${WARN_LIST}  - $1
"
}
fail() {
    FAIL_N=$((FAIL_N + 1)); printf '  [FAIL] %s\n' "$1"
    FAIL_LIST="${FAIL_LIST}  - $1
"
}

# _pci_class_devices <class-pattern> — emit "vendorid deviceid name" per PCI
# device whose class matches (0x03 = display, 0x0280 = WiFi). Handles BOTH
# pciconf schemas: modern "vendor=0x.. device=0x.." and legacy "chip=0xDDDDVVVV"
# (device = high 16 bits, vendor = low 16). Same parser family as
# lib/hardware.sh — keep the two in sync.
_pci_class_devices() {
    pciconf -lv 2>/dev/null | awk -v cpat="$1" '
        /^[a-zA-Z].*@pci[0-9]+:/ {
            line=$0; want=(line ~ "class=" cpat)
            vid=""; did=""
            if (match(line, /vendor=0x[0-9a-fA-F]+/)) vid=substr(line, RSTART+9, 4)
            if (match(line, /device=0x[0-9a-fA-F]+/)) did=substr(line, RSTART+9, 4)
            if (vid=="" && match(line, /chip=0x[0-9a-fA-F]{8}/)) {
                c=substr(line, RSTART+7, 8); did=substr(c,1,4); vid=substr(c,5,4)
            }
            cur=want; cvid=tolower(vid); cdid=tolower(did); next
        }
        cur==1 && /device *=/ {
            name=$0; sub(/^[^=]*= *./,"",name); sub(/.$/,"",name)
            printf "%s %s %s\n", cvid, cdid, name; cur=0
        }
    '
}

printf 'FreeBSD live hardware check — %s — %s\n' "$(uname -r 2>/dev/null || echo '?')" "$(date 2>/dev/null || true)"

# --- CPU / RAM ------------------------------------------------------------
section "CPU / RAM"
ARCH=$(uname -m 2>/dev/null) || ARCH=""
CPU_MODEL=$(sysctl -n hw.model 2>/dev/null) || CPU_MODEL="unknown"
NCPU=$(sysctl -n hw.ncpu 2>/dev/null) || NCPU="?"
PHYSMEM=$(sysctl -n hw.physmem 2>/dev/null) || PHYSMEM=0
RAM_MIB=$((PHYSMEM / 1048576))
info "CPU: ${CPU_MODEL} (${NCPU} threads)"
info "RAM: ${RAM_MIB} MiB (hw.physmem)"
if [ "${ARCH}" = "amd64" ]; then
    pass "Architecture amd64 (installer requirement)"
else
    fail "Architecture '${ARCH}' — the installer is amd64-only"
fi
if [ "${RAM_MIB}" -ge 4096 ]; then
    pass "RAM >= 4 GiB"
else
    warn "RAM < 4 GiB — ZFS+desktop will be tight; consider the UFS profile"
fi

# --- GPU --------------------------------------------------------------------
section "GPU (pciconf class 0x03)"
GPU_SEEN=0
while read -r vid did name; do
    [ -z "${vid}" ] && continue
    GPU_SEEN=1
    case "${vid}" in
        8086)
            pass "Intel iGPU: ${name} [${vid}:${did}] — i915kms via drm-kmod. On 15.1: if GPU HANG appears, revert to drm-66-kmod"
            ;;
        1002)
            pass "AMD GPU: ${name} [${vid}:${did}] — amdgpu via drm-kmod. Phoenix (780M) needs ALL six firmware flavors or the kernel panics"
            ;;
        10de)
            warn "NVIDIA GPU: ${name} [${vid}:${did}] — proprietary nvidia-driver only; Wayland compositors effectively unsupported"
            ;;
        *)
            warn "Unknown GPU vendor ${vid}: ${name} [${vid}:${did}] — drm-kmod support unverified"
            ;;
    esac
done <<EOF
$(_pci_class_devices '0x03')
EOF
if [ "${GPU_SEEN}" = "0" ]; then
    fail "No PCI display controller detected (pciconf class 0x03)"
fi

# --- WiFi -------------------------------------------------------------------
section "WiFi (pciconf class 0x0280)"
WIFI_SEEN=0
while read -r vid did name; do
    [ -z "${vid}" ] && continue
    WIFI_SEEN=1
    case "${vid}" in
        8086)
            pass "Intel WiFi: ${name} [${vid}:${did}] — iwlwifi: 802.11 a/b/g/n/ac since 14.3 (LinuxKPI, ~100-200 Mbps real); ax/WiFi 6 in progress (Foundation, 2026). Bounce wlan0 after suspend resume"
            ;;
        14c3)
            fail "MediaTek WiFi: ${name} [${vid}:${did}] — mt76 is DISCONNECTED FROM BUILD: zero association. Wired/USB-Ethernet required for install AND daily use"
            ;;
        10ec|0bda)
            warn "Realtek WiFi: ${name} [${vid}:${did}] — rtw88/rtw89 best-effort, module choice ambiguous; verify association on this live boot"
            ;;
        168c)
            warn "Atheros WiFi: ${name} [${vid}:${did}] — ath/ath10k; QCA61xx may be unbuilt (no WiFi). Verify on this live boot"
            ;;
        *)
            warn "WiFi vendor ${vid}: ${name} [${vid}:${did}] — FreeBSD support unverified"
            ;;
    esac
done <<EOF
$(_pci_class_devices '0x0280')
EOF
if [ "${WIFI_SEEN}" = "0" ]; then
    info "No PCI WiFi controller (USB WiFi or none) — wired install path recommended anyway"
fi
WLAN_DEVS=$(sysctl -n net.wlan.devices 2>/dev/null) || WLAN_DEVS=""
if [ -n "${WLAN_DEVS}" ]; then
    info "Attached wlan parent(s) on this live boot: ${WLAN_DEVS}"
else
    info "No wlan device attached on the live system (driver may need kld_list on the installed system)"
fi

# --- Suspend (S3) -------------------------------------------------------------
section "Suspend (ACPI sleep states)"
SLEEP_STATES=$(sysctl -n hw.acpi.supported_sleep_state 2>/dev/null) || SLEEP_STATES=""
case " ${SLEEP_STATES} " in
    *" S3 "*)
        pass "S3 supported (${SLEEP_STATES}) — suspend works: acpiconf -s 3 (installer will wire the lid switch)"
        ;;
    *)
        fail "No S3 in supported sleep states ('${SLEEP_STATES:-none}') — SUSPEND UNAVAILABLE (FreeBSD has no s0ix; s2idle targeted ~15.2). Check BIOS for a Sleep State option (ThinkPad: Config > Power > Sleep State = Linux, may need a BIOS update)"
        ;;
esac

# --- Battery -------------------------------------------------------------------
section "Battery"
BATT_UNITS=$(sysctl -n hw.acpi.battery.units 2>/dev/null) || BATT_UNITS=0
case "${BATT_UNITS}" in ''|*[!0-9]*) BATT_UNITS=0 ;; esac
if [ "${BATT_UNITS}" -gt 0 ]; then
    BATT_LIFE=$(sysctl -n hw.acpi.battery.life 2>/dev/null) || BATT_LIFE="?"
    pass "ACPI battery present (${BATT_UNITS} unit(s), charge ${BATT_LIFE}%) — the installer's laptop phase (powerd/suspend/backlight/touchpad) will apply"
else
    info "No ACPI battery — desktop/VM; the installer's laptop phase will be skipped"
fi

# --- Audio ---------------------------------------------------------------------
section "Audio"
SNDSTAT=$(cat /dev/sndstat 2>/dev/null) || SNDSTAT=""
if [ -n "${SNDSTAT}" ]; then
    printf '%s\n' "${SNDSTAT}" | while read -r sndline; do
        [ -n "${sndline}" ] && info "sndstat: ${sndline}"
    done
    pass "Sound device(s) registered (/dev/sndstat)"
else
    warn "No /dev/sndstat output — no sound device attached on the live boot (snd_hda not loaded, or unsupported codec path)"
fi
if pciconf -lv 2>/dev/null | grep -qi 'Smart Sound'; then
    warn "Intel Smart Sound (SOF) controller present — the internal DMIC microphone will NOT work on FreeBSD (no SOF DSP driver, likely never); speakers/jack may still work via legacy snd_hda, possibly needing device.hints pin quirks"
fi

# --- Touchpad (I2C-HID path) -----------------------------------------------------
section "Touchpad (I2C-HID: ig4 + iichid)"
I2C_CTRL=$(pciconf -lv 2>/dev/null | grep -iE 'serial ?io|i2c' | head -4) || I2C_CTRL=""
if [ -n "${I2C_CTRL}" ]; then
    info "I2C controller(s) present — a Windows-Precision touchpad likely hangs off I2C-HID:"
    printf '%s\n' "${I2C_CTRL}" | while read -r i2cline; do
        [ -n "${i2cline}" ] && info "  ${i2cline}"
    done
else
    info "No I2C controller matched in pciconf — touchpad may be PS/2 (psm: basic motion, degraded gestures)"
fi
if [ "${PROBE_KMODS}" = "1" ]; then
    if [ "$(id -u 2>/dev/null || echo 1)" != "0" ]; then
        warn "--probe-kmods needs root — skipping kldload probe"
    else
        info "Probing I2C touchpad path (kldload ig4 + iichid)..."
        kldload -n ig4 2>/dev/null || warn "kldload ig4 failed (no Intel I2C controller or module missing)"
        kldload -n iichid 2>/dev/null || warn "kldload iichid failed"
        IICHID_DEVS=$(sysctl dev.iichid 2>/dev/null | head -3) || IICHID_DEVS=""
        if [ -n "${IICHID_DEVS}" ]; then
            pass "iichid attached a device — I2C-HID touchpad path works (full multitouch/gestures possible)"
        else
            warn "No dev.iichid after probe — touchpad is not I2C-HID here (PS/2 fallback: basic motion, no real gestures)"
        fi
    fi
else
    info "Not loading kmods (pass --probe-kmods to test ig4+iichid attach on this boot)"
fi
if command -v libinput >/dev/null 2>&1; then
    info "libinput present — verify gestures: libinput debug-events (3-finger swipe should print GESTURE_SWIPE_BEGIN)"
else
    info "For the gesture verdict install libinput first (pkg install libinput), then: libinput debug-events"
fi

# --- Thunderbolt / USB4 ----------------------------------------------------------
section "Thunderbolt / USB4"
TB=$(pciconf -lv 2>/dev/null | grep -iE 'thunderbolt|usb4' | head -4) || TB=""
if [ -n "${TB}" ]; then
    info "TB/USB4 controller present. Verdict 2026: TB/USB4 DOCKS DO NOT WORK on FreeBSD; plain USB-C and DP alt-mode video DO work"
else
    info "No Thunderbolt/USB4 controller matched"
fi

# --- Disks -----------------------------------------------------------------------
section "Disks (install targets)"
DISKS=$(sysctl -n kern.disks 2>/dev/null) || DISKS=""
if [ -n "${DISKS}" ]; then
    for d in ${DISKS}; do
        case "${d}" in cd*|md*|fd*) continue ;; esac
        DSIZE=$(geom disk list "${d}" 2>/dev/null | sed -n 's/.*Mediasize:[^(]*(\([^)]*\)).*/\1/p' | head -1) || DSIZE=""
        DDESC=$(geom disk list "${d}" 2>/dev/null | sed -n 's/^[[:space:]]*descr:[[:space:]]*//p' | head -1) || DDESC=""
        info "/dev/${d}: ${DSIZE:-?} ${DDESC:-unknown} (the live medium is auto-excluded by the installer)"
    done
    pass "Disk enumeration OK (kern.disks)"
else
    fail "kern.disks returned nothing — no install target visible"
fi

# --- Summary ----------------------------------------------------------------------
section "Summary"
printf '  PASS: %s   WARN: %s   FAIL: %s\n' "${PASS_N}" "${WARN_N}" "${FAIL_N}"
if [ -n "${FAIL_LIST}" ]; then
    printf '\n  Blockers / hard misses:\n%s' "${FAIL_LIST}"
fi
if [ -n "${WARN_LIST}" ]; then
    printf '\n  Caveats to verify:\n%s' "${WARN_LIST}"
fi
if [ "${FAIL_N}" -gt 0 ]; then
    printf '\n  Verdict: at least one hard blocker above — read docs/DAILY-DRIVER-AUDIT.md before installing.\n'
    exit 1
fi
printf '\n  Verdict: no hard blockers detected. Continue with docs/LIVE-USB-CHECKLIST.md.\n'
exit 0
