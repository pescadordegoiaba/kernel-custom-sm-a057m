#!/usr/bin/env bash
# Build host-only vendor_dlkm isolation images. This script never flashes.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${ROOT_DIR}/out/diagnostic/vendor_dlkm"
STOCK_MODULES="${ROOT_DIR}/vendor_dlkm/extracted/lib/modules"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# shellcheck source=lib/module_prepare.sh
source "${ROOT_DIR}/scripts/lib/module_prepare.sh"

mkdir -p "${OUT_DIR}"
module_prepare_for_dlkm \
  "${STOCK_MODULES}/cpu_hotplug.ko" \
  "${STOCK_MODULES}/cpu_hotplug.ko" \
  "${WORK}/cpu_hotplug-stock-runtime.ko"

build_variant() {
  local name="$1" modules="$2"
  shift 2
  local target="${OUT_DIR}/${name}"
  rm -rf "${target}"
  mkdir -p "${target}"
  echo "==> ${name}: ${modules}"
  env \
    FLASH_OUT="${target}" \
    CUSTOM_VENDOR_DLKM_MODULES="${modules}" \
    "$@" \
    "${ROOT_DIR}/scripts/deploy_kernel_modules.sh" \
    >"${target}/build.log" 2>&1
  sha256sum "${target}/vendor_dlkm.img" > "${target}/SHA256SUM"
}

# Same stock runtime code; only DWARF is removed from cpu_hotplug to fit the
# stock partition after SELinux xattrs are encoded by the host mkfs.erofs.
build_variant \
  "00-control-stock-code" \
  "cpu_hotplug" \
  CUSTOM_CPU_HOTPLUG_SRC="${WORK}/cpu_hotplug-stock-runtime.ko"

build_variant "01-hotplug-only" "cpu_hotplug"
build_variant "02-kgsl-only" "msm_kgsl"

full="${OUT_DIR}/03-full"
rm -rf "${full}"
mkdir -p "${full}/prepared_modules"
cp --reflink=auto -p "${ROOT_DIR}/out/flash/vendor_dlkm.img" "${full}/vendor_dlkm.img"
cp -p "${ROOT_DIR}/out/flash/prepared_modules/"*.ko "${full}/prepared_modules/"
sha256sum "${full}/vendor_dlkm.img" > "${full}/SHA256SUM"

echo "Variantes geradas em ${OUT_DIR}"
