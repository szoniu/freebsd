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

## Release-version verification

- [ ] **15.0 vs 14.x bsdinstall internals.** Re-verify on real media: the
  de-facto `ZFSBOOT_*` / `nonInteractive` knobs against
  `usr.sbin/bsdinstall/scripts/zfsboot` for the target branch (14.2/14.3/15.0);
  `ZFSBOOT_POOL_CREATE_OPTIONS` default (differs by version — we set it
  explicitly); single-stage `loader.efi` path; `efibootmgr` flags; fixed 260M
  ESP; 2g vs 4g swap default; `pciconf -lv` dual format (`vendor=`/`device=` vs
  legacy `chip=0xDDDDVVVV`) — test the GPU/WiFi parser on both 14.x and 15.0
  live media.

## Security / boot

- [ ] **Secure Boot status note.** No Secure Boot enrollment is performed
  (the Linux family's shim+MOK flow does not port — FreeBSD has no signed shim
  in the ports tree and `loader.efi` is unsigned). Document in README that
  Secure Boot must be disabled in firmware before install, and track whether a
  future signed-loader path becomes viable.
