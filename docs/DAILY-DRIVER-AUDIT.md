# Audyt: FreeBSD jako desktop daily driver (instalator + dotfiles wizard + sprzęt)

> Stan na 2026-07-07. Audyt 8-agentowy: kod instalatora (`dev/freebsd`), wizard dotfiles
> (`~/dotfiles`), inwentarz homelab + research webowy (FreshPorts / ports tree / GitHub
> issues / FreeBSD Foundation laptop project). Cel: programowanie w Claude Code, desktop
> niri lub mango (Plasma OK), laptop — kandydat X1 Nano Gen 1 lub coś z homelabu.

## Werdykt

**Wykonalne.** niri 26.04 i mango 0.14.4 są w ports i równe upstreamowi, Claude Code działa
przez Linuxulator (port `misc/claude-code`, aktualizowany dzień-w-dzień z upstreamem),
cały plumbing Wayland (seatd, pipewire, portale, waybar, fuzzel, locki) jest w pkg.
Ale: (1) instalator zostawia po niri/mango sesję, która **nie wstanie z tty** (brak
XDG_RUNTIME_DIR) i nie konfiguruje NIC z warstwy laptopowej (powerd/suspend/backlight/
touchpad I2C); (2) wizard dotfiles ma FreeBSD first-class w rdzeniu, ale
`apps_special.sh` (55 bloków `case "$PM"`, zero gałęzi `pkg)`) potrafi **nadpisać pkg-owe
binarki linuksowymi ELF-ami**; (3) 13 skryptów configowych ma shebang `#!/bin/bash`,
którego FreeBSD nie ma → martwy lock screen, power menu i autostart.

Rzeczy, które na FreeBSD **nie zadziałają w ogóle** (2026): mikrofon DMIC na laptopach
z Intel SOF (brak sterownika DSP), Bluetooth na AX201 (w praktyce brak; BT audio martwe
w ogóle), Thunderbolt 4/USB4 (docki TB — nie; USB-C+DP alt-mode — tak), Wi-Fi 6/ax
(iwlwifi = max 802.11ac ~100–200 Mbps), s0ix/s2idle suspend (celowane w 15.2), hibernacja,
COSMIC (w portach tylko goły `cosmic-comp` bez sesji/panelu — nie da się złożyć DE),
sandboxing wbudowany w Claude Code (Linux namespaces).

## Sprzęt — ranking kandydatów

| Maszyna | Ocena | Uzasadnienie |
|---|---|---|
| **HP ProBook 450 G8** („rhel") | **#1** | i5-1135G7 Tiger Lake + Iris Xe (i915 OK), **AX201** (iwlwifi, ac od 14.3), **jedyny kandydat z RJ45** (fallback gdy WiFi kaprysi), 15.6" = najbardziej desktopowy, RHEL 10.1 „dev i nauka" — zbywalny bez bólu |
| **HP Elite Dragonfly** („aerynos") | #2 | UHD 620 (Gen9.5 — najdojrzalszy i915) + **AX200 PCIe** (najlepiej przetestowana karta pod iwlwifi) = najmniejsze ryzyko sterowników; minusy: brak RJ45, słabszy CPU, convertible/dotyk częściowo martwy |
| ThinkPad **X1 Nano Gen 1** | #3, ryzykowny | Platforma (TGL+AX201) OK, ale model **niezweryfikowany na marginesach**: głośniki unknown (snd_hda możliwe, może wymagać pin-quirków device.hints), mikrofon DMIC **martwy na zawsze** (SOF), BT martwy, TB4 docki martwe (jedyne porty to 2× USB-C TB4!), suspend **tylko po update BIOS ≥1.43 + Config→Power→Sleep State="Linux"** (S3). Zero wpisu w homelab inventory — zinwentaryzować. Brak pełnego trip-reportu FreeBSD (probe 14.0: grafika+WiFi work, audio/touchpad detected-only) |
| ZenBook UX425EA („chimera") | rezerwa | Ten sam krzem co ProBook, ale kosztem wysiedlenia Chimera+Win11 |
| X1 Titanium, NUC Venus, MacBook | **nie ruszać** | odpowiednio: obecny daily (Gentoo), serwer produkcyjny (31 kontenerów), główna stacja + ARM |
| GPD Pocket 4, ROG Zephyrus, Surface Go | odpada | form factor / RTX 4070+Arc pod Waylandem / quirky platforma |

Luka w inwentarzu: desktop (KDE+Hyprland) i ~7–8 laptopów (w tym X1 Nano) nie mają YAML-i
w `homelab/inventory/hardware/`.

### X1 Nano Gen 1 — szczegóły (gdyby jednak on)

- **Grafika**: Iris Xe działa (probe bsd-hardware.info b97dcbade6). Na 15.1 default
  drm-612 ma na części Inteli GPU HANG — trzymać `drm-66-kmod` jako revert; prewencyjnie
  `compat.linuxkpi.i915_disable_power_well=0` (leczy też `hdac0: Command timeout`).
- **WiFi AX201**: od 14.3 802.11n/ac (LinuxKPI crypto offload); na 15.1 wciąż warto
  `compat.linuxkpi.iwlwifi_11n_disable="0"` + `compat.linuxkpi.iwlwifi_disable_11ac="0"`.
  Realnie ~100–200 Mbps. Po suspend trzeba zbounce'ować wlan0 (hook resume).
- **Suspend**: BIOS ≥1.43 dodał opcję S3 („Linux"). Bez tego brak suspendu (FreeBSD nie ma
  s0ix; s2idle „nearly complete", target 15.2, nie zdążyło do 15.1).
- **Audio**: głośniki/jack przez legacy HDA (ALC287) — OpenBSD ogarnia (azalia), FreeBSD
  prawdopodobnie z device.hints; **mikrofon wewnętrzny = nigdy** (DMIC za SOF DSP).
- **Touchpad**: I2C Windows Precision → wymaga `kld_list+="ig4 iichid"`; TrackPoint po PS/2
  działa zawsze. Kamera: przez webcamd/cuse (natywny uvc(4) — target Q2 2026).
  Fingerprint: nie.
- Proxy-dowody: X1 Carbon Gen 9 (ta sama platforma) — daily driver na 15.1
  (sacredheartsc.com/blog/freebsd-15-on-a-laptop, VI 2026); T14 Gen 2 Intel — 8/8 w matrycy
  testowej Foundation.

## Kompozytory / DE (stan ports 07.2026)

| Co | Stan | Uwagi |
|---|---|---|
| **niri** | ✅ x11-wm/niri 26.04_3, równy upstreamowi | ⚠️ otwarta regresja **#3013**: od 25.11 nie startuje z tty/DRM na 15.x (losowe major/minor devfs). Obejścia: `LIBSEAT_BACKEND=consolekit2 ck-launch-session dbus-launch niri --session`, albo FreeBSD 14.3+drm-61. Port NIE ma łatki. Runtime deps trzeba doinstalować samemu: xwayland-satellite, xdg-desktop-portal-gnome, pipewire |
| **mango** | ✅ x11-wm/mango 0.14.4 (update w dzień releasu) | wlroots019 0.19.3 + scenefx; relacja z forum na 15: „working amazing", fcitx5 działa |
| **Plasma 6 Wayland** | ⚠️ plasma6-plasma 6.6.5 (~1 release za upstreamem) | Działa (potwierdzone na 14.3/amdgpu — Framework 13); na Intelu brak mocnego świadectwa. sddm 0.21.0.36_3: bug Ctrl+C-wyrzuca-z-sesji NAPRAWIONY w porcie od _2 (X.2025) — stare poradniki nieaktualne. Trzymać sesję X11 jako fallback |
| **COSMIC** | ❌ | tylko cosmic-comp 1.0.0_5 bez maintainera; brak session/panel/settings/greeter — DE nie do złożenia |
| Hyprland | ⚠️ 0.55.4 w portach | eksperymentalny/beta, okazjonalne crashe |
| Portale | ✅/⚠️ | xdg-desktop-portal 1.20.3, -wlr 0.8.3, -luminous 0.1.11, -gnome 47.3 (dla niri), -gtk/-kde. **Brak devel/libei** → RemoteDesktop-with-input/InputCapture niemożliwe. Screenshare pipewire: Chromium ma PIPEWIRE=on domyślnie; sporadyczne buffer underruns — przetestować Meet/Teams zanim uznasz za produkcyjne |
| Locki/notyfikacje/reszta | ✅ | swaylock 1.8.5(+effects), waylock 1.5 (najodporniejszy, polecany), hyprlock/hypridle, mako/dunst/swaync, grim/slurp, wl-clipboard, waybar 0.15, fuzzel 1.13, swww 0.11 (awww brak → fallback w skryptach już jest) |

### Gesty touchpada (Twój priorytet)

libinput 1.31.1 w portach = silnik gestów identyczny jak na Linuksie. **Wszystko rozstrzyga
ścieżka kernelowa**: touchpad na **I2C-HID (ig4+iichid+hmt)** → pełny multitouch, 3/4-palcowe
swipe'y w niri/Plasmie jak na Linuksie; touchpad na **PS/2 (psm)** → degradacja (liczba palców
bez pełnego MT, pinch praktycznie nie). Brak opublikowanego świadectwa „gesty działają mi w niri
na FreeBSD" — do weryfikacji na sprzęcie: `kldload ig4 iichid; libinput debug-events` i szukać
`GESTURE_SWIPE_BEGIN` przy 3 palcach. To jest **twardy warunek** wyboru maszyny.

## Claude Code na FreeBSD — przepis (2026)

Ścieżka npm **umarła w IV 2026** (od 2.1.113 wrapper odrzuca freebsd; binarka = zamknięty ELF
kompilowany Bunem). Upstream zamyka issue FreeBSD jako „not planned". Jedyna żywa ścieżka —
**Linuxulator**:

```sh
pkg install claude-code            # misc/claude-code 2.1.201 (yuri@), USES=linux:rl9, oficjalna binarka linux-x64
sysrc linux_enable=YES
service linux start
```

Twarde reguły:
1. **`DISABLE_UPDATES=1`** w `~/.claude/settings.json` (env) — auto-updater realnie rozwala
   instalację z pkg (issue #51833, closed not planned). Wersje tylko przez `pkg upgrade`.
2. **fdescfs z opcją `linrdlnk`** — bez tego Bun wisi w milczeniu na starcie (open()+readlink()
   na /dev/fd). `service linux start` montuje dobrze; psuje się przy ręcznych fstab/jailach.
   Debug: `mount | grep fdescfs`.
3. `pkg install ripgrep` + `USE_BUILTIN_RIPGREP=0` w env (vendorowany rg nie ma buildu freebsd).
4. Izolacja/YOLO: wbudowany sandboxing nie działa (Linux namespaces) → **efemeryczne
   Linux-enabled jaile na klonach ZFS** (spun.io/2026/04/26/ephemeral-claude-code-jails-on-freebsd):
   NIE nullfs-mountować samego ~/.claude.json (atomic rename deadlockuje kernel), securelevel=-1.
5. Fallback bez linux.ko: `misc/claude-code-legacy` (Node, zamrożona 2.1.110 — starzeje się).
6. Node do projektów: `pkg install node24 npm-node24`; `devel/fnm` jest w portach (volta nie).
7. Reszta toolingu w pkg: git, gh 2.83, ripgrep, fzf.

## Poprawki — instalator (`dev/freebsd`)

Priorytet malejąco:

1. **BLOCKER — XDG_RUNTIME_DIR dla niri/mango**: kompozytor startuje z tty, ale nikt nie tworzy
   `/var/run/user/<uid>` ani nie wpina `pam_xdg` → pierwsza sesja nie wstanie. Fix w
   `desktop_install` dla `_de_is_wayland`: `session optional pam_xdg.so` w pam.d logowania
   (README.md:189 opisuje to ręcznie tylko dla KDE) + notka POST-INSTALL.
2. **Goły kompozytor**: dla niri/mango instalowane tylko wayland+seatd+dbus+pkg kompozytora+pipewire
   (lib/desktop.sh:119-148). Dodać zestaw: foot/alacritty, fuzzel, mako, grim+slurp, swaylock/waylock,
   swaybg, xdg-desktop-portal(+wlr / +gnome dla niri), **xwayland-satellite**, fonty (noto/dejavu),
   xdg-user-dirs — np. jako domyślnie zaznaczony checklist w `tui/extra_packages.sh`.
3. **Power management zgubiony przy implementacji**: DESIGN.md:258 przewiduje powerd, `_emit_setup_script`
   go nie emituje. Dodać (gate na `hw.acpi.battery.units>0`): `powerd_enable=YES` (lub powerdxx),
   `performance_cx_lowest=C2 economy_cx_lowest=Cmax`; suspend: sprawdzić `hw.acpi.supported_sleep_state`
   → jeśli S3: opt-in `hw.acpi.lid_switch_state=S3`; jeśli brak S3: **głośna notka** „suspend
   niedostępny (s2idle ~15.2)".
4. **Backlight**: devfs.rules dające grupie video dostęp do `/dev/backlight/*` + bindy w skel.
5. **Touchpad generic**: `kld_list+="ig4 iichid"` nie tylko dla Surface (dziś: lib/umpc.sh:290);
   `hw.psm.synaptics_support=1`; **moused włączać tylko dla DESKTOP_TYPE=none** (dubluje kursor
   pod libinput).
6. **WiFi first boot**: opcjonalny ekran SSID+PSK (zapis przez `wpa_passphrase` do
   wpa_supplicant.conf targetu, 0600) + `create_args_wlan0="country PL"` wg locale. Dziś system
   bootuje z wlan0 bez credentiali.
7. **Profil thinkpad** (kenv smbios maker=LENOVO, product ThinkPad*): `kld_list+=acpi_ibm`
   (hotkeys/fan) + notka o braku S3 na nowych generacjach.
8. Webcam: `WEBCAM_DETECTED` jest martwe — dodać webcamd+cuse+grupa (komentarz w
   extra_packages.sh:9 „handled elsewhere" jest nieprawdziwy).
9. ZFS: `zpool set autotrim=on zroot` w finalize; UFS: `trim` w fstab dla SSD.
10. Ujednolicić werdykt iwlwifi (DESIGN.md mówi a/b/g, hardware.sh a/b/g/n, system.sh/README ac —
    poprawnie: **ac od 14.3**); Bluetooth: opt-in hcsecd/sdpd + uczciwa notka (HID tak, audio nie).
11. Pomysł-feature: krok „Claude Code" w extras — `linux_enable=YES` + pkg claude-code +
    settings.json z DISABLE_UPDATES/USE_BUILTIN_RIPGREP.
12. TODO.md nie trackuje ŻADNEJ pozycji laptopowej — dodać sekcję „Laptop daily-driver".

## Poprawki — wizard dotfiles (`~/dotfiles`)

Rdzeń (detekcja, pkg, batch, minor/major upgrade, gum, sysrc/service, bootstrap) — **wzorcowy**.
Defekty niżej:

1. **BLOCKER — shebangi**: 13 skryptów z `#!/bin/bash` (hypr/scripts/{lock,power-menu,switch-shell,
   wallhaven-rotate,refresh-colors,ensure-waybar-colors,bluetooth-toggle,mask-waybar-service,
   autostart-shell}.sh, niri/scripts/autostart-shell.sh, mango/autostart.sh,
   waybar/scripts/{theme-toggle,wallpaper-chooser}.sh) → `#!/usr/bin/env bash`. To naprawia lock,
   power-menu, autostart, tapety. Zero ryzyka dla Linuksa. UWAGA: niri i mango execują
   `~/.config/hypr/scripts/*` — hypr/scripts to współdzielona warstwa, deployować też bez Hyprlanda.
2. **BLOCKER — klobber binarek**: `_update_special_apps` → manage_eza/topgrade/broot na PM=pkg
   wpadają w default `*)` → pobierają hardcodowane `x86_64-unknown-linux-{gnu,musl}` i robią
   `_sudo mv` do /usr/local/bin **nadpisując działające pkg-owe binarki linuksowym ELF-em**
   (apps_special.sh:134,634; pkg_install.sh:924-947). Fix: guard `[ "$(uname -s)" = Linux ]`
   w `install_from_binary_url`/`*_from_github` + gałęzie `pkg)` w manage_* (wzorzec z
   manage_direnv: `app_get_pm_name` + `install_single_pkg` — bez pisania 55 case'ów).
3. **BLOCKER — pipewire_stack**: w DESKTOP_SYSTEM_APPS, a `manage_pipewire_stack` na pkg
   → „brak mapowania" → return 1 (apps_special.sh:5434). Dodać `pkg) pkgs=(pipewire wireplumber)`
   + pominąć krok systemd (na FreeBSD startuje z autostartu kompozytora — configi już to robią).
4. **BLOCKER — claude_code**: na FreeBSD leci w `curl claude.ai/install.sh` który twardo odrzuca
   FreeBSD. Dodać gałąź pkg: `pkg install -y claude-code` + zapis DISABLE_UPDATES (rejestr
   celowo nie mapuje portu — registry.sh:931-933 — do rewizji, port jest teraz aktualny
   dzień-w-dzień).
5. **MAJOR — GNU find**: `find -executable` (pkg_install.sh:890 + 6 kopii w apps_special) → BSD find
   nie zna → cała ścieżka GitHub-fallback martwa. Fix: `-perm -u+x` (działa w obu).
6. **MAJOR — check_internet**: baza FreeBSD nie ma curl/wget (jest fetch(1)), a `ping -W3` to na
   FreeBSD 3 **milisekundy** → świeży system zawsze „bez internetu". Dodać fetch + flagi per-uname.
7. **MAJOR — $SED**: wybierany raz przy source, a gsed instaluje się dopiero w kroku [1/7] →
   pierwsze uruchomienie z BSD sed psuje `$SED -i`. Zamienić na funkcję `_sed_i()` (wybór per-call).
8. **MAJOR — ekosystem niri w config.sh**: brak mapy pkg → do batcha lecą network-manager-applet,
   blueman, brightnessctl (nie istnieją na FreeBSD); detekcja portali sprawdza tylko
   `/usr/share/...` (FreeBSD: `/usr/local/share/...`); dep-helpery awww/xwayland-satellite bez
   gałęzi pkg. Dodać `_pkg_names` z pustymi wpisami + komunikat o natywnych odpowiednikach.
9. MINOR: node nigdy nieinstalowany na FreeBSD (dodać node24+npm-node24 do install_distro_tools);
   atuin — upgrade-path przez curl-installer bez artefaktów freebsd (gate na Linux); waypaper —
   pipx bez PyGObject/GTK (dodać py3XX-gobject3 gtk3); noctalia — `_ensure_quickshell` nie zna
   freebsd mimo że x11/quickshell JEST w portach; pikabar — Linux-only (zig-binarki z .deb),
   gate'ować; `make -j$(nproc)` → `sysctl -n hw.ncpu` + gmake; gnome-keyring/libsecret w kroku
   „dodatkowe pakiety" (gałąź pkg); status: pomijać wiersz Distrobox, dodać pkg/freebsd-update.

## Poprawki — configi

1. **Power menu / wlogout**: `systemctl suspend|reboot|poweroff` + `loginctl` → martwe. Gałąź OS:
   suspend `acpiconf -s 3`, reboot `shutdown -r now`, poweroff `shutdown -p now` (user w grupie
   **operator** — instalator już to robi), hibernate usunąć. Dotyczy: wlogout/layout,
   hypr/scripts/power-menu.sh, lock.sh:95.
2. **Jasność**: `brightnessctl` (niri/config.kdl:193, mango/config.conf:204) → nie istnieje na
   FreeBSD. Shim `scripts/brightness.sh`: `command -v brightnessctl || backlight incr/decr 5`.
3. **Waybar — wariant config-freebsd.jsonc**: moduły **network i bluetooth nie są wkompilowane**
   w FreeBSD-owy build (libnl / is_linux w meson), backlight kompiluje się ale nie widzi urządzeń
   (libudev-devd nie eksportuje subsystemu). Działają: battery, cpu, memory, temperature (sysctl!),
   wireplumber, tray, clock, niri/*, custom/*. Fix: wywalić network/bluetooth/backlight, dodać
   custom wifi (`ifconfig wlan0 list scan` + wpa_cli) i custom backlight (`backlight -q`),
   `thermal-zone: 0` (nie 5) + kldload coretemp.
4. **wifi-menu.sh** (nmcli) → przepisać na wpa_cli + fuzzel; GUI: net-mgmt/wifimgr lub networkmgr.
5. **bluetooth-menu/toggle** (bluetoothctl+rfkill, BlueZ nie istnieje) → gate `command -v
   bluetoothctl || exit 0`; BT na FreeBSD dokumentować jako unsupported.
6. **matugen**: brak portu → `cargo install matugen` (rust z pkg, buduje się); **pkill w
   config.toml ma sygnał po flagach** (`pkill -x -SIGUSR2 waybar`) — FreeBSD wymaga sygnału
   PIERWSZEGO: `pkill -USR2 -x waybar` (działa na obu) — bez tego live-reload kolorów nie działa.
7. Drobne: setsid → `pkg install setsid` (sysutils/setsid) albo fallback; polkit agent — dodać
   ścieżki `/usr/local/libexec/...`; weather.sh `stat -c` → `stat -f %m ||`; zsh
   `alias cal='ncal -3bMJw'` → FreeBSD nie zna `-b`; ghostty terminfo probe — dodać
   `/usr/local/share/terminfo`; waypaper `backend = swww`; fastfetch config13 (/proc,/sys) —
   nie używać na FreeBSD; distro-icon.sh — dodać case freebsd; launcher.sh — kolizja nazwy
   `walker` z dns/walker w pkg.

## Checklist weryfikacyjny (live USB 15.1, przed instalacją na dysk)

1. GPU: `kldload i915kms` → czy konsola przełącza się bez paniki; potem test niri/mango.
   Przy GPU HANG na 15.1 → drm-66-kmod.
2. WiFi: asocjacja + `iperf3` (oczekiwane ~100–200 Mbps na ac).
3. **Gesty**: `kldload ig4 iichid; libinput debug-events` → GESTURE_SWIPE_BEGIN na 3 palce.
4. Audio: `sysctl hw.snd.default_unit`, `mixer`, test głośników/jacka (X1 Nano: możliwe pin-quirki).
5. Suspend: `sysctl hw.acpi.supported_sleep_state`; jeśli S3 → `acpiconf -s 3` + resume
   (ekran, WiFi po bounce, klawiatura).
6. niri z tty: czy 26.04 wstaje (regresja #3013) — jak nie: `LIBSEAT_BACKEND=consolekit2`.
7. Kamera: webcamd + cuse. 8. Screenshare: Chromium + Meet przez portal.
9. Zrobić `hw-probe` i wrzucić do bsd-hardware.info (zamyka lukę dowodową dla modelu).

## Kluczowe źródła

- FreshPorts: x11-wm/niri 26.04_3, x11-wm/mango 0.14.4, misc/claude-code 2.1.201,
  misc/claude-code-legacy, x11/plasma6-plasma 6.6.5, x11/sddm 0.21.0.36_3 (fix bug 286592),
  x11-wm/cosmic-comp (bez DE), x11/libinput 1.31.1, devel/fnm
- niri: github.com/niri-wm/niri issues #3013 (DRM/tty na 15.x, OPEN), PR #4016
- Claude Code: spun.io/2026/04/26 (Linuxulator + fdescfs linrdlnk; ephemeral jails),
  anthropics/claude-code #51020 (npm od 2.1.113 odrzuca freebsd), #51833 (auto-updater vs pkg)
- X1 Nano: bsd-hardware.info/?probe=b97dcbade6 (14.0), jcs.org/2021/01/27/x1nano (S3 od BIOS 1.43,
  topologia), sacredheartsc.com/blog/freebsd-15-on-a-laptop (X1C na 15.1, VI 2026),
  thesofproject discussion #9506 (DMIC nie przez legacy HDA)
- Laptop project: freebsdfoundation.org „year one update" (XII 2025), status report 2026Q1,
  proj-laptop monthly 2026-04/05 (s2idle w review, missed 15.1; uvc Q2 2026; Wi-Fi 6 underway)
