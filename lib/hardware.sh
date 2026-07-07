#!/usr/bin/env bash
# hardware.sh — Hardware detection on FreeBSD: CPU, GPU, WiFi, disks, ESP,
# installed OSes, device profile (Surface / GPD Pocket 4 via SMBIOS).
#
# FreeBSD primitives replace the Linux ones:
#   /proc/cpuinfo        -> sysctl hw.model / hw.ncpu / hw.physmem (BYTES)
#   lspci -nn            -> pciconf -lv   (TWO id formats: vendor=/device= OR chip=0xDDDDVVVV)
#   lsblk                -> sysctl kern.disks + geom disk list + gpart show -p
#   /sys/class/dmi/id    -> kenv -q smbios.system.maker / .product / smbios.planar.product
#   /sys/firmware/efi    -> sysctl machdep.bootmethod  (UEFI|BIOS)
source "${LIB_DIR}/protection.sh"

# PCI vendor IDs (lowercase, 4 hex digits — same constants as the Linux family)
readonly PCI_VENDOR_NVIDIA="10de"
readonly PCI_VENDOR_AMD="1002"
readonly PCI_VENDOR_INTEL="8086"

# --- low-level pciconf parsing -------------------------------------------------

# _pci_emit_class — Emit "bus vendorid deviceid name" for every PCI device whose
# class matches the egrep pattern in $1 (e.g. '0x03' for display, '0x0280' WiFi).
# Handles BOTH pciconf schemas: modern "vendor=0x.. device=0x.." and legacy
# "chip=0xDDDDVVVV" (device = high 16 bits, vendor = low 16 bits).
_pci_emit_class() {
    local class_pat="$1"
    pciconf -lv 2>/dev/null | awk -v cpat="${class_pat}" '
        # selector line, e.g.  vgapci0@pci0:0:2:0:  class=0x030000 ...
        /^[a-zA-Z].*@pci[0-9]+:/ {
            # flush previous device if it matched and had no name line
            sel=$1; line=$0; want=(line ~ "class="cpat)
            vid=""; did=""
            if (match(line, /vendor=0x[0-9a-fA-F]+/))  vid=substr(line, RSTART+9, 4)
            if (match(line, /device=0x[0-9a-fA-F]+/))  did=substr(line, RSTART+9, 4)
            if (vid=="" && match(line, /chip=0x[0-9a-fA-F]{8}/)) {
                c=substr(line, RSTART+7, 8); did=substr(c,1,4); vid=substr(c,5,4)
            }
            n=split(sel, a, ":"); bus=a[2]
            cur=want; cbus=bus; cvid=tolower(vid); cdid=tolower(did); cname=""
            next
        }
        # indented description line:  device = "Phoenix1"
        cur==1 && /(vendor|device) *=/ {
            if ($0 ~ /device *=/) {
                name=$0; sub(/^[^=]*= *./,"",name); sub(/.$/,"",name)
                printf "%s %s %s %s\n", cbus, cvid, cdid, name
                cur=0
            }
        }
    '
}

# --- CPU ----------------------------------------------------------------------

detect_cpu() {
    CPU_MODEL=$(sysctl -n hw.model 2>/dev/null) || CPU_MODEL="unknown"
    CPU_CORES=$(sysctl -n hw.ncpu 2>/dev/null) || CPU_CORES=4
    case "${CPU_MODEL}" in
        *AMD*)   CPU_VENDOR="amd" ;;
        *Intel*) CPU_VENDOR="intel" ;;
        *VIA*)   CPU_VENDOR="via" ;;
        *)       CPU_VENDOR="unknown" ;;
    esac

    # Total RAM in MiB (hw.physmem is BYTES; never use hw.realmem — PCI-hole shadow)
    local ram_bytes
    ram_bytes=$(sysctl -n hw.physmem 2>/dev/null) || ram_bytes=0
    RAM_BYTES="${ram_bytes}"
    RAM_MIB=$(( ram_bytes / 1024 / 1024 ))

    export CPU_VENDOR CPU_MODEL CPU_CORES RAM_BYTES RAM_MIB
    einfo "CPU: ${CPU_MODEL} (${CPU_CORES} cores, ${CPU_VENDOR})"
    einfo "RAM: ${RAM_MIB} MiB"
}

# --- GPU ----------------------------------------------------------------------

_classify_gpu_vendor() {
    case "$1" in
        "${PCI_VENDOR_NVIDIA}") echo "nvidia" ;;
        "${PCI_VENDOR_AMD}")    echo "amd" ;;
        "${PCI_VENDOR_INTEL}")  echo "intel" ;;
        *)                      echo "unknown" ;;
    esac
}

# _gpu_driver_for — set GPU_KMOD / DRM_PKG / GPU_DRIVER / GPU_FW_FLAVORS for a vendor+device.
# AMD Phoenix (Radeon 780M, device 0x15bf / 0x1900 family) needs the six explicit
# firmware flavors; a missing/wrong flavor PANICS the kernel at amdgpu load.
_gpu_driver_for() {
    local vname="$1" did="$2"
    case "${vname}" in
        amd)
            GPU_KMOD="amdgpu"; DRM_PKG="${DRM_KMOD_PKG}"; GPU_DRIVER="amdgpu"
            case "${did}" in
                15bf|15c8|1900|1901|150e)   # Phoenix / Phoenix2 APUs (780M etc.)
                    GPU_FW_FLAVORS="${AMD_PHOENIX_FW_FLAVORS[*]}" ;;
                *)
                    GPU_FW_FLAVORS="gpu-firmware-amd-kmod" ;;  # meta: pulls all flavors
            esac
            ;;
        intel)
            # There is NO single `gpu-firmware-intel-kmod` package — that port is
            # FLAVORized per GPU generation (skylake..meteorlake). Use the
            # vendor-agnostic `gpu-firmware-kmod` meta, which pulls every Intel
            # (and AMD) firmware flavor, so i915kms gets its GuC/HuC/DMC firmware
            # on any generation without a device->generation table.
            GPU_KMOD="i915kms"; DRM_PKG="${DRM_KMOD_PKG}"; GPU_DRIVER="i915kms"
            GPU_FW_FLAVORS="gpu-firmware-kmod" ;;
        nvidia)
            GPU_KMOD="nvidia-modeset"; DRM_PKG=""; GPU_DRIVER="nvidia-driver"
            GPU_FW_FLAVORS="" ;;
        *)
            GPU_KMOD=""; DRM_PKG="${DRM_KMOD_PKG}"; GPU_DRIVER="drm-kmod"
            GPU_FW_FLAVORS="" ;;
    esac
}

detect_gpu() {
    GPU_VENDOR=""; GPU_DEVICE_ID=""; GPU_DEVICE_NAME=""; GPU_DRIVER=""
    GPU_KMOD=""; DRM_PKG=""; GPU_FW_FLAVORS=""
    HYBRID_GPU="no"; IGPU_VENDOR=""; IGPU_DEVICE_NAME=""; DGPU_VENDOR=""; DGPU_DEVICE_NAME=""

    local -a buses=() vids=() dids=() names=() vendors=()
    local bus vid did name
    while read -r bus vid did name; do
        [[ -z "${bus}" ]] && continue
        buses+=("${bus}"); vids+=("${vid}"); dids+=("${did}"); names+=("${name}")
        vendors+=("$(_classify_gpu_vendor "${vid}")")
        einfo "GPU @pci bus ${bus}: ${name} [${vid}:${did}]"
    done < <(_pci_emit_class '0x03' || true)

    if [[ ${#buses[@]} -eq 0 ]]; then
        ewarn "No GPU detected via pciconf"
        GPU_VENDOR="unknown"; GPU_DRIVER="drm-kmod"; DRM_PKG="${DRM_KMOD_PKG}"
        export GPU_VENDOR GPU_DEVICE_ID GPU_DEVICE_NAME GPU_DRIVER GPU_KMOD DRM_PKG GPU_FW_FLAVORS
        export HYBRID_GPU IGPU_VENDOR IGPU_DEVICE_NAME DGPU_VENDOR DGPU_DEVICE_NAME
        return 0
    fi

    if [[ ${#buses[@]} -ge 2 ]]; then
        # Classify iGPU vs dGPU. NVIDIA=dGPU, Intel=iGPU, AMD by bus (0=on-die).
        local igpu=-1 dgpu=-1 i
        for (( i=0; i<${#buses[@]}; i++ )); do
            case "${vendors[$i]}" in
                nvidia) dgpu=${i} ;;
                intel)  igpu=${i} ;;
                *)      if [[ "${buses[$i]}" == "0" ]]; then igpu=${i}; else dgpu=${i}; fi ;;
            esac
        done
        if [[ ${igpu} -ge 0 && ${dgpu} -ge 0 ]]; then
            HYBRID_GPU="yes"
            IGPU_VENDOR="${vendors[$igpu]}"; IGPU_DEVICE_NAME="${names[$igpu]}"
            DGPU_VENDOR="${vendors[$dgpu]}"; DGPU_DEVICE_NAME="${names[$dgpu]}"
            GPU_VENDOR="${DGPU_VENDOR}"; GPU_DEVICE_ID="${dids[$dgpu]}"; GPU_DEVICE_NAME="${DGPU_DEVICE_NAME}"
            _gpu_driver_for "${GPU_VENDOR}" "${GPU_DEVICE_ID}"
            einfo "Hybrid GPU: iGPU=${IGPU_DEVICE_NAME} + dGPU=${DGPU_DEVICE_NAME}"
        else
            GPU_VENDOR="${vendors[0]}"; GPU_DEVICE_ID="${dids[0]}"; GPU_DEVICE_NAME="${names[0]}"
            _gpu_driver_for "${GPU_VENDOR}" "${GPU_DEVICE_ID}"
        fi
    else
        GPU_VENDOR="${vendors[0]}"; GPU_DEVICE_ID="${dids[0]}"; GPU_DEVICE_NAME="${names[0]}"
        _gpu_driver_for "${GPU_VENDOR}" "${GPU_DEVICE_ID}"
    fi

    export GPU_VENDOR GPU_DEVICE_ID GPU_DEVICE_NAME GPU_DRIVER GPU_KMOD DRM_PKG GPU_FW_FLAVORS
    export HYBRID_GPU IGPU_VENDOR IGPU_DEVICE_NAME DGPU_VENDOR DGPU_DEVICE_NAME
    einfo "GPU: ${GPU_DEVICE_NAME} (${GPU_VENDOR}) -> kmod=${GPU_KMOD:-none}"
}

# --- WiFi (top GPD Pocket 4 risk: MediaTek MT7922 has no working FreeBSD driver) ---

detect_wifi() {
    WIFI_VENDOR=""; WIFI_DEVICE_ID=""; WIFI_SUPPORTED=1
    local bus vid did name
    # WiFi class is 0x0280 (other network controller); ethernet is 0x0200.
    read -r bus vid did name < <(_pci_emit_class '0x0280' || true) || true
    if [[ -z "${vid:-}" ]]; then
        # No PCI WiFi (could be USB or absent). Leave supported unknown-ish.
        WIFI_SUPPORTED=1
        export WIFI_VENDOR WIFI_DEVICE_ID WIFI_SUPPORTED
        return 0
    fi
    WIFI_DEVICE_ID="${vid}:${did}"
    case "${vid}" in
        14c3)  # MediaTek — mt76 is in-tree but DISCONNECTED FROM BUILD as of 2026
            WIFI_VENDOR="mediatek"; WIFI_SUPPORTED=0
            ewarn "WiFi: MediaTek ${WIFI_DEVICE_ID} (${name}) — NO working FreeBSD driver (mt76 unbuilt)"
            ewarn "      Bootstrap via wired/USB-Ethernet; built-in WiFi will not associate." ;;
        8086)
            WIFI_VENDOR="intel"; WIFI_SUPPORTED=1
            einfo "WiFi: Intel ${WIFI_DEVICE_ID} (${name}) — iwlwifi (802.11 a/b/g/n/ac since 14.3 via LinuxKPI; ax/WiFi 6 in progress — Foundation, 2026)" ;;
        10ec|0bda)
            WIFI_VENDOR="realtek"; WIFI_SUPPORTED=1
            einfo "WiFi: Realtek ${WIFI_DEVICE_ID} (${name}) — rtw88/rtw89 (best-effort)" ;;
        168c)
            WIFI_VENDOR="atheros"; WIFI_SUPPORTED=1
            einfo "WiFi: Atheros ${WIFI_DEVICE_ID} (${name}) — ath/ath10k (QCA61xx may be unbuilt)" ;;
        *)
            WIFI_VENDOR="unknown"; WIFI_SUPPORTED=1
            einfo "WiFi: ${WIFI_DEVICE_ID} (${name}) — support unverified" ;;
    esac
    export WIFI_VENDOR WIFI_DEVICE_ID WIFI_SUPPORTED
}

# --- Microsoft Surface (SMBIOS) -----------------------------------------------

detect_surface() {
    SURFACE_DETECTED=0; SURFACE_MODEL=""
    local maker product
    maker=$(kenv -q smbios.system.maker 2>/dev/null) || maker=""
    product=$(kenv -q smbios.system.product 2>/dev/null) || product=""
    if [[ "${maker}" == "Microsoft Corporation" && "${product}" == Surface* ]]; then
        SURFACE_DETECTED=1
        SURFACE_MODEL="${product}"
        einfo "Microsoft Surface detected: ${product}"
    fi
    export SURFACE_DETECTED SURFACE_MODEL
}

# --- UMPC / GPD (SMBIOS) ------------------------------------------------------
# Portrait-panel rotation on FreeBSD is DESKTOP-LAYER ONLY (no kern.vt.rotate);
# PANEL_ROTATION is the Wayland/xrandr transform applied post-login, not a
# console/loader fix. 90 == sway "transform 90" == xrandr "--rotate right".

detect_umpc() {
    UMPC_DETECTED=0; UMPC_VENDOR=""; UMPC_MODEL=""; PANEL_ROTATION=""
    local maker product board
    maker=$(kenv -q smbios.system.maker 2>/dev/null) || maker=""
    product=$(kenv -q smbios.system.product 2>/dev/null) || product=""
    board=$(kenv -q smbios.planar.product 2>/dev/null) || board=""

    if [[ "${maker}" == "GPD" ]]; then
        UMPC_VENDOR="GPD"
        case "${product}${board}" in
            *Pocket*4*|*G1628-04*) UMPC_DETECTED=1; UMPC_MODEL="Pocket 4"; PANEL_ROTATION="90" ;;
            *Pocket*3*|*G1618-03*) UMPC_DETECTED=1; UMPC_MODEL="Pocket 3"; PANEL_ROTATION="90" ;;
            *Win*Mini*|*G1617*)    UMPC_DETECTED=1; UMPC_MODEL="Win Mini" ;;
            *Win*Max*2*|*G1619*)   UMPC_DETECTED=1; UMPC_MODEL="Win Max 2" ;;
            *Win*4*|*G1618-04*)    UMPC_DETECTED=1; UMPC_MODEL="Win 4" ;;
        esac
    fi

    if [[ "${UMPC_DETECTED}" == "1" ]]; then
        einfo "UMPC detected: ${UMPC_VENDOR} ${UMPC_MODEL}"
        [[ -n "${PANEL_ROTATION}" ]] && einfo "  Portrait panel: desktop-layer rotation ${PANEL_ROTATION} (console stays sideways — no vt rotate on FreeBSD)"
    fi
    export UMPC_DETECTED UMPC_VENDOR UMPC_MODEL PANEL_ROTATION
}

# detect_device_profile — collapse SMBIOS detection into one profile knob.
# Call AFTER detect_surface + detect_umpc.
detect_device_profile() {
    DEVICE_PROFILE="generic"
    if [[ "${UMPC_DETECTED:-0}" == "1" && "${UMPC_VENDOR:-}" == "GPD" && "${UMPC_MODEL:-}" == "Pocket 4" ]]; then
        DEVICE_PROFILE="gpd_pocket4"
    elif [[ "${SURFACE_DETECTED:-0}" == "1" ]]; then
        DEVICE_PROFILE="surface"
    fi
    export DEVICE_PROFILE
    einfo "Device profile: ${DEVICE_PROFILE}"
}

# --- Peripherals (best-effort) ------------------------------------------------

detect_bluetooth() {
    BLUETOOTH_DETECTED=0
    # USB BT advertises bDeviceClass 0xe0 (wireless controller); ng_ubt(4) attaches it.
    if usbconfig list 2>/dev/null | grep -qiE 'bluetooth'; then
        BLUETOOTH_DETECTED=1
    else
        local d desc
        for d in $(usbconfig list 2>/dev/null | awk -F: '/ugen/{print $1}'); do
            desc=$(usbconfig -d "${d}" dump_device_desc 2>/dev/null) || continue
            if printf '%s\n' "${desc}" | grep -qi 'bDeviceClass.*0x00e0'; then
                BLUETOOTH_DETECTED=1; break
            fi
        done
    fi
    [[ "${BLUETOOTH_DETECTED}" == "1" ]] && einfo "Bluetooth controller detected"
    export BLUETOOTH_DETECTED
}

detect_webcam() {
    WEBCAM_DETECTED=0
    # webcamd-backed UVC cams show as Video class on USB; cuse/webcamd needed.
    if usbconfig list 2>/dev/null | grep -qiE 'camera|webcam|UVC'; then
        WEBCAM_DETECTED=1; einfo "Webcam detected (USB UVC — needs multimedia/webcamd)"
    fi
    export WEBCAM_DETECTED
}

# detect_battery — ACPI battery count. Gates the generic "laptop" phase
# (lib/laptop.sh: powerd, suspend, backlight, touchpad). hw.acpi.battery.units
# does not exist on desktops/VMs (sysctl fails) -> 0. Sanitize to an integer so
# a weird sysctl output can never leak shell-significant text into the config.
detect_battery() {
    BATTERY_DETECTED=$(sysctl -n hw.acpi.battery.units 2>/dev/null) || BATTERY_DETECTED=0
    case "${BATTERY_DETECTED}" in
        ''|*[!0-9]*) BATTERY_DETECTED=0 ;;
    esac
    if [[ "${BATTERY_DETECTED}" != "0" ]]; then
        einfo "Battery: ${BATTERY_DETECTED} ACPI unit(s) detected — laptop phase will apply"
    fi
    export BATTERY_DETECTED
}

# --- Disk detection -----------------------------------------------------------

# _boot_disks — best-effort base-disk name(s) backing the live medium, to exclude
# them from install targets (the install stick can enumerate as da0/nda0).
_boot_disks() {
    local provs p label dev out=""
    provs=$(mount -p 2>/dev/null | awk -v d="${DIST_DIR}" '$2=="/"||$2==d{print $1}') || true
    for p in ${provs}; do
        p="${p#/dev/}"
        case "${p}" in
            */*)  # GEOM label (ufs/.., iso9660/..) — resolve to provider via glabel
                dev=$(glabel status -s 2>/dev/null | awk -v l="${p}" '$1==l{print $3; exit}') || true
                [[ -z "${dev}" ]] && dev="${p##*/}"
                ;;
            *) dev="${p}" ;;
        esac
        # strip partition suffix pN / sN  (disk base names end in a digit: da0, nda0)
        dev=$(printf '%s\n' "${dev}" | sed -E 's/(p|s)[0-9]+$//')
        [[ -n "${dev}" ]] && out+="${dev} "
    done
    printf '%s' "${out}"
}

# detect_disks — populate AVAILABLE_DISKS: "device|size|model|transport"
detect_disks() {
    declare -ga AVAILABLE_DISKS=()
    local boot_excl disks d
    boot_excl=" $(_boot_disks)"
    disks=$(sysctl -n kern.disks 2>/dev/null) || disks=""

    for d in ${disks}; do
        case "${d}" in cd*|md*|fd*) continue ;; esac
        case "${boot_excl}" in *" ${d} "*) einfo "Skipping boot medium: ${d}"; continue ;; esac

        local info bytes human model rot tran
        info=$(geom disk list "${d}" 2>/dev/null) || info=""
        bytes=$(printf '%s\n' "${info}" | awk '/Mediasize:/{print $2; exit}') || bytes=""
        human=$(printf '%s\n' "${info}" | sed -n 's/.*Mediasize:[^(]*(\([^)]*\)).*/\1/p' | head -1) || human=""
        model=$(printf '%s\n' "${info}" | sed -n 's/^[[:space:]]*descr:[[:space:]]*//p' | head -1) || model=""
        rot=$(printf '%s\n' "${info}" | awk '/rotationrate:/{print $2; exit}') || rot=""
        [[ -z "${human}" && -n "${bytes}" ]] && human="$(( bytes / 1024 / 1024 / 1024 ))G"
        case "${d}" in
            nda*|nvd*) tran="nvme" ;;
            ada*)      tran="sata" ;;
            da*)       tran="usb/scsi" ;;
            vtbd*)     tran="virtio" ;;
            *)         tran="disk" ;;
        esac
        [[ "${rot}" == "0" || "${rot}" == "Unknown" ]] && tran="${tran}/ssd"

        AVAILABLE_DISKS+=("${d}|${human:-?}|${model:-unknown}|${tran}")
        einfo "Disk: /dev/${d} -- ${human:-?} -- ${model:-unknown} (${tran})"
    done

    export AVAILABLE_DISKS
    [[ ${#AVAILABLE_DISKS[@]} -eq 0 ]] && ewarn "No suitable disks detected"
}

# get_disk_list_for_dialog — emit tag/description pairs for dialog_menu
get_disk_list_for_dialog() {
    local entry name size model tran
    for entry in "${AVAILABLE_DISKS[@]}"; do
        IFS='|' read -r name size model tran <<< "${entry}"
        echo "/dev/${name}"
        echo "${size} ${model} (${tran})"
    done
}

# --- ESP / installed OS detection ---------------------------------------------

detect_esp() {
    declare -ga ESP_PARTITIONS=()
    WINDOWS_DETECTED=0; WINDOWS_ESP=""
    local entry name size model tran prov
    for entry in "${AVAILABLE_DISKS[@]}"; do
        IFS='|' read -r name size model tran <<< "${entry}"
        # provider name(s) of type 'efi' on this disk
        while read -r prov; do
            [[ -z "${prov}" ]] && continue
            ESP_PARTITIONS+=("/dev/${prov}")
            einfo "Found ESP: /dev/${prov}"
            local tmp
            tmp=$(mktemp -d /tmp/esp-check-XXXXXX) || continue
            if mount -t msdosfs -o ro "/dev/${prov}" "${tmp}" 2>/dev/null; then
                if [[ -f "${tmp}/EFI/Microsoft/Boot/bootmgfw.efi" ]]; then
                    WINDOWS_DETECTED=1; WINDOWS_ESP="/dev/${prov}"
                    einfo "Windows Boot Manager found on /dev/${prov}"
                fi
                umount "${tmp}" 2>/dev/null || true
            fi
            rmdir "${tmp}" 2>/dev/null || true
        done < <(gpart show -p "${name}" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="efi") print $(i-1)}' || true)
    done
    export ESP_PARTITIONS WINDOWS_DETECTED WINDOWS_ESP
}

# detect_installed_oses — best-effort scan of GPT partition types for other OSes.
# FreeBSD auto-ZFS is whole-disk destructive, so this mainly drives WARNINGS and
# the dual-boot ERASE gate; we do not deep-mount NTFS (no ntfs-3g on the ISO).
detect_installed_oses() {
    declare -gA DETECTED_OSES=()
    LINUX_DETECTED=0
    einfo "Scanning for installed operating systems..."

    local entry name size model tran prov ptype
    for entry in "${AVAILABLE_DISKS[@]}"; do
        IFS='|' read -r name size model tran <<< "${entry}"
        while read -r prov ptype; do
            [[ -z "${prov}" || -z "${ptype}" ]] && continue
            case "${ptype}" in
                ms-basic-data)
                    [[ "${WINDOWS_DETECTED:-0}" == "1" ]] && DETECTED_OSES["/dev/${prov}"]="Windows (data)" ;;
                ms-recovery)   DETECTED_OSES["/dev/${prov}"]="Windows (recovery)" ;;
                linux-data)    DETECTED_OSES["/dev/${prov}"]="Linux"; LINUX_DETECTED=1 ;;
                linux-swap)    DETECTED_OSES["/dev/${prov}"]="Linux (swap)" ;;
                freebsd-zfs|freebsd-ufs|freebsd-boot)
                    DETECTED_OSES["/dev/${prov}"]="FreeBSD" ;;
            esac
        done < <(gpart show -p "${name}" 2>/dev/null | awk 'NF>=4 && $3 ~ /[ps][0-9]+$/ {print $3, $4}' || true)
    done

    if [[ "${WINDOWS_DETECTED:-0}" == "1" && -n "${WINDOWS_ESP:-}" ]]; then
        DETECTED_OSES["${WINDOWS_ESP}"]="Windows Boot Manager"
    fi

    export LINUX_DETECTED DETECTED_OSES
    if [[ ${#DETECTED_OSES[@]} -gt 0 ]]; then
        local p
        for p in "${!DETECTED_OSES[@]}"; do einfo "Detected OS: ${p} -> ${DETECTED_OSES[${p}]}"; done
    else
        einfo "No other operating systems detected"
    fi
    serialize_detected_oses
}

# serialize_detected_oses — DETECTED_OSES -> "/dev/p1=Windows|/dev/p3=Linux"
serialize_detected_oses() {
    local result="" part name
    for part in "${!DETECTED_OSES[@]}"; do
        name="${DETECTED_OSES[${part}]}"
        name="${name//|/-}"; name="${name//=/-}"
        [[ -n "${result}" ]] && result+="|"
        result+="${part}=${name}"
    done
    DETECTED_OSES_SERIALIZED="${result}"
    export DETECTED_OSES_SERIALIZED
}

deserialize_detected_oses() {
    declare -gA DETECTED_OSES=()
    WINDOWS_DETECTED="${WINDOWS_DETECTED:-0}"
    LINUX_DETECTED="${LINUX_DETECTED:-0}"
    local serialized="${DETECTED_OSES_SERIALIZED:-}"
    [[ -z "${serialized}" ]] && return 0
    local IFS='|' entry part name
    for entry in ${serialized}; do
        part="${entry%%=*}"; name="${entry#*=}"
        [[ -z "${part}" || -z "${name}" ]] && continue
        DETECTED_OSES["${part}"]="${name}"
        if [[ "${name}" == *"Windows"* ]]; then WINDOWS_DETECTED=1; else LINUX_DETECTED=1; fi
    done
    export DETECTED_OSES WINDOWS_DETECTED LINUX_DETECTED
}

# --- EFI / arch ---------------------------------------------------------------

# is_arm64_surface — Snapdragon Surface (Pro 11th / Laptop 7th) is out of scope.
is_unsupported_arch() {
    local m
    m=$(uname -m 2>/dev/null) || m=""
    [[ "${m}" != "amd64" && "${m}" != "x86_64" ]]
}

# --- Full detection -----------------------------------------------------------

detect_all_hardware() {
    einfo "=== Hardware Detection ==="
    detect_cpu
    detect_gpu
    detect_wifi
    detect_surface
    detect_umpc
    detect_device_profile
    detect_bluetooth
    detect_webcam
    detect_battery
    detect_disks
    detect_esp
    detect_installed_oses
    einfo "=== Hardware Detection Complete ==="
}

# get_hardware_summary — multi-line summary for the hw_detect screen
get_hardware_summary() {
    local summary=""
    summary+="CPU: ${CPU_MODEL:-unknown}\n"
    summary+="  Cores: ${CPU_CORES:-?}   RAM: ${RAM_MIB:-?} MiB\n\n"
    if [[ "${HYBRID_GPU:-no}" == "yes" ]]; then
        summary+="GPU: Hybrid\n"
        summary+="  iGPU: ${IGPU_DEVICE_NAME:-unknown} (${IGPU_VENDOR:-unknown})\n"
        summary+="  dGPU: ${DGPU_DEVICE_NAME:-unknown} (${DGPU_VENDOR:-unknown})\n"
    else
        summary+="GPU: ${GPU_DEVICE_NAME:-unknown} (${GPU_VENDOR:-unknown})\n"
    fi
    summary+="  Driver: ${GPU_DRIVER:-none} (kmod ${GPU_KMOD:-none})\n"
    if [[ -n "${WIFI_VENDOR:-}" ]]; then
        if [[ "${WIFI_SUPPORTED:-1}" == "0" ]]; then
            summary+="WiFi: ${WIFI_VENDOR} ${WIFI_DEVICE_ID} -- NO FreeBSD driver! Use wired/USB-Ethernet\n"
        else
            summary+="WiFi: ${WIFI_VENDOR} ${WIFI_DEVICE_ID} (best-effort)\n"
        fi
    fi
    [[ "${BLUETOOTH_DETECTED:-0}" == "1" ]] && summary+="Bluetooth: detected\n"
    [[ "${BATTERY_DETECTED:-0}" != "0" ]] && summary+="Battery: ${BATTERY_DETECTED} ACPI unit(s) — laptop phase (powerd/suspend/backlight/touchpad) will apply\n"
    [[ "${SURFACE_DETECTED:-0}" == "1" ]] && summary+="Microsoft Surface: ${SURFACE_MODEL:-detected} (best-effort — see README)\n"
    if [[ "${UMPC_DETECTED:-0}" == "1" ]]; then
        summary+="UMPC: ${UMPC_VENDOR} ${UMPC_MODEL}\n"
        [[ -n "${PANEL_ROTATION:-}" ]] && summary+="  Portrait panel: desktop rotation ${PANEL_ROTATION} (console stays sideways)\n"
    fi
    summary+="Device profile: ${DEVICE_PROFILE:-generic}\n\n"
    summary+="Disks:\n"
    local entry name size model tran
    for entry in "${AVAILABLE_DISKS[@]}"; do
        IFS='|' read -r name size model tran <<< "${entry}"
        summary+="  /dev/${name}: ${size} ${model} (${tran})\n"
    done
    summary+="\n"
    [[ ${#ESP_PARTITIONS[@]} -gt 0 ]] && summary+="ESP partitions: ${ESP_PARTITIONS[*]}\n"
    if [[ ${#DETECTED_OSES[@]} -gt 0 ]]; then
        summary+="Detected operating systems:\n"
        local p
        for p in "${!DETECTED_OSES[@]}"; do summary+="  ${p}: ${DETECTED_OSES[${p}]}\n"; done
    else
        summary+="Detected operating systems: none\n"
    fi
    echo -e "${summary}"
}
