#!/usr/bin/env bash
# tui/welcome.sh — Welcome screen + prerequisite checks
source "${LIB_DIR}/protection.sh"

# screen_welcome — First wizard screen
# Branding + a destructive-wipe / hardware notice + prerequisite gate.
# Returns: TUI_NEXT (0), TUI_BACK (1), TUI_ABORT (2)
screen_welcome() {
    local welcome_text
    welcome_text="Welcome to ${INSTALLER_NAME} v${INSTALLER_VERSION}

This wizard guides you through installing FreeBSD, from disk
partitioning to a working desktop.

The installer will:
  * Detect hardware (CPU, GPU, disks, WiFi)
  * Partition and format the target disk (ZFS or UFS)
  * Run bsdinstall (base + kernel) onto the target
  * Configure GPU drivers (drm-kmod), a desktop and services
  * Apply device quirks (GPD Pocket 4 / Surface) where detected

Requirements:
  * Root access            * amd64 CPU
  * Network connectivity   * UEFI (recommended)
  * 8 GiB+ target disk

Press OK to check prerequisites and continue."

    dialog_msgbox "Welcome" "${welcome_text}" || return "${TUI_ABORT}"

    # Architecture gate — checked FIRST, before any other prerequisite and
    # before anything touches the disk. This installer is amd64 only: bsdinstall,
    # the bundled amd64 gum binary and every pkg set are amd64-only. On ARM64
    # (the Snapdragon X "Surface Pro 11th / Laptop 7th") it would partition and
    # wipe the disk, then fail on the first amd64 chroot_exec — bricking the
    # machine. NOT bypassable with --force: an amd64 install cannot succeed on a
    # non-amd64 CPU.
    if ! is_supported_arch; then
        eerror "Unsupported architecture: $(uname -m 2>/dev/null || echo unknown)"
        dialog_msgbox "Unsupported architecture" \
"Detected CPU architecture: $(uname -m 2>/dev/null || echo unknown)

This installer supports ONLY amd64 (x86_64).

ARM64 / aarch64 machines — including the Microsoft Surface Pro 11th
Edition and Surface Laptop 7th Edition (Qualcomm Snapdragon X) and
other ARM laptops — are OUT OF SCOPE: bsdinstall here, the bundled gum
binary and the pkg sets are all amd64. Proceeding would wipe the disk
and then fail on the first chroot command.

Installation aborted. No changes were made to any disk."
        return "${TUI_ABORT}"
    fi

    # Destructive-wipe + hardware notice. Surfaced BEFORE the prereq results so
    # the user understands the stakes (and the WiFi caveat) up front. The WiFi
    # blocker is the big one: on the GPD Pocket 4 the built-in MediaTek MT7922
    # (RZ616, PCI 14c3:0616) has its mt76 driver disconnected from the FreeBSD
    # build — ZERO successful associations as of early 2026 — and some Surface
    # radios are likewise unsupported (WIFI_SUPPORTED=0). There is no driver to
    # "enable"; the only path is to bootstrap over a wired link: Ethernet, a
    # USB-C Ethernet dongle (ure/cdce), USB phone tethering, or a supported USB
    # WiFi stick (rtwn/run).
    local notice_text
    notice_text="Before you continue, please read:

  [!] DISK WIPE — the disk you select for an automatic install
      will be ERASED. Back up anything important first. (Dual-boot
      and manual schemes preserve other partitions; auto does not.)

  [!] WiFi may NOT work — the built-in WiFi on the GPD Pocket 4
      (MediaTek MT7922 / RZ616) and on some Surface models has no
      working FreeBSD driver. You MUST bootstrap over a wired link:
        - Ethernet or a USB-C Ethernet dongle (ure / cdce)
        - USB phone tethering
        - a supported USB WiFi stick (rtwn / run)

  [i] UEFI is recommended — boot the installer media in UEFI mode
      for the cleanest ESP + loader setup.

Continue?"

    dialog_yesno "Please read — disk wipe & WiFi" "${notice_text}" \
        || return "${TUI_ABORT}"

    # --- Prerequisite check ---
    local -a errors=()
    local -a warnings=()

    # Root check
    if ! is_root; then
        errors+=("Not running as root. Re-run with su/doas or as root.")
    fi

    # UEFI check (machdep.bootmethod == UEFI). Legacy BIOS still installs, but
    # the ESP/loader path is cleaner under UEFI — warn, do not block.
    if ! is_efi; then
        warnings+=("Not booted in UEFI mode (legacy BIOS). UEFI is recommended.")
    fi

    # Network check — needed for the pkg phases (GPU/desktop/extras). bsdinstall's
    # base+kernel come from the local dist sets, but pkg needs a working link;
    # WiFi may have no driver, so a wired link is the safe assumption.
    if ! has_network; then
        warnings+=("No network detected. A wired link is required for the pkg phases (built-in WiFi may have no driver — see above).")
    fi

    # Dialog backend (we are already inside it if we got here, but verify).
    if [[ -z "${DIALOG_CMD:-}" ]]; then
        errors+=("No dialog backend available.")
    fi

    # Build the status report.
    local status_text=""
    local has_errors=0

    status_text+="Prerequisite Check Results:\n\n"

    # Passes
    if is_root 2>/dev/null; then
        status_text+="  [OK] Running as root\n"
    fi
    status_text+="  [OK] Architecture: $(uname -m 2>/dev/null || echo amd64)\n"
    if is_efi 2>/dev/null; then
        status_text+="  [OK] UEFI boot mode\n"
    fi
    if has_network 2>/dev/null; then
        status_text+="  [OK] Network connectivity\n"
    fi
    status_text+="  [OK] Dialog backend: ${DIALOG_CMD:-unknown}\n"

    # Warnings
    local w
    for w in "${warnings[@]}"; do
        status_text+="\n  [!!] ${w}\n"
    done

    # Errors
    local e
    for e in "${errors[@]}"; do
        status_text+="\n  [FAIL] ${e}\n"
        has_errors=1
    done

    if [[ ${has_errors} -eq 1 ]]; then
        status_text+="\nCritical errors found. Installation cannot proceed."
        dialog_msgbox "Prerequisites — FAILED" "${status_text}"

        if [[ "${FORCE:-0}" != "1" ]]; then
            return "${TUI_ABORT}"
        fi

        # Force mode — warn but continue.
        dialog_yesno "Force Mode" \
            "Prerequisites failed but --force is set.\n\nContinue anyway? This may cause errors." \
            || return "${TUI_ABORT}"
    elif [[ ${#warnings[@]} -gt 0 ]]; then
        status_text+="\nWarnings found, but installation can proceed."
        dialog_yesno "Prerequisites — Warnings" "${status_text}" \
            || return "${TUI_ABORT}"
    else
        status_text+="\nAll prerequisites passed."
        dialog_msgbox "Prerequisites — OK" "${status_text}"
    fi

    return "${TUI_NEXT}"
}
