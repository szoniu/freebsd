# LIVE-TEST.md — runbook testu na żywym sprzęcie

> Field guide do pierwszego uruchomienia instalatora na realnym sprzęcie (PC first-class,
> GPD Pocket 4 / Surface best-effort). Czytaj z [DESIGN.md](DESIGN.md) (§5 device caveats,
> §8 bootstrap, §9 open risks) i [HANDOFF.md](HANDOFF.md) (stan). Pętla pracy:
> **boot live → `git pull` na targecie → re-run → fix na `main` → pull → ponów.**

## 0. Czego potrzebujesz fizycznie (PER URZĄDZENIE)

| Urządzenie | Sieć do bootstrapu | Klawiatura | Uwaga |
|---|---|---|---|
| **Zwykły PC** (first-class) | wired Ethernet zwykle działa | wbudowana/USB | ścieżka referencyjna |
| **GPD Pocket 4** | **KABEL / USB-Ethernet** (`ure`/`cdce`) — WiFi MT7922 NIE działa (BLOCKER) | USB | ekran live + loader **bokiem** (brak rotacji konsoli) — to normalne |
| **Surface** Laptop/Book/Studio | wg chipu (AX200/AX201 częściowo; QCA6174 = USB dongle) | **zewn. USB kbd+mysz** — wbudowana przez SAM = martwa | Snapdragon (ARM64) = instalator ODMÓWI (amd64-only) |

Nośnik: **FreeBSD 14.x RELEASE memstick** (pierwszy wybór, najdojrzalsze sterowniki). 15.0 jako „newest base".

## 1. Bootstrap live media → instalator (jako root w Live Shell)

Sieć wired (dobierz interfejs z `ifconfig -l`):
```
dhclient em0
```
Writable `/usr/local` + `/tmp` (media RO) — zachowaj resolv.conf PRZED remountem `/tmp` (inaczej go wymaże):
```
mount -t tmpfs -o size=1g tmpfs /usr/local
mkdir -p /tmp.bak && cp -a /tmp/. /tmp.bak/ && mount -t tmpfs -o size=512m tmpfs /tmp && cp -a /tmp.bak/. /tmp/
[ -s /etc/resolv.conf ] || echo 'nameserver 1.1.1.1' > /etc/resolv.conf
```
pkg + warstwa shell (TMPDIR na writable tmpfs) + locale dla gum na vt(4):
```
export TMPDIR=/usr/local TERM=xterm-256color LANG=en_US.UTF-8 LC_CTYPE=en_US.UTF-8
pkg bootstrap -fy && pkg update -f && pkg install -y bash gum git
```
Klon + run:
```
git clone https://github.com/szoniu/freebsd.git /tmp/installer && exec /usr/local/bin/bash /tmp/installer/install.sh
```
**Fallback gum** (pkg-repo zablokowany, GitHub OK): bundlowany `data/gum.tar.gz` (`gum_0.17.0_Freebsd_x86_64`).

## 2. Pętla fix-on-the-fly

Na targecie po `git clone`/`git pull` zawsze świeży kod:
```
cd /tmp/installer && git pull && exec /usr/local/bin/bash install.sh --resume
```
- `--resume` wznawia od ostatniego checkpointu (w sesji: /tmp; cross-reboot: config na targecie w `/var/db/freebsd-installer/`).
- Log do wysłania mi: `/tmp/freebsd-installer.log`. Generowany skrypt bsdinstall: `/tmp/freebsd-installer-install.cfg` (0600, **zawiera hashe — NIE wklejaj publicznie**).
- Suchy przebieg bez niszczenia dysku: `./install.sh --configure --dry-run` (sam wizard + podgląd generowanego skryptu).

## 3. WATCH LIST — co najpewniej zgrzytnie na realnym HW

Rzeczy **zweryfikowane tylko strukturalnie / na Linuksie** — pierwszy realny test je potwierdzi. Jak coś padnie, podaj objaw + log.

### Krytyczne ścieżki (mogą wywalić instalację)
- **Parser `pciconf -lv` (dwa formaty)** — GPU/WiFi wykrywanie. Na realnym 14.x sprawdź `pciconf -lv | grep -A1 vgapci` — czy format to `vendor=0x.. device=0x..` czy `chip=0xDDDDVVVV`. Parser obsługuje oba, ale to testuj NAJPIERW (`./install.sh --configure` → ekran „Hardware" pokaże wykryty GPU/WiFi).
- **`ZFSBOOT_*` de-facto knoby** — różnią się między 14.2/14.3/15.0. Jeśli `bsdinstall script` padnie na preamble, zdiffuj nasz preamble z `usr.sbin/bsdinstall/scripts/zfsboot` docelowego brancha.
- **Intel iGPU firmware = meta `gpu-firmware-kmod`** (fix: stary `gpu-firmware-intel-kmod` nie istniał). Ciągnie firmware WSZYSTKICH GPU (~dziesiątki MB) — zweryfikuj że `pkg install drm-kmod gpu-firmware-kmod` się rozwiązuje. UWAGA: na Alder Lake bywał boot-freeze przy obecnym firmware (drm-kmod #252) — gdyby zawisł boot, zrzuć `i915kms` z `kld_list` i `kldload` ręcznie.
- **AMD Radeon 780M (GPD)** — sześć flavorów `gpu-firmware-amd-kmod-*` MUSI pasować; zły/brakujący = **kernel panic** przy ładowaniu amdgpu. Na niektórych 14.3 `amdgpu` w `kld_list` zamrażał boot → notatka POST-INSTALL opisuje fallback `kldload amdgpu` (patrz `/root/POST-INSTALL-NOTES.txt`).

### UEFI / dysk
- **`efibootmgr` (FreeBSD ≠ Linux)** — re-pin wpisu w fazie finalize, teraz ESP montowany też na ZFS. Po instalacji sprawdź `efibootmgr -v` czy jest wpis „FreeBSD". (Best-effort: bsdinstall zwykle już go tworzy.)
- **UFS + BIOS** (jeśli testujesz tę kombinację) — generuje teraz `512k freebsd-boot` zamiast efi-only. Na czystym BIOS sprawdź że bootuje. UEFI/auto dalej dają `efi`.
- **GELI full-disk root** (opt-in) — pod `nonInteractive=YES` zfsboot **i tak zapyta o passphrase na konsoli** (to nie zawias). Przetestuj boot-unlock na TYM sprzęcie zanim zaufasz; utracone hasło = nieodwracalne. GPD/Surface mają „quirky UEFI".
- **`vfs.zfs.arc_max` w BAJTACH** (nie „4G") — na ≤16 GiB RAM cap = `physmem/3`. Sprawdź `sysctl vfs.zfs.arc_max` po boocie.

### Konto / lokalizacja (fix injection)
- **`%q` na FULLNAME/TIMEZONE/KEYMAP/groups** — wpisz w wizardzie normalne imię ze spacją (np. „Jan Kowalski") i sprawdź że user się tworzy (`pw usershow`), oraz że dziwny GECOS nie psuje setup-scriptu.
- **Locale przez login.conf + `cap_mkdb`** — po boocie `locale` i `echo $LANG` jako user.

### SMBIOS / profil urządzenia
- **`kenv -q smbios.*`** — na whiteboxie bywa puste („To Be Filled By O.E.M."). Na GPD/Surface sprawdź że profil wykryty (ekran Hardware: `DEVICE_PROFILE`). Snapdragon Surface → instalator ma ODMÓWIĆ (`is_supported_arch`, amd64-only) PRZED czymkolwiek destrukcyjnym.

## 4. Znane NIE-DZIAŁA (nie zgłaszaj jako bug — udokumentowane)

- GPD Pocket 4 / wiele Surface: **WiFi** (MT7922 / QCA6174). Bootstrap kablem.
- **Rotacja konsoli/loadera** — brak (`kern.vt.rotate` nie istnieje). Rotacja tylko desktop-layer (po loginie). GPD: ekran live bokiem = oczekiwane.
- Surface: **touch/pen** (IPTS/iptsd Linux-only), Bluetooth, kamery, **S3/S0ix suspend**.
- GPD: **fan control** (brak gpd-fan analogu), **auto-rotate** (brak IIO/MXC6655). Audio ALC287: szablon `device.hints` + instrukcja pindump w `/root/POST-INSTALL-NOTES.txt`.

## 5. Co wysłać, gdy coś padnie

1. Objaw (na którym ekranie/fazie, co się stało).
2. `/tmp/freebsd-installer.log` (ostatnie ~50 linii: menu `try()` ma opcję „View log").
3. Przy błędzie generacji/bsdinstall: `cat /tmp/freebsd-installer-install.cfg` (**zredaguj linie z `$6$`/ROOTPASS_ENC**).
4. Sprzęt: `pciconf -lv | grep -A2 -E 'class=0x03|class=0x0280'`, `kenv -q smbios.system.product`, `sysctl machdep.bootmethod hw.physmem`.
