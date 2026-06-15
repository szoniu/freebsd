# FreeBSD TUI Installer

An interactive, menu-driven installer for **FreeBSD** (14.x RELEASE first; 15.0-RELEASE as
the "newest base" option). Clone the repo on the live memstick, run `bash install.sh`, and
get walked through everything from disk layout to a working desktop. After a crash you can
re-run with `--resume` and it picks up from the last completed checkpoint.

It is a faithful port of the **szoniu Linux installer family** — sibling installers for
`alpine`, `chimeraos`, `gentoo`, `nixos`, `porteux`, and `void` — translated from Linux idioms
to FreeBSD ones. Same `bash` + [`gum`](https://github.com/charmbracelet/gum) TUI, same screen
flow, same `try()` recovery menu, same checkpoint/resume model. What changes is the substrate:

- **Base install** is done by `bsdinstall(8)` in *scripted* mode — our TUI generates a
  `bsdinstall script` (PREAMBLE variable assignments + a chrooted SETUP SCRIPT) and runs it.
- **Post-install** (graphics, desktop, device quirks, extras, finalize) runs as our own phases
  that shell into the freshly-installed system at `/mnt` via `chroot_exec`/`chroot_pkg`.
- **Package management** is `pkg`, not `xbps`/`portage`/`apt`. Services are `rc.conf` (`sysrc`),
  not runit/systemd. Bootloader is the FreeBSD EFI loader, not GRUB. Filesystem is **ZFS**
  (with boot environments) or UFS — there is no ext4/btrfs here.

> Target detail and rationale for every FreeBSD-specific decision live in
> [`docs/DESIGN.md`](docs/DESIGN.md). This README is the operator-facing guide.

---

## Quick start — bootstrap on the live media

The FreeBSD live ISO/memstick boots into a **read-only** root with only `/bin/sh` (ash, *not*
bash), no `pkg` bootstrapped, and an empty/read-only `/usr/local`. You must lay down a writable
overlay and bootstrap the shell layer before you can clone and run the installer.

> **WiFi warning — read this first.** On the **GPD Pocket 4** and on **several Microsoft
> Surface** models the built-in WiFi chip has **no FreeBSD driver** (see the per-device tables
> below). On those machines you **cannot** bring up wireless on the live media at all — use
> **wired Ethernet or a USB-Ethernet dongle** (or USB-tether a phone). Plan for a cable.

Run as `root` in the Live System shell:

```sh
# 0) Bring up wired networking (WiFi may have NO driver on GPD/Surface — use a cable):
ifconfig -l
dhclient em0                                    # use your NIC: igb0 / re0 / ure0 / ...

# 1) Make /usr/local and /tmp writable (media is RO), PRESERVING resolv.conf:
mount -t tmpfs -o size=1g tmpfs /usr/local
mkdir -p /tmp.bak && cp -a /tmp/. /tmp.bak/
mount -t tmpfs -o size=512m tmpfs /tmp
cp -a /tmp.bak/. /tmp/

# 2) DNS:
[ -s /etc/resolv.conf ] || echo 'nameserver 1.1.1.1' > /etc/resolv.conf

# 3) Bootstrap pkg + the shell layer (TMPDIR points at the writable tmpfs):
export TMPDIR=/usr/local
pkg bootstrap -fy && pkg update -f && pkg install -y bash gum git

# 4) Console env for gum on vt(4):
export TERM=xterm-256color LANG=en_US.UTF-8 LC_CTYPE=en_US.UTF-8

# 5) Clone and run:
git clone https://github.com/szoniu/freebsd.git /tmp/installer
exec bash /tmp/installer/install.sh
```

Gotchas:

- **Remounting `/tmp` as tmpfs wipes `resolv.conf`** if you didn't copy it back first — step 1
  preserves it. If DNS dies later, just re-add the nameserver line.
- `bash`/`gum`/`git` land in **`/usr/local/bin`**, not `/bin` — every script uses the
  `#!/usr/bin/env bash` shebang for that reason. Never run the `lib/*.sh` files directly; they
  are *sourced*.
- The vt(4) console renders 16 colors; `gum` degrades gracefully but needs a **UTF-8 locale**
  (step 4).
- **Offline pkg blocked but GitHub reachable?** A FreeBSD/amd64 `gum` static binary is bundled
  in `data/gum.tar.gz` (asset `gum_0.17.0_Freebsd_x86_64.tar.gz`, note the capitalized
  `Freebsd`); the installer extracts it automatically, so you only strictly need `bash` + `git`.

### Other ways to run

```sh
bash install.sh                  # full run: wizard, then install
bash install.sh --configure      # wizard only — writes the .conf, installs nothing
bash install.sh --install        # install only, from an existing config
bash install.sh --resume         # resume an interrupted install (scans for checkpoints)
bash install.sh --dry-run        # walk the whole flow with NO destructive operations
bash install.sh --config FILE    # use a specific config file
bash install.sh --force          # continue past failed prerequisite checks
bash install.sh --non-interactive  # abort on any error (no recovery menu)
```

---

## Desktop menu

The desktop screen offers one choice (radiolist). The FreeBSD caveat for each is shown inline
so you see the trade-off before you pick. Display managers and Wayland seat handling differ
sharply from Linux — there is **no systemd-logind**; Wayland sessions start from a tty login
via **`seatd`**, and the user must be in the `_seatd` group (the installer does
`pw groupmod _seatd -m <user>`).

| Choice | Stack | FreeBSD caveat |
|---|---|---|
| **none** | Server, no GUI — base system only, tty login | Nothing graphical installed. |
| **KDE Plasma** | `kde` / `plasma6-plasma` + **SDDM** | **`startplasma-x11` is the stable 2026 path**; Wayland works but X11 is the documented fallback. Broken under VirtualBox. |
| **GNOME** | `gnome` / `gnome-lite` + **GDM** (bundled) | Requires `proc /proc procfs rw 0 0` in fstab. |
| **Xfce** | `xfce4` + **LightDM** | Lightweight, reliable. |
| **MATE** | `mate` / `mate-base` + **LightDM** | Traditional, reliable; needs procfs in fstab. |
| **Cinnamon** | `cinnamon` + **LightDM** | **X11-only** on FreeBSD; needs procfs in fstab. |
| **LXQt** | `lxqt` + **SDDM** | Minimal Qt desktop; needs procfs in fstab. |
| **sway** | `sway` (Wayland) | tty login via `seatd`; **reliable binary pkg**. |
| **niri** | `niri` (Wayland, scrollable tiling) | **reliable binary pkg** on 14/15 amd64. |
| **Hyprland** | `hyprland` (Wayland) | **binary pkg is inconsistent — may require a ports build**. |
| **Mango** | `mango` (Wayland, dwl-based dynamic tiling) | tty login via `seatd`; **reliable binary pkg** (Latest). dwm-style tags + scenefx effects. |

Every graphical profile pulls in `xorg`/`wayland` + `drm-kmod` and enables `dbus` +
`moused`. **PipeWire is a USER service on FreeBSD** — there is no `pipewire_enable` in
`rc.conf`; it starts per-user via XDG autostart. `elogind` and `seatd` conflict, so this
installer standardizes on **`seatd`**.

---

## Per-device caveats

These two devices are the reason the installer exists in this shape. The verdicts come from
[`docs/DESIGN.md`](docs/DESIGN.md) §5 (10-agent hardware research, June 2026).

### GPD Pocket 4 (Ryzen 8840U / Radeon 780M)

> **WiFi/Bluetooth — VERDICT FIRST: DOES NOT WORK (severity: BLOCKER).** The chip is an
> AMD RZ616 = MediaTek **MT7922** (Filogic 330P, PCI `14c3:0616`) — **not** an Intel AX210.
> The `mt76` driver is in-tree since 14.x but **disconnected from the build**, and forum reports
> (Jan 2026) show **zero successful associations**. Bluetooth is a separate USB interface, also
> dead. **You must bootstrap over wired/USB-Ethernet** (a USB-C dongle `ure`/`cdce`, a USB-tethered
> phone, or a `rtwn`/`run` USB WiFi stick). The installer sets `WIFI_SUPPORTED=0` and warns.

| Component | Status | Severity |
|---|---|---|
| WiFi/BT (MT7922) | **DOES NOT WORK** — no association | **BLOCKER** |
| Radeon 780M GPU | **WORKS** — `drm-61-kmod` + `amdgpu` + the **six** AMD Phoenix firmware flavors; a wrong/missing flavor = **KERNEL PANIC** | medium |
| 780M Vulkan compute | hard-locks the GPU under sustained compute (drm-kmod #387) | medium |
| Console / loader rotation | **NOT POSSIBLE** — `kern.vt.rotate` does not exist; the bsdinstall TUI shows up **sideways** on the portrait panel | high (UX) |
| GUI rotation | **WORKS post-login** — Wayland `output eDP-1 transform 90/270`, Plasma Portrait, Xorg `xrandr --rotate right` | — |
| Audio (ALC287) | possible with `snd_hda`; pin values are per-unit (`dev.hdaa.N.pindump=1` → `/boot/device.hints`); no Auto-Mute | medium |
| Accelerometer auto-rotate (MXC6655) | **NO** — no IIO / iio-sensor-proxy | low |
| Fan control | **NO** — no `gpd-fan` analog; EC runs autonomously | low |

ZFS ARC is capped for the 12 GB-RAM model: `vfs.zfs.arc_max="4294967296"` (4 GiB, **in bytes** —
the `"4G"` form is sometimes rejected). Swap defaults to **8 GiB, encrypted**.

The 780M works but the firmware-flavor coupling is fragile: the six split packages —
`gpu-firmware-amd-kmod-{dcn-3-1-4, gc-11-0-1, gc-11-0-4, psp-13-0-4, sdma-6-0-1, vcn-4-0-2}` —
must all be present, and `amdgpu` loads via **`sysrc kld_list+=amdgpu`**, *never* via
`loader.conf` (that panics early boot). On some 14.3 builds `amdgpu` in `kld_list` froze the
boot, so a `kldload amdgpu` post-boot fallback exists.

### Microsoft Surface (best-effort)

> **WiFi verdict (chip-dependent):** AX200/AX201 (Go 2/3, Pro 7/8) work via `iwlwifi` but only
> **802.11 a/b/g**; QCA6174 (original Go, many Pro 4–6) has `ath10k` disconnected → **no WiFi,
> use a USB dongle**.

| Component | Status | Severity |
|---|---|---|
| Keyboard/touchpad (Laptop 1–6, Book 3, Laptop Studio) | **DEAD** — routed through the Surface Aggregator Module (SAM), no driver. **Needs an external USB keyboard + mouse even to install** | **BLOCKER** (these models) |
| Type Cover (Pro / Go) | **WORKS** — USB-HID via `ukbd`/`hkbd`/`hms`/`hmt` (not SAM) | — |
| Touch / pen (Pro 4+, Book, Laptop, Studio) | **NO** — IPTS needs the Linux-only `iptsd` | medium |
| Touch (Go / Go2 / Go3) | maybe via `iichid`/`ig4`/`hmt` — **low confidence** | low-conf |
| GPU | Intel `i915kms` / AMD `amdgpu` — works | — |
| Bluetooth, cameras, sensors, **S3 suspend** (S0ix) | **NO** | medium |
| ARM64 Snapdragon (Pro 11th gen / Laptop 7th gen) | **out of scope** — detected and **refused** | — |

Surface HID-over-I2C needs `sysrc kld_list+="ig4 iichid"` and
`loader.conf hw.usb.usbhid.enable=1`; AX200/AX201 need
`sysrc kld_list+=if_iwlwifi wlans_iwlwifi0=wlan0`.

---

## The live-test loop

This installer is developed against real hardware booted from the live memstick. The loop:

1. **Boot** the target from the live media and bootstrap as above (`git clone … && bash
   install.sh`).
2. **Fix on `main`** (on your dev machine), push.
3. On the target, **`git pull`** in the cloned repo and **re-run** — no re-flashing the stick.
4. If an install was interrupted (panic, lost SSH, power), **`bash install.sh --resume`** scans
   for checkpoints and resumes from the last completed phase rather than starting over.

Aids while testing:

- **Log:** everything is appended to **`/tmp/freebsd-installer.log`**. Tail it from a second
  console: `tail -f /tmp/freebsd-installer.log`.
- **Multiple TTYs:** vt(4) gives you `Alt+F1`…`Alt+F8`. Run the installer on one, debug on
  another (`top`, `tail -f`, manual `pkg`).
- **SSH:** set a root password (`passwd`), `service sshd onestart`, then drive the install
  remotely. Run inside `tmux` so a dropped SSH session doesn't kill the install.
- **Recovery menu:** any command wrapped in `try()` that fails opens a
  **Retry / Shell / Continue / Log / Abort** menu — drop to a shell, fix the problem by hand,
  and retry the exact command.

---

## ZFS boot environments (rollback as a feature)

On the **ZFS** profile the system ships with `bectl` boot environments, and the installer
surfaces this prominently. A boot environment is an instant (<1 s) snapshot+clone of the root
dataset that you can boot independently from the loader menu:

```sh
bectl create pre-upgrade-$(date +%F)      # instant snapshot+clone
bectl activate -t pre-upgrade-2026-06-15  # boot the OLD BE once (temporary)
bectl activate pre-upgrade-2026-06-15     # make it the permanent default
```

`freebsd-update` and `pkg` automatically create a BE before they change the system, so a bad
upgrade is a **reboot-and-pick-the-previous-BE** away — no restore from backup. This is the
strongest argument for choosing ZFS over UFS here. **UFS has no `bectl`** — choosing the UFS
profile trades boot environments for lower overhead.

---

## Known limitations / not yet supported

- **Dual-boot.** v0.1 does **whole-disk auto layout only**. Auto-ZFS unconditionally
  `gpart destroy -F`s every target disk and erases Windows/ESP without a second prompt under
  `nonInteractive=YES`. Side-by-side dual-boot (manual `PARTITIONS`/scriptedpart, ESP reuse) is
  scaffolded in the config vars but **not wired up** yet — do not point this at a disk you want
  to keep.
- **Cross-reboot disk-scan resume.** `bsdinstall` is stateless and has no native resume. Our
  wrapper resumes within a session via checkpoints; full **disk-scanning resume across a reboot**
  (re-discovering a half-installed pool, exporting it, re-wiping) is partial — `--resume` is
  reliable for an interrupted run that hasn't lost `/tmp`.
- **Secure Boot.** Not handled. FreeBSD's Secure Boot story differs from the Linux MOK/shim
  approach the sibling installers use; disable Secure Boot in firmware for now.
- **GELI full-disk root** is present as an option but flagged experimental on quirky UEFI
  (GPD/Surface) — a lost passphrase is unrecoverable.

---

## Running tests

All tests are standalone — no root, no real hardware. They run under `DRY_RUN=1` and export
the installer guard so the `lib/*.sh` modules can be sourced.

```sh
bash tests/test_config.sh        # config save/load round-trip
bash tests/test_hardware.sh      # hardware detection / GPU + firmware mapping
bash tests/test_checkpoint.sh    # checkpoint set/reached/validate/migrate
bash tests/test_validate.sh      # validate_config() — pre-install safety gate
bash tests/shellcheck.sh         # static analysis / lint (needs shellcheck installed)
```

`tests/shellcheck.sh` lints every `.sh` file in the tree and is the quickest way to catch the
`set -Eeuo pipefail` foot-guns this codebase is careful about (e.g. `(( x++ ))` returning 1 at
zero, `grep` in a `$()` failing the pipeline).

---

## Project layout

```
install.sh        — entry point: arg parsing, wizard orchestration, phase dispatch
configure.sh      — wrapper: exec install.sh --configure

lib/              — library modules (SOURCED, never executed)
  constants.sh    — CONFIG_VARS[], CHECKPOINTS[], paths, ZFS/AMD-firmware/disk-probe constants
  protection.sh   — guard: refuses to run unless sourced by the installer
  logging.sh      — einfo/ewarn/eerror/elog + logging to /tmp/freebsd-installer.log
  utils.sh        — try() recovery, checkpoints, is_efi/has_network, generate_password_hash
  dialog.sh       — gum/dialog primitives + run_wizard
  config.sh       — config_save/load + validate_config()
  hardware.sh     — CPU/GPU/disk/WiFi/Surface/GPD detection via pciconf/sysctl/kenv
  bsdinstall.sh   — generate + run the bsdinstall scripted-install file
  chroot.sh       — chroot_exec/chroot_sh/chroot_pkg/chroot_teardown (DRY_RUN-aware)
  gpu.sh          — drm-kmod + firmware flavors + kld_list
  desktop.sh      — DE / display manager / seatd+dbus / groups
  system.sh       — locale (login.conf + cap_mkdb), users, finalize, bectl baseline
  umpc.sh         — GPD Pocket 4 / Surface device quirks
  hooks.sh        — before_*/after_* phase hooks
  preset.sh       — reusable-config export/import (hardware overlay)

tui/              — TUI screens (each a screen_*() returning TUI_NEXT/BACK/ABORT)
data/             — bundled gum binary, dialog theme
presets/          — example configurations
hooks/            — *.sh.example
tests/            — standalone tests
docs/DESIGN.md    — the implementation spec (bsdinstall templates, hardware matrix, caveats)
```
</content>
