#!/usr/bin/env bash
# tests/test_bsdinstall.sh — Test bsdinstall scripted-install file generation.
# Renders ${BSDINSTALL_SCRIPT} from fake CONFIG_VARS (DRY_RUN, no disk touched)
# and asserts the preamble + setup script are well-formed sh and carry the
# FreeBSD-specific knobs (ZFSBOOT_* / PARTITIONS, password hash via stdin, etc.).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export _FREEBSD_INSTALLER=1
export LIB_DIR="${SCRIPT_DIR}/lib"
export DATA_DIR="${SCRIPT_DIR}/data"
export LOG_FILE="/tmp/freebsd-test-bsdinstall.log"
export DRY_RUN=1
export NON_INTERACTIVE=1
: > "${LOG_FILE}"

source "${LIB_DIR}/constants.sh"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/bsdinstall.sh"

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

# assert_contains — true if the generated file contains a fixed substring.
assert_contains() {
    local desc="$1" needle="$2" file="$3"
    if grep -qF -- "${needle}" "${file}" 2>/dev/null; then
        echo "  PASS: ${desc}"
        (( PASS++ )) || true
    else
        echo "  FAIL: ${desc} — '${needle}' not found in ${file}"
        (( FAIL++ )) || true
    fi
}

# assert_not_contains — true if the generated file does NOT contain a substring.
assert_not_contains() {
    local desc="$1" needle="$2" file="$3"
    if grep -qF -- "${needle}" "${file}" 2>/dev/null; then
        echo "  FAIL: ${desc} — '${needle}' unexpectedly present in ${file}"
        (( FAIL++ )) || true
    else
        echo "  PASS: ${desc}"
        (( PASS++ )) || true
    fi
}

# A fixed fake hash with a literal '$' so we exercise %q quoting (a bare hash in
# argv would word-split / glob; it must reach the file safely quoted).
FAKE_HASH='$6$abc.def/ghi$0123456789ABCDEF'

# Common fake CONFIG_VARS shared by both profiles.
set_common_config() {
    TARGET_DISK="nda0"
    HOSTNAME="testbox"
    TIMEZONE="Europe/Warsaw"
    KEYMAP="pl.kbd"
    LOCALE="en_US.UTF-8"
    LOCALE_CLASS="english"
    USERNAME="tester"
    FULLNAME="Test User"
    USER_GROUPS="wheel,operator,video"
    PRIV_TOOL="doas"
    ROOT_PASSWORD_HASH="${FAKE_HASH}"
    USER_PASSWORD_HASH="${FAKE_HASH}"
    SWAP_TYPE="partition"
    SWAP_SIZE_MIB="4096"
    DIST_SITE=""
    export TARGET_DISK HOSTNAME TIMEZONE KEYMAP LOCALE LOCALE_CLASS
    export USERNAME FULLNAME USER_GROUPS PRIV_TOOL
    export ROOT_PASSWORD_HASH USER_PASSWORD_HASH SWAP_TYPE SWAP_SIZE_MIB DIST_SITE
}

# ---------------------------------------------------------------------------
echo "=== Test: _mib_to_size (whole GiB -> Ng, else Nm) ==="

assert_eq "_mib_to_size 4096 -> 4g"     "4g"     "$(_mib_to_size 4096)"
assert_eq "_mib_to_size 1536 -> 1536m"  "1536m"  "$(_mib_to_size 1536)"
assert_eq "_mib_to_size 1024 -> 1g"     "1g"     "$(_mib_to_size 1024)"
assert_eq "_mib_to_size 8192 -> 8g"     "8g"     "$(_mib_to_size 8192)"
assert_eq "_mib_to_size 0 -> 0g"        "0g"     "$(_mib_to_size 0)"

# ---------------------------------------------------------------------------
echo ""
echo "=== Test: ZFS profile script generation ==="

export BSDINSTALL_SCRIPT="/tmp/test-bsdinstall-$$.cfg"

set_common_config
FS_PROFILE="zfs"
ZFS_POOL_NAME="zroot"
ZFS_VDEV_TYPE="stripe"
ZFS_POOL_OPTS="-O compression=lz4 -O atime=off"
export FS_PROFILE ZFS_POOL_NAME ZFS_VDEV_TYPE ZFS_POOL_OPTS

bsdinstall_generate_script

assert_eq "ZFS script file exists" "true" \
    "$([[ -f "${BSDINSTALL_SCRIPT}" ]] && echo true || echo false)"

# (1) the generated file must parse as POSIX sh
assert_eq "ZFS script parses with sh -n" "true" \
    "$(sh -n "${BSDINSTALL_SCRIPT}" 2>>"${LOG_FILE}" && echo true || echo false)"

# (2) ZFS preamble knobs + #!/bin/sh split + ROOTPASS_ENC
assert_contains "ZFSBOOT_DISKS present"      "ZFSBOOT_DISKS"      "${BSDINSTALL_SCRIPT}"
assert_contains "ZFSBOOT_VDEV_TYPE present"  "ZFSBOOT_VDEV_TYPE"  "${BSDINSTALL_SCRIPT}"
assert_contains "ZFSBOOT_POOL_NAME present"  "ZFSBOOT_POOL_NAME"  "${BSDINSTALL_SCRIPT}"
assert_contains "ZFSBOOT_DISKS uses target"  'ZFSBOOT_DISKS="nda0"' "${BSDINSTALL_SCRIPT}"
assert_contains "setup-script #!/bin/sh split" "#!/bin/sh"        "${BSDINSTALL_SCRIPT}"
assert_contains "ROOTPASS_ENC line present"  "ROOTPASS_ENC"       "${BSDINSTALL_SCRIPT}"
assert_contains "ZFS swap token (4g) emitted" 'ZFSBOOT_SWAP_SIZE="4g"' "${BSDINSTALL_SCRIPT}"

# (3) password hash reaches the file safely quoted via stdin, never as a bare pw arg.
# The user hash is piped: `printf %s <hash> | pw usermod -n <user> -H 0`.
assert_contains "user hash piped to pw -H 0" "| pw usermod -n" "${BSDINSTALL_SCRIPT}"
assert_contains "pw usermod uses -H 0 (stdin hash)" "-H 0" "${BSDINSTALL_SCRIPT}"
# A bare `pw usermod ... -p <hash>` (hash in argv) must NOT appear.
assert_not_contains "no -p hash in argv" "pw usermod -p" "${BSDINSTALL_SCRIPT}"
assert_not_contains "no useradd -p hash in argv" "pw useradd -p" "${BSDINSTALL_SCRIPT}"
# The hash contains '$' and '/'; %q quoting escapes each '$' as '\$' so the sh
# preamble doesn't interpolate it. That ESCAPED form is exactly the "safely
# quoted" invariant — a bare '$6$...' in the file would be expanded by sh. It
# must appear in both ROOTPASS_ENC and the pw line.
FAKE_HASH_Q='\$6\$abc.def/ghi\$0123456789ABCDEF'
assert_contains "ROOTPASS_ENC carries escaped hash" "ROOTPASS_ENC=${FAKE_HASH_Q}" "${BSDINSTALL_SCRIPT}"
assert_contains "pw usermod stdin carries escaped hash" "printf %s ${FAKE_HASH_Q} | pw usermod -n" "${BSDINSTALL_SCRIPT}"
assert_eq "escaped hash appears at least twice (root + user)" "true" \
    "$([[ "$(grep -cF -- "${FAKE_HASH_Q}" "${BSDINSTALL_SCRIPT}" || true)" -ge 2 ]] && echo true || echo false)"
# And the dangerous UNESCAPED bare hash must NOT appear (would be sh-expanded).
assert_not_contains "no bare unescaped \$6\$ hash" "${FAKE_HASH}" "${BSDINSTALL_SCRIPT}"

rm -f "${BSDINSTALL_SCRIPT}"

# ---------------------------------------------------------------------------
echo ""
echo "=== Test: UFS profile script generation ==="

export BSDINSTALL_SCRIPT="/tmp/test-bsdinstall-ufs-$$.cfg"

set_common_config
FS_PROFILE="ufs"
export FS_PROFILE
# Drop ZFS-only vars so the UFS path is exercised cleanly.
unset ZFS_POOL_NAME ZFS_VDEV_TYPE ZFS_POOL_OPTS 2>/dev/null || true

bsdinstall_generate_script

assert_eq "UFS script file exists" "true" \
    "$([[ -f "${BSDINSTALL_SCRIPT}" ]] && echo true || echo false)"

assert_eq "UFS script parses with sh -n" "true" \
    "$(sh -n "${BSDINSTALL_SCRIPT}" 2>>"${LOG_FILE}" && echo true || echo false)"

# (5) UFS profile -> PARTITIONS=... with efi + freebsd-ufs (no ZFSBOOT_*)
assert_contains "PARTITIONS line present"     "PARTITIONS="     "${BSDINSTALL_SCRIPT}"
assert_contains "PARTITIONS has efi entry"    "efi"             "${BSDINSTALL_SCRIPT}"
assert_contains "PARTITIONS has freebsd-ufs"  "freebsd-ufs"     "${BSDINSTALL_SCRIPT}"
assert_contains "PARTITIONS includes swap (4g)" "4g freebsd-swap" "${BSDINSTALL_SCRIPT}"
assert_not_contains "no ZFSBOOT_DISKS in UFS"  "ZFSBOOT_DISKS"   "${BSDINSTALL_SCRIPT}"
# ROOTPASS_ENC + stdin-piped user hash still apply for UFS.
assert_contains "UFS ROOTPASS_ENC present"     "ROOTPASS_ENC"    "${BSDINSTALL_SCRIPT}"
assert_contains "UFS user hash piped to pw"    "| pw usermod -n" "${BSDINSTALL_SCRIPT}"

rm -f "${BSDINSTALL_SCRIPT}"

# ---------------------------------------------------------------------------
echo ""
echo "=== Test: UFS boot partition follows BOOT_TYPE (UFS+BIOS must be bootable) ==="

export BSDINSTALL_SCRIPT="/tmp/test-bsdinstall-ufsboot-$$.cfg"
set_common_config
FS_PROFILE="ufs"; export FS_PROFILE
unset ZFS_POOL_NAME ZFS_VDEV_TYPE ZFS_POOL_OPTS 2>/dev/null || true

# BIOS: a pure-BIOS GPT box needs a freebsd-boot partition for gptboot bootcode;
# an efi-only layout would be UNBOOTABLE. (regression for the efi-only bug)
BOOT_TYPE="BIOS"; export BOOT_TYPE
bsdinstall_generate_script
assert_contains     "UFS+BIOS has freebsd-boot"   "freebsd-boot" "${BSDINSTALL_SCRIPT}"
assert_not_contains "UFS+BIOS has no efi ESP"      "260M efi"     "${BSDINSTALL_SCRIPT}"

# UEFI: an efi ESP, no freebsd-boot.
BOOT_TYPE="UEFI"; export BOOT_TYPE
bsdinstall_generate_script
assert_contains     "UFS+UEFI has efi ESP"            "260M efi"     "${BSDINSTALL_SCRIPT}"
assert_not_contains "UFS+UEFI has no freebsd-boot"    "freebsd-boot" "${BSDINSTALL_SCRIPT}"
rm -f "${BSDINSTALL_SCRIPT}"

# ---------------------------------------------------------------------------
echo ""
echo "=== Test: setup-script injection safety (%q on user-controlled fields) ==="

export BSDINSTALL_SCRIPT="/tmp/test-bsdinstall-inj-$$.cfg"
set_common_config
FS_PROFILE="zfs"; export FS_PROFILE
unset BOOT_TYPE 2>/dev/null || true
# A hostile GECOS carrying an apostrophe, a (escaped, literal) command
# substitution and a double quote. The quote chars are built from octal escapes
# (no literal quotes in the source) and the command-sub is backslash-escaped, so
# the value is plain DATA, never executed here.
printf -v sq '\047'   # apostrophe
printf -v dq '\042'   # double quote
FULLNAME="O${sq}Brien \$(touch /tmp/freebsd-test-PWNED-$$) ${dq}x${dq}"
export FULLNAME
bsdinstall_generate_script
assert_eq "injected FULLNAME: generated script still parses with sh -n" "true" \
    "$(sh -n "${BSDINSTALL_SCRIPT}" 2>>"${LOG_FILE}" && echo true || echo false)"
assert_not_contains "FULLNAME command-sub neutralized (no bare \$(touch)" '$(touch' "${BSDINSTALL_SCRIPT}"
assert_eq "injection did not execute touch during generation" "absent" \
    "$([[ -e "/tmp/freebsd-test-PWNED-$$" ]] && echo present || echo absent)"
rm -f "${BSDINSTALL_SCRIPT}" "/tmp/freebsd-test-PWNED-$$"

# ---------------------------------------------------------------------------
# Cleanup (defensive — temp files already removed above)
rm -f "/tmp/test-bsdinstall-$$.cfg" "/tmp/test-bsdinstall-ufs-$$.cfg" "${LOG_FILE}"

echo ""
echo "=== Results ==="
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"

[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
