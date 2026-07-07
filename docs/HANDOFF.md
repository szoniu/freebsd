# HANDOFF — stan budowy instalatora FreeBSD (2026-06-15)

> Dokument przekazania między sesjami Claude Code. Czytaj RAZEM z
> [docs/DESIGN.md](DESIGN.md) (pełny brief badawczy + werdykty sprzętowe).
> Repo: `~/dev/freebsd` → `github.com/szoniu/freebsd` (public, SSH). **Zpushowane** (initial import, branch `main`).

## Cel i decyzje (zatwierdzone przez użytkownika)

Instalator TUI FreeBSD wzorowany na rodzinie 6 bliźniaczych instalatorów Linux w `~/dev`
(alpine/chimeraos/gentoo/nixos/porteux/void) — bash + gum, wizard `screen_*`, config/checkpoint/
resume, `try()` recovery. Menu wyboru desktopu. Testy live na: **zwykły PC** (first-class),
**GPD Pocket 4** (best-effort), **Surface** (best-effort, udokumentowane luki).

Cztery decyzje architektoniczne (odpowiedzi użytkownika):
1. **Silnik instalacji**: `bsdinstall script` (scripted) + nasz TUI na wierzchu (reuse natywnego bsdinstall).
2. **Shell/TUI**: bash + gum (bootstrap `pkg install bash gum` na live media) — maks. reuse rodziny.
3. **Zakres**: PC first-class, GPD/Surface best-effort z udokumentowanymi lukami.
4. **Repo**: `szoniu/freebsd`, publiczne, remote SSH `git@github.com:szoniu/freebsd.git`.

## Architektura (jak to działa)

- **Model jednoprocesowy** (inaczej niż void/gentoo): `bsdinstall` robi destrukcyjną instalację bazy;
  nasze fazy post-install lecą w TYM SAMYM procesie i wchodzą do targetu przez `chroot_*` (bez
  re-inwokacji instalatora w chroocie).
- **bsdinstall jest bezstanowy** → re-entrancy (wipe/export/re-mount) robi NASZ wrapper
  (`lib/bsdinstall.sh`: `bsdinstall_wipe_target` + `bsdinstall_run` + `bsdinstall_mount_target`).
- **Generowany skrypt** = PREAMBLE (zmienne `ZFSBOOT_*` lub `PARTITIONS`) + SETUP SCRIPT po
  `#!/bin/sh` (chroot `/mnt`: hostname/users/tz/locale/pkg bootstrap/loader.conf). Długie, awaryjne
  fazy (gpu/desktop) są POZA setup-scriptem — jako nasze checkpointowane fazy chroot (resumowalne).
- **Wizard** (`install.sh run_configuration_wizard`): 14 ekranów → `config_save`.
- **Egzekutor** (`tui/progress.sh screen_progress`): fazy z checkpointami + `LIVE_OUTPUT=1`.

### Fazy (CHECKPOINTS) → funkcje
`preflight`(preflight_checks) → `bsdinstall`(bsdinstall_run) → `mount_target`(bsdinstall_mount_target)
→ `gpu`(gpu_install) → `desktop`(desktop_install) → `device_quirks`(device_quirks_apply)
→ `laptop`(laptop_setup_apply) → `extras`(install_extras) → `finalize`(system_finalize).

### Ekrany wizarda (kolejność w install.sh)
welcome, preset_load, hw_detect, disk_select, filesystem_select, swap_config, network_config,
locale_config, gpu_config, desktop_select, user_config, extra_packages, preset_save, summary.

### Kontrakt dialog_* (KRYTYCZNE — zła arność = wizard „odbija")
`dialog_menu "TYTUŁ" tag desc ...` (PARY, bez prompt-arg). `dialog_radiolist/checklist "TYTUŁ"
tag desc state ...` (TRÓJKI). `dialog_inputbox "TYTUŁ" "default"`, `dialog_passwordbox "TYTUŁ"`,
`dialog_yesno/msgbox/infobox "TYTUŁ" "TEKST"`. Ekrany zwracają `TUI_NEXT`/`TUI_BACK`/`TUI_ABORT`.

## Stan plików

### GOTOWE i zweryfikowane (`bash -n` OK; bsdinstall — realny test generacji + `sh -n` na output)
- `lib/constants.sh` — CONFIG_VARS[], CHECKPOINTS[], ścieżki, ZFS/AMD-firmware/DISK_PROBE.
- `lib/protection.sh` (`_FREEBSD_INSTALLER`), `lib/logging.sh`, `lib/hooks.sh`, `lib/preset.sh`.
- `lib/dialog.sh` — gum FreeBSD (poprawiony `_extract_bundled_gum` na `Freebsd_x86_64`).
  ⚠️ backend `bsddialog` (flagi vs classic dialog) NIE zweryfikowany — gum jest primary.
- `lib/utils.sh` — sondy FreeBSD (`is_efi`→machdep.bootmethod, `has_network`/`ensure_dns` -t,
  `check_dependencies` FreeBSD, `is_supported_arch` amd64). Wycięty linuksowy resume/inference;
  `try_resume_from_disk` = minimalny (ZFS import + odczyt configu z `/var/db/freebsd-installer/`).
  `try()`/`checkpoint_*`/`generate_password_hash` (openssl passwd -6) — nietknięte/portable.
- `lib/hardware.sh` — pciconf (DWA formaty: `vendor=`/`device=` i `chip=`), kenv smbios, gpart,
  `detect_wifi` (flaga `WIFI_SUPPORTED=0` dla MT7922 14c3), `detect_device_profile`, `_gpu_driver_for`.
- `lib/bsdinstall.sh` — generator (ZFS-auto + UFS-auto + GELI), `bsdinstall_wipe_target`,
  `bsdinstall_mount_target`. Generacja PRZETESTOWANA, hash hasła bezpieczny (printf|pw -H 0).
- `lib/chroot.sh` — `chroot_exec`/`chroot_sh`/`chroot_pkg`/`chroot_teardown` (honorują DRY_RUN).
- `lib/config.sh` — save/load/get/set/dump/diff portable (⚠️ `validate_config` przepisuje workflow).
- `install.sh` — orkiestracja (⚠️ NIE source-testowany, bo brakowało gpu.sh itd.).
- `tui/progress.sh` — egzekutor faz.
- `docs/DESIGN.md` — pełny brief badawczy. `data/gum.tar.gz` — build FreeBSD/amd64.
- `configure.sh`, `.gitignore` — OK bez zmian.

### GOTOWE (workflow `w9b2gc0ho` — 26 agentów, ZWERYFIKOWANE 2026-06-15)
Moduły: `lib/gpu.sh`(gpu_install), `lib/desktop.sh`(desktop_install+install_extras),
`lib/system.sh`(system_finalize), `lib/umpc.sh`(device_quirks_apply), `lib/config.sh`(validate_config).
Ekrany TUI: wszystkie 14. Testy: `test_hardware`, `test_bsdinstall`, `test_config`, `test_validate`.
Docs: `README.md`, `CLAUDE.md`, `TODO.md`.

### DODANE PÓŹNIEJ (faza laptop, 2026-07)
- `lib/laptop.sh` — faza `laptop` (gated na `BATTERY_DETECTED`): powerd/Cx, suspend S3 (lid tylko przy
  desktopie; `/dev/acpi` dla grupy `operator` przez devfs.conf), backlight devfs.rules, touchpad ig4+iichid,
  ThinkPad acpi_ibm. Diagnostyka read-only: `tests/live-hw-check.sh` (**POSIX sh** — leci na gołym live
  medium, NIE wprowadzać bashizmów). Docs: `LIVE-USB-CHECKLIST.md` (runbook per maszyna),
  `DAILY-DRIVER-AUDIT.md` (werdykty kandydatów).

**Weryfikacja integracji (PASS):**
- `bash -n` na 38 plikach `.sh` — czysto.
- Smoke-test: source wszystkich lib+tui w kolejności install.sh pod `set -Eeuo pipefail` — **0 brakujących funkcji**.
- Testy jednostkowe (DRY_RUN): **143/143** (config 38, hardware 40, validate 18, bsdinstall 31, checkpoint 16).
- `tests/shellcheck.sh` (severity=warning): 38 plików, **0 uwag**.
- Poprawki integracyjne (moje): `hardware.sh` martwy wzorzec `cd[0-9]*`; `install.sh` 3× `A && B || C` → `if`.
- Potwierdzone: funkcje faz NIE ustawiają własnych checkpointów (robi to `_run_phase` w `progress.sh`).

### USUNIĘTE (Linux-only, nie dotyczą FreeBSD)
lib: xbps, rootfs, kernel, secureboot, disk, swap, bootloader, network.
tui: kernel_select, secureboot_config, desktop_config.
data: gpu_database, mirrors. tests: infer_config, resume, shrink, multiboot, disk.

## Werdykty sprzętowe (z DESIGN.md — krytyczne dla testów live)
- **GPD Pocket 4 WiFi = MediaTek MT7922 (`14c3:0616`) NIE DZIAŁA** (mt76 odłączony od builda) →
  **BLOCKER, bootstrap przez kabel/USB-Ethernet**.
- **Radeon 780M DZIAŁA** (drm-kmod + amdgpu + 6 flavorów `AMD_PHOENIX_FW_FLAVORS`); **zły flavor =
  kernel panic**. amdgpu ładować przez `kld_list` w rc.conf, NIGDY loader.conf.
- **Rotacja konsoli/loadera = brak** (`kern.vt.rotate` nie istnieje); rotacja tylko desktop-layer
  (`PANEL_ROTATION=90` → sway transform / xrandr right / Plasma Portrait).
- **Surface**: SAM klawiatura/touchpad martwe na Laptop/Book/Studio → zewn. USB kbd; Type Cover
  (Pro/Go) OK; touch/pen (iptsd) brak; ARM64 Surface poza zakresem.
- Hash: `openssl passwd -6` (`$6$`) + `pw usermod -H 0` (stdin). Locale: `/etc/login.conf` + `cap_mkdb`.
  Swap: partycja `freebsd-swap` (brak zram). Dysk: probe `nda0` PIERWSZY, wyklucz boot medium.
  ARC cap (≤16 GiB RAM): `vfs.zfs.arc_max` w BAJTACH.

## POZOSTAŁO (kolejne kroki)

✅ **Weryfikacja workflow + lint + testy jednostkowe — ZROBIONE** (patrz „Weryfikacja integracji" wyżej).

✅ **Przegląd adwersarialny semantyki FreeBSD — ZROBIONE (2026-06-15, workflow `freebsd-adversarial-review`,
   78 agentów, każdy finding refutowany przez 2 niezależnych sceptyków z dostępem do web).** 36 findingów →
   18 potwierdzonych (naprawione), 8 niepewnych, 10 odrzuconych. Naprawione:
   - **[blocker] UFS+BIOS** (`_emit_ufs_preamble`): hardcodowany `efi`, brak `freebsd-boot` → niebootowalne
     na czystym BIOS. Teraz partycja boot wg `BOOT_TYPE` (BIOS→`512k freebsd-boot`, UEFI→`efi`, BIOS+UEFI→oba).
   - **[blocker] validate_config omijany w `install`/`resume`** → bramka przeniesiona do `screen_progress`
     (chroni destrukcyjną fazę na KAŻDEJ ścieżce).
   - **[high] `gpu-firmware-intel-kmod` NIE ISTNIEJE** (port flavoryzowany per-generacja) → meta
     `gpu-firmware-kmod` (hardware.sh + gpu.sh; intel konsumuje `${GPU_FW_FLAVORS}`).
   - **[high] injection w setup-scripcie** (FULLNAME/TIMEZONE/KEYMAP/groups bez `%q`) → `printf -v ... %q`
     na wszystkich polach-tokenach sh (test injection w test_bsdinstall: `$(touch)` neutralizowane).
   - **[high] leak `$HOSTNAME`** (bash auto-eksportuje hostname live-medium) → `unset HOSTNAME` na starcie `main`.
   - **[high] preset leakuje `$6$` hashe** (plik 0644) → `umask 077` w `preset_export` (hashe zostają — skip-flow
     ich używa — ale plik 0600).
   - **[high] ESP nie montowany na ZFS** → `bsdinstall_mount_target` montuje ESP też w gałęzi ZFS (efibootmgr/finalize).
   - **[med] validate**: DISPLAY_MANAGER enum, ARC_MAX_BYTES/SWAP_SIZE_MIB integer, SWAP_ENCRYPTION/GELI_ROOT 0|1.
   - **[med] plik bsdinstall 0644 przed chmod (TOCTOU)** → `umask 077` przy generacji.
   - **[low] `steam-utils`→`linux-steam-utils`**; opis wine (native, nie Linuxulator); ESC w swap_config (128→BACK);
     default TIMEZONE; komentarz GELI (interaktywny passphrase); `_dm_for_desktop`→`_de_default_dm`.
   - Odrzucone (NIE bugi): `pw useradd -s /usr/local/bin/bash` przed instalacją basha (pełna ścieżka pomija
     walidację shella — OK); idempotencja kld_list w umpc (checkpoint gating); znaki `\\` login.conf; sześć
     flavorów AMD Phoenix i origin-y DE — zweryfikowane jako POPRAWNE.
   - **Testy: 143 → 155** (dodane regresje: UFS+BIOS/UEFI boot-part, injection-safety, mango/DISPLAY_MANAGER/ARC).

✅ **Desktop Mango DODANY** (`x11-wm/mango`, dwl-based Wayland tiling — binarka w Latest): wpis w
   `desktop_select` (radiolist + DM=none), `_de_packages`/`_de_is_wayland` w desktop.sh, enum w validate,
   constants/README/CLAUDE.md. Menu: none/kde/gnome/xfce/mate/cinnamon/lxqt/sway/niri/hyprland/**mango**.
   **COSMIC odłożony** (TODO w DESIGN.md §4): w pkg tylko `cosmic-comp`, brak sesji/panelu/greetera → nie
   dodano do menu, by nie kusić pułapką; jednolinijkowe dodanie gdy `cosmic-session` trafi do binarnego pkg.

1. **(opcjonalnie) DRY-RUN E2E**: `./install.sh --configure --dry-run` (uwaga: gum/bsddialog na Linuksie
   bywa kapryśny; ewentualnie smoke per-ekran). Smoke generacji + smoke faz (DRY_RUN) — ZROBIONE.
2. ✅ **Push — ZROBIONE** (initial import na `main`, SSH `git@github.com:szoniu/freebsd.git`, path-scoped).
3. **Test na żywym sprzęcie** (użytkownik): boot live → fix na main → target `git pull` → re-run.
   GPD Pocket 4 WiFi (MT7922) NIE działa → bootstrap kablem/USB-Ethernet.

## Pułapki dla integratora
- Cały kod leci pod `set -Eeuo pipefail` + `inherit_errexit`: `(( x++ )) || true`; `cmd|grep` w `$()`
  zakończ `|| true`; nie `[[ -n "$x" ]] && cmd` jako samodzielna instrukcja (pełny `if`).
- Pliki `lib/` są SOURCE'owane, nie uruchamiane (guard `protection.sh`).
- Agenci workflow mogli wprowadzić drobne niespójności (nazwy, arność dialog) — krok 4 to łapie.
- `git status`/`branch --show-current` ŚWIEŻO przed operacjami git (worktree współdzielony między maszynami).

## Workflowy tej sesji (transkrypty)
- Badawczy: `freebsd-installer-research` (run `wf_f8870b87-6a0`) → `docs/DESIGN.md`.
- Implementacyjny: `freebsd-installer-implement` (run `wf_78596fdd-2f7`, task `w9b2gc0ho`).
- Referencja kodu: `~/dev/void` (najbliższy model), `~/dev/gentoo` (najbogatsze haki sprzętowe).
