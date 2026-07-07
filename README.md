# FreeBSD TUI Installer

Interaktywny installer **FreeBSD** z interfejsem TUI (gum/dialog). Przeprowadza za rękę przez cały proces instalacji — od układu dysku po działający desktop. Po awarii: `bash install.sh --resume` wznawia od ostatniego checkpointu, bez ponownego nagrywania pendrive'a.

Wierny port **rodziny instalatorów szoniu** (bliźniacze: `alpine`, `chimeraos`, `gentoo`, `nixos`, `porteux`, `void`) przełożony z idiomów Linuksa na FreeBSD. Ten sam `bash` + [`gum`](https://github.com/charmbracelet/gum), ten sam przepływ ekranów, to samo menu recovery `try()`, ten sam model checkpoint/resume. Zmienia się podłoże:

- **Instalacja bazy** robi `bsdinstall(8)` w trybie *scripted* — nasz TUI generuje plik `bsdinstall script` (PREAMBLE z przypisaniami zmiennych + chrootowany SETUP SCRIPT) i go uruchamia.
- **Post-install** (grafika, desktop, quirki sprzętowe, dodatki, finalize) leci jako nasze własne fazy, które wchodzą do świeżo zainstalowanego systemu w `/mnt` przez `chroot_exec`/`chroot_pkg`.
- **Pakiety** to `pkg`, nie `xbps`/`portage`/`apt`. Usługi przez `rc.conf` (`sysrc`), nie runit/systemd. Bootloader to EFI loader FreeBSD, nie GRUB. System plików: **ZFS** (z boot environments) albo UFS — żadnego ext4/btrfs.

> Pełne uzasadnienie każdej decyzji specyficznej dla FreeBSD: [`docs/DESIGN.md`](docs/DESIGN.md).
> Runbook testu na żywym sprzęcie: [`docs/LIVE-TEST.md`](docs/LIVE-TEST.md). Status: [`docs/HANDOFF.md`](docs/HANDOFF.md).

## Krok po kroku (od zera do działającego systemu)

> **Gdzie fizycznie, skąd zdalnie.** Kroki **1–3b wykonujesz przy maszynie** (klawiatura + ekran targetu) — to kura-i-jajko: bez sieci i działającego `sshd` nie ma jak się połączyć. Od **kroku 4 (bootstrap + uruchomienie instalatora) możesz już działać przez SSH** z innej maszyny — montowanie tmpfs na `/usr/local` i `/tmp` nie rusza działającego `sshd` (klucze/config są w `/etc`), więc sesja nie pada. Jeśli nie chcesz zdalnie — pomiń §3b i zrób wszystko na targecie; też zadziała.

### 1. Przygotuj bootowalny pendrive (memstick)

FreeBSD rozprowadza obraz **`*-memstick.img`** (NIE plik ISO). Pobierz **pełny memstick amd64** — nie mini-memstick (mini ciągnie bazę z sieci; pełny ma offline'owe `base.txz`/`kernel.txz` w `/usr/freebsd-dist`, więc instalacja bazy działa bez internetu):

- Oficjalnie: https://www.freebsd.org/where/ → **Get FreeBSD** → **amd64**
- Bezpośredni katalog (podstaw wersję na końcu ścieżki — `14.3/`, `15.0/`, `15.1/`): https://download.freebsd.org/releases/amd64/amd64/ISO-IMAGES/

Wybierz wydanie: **14.x (14.3 / 14.4) — zalecane** (najdojrzalsze sterowniki), albo **15.x (15.0 / 15.1)** jako „newest base". Plik: `FreeBSD-14.3-RELEASE-amd64-memstick.img` (dla 15.0 analogicznie `FreeBSD-15.0-RELEASE-amd64-memstick.img`). Wersji nie musisz nigdzie podawać instalatorowi — `drm-kmod` sam dobiera sterownik pod uruchomiony kernel (14.x → `drm-61`, **15.0 → `drm-66`**, 15.1 → `drm-612`).

#### Nagranie przez `dd` (Linux)

> **`dd` nie pyta o potwierdzenie i kasuje cel bez ostrzeżenia.** Pomyłka w `of=` = wymazany dysk systemowy. Najpierw **na 100% ustal nazwę pendrive'a**, dopiero potem pisz.

**1. Znajdź urządzenie pendrive'a.** Wypisz dyski PRZED i PO włożeniu pendrive'a — nowy wpis to on:

```bash
lsblk -o NAME,SIZE,MODEL,TRAN,MOUNTPOINTS
```

Pendrive rozpoznasz po rozmiarze i `TRAN=usb` (np. `sdb`, `sdc`). Dysk systemowy to zwykle `nvme0n1` lub `sda` (`TRAN=nvme`/`sata`). Cel to **całe urządzenie** (`/dev/sdb`), **nie** partycja (`/dev/sdb1`). Alternatywnie zaraz po włożeniu: `dmesg | tail` pokaże `sdX ... USB`.

**2. Odmontuj auto-zamontowane partycje** (środowisko graficzne montuje pendrive samo — `dd` do podmontowanego nośnika może się wywalić):

```bash
sudo umount /dev/sdX*    # podstaw swoje sdX; gwiazdka = wszystkie partycje
```

**3. Zapisz obraz** (podstaw `sdX`; `conv=fsync` wymusza zrzut na dysk przed końcem):

```bash
sudo dd if=FreeBSD-14.3-RELEASE-amd64-memstick.img of=/dev/sdX bs=4M status=progress conv=fsync
```

Jeśli pobrałeś skompresowane `.img.xz`, rozpakuj w locie (bez rozpakowywania na dysk):

```bash
xzcat FreeBSD-14.3-RELEASE-amd64-memstick.img.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

**4. Dosynchronizuj i sprawdź.** `sync` opróżnia bufory; `lsblk` powinno teraz pokazać partycje FreeBSD na pendrive:

```bash
sync && lsblk -o NAME,SIZE,LABEL /dev/sdX
```

Zobaczysz partycje typu `efi` i `FreeBSD_Install` — wtedy pendrive jest gotowy do bootowania. Możesz wyjąć.

> macOS: to samo, ale urządzenie to `/dev/diskN` (znajdź przez `diskutil list`), odmontuj `diskutil unmountDisk /dev/diskN`, pisz na `/dev/rdiskN` (raw, szybsze). Windows: [Rufus](https://rufus.ie) (tryb **DD Image**) lub [balenaEtcher](https://etcher.balena.io).

### 2. Bootuj z pendrive

- Wejdź do BIOS/UEFI (zwykle F2, F12, Del przy starcie), ustaw boot z USB.
- **Secure Boot — WYŁĄCZ.** FreeBSD nie ma odpowiednika MOK/shim z rodziny Linux; przy włączonym Secure Boot loader się nie uruchomi.
- Wybierz **UEFI** (nie Legacy/CSM), chyba że celowo instalujesz w trybie BIOS.
- **Snapdragon / ARM64** (Surface Pro 11. gen, Laptop 7. gen): instalator wykryje i **ODMÓWI** — jest tylko amd64.

W menu bootloadera FreeBSD **nie wciskaj nic** — pozwól odliczyć (opcja 1, Multi-user/Install). Gdy pojawi się menu instalatora `[ Install ] [ Shell ] [ Live CD ]`, wybierz **`Shell`** — to właściwy live shell (`#`), w którym robisz bootstrap (krok 4).

> **„Gdzie jestem?" — nie pomyl promptów.** Jeśli zobaczysz `OK`, to **NIE** live shell, tylko prompt **loadera** (forth) — wpadasz w niego, wybierając „Escape to loader prompt"; uniksowe komendy dają tam „unknown command". Wpisz **`boot`**, żeby dokończyć start, potem wybierz `Shell`.
>
> | Prompt | Gdzie jesteś | Co zrobić |
> |---|---|---|
> | `OK` | loader (forth), przed startem OS | `boot` |
> | menu `[Install] [Shell] [Live CD]` | bsdinstall | wybierz `Shell` |
> | `#` | live shell (root) | tu robisz bootstrap (krok 4) |

### 3. Połącz się z internetem — KABLEM

> **Ostrzeżenie WiFi — przeczytaj najpierw.** Na **GPD Pocket 4** i kilku modelach **Microsoft Surface** wbudowany chip WiFi **nie ma sterownika FreeBSD** (tabele niżej). Na tych maszynach **nie postawisz** WiFi na live media — użyj **kabla Ethernet lub przejściówki USB-Ethernet** (albo USB-tether z telefonu). Zaplanuj kabel.

Jako `root` w Live Shell:

```sh
ifconfig -l            # znajdź interfejs
dhclient em0           # podstaw swój: igb0 / re0 / ure0 / ...
```

> **Po instalacji — WiFi w zainstalowanym systemie.** Na zwykłym laptopie (np. **Intel AX201/AX211** jak w HP ProBook G8) chip ma sterownik. Instalator wykrywa go i — dla **Intel (`iwlwifi`)** — **sam wpisuje `if_iwlwifi` + `wlan0` (WPA/SYNCDHCP) do `rc.conf`** targetu oraz zostawia szablon `/etc/wpa_supplicant.conf`. Po pierwszym boocie uzupełniasz tam SSID/hasło i `service netif restart wlan0`. (`iwlwifi` = **802.11 a/b/g/n/ac od 14.3** przez LinuxKPI; ax/Wi-Fi 6 w toku — FreeBSD Foundation, 2026.) Realtek/Atheros instalator wykrywa, ale konfigurację zostawia w notatkach POST-INSTALL (nazwa modułu jest niejednoznaczna: rtw88 vs rtw89, ath vs ath10k). **Podczas samej instalacji i tak używaj kabla.**

> **Sieć przewodowa w zainstalowanym systemie działa od pierwszego bootu** — instalator wpisuje do `rc.conf` `ifconfig_DEFAULT="DHCP"`, więc dowolny interfejs Ethernet bez własnego configu dostaje DHCP, bez podawania nazwy `em0`/`igb0`. **Uwaga na KDE:** aplet sieci Plasmy (`plasma-nm`) bywa „ślepy" i pokazuje *brak sieci*, bo FreeBSD nie używa NetworkManagera — sieć stoi na `rc.conf`. To **kosmetyka**: sprawdź realną łączność przez `ping`, a WiFi konfiguruj przez `wpa_supplicant`/`rc.conf` (lub `service netif restart wlan0`), nie przez ikonkę. Doraźnie: `doas dhclient <iface>`.

### 3b. (Opcjonalnie) Zdalny podgląd przez SSH

Chcesz prowadzić instalację z innej maszyny (wygodniej niż na ekranie targetu)? Na live media jako `root`, gdy sieć już stoi:

```sh
mount -uw /                                          # live root jest RO — BEZ tego passwd się nie utrwala ani sshd nie zapisze kluczy/configu
passwd                                               # ustaw hasło roota (live nie ma żadnego; bez hasła sshd odbije PAM)
echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config   # domyślnie sshd nie wpuszcza roota po haśle (prohibit-password)
service sshd onestart                                # start sshd (wygeneruje brakujące klucze hosta w /etc/ssh)
ifconfig em0 | grep 'inet '                          # odczytaj IP targetu (podstaw swój iface)
```

> **`mount -uw /` jest kluczowe.** Live root montuje się read-only: bez przemontowania na RW `passwd` nie zapisze się do `/etc/master.passwd` (root zostaje bez hasła → `ssh` zwraca „PAM authentication error"), `echo >> sshd_config` daje „Read only file system", a `service sshd onestart` nie wygeneruje kluczy hosta. Memstick to fizyczny UFS, więc `mount -uw /` działa. **Gdyby sypnął** (rzadkie buildy z root na md(4)): nie utrwalisz hasła — wejdź na klucz publiczny, startując sshd bez edycji configu:
> ```sh
> ssh-keygen -t ed25519 -f /tmp/hk -N ''      # klucz hosta w zapisywalnym /tmp
> mkdir -p /tmp/ssh && cat >> /tmp/ssh/authorized_keys   # wklej swój ~/.ssh/id_*.pub z dev, Ctrl-D
> /usr/sbin/sshd -o PermitRootLogin=yes -o AuthorizedKeysFile=/tmp/ssh/authorized_keys -h /tmp/hk
> ```

Z maszyny dev: `ssh root@<IP-targetu>`. **Odpalaj instalator w `tmux`** (doinstaluj `tmux` w kroku 4, potem `tmux`), żeby zerwane SSH nie ubiło instalacji — po rozłączeniu wrócisz przez `tmux attach`. Z drugiej zakładki tmux podglądasz log: `tail -f /tmp/freebsd-installer.log`.

### 4. Bootstrap warstwy shell + uruchomienie instalatora

Live media FreeBSD ma root **tylko do odczytu**, tylko `/bin/sh` (ash, *nie* bash), `pkg` niezbootstrapowany i pusty/RO `/usr/local`. Trzeba położyć zapisywalną nakładkę i zbootstrapować warstwę shell:

```sh
# 1) /usr/local i /tmp zapisywalne (media RO), ZACHOWUJĄC resolv.conf:
mount -t tmpfs -o size=1g tmpfs /usr/local
mkdir -p /tmp.bak && cp -a /tmp/. /tmp.bak/
mount -t tmpfs -o size=512m tmpfs /tmp
cp -a /tmp.bak/. /tmp/

# 2) DNS:
[ -s /etc/resolv.conf ] || echo 'nameserver 1.1.1.1' > /etc/resolv.conf

# 3) pkg + warstwa shell. TMPDIR + baza/cache pkg na zapisywalnym tmpfs — inaczej
#    duży katalog repo (zwł. 15.x) przepełnia ciasny live-tmpfs na /var:
mkdir -p /usr/local/pkg/db /usr/local/pkg/cache
export TMPDIR=/usr/local PKG_DBDIR=/usr/local/pkg/db PKG_CACHEDIR=/usr/local/pkg/cache
pkg bootstrap -fy && pkg update -f && pkg install -y bash gum git tmux

# 4) Środowisko konsoli dla gum na vt(4):
export TERM=xterm-256color LANG=en_US.UTF-8 LC_CTYPE=en_US.UTF-8

# 5) Klon i uruchomienie:
git clone https://github.com/szoniu/freebsd.git /tmp/installer
exec bash /tmp/installer/install.sh
```

Pułapki:

- **Remount `/tmp` jako tmpfs WYMAZUJE `resolv.conf`**, jeśli nie skopiujesz go z powrotem — krok 1 to robi. Gdy DNS padnie później, po prostu dodaj linię nameserver ponownie.
- **`/var` na live media to ciasny tmpfs**, a `pkg` domyślnie pisze tam katalog repo (`/var/db/pkg`) i cache (`/var/cache/pkg`). Duży katalog binarnego repo (zwł. 15.x) go przepełnia → `pkg: ... database or disk is full`. Krok 3 przekierowuje `PKG_DBDIR`/`PKG_CACHEDIR` na większy tmpfs (`/usr/local`). Te zmienne dotyczą TYLKO bootstrapu live — instalator odcina je w chroocie (`chroot_pkg` robi `env -u PKG_DBDIR -u PKG_CACHEDIR`), więc baza pakietów targetu zawsze ląduje w jego `/var/db/pkg`.
- `bash`/`gum`/`git` lądują w **`/usr/local/bin`**, nie `/bin` — dlatego każdy skrypt ma shebang `#!/usr/bin/env bash`. Plików `lib/*.sh` nie uruchamiaj wprost; są *source'owane*.
- Konsola vt(4) renderuje 16 kolorów; `gum` degraduje się łagodnie, ale wymaga **locale UTF-8** (krok 4).
- **Repo pkg zablokowane, ale GitHub działa?** Statyczna binarka `gum` dla FreeBSD/amd64 jest bundlowana w `data/gum.tar.gz` (asset `gum_0.17.0_Freebsd_x86_64.tar.gz`, uwaga na kapitalizowane `Freebsd`); instalator wypakowuje ją sam, więc twardo potrzebujesz tylko `bash` + `git`.

### Inne tryby uruchomienia

```sh
bash install.sh                  # pełny przebieg: wizard, potem instalacja
bash install.sh --configure      # tylko wizard — zapisuje .conf, nic nie instaluje
bash install.sh --install        # tylko instalacja, z istniejącego configu
bash install.sh --resume         # wznów przerwaną instalację (skan checkpointów)
bash install.sh --dry-run        # przejdź cały przepływ BEZ operacji destrukcyjnych
bash install.sh --config FILE    # użyj konkretnego pliku konfiguracji
bash install.sh --force          # kontynuuj mimo nieudanych prerequisite-checków
bash install.sh --non-interactive  # przerwij na każdym błędzie (bez menu recovery)
```

## Menu desktopów

Ekran desktopu oferuje jeden wybór (radiolist). Caveat FreeBSD jest pokazany inline, żebyś widział trade-off przed wyborem. Display managery i obsługa „seat" w Waylandzie różnią się ostro od Linuksa — **nie ma systemd-logind**; sesje Wayland startują przez **`seatd`**, a user musi mieć dostęp do jego socketu. Uwaga: na aktualnym `seatd` socket jest własnością grupy `seatd_group` (domyślnie **`video`**), a **nie** nieistniejącej grupy `_seatd` (`pw groupmod _seatd` zwraca „unknown group"); instalator pinuje `seatd_group=video` i dba, by user był w `video`.

| Wybór | Stack | Caveat FreeBSD |
|---|---|---|
| **none** | Serwer, bez GUI — sama baza, login tty | Nic graficznego. |
| **KDE Plasma** | `kde` / `plasma6-plasma` + **SDDM** | **Wybierz `startplasma-x11` (X11)** — stabilna ścieżka 2026. **Sesja Wayland z SDDM jest na FreeBSD zepsuta** (znany bug, nie regresja wersji — patrz nota niżej). Zepsute też pod VirtualBox. |
| **GNOME** | `gnome` / `gnome-lite` + **GDM** (bundled) | Wymaga `proc /proc procfs rw 0 0` w fstab. |
| **Xfce** | `xfce4` + **LightDM** | Lekki, niezawodny. |
| **MATE** | `mate` / `mate-base` + **LightDM** | Tradycyjny, niezawodny; potrzebuje procfs w fstab. |
| **Cinnamon** | `cinnamon` + **LightDM** | **Tylko X11** na FreeBSD; potrzebuje procfs w fstab. |
| **LXQt** | `lxqt` + **SDDM** | Minimalny desktop Qt; potrzebuje procfs w fstab. |
| **sway** | `sway` (Wayland) | login tty przez `seatd`; **pewny binarny pkg**. |
| **niri** | `niri` (Wayland, scrollable tiling) | **pewny binarny pkg** na 14/15 amd64. |
| **Hyprland** | `hyprland` (Wayland) | **binarny pkg niespójny — może wymagać builda z portów**. |
| **Mango** | `mango` (Wayland, dwl-based tiling) | login tty przez `seatd`; **pewny binarny pkg** (Latest). Tagi w stylu dwm + efekty scenefx. |

Każdy profil graficzny ciągnie `xorg`/`wayland` + `drm-kmod` i włącza `dbus`. **`moused` jest włączany tylko przy instalacji bez desktopu (`none`)** — pod libinput/Waylandem rysowałby drugi, rozjechany kursor. Kompozytory Wayland bez DM (sway/niri/Hyprland/Mango) dostają dodatkowo **`pam_xdg` w `/etc/pam.d/login`** (XDG_RUNTIME_DIR przy logowaniu z tty) oraz komplet userlandu sesji (foot, fuzzel, mako, grim+slurp, swaylock, swaybg, portale XDG per-kompozytor, xdg-user-dirs, fonty noto-basic+dejavu; niri dodatkowo xwayland-satellite). **PipeWire to usługa USER na FreeBSD** — nie ma `pipewire_enable` w `rc.conf`; startuje per-user przez XDG autostart. `elogind` i `seatd` konfliktują, więc instalator standaryzuje na **`seatd`**.

> **KDE Plasma Wayland na FreeBSD — używaj X11 (zweryfikowane na sprzęcie).** Logowanie w sesję **Plasma (Wayland) z SDDM zwykle nie wstaje** i wyrzuca do ekranu logowania. W logu (`~/.local/share/sddm/wayland-session.log`) widać `kwin_wayland_drm: No suitable DRM devices have been found` — kompozytor nie przejmuje GPU spod SDDM (z SDDM-a nie dostaje aktywnego VT/seatu). To **nie regresja 15.0→15.1**, tylko długoletni, ogólnofreebsdowy problem (KDE Community Wiki notuje „SDDM may be bugged" dla Waylanda; handbook trzyma Wayland jako eksperymentalny). Udokumentowana metoda startu to **z TTY**, nie z SDDM: na wolnej konsoli (`Ctrl+Alt+F3`) `export XDG_RUNTIME_DIR=/var/run/user/$(id -u); mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"`, potem `dbus-run-session startplasma-wayland` — i bywa niestabilne. Jeśli i tak chcesz Waylanda dla gestów touchpada, potrzebujesz: `seatd` (running, user w `video`) + `XDG_RUNTIME_DIR` przy logowaniu, które na FreeBSD daje **`pam_xdg`** wpięty do **`/usr/local/etc/pam.d/sddm`** (porty trzymają politykę PAM w `/usr/local/etc/pam.d/`, NIE w `/etc/pam.d/`: `echo 'session optional pam_xdg.so' >> /usr/local/etc/pam.d/sddm`). Pragmatyczna alternatywa: **zostań na X11** i gesty 3-palcowe zrób przez `libinput-gestures` mapujące swipe na `qdbus` zmianę pulpitu.

> **COSMIC** (System76) jeszcze **NIE** w menu: w portach jest tylko `cosmic-comp` (sam kompozytor), brak `cosmic-session`/panelu/greetera → nie daje używalnej sesji. Dodanie zaplanowane, gdy pełna sesja trafi do binarnego pkg (TODO w `docs/DESIGN.md` §4).
>
> **Gershwin** (desktop GNUstep w stylu macOS, rozwijany w GhostBSD) też **NIE** w menu — i to świadomie. To wczesna **alfa**; na czystym FreeBSD stawia się go tylko przez `gershwin-build` (build ze źródeł) lub z **niestabilnych repo GhostBSD**, brak czystego binarnego `pkg` z gotową sesją (dziś używa nawet `xfce4-wm` jako WM). Ta sama logika co przy COSMIC: dodanie będzie jednolinijkowe (jak Mango), gdy trafi do binarnego pkg jako samodzielna sesja. Na razie wybierz **`none`** i złóż Gershwina ręcznie po instalacji.

## Uwagi per-urządzenie

Te dwa urządzenia są powodem, dla którego instalator ma taki kształt. Werdykty z [`docs/DESIGN.md`](docs/DESIGN.md) §5 (badanie sprzętowe 10 agentów, czerwiec 2026).

### GPD Pocket 4 (Ryzen 8840U / Radeon 780M)

> **WiFi/Bluetooth — WERDYKT NAJPIERW: NIE DZIAŁA (severity: BLOCKER).** Chip to AMD RZ616 = MediaTek **MT7922** (Filogic 330P, PCI `14c3:0616`) — **nie** Intel AX210. Sterownik `mt76` jest in-tree od 14.x, ale **odłączony od builda**, a raporty z forum (styczeń 2026) pokazują **zero udanych asocjacji**. Bluetooth to osobny interfejs USB, też martwy. **Musisz bootstrapować przez wired/USB-Ethernet** (przejściówka USB-C `ure`/`cdce`, USB-tether telefonu, albo stick USB WiFi `rtwn`/`run`). Instalator ustawia `WIFI_SUPPORTED=0` i ostrzega.

| Komponent | Status | Severity |
|---|---|---|
| WiFi/BT (MT7922) | **NIE DZIAŁA** — brak asocjacji | **BLOCKER** |
| Radeon 780M GPU | **DZIAŁA** — `drm-61-kmod` + `amdgpu` + **sześć** flavorów firmware AMD Phoenix; zły/brakujący flavor = **KERNEL PANIC** | medium |
| 780M Vulkan compute | hard-lock GPU przy długim compute (drm-kmod #387) | medium |
| Rotacja konsoli / loadera | **NIEMOŻLIWA** — `kern.vt.rotate` nie istnieje; TUI bsdinstall wyświetla się **bokiem** na portretowym panelu | high (UX) |
| Rotacja GUI | **DZIAŁA po loginie** — Wayland `output eDP-1 transform 90/270`, Plasma Portrait, Xorg `xrandr --rotate right` | — |
| Audio (ALC287) | możliwe z `snd_hda`; wartości pinów per-unit (`dev.hdaa.N.pindump=1` → `/boot/device.hints`); brak Auto-Mute | medium |
| Auto-rotate akcelerometr (MXC6655) | **NIE** — brak IIO / iio-sensor-proxy | low |
| Sterowanie wentylatorem | **NIE** — brak odpowiednika `gpd-fan`; EC działa autonomicznie | low |

ARC ZFS jest capowany na modelu 12 GB RAM: `vfs.zfs.arc_max="4294967296"` (4 GiB, **w bajtach** — forma `"4G"` bywa odrzucana). Swap domyślnie **8 GiB, szyfrowany**.

780M działa, ale powiązanie z flavorami firmware jest kruche: sześć split-pakietów — `gpu-firmware-amd-kmod-{dcn-3-1-4, gc-11-0-1, gc-11-0-4, psp-13-0-4, sdma-6-0-1, vcn-4-0-2}` — musi być obecnych, a `amdgpu` ładuje się przez **`sysrc kld_list+=amdgpu`**, *nigdy* przez `loader.conf` (to panikuje wczesny boot). Na niektórych buildach 14.3 `amdgpu` w `kld_list` zamrażał boot, więc istnieje fallback `kldload amdgpu` po boocie.

### Microsoft Surface (best-effort)

> **Werdykt WiFi (zależny od chipu):** AX200/AX201 (Go 2/3, Pro 7/8) działają przez `iwlwifi` — **802.11 a/b/g/n/ac od 14.3 (LinuxKPI)**, ax/Wi-Fi 6 w toku (FreeBSD Foundation, 2026); QCA6174 (oryginalny Go, wiele Pro 4–6) ma `ath10k` odłączony → **brak WiFi, użyj donglea USB**.

| Komponent | Status | Severity |
|---|---|---|
| Klawiatura/touchpad (Laptop 1–6, Book 3, Laptop Studio) | **MARTWE** — routowane przez Surface Aggregator Module (SAM), brak sterownika. **Wymaga zewn. USB kbd + mysz nawet do instalacji** | **BLOCKER** (te modele) |
| Type Cover (Pro / Go) | **DZIAŁA** — USB-HID przez `ukbd`/`hkbd`/`hms`/`hmt` (nie SAM) | — |
| Touch / pen (Pro 4+, Book, Laptop, Studio) | **NIE** — IPTS wymaga linuksowego `iptsd` | medium |
| Touch (Go / Go2 / Go3) | może przez `iichid`/`ig4`/`hmt` — **niska pewność** | low-conf |
| GPU | Intel `i915kms` / AMD `amdgpu` — działa | — |
| Bluetooth, kamery, sensory, **suspend S3** (S0ix) | **NIE** | medium |
| ARM64 Snapdragon (Pro 11. gen / Laptop 7. gen) | **poza zakresem** — wykryty i **odrzucony** | — |

Surface HID-over-I2C potrzebuje `sysrc kld_list+="ig4 iichid"` i `loader.conf hw.usb.usbhid.enable=1`; AX200/AX201 potrzebują `sysrc kld_list+=if_iwlwifi wlans_iwlwifi0=wlan0`.

## Pętla testu na żywo

Instalator rozwijany jest na realnym sprzęcie bootowanym z live memstick. Pętla (szczegóły w [`docs/LIVE-TEST.md`](docs/LIVE-TEST.md)):

1. **Boot** targetu z live media i bootstrap jak wyżej (`git clone … && bash install.sh`).
2. **Fix na `main`** (na maszynie dev), push.
3. Na targecie **`git pull`** w sklonowanym repo i **re-run** — bez przenagrywania pendrive'a.
4. Przy przerwanej instalacji (panic, zerwane SSH, zasilanie) **`bash install.sh --resume`** skanuje checkpointy i wznawia od ostatniej ukończonej fazy.

Pomoce przy teście:

- **Log:** wszystko dopisywane do **`/tmp/freebsd-installer.log`**. Z drugiej konsoli: `tail -f /tmp/freebsd-installer.log`.
- **Wiele TTY:** vt(4) daje `Alt+F1`…`Alt+F8`. Instalator na jednym, debug na drugim (`top`, `tail -f`, ręczny `pkg`).
- **SSH:** ustaw hasło roota (`passwd`), `service sshd onestart`, potem steruj instalacją zdalnie. Odpalaj w `tmux`, żeby zerwana sesja SSH nie ubiła instalacji.
- **Menu recovery:** każda komenda owinięta w `try()`, która padnie, otwiera menu **Retry / Shell / Continue / Log / Abort** — zejdź do shella, napraw ręcznie, ponów dokładnie tę komendę.

## Boot environments ZFS (rollback jako feature)

Na profilu **ZFS** system dostaje boot environments `bectl`, a instalator eksponuje to na wierzchu. Boot environment to natychmiastowy (<1 s) snapshot+clone datasetu root, który możesz bootować niezależnie z menu loadera:

```sh
bectl create pre-upgrade-$(date +%F)      # natychmiastowy snapshot+clone
bectl activate -t pre-upgrade-2026-06-15  # zbootuj STARY BE raz (tymczasowo)
bectl activate pre-upgrade-2026-06-15     # ustaw jako trwały domyślny
```

`freebsd-update` i `pkg` automatycznie tworzą BE przed zmianą systemu, więc zły upgrade to **reboot-i-wybierz-poprzedni-BE** — bez przywracania z backupu. To najmocniejszy argument za ZFS zamiast UFS. **UFS nie ma `bectl`** — wybór profilu UFS wymienia boot environments na niższy narzut.

## Znane ograniczenia / jeszcze niewspierane

- **Dual-boot.** v0.1 robi **tylko whole-disk auto layout**. Auto-ZFS bezwarunkowo `gpart destroy -F` na każdym dysku docelowym i kasuje Windows/ESP bez drugiego pytania przy `nonInteractive=YES`. Dual-boot side-by-side (ręczne `PARTITIONS`/scriptedpart, reuse ESP) jest naszkicowany w zmiennych configu, ale **niepodłączony** — nie celuj tym w dysk, który chcesz zachować.
- **Resume z disk-scanem przez reboot.** `bsdinstall` jest bezstanowy, brak natywnego resume. Nasz wrapper wznawia w sesji przez checkpointy; pełny **skan dysku przez reboot** (odkrycie na wpół zainstalowanego poola, export, re-wipe) jest częściowy — `--resume` jest pewny dla przerwanego przebiegu, który nie stracił `/tmp`.
- **Secure Boot.** Nieobsługiwany. Historia Secure Boot FreeBSD różni się od linuksowego MOK/shim; na razie wyłącz Secure Boot w firmware.
- **GELI full-disk root** jest jako opcja, ale oznaczony eksperymentalnie na kapryśnym UEFI (GPD/Surface) — utracone hasło jest nieodwracalne; pod `nonInteractive=YES` zfsboot i tak zapyta o passphrase na konsoli.

## Uruchamianie testów

Testy są samodzielne — bez roota, bez prawdziwego sprzętu. Lecą pod `DRY_RUN=1` i eksportują guard instalatora, żeby moduły `lib/*.sh` dały się source'ować.

```sh
bash tests/test_config.sh        # round-trip zapisu/odczytu configu
bash tests/test_hardware.sh      # detekcja sprzętu / mapowanie GPU + firmware
bash tests/test_checkpoint.sh    # checkpoint set/reached/validate/migrate
bash tests/test_validate.sh      # validate_config() — bramka bezpieczeństwa pre-install
bash tests/test_bsdinstall.sh    # generacja pliku bsdinstall (preamble + setup script)
bash tests/shellcheck.sh         # analiza statyczna / lint (potrzebny shellcheck)
```

`tests/shellcheck.sh` lintuje każdy plik `.sh` i jest najszybszym sposobem na złapanie pułapek `set -Eeuo pipefail`, na które ten kod uważa (np. `(( x++ ))` zwracające 1 przy zerze, `grep` w `$()` wywalający pipeline).

## Układ projektu

```
install.sh        — entry point: parsowanie argów, orkiestracja wizarda, dispatch faz
configure.sh      — wrapper: exec install.sh --configure

lib/              — moduły biblioteczne (SOURCE'owane, nigdy uruchamiane)
  constants.sh    — CONFIG_VARS[], CHECKPOINTS[], ścieżki, stałe ZFS/AMD-firmware/disk-probe
  protection.sh   — guard: odmawia uruchomienia, jeśli nie source'owany przez instalator
  logging.sh      — einfo/ewarn/eerror/elog + logowanie do /tmp/freebsd-installer.log
  utils.sh        — try() recovery, checkpointy, is_efi/has_network, generate_password_hash
  dialog.sh       — prymitywy gum/dialog + run_wizard
  config.sh       — config_save/load + validate_config()
  hardware.sh     — detekcja CPU/GPU/dysk/WiFi/Surface/GPD przez pciconf/sysctl/kenv
  bsdinstall.sh   — generacja + uruchomienie pliku scripted-install bsdinstall
  chroot.sh       — chroot_exec/chroot_sh/chroot_pkg/chroot_teardown (świadome DRY_RUN)
  gpu.sh          — drm-kmod + flavory firmware + kld_list
  desktop.sh      — DE / display manager / seatd+dbus / grupy
  system.sh       — locale (login.conf + cap_mkdb), users, finalize, baseline bectl
  umpc.sh         — quirki GPD Pocket 4 / Surface
  hooks.sh        — haki faz before_*/after_*
  preset.sh       — export/import reużywalnego configu (nakładka sprzętowa)

tui/              — ekrany TUI (każdy to screen_*() zwracający TUI_NEXT/BACK/ABORT)
data/             — bundlowana binarka gum, motyw dialog
presets/          — przykładowe konfiguracje
hooks/            — *.sh.example
tests/            — samodzielne testy
docs/DESIGN.md    — spec implementacyjny (szablony bsdinstall, matryca sprzętowa, caveaty)
docs/LIVE-TEST.md — runbook testu na żywym sprzęcie
docs/HANDOFF.md   — status / co podłączone vs TODO
```
</content>
