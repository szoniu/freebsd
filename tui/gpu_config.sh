#!/usr/bin/env bash
# tui/gpu_config.sh — GPU driver configuration (FreeBSD)
#
# Shows the GPU detected by detect_gpu() (lib/hardware.sh) and lets the user
# override the vendor when autodetection is wrong (e.g. an unknown vgapci id,
# or forcing "none" on a headless/serial box). On override we re-run
# _gpu_driver_for() so the dependent fields (GPU_KMOD / DRM_PKG / GPU_DRIVER /
# GPU_FW_FLAVORS) are re-derived consistently — these drive the `gpu` install
# phase: `pkg install ${DRM_PKG} ${GPU_FW_FLAVORS}` + `sysrc kld_list+=${GPU_KMOD}`.
#
# FreeBSD specifics (DESIGN.md graphics matrix):
#   - amdgpu/i915kms load via kld_list in rc.conf, NEVER loader.conf (early panic).
#   - AMD Phoenix (Radeon 780M / gfx1103) needs the six gpu-firmware-amd-kmod-*
#     flavors; a missing/wrong flavor PANICS the kernel at amdgpu attach.
#   - NVIDIA = nvidia-driver + nvidia-modeset, no DRM metaport, NO Wayland.
source "${LIB_DIR}/protection.sh"

screen_gpu_config() {
    local vendor="${GPU_VENDOR:-unknown}"
    local device="${GPU_DEVICE_NAME:-Unknown GPU}"

    # --- Build the detection summary shown before the override menu ---------
    local info_text=""
    if [[ "${HYBRID_GPU:-no}" == "yes" ]]; then
        info_text+="Hybrid GPU detected:\n"
        info_text+="  iGPU: ${IGPU_DEVICE_NAME:-unknown} (${IGPU_VENDOR:-unknown})\n"
        info_text+="  dGPU: ${DGPU_DEVICE_NAME:-unknown} (${DGPU_VENDOR:-unknown})\n\n"
        info_text+="Primary vendor: ${vendor}  (PCI id ${GPU_DEVICE_ID:-?})\n\n"
    else
        info_text+="Detected GPU: ${device}\n"
        info_text+="Vendor: ${vendor}  (PCI id ${GPU_DEVICE_ID:-?})\n\n"
    fi
    info_text+="Driver plan:\n"
    info_text+="  kld_list+=${GPU_KMOD:-none}   pkg: ${DRM_PKG:-none}\n"
    if [[ -n "${GPU_FW_FLAVORS:-}" ]]; then
        info_text+="  firmware: ${GPU_FW_FLAVORS}\n"
    fi
    info_text+="\n"
    case "${vendor}" in
        amd)
            info_text+="AMD: open amdgpu (drm-kmod). On Phoenix APUs the six\n"
            info_text+="gpu-firmware-amd-kmod flavors are mandatory — a wrong\n"
            info_text+="flavor panics the kernel at amdgpu load.\n" ;;
        intel)
            info_text+="Intel: open i915kms (drm-kmod). Note: discrete Arc panics.\n" ;;
        nvidia)
            info_text+="NVIDIA: nvidia-driver + nvidia-modeset. No Wayland support;\n"
            info_text+="modeset is asserted via loader.conf hw.nvidiadrm.modeset=1.\n" ;;
        *)
            info_text+="No supported GPU vendor detected — falling back to the\n"
            info_text+="drm-kmod metaport (framebuffer / generic KMS).\n" ;;
    esac
    dialog_msgbox "Detected Graphics" "${info_text}" || return "${TUI_BACK}"

    # --- Override radiolist. "auto" keeps the detected vendor untouched. -----
    # Preselect "auto" so a confirm keeps autodetection (incl. the hybrid split).
    local on_auto="on" on_amd="off" on_intel="off" on_nvidia="off" on_none="off"
    local choice
    choice=$(dialog_radiolist "GPU Vendor Override" \
        "auto"   "Keep detected vendor (${vendor})"          "${on_auto}" \
        "amd"    "AMD — amdgpu (drm-kmod + firmware flavors)" "${on_amd}" \
        "intel"  "Intel — i915kms (drm-kmod)"                 "${on_intel}" \
        "nvidia" "NVIDIA — nvidia-driver (no Wayland)"        "${on_nvidia}" \
        "none"   "None — generic drm-kmod / framebuffer"      "${on_none}") \
        || return "${TUI_BACK}"

    # Cancel/empty selection is treated as Back (wizard convention).
    if [[ -z "${choice}" ]]; then
        return "${TUI_BACK}"
    fi

    if [[ "${choice}" != "auto" ]]; then
        # User overrode the vendor: collapse any hybrid split (the override is a
        # single explicit vendor) and re-derive every dependent driver field so
        # GPU_KMOD / DRM_PKG / GPU_DRIVER / GPU_FW_FLAVORS stay consistent.
        GPU_VENDOR="${choice}"
        HYBRID_GPU="no"
        IGPU_VENDOR=""; IGPU_DEVICE_NAME=""
        DGPU_VENDOR=""; DGPU_DEVICE_NAME=""
        # _gpu_driver_for (lib/hardware.sh) sets GPU_KMOD/DRM_PKG/GPU_DRIVER/GPU_FW_FLAVORS.
        # device-id keys the AMD Phoenix firmware-flavor split; keep the detected id.
        _gpu_driver_for "${GPU_VENDOR}" "${GPU_DEVICE_ID:-}"

        # FreeBSD-specific gotchas worth surfacing at override time.
        if [[ "${GPU_VENDOR}" == "amd" && "${GPU_FW_FLAVORS}" == *gpu-firmware-amd-kmod-* ]]; then
            dialog_msgbox "AMD Phoenix firmware" \
"This AMD device needs the explicit gpu-firmware-amd-kmod flavors:\n\n${GPU_FW_FLAVORS}\n\nA missing or mismatched flavor panics the kernel when amdgpu attaches. The installer pins all six." \
                || true
        elif [[ "${GPU_VENDOR}" == "nvidia" ]]; then
            dialog_msgbox "NVIDIA on FreeBSD" \
"NVIDIA uses the proprietary nvidia-driver (kld nvidia-modeset). There is NO Wayland support on FreeBSD — plan on an X11 desktop. KMS is asserted via loader.conf hw.nvidiadrm.modeset=1." \
                || true
        fi
    fi

    export GPU_VENDOR GPU_DEVICE_ID GPU_DEVICE_NAME GPU_DRIVER
    export GPU_KMOD DRM_PKG GPU_FW_FLAVORS
    export HYBRID_GPU IGPU_VENDOR IGPU_DEVICE_NAME DGPU_VENDOR DGPU_DEVICE_NAME

    einfo "GPU: ${GPU_VENDOR} -> kmod=${GPU_KMOD:-none} pkg=${DRM_PKG:-none}"
    if [[ -n "${GPU_FW_FLAVORS:-}" ]]; then
        einfo "GPU firmware flavors: ${GPU_FW_FLAVORS}"
    fi
    if [[ "${HYBRID_GPU}" == "yes" ]]; then
        einfo "Hybrid GPU kept: iGPU=${IGPU_VENDOR} + dGPU=${DGPU_VENDOR}"
    fi
    return "${TUI_NEXT}"
}
