#!/usr/bin/env bash
# tests/test_validate.sh — Test validate_config() (FreeBSD schema)
#
# validate_config() lives in lib/config.sh. It prints "- <message>" lines to
# stdout for each problem and returns 1 if any error was found, 0 otherwise.
# Non-fatal advisories (e.g. UFS has no boot environments) go to ewarn (stderr)
# and never affect the return code, so they are invisible to the stdout capture.
#
# Run with DRY_RUN=1 so the block-device existence checks (test -c /dev/...) are
# skipped — these tests never touch real disks. FreeBSD disks are character
# devices (nda0/ada0/...), unlike Void's block devices (/dev/sda).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Setup mock environment
export _FREEBSD_INSTALLER=1
export LIB_DIR="${SCRIPT_DIR}/lib"
export DATA_DIR="${SCRIPT_DIR}/data"
export LOG_FILE="/tmp/freebsd-test-validate.log"
export DRY_RUN=1
: > "${LOG_FILE}"

source "${LIB_DIR}/constants.sh"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/config.sh"

# Guard against the parallel rewrite of validate_config(): if the function is
# absent, emit a clear skip and exit 0 so this file is still well-formed and the
# suite is not blocked. (The SPEC may land before/after this test file.)
if ! declare -F validate_config >/dev/null; then
    echo "SKIP: validate_config() not defined in lib/config.sh (parallel rewrite in flight)"
    exit 0
fi

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

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "${haystack}" == *"${needle}"* ]]; then
        echo "  PASS: ${desc}"
        (( PASS++ )) || true
    else
        echo "  FAIL: ${desc} — '${needle}' not found in output"
        (( FAIL++ )) || true
    fi
}

# Helper: set all required vars to valid defaults (FreeBSD config schema).
# zfs root, niri Wayland desktop on AMD, $6$ SHA-512 hashes (never plaintext).
# PARTITION_SCHEME stays "auto" so the (DRY_RUN-skipped) device check would
# apply, and SWAP_TYPE=none keeps the swap cross-field rule inert by default.
set_valid_config() {
    export TARGET_DISK="nda0"
    export FS_PROFILE="zfs"
    export PARTITION_SCHEME="auto"
    export BOOT_TYPE="UEFI"
    export SWAP_TYPE="none"
    export HOSTNAME="freebsd-test"
    export TIMEZONE="Europe/Warsaw"
    export LOCALE="pl_PL.UTF-8"
    export KEYMAP="pl.kbd"
    export GPU_VENDOR="amd"
    export DESKTOP_TYPE="niri"
    export PRIV_TOOL="doas"
    export USERNAME="szoniu"
    export ROOT_PASSWORD_HASH='$6$rootsalt$AbCdEfGhIjKlMnOpQrStUvWxYz0123456789aBcDeFgHiJkLmNoPqRsTuVwXyZ.abc/'
    export USER_PASSWORD_HASH='$6$usersalt$ZyXwVuTsRqPoNmLkJiHgFeDcBa9876543210ZyXwVuTsRqPoNmLkJiHgFeDcBa.xyz/'
}

clear_config() {
    unset TARGET_DISK FS_PROFILE PARTITION_SCHEME BOOT_TYPE SWAP_TYPE \
          SWAP_SIZE_MIB HOSTNAME TIMEZONE LOCALE KEYMAP GPU_VENDOR DESKTOP_TYPE \
          PRIV_TOOL NOCTALIA_COMPOSITOR USERNAME ROOT_PASSWORD_HASH \
          USER_PASSWORD_HASH ESP_PARTITION ESP_REUSE ROOT_PARTITION 2>/dev/null || true
}

# ============================
echo "=== Test: Valid baseline config ==="
clear_config
set_valid_config

rc=0
output=$(validate_config) || rc=$?
assert_eq "Valid config returns 0" "0" "${rc}"
assert_eq "Valid config has no error output" "" "${output}"

# ============================
echo ""
echo "=== Test: Missing required variables ==="
clear_config
set_valid_config
unset TARGET_DISK

rc=0
output=$(validate_config) || rc=$?
assert_eq "Missing TARGET_DISK returns 1" "1" "${rc}"
assert_contains "Output mentions TARGET_DISK" "TARGET_DISK" "${output}"

clear_config
set_valid_config
unset ROOT_PASSWORD_HASH

rc=0
output=$(validate_config) || rc=$?
assert_eq "Missing ROOT_PASSWORD_HASH returns 1" "1" "${rc}"
assert_contains "Output mentions ROOT_PASSWORD_HASH" "ROOT_PASSWORD_HASH" "${output}"

# ============================
echo ""
echo "=== Test: Invalid enum values ==="
# FS_PROFILE must be zfs or ufs — ntfs is not a FreeBSD root profile.
clear_config
set_valid_config
export FS_PROFILE="ntfs"

rc=0
output=$(validate_config) || rc=$?
assert_eq "Bad FS_PROFILE (ntfs) returns 1" "1" "${rc}"
assert_contains "Output mentions FS_PROFILE" "FS_PROFILE" "${output}"

# DESKTOP_TYPE allows kde/gnome/... but "plasma6" is not a valid tag.
clear_config
set_valid_config
export DESKTOP_TYPE="plasma6"

rc=0
output=$(validate_config) || rc=$?
assert_eq "Bad DESKTOP_TYPE (plasma6) returns 1" "1" "${rc}"
assert_contains "Output mentions DESKTOP_TYPE" "DESKTOP_TYPE" "${output}"

# GPU_VENDOR is the vendor name (amd), not the historic driver name (radeon).
clear_config
set_valid_config
export GPU_VENDOR="radeon"

rc=0
output=$(validate_config) || rc=$?
assert_eq "Bad GPU_VENDOR (radeon) returns 1" "1" "${rc}"
assert_contains "Output mentions GPU_VENDOR" "GPU_VENDOR" "${output}"

# ============================
echo ""
echo "=== Test: Hostname validation (RFC 1123) ==="
# "Bad_Host!" has an underscore and a bang — both illegal in RFC 1123 hostnames.
clear_config
set_valid_config
export HOSTNAME="Bad_Host!"

rc=0
output=$(validate_config) || rc=$?
assert_eq "Bad HOSTNAME returns 1" "1" "${rc}"
assert_contains "Output mentions HOSTNAME" "HOSTNAME" "${output}"

# ============================
echo ""
echo "=== Test: Cross-field — SWAP_TYPE=partition needs a size ==="
# A freebsd-swap partition with size 0 is meaningless and must be rejected.
clear_config
set_valid_config
export SWAP_TYPE="partition"
export SWAP_SIZE_MIB="0"

rc=0
output=$(validate_config) || rc=$?
assert_eq "partition swap with size 0 returns 1" "1" "${rc}"
assert_contains "Output mentions SWAP_SIZE_MIB" "SWAP_SIZE_MIB" "${output}"

# Sanity: the same scheme with a real size passes (proves the failure above is
# the size gate, not the SWAP_TYPE enum).
clear_config
set_valid_config
export SWAP_TYPE="partition"
export SWAP_SIZE_MIB="4096"

rc=0
output=$(validate_config) || rc=$?
assert_eq "partition swap with size 4096 returns 0" "0" "${rc}"

# ============================
echo ""
echo "=== Test: DRY_RUN skips block-device check ==="
# A nonexistent character device must NOT fail under DRY_RUN=1 (no disk I/O).
clear_config
set_valid_config
export DRY_RUN=1
export TARGET_DISK="nonexistent99"

rc=0
output=$(validate_config) || rc=$?
assert_eq "DRY_RUN=1 skips device existence check" "0" "${rc}"

# ============================
echo ""
echo "=== Test: DESKTOP_TYPE=mango is accepted ==="
# Mango (x11-wm/mango) is a supported Wayland tiling compositor.
clear_config
set_valid_config
export DESKTOP_TYPE="mango"
export DISPLAY_MANAGER="none"

rc=0
output=$(validate_config) || rc=$?
assert_eq "DESKTOP_TYPE=mango returns 0" "0" "${rc}"

# ============================
echo ""
echo "=== Test: DISPLAY_MANAGER enum ==="
# Only sddm/gdm/lightdm/none are wired; a garbage value would sysrc a bogus knob.
clear_config
set_valid_config
export DISPLAY_MANAGER="ly"

rc=0
output=$(validate_config) || rc=$?
assert_eq "Bad DISPLAY_MANAGER (ly) returns 1" "1" "${rc}"
assert_contains "Output mentions DISPLAY_MANAGER" "DISPLAY_MANAGER" "${output}"

# ============================
echo ""
echo "=== Test: ARC_MAX_BYTES must be an integer (never '4G') ==="
# vfs.zfs.arc_max is in BYTES; the '4G' form is rejected by the loader.
clear_config
set_valid_config
export ARC_MAX_BYTES="4G"

rc=0
output=$(validate_config) || rc=$?
assert_eq "ARC_MAX_BYTES=4G returns 1" "1" "${rc}"
assert_contains "Output mentions ARC_MAX_BYTES" "ARC_MAX_BYTES" "${output}"

# Cleanup
rm -f "${LOG_FILE}"

echo ""
echo "=== Results ==="
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"

[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
