#!/usr/bin/env bash
# tests/test_devfs_rules.sh — Test chroot_devfs_rule_add() (lib/chroot.sh).
#
# devfs permissions are rebuilt from scratch on every boot, so access to
# /dev/input/* and /dev/backlight/* can only be granted by a devfs.rules ruleset
# + devfs_system_ruleset in rc.conf. Two phases write into that ruleset (desktop:
# input/*, laptop: backlight/*), so the invariant under test is that they share
# ONE [localrules=10] section and never duplicate a rule.
#
# chroot_sh is mocked to run the generated script locally: the target path is
# swapped for a temp file and `sysrc` (absent on the host) is turned into a
# printf that records what would have been set. Everything else is the real code.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export _FREEBSD_INSTALLER=1
export LIB_DIR="${SCRIPT_DIR}/lib"
export DATA_DIR="${SCRIPT_DIR}/data"
export LOG_FILE="/tmp/freebsd-test-devfs-rules.log"
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

RULES="$(mktemp -t devfsrules)"
SYSRC_LOG="$(mktemp -t devfssysrc)"
trap 'rm -f "${RULES}" "${RULES}.new" "${SYSRC_LOG}"' EXIT

chroot_sh() {
    local script="${1//\/etc\/devfs.rules/${RULES}}"
    script="${script//sysrc /printf \'SYSRC %s\\n\' }"
    /bin/sh -c "${script}" >> "${SYSRC_LOG}" 2>&1
}

echo "=== Test: first rule creates the section ==="

: > "${RULES}"
chroot_devfs_rule_add "input/*" 0660 video >/dev/null 2>&1
assert_eq "one [localrules=10] header" "1" "$(grep -c '^\[localrules=10\]' "${RULES}" || true)"
assert_eq "input rule written" "1" \
    "$(grep -cF "add path 'input/*' mode 0660 group video" "${RULES}" || true)"
assert_eq "devfs_system_ruleset set via sysrc" "1" \
    "$(grep -c 'SYSRC devfs_system_ruleset=localrules' "${SYSRC_LOG}" || true)"

echo ""
echo "=== Test: a second caller reuses the same section ==="

# This is the laptop (backlight) + desktop (input) pair. A second header would be
# ambiguous for devfs(8), so the header count must stay at 1.
chroot_devfs_rule_add "backlight/*" 0660 video >/dev/null 2>&1
assert_eq "still one header" "1" "$(grep -c '^\[localrules=10\]' "${RULES}" || true)"
assert_eq "both rules present" "2" "$(grep -c '^add path ' "${RULES}" || true)"

echo ""
echo "=== Test: re-running the same rule is a no-op (resume safety) ==="

chroot_devfs_rule_add "input/*" 0660 video >/dev/null 2>&1
assert_eq "input rule not duplicated" "1" \
    "$(grep -cF "add path 'input/*' mode 0660 group video" "${RULES}" || true)"

echo ""
echo "=== Test: rules land INSIDE the section, not at EOF ==="

# Anything appended after the section (a hand-edit, another ruleset) must not
# swallow our rule: it is inserted directly below the header, not with >>.
printf '\n[otherrules=20]\nadd path %s zfs%s mode 0660 group operator\n' "'" "'" >> "${RULES}"
chroot_devfs_rule_add "dri/*" 0660 video >/dev/null 2>&1
assert_eq "new rule sits above the later section" "true" \
    "$([[ "$(grep -n "dri/\*" "${RULES}" | cut -d: -f1)" -lt "$(grep -n '^\[otherrules=20\]' "${RULES}" | cut -d: -f1)" ]] && echo true || echo false)"

echo ""
echo "=== Test: empty glob is a no-op ==="

cp "${RULES}" "${RULES}.before"
chroot_devfs_rule_add "" 0660 video >/dev/null 2>&1
assert_eq "file untouched for empty glob" "true" \
    "$(cmp -s "${RULES}" "${RULES}.before" && echo true || echo false)"
rm -f "${RULES}.before"

echo ""
echo "=== Test: callers are wired up ==="

# The regression this test exists for: a Wayland/KDE session with no input access
# because nobody asked for the input/* rule.
assert_eq "desktop phase grants input/*" "1" \
    "$(grep -cF 'chroot_devfs_rule_add "input/*"' "${LIB_DIR}/desktop.sh" || true)"
assert_eq "laptop phase grants backlight/*" "1" \
    "$(grep -cF 'chroot_devfs_rule_add "backlight/*"' "${LIB_DIR}/laptop.sh" || true)"
# And nothing writes the section header by hand any more (that is what produced
# two competing [localrules=10] blocks).
# The regression is a second WRITER of /etc/devfs.rules (that is what produced
# two competing [localrules=10] headers) — not a mention of the file in a comment
# or in the POST-INSTALL notes text, so match on the append operator.
assert_eq "nothing appends to devfs.rules outside the helper" "" \
    "$(grep -rn 'devfs\.rules' "${LIB_DIR}" | grep -v '/chroot.sh:' | grep '>>' || true)"

echo ""
echo "=== Results ==="
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"
[[ "${FAIL}" -eq 0 ]] || exit 1
