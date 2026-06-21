#!/usr/bin/env bash
# constants.sh — Global constants for the FreeBSD installer
source "${LIB_DIR}/protection.sh"

readonly INSTALLER_VERSION="0.1.0"
readonly INSTALLER_NAME="FreeBSD TUI Installer"

# Paths (use defaults, allow override from environment / tests).
# bsdinstall mounts the target at /mnt (BSDINSTALL_CHROOT); we align with it.
: "${MOUNTPOINT:=/mnt}"
: "${CHROOT_INSTALLER_DIR:=/tmp/freebsd-installer}"
: "${LOG_FILE:=/tmp/freebsd-installer.log}"
: "${CHECKPOINT_DIR:=/tmp/freebsd-installer-checkpoints}"
: "${CHECKPOINT_DIR_SUFFIX:=/tmp/freebsd-installer-checkpoints}"
: "${CONFIG_FILE:=/tmp/freebsd-installer.conf}"

# Generated bsdinstall scripted-install file (preamble + setup script).
: "${BSDINSTALL_SCRIPT:=/tmp/freebsd-installer-install.cfg}"

# FreeBSD distribution sets. The live memstick/DVD ships these in
# /usr/freebsd-dist with a MANIFEST, so distextract uses them with no network.
: "${DIST_DIR:=/usr/freebsd-dist}"
readonly DIST_DEFAULT="kernel.txz base.txz"
# Optional network dist site (only used if a required set is missing locally).
: "${DIST_SITE:=}"

# Partition sizing (MiB). bsdinstall auto-ZFS uses a fixed 260M ESP.
readonly ESP_SIZE_MIB=260
readonly SWAP_DEFAULT_SIZE_MIB=4096      # PC default; UMPC bumps to 8192
readonly FREEBSD_MIN_SIZE_MIB=8192       # 8 GiB minimum target disk

# GPT partition type aliases used by gpart / scriptedpart
readonly GPT_TYPE_EFI="efi"
readonly GPT_TYPE_FREEBSD_ZFS="freebsd-zfs"
readonly GPT_TYPE_FREEBSD_UFS="freebsd-ufs"
readonly GPT_TYPE_FREEBSD_SWAP="freebsd-swap"
readonly GPT_TYPE_FREEBSD_BOOT="freebsd-boot"

# ZFS defaults (mirror the in-tree bsdinstall zfsboot reference)
: "${ZFS_POOL_NAME_DEFAULT:=zroot}"
: "${ZFS_VDEV_TYPE_DEFAULT:=stripe}"
: "${ZFS_POOL_OPTS_DEFAULT:=-O compression=lz4 -O atime=off}"

# drm-kmod metaport auto-selects the DRM version matching the running kernel
# (14.x -> drm-61-kmod, 15.0 -> drm-66-kmod, 15.1 -> drm-612-kmod). Keep the metaport as the default.
: "${DRM_KMOD_PKG:=drm-kmod}"

# AMD Phoenix (Radeon 780M / gfx1103) firmware flavor split-packages. A missing
# or wrong flavor panics the kernel at amdgpu load — install all six.
readonly -a AMD_PHOENIX_FW_FLAVORS=(
    gpu-firmware-amd-kmod-dcn-3-1-4
    gpu-firmware-amd-kmod-gc-11-0-1
    gpu-firmware-amd-kmod-gc-11-0-4
    gpu-firmware-amd-kmod-psp-13-0-4
    gpu-firmware-amd-kmod-sdma-6-0-1
    gpu-firmware-amd-kmod-vcn-4-0-2
)

# Disk probe order: NVMe-first (nda is the real device on 14+, nvd an alias),
# then SATA/USB/VirtIO. The boot medium is excluded at detection time.
readonly -a DISK_PROBE_ORDER=(nda nvd ada da vtbd)

# Timeouts
readonly COUNTDOWN_DEFAULT=10
readonly DIALOG_TIMEOUT=0

# Gum (bundled TUI backend) — FreeBSD/amd64 static binary in data/gum.tar.gz
: "${GUM_VERSION:=0.17.0}"
: "${GUM_CACHE_DIR:=/tmp/freebsd-installer-gum}"

# Exit codes for TUI screens
readonly TUI_NEXT=0
readonly TUI_BACK=1
readonly TUI_ABORT=2

# --- Checkpoint names (install-time phases) ---
# bsdinstall is stateless: the `bsdinstall` checkpoint owns the destructive
# wipe+base install; the long, failure-prone pkg phases live behind their own
# checkpoints so --resume skips what already succeeded. Re-entrancy (zpool
# export + unmount + re-wipe) is handled in our wrapper, not by bsdinstall.
readonly -a CHECKPOINTS=(
    "preflight"
    "bsdinstall"        # wipe + bsdinstall script: partitions, base, loader, root/user, base sysrc
    "mount_target"      # mount /mnt, prep chroot (resolv.conf, pkg bootstrap)
    "gpu"               # drm-kmod + firmware flavors + kld_list
    "desktop"           # pkg DE + display manager + seatd/dbus + groups
    "device_quirks"     # GPD Pocket 4 / Surface quirks (best-effort)
    "extras"            # extra packages, Wayland shells, gaming
    "finalize"          # cap_mkdb, efibootmgr re-assert, bectl baseline, POST-INSTALL notes
)

# --- Configuration variable names (for save/load) ---
readonly -a CONFIG_VARS=(
    # --- target / disk / filesystem ---
    TARGET_DISK             # nda0|nvd0|ada0|da0|... (NVMe-first probe, boot medium excluded)
    FS_PROFILE              # zfs | ufs
    PARTITION_SCHEME        # auto | dual-boot | manual
    ZFS_POOL_NAME           # zroot
    ZFS_VDEV_TYPE           # stripe|mirror|raid10|raidz1..3
    ZFS_POOL_OPTS           # "-O compression=lz4 -O atime=off" (set explicitly)
    BOOT_TYPE               # UEFI | BIOS | BIOS+UEFI | auto (machdep.bootmethod)
    # --- encryption / swap ---
    GELI_ROOT               # 0|1  full-disk geli root (test on quirky UEFI first)
    SWAP_TYPE               # partition | none
    SWAP_SIZE_MIB           # integer MiB (converted to Ng for bsdinstall)
    SWAP_ENCRYPTION         # 0|1  -> swapN.eli (one-time key)
    # --- ZFS tuning ---
    ARC_MAX_BYTES           # vfs.zfs.arc_max in BYTES (e.g. 4294967296 for 12 GiB RAM)
    # --- system ---
    HOSTNAME
    TIMEZONE                # Europe/Warsaw
    KEYMAP                  # pl.kbd (vt keymap)
    LOCALE                  # en_US.UTF-8 (used to derive login.conf class)
    LOCALE_CLASS            # login.conf class name (e.g. english)
    USERNAME
    FULLNAME
    ROOT_PASSWORD_HASH      # $6$ SHA-512 (never plaintext)
    USER_PASSWORD_HASH      # $6$ SHA-512 (never plaintext)
    USER_GROUPS             # comma-separated, e.g. wheel,operator,video
    PRIV_TOOL               # doas | sudo
    # --- desktop / gpu ---
    DESKTOP_TYPE            # none|kde|gnome|xfce|mate|cinnamon|lxqt|sway|niri|hyprland|mango
    DISPLAY_MANAGER         # sddm|gdm|lightdm|none
    DESKTOP_EXTRAS          # space-separated apps (firefox, etc.)
    GPU_VENDOR              # amd|intel|nvidia|none|unknown
    GPU_DEVICE_ID           # PCI device id
    GPU_DEVICE_NAME         # human-readable model
    GPU_KMOD                # amdgpu|i915kms|nvidia-modeset
    DRM_PKG                 # drm-kmod (metaport) | drm-61-kmod | drm-66-kmod | drm-612-kmod
    GPU_FW_FLAVORS          # space-separated gpu-firmware-amd-kmod-* (Phoenix)
    HYBRID_GPU              # yes|no
    IGPU_VENDOR
    IGPU_DEVICE_NAME
    DGPU_VENDOR
    DGPU_DEVICE_NAME
    # --- multi-boot (dual-boot detection) ---
    ESP_PARTITION           # existing ESP device (dual-boot reuse)
    ESP_REUSE               # yes|no
    ROOT_PARTITION          # resolved after install (resume)
    SWAP_PARTITION
    WINDOWS_DETECTED        # 0|1
    LINUX_DETECTED          # 0|1
    DETECTED_OSES_SERIALIZED
    # --- device profile / peripherals ---
    DEVICE_PROFILE          # generic|gpd_pocket4|surface
    PANEL_ROTATION          # "" | 90 | 270 (desktop-layer rotation, portrait UMPC)
    SURFACE_DETECTED        # 0|1
    SURFACE_MODEL
    UMPC_DETECTED           # 0|1
    UMPC_VENDOR
    UMPC_MODEL
    WIFI_VENDOR             # detected WiFi chip vendor (mediatek/intel/realtek/...)
    WIFI_DEVICE_ID          # pci vendor:device (e.g. 14c3:0616)
    WIFI_SUPPORTED          # 0|1  (0 = no FreeBSD driver, e.g. MT7922 -> wired bootstrap)
    BLUETOOTH_DETECTED      # 0|1
    WEBCAM_DETECTED         # 0|1
    # --- extras / community ---
    EXTRA_PACKAGES          # space-separated additional pkg
    ENABLE_NOCTALIA         # yes|no  (Noctalia Wayland shell)
    NOCTALIA_COMPOSITOR     # niri|sway|hyprland
    ENABLE_GAMING           # yes|no  (Steam/wine/gamescope where available)
)
