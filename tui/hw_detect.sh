#!/usr/bin/env bash
# tui/hw_detect.sh — Hardware detection summary screen
#
# Runs detect_all_hardware (pciconf/sysctl/kenv/geom probes — see lib/hardware.sh)
# then shows the human-readable get_hardware_summary. This screen is informational:
# it always advances (TUI_NEXT) once the user acknowledges. Disk selection happens
# on the NEXT screen, so there is nothing to "reject" here.
#
# FreeBSD-specific extra: when the built-in WiFi has no working driver
# (WIFI_SUPPORTED=0 — e.g. the GPD Pocket 4's MediaTek MT7922, whose mt76 is
# in-tree but DISCONNECTED FROM BUILD, zero successful associations), we raise a
# loud separate warning. The pkg phases need a network; without a wired/USB
# connection the install cannot fetch drm-kmod, the desktop, or anything else.
source "${LIB_DIR}/protection.sh"

# screen_hw_detect — Detect hardware and show a summary.
# Returns: TUI_NEXT (0), TUI_BACK (1), TUI_ABORT (2)
screen_hw_detect() {
    # infobox returns immediately (no input) — gives feedback while the probes run.
    dialog_infobox "Hardware Detection" \
        "Scanning your hardware...\n\nThis may take a moment."

    # Populate CPU/GPU/WiFi/disks/ESP/OSes + device profile globals.
    detect_all_hardware

    # Render the multi-line summary (CPU, GPU + driver, WiFi, disks, ESP, OSes).
    local summary
    summary=$(get_hardware_summary)

    # msgbox blocks until the user acknowledges (ESC = Cancel = TUI_BACK).
    dialog_msgbox "Hardware Detected" "${summary}" || return "${TUI_BACK}"

    # FreeBSD blocker: built-in WiFi with no usable driver. Surface this as its
    # own prominent screen so it is not buried in the summary scroll — the user
    # must arrange a wired/USB-Ethernet/USB-tether link before the pkg phases.
    if [[ "${WIFI_SUPPORTED:-1}" == "0" ]]; then
        local wifi_warn
        wifi_warn="!!! BUILT-IN WIFI WILL NOT WORK !!!

Detected WiFi: ${WIFI_VENDOR:-unknown} ${WIFI_DEVICE_ID:-}

This wireless chip has NO working FreeBSD driver. On the GPD Pocket 4
the chip is a MediaTek MT7922 (AMD RZ616) whose mt76 driver is in-tree
but disconnected from the build — there are ZERO successful WiFi
associations. Bluetooth (a separate USB interface) is dead too.

The installer downloads packages (drm-kmod, the desktop, firmware) over
the network. You MUST provide a WIRED connection before continuing:

  * USB-C / USB Ethernet adapter (ure/cdce/axge)
  * USB tether from a phone
  * a supported USB WiFi dongle (rtwn/run)

Without one of these, the package-install phases will fail."
        dialog_msgbox "WiFi Not Supported — Wired Connection Required" "${wifi_warn}" \
            || return "${TUI_BACK}"
    fi

    return "${TUI_NEXT}"
}
