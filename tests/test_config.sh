#!/usr/bin/env bash
# tests/test_config.sh — Test config save/load round-trip (FreeBSD schema)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Setup mock environment
export _FREEBSD_INSTALLER=1
export LIB_DIR="${SCRIPT_DIR}/lib"
export DATA_DIR="${SCRIPT_DIR}/data"
export LOG_FILE="/tmp/freebsd-test-config.log"
: > "${LOG_FILE}"

source "${LIB_DIR}/constants.sh"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/config.sh"

PASS=0
FAIL=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "${expected}" == "${actual}" ]]; then
        echo "  PASS: ${desc}"
        (( PASS++ )) || true
    else
        echo "  FAIL: ${desc} — expected '${expected}', got '${actual}'"
        (( FAIL++ )) || true
    fi
}

echo "=== Test: Config Round-Trip ==="

# Set a representative FreeBSD config — ZFS root on an NVMe disk (nda0 is the
# real NVMe device on 14+), niri Wayland desktop on an AMD GPU, doas privilege
# tool, $6$ SHA-512 password hashes (never plaintext).
TARGET_DISK="nda0"
FS_PROFILE="zfs"
PARTITION_SCHEME="auto"
ZFS_POOL_NAME="zroot"
ZFS_VDEV_TYPE="stripe"
ZFS_POOL_OPTS="-O compression=lz4 -O atime=off"
BOOT_TYPE="UEFI"
SWAP_TYPE="partition"
SWAP_SIZE_MIB="4096"
SWAP_ENCRYPTION="1"
HOSTNAME="freebsd-test"
TIMEZONE="Europe/Warsaw"
KEYMAP="pl.kbd"
LOCALE="pl_PL.UTF-8"
LOCALE_CLASS="polish"
USERNAME="szoniu"
FULLNAME="Test User"
ROOT_PASSWORD_HASH='$6$rootsalt$AbCdEfGhIjKlMnOpQrStUvWxYz0123456789aBcDeFgHiJkLmNoPqRsTuVwXyZ.abc/'
USER_PASSWORD_HASH='$6$usersalt$ZyXwVuTsRqPoNmLkJiHgFeDcBa9876543210ZyXwVuTsRqPoNmLkJiHgFeDcBa.xyz/'
USER_GROUPS="wheel,operator,video"
PRIV_TOOL="doas"
DESKTOP_TYPE="niri"
DISPLAY_MANAGER="none"
DESKTOP_EXTRAS="firefox foot"
GPU_VENDOR="amd"
GPU_KMOD="amdgpu"
DRM_PKG="drm-kmod"
GPU_FW_FLAVORS="gpu-firmware-amd-kmod-dcn-3-1-4 gpu-firmware-amd-kmod-gc-11-0-1 gpu-firmware-amd-kmod-psp-13-0-4"
DEVICE_PROFILE="gpd_pocket4"
WIFI_SUPPORTED="0"
EXTRA_PACKAGES="git vim"
export TARGET_DISK FS_PROFILE PARTITION_SCHEME ZFS_POOL_NAME ZFS_VDEV_TYPE \
    ZFS_POOL_OPTS BOOT_TYPE SWAP_TYPE SWAP_SIZE_MIB SWAP_ENCRYPTION HOSTNAME \
    TIMEZONE KEYMAP LOCALE LOCALE_CLASS USERNAME FULLNAME ROOT_PASSWORD_HASH \
    USER_PASSWORD_HASH USER_GROUPS PRIV_TOOL DESKTOP_TYPE DISPLAY_MANAGER \
    DESKTOP_EXTRAS GPU_VENDOR GPU_KMOD DRM_PKG GPU_FW_FLAVORS DEVICE_PROFILE \
    WIFI_SUPPORTED EXTRA_PACKAGES

# Save
TMPFILE="/tmp/freebsd-test-config-$$.conf"
config_save "${TMPFILE}"

# Assert the saved file carries umask-077 perms (it contains password hashes —
# config_save() runs the write under `umask 077`, so the mode must be 0600).
FILE_MODE="$(stat -c '%a' "${TMPFILE}" 2>/dev/null || stat -f '%Lp' "${TMPFILE}")"
assert_eq "Saved file perms (umask 077 -> 600)" "600" "${FILE_MODE}"

# Clear values — prove load actually repopulates them, not stale globals.
unset TARGET_DISK FS_PROFILE PARTITION_SCHEME ZFS_POOL_NAME ZFS_VDEV_TYPE \
    ZFS_POOL_OPTS BOOT_TYPE SWAP_TYPE SWAP_SIZE_MIB SWAP_ENCRYPTION HOSTNAME \
    TIMEZONE KEYMAP LOCALE LOCALE_CLASS USERNAME FULLNAME ROOT_PASSWORD_HASH \
    USER_PASSWORD_HASH USER_GROUPS PRIV_TOOL DESKTOP_TYPE DISPLAY_MANAGER \
    DESKTOP_EXTRAS GPU_VENDOR GPU_KMOD DRM_PKG GPU_FW_FLAVORS DEVICE_PROFILE \
    WIFI_SUPPORTED EXTRA_PACKAGES

# Load
config_load "${TMPFILE}"

# Verify every value round-trips
assert_eq "TARGET_DISK" "nda0" "${TARGET_DISK:-}"
assert_eq "FS_PROFILE" "zfs" "${FS_PROFILE:-}"
assert_eq "PARTITION_SCHEME" "auto" "${PARTITION_SCHEME:-}"
assert_eq "ZFS_POOL_NAME" "zroot" "${ZFS_POOL_NAME:-}"
assert_eq "ZFS_VDEV_TYPE" "stripe" "${ZFS_VDEV_TYPE:-}"
assert_eq "ZFS_POOL_OPTS" "-O compression=lz4 -O atime=off" "${ZFS_POOL_OPTS:-}"
assert_eq "BOOT_TYPE" "UEFI" "${BOOT_TYPE:-}"
assert_eq "SWAP_TYPE" "partition" "${SWAP_TYPE:-}"
assert_eq "SWAP_SIZE_MIB" "4096" "${SWAP_SIZE_MIB:-}"
assert_eq "SWAP_ENCRYPTION" "1" "${SWAP_ENCRYPTION:-}"
assert_eq "HOSTNAME" "freebsd-test" "${HOSTNAME:-}"
assert_eq "TIMEZONE" "Europe/Warsaw" "${TIMEZONE:-}"
assert_eq "KEYMAP" "pl.kbd" "${KEYMAP:-}"
assert_eq "LOCALE" "pl_PL.UTF-8" "${LOCALE:-}"
assert_eq "LOCALE_CLASS" "polish" "${LOCALE_CLASS:-}"
assert_eq "USERNAME" "szoniu" "${USERNAME:-}"
assert_eq "FULLNAME" "Test User" "${FULLNAME:-}"
assert_eq "ROOT_PASSWORD_HASH" '$6$rootsalt$AbCdEfGhIjKlMnOpQrStUvWxYz0123456789aBcDeFgHiJkLmNoPqRsTuVwXyZ.abc/' "${ROOT_PASSWORD_HASH:-}"
assert_eq "USER_PASSWORD_HASH" '$6$usersalt$ZyXwVuTsRqPoNmLkJiHgFeDcBa9876543210ZyXwVuTsRqPoNmLkJiHgFeDcBa.xyz/' "${USER_PASSWORD_HASH:-}"
assert_eq "USER_GROUPS" "wheel,operator,video" "${USER_GROUPS:-}"
assert_eq "PRIV_TOOL" "doas" "${PRIV_TOOL:-}"
assert_eq "DESKTOP_TYPE" "niri" "${DESKTOP_TYPE:-}"
assert_eq "DISPLAY_MANAGER" "none" "${DISPLAY_MANAGER:-}"
assert_eq "DESKTOP_EXTRAS" "firefox foot" "${DESKTOP_EXTRAS:-}"
assert_eq "GPU_VENDOR" "amd" "${GPU_VENDOR:-}"
assert_eq "GPU_KMOD" "amdgpu" "${GPU_KMOD:-}"
assert_eq "DRM_PKG" "drm-kmod" "${DRM_PKG:-}"
assert_eq "GPU_FW_FLAVORS" "gpu-firmware-amd-kmod-dcn-3-1-4 gpu-firmware-amd-kmod-gc-11-0-1 gpu-firmware-amd-kmod-psp-13-0-4" "${GPU_FW_FLAVORS:-}"
assert_eq "DEVICE_PROFILE" "gpd_pocket4" "${DEVICE_PROFILE:-}"
assert_eq "WIFI_SUPPORTED" "0" "${WIFI_SUPPORTED:-}"
assert_eq "EXTRA_PACKAGES" "git vim" "${EXTRA_PACKAGES:-}"

# Test config_set / config_get
echo ""
echo "=== Test: config_set / config_get ==="
config_set "HOSTNAME" "new-host"
assert_eq "config_set HOSTNAME" "new-host" "$(config_get HOSTNAME)"

# Spaces survive config_set/get
config_set "EXTRA_PACKAGES" "pkg with spaces"
assert_eq "Spaces in value" "pkg with spaces" "$(config_get EXTRA_PACKAGES)"

# ZFS pool opts carry shell-significant chars (dashes, spaces, '=')
config_set "ZFS_POOL_OPTS" "-O compression=zstd -O atime=off"
assert_eq "Special chars (=/-/space)" "-O compression=zstd -O atime=off" "$(config_get ZFS_POOL_OPTS)"

# Test round-trip with special characters
TMPFILE2="/tmp/freebsd-test-config-special-$$.conf"
config_save "${TMPFILE2}"
unset HOSTNAME EXTRA_PACKAGES ZFS_POOL_OPTS
config_load "${TMPFILE2}"
assert_eq "Round-trip HOSTNAME" "new-host" "${HOSTNAME:-}"
assert_eq "Round-trip EXTRA_PACKAGES" "pkg with spaces" "${EXTRA_PACKAGES:-}"
assert_eq "Round-trip ZFS_POOL_OPTS" "-O compression=zstd -O atime=off" "${ZFS_POOL_OPTS:-}"

# Cleanup
rm -f "${TMPFILE}" "${TMPFILE2}" "${LOG_FILE}"

echo ""
echo "=== Results ==="
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"

if [[ ${FAIL} -eq 0 ]]; then
    exit 0
else
    exit 1
fi
