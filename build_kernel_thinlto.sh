#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOBS="${JOBS:-4}"

"${ROOT_DIR}/scripts/integrate_sukisu.sh"
chmod +x "${ROOT_DIR}/scripts/integrate_sukisu.sh" 2>/dev/null || true

if [[ "${ROOT_DIR}" == *" "* ]]; then
  BUILD_ROOT="${BUILD_ROOT:-$(dirname "${ROOT_DIR}")/Kernel-A15-build}"
  mkdir -p "${BUILD_ROOT}/kernel_platform"
  rsync -a --delete --exclude out/ \
    --exclude msm-kernel/arch/arm64/boot/dts/vendor \
    "${ROOT_DIR}/kernel_platform/" "${BUILD_ROOT}/kernel_platform/"
else
  BUILD_ROOT="${BUILD_ROOT:-${ROOT_DIR}}"
fi

KP_DIR="${BUILD_ROOT}/kernel_platform"
TOOLCHAIN_DIR="${KP_DIR}/prebuilts/clang/host/linux-x86/clang-r450784e"
export PATH="${TOOLCHAIN_DIR}/bin:${KP_DIR}/local-tools:${PATH}"
DTS_DIR="${KP_DIR}/msm-kernel/arch/arm64/boot/dts/vendor"

rm -rf "${DTS_DIR}"
mkdir -p "${DTS_DIR}"
rsync -aL --delete \
  "${KP_DIR}/qcom/proprietary/devicetree/" "${DTS_DIR}/"

if [[ ! -x "${TOOLCHAIN_DIR}/bin/clang" ]]; then
  echo "Toolchain ausente: ${TOOLCHAIN_DIR}" >&2
  echo "Execute o download/preparo da toolchain antes de compilar." >&2
  exit 1
fi

cd "${KP_DIR}"

export BUILD_CONFIG=build.config
export BUILD_CONFIG_FRAGMENTS=build.config.local
export TARGET_BUILD_VARIANT=user
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1735689600}"
export OUT_DIR="${OUT_DIR:-${BUILD_ROOT}/out/kernel-m269-thinlto}"
export LTO=thin
export FAST_BUILD="${FAST_BUILD:-1}"
export SKIP_MRPROPER="${SKIP_MRPROPER:-1}"

OUT_DTS_DIR="${OUT_DIR}/msm-kernel/arch/arm64/boot/dts/vendor"
rm -rf "${OUT_DTS_DIR}"
mkdir -p "$(dirname "${OUT_DTS_DIR}")"
ln -s "${DTS_DIR}" "${OUT_DTS_DIR}"

./build/build.sh -j"${JOBS}"

if [[ "${BUILD_ROOT}" != "${ROOT_DIR}" ]]; then
  mkdir -p "${ROOT_DIR}/out/kernel-m269-thinlto/dist"
  rsync -a "${OUT_DIR}/dist/" "${ROOT_DIR}/out/kernel-m269-thinlto/dist/"
fi

ln -sfn "${ROOT_DIR}/vendor" "${BUILD_ROOT}/vendor"
if [[ -x "${ROOT_DIR}/build_ext_modules.sh" ]]; then
  BUILD_ROOT="${BUILD_ROOT}" OUT_DIR="${OUT_DIR}" "${ROOT_DIR}/build_ext_modules.sh"
fi

for required_module in \
  "${ROOT_DIR}/out/kernel-m269-thinlto/dist/camera/camera.ko" \
  "${ROOT_DIR}/out/kernel-m269-thinlto/dist/graphics/msm_kgsl.ko"; do
  if [[ ! -s "${required_module}" ]]; then
    echo "ERRO: módulo custom obrigatório ausente: ${required_module}" >&2
    exit 1
  fi
done

STOCK_DIR="${STOCK_DIR:-${ROOT_DIR}/kernel_imgs/FILESKERNEL}"
if [[ -f "${STOCK_DIR}/boot.img" && -f "${STOCK_DIR}/vendor_boot.img" ]]; then
  echo "==> Gerando imagens flasháveis com pack_flash_images.sh"
  STOCK_DIR="${STOCK_DIR}" DIST_DIR="${ROOT_DIR}/out/kernel-m269-thinlto/dist" \
    PACK_OUT_DIR="${ROOT_DIR}/out/flash" \
    "${ROOT_DIR}/pack_flash_images.sh"
  echo "==> BLOQUEADOR: NÃO flashear até BUILD_SAFE + PACK_SAFE + FLASH_LAYOUT_SAFE."
  echo "    ./scripts/audit_kernel_release.sh   # BUILD_SAFE: SIM (mínimo)"
  echo "    ./scripts/audit_host_modules.sh"
  echo "    PULL=1 ./scripts/deploy_kernel_modules.sh"
  echo "    ./scripts/discover_flash_layout.sh"
  echo "    ./scripts/validate_modules_adb.sh"
else
  echo "==> Para gerar boot.img/vendor_boot.img, extraia do firmware atual e coloque em:"
  echo "    ${STOCK_DIR}/boot.img"
  echo "    ${STOCK_DIR}/vendor_boot.img"
  echo "    ${STOCK_DIR}/init_boot.img  (recomendado, header v4)"
  echo "    Depois execute: ./pack_flash_images.sh"
fi
