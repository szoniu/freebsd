# TODO — FreeBSD TUI Installer

Honest list of planned work. The core install path (auto-ZFS / auto-UFS via
`bsdinstall script`, checkpointed post-install, `try()` recovery, gum TUI) is
implemented. The items below are deferred, partial, or unverified-on-hardware.

## Disk / partitioning

- [ ] **Real side-by-side dual-boot.** v0.1 forces `PARTITION_SCHEME=auto`
  (whole-disk wipe via `gpart destroy -F`). True dual-boot needs: shrink an
  existing NTFS/ext4/Linux partition, emit a manual `PARTITIONS="... GPT { ... }"`
  preamble that places FreeBSD into the freed space (not whole-disk), reuse the
  existing ESP (`ESP_PARTITION`/`ESP_REUSE` already in `CONFIG_VARS[]`), and add
  a FreeBSD boot entry without clobbering the Windows/Linux entry. Blockers:
  FreeBSD base ships no online NTFS/ext4 shrinker (the Linux family used
  `ntfsresize`/`resize2fs` + sfdisk; no in-base analogue), and auto-ZFS
  unconditionally destroys every disk in `ZFSBOOT_DISKS`. The dual-boot caveats
  in `lib/disk_select.sh` (header comment) and `tui/summary.sh` document the
  gap. `efibootmgr` on FreeBSD takes `-l /path/to/loader.efi` (NOT Linux
  `--disk/--part`) — re-derive the invocation, don't port the Linux one.

  **Research 2026-07 (sibling-parity audit — why it did NOT port 1:1):**
  - **Detection is already done and matches the siblings.** `lib/hardware.sh`
    (`detect_installed_oses`/`detect_esp`, `DETECTED_OSES[]`, `WINDOWS_ESP`,
    `ESP_PARTITIONS`, serialized into a preset var) mounts partitions and reads
    the GPT type / `bootmgfw.efi` — the same manual-scan approach the Linux
    family uses (they do NOT use os-prober for detection either; os-prober only
    runs at GRUB-config time). Today that output dead-ends at the `ERASE` safety
    gate in `tui/disk_select.sh` — it is never reused for install. No detection
    work is missing.
  - **The two real gaps are the partitioner and the boot entry, not detection.**
    Siblings own their partitioner (`disk_plan_dualboot` + `sfdisk --append`
    into free space, `_shrink_wizard` → `ntfsresize`/`resize2fs`/`btrfs resize`);
    we deliberately delegate partitioning to `bsdinstall`, which only does
    whole-disk. That delegation is the port's foundation — reworking it is what
    makes this expensive, not a missing feature.
  - **Bootloader model: follow porteux, not void/gentoo.** GRUB+os-prober does
    not port (FreeBSD has no GRUB and `loader.efi` doesn't probe foreign OSes).
    The in-family precedent is **porteux**, which dual-boots WITHOUT os-prober:
    shared ESP + a separate UEFI firmware entry per OS (`efibootmgr`), OS choice
    made in the firmware boot menu (no unified chainload menu). FreeBSD maps onto
    this cleanly — `lib/system.sh` already pins a "FreeBSD" UEFI entry; it just
    must stop being the *only* entry (preserve the Windows/Linux entry) and the
    ESP must be reused, not recreated.
  - **Recommended path — two steps, not one big feature:**
    - **C (cheap, honest UX first):** replace the bare `ERASE` gate with a screen
      that says the installer does no in-place shrink — free the space yourself,
      or the disk is sacrificed. A few lines; stops silently implying whole-disk
      is the only option.
    - **A (real dual-boot, UFS profile only):** user pre-shrinks; installer adds a
      partial-disk path (skip `gpart destroy -F`, emit a `PARTITIONS` preamble
      targeting existing free space), reuses `WINDOWS_ESP`, and adds the FreeBSD
      UEFI entry alongside Windows. ZFS-auto stays whole-disk (`ZFSBOOT_DISKS`
      can't target free space) — ZFS dual-boot would need a hand-rolled preamble,
      out of scope for A.
    - **B (full automatic shrink like the siblings): rejected** — needs in-base FS
      shrinkers absent from the memstick and abandoning `bsdinstall` for manual
      `gpart`; that is rewriting the port's foundation.

## Resume / idempotency

- [ ] **Cross-reboot disk-scan resume + config inference.** Today resume is
  within-session only: `/tmp` checkpoints (`screen_progress`) cover crash-and-rerun,
  and `try_resume_from_disk()` recovers a saved config from `/tmp` or a
  read-only ZFS-pool import (returns 0/2, no rc=1 "checkpoints-but-no-config"
  path). Missing vs the Linux family: full `infer_config_from_partition()` that
  reads an installed system after a reboot — `/etc/rc.conf` (hostname/keymap),
  `tzsetup` state, `/etc/fstab` (partitions/swap/FS profile), `/etc/login.conf`
  class (locale), installed-pkg DB (DE/GPU), `bectl list` (ZFS) — and pre-fills
  the wizard. Also: UFS-profile resume has no `bectl`, so scan must distinguish
  ZFS vs UFS targets.

## TUI backend

- [ ] **bsddialog backend verification.** gum is primary (bundled
  `data/gum.tar.gz`, then system `dialog`, then `whiptail`). 15.0-RELEASE base
  ships `bsddialog` instead of `dialog`; its flags differ from cdialog
  (e.g. `--menu`/`--radiolist` height/width/list-height arg order, exit-status
  conventions). Verify each `dialog_*` primitive against `bsddialog` and add it
  to the fallback chain in `init_dialog()` so the installer works with zero
  network on stock 15.0 media (no `pkg install gum` needed).

## Progress UI

- [ ] **Prettier progress UI (gauge, not scrolling output).** `screen_progress`
  runs phases with `LIVE_OUTPUT=1` (scrolling `tee` output). A `dialog_gauge`
  already exists in `lib/dialog.sh`; wire a per-phase percentage gauge for the
  short phases and keep the live terminal only for the long, chroot pkg phases
  (where streaming output is genuinely useful for diagnosis).

## Hardware / device caveats (verify on real media)

- [ ] **Automated ALC287 pindump on GPD Pocket 4.** `_quirk_gpd_audio_note()`
  (`lib/umpc.sh`) currently drops a commented `hint.hdaa.N.*` TEMPLATE into
  `/boot/device.hints` plus manual pindump instructions — NIDs are per-unit so
  values can't be hardcoded. Automate: run `dev.hdaa.N.pindump=1`, parse the NID
  table, generate the verb overrides, and write them. snd_hda(4), not ALSA —
  there is no amixer Auto-Mute to disable.
- [ ] **Surface touch via `iichid` investigation.** Surface SAM keyboard/touchpad
  on Laptop/Book/Studio route through SAM (no driver) — external USB kbd+mouse
  may be required even during install (documented in `lib/system.sh` notes).
  Touch on Go/Go2/Go3 *may* work via `iichid`/`ig4`/`hmt` (low confidence);
  IPTS touch/pen on Pro/Book needs Linux-only `iptsd` (no FreeBSD port). Probe
  `iichid`+`ig4` (`kld_list+="ig4 iichid"`, `loader.conf hw.usb.usbhid.enable=1`)
  on real Surface Go hardware and gate the rc.conf snippet on a positive result.
- [x] **UFS swap-on-ZFS avoidance.** Already handled: swap is always a dedicated
  `freebsd-swap` partition (optionally `swapN.eli`), never a swapfile-on-ZFS and
  never a zvol — see DESIGN.md §"Swap" and the UFS/ZFS preamble emitters in
  `lib/bsdinstall.sh`.

## Laptop daily-driver

Context: `docs/DAILY-DRIVER-AUDIT.md` ("Poprawki — instalator"). Done in the 2026-07 pass:
pam_xdg for tty-started Wayland sessions (`lib/desktop.sh` + POST-INSTALL note on
XDG_RUNTIME_DIR), the Wayland session userland set (foot/fuzzel/mako/grim+slurp/swaylock/
swaybg/portals per compositor/xdg-user-dirs/fonts; niri also gets xwayland-satellite), the
new battery-gated `laptop` phase (`lib/laptop.sh`: powerd + Cx states, S3-probed suspend,
backlight devfs.rules, ig4+iichid touchpad stack, ThinkPad acpi_ibm), `moused` only for
`DESKTOP_TYPE=none`, the unified iwlwifi verdict (802.11 a/b/g/n/ac since 14.3; ax in
progress), plus `tests/live-hw-check.sh` and `docs/LIVE-USB-CHECKLIST.md`.

- [ ] **WiFi first-boot credentials screen.** Optional wizard screen for SSID+PSK:
  write via `wpa_passphrase` into the target's `/etc/wpa_supplicant.conf` (0600) and
  set `create_args_wlan0="country XX"` from the locale. Today the system boots with
  wlan0 armed (Intel) but no credentials.
- [ ] **webcamd for WEBCAM_DETECTED.** The variable is detected but dead — install
  `multimedia/webcamd` + cuse, enable `webcamd_enable`, add the user to the `webcamd`
  group. The "webcam is webcamd, handled elsewhere" comment in `tui/extra_packages.sh`
  is not true today.
- [ ] **SSD trim.** ZFS: `zpool set autotrim=on zroot` in finalize; UFS: add `trim`
  to the fstab options for SSD targets.
- [ ] **Bluetooth opt-in.** `hcsecd`/`sdpd` enable behind an explicit toggle + an honest
  note: HID (mice/keyboards) mostly works, BT **audio does not**; AX201 BT is effectively
  dead on FreeBSD.
- [ ] **DEVICE_PROFILE=thinkpad.** Today ThinkPads get generic `acpi_ibm` in the laptop
  phase; a full profile (kenv maker=LENOVO + product/version ThinkPad*) could add
  per-model device.hints and notes (e.g. X1 Nano speaker pin quirks, TrackPoint).
- [ ] **Optional "Claude Code" extras step.** `sysrc linux_enable=YES` + `pkg install
  claude-code` + seed `~/.claude/settings.json` with `DISABLE_UPDATES=1` and
  `USE_BUILTIN_RIPGREP=0` (+ `pkg install ripgrep`); fdescfs `linrdlnk` caveat — see
  `docs/DAILY-DRIVER-AUDIT.md` "Claude Code na FreeBSD".
- [ ] **SOF/DMIC audio warning heuristic.** `pciconf -lv` matching 'Smart Sound' →
  POST-INSTALL warning that the internal DMIC microphone will never work (no SOF DSP
  driver) and speakers may need snd_hda pin quirks. `tests/live-hw-check.sh` already
  flags it pre-install; the installer itself does not yet.

## Release-version verification

- [ ] **15.0/15.1 vs 14.x bsdinstall internals.** Re-verify on real media: the
  de-facto `ZFSBOOT_*` / `nonInteractive` knobs against
  `usr.sbin/bsdinstall/scripts/zfsboot` for the target branch (14.2/14.3/15.0/15.1);
  `ZFSBOOT_POOL_CREATE_OPTIONS` default (differs by version — we set it
  explicitly); single-stage `loader.efi` path; `efibootmgr` flags; fixed 260M
  ESP; 2g vs 4g swap default; `pciconf -lv` dual format (`vendor=`/`device=` vs
  legacy `chip=0xDDDDVVVV`) — test the GPU/WiFi parser on both 14.x and 15.0/15.1
  live media.
- [ ] **15.1 pkgbase-by-default.** In 15.1 `bsdinstall` defaults to a packaged-base
  install unless `DISTRIBUTIONS` is set — we set `DISTRIBUTIONS="kernel.txz base.txz"`
  explicitly (`constants.sh` / `bsdinstall.sh`), which forces the legacy distset path,
  so the flip does NOT bite. Confirm on real 15.1 media that the distset extract still
  works and `/usr/freebsd-dist/*.txz` are present. (Major upgrade 14.x→15.1 of an
  existing box lives in the dotfiles wizard, not here.)

## Security / boot

- [ ] **Secure Boot status note.** No Secure Boot enrollment is performed
  (the Linux family's shim+MOK flow does not port — FreeBSD has no signed shim
  in the ports tree and `loader.efi` is unsigned). Document in README that
  Secure Boot must be disabled in firmware before install, and track whether a
  future signed-loader path becomes viable.
