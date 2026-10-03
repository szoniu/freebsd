#!/usr/bin/env bash
# tests/test_pkg_branch.sh — Test the pkg repo branch knob (PKG_BRANCH).
#
# Guards three ways the knob can break silently:
#
#  1. ${ABI} / ${VERSION_MINOR} expanded on the HOST instead of by pkg(8). The
#     setup script is a heredoc expanded on the host, so a missing escape turns
#     the URL into `pkg+https://pkg.FreeBSD.org//latest` — pkg then fails with a
#     fetch error that says nothing about the cause.
#  2. Only FreeBSD-ports switched. The kmods repo is separate and per base
#     version; leaving it behind ships kernel modules for another base (on 15.1,
#     the main `latest` repo carries drm-66-kmod built for 15.0).
#  3. The repo config written AFTER `pkg bootstrap`, so bash/git/doas come from
#     a different branch than the rest of the system.
#
# The functional part EXECUTES the generated block with sh against a fake root,
# so the heredoc quoting is exercised for real instead of asserted as a string.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export _FREEBSD_INSTALLER=1
export LIB_DIR="${SCRIPT_DIR}/lib"
export DATA_DIR="${SCRIPT_DIR}/data"
export DRY_RUN=1
export NON_INTERACTIVE=1

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pkgbranch.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
export LOG_FILE="${WORK}/test.log"
export BSDINSTALL_SCRIPT="${WORK}/install.cfg"
: > "${LOG_FILE}"

source "${LIB_DIR}/constants.sh"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/utils.sh"
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

# Minimal config so bsdinstall_generate_script renders a full setup script.
export TARGET_DISK=nda0 FS_PROFILE=zfs ZFS_POOL_NAME=zroot ZFS_VDEV_TYPE=stripe
export HOSTNAME=testhost USERNAME=tester BOOT_TYPE=UEFI SWAP_TYPE=none

# generate_and_apply BRANCH — render the setup script, cut out the repo block,
# run it with sh against a fake root, print the resulting config file path.
generate_and_apply() {
    local branch="$1" root="${WORK}/root-${1:-default}"
    if [[ -n "${branch}" ]]; then
        export PKG_BRANCH="${branch}"
    else
        unset PKG_BRANCH
    fi
    bsdinstall_generate_script >/dev/null 2>&1
    sed -n "/^mkdir -p \"\$(dirname/,/^PKGREPO\$/p" "${BSDINSTALL_SCRIPT}" \
        | sed "s#/usr/local#${root}/usr/local#g" > "${WORK}/block.sh"
    sh "${WORK}/block.sh"
    echo "${root}/usr/local/etc/pkg/repos/FreeBSD.conf"
}

count() { grep -c -- "$1" "$2" || true; }

for branch in latest quarterly; do
    echo "=== PKG_BRANCH=${branch} ==="
    conf="$(generate_and_apply "${branch}")"

    assert_eq "config file written" "yes" "$([[ -f "${conf}" ]] && echo yes || echo no)"
    assert_eq "both repos present" "2" \
        "$(grep -cE '^FreeBSD-ports(-kmods)?: \{' "${conf}" || true)"
    # 1. host must not expand pkg's variables
    assert_eq "\${ABI} reaches the file verbatim (both URLs)" "2" "$(count '${ABI}' "${conf}")"
    assert_eq "\${VERSION_MINOR} reaches the file verbatim" "1" "$(count '${VERSION_MINOR}' "${conf}")"
    assert_eq "no empty path segment in any URL" "0" "$(count 'org//' "${conf}")"
    # 2. BOTH repos follow the branch
    assert_eq "ports repo on ${branch}" "1" "$(count "\${ABI}/${branch}\"" "${conf}")"
    assert_eq "kmods repo on ${branch}" "1" "$(count "kmods_${branch}_" "${conf}")"
    assert_eq "kmods priority ${PKG_KMODS_PRIORITY}" "1" \
        "$(count "priority: ${PKG_KMODS_PRIORITY}" "${conf}")"
    other="$([[ ${branch} == latest ]] && echo quarterly || echo latest)"
    assert_eq "no repo left on the other branch (${other})" "0" "$(count "${other}" "${conf}")"
done

echo "=== PKG_BRANCH unset (default) ==="
conf="$(generate_and_apply "")"
assert_eq "default branch is ${PKG_BRANCH_DEFAULT}" "1" \
    "$(count "\${ABI}/${PKG_BRANCH_DEFAULT}\"" "${conf}")"

echo "=== ordering in the setup script ==="
export PKG_BRANCH=latest
bsdinstall_generate_script >/dev/null 2>&1
repo_line="$(grep -n "^cat > ${PKG_REPO_CONF}" "${BSDINSTALL_SCRIPT}" | head -1 | cut -d: -f1)"
boot_line="$(grep -n 'pkg bootstrap' "${BSDINSTALL_SCRIPT}" | head -1 | cut -d: -f1)"
assert_eq "repo config written BEFORE pkg bootstrap" "yes" \
    "$([[ -n "${repo_line}" && -n "${boot_line}" && ${repo_line} -lt ${boot_line} ]] && echo yes || echo no)"

echo "=== injection via preset value (PKG_BRANCH carries a newline) ==="
# config_load filters variable NAMES, not values: a preset can set PKG_BRANCH to
# anything. A newline + "PKGREPO" would close the heredoc early and the rest would
# run as root in the chroot. Check the WHOLE setup script — cutting out the repo
# block with sed stops at the first PKGREPO and hides exactly this failure.
export PKG_BRANCH=$'latest\nPKGREPO\ntouch /tmp/pkgbranch-pwned\ncat > /dev/null <<\'PKGREPO\''
bsdinstall_generate_script >/dev/null 2>&1
assert_eq "injected command is NOT a standalone line" "0" \
    "$(grep -c '^touch /tmp/pkgbranch-pwned$' "${BSDINSTALL_SCRIPT}" || true)"
assert_eq "heredoc closed exactly once" "1" "$(grep -c '^PKGREPO$' "${BSDINSTALL_SCRIPT}" || true)"
assert_eq "invalid value falls back to quarterly" "1" \
    "$(grep -c 'pkg.FreeBSD.org/\${ABI}/quarterly"' "${BSDINSTALL_SCRIPT}" || true)"

source "${LIB_DIR}/config.sh"
export TIMEZONE=UTC LOCALE=en_US.UTF-8 ROOT_PASSWORD_HASH='$6$x' USER_PASSWORD_HASH='$6$x'
validate_config >/dev/null 2>&1 && v=accepted || v=rejected
assert_eq "validate_config rejects the injected value" "rejected" "${v}"
export PKG_BRANCH=latest
validate_config >/dev/null 2>&1 && v=accepted || v=rejected
assert_eq "validate_config accepts latest" "accepted" "${v}"

echo "=== TUI default follows DESKTOP_TYPE ==="
source "${SCRIPT_DIR}/tui/pkg_branch_config.sh"
# TUI_NEXT/TUI_BACK/TUI_ABORT come from lib/constants.sh (readonly).
# Mock: return whichever option the screen pre-selected ("on"), i.e. the default.
dialog_radiolist() {
    shift
    while [[ $# -ge 3 ]]; do
        [[ "$3" == "on" ]] && { echo "$1"; return 0; }
        shift 3
    done
    return 1
}
for case_ in "none:quarterly" "kde:latest" "hyprland:latest" "niri:latest"; do
    unset PKG_BRANCH
    export DESKTOP_TYPE="${case_%%:*}"
    screen_pkg_branch_config >/dev/null 2>&1 || true
    assert_eq "DESKTOP_TYPE=${DESKTOP_TYPE} -> ${case_##*:}" "${case_##*:}" "${PKG_BRANCH:-}"
done
export DESKTOP_TYPE=kde PKG_BRANCH=quarterly
screen_pkg_branch_config >/dev/null 2>&1 || true
assert_eq "explicit/preset value wins over the desktop default" "quarterly" "${PKG_BRANCH}"

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
