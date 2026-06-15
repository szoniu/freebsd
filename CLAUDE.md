# CLAUDE.md — Project context for Claude Code (FreeBSD installer)

## What this is

Interactive TUI installer for **FreeBSD 14.x/15.0** written in Bash + `gum`. A faithful
port of a family of 6 sibling Linux installers (Void / Gentoo / …) to FreeBSD. Goal:
bootstrap `bash`/`gum` on the live memstick via `pkg`, clone the repo, run `./install.sh`,
and be guided from disk selection to a working desktop. `./install.sh --resume` recovers
an interrupted install.

Two things make FreeBSD fundamentally different from the Linux siblings:

1. **The base install is driven by `bsdinstall(8)` in scripted mode.** We do not partition,
   extract a rootfs, or install a bootloader ourselves — we **generate a bsdinstall script**
   (preamble + chrooted setup script) and let `bsdinstall script FILE` do the destructive
   base install (GPT, base.txz/kernel.txz, loader, root/user accounts, base sysrc).
2. **Single-process model — NO chroot re-invocation.** Unlike Void/Gentoo (which copy the
   installer into the target and re-`exec` themselves inside the chroot), our post-install
   phases (gpu / desktop / quirks / extras / finalize) run in the **OUTER process** and shell
   into the mounted target via `chroot_exec`/`chroot_sh`/`chroot_pkg`. `pkg`/`sysrc`/`pw` all
   exist in the freshly installed base, so a plain `chroot` is enough — there is no second
   "inner process" and no `__chroot_phase` argument.

The spec / research brief is **`docs/DESIGN.md`** (10-agent research workflow output). Read it
for bsdinstall templates, the hardware cheat-sheet, the graphics/desktop matrices, the device
caveats (GPD Pocket 4, Surface), and the live-media bootstrap sequence. `docs/HANDOFF.md`
tracks implementation status.

## Architecture

### Single-process flow (`install.sh main`)

```
full:      run_configuration_wizard → screen_progress → run_post_install
configure: run_configuration_wizard
install:   config_load → screen_progress → run_post_install
resume:    try_resume_from_disk → (config_load | wizard) → screen_progress → run_post_install
```

`screen_progress()` (`tui/progress.sh`) runs the checkpointed phases in order via `_run_phase`:
`preflight → bsdinstall → mount_target → gpu → desktop → device_quirks → extras → finalize`.
`bsdinstall` is the single destructive phase; `mount_target` re-imports/re-mounts the target
so the OUTER-process chroot phases can run.

### File structure

```
install.sh              — Entry point, arg parsing, source order, phase orchestration (main)

lib/                    — Library modules (SOURCED, never executed)
├── protection.sh       — Guard: aborts unless $_FREEBSD_INSTALLER is set
├── constants.sh        — Paths, sizes, GPT type aliases, ZFS/DRM/AMD-firmware/DISK_PROBE
│                         constants, TUI exit codes, CHECKPOINTS[], CONFIG_VARS[]
├── logging.sh          — _log + elog/einfo/ewarn/eerror/die, colors, file + stderr
├── utils.sh            — try() (recovery menu, text fallback w/o dialog, LIVE_OUTPUT via tee),
│                         checkpoint_set/reached/validate/clear/migrate_to_target,
│                         is_root/is_efi(machdep.bootmethod)/is_supported_arch(amd64-only)/
│                         has_network/ensure_dns(ping -t), check_dependencies,
│                         generate_password_hash (openssl passwd -6), try_resume_from_disk,
│                         countdown, bytes_to_human
├── dialog.sh           — TUI wrapper (bsddialog/gum/dialog/whiptail); primitives
│                         (msgbox/yesno/menu/radiolist/checklist/inputbox/passwordbox/
│                         infobox/textbox/gauge); register_wizard_screens + run_wizard;
│                         bundled gum extraction; dialogrc theme
├── config.sh           — config_save/load/dump/diff (${VAR@Q} quoting, umask 077),
│                         validate_config() pre-install safety gate
├── hardware.sh         — detect_all_hardware: CPU (sysctl hw.model/ncpu/physmem-BYTES),
│                         GPU (pciconf -lv, BOTH vendor=/device= and chip= formats; hybrid),
│                         WiFi (class 0x0280; WIFI_SUPPORTED gate), disks (kern.disks +
│                         geom + gpart show -p, boot medium excluded), ESP/Windows detect,
│                         DEVICE_PROFILE via kenv SMBIOS (Surface / GPD Pocket 4),
│                         get_hardware_summary, get_disk_list_for_dialog,
│                         serialize/deserialize_detected_oses, _gpu_driver_for
├── bsdinstall.sh       — bsdinstall_generate_script (preamble: ZFS/UFS; + chrooted setup
│                         script), bsdinstall_wipe_target (export pool/destroy/labelclear),
│                         bsdinstall_run, bsdinstall_mount_target, _mib_to_size,
│                         _resolve_part_by_type
├── chroot.sh           — chroot_exec / chroot_sh / chroot_pkg / chroot_teardown (all DRY_RUN-aware)
├── gpu.sh              — gpu_install: drm-kmod + AMD Phoenix firmware flavors + kld_list +
│                         video group (OUTER process, via chroot_*)
├── desktop.sh          — desktop_install: X11/Wayland prereqs, DE pkg, display manager,
│                         seatd/dbus, _seatd group; install_extras (Noctalia, gaming)
├── system.sh           — system_finalize: cap_mkdb re-assert, bectl baseline, efibootmgr
│                         re-pin, POST-INSTALL notes, pkg cache reclaim (the "finalize" phase)
├── umpc.sh             — device_quirks_apply: dispatch on DEVICE_PROFILE (generic /
│                         gpd_pocket4 / surface), best-effort FreeBSD workarounds + notes
├── hooks.sh            — maybe_exec 'before_<cp>' / 'after_<cp>'
└── preset.sh           — preset_export/import (PRESET_HW_VARS stripped → re-detected)

tui/                    — TUI screens (screen_*; each returns TUI_NEXT/BACK/ABORT)
├── welcome.sh          — screen_welcome: branding + destructive notice + prereq gate
│                         (arch/root/network); amd64-only, aborts on aarch64
├── preset_load.sh      — screen_preset_load: skip / file / browse
├── hw_detect.sh        — screen_hw_detect: detect_all_hardware + summary (informational)
├── disk_select.sh      — screen_disk_select: whole-disk auto only (v0.1); bare device name
├── filesystem_select.sh — screen_filesystem_select: ZFS (bectl) | UFS + optional GELI root
├── swap_config.sh      — screen_swap_config: dedicated freebsd-swap partition | none
│                         (NO zram, NO swapfile-on-ZFS) + optional swap encryption
├── network_config.sh   — screen_network_config: hostname (RFC 1123)
├── locale_config.sh    — screen_locale_config: timezone (tzsetup) + locale (login.conf
│                         class) + console keymap (vt)
├── gpu_config.sh       — screen_gpu_config: show detected GPU, override vendor
├── desktop_select.sh   — screen_desktop_select: DESKTOP_TYPE + derived DISPLAY_MANAGER
├── user_config.sh      — screen_user_config: root pw, user, groups (wheel,operator,video),
│                         doas/sudo
├── extra_packages.sh   — screen_extra_packages: extra pkg + Noctalia Wayland shell + gaming
├── preset_save.sh      — screen_preset_save: optional export (hw values stripped)
├── summary.sh          — screen_summary: validate_config + full summary + typed YES + countdown
└── progress.sh         — screen_progress: within-session resume + checkpointed phases (live output)

data/                   — Static assets
├── dialogrc            — Dark TUI theme (loaded via DIALOGRC)
└── gum.tar.gz          — Bundled gum v0.17.0 (FreeBSD/amd64 static binary)

docs/                   — DESIGN.md (the research brief / spec) + HANDOFF.md (status)
presets/                — example.conf
tests/                  — Standalone tests (test_config / test_hardware / test_checkpoint /
                          test_validate; shellcheck.sh)
hooks/                  — before_install.sh.example / after_install.sh.example
```

> Note: there is no `data/mirrors.sh`/`data/gpu_database.sh` (Void-only — pkg has no mirror
> picker and the GPU matrix lives inline in `lib/gpu.sh` / `docs/DESIGN.md`), no `kernel.sh`
> / `bootloader.sh` / `secureboot.sh` / `rootfs.sh` / `xbps.sh` (all subsumed by bsdinstall),
> and no `kernel_select` / `secureboot_config` / `desktop_config` screens.

### TUI screen conventions

Each screen is a `screen_*()` returning `TUI_NEXT`(0) / `TUI_BACK`(1) / `TUI_ABORT`(2).
`run_wizard()` in `lib/dialog.sh` advances/retreats the screen index by the return code; a
dialog **Cancel is treated as `TUI_BACK`**. Screens set `CONFIG_VARS` and `export` them.

`dialog_*` arity (getting this wrong makes the wizard "bounce back"):
- `dialog_menu "TITLE" tag desc tag desc …` — PAIRS, no prompt arg (the title carries meaning)
- `dialog_radiolist/dialog_checklist "TITLE" tag desc state tag desc state …` — TRIPLES
- `dialog_inputbox "TITLE" "TEXT" "default"` (3 args), `dialog_passwordbox "TITLE" "TEXT"` (2 args)
- `dialog_yesno "TITLE" "TEXT"`, `dialog_msgbox "TITLE" "TEXT"`, `dialog_infobox "TITLE" "TEXT"`,
  `dialog_textbox "TITLE" "FILE"`

### Configuration variables

All config vars live in `CONFIG_VARS[]` in `lib/constants.sh` (read it for the authoritative
list + inline value docs). Highlights vs the Linux siblings:

| Variable | Values | Note |
|---|---|---|
| `TARGET_DISK` | nda0/nvd0/ada0/da0/vtbd0 | bare name (NVMe-first probe; boot medium excluded) |
| `FS_PROFILE` | zfs / ufs | ZFS gets bectl; UFS does not |
| `BOOT_TYPE` | UEFI / BIOS / BIOS+UEFI / auto | auto = `machdep.bootmethod` |
| `GELI_ROOT` | 0 / 1 | full-disk geli root (test on quirky UEFI first) |
| `SWAP_TYPE` | partition / none | NO zram; NO swapfile-on-ZFS |
| `SWAP_ENCRYPTION` | 0 / 1 | → `swapN.eli` (one-time key; breaks hibernate) |
| `ARC_MAX_BYTES` | integer **BYTES** | `vfs.zfs.arc_max` — emit BYTES, never "4G" |
| `LOCALE` / `LOCALE_CLASS` | en_US.UTF-8 / english | locale is a `login.conf` class, not a file |
| `ROOT_PASSWORD_HASH` / `USER_PASSWORD_HASH` | `$6$…` | SHA-512 (`openssl passwd -6`); never plaintext, never `$y$` yescrypt |
| `USER_GROUPS` | wheel,operator,video | FreeBSD convention |
| `PRIV_TOOL` | doas / sudo | doas writes `/usr/local/etc/doas.conf` |
| `GPU_KMOD` | amdgpu / i915kms / nvidia-modeset | loaded via `kld_list`, never loader.conf |
| `DRM_PKG` | drm-kmod / drm-61-kmod / drm-66-kmod | metaport matches running kernel |
| `GPU_FW_FLAVORS` | space-separated | AMD Phoenix needs all six or it panics |
| `DEVICE_PROFILE` | generic / gpd_pocket4 / surface | from kenv SMBIOS |
| `WIFI_SUPPORTED` | 0 / 1 | 0 (e.g. MT7922) → warn, require wired bootstrap |
| `DESKTOP_TYPE` | none/kde/gnome/xfce/mate/cinnamon/lxqt/sway/niri/hyprland/mango | mango = dwl-based Wayland tiling (tty+seatd) |
| `DISPLAY_MANAGER` | sddm/gdm/lightdm/none | derived from DESKTOP_TYPE |
| `ENABLE_NOCTALIA` / `NOCTALIA_COMPOSITOR` | yes/no / niri/sway/hyprland | Wayland shell |
| `ENABLE_GAMING` | yes/no | Steam/wine/gamescope where available |

### bsdinstall script generation (`lib/bsdinstall.sh`)

`bsdinstall_generate_script()` renders `${BSDINSTALL_SCRIPT}` from CONFIG_VARS as two parts:

1. **PREAMBLE** (sh variable assignments, no shebang): `DISTRIBUTIONS="kernel.txz base.txz"`,
   `nonInteractive=YES`, then either `_emit_zfs_preamble` (`ZFSBOOT_DISKS`, `ZFSBOOT_VDEV_TYPE`,
   `ZFSBOOT_POOL_NAME`, `ZFSBOOT_CONFIRM_LAYOUT=0`, `ZFSBOOT_FORCE_4K_SECTORS=1`,
   `ZFSBOOT_POOL_CREATE_OPTIONS` **set explicitly**, optional `ZFSBOOT_BOOT_TYPE`/`SWAP_*`/
   `GELI_*`) or `_emit_ufs_preamble` (a single `PARTITIONS="DISK GPT { …M efi, …g freebsd-swap,
   auto freebsd-ufs / }"` line). `ROOTPASS_ENC` carries the root `$6$` hash (`%q`-quoted).
2. **SETUP SCRIPT** (after `#!/bin/sh`, runs LAST, chrooted in `/mnt`): `_emit_setup_script` —
   hostname/hosts, base sysrc, `tzsetup`, keymap, locale `login.conf` class + `cap_mkdb`, the
   user account (`pw useradd` + hash via stdin), `pkg bootstrap`/`pkg install bash git doas`,
   and boot-critical loader.conf (`zfs_load`, `vfs.zfs.arc_max`). The heredoc is expanded on
   the HOST so CONFIG_VARS interpolate into the file; `%q` is used for hashes/usernames.

The file is `chmod 600` (contains hashes). `bsdinstall_run()` = generate + wipe + `try
"…" bsdinstall script FILE`.

### Re-mount + chroot post-install phases

`bsdinstall` unmounts on completion. `bsdinstall_mount_target()` brings the target back up:
ZFS → `zpool import -fR ${MOUNTPOINT}` + `zfs mount -a`; UFS → mount the freebsd-ufs root +
ESP via `_resolve_part_by_type`. It also mounts `devfs` and copies `resolv.conf` so chrooted
`pkg` works. The `gpu`/`desktop`/`device_quirks`/`extras`/`finalize` modules then run in the
OUTER process and touch the target ONLY through `chroot_exec`/`chroot_sh`/`chroot_pkg` (all
DRY_RUN-aware). `chroot_teardown` (EXIT trap + end of `run_post_install`) unmounts devfs/ESP
and exports the pool.

### Checkpoints / resume

`checkpoint_set "name" [meta]` writes a file in `${CHECKPOINT_DIR}`; `checkpoint_reached`
tests it; `_run_phase` skips a phase whose checkpoint exists. After `mount_target`,
`checkpoint_migrate_to_target` moves checkpoints onto the target so a reformat clears them.

- **Within-session resume** (crash + re-run, /tmp checkpoints): `screen_progress()` counts
  completed checkpoints and offers to resume; "No" wipes the disk and starts over. **Works today.**
- **Cross-reboot resume** (`--resume`): `run_post_install` copies the config to
  `${MOUNTPOINT}/var/db/freebsd-installer/`; `try_resume_from_disk()` finds same-session config
  in /tmp OR imports each visible ZFS pool read-only and reads it back (returns 0 = recovered,
  2 = nothing). **Full disk-scan config *inference* from an installed system (the Void
  `infer_config_from_partition` path) is a TODO** — `try_resume_from_disk` only recovers a
  config we saved, it does not reconstruct one. `checkpoint_validate` still has Void-era cases
  (`vmlinuz`, `xbps`) that do not apply to FreeBSD; treat them as inert until reworked.

### `try` and logging

`try "description" cmd args…` wraps every fallible command; on failure it shows a
retry/shell/continue/log/abort menu (text fallback when `dialog` is missing, e.g. early
chroot). The whole `screen_progress` run sets `LIVE_OUTPUT=1`, so output streams to the
terminal via `tee` and the command's **real** exit code is read from `PIPESTATUS[0]` (tee's
exit must not mask it). Use `einfo/ewarn/eerror/elog`; `die` aborts.

## FreeBSD-specific patterns (all different from the Linux siblings)

- **`pkg`, not xbps/portage/apt.** `pkg bootstrap -f` → `pkg update -f` → `pkg install -y`.
  Non-interactive via `ASSUME_ALWAYS_YES=yes` (set by `chroot_pkg`). No mirror-picker screen.
- **`sysrc`/`rc.conf`, not runit/systemd.** Enable services with `sysrc foo_enable=YES`. There
  is no `/var/service` symlink dance. Use `sysrc -f /boot/loader.conf …` only for boot-critical
  knobs.
- **ZFS + `bectl`.** Root-on-ZFS is the default profile; surface boot environments prominently
  (`bectl create`/`activate`). UFS is the low-overhead alternative and has **no** bectl.
- **`drm-kmod` + AMD Phoenix firmware flavors.** `drm-kmod` is a metaport matching the running
  kernel (14.x → drm-61, 15.0 → drm-66). The Radeon 780M (gfx1103) needs **all six**
  `${AMD_PHOENIX_FW_FLAVORS}` — a missing/wrong flavor **panics the kernel** at amdgpu load.
- **amdgpu/i915kms load via `sysrc kld_list+=…`, NEVER loader.conf.** drm-kmod in loader.conf
  panics early boot (drm-kmod #100). Always use `kld_list` in rc.conf. (On some 14.3 boxes even
  `kld_list` froze boot → fallback is `kldload amdgpu` post-boot.)
- **`seatd`, not elogind/systemd-logind, for Wayland.** Install `wayland seatd dbus`, `sysrc
  seatd_enable=YES dbus_enable=YES`, and **`pw groupmod _seatd -m USER`** (commonly forgotten →
  the compositor fails silently). `elogind` and `seatd` conflict — pick seatd.
- **PipeWire is a USER service.** No `pipewire_enable` in rc.conf; it starts per-user via XDG
  autostart. Install `pipewire wireplumber pipewire-spa-oss`.
- **Locale via `login.conf` class + `cap_mkdb`, not `/etc/locale.conf`.** Append a class to
  `/etc/login.conf`, run `cap_mkdb /etc/login.conf` (the system reads the `.db`), and set the
  user's class with `pw usermod -L CLASS`.
- **Passwords: `openssl passwd -6` (SHA-512 `$6$`) + `pw … -H 0`.** Never `$y$` yescrypt (glibc-
  only, rejected by `pw -H 0`). Feed the hash via **stdin**, never argv: `printf %s "$HASH" |
  pw usermod -n USER -H 0`.
- **Swap = dedicated `freebsd-swap` partition (NO zram, NO swapfile-on-ZFS, NO zvol default).**
  Optional one-time-key encryption → `swapN.eli` (breaks hibernation). There is no zram analogue
  — do not promise it in the TUI.
- **`vfs.zfs.arc_max` in BYTES.** The "4G" form is sometimes rejected; emit a byte value
  (`finalize_config` caps `<=16 GiB` boxes at `physmem/3`).
- **MT7922 / RZ616 WiFi is unsupported (GPD Pocket 4 BLOCKER).** The `mt76` driver is in-tree but
  disconnected from the build → zero association. `WIFI_SUPPORTED=0` → warn and require wired /
  USB-Ethernet bootstrap. Surface WiFi is chip-dependent (AX200/AX201 partial via `iwlwifi`;
  QCA6174 dead).
- **No console/loader rotation on portrait UMPCs** (`kern.vt.rotate` does not exist) — bsdinstall
  renders sideways on the GPD Pocket 4; rotation is a desktop-layer concern only.
- **Surface SAM keyboard/touchpad** is dead on Laptop 1-6 / Book 3 / Studio → an external USB
  keyboard+mouse is required even during install. Type Cover works (USB-HID).
- **`efibootmgr` ≠ Linux.** FreeBSD's takes `-l /path/to/loader.efi`, not `--disk`/`--part`.
  Don't copy a Linux invocation.

## Known patterns and pitfalls

The whole installer runs under `set -Eeuo pipefail` + `shopt -s inherit_errexit`. The classic
set-e / pipefail / dialog-arity traps carried over from the Linux family that STILL apply:

- **`(( var++ ))` at `var=0` returns exit 1 under `set -e`** — always append `|| true`.
- **`cmd | grep …` inside `$()` aborts on no-match** (grep exits 1 + pipefail) BEFORE you can
  test `[[ -z "$var" ]]` — append `|| true` to the `$()`.
- **Never `[[ -n "$x" ]] && cmd` as a standalone statement** — if the test is false the line
  returns 1 and set -e fires. Use a full `if`. Don't let a function END on a failing test.
- **`dialog_*` arity** (see above) — adding a prompt arg to menu/radiolist/checklist, or the
  wrong number of state fields, makes the wizard bounce back to the previous screen.
- **Cancel == TUI_BACK** — a dialog cancel is not an abort; return codes drive `run_wizard`.
- **Passwords/hashes never in argv** (visible in `ps`) — `generate_password_hash` uses
  `openssl passwd -6 -stdin`; the setup script pipes the hash into `pw … -H 0` via stdin.
- **`config_save` uses `${VAR@Q}`** (bash 4.4+) and `umask 077` (the file holds hashes);
  `config_load` sources a filtered temp file (only known CONFIG_VARS) — no injection from config.
- **Never `eval` external data** (`blkid`/`gpart`/`pciconf` output, config lines) — parse with
  `read`/`case`/`declare`. A crafted partition label can carry code.
- **stderr redirect vs dialog UI** — when stderr is redirected to the log, `dialog` is invisible;
  `try()` restores fd 4 before showing the recovery menu (`if { true >&4; } 2>/dev/null; then
  exec 2>&4; fi`).
- **`dialog` missing in fresh chroot** — `try()` falls back to a `read -r` text menu.
- **Killing `tee` cascade-kills the running command** (SIGPIPE) — don't kill tee mid-phase.
- **`if cmd; then …; fi` without `else` resets `$?` to 0** — cosmetic "Failed (exit 0)" in
  `try()`; detection still works via `PIPESTATUS`.
- **Heredoc expansion side in `bsdinstall.sh`** — `_emit_setup_script` is expanded on the HOST so
  CONFIG_VARS interpolate; `%q`-quote anything (hashes, usernames) that lands in the generated
  file, and double-escape `\\` inside the inner `login.conf` heredoc.
- **`pciconf -lv` has two id formats** — `vendor=0x… device=0x…` (new) AND `chip=0xDDDDVVVV`
  (legacy: device = high 16 bits, vendor = low 16). The parser must handle both.
- **RAM is `hw.physmem` in BYTES** — not `hw.realmem` (PCI-hole) or `hw.usermem`.
- **`kenv -q`** — the `-q` is load-bearing under set -e (silent on missing key); whitebox SMBIOS
  can be empty ("To Be Filled By O.E.M.").
- **`ping -t SECONDS`** on FreeBSD is the overall timeout (Linux uses `-W`); used by
  `ensure_dns`/`has_network`.
- **`is_supported_arch` is amd64-only and NOT bypassable** — an amd64 install can't succeed on
  aarch64 (Snapdragon Surface). Gated first in `screen_welcome`, before anything destructive.
- **Files in `lib/` are SOURCED, never executed** — each begins with the shebag +
  `source "${LIB_DIR}/protection.sh"`, which aborts unless `$_FREEBSD_INSTALLER` is set
  (tests must export it).

## Running tests

```bash
bash tests/test_config.sh        # Config save/load round-trip
bash tests/test_hardware.sh      # Hardware detection / parsing
bash tests/test_checkpoint.sh    # Checkpoint set/reached/validate/migrate
bash tests/test_validate.sh      # validate_config() pre-install safety gate
bash tests/shellcheck.sh         # Static analysis (needs shellcheck)
```

Tests are standalone (no root/hardware); they export `_FREEBSD_INSTALLER=1`, `DRY_RUN=1`,
`NON_INTERACTIVE=1` and override paths in `lib/constants.sh` (which uses `: "${VAR:=default}"`,
not `readonly`, so values can be overridden).

## How to add a TUI screen

1. Create `tui/new_screen.sh` with `screen_new_screen()` returning TUI_NEXT/BACK/ABORT.
2. `source "${TUI_DIR}/new_screen.sh"` in `install.sh`.
3. Add `screen_new_screen` to the `register_wizard_screens` list in `run_configuration_wizard()`.
4. Set + `export` any CONFIG_VARS the screen produces.

## How to add a config variable

1. Add the name to `CONFIG_VARS[]` in `lib/constants.sh` (with an inline value comment).
2. Set + `export` it in the owning TUI screen.
3. Consume it in the relevant `lib/` module (and emit it into the bsdinstall script if it
   affects the base install — see `_emit_*_preamble` / `_emit_setup_script`).

## How to add an installation phase

1. Add the checkpoint name to `CHECKPOINTS[]` in `lib/constants.sh`.
2. Write the phase function in the appropriate `lib/` module (touch the target only via
   `chroot_*`; wrap fallible steps in `try`).
3. Add a `_run_phase "<cp>" "Description" <function>` line in `screen_progress()`
   (`tui/progress.sh`), in order.
4. The checkpoint gating is handled by `_run_phase` — it skips the phase if the checkpoint
   already exists and sets it on success.

## Pointers

- **`docs/DESIGN.md`** — the full research brief / spec: bsdinstall ZFS+UFS templates, hardware
  detection cheat-sheet (Linux probe → FreeBSD command), graphics matrix (drm-kmod + AMD Phoenix
  firmware flavors, panic conditions), desktop matrix (DE → pkg/DM/services), device caveats
  (GPD Pocket 4 MT7922 WiFi BLOCKER + no console rotation; Surface SAM), system config snippets,
  the live-media bootstrap sequence, and the open risks / low-confidence items to verify on real
  hardware.
- **`docs/HANDOFF.md`** — implementation status / what's wired vs TODO.
