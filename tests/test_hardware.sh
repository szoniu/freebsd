#!/usr/bin/env bash
# tests/test_hardware.sh — Test the pure hardware helpers (no real hardware needed):
#   _classify_gpu_vendor      (PCI vendor id -> nvidia/amd/intel/unknown)
#   _gpu_driver_for           (vendor+device -> GPU_KMOD / DRM_PKG / GPU_FW_FLAVORS)
#   serialize/deserialize_detected_oses  (DETECTED_OSES assoc-array round-trip)
#   is_unsupported_arch       (amd64/x86_64 OK; everything else unsupported)
#
# Standalone: no root, no hardware. DRY_RUN + NON_INTERACTIVE so nothing touches
# the system. We source only constants + logging + hardware (the FreeBSD GPU
# database is inline in hardware.sh, unlike the Void data/gpu_database.sh split).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export _FREEBSD_INSTALLER=1
export LIB_DIR="${SCRIPT_DIR}/lib"
export DRY_RUN=1
export NON_INTERACTIVE=1
export LOG_FILE="/tmp/freebsd-test-hardware.log"
: > "${LOG_FILE}"

source "${LIB_DIR}/constants.sh"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/hardware.sh"

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

# assert_contains — substring match (for the multi-flavor GPU_FW_FLAVORS string)
assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "${haystack}" == *"${needle}"* ]]; then
        echo "  PASS: ${desc}"
        (( PASS++ )) || true
    else
        echo "  FAIL: ${desc} — '${needle}' not found in '${haystack}'"
        (( FAIL++ )) || true
    fi
}

echo "=== Test: GPU vendor classification (_classify_gpu_vendor) ==="

assert_eq "NVIDIA 10de -> nvidia"  "nvidia"  "$(_classify_gpu_vendor "10de")"
assert_eq "AMD 1002 -> amd"        "amd"     "$(_classify_gpu_vendor "1002")"
assert_eq "Intel 8086 -> intel"    "intel"   "$(_classify_gpu_vendor "8086")"
assert_eq "Unknown vendor -> unknown" "unknown" "$(_classify_gpu_vendor "1af4")"

echo ""
echo "=== Test: GPU driver selection (_gpu_driver_for) ==="

# AMD Phoenix (Radeon 780M, device 0x15bf): amdgpu kmod + the six explicit firmware
# flavors — a missing/wrong flavor PANICS the kernel at amdgpu load.
_gpu_driver_for amd 15bf
assert_eq "AMD Phoenix -> kmod amdgpu"   "amdgpu"  "${GPU_KMOD}"
assert_eq "AMD Phoenix -> driver amdgpu" "amdgpu"  "${GPU_DRIVER}"
assert_eq "AMD Phoenix -> DRM metaport"  "${DRM_KMOD_PKG}" "${DRM_PKG}"
assert_contains "AMD Phoenix FW has dcn-3-1-4"  "gpu-firmware-amd-kmod-dcn-3-1-4"  "${GPU_FW_FLAVORS}"
assert_contains "AMD Phoenix FW has gc-11-0-1"  "gpu-firmware-amd-kmod-gc-11-0-1"  "${GPU_FW_FLAVORS}"
assert_contains "AMD Phoenix FW has gc-11-0-4"  "gpu-firmware-amd-kmod-gc-11-0-4"  "${GPU_FW_FLAVORS}"
assert_contains "AMD Phoenix FW has psp-13-0-4" "gpu-firmware-amd-kmod-psp-13-0-4" "${GPU_FW_FLAVORS}"
assert_contains "AMD Phoenix FW has sdma-6-0-1" "gpu-firmware-amd-kmod-sdma-6-0-1" "${GPU_FW_FLAVORS}"
assert_contains "AMD Phoenix FW has vcn-4-0-2"  "gpu-firmware-amd-kmod-vcn-4-0-2"  "${GPU_FW_FLAVORS}"

# Non-Phoenix AMD falls back to the meta firmware port (pulls all flavors).
_gpu_driver_for amd 7340
assert_eq "AMD non-Phoenix -> kmod amdgpu"   "amdgpu"                "${GPU_KMOD}"
assert_eq "AMD non-Phoenix -> firmware meta" "gpu-firmware-amd-kmod" "${GPU_FW_FLAVORS}"

# Intel: i915kms + the vendor-agnostic gpu-firmware-kmod meta (there is NO single
# gpu-firmware-intel-kmod package — that port is flavorized per generation), drm metaport.
_gpu_driver_for intel 9a49
assert_eq "Intel -> kmod i915kms"   "i915kms" "${GPU_KMOD}"
assert_eq "Intel -> driver i915kms" "i915kms" "${GPU_DRIVER}"
assert_eq "Intel -> DRM metaport"   "${DRM_KMOD_PKG}" "${DRM_PKG}"
assert_eq "Intel -> firmware meta"  "gpu-firmware-kmod" "${GPU_FW_FLAVORS}"

# NVIDIA: nvidia-modeset kmod, nvidia-driver, no drm-kmod (proprietary stack), no FW flavors.
_gpu_driver_for nvidia 2704
assert_eq "NVIDIA -> kmod nvidia-modeset"  "nvidia-modeset" "${GPU_KMOD}"
assert_eq "NVIDIA -> driver nvidia-driver" "nvidia-driver"  "${GPU_DRIVER}"
assert_eq "NVIDIA -> empty DRM_PKG"        ""               "${DRM_PKG}"
assert_eq "NVIDIA -> empty FW flavors"     ""               "${GPU_FW_FLAVORS}"

# Unknown vendor: generic drm-kmod metaport, no specific kmod.
_gpu_driver_for unknown ffff
assert_eq "Unknown -> empty kmod"       ""          "${GPU_KMOD}"
assert_eq "Unknown -> driver drm-kmod"  "drm-kmod"  "${GPU_DRIVER}"
assert_eq "Unknown -> DRM metaport"     "${DRM_KMOD_PKG}" "${DRM_PKG}"

echo ""
echo "=== Test: DETECTED_OSES serialize/deserialize round-trip ==="

# Build a fake DETECTED_OSES map, serialize it, then deserialize into a fresh
# array and verify every entry survived. serialize joins "part=name" with '|',
# sanitizing '|' and '=' out of OS names.
declare -gA DETECTED_OSES=()
DETECTED_OSES["/dev/nda0p1"]="Windows Boot Manager"
DETECTED_OSES["/dev/nda0p3"]="Linux"
DETECTED_OSES["/dev/nda0p5"]="FreeBSD"
WINDOWS_DETECTED=1
LINUX_DETECTED=1

serialize_detected_oses
assert_contains "serialized has Windows entry" "/dev/nda0p1=Windows Boot Manager" "${DETECTED_OSES_SERIALIZED}"
assert_contains "serialized has Linux entry"   "/dev/nda0p3=Linux"   "${DETECTED_OSES_SERIALIZED}"
assert_contains "serialized has FreeBSD entry" "/dev/nda0p5=FreeBSD" "${DETECTED_OSES_SERIALIZED}"

# Wipe the live array + flags, then rebuild purely from the serialized string.
unset DETECTED_OSES; declare -gA DETECTED_OSES=()
WINDOWS_DETECTED=0
LINUX_DETECTED=0
deserialize_detected_oses

assert_eq "round-trip: 3 OSes recovered"   "3" "${#DETECTED_OSES[@]}"
assert_eq "round-trip: Windows preserved"  "Windows Boot Manager" "${DETECTED_OSES[/dev/nda0p1]:-MISSING}"
assert_eq "round-trip: Linux preserved"    "Linux"   "${DETECTED_OSES[/dev/nda0p3]:-MISSING}"
assert_eq "round-trip: FreeBSD preserved"  "FreeBSD" "${DETECTED_OSES[/dev/nda0p5]:-MISSING}"
# deserialize re-derives the boolean flags from the OS names.
assert_eq "round-trip: WINDOWS_DETECTED re-derived" "1" "${WINDOWS_DETECTED}"
assert_eq "round-trip: LINUX_DETECTED re-derived"   "1" "${LINUX_DETECTED}"

# Empty serialized string -> empty array, no error.
DETECTED_OSES_SERIALIZED=""
unset DETECTED_OSES; declare -gA DETECTED_OSES=()
deserialize_detected_oses
assert_eq "empty serialized -> empty array" "0" "${#DETECTED_OSES[@]}"

echo ""
echo "=== Test: architecture guard (is_unsupported_arch) ==="

# is_unsupported_arch reads `uname -m`; it returns 0 (true = unsupported) for
# anything that isn't amd64/x86_64. We can't change the real uname, so we stub it
# and drive it with _FAKE_UNAME_M.
uname() {
    if [[ "${1:-}" == "-m" ]]; then printf '%s\n' "${_FAKE_UNAME_M:-amd64}"; return 0; fi
    command uname "$@"
}

_FAKE_UNAME_M="amd64"
if is_unsupported_arch; then r="unsupported"; else r="supported"; fi
assert_eq "amd64 is supported" "supported" "${r}"

_FAKE_UNAME_M="x86_64"
if is_unsupported_arch; then r="unsupported"; else r="supported"; fi
assert_eq "x86_64 is supported" "supported" "${r}"

_FAKE_UNAME_M="arm64"
if is_unsupported_arch; then r="unsupported"; else r="supported"; fi
assert_eq "arm64 is unsupported" "unsupported" "${r}"

_FAKE_UNAME_M="aarch64"
if is_unsupported_arch; then r="unsupported"; else r="supported"; fi
assert_eq "aarch64 is unsupported" "unsupported" "${r}"

unset -f uname

# Cleanup
rm -f "${LOG_FILE}"

echo ""
echo "=== Results ==="
echo "Passed: ${PASS}"
echo "Failed: ${FAIL}"

[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
