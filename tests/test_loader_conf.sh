#!/usr/bin/env bash
# tests/test_loader_conf.sh — Test chroot_loader_conf_set() and guard the whole
# "sysrc with a dotted name" class of bugs.
#
# sysrc(8) validates the variable name as a shell identifier and rejects dots
# ("name contains characters not allowed in shell"), even though dotted knobs are
# what loader.conf is made of — that aborted the bsdinstall and laptop phases on
# real hardware. Dotted knobs must therefore go through chroot_loader_conf_set
# (or the generated _loader_set in the setup script), never sysrc.
#
# The functional part runs the REAL helper with chroot_sh mocked to execute the
# script locally against a temp file, so the grep/printf/mv logic is exercised
# for real instead of being asserted as a string.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export _FREEBSD_INSTALLER=1
export LIB_DIR="${SCRIPT_DIR}/lib"
export DATA_DIR="${SCRIPT_DIR}/data"
export LOG_FILE="/tmp/freebsd-test-loader-conf.log"
export DRY_RUN=0
export NON_INTERACTIVE=1
: > "${LOG_FILE}"

source "${LIB_DIR}/constants.sh"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/utils.sh"
source "${LIB_DIR}/chroot.sh"

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

TESTCONF="$(mktemp -t loaderconf)"
trap 'rm -f "${TESTCONF}" "${TESTCONF}.new"' EXIT

# Mock: run the helper's script locally, with the target path swapped for a temp
# file. Everything else (quoting, dot escaping, rewrite-in-place) stays real.
chroot_sh() {
    local script="${1//\/boot\/loader.conf/${TESTCONF}}"
    /bin/sh -c "${script}"
}

echo "=== Test: chroot_loader_conf_set writes dotted knobs ==="

: > "${TESTCONF}"
chroot_loader_conf_set "vfs.zfs.arc_max" "5614422698" >/dev/null 2>&1
assert_eq "dotted knob written with quoted value" \
    'vfs.zfs.arc_max="5614422698"' "$(cat "${TESTCONF}")"

echo ""
echo "=== Test: idempotent rewrite (no duplicates, new value wins) ==="

chroot_loader_conf_set "vfs.zfs.arc_max" "42" >/dev/null 2>&1
assert_eq "still exactly one arc_max line" "1" \
    "$(grep -c '^vfs\.zfs\.arc_max=' "${TESTCONF}" || true)"
assert_eq "value replaced, not appended" 'vfs.zfs.arc_max="42"' "$(cat "${TESTCONF}")"

echo ""
echo "=== Test: dots are escaped, not treated as regex wildcards ==="

# A pre-existing line that differs from the knob ONLY where the dots are: with an
# unescaped '.' in the grep pattern this line would be silently deleted.
printf 'vfsXzfsXarc_max="999"\nzfs_load="YES"\n' > "${TESTCONF}"
chroot_loader_conf_set "vfs.zfs.arc_max" "1" >/dev/null 2>&1
assert_eq "lookalike line survives" "1" \
    "$(grep -c '^vfsXzfsXarc_max=' "${TESTCONF}" || true)"
assert_eq "unrelated knob survives" "1" "$(grep -c '^zfs_load=' "${TESTCONF}" || true)"
assert_eq "new knob appended" "1" \
    "$(grep -c '^vfs\.zfs\.arc_max="1"$' "${TESTCONF}" || true)"

echo ""
echo "=== Test: empty name is a no-op ==="

cp "${TESTCONF}" "${TESTCONF}.before"
chroot_loader_conf_set "" "1" >/dev/null 2>&1
assert_eq "file untouched for empty name" "true" \
    "$(cmp -s "${TESTCONF}" "${TESTCONF}.before" && echo true || echo false)"
rm -f "${TESTCONF}.before"

echo ""
echo "=== Test: no lib/ module calls sysrc with a dotted variable name ==="

# Anchored on the NAME right before '=', so `sysrc -f /boot/loader.conf zfs_load=YES`
# (dot in the PATH, undotted name) is correctly not a match.
offenders="$(grep -rnE 'sysrc[^=]*[[:space:]][A-Za-z_][A-Za-z0-9_]*\.[A-Za-z0-9_.]*=' \
    "${LIB_DIR}" 2>/dev/null | grep -v '^\s*#' || true)"
assert_eq "no dotted sysrc in lib/" "" "${offenders}"

echo ""
echo "=== Results ==="
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"
[[ "${FAIL}" -eq 0 ]] || exit 1
