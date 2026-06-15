# DESIGN.md — Brief implementacyjny instalatora FreeBSD

> Wygenerowany z 10-agentowego workflow badawczego (`freebsd-installer-research`, 2026-06-15).
> Spec dla implementera + źródło sekcji „device caveats" do README. Target: **FreeBSD 14.x
> RELEASE** jako pierwszy wybór (max dojrzałość sterowników), **15.0-RELEASE** (2025-12-02,
> używa `bsddialog`) jako opcja „newest base". Shell layer: `bash` + `gum` bootstrapowane przez
> `pkg` na live media. Bazowa instalacja: `bsdinstall script` w trybie scripted; nasz TUI
> generuje skrypt i robi post-install.

## Globalne decyzje przekrojowe

- **Dysk**: probuj `nda0` PIERWSZY (FreeBSD 14+), `nvd0` to tylko alias. Kolejność:
  `nda0 nvd0 ada0 da0 vtbd0`, ale ZAWSZE wyklucz boot medium (stick bywa `da0`).
- **DRM/amdgpu**: ładuj przez `kld_list` w `rc.conf` (`sysrc kld_list+=amdgpu`), NIGDY w
  `loader.conf` (panic early-boot, drm-kmod #100).
- **Resume/idempotencja**: `bsdinstall` NIE ma natywnego resume — cała re-entrancy żyje w
  naszym wrapperze (`zpool export` + unmount + re-wipe przed ponownym uruchomieniem).
- **Swap**: dedykowana partycja `freebsd-swap` (NIGDY swapfile-on-ZFS, NIGDY zvol jako default).
  Brak zram-analogu — nie obiecuj go w TUI.
- **Hash hasła**: `openssl passwd -6` (SHA-512 `$6$`). NIE yescrypt `$y$` (Linux-glibc,
  nieobsługiwany przez `pw -H 0`).

---

## 1. Szablony `bsdinstall script` + szkielet post-install

`bsdinstall script FILE` = PREAMBLE (przypisania zmiennych sh, uruchamiane na starcie) +
SETUP SCRIPT (po `#!/bin/sh`, uruchamiany OSTATNI, chrootowany w `/mnt`). Ten sam plik w
`/etc/installerconfig` auto-startuje przy boocie live media.

### 1a. ZFS-auto (root-on-ZFS, single-disk stripe, UEFI)

```sh
# ============ PREAMBLE (zmienne sh, brak shebang) ============
DISTRIBUTIONS="kernel.txz base.txz"          # standard 14.x media; NIE COMPONENTS=pkgbase
export nonInteractive=YES                     # de-facto knob (medium-conf)
export ZFSBOOT_CONFIRM_LAYOUT=0               # bez interaktywnego potwierdzenia
export ZFSBOOT_DISKS=nda0                     # REQUIRED; brak = błąd
export ZFSBOOT_VDEV_TYPE=stripe               # stripe|mirror|raid10|raidz1..3
export ZFSBOOT_POOL_NAME=zroot
export ZFSBOOT_BOOT_TYPE=UEFI                 # UEFI|BIOS|BIOS+UEFI; OMIT=auto (machdep.bootmethod)
export ZFSBOOT_SWAP_SIZE=4g                   # 0=brak swap; PC=4g, Pocket4=8g
export ZFSBOOT_SWAP_ENCRYPTION=1              # geli one-time key -> swapN.eli
export ZFSBOOT_FORCE_4K_SECTORS=1
export ZFSBOOT_POOL_CREATE_OPTIONS="-O compression=lz4 -O atime=off"  # USTAW JAWNIE (default różni się wersją!)
# export ZFSBOOT_GELI_ENCRYPTION=1           # full-disk geli root (opcja; test na quirky UEFI!)
# export ZFSBOOT_GELI_KEY_FILE=/boot/encryption.key
export ROOTPASS_ENC="$6$..."                  # crypt SHA-512; ROOTPASS_ENC WYGRYWA z ROOTPASS_PLAIN
# BSDINSTALL_DISTDIR domyślnie /usr/freebsd-dist (memstick ma .txz + MANIFEST → bez sieci)

#!/bin/sh
# ============ SETUP SCRIPT (chroot /mnt, uruchamiany OSTATNI) ============
# Tu cały minimalny post-install (sysrc, users, tz). Patrz 1c.
```

**Default reference `ZFSBOOT_*`** (vs in-tree zfsboot): `POOL_NAME=zroot`, `VDEV_TYPE=stripe`,
`BEROOT_NAME=ROOT`, `BOOTFS_NAME=default` → `zroot/ROOT/default` mount `/`;
`POOL_CREATE_OPTIONS=-O compression=on -O atime=off` (`compression=on`==lz4);
`FORCE_4K_SECTORS=1`; `SWAP_SIZE=2g`; `GELI_ENCRYPTION` empty=off;
`GELI_KEY_FILE=/boot/encryption.key`; `BOOT_POOL` empty=off; `CONFIRM_LAYOUT=1`;
`PARTITION_SCHEME` empty=GPT. ESP=stały 260M (brak knoba na resize). Datasety:
`zroot/{home,tmp,usr(+ports,src),var(+audit,crash,log,mail,tmp)}`.

### 1b. UFS-auto (GPT + EFI + swap + single UFS root) — niski overhead

```sh
# ============ PREAMBLE ============
DISTRIBUTIONS="kernel.txz base.txz"
PARTITIONS="nda0 GPT { 260M efi, 4G freebsd-swap, auto freebsd-ufs / }"
# size: K/M/G lub 'auto' (=reszta). type: efi|freebsd-boot|freebsd-swap|freebsd-ufs
# BIOS: zamień '260M efi' na '512k freebsd-boot'. PARTITIONS=DEFAULT = interaktywny Auto-UFS.

#!/bin/sh
# ============ SETUP SCRIPT (chroot /mnt) ============
# UFS nie ma bectl/snapshotów — surface bectl TYLKO dla profilu ZFS.
```

UFS na SSD: `newfs -U -j -t /dev/gpt/rootfs` (-U soft updates, -j SU-journaling, -t TRIM);
fstab `rw,trim`.

### 1c. Szkielet post-install (SETUP SCRIPT, chroot `/mnt`)

```sh
#!/bin/sh
set -e
[ -s /etc/resolv.conf ] || echo 'nameserver 1.1.1.1' > /etc/resolv.conf   # pkg w chroot
sysrc hostname="${HOSTNAME}"
sysrc zfs_enable=YES                    # TYLKO root-on-ZFS
sysrc ifconfig_DEFAULT=DHCP             # wildcard: dowolny pojedynczy NIC
sysrc sshd_enable=YES
sysrc sendmail_enable=NONE
tzsetup "${TIMEZONE}"                   # np. Europe/Warsaw → /etc/localtime + /var/db/zoneinfo
sysrc keymap="${KEYMAP}"               # np. pl.kbd (/usr/share/vt/keymaps)
pw useradd -n "${USER}" -c "${FULLNAME}" -d "/home/${USER}" -m -s /usr/local/bin/bash -G wheel,operator,video
printf '%s' "${USER_HASH}" | pw usermod -n "${USER}" -H 0   # -H = hash; -h = plaintext
ASSUME_ALWAYS_YES=yes pkg bootstrap -f
pkg update -f
pkg install -y bash gum git doas
[ -n "${GPU_KMOD}" ] && sysrc kld_list+="${GPU_KMOD}"   # amdgpu | i915kms | nvidia-modeset
sysrc -f /boot/loader.conf zfs_load=YES
[ -n "${ARC_MAX}" ] && sysrc -f /boot/loader.conf vfs.zfs.arc_max="${ARC_MAX}"  # BYTES!
```

**Caveaty:** DESTRUKCYJNE — auto-ZFS bezwarunkowo `gpart destroy -F` na każdym dysku z
`ZFSBOOT_DISKS`, kasuje Windows/ESP bez drugiego potwierdzenia gdy `nonInteractive=YES`. Brak
dual-boot w auto-ZFS (wymaga ręcznego `PARTITIONS`/scriptedpart). `nonInteractive`/
`ZFSBOOT_BOOT_TYPE`/`ZFSBOOT_PARTITION_SCHEME` to de-facto knoby — diff vs
`usr.sbin/bsdinstall/scripts/zfsboot` dla docelowego brancha (14.2/14.3/15.0).

---

## 2. Hardware detection cheat-sheet

| Linux probe | FreeBSD komenda | Parse / uwaga |
|---|---|---|
| `/proc/cpuinfo` model | `sysctl -n hw.model` | vendor przez substring `*AMD*`/`*Intel*`/`*VIA*` |
| nproc | `sysctl -n hw.ncpu` | int |
| total RAM | `sysctl -n hw.physmem` | **BYTES**; NIE `hw.realmem` (PCI-hole), NIE `hw.usermem` |
| `lspci -nn` | `pciconf -lv` | GPU: `vgapciN@pci0:B:D:F:`, `class=0x03..`. **DWA formaty**: `vendor=0x.. device=0x..` (nowe) LUB `chip=0xDDDDVVVV` (legacy: device=HIGH16, vendor=LOW16). Parser MUSI obsłużyć oba |
| GPU vendor IDs | (z `pciconf`) | `0x10de`=NVIDIA, `0x1002`=AMD/ATI, `0x8086`=Intel |
| hybrid GPU | count `class=0x0300`/`0x0302` | bus 0 (`pci0:0:`)=iGPU, wyższy bus=dGPU |
| WiFi PCI | `pciconf -lv \| awk '/class=0x0280/'` | WiFi=`0x028000`, wired=`0x020000` |
| `lsusb` | `usbconfig list` + `usbconfig -d ugenX.Y dump_device_desc` | `idVendor`/`idProduct`; BT class `bDeviceClass=0x00e0` |
| `lsblk` (dyski) | `sysctl -n kern.disks` | **REVERSE order**, zawiera md/cd/stick — filtruj. Detal: `geom disk list <d>` (`Mediasize:` bytes, `descr:`, `ident:`, `rotationrate:` 0=SSD) |
| `lsblk` (partycje) | `gpart show -p` | `-p`=provider (ada0p1), `-l`=labels, `-r`=GUID. ESP: type `efi` |
| Windows detect | mount ESP msdosfs RO | `/EFI/Microsoft/Boot/bootmgfw.efi` + typ `ms-basic-data` |
| `/sys/class/dmi/id/sys_vendor` | `kenv -q smbios.system.maker` | `-q` = cicho przy braku (ważne pod `set -e`) |
| product_name | `kenv -q smbios.system.product` | |
| board_vendor / board_name | `kenv -q smbios.planar.maker` / `smbios.planar.product` | |
| `/sys/firmware/efi` | `sysctl -n machdep.bootmethod` | zwraca dokładnie `UEFI` lub `BIOS` |

**Klucze kenv dla Surface/GPD:** `Surface` ⇔ maker=`Microsoft Corporation` && product=`Surface*`.
`GPD Pocket 4` ⇔ maker=`GPD` && `${product}${board}` ~ `*Pocket*4*`|`*G1628-04*`.
Brak `/sys/class/drm` w early installerze → fallback panel-geometry (jak Chuwi w Linuksie) nie zadziała.

---

## 3. Graphics matrix

`drm-kmod` = metaport auto-dobierający DRM: **14.x → drm-61-kmod (6.1)**, **15.0 → drm-66-kmod
(6.6)**. Nie w base — kmod MUSI pasować do running kernel.

| Vendor | pkg | kld | Kroki |
|---|---|---|---|
| **AMD (780M/gfx1103 Phoenix)** | `drm-kmod` + 6 flavorów `gpu-firmware-amd-kmod`: `dcn-3-1-4`, `gc-11-0-1`, `gc-11-0-4`, `psp-13-0-4`, `sdma-6-0-1`, `vcn-4-0-2` | `amdgpu` | `pkg install drm-kmod gpu-firmware-amd-kmod-{...}` → `sysrc kld_list+=amdgpu` → `pw groupmod video -m USER`. **Brakujący/zły flavor = KERNEL PANIC** |
| Intel iGPU | `drm-kmod` | `i915kms` | `sysrc kld_list+=i915kms`. Discrete Arc **panikuje** |
| NVIDIA | `nvidia-driver` | `nvidia-modeset` | `+ loader.conf hw.nvidiadrm.modeset=1`. **Brak Wayland** |

**Werdykt Radeon 780M (gfx1103 Phoenix, RDNA3): DZIAŁA — confidence MEDIUM.** Ten sam iGPU co
7940HS, potwierdzony na forum FreeBSD 92161. 2D/GL/desktop KMS OK. RYZYKO: sustained Vulkan
compute hard-lockuje GPU (drm-kmod #387). Flavor-matching kruchy: rebuild `drm-XX-kmod` +
firmware po każdym minor upgrade. Na niektórych 14.3 `amdgpu` w `kld_list` zamrażał boot →
fallback `kldload amdgpu` post-boot.

**Wayland prereq (każdy vendor):** `pkg install wayland seatd dbus` → `sysrc seatd_enable=YES
dbus_enable=YES` → `pw groupmod _seatd -m USER`.

---

## 4. Desktop matrix

| DE | pkg | display-manager | rc.conf services[] | notes |
|---|---|---|---|---|
| KDE Plasma | `x11/kde` / `x11/plasma6-plasma` | `x11/sddm` | `dbus_enable sddm_enable` | **X11 `startplasma-x11` = stabilna ścieżka 2026**; Wayland działa ale dokumentuj X11 fallback; broken w VirtualBox |
| GNOME | `x11/gnome` / `gnome-lite` | GDM (bundled) | `dbus_enable gdm_enable` | + fstab `proc /proc procfs rw 0 0` |
| Xfce | `x11-wm/xfce4` | `lightdm`+`lightdm-gtk-greeter` | `dbus_enable lightdm_enable` | |
| MATE | `x11/mate` / `mate-base` | `lightdm` | `dbus_enable lightdm_enable` | + fstab proc |
| Cinnamon | `x11/cinnamon` | `lightdm` | `dbus_enable lightdm_enable` | **X11-only**; + fstab proc |
| LXQt | `x11-wm/lxqt` | `sddm` | `dbus_enable sddm_enable` | + fstab proc |

**Wayland compositors:**

| Compositor | pkg | rc.conf | status |
|---|---|---|---|
| **niri** (scrollable tiling) | `x11-wm/niri` | `seatd_enable dbus_enable` | **binary pkg na 14/15 amd64, reliable** |
| sway | `x11-wm/sway` | `seatd_enable` | reliable |
| **Hyprland** | `x11-wm/hyprland` | `seatd_enable dbus_enable` | **binary pkg niespójny — może wymagać ports build** |
| **Mango** (dwl-based dynamic tiling) | `x11-wm/mango` | `seatd_enable dbus_enable` | **binary pkg w Latest, reliable na 14.3/15** (dwm-style tagi, scenefx blur/shadow) — w menu instalatora |
| labwc / wayfire / river / hikari | `x11-wm/*` | `seatd_enable` | w ports |

**COSMIC (System76) — NIE w menu (TODO).** W portach jest dziś TYLKO `x11-wm/cosmic-comp`
(sam kompozytor, Wayland-only, opiekun jbeich); brak pakietów `cosmic-session` / `cosmic-panel` /
`cosmic-settings` / `cosmic-greeter`, więc pkg nie daje używalnej sesji (forum FreeBSD, stan
2026-01: porting nieukończony, build-fallouty). Świadomie pominięty, by nie dawać pułapki na
instalatorze wymazującym dysk. **Dodanie = jednolinijkowy wpis** (jak Mango: `DESKTOP_TYPE=cosmic`,
ścieżka Wayland tty+seatd, `_de_packages` → komponenty cosmic-*) **gdy `cosmic-session` + reszta
sesji trafią do binarnego pkg dla FreeBSD:14/15:amd64.**

**Prereq dowolny graficzny:** `pkg install xorg drm-kmod` → `sysrc dbus_enable=YES
moused_enable=YES` → `pw groupmod video -m USER`. **PipeWire to USER service** (brak
`pipewire_enable`; XDG autostart) — `pkg install pipewire wireplumber pipewire-spa-oss`. Brak
systemd-logind; `elogind` i `seatd` konfliktują → wybierz **seatd**.

---

## 5. Device caveats (źródło sekcji README)

### GPD Pocket 4 (8840U / 780M)

**WiFi/BT — WERDYKT NAJPIERW: NIE DZIAŁA (severity: BLOCKER).** Chip = AMD RZ616 = MediaTek
MT7922 (Filogic 330P), PCI `14c3:0616` (NIE Intel AX210). Sterownik `mt76` jest in-tree od 14.x
ale **DISCONNECTED FROM BUILD** (LinuxKPI VM changes, proj-laptop #66). Forum 97165 (Jan 2026):
**ZERO udanych asocjacji**. Firmware port `wifi-firmware-mt76-kmod-mt7921` istnieje ale to tylko
firmware. BT to osobny USB iface, też martwy. **Instalator MUSI bootstrapować przez wired/USB-
tether.** Workaround: USB-C Ethernet (`ure`/`cdce`), tether telefonu USB, albo USB WiFi
`rtwn`/`run`.

| Komponent | Status | Severity |
|---|---|---|
| WiFi/BT (MT7922) | **NIE DZIAŁA** — brak asocjacji | BLOCKER |
| 780M GPU | DZIAŁA (drm-61-kmod + amdgpu + 6 firmware flavorów); zły flavor = **panic** | medium |
| 780M Vulkan compute | hard-lock przy sustained compute (#387) | medium |
| Console/loader rotation | **NIE DZIAŁA** — `kern.vt.rotate` nie istnieje (D34221 unmerged); TUI bsdinstall **bokiem** na portrecie | high (UX) |
| GUI rotation | DZIAŁA post-login: Wayland `output eDP-1 transform 90/270`, Plasma Orientation=Portrait, Xorg `xrandr --rotate right` | — |
| Audio (ALC287) | szansa z `snd_hda`; pin values per-unit z `dev.hdaa.N.pindump=1` → `/boot/device.hints`; brak amixer Auto-Mute | medium |
| Accelerometer auto-rotate (MXC6655) | **NIE** — brak IIO/iio-sensor-proxy | low |
| Fan control | **NIE** — brak gpd-fan analogu (tylko `acpi_ibm`); EC autonomiczny | low |

ARC cap (12GB RAM): `vfs.zfs.arc_max="4294967296"` (4 GiB, BYTES) w `loader.conf`. Swap: 8g,
encrypted.

### Microsoft Surface (best-effort)

**WiFi WERDYKT (chip-dependent):** AX200/AX201 (Go 2/3, Pro 7/8) działają via `iwlwifi` **tylko
802.11 a/b/g**; QCA6174 (orig Go, wiele Pro 4-6) — `ath10k` disconnected, **brak WiFi → USB
dongle**.

| Komponent | Status | Severity |
|---|---|---|
| Klawiatura/touchpad (Laptop 1-6, Book 3, Laptop Studio) | **MARTWE** — routowane przez SAM (brak drivera). **Wymaga zewn. USB kbd+mouse NAWET podczas instalacji** | BLOCKER (te modele) |
| Type Cover (Pro/Go) | DZIAŁA — USB-HID via `ukbd`/`hkbd`/`hms`/`hmt` (nie SAM) | — |
| Touch/pen (Pro 4+, Book, Laptop, Studio) | **NIE** — IPTS wymaga Linux-only `iptsd` | medium |
| Touch (Go/Go2/Go3) | może via `iichid`/`ig4`/`hmt`; **low-conf** | low-conf |
| GPU | Intel `i915kms` / AMD `amdgpu` — działa | — |
| Bluetooth, kamery, sensory, **S3 suspend** (S0ix) | **NIE** | medium |
| ARM64 Snapdragon (Pro 11th / Laptop 7th) | **out of scope** — wykryj i ODMÓW | — |

rc.conf Surface: `sysrc kld_list+="ig4 iichid"` (HID-over-I2C); AX200/AX201:
`sysrc kld_list+=if_iwlwifi wlans_iwlwifi0=wlan0`; `loader.conf hw.usb.usbhid.enable=1`.

---

## 6. System config snippets

**Users (safe hash set — hash przez fd, nie argv):**
```sh
# USER_HASH=$(openssl passwd -6)   # SHA-512 $6$; NIE $y$ yescrypt
pw useradd -n "$USERNAME" -c "$FULLNAME" -d "/home/$USERNAME" -m -s /usr/local/bin/bash -G wheel,operator,video
printf '%s' "$USER_HASH" | pw usermod -n "$USERNAME" -H 0     # -H = pre-hashed; -h = plaintext
printf '%s' "$ROOT_HASH" | pw usermod -n root -H 0
pw groupmod _seatd -m "$USERNAME"     # Wayland seat (CZĘSTO POMIJANE — compositor failuje bez tego)
```

**rc.conf fragment (desktop + laptop):**
```sh
sysrc dbus_enable="YES" seatd_enable="YES" moused_enable="YES"
sysrc ntpd_enable="YES" ntpd_sync_on_start="YES"
sysrc powerd_enable="YES" powerd_flags="-a hadp -b adp"
sysrc kld_list+="amdgpu"            # += NIE druga przypisanie (nadpisze!)
sysrc zfs_enable="YES"
sysrc sendmail_enable="NONE"
```

**Locale via login.conf (NIE `/etc/locale.conf`):**
```sh
cat >> /etc/login.conf <<'EOF'

english|English UTF-8 users:\
	:charset=UTF-8:\
	:lang=en_US.UTF-8:\
	:tc=default:
EOF
cap_mkdb /etc/login.conf            # WYMAGANE — system czyta .db, nie tekst
pw usermod "$USERNAME" -L english
```

**Swap (dedykowana partycja, NO zram) — fstab:**
```
/dev/gpt/efiboot0   /boot/efi   msdosfs rw          2   2
/dev/gpt/swap0.eli  none        swap    sw          0   0
```
`.eli` = geli auto-attach świeżym losowym one-time key (niekompatybilne z hibernacją). NIGDY
swapfile-on-ZFS. ARC cap (12GB): **`vfs.zfs.arc_max="4294967296"` w BYTES** — forma "4G" bywa
odrzucana; generuj wartość bajtową (`ram_bytes/3`).

**bectl boot environments (ZFS-only, surface prominently w TUI):**
```sh
bectl create pre-upgrade-DATE       # instant snapshot+clone (<1s)
bectl activate -t pre-upgrade-DATE  # boot STARY BE jednorazowo
bectl activate pre-upgrade-DATE     # permanentny default
```
`freebsd-update`/`pkg` auto-tworzą BE → rollback przez wybór BE w loader menu. **UFS: bectl
niedostępny.**

---

## 7. CONFIG_VARS & CHECKPOINTS (od void reference)

**DROP z void:** `GRUB_*`, `secureboot-shim`, `xbps`, `zram`, GRUB-themed.
**ADD:** ZFS/UFS profil, bectl, GELI, FreeBSD swap-partition, drm-kmod flavor, kenv detection.
Pełne tablice — patrz `lib/constants.sh`. Resume (krytyczne — bsdinstall stateless): faza
`bsdinstall` musi `zpool export zroot` + odmontować `/mnt` + re-wipe PRZED ponownym
`bsdinstall script`. NIE re-uruchamiaj ślepo nad częściową instalacją.

---

## 8. Bootstrap sequence (live media → nasz installer)

Live ISO/memstick: root READ-ONLY, tylko `/bin/sh` (ash, NIE bash), pkg NIE zbootstrapowany,
`/usr/local` pusty/RO.

```sh
# Jako root w Live System / Shell.
# 0) sieć wired (WiFi Pocket4/Surface może nie mieć drivera → użyj kabla/USB-Ethernet):
ifconfig -l
dhclient em0                                    # igb0/re0/ure0 wg sprzętu
# 1) writable /usr/local i /tmp (media RO), zachowaj resolv.conf:
mount -t tmpfs -o size=1g tmpfs /usr/local
mkdir -p /tmp.bak && cp -a /tmp/. /tmp.bak/
mount -t tmpfs -o size=512m tmpfs /tmp
cp -a /tmp.bak/. /tmp/
# 2) DNS:
[ -s /etc/resolv.conf ] || echo 'nameserver 1.1.1.1' > /etc/resolv.conf
# 3) pkg bootstrap + warstwa shell (TMPDIR na writable tmpfs):
export TMPDIR=/usr/local
pkg bootstrap -fy && pkg update -f && pkg install -y bash gum git
# 4) console dla gum na vt(4):
export TERM=xterm-256color LANG=en_US.UTF-8 LC_CTYPE=en_US.UTF-8
# 5) clone + run:
git clone https://github.com/szoniu/freebsd.git /tmp/installer
exec /usr/local/bin/bash /tmp/installer/install.sh
```

**Fallback gum z tarballa** (pkg-repo blocked ale GitHub OK): asset
`gum_0.17.0_Freebsd_x86_64.tar.gz` (kapitalizowane 'Freebsd') — bundlowany w `data/gum.tar.gz`.
**Caveaty:** bash/gum w `/usr/local/bin` (NIE `/bin`) — shebang `#!/usr/bin/env bash`. Remount
`/tmp` jako tmpfs WYMAZUJE resolv.conf jeśli nie skopiujesz wcześniej. vt(4) renderuje 16
kolorów; gum degraduje gracefully ale wymaga UTF-8 locale.

---

## 9. Open risks / low-confidence (zweryfikować na realnym sprzęcie)

1. **[BLOCKER] Pocket 4 WiFi/BT (MT7922)** — niedziałający (forum 97165 = zero asocjacji).
   Założenie: wired bootstrap.
2. **[high] Radeon 780M firmware-flavor panic** — zły/brakujący flavor = panic; fallback
   `kldload` post-boot. Confidence MEDIUM.
3. **[high UX] Console/loader rotation Pocket 4** — `kern.vt.rotate` nie istnieje. TUI bokiem.
   Rotacja tylko desktop-layer.
4. **[Surface BLOCKER] SAM keyboard/touchpad** — martwe na Laptop 1-6/Book 3/Studio; wymaga
   zewn. USB kbd+mouse podczas instalacji.
5. **[medium] `pciconf -lv` dwuformatowość** (`vendor=`/`device=` vs `chip=`) — TESTUJ parser
   na realnym 14.x/15.0 live media.
6. **[medium] de-facto `ZFSBOOT_*` knoby** — diff vs `usr.sbin/bsdinstall/scripts/zfsboot` dla
   target brancha.
7. **[medium] `ZFSBOOT_POOL_CREATE_OPTIONS` default różni się wersją** — USTAW JAWNIE.
8. **[medium] `vfs.zfs.arc_max` format** — ZAWSZE emituj bajty (nie "4G").
9. **[medium] geli boot-unlock na quirky UEFI** (GPD/Surface) — test interaktywnie zanim
   włączysz `GELI_ROOT`. Utracone passphrase = nieodwracalne.
10. **[medium] efibootmgr ≠ Linux** — FreeBSD bierze `-l /path/to/loader.efi` (nie
    `--disk/--part`). NIE kopiuj inwokacji z Linuksa.
11. **[low] SMBIOS kenv puste na whitebox** ('To Be Filled By O.E.M.').
12. **[low] 15.0 specyfika** — re-weryfikuj single-stage `loader.efi`, efibootmgr flags, ESP
    260M, 2g swap default na live media.
