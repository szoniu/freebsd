# LIVE-USB-CHECKLIST.md — runbook per maszyna-kandydat (przed instalacją na dysk)

> Krótka checklista dla kandydatów na laptopowy daily driver (ranking i pełne werdykty:
> [DAILY-DRIVER-AUDIT.md](DAILY-DRIVER-AUDIT.md)). Bootstrap live media, pętla fix→pull→re-run
> i „co wysłać gdy padnie" są w [LIVE-TEST.md](LIVE-TEST.md) — ten plik ich NIE dubluje.

## Krok 0: diagnostyka read-only — `tests/live-hw-check.sh`

Skrypt jest **POSIX `/bin/sh`** — działa na gołym live memsticku **bez** bootstrapu pkg/bash
(w przeciwieństwie do samego instalatora). Nic nie zapisuje i nie ładuje modułów bez zgody.

Na live media jako root, z siecią (patrz [LIVE-TEST.md](LIVE-TEST.md) §1 — `dhclient em0`):

```sh
fetch -o /tmp/live-hw-check.sh https://raw.githubusercontent.com/szoniu/freebsd/main/tests/live-hw-check.sh
sh /tmp/live-hw-check.sh
```

Bez sieci: przepisz z drugiego kompa albo weź z klonu repo (`tests/live-hw-check.sh`),
jeśli już zbootstrapowałeś git wg [LIVE-TEST.md](LIVE-TEST.md) §1.

- `--probe-kmods` — dodatkowo `kldload ig4 iichid` i sprawdza, czy touchpad wisi na I2C-HID
  (pełny multitouch/gesty) czy na PS/2 (degradacja). To JEDYNA akcja modyfikująca (ładuje
  moduły), dlatego opt-in.
- Werdykt gestów (twardy warunek wyboru maszyny) wymaga libinput, czyli bootstrapu pkg
  ([LIVE-TEST.md](LIVE-TEST.md) §1): `pkg install -y libinput`, potem `libinput debug-events`
  i 3-palcowy swipe → szukaj `GESTURE_SWIPE_BEGIN`.
- Exit 1 = co najmniej jeden twardy FAIL (np. WiFi MediaTek, brak S3) — czytaj podsumowanie.

## HP ProBook 450 G8 („rhel") — kandydat #1

> **UWAGA: ta maszyna JUŻ przeszła field-test instalatora na 15.1** (commity `4ed4f65` —
> mount aktywnego BE przy ZFS, `d4710c7` — seatd_group=video, DISTSITE, nota KDE Wayland).
> Instalacja ZFS + KDE działała; poniżej zostaje weryfikacja warstwy laptop/Wayland dodanej
> po tym teście.

- [ ] `sh live-hw-check.sh --probe-kmods` — oczekiwane: Intel Iris Xe PASS, AX201 PASS
  (iwlwifi, a/b/g/n/ac od 14.3), S3 do potwierdzenia, SOF/DMIC WARN (mikrofon martwy).
- [ ] Gesty: libinput debug-events (patrz wyżej) — TGL zwykle I2C-HID, ale brak świadectwa.
- [ ] Po instalacji z nową fazą `laptop`: `sysrc -n powerd_enable`, `acpiconf -s 3` + resume
  (WiFi po resume: `service netif restart wlan0`), `backlight -q` jako user (grupa video).
- [ ] niri/mango z tty: czy sesja wstaje po loginie (pam_xdg → `echo $XDG_RUNTIME_DIR`);
  na 15.x pamiętaj o regresji niri #3013 (obejście `LIBSEAT_BACKEND=consolekit2`).
- Fallback sieci: **jedyny kandydat z RJ45** — przy kaprysach WiFi instaluj po kablu.

## ThinkPad X1 Nano Gen 1 — kandydat #3 (ryzykowny)

Przed czymkolwiek (szczegóły: [DAILY-DRIVER-AUDIT.md](DAILY-DRIVER-AUDIT.md) §„X1 Nano"):

- [ ] **BIOS ≥ 1.43** + `Config → Power → Sleep State = "Linux"` — bez tego **zero suspendu**
  (FreeBSD nie ma s0ix). Potem na live: `sysctl hw.acpi.supported_sleep_state` musi pokazać S3.
- [ ] `sh live-hw-check.sh --probe-kmods` — oczekiwane: Iris Xe PASS (na 15.1 przy GPU HANG
  → drm-66-kmod), AX201 PASS, SOF WARN (DMIC = nigdy), TB/USB4 INFO (**jedyne porty to
  2× USB-C TB4 — docki martwe**; ładowanie i DP alt-mode działają).
- [ ] **Głośniki** (unknown!): `cat /dev/sndstat`, test playback; cisza → pin-quirki
  device.hints (ALC287, wzór w `lib/umpc.sh` dla GPD).
- [ ] **Gesty** (unknown): probe-kmods + libinput debug-events — to jest twardy warunek.
- [ ] Kamera: tylko webcamd/cuse (natywny uvc ~Q2 2026); fingerprint: nie.
- [ ] Po pozytywnym teście: hw-probe → bsd-hardware.info (zamyka lukę dowodową modelu)
  + YAML do homelab inventory (brak wpisu!).
- Sieć do instalacji: brak RJ45 — przejściówka USB-C Ethernet (`ure`/`cdce`).

## HP Elite Dragonfly („aerynos") — kandydat #2

- [ ] `sh live-hw-check.sh --probe-kmods` — oczekiwane: UHD 620 PASS (Gen9.5 — najdojrzalszy
  i915), **AX200 PCIe** PASS (najlepiej przetestowana karta pod iwlwifi), S3 do potwierdzenia.
- [ ] Gesty: jak wyżej (unknown do weryfikacji).
- [ ] Convertible: dotyk/tablet-mode częściowo martwy (brak IIO) — zdecyduj, czy to boli.
- [ ] Audio + SOF WARN: test głośników/jacka na live.
- Sieć do instalacji: brak RJ45 — USB-Ethernet.

## Wspólne (każda maszyna, po czystym przejściu live-hw-check)

1. `kldload i915kms` na live — konsola musi przełączyć się bez paniki; dopiero potem instalacja.
2. WiFi: asocjacja + `iperf3` (oczekiwane ~100–200 Mbps na ac — to norma, nie bug).
3. Pełny przebieg instalatora wg [LIVE-TEST.md](LIVE-TEST.md) (§2 pętla, §3 watch-list).
4. Po instalacji: przeczytaj `/root/POST-INSTALL-NOTES.txt` (suspend/backlight/touchpad/WiFi
   — sekcje fazy `laptop`).
