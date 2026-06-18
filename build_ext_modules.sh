#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOBS="${JOBS:-4}"

if [[ "${ROOT_DIR}" == *" "* ]]; then
  BUILD_ROOT="${BUILD_ROOT:-$(dirname "${ROOT_DIR}")/Kernel-A15-build}"
else
  BUILD_ROOT="${BUILD_ROOT:-${ROOT_DIR}}"
fi

KP_DIR="${BUILD_ROOT}/kernel_platform"
OUT_PARENT="${OUT_DIR:-${BUILD_ROOT}/out/kernel-m269-thinlto}"
KERNEL_KIT="${OUT_PARENT}/msm-kernel"
GKI_MIXED_TREE="${OUT_PARENT}/gki_kernel/dist"

if [[ ! -f "${KERNEL_KIT}/.config" || ! -f "${KERNEL_KIT}/Module.symvers" ]]; then
  echo "Kernel não compilado. Execute ./build_kernel_thinlto.sh primeiro." >&2
  exit 1
fi

VENDOR_DIR="${BUILD_ROOT}/vendor"
if [[ "${ROOT_DIR}" == *" "* ]]; then
  if [[ -L "${VENDOR_DIR}" || ! -d "${VENDOR_DIR}/qcom/opensource/camera-kernel" ]]; then
    echo "==> Copiando vendor/ para caminho sem espaços (${VENDOR_DIR})"
    rm -rf "${VENDOR_DIR}"
    mkdir -p "${VENDOR_DIR}"
    rsync -a "${ROOT_DIR}/vendor/" "${VENDOR_DIR}/"
  else
    echo "==> Sincronizando módulos externos (camera-kernel, graphics-kernel)"
    rsync -a "${ROOT_DIR}/vendor/qcom/opensource/camera-kernel/" \
      "${VENDOR_DIR}/qcom/opensource/camera-kernel/"
    rsync -a "${ROOT_DIR}/vendor/qcom/opensource/graphics-kernel/" \
      "${VENDOR_DIR}/qcom/opensource/graphics-kernel/"
  fi
  rsync -a "${ROOT_DIR}/kernel_platform/msm-kernel/drivers/thermal/qcom/cpu_hotplug.c" \
    "${BUILD_ROOT}/kernel_platform/msm-kernel/drivers/thermal/qcom/cpu_hotplug.c" 2>/dev/null || true
else
  ln -sfn "${ROOT_DIR}/vendor" "${VENDOR_DIR}"
fi

cd "${KP_DIR}"
export BUILD_CONFIG=build.config
export BUILD_CONFIG_FRAGMENTS=build.config.local
export OUT_DIR="${OUT_PARENT}"
export EXT_MODULES="../vendor/qcom/opensource/camera-kernel ../vendor/qcom/opensource/graphics-kernel"
export LOCALVERSION="${LOCALVERSION:--31192385}"
export BUILD_NUMBER="${BUILD_NUMBER:-A057MUBSADYG1}"
export PATH="${KP_DIR}/local-tools:${PATH}"

./build/build_module.sh -j"${JOBS}"

DIST="${ROOT_DIR}/out/kernel-m269-thinlto/dist"
mkdir -p "${DIST}/camera" "${DIST}/graphics"
rm -f "${DIST}/camera/camera.ko" "${DIST}/graphics/msm_kgsl.ko"

VENDOR_OUT="$(dirname "${OUT_PARENT}")/vendor"

CAMERA_KO="$(find "${OUT_PARENT}" "${VENDOR_OUT}" \
  -path '*/camera-kernel/camera.ko' -print -quit 2>/dev/null || true)"
KGSL_KO="$(find "${OUT_PARENT}" "${VENDOR_OUT}" \
  -path '*/graphics-kernel/msm_kgsl.ko' -print -quit 2>/dev/null || true)"

[[ -n "${CAMERA_KO}" && -s "${CAMERA_KO}" ]] || {
  echo "ERRO: camera.ko não foi produzido pelo build externo." >&2
  exit 1
}
[[ -n "${KGSL_KO}" && -s "${KGSL_KO}" ]] || {
  echo "ERRO: msm_kgsl.ko não foi produzido pelo build externo." >&2
  exit 1
}

cp -p "${CAMERA_KO}" "${DIST}/camera/camera.ko"
cp -p "${KGSL_KO}" "${DIST}/graphics/msm_kgsl.ko"

echo "==> Módulos externos copiados:"
ls -lah "${DIST}/camera/"*.ko 2>/dev/null | head -5 || echo "  (camera: nenhum .ko)"
ls -lah "${DIST}/graphics/"*.ko 2>/dev/null | head -5 || echo "  (graphics: nenhum .ko)"
