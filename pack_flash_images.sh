#!/usr/bin/env bash
# Repack stock boot/vendor_boot images with the kernel built by build_kernel_thinlto.sh.
#
# Requires boot.img and vendor_boot.img extracted from the phone's current firmware
# (same Android version / build as the device you will flash).
#
# Usage:
#   STOCK_DIR=./stock_images ./pack_flash_images.sh
#
# Output:
#   out/flash/boot.img
#   out/flash/vendor_boot.img
#   out/flash/init_boot.img  (copied from stock when present)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STOCK_DIR="${STOCK_DIR:-${ROOT_DIR}/kernel_imgs/FILESKERNEL}"
DIST_DIR="${DIST_DIR:-${ROOT_DIR}/out/kernel-m269-thinlto/dist}"
PACK_OUT_DIR="${PACK_OUT_DIR:-${FLASH_OUT:-${ROOT_DIR}/out/flash}}"
MKBOOTIMG="${MKBOOTIMG:-${ROOT_DIR}/kernel_platform/tools/mkbootimg/mkbootimg.py}"
UNPACK="${UNPACK:-${ROOT_DIR}/kernel_platform/tools/mkbootimg/unpack_bootimg.py}"
DTB_MODE="${DTB_MODE:-stock}"

# shellcheck source=scripts/lib/avb_util.sh
source "${ROOT_DIR}/scripts/lib/avb_util.sh"

require_file() {
  if [[ ! -f "$1" ]]; then
    echo "Arquivo obrigatório ausente: $1" >&2
    exit 1
  fi
}

require_file "${DIST_DIR}/Image"
require_file "${STOCK_DIR}/boot.img"
require_file "${STOCK_DIR}/vendor_boot.img"

mkdir -p "${PACK_OUT_DIR}"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

assert_clean_stock_boot_reference() {
  local stock_boot="$1"
  local unpack_dir="${WORK}/stock_boot_reference"
  local cfg="${WORK}/stock_boot_reference.config"
  local extract_ikconfig="${ROOT_DIR}/kernel_platform/common/scripts/extract-ikconfig"

  rm -rf "${unpack_dir}"
  mkdir -p "${unpack_dir}"
  python3 "${UNPACK}" --boot_img "${stock_boot}" --out "${unpack_dir}" >/dev/null

  if [[ ! -x "${extract_ikconfig}" || ! -f "${unpack_dir}/kernel" ]]; then
    echo "    aviso: não foi possível auditar IKCONFIG do boot.img de referência"
    return 0
  fi

  if ! "${extract_ikconfig}" "${unpack_dir}/kernel" > "${cfg}" 2>/dev/null; then
    echo "    aviso: boot.img de referência sem IKCONFIG extraível"
    return 0
  fi

  if grep -Eq '^CONFIG_(KSU|KPM|KSU_SUSFS)=' "${cfg}"; then
    if [[ "${ALLOW_CUSTOM_STOCK_BOOT_REF:-0}" == "1" ]]; then
      echo "    AVISO: boot.img de referência contém KSU/KPM/SUSFS; override experimental ativo"
      grep -E '^CONFIG_(KSU|KPM|KSU_SUSFS)=' "${cfg}" | sed 's/^/      /'
      return 0
    fi
    echo "ERRO: ${stock_boot} não parece ser stock limpo; contém KSU/KPM/SUSFS:" >&2
    grep -E '^CONFIG_(KSU|KPM|KSU_SUSFS)=' "${cfg}" >&2
    echo "Use imagens oficiais do firmware em kernel_imgs/FILESKERNEL/ ou defina ALLOW_CUSTOM_STOCK_BOOT_REF=1 apenas para diagnóstico." >&2
    exit 1
  fi
}

assert_clean_stock_boot_reference "${STOCK_DIR}/boot.img"

case "${DTB_MODE}" in
  stock)
    echo "==> DTB: preservando o blob stock do firmware"
    ;;
  custom)
    CUSTOM_DTB_IMG="${CUSTOM_DTB_IMG:-${ROOT_DIR}/out/dtb}"
    require_file "${CUSTOM_DTB_IMG}"
    cp -p "${CUSTOM_DTB_IMG}" "${WORK}/dtb.img"
    echo "==> DTB: usando blob custom explícito (${CUSTOM_DTB_IMG})"
    ;;
  *)
    echo "DTB_MODE inválido: ${DTB_MODE} (use stock ou custom)" >&2
    exit 1
    ;;
esac

pack_boot_image() {
  local stock="$1"
  local output="$2"
  local kernel="$3"
  local unpack_dir="${WORK}/$(basename "${stock}" .img)"
  local args_file="${WORK}/$(basename "${stock}" .img).args"

  rm -rf "${unpack_dir}"
  mkdir -p "${unpack_dir}"

  python3 "${UNPACK}" --boot_img "${stock}" --out "${unpack_dir}" --format=mkbootimg -0 > "${args_file}"

  declare -a mkbootimg_args=()
  while IFS= read -r -d '' arg; do
    mkbootimg_args+=("${arg}")
  done < "${args_file}"

  local replaced_kernel=0
  local -a final_args=()
  local i=0
  while (( i < ${#mkbootimg_args[@]} )); do
    if [[ "${mkbootimg_args[i]}" == "--kernel" ]]; then
      final_args+=("--kernel" "${kernel}")
      replaced_kernel=1
      i=$((i + 2))
      continue
    fi
    if [[ "${mkbootimg_args[i]}" == "--dtb" ]]; then
      if [[ "${DTB_MODE}" == "custom" ]]; then
        final_args+=("--dtb" "${WORK}/dtb.img")
      else
        final_args+=("${mkbootimg_args[i]}" "${mkbootimg_args[i + 1]}")
      fi
      i=$((i + 2))
      continue
    fi
    if [[ "${mkbootimg_args[i]}" == "--output" || "${mkbootimg_args[i]}" == "-o" ]]; then
      i=$((i + 2))
      continue
    fi
    if [[ "${mkbootimg_args[i]}" == "--vendor_boot" ]]; then
      i=$((i + 2))
      continue
    fi
    final_args+=("${mkbootimg_args[i]}")
    i=$((i + 1))
  done

  if [[ "${stock}" == *vendor_boot* ]]; then
    if [[ -f "${DIST_DIR}/initramfs.img" ]]; then
      local replaced_fragment=0
      local -a vendor_args=()
      local j=0
      local pending_dlkm=0
      while (( j < ${#final_args[@]} )); do
        if [[ "${final_args[j]}" == "--ramdisk_type" ]]; then
          vendor_args+=("${final_args[j]}" "${final_args[j + 1]}")
          pending_dlkm=0
          if [[ "${final_args[j + 1]}" == "3" ]]; then
            pending_dlkm=1
          fi
          j=$((j + 2))
          continue
        fi
        if [[ "${final_args[j]}" == "--vendor_ramdisk_fragment" ]]; then
          if [[ "${pending_dlkm}" -eq 1 && "${replaced_fragment}" -eq 0 ]]; then
            vendor_args+=("--vendor_ramdisk_fragment" "${DIST_DIR}/initramfs.img")
            replaced_fragment=1
            pending_dlkm=0
          else
            vendor_args+=("${final_args[j]}" "${final_args[j + 1]}")
          fi
          j=$((j + 2))
          continue
        fi
        vendor_args+=("${final_args[j]}")
        j=$((j + 1))
      done
      final_args=("${vendor_args[@]}")
      if [[ "${replaced_fragment}" -eq 1 ]]; then
        echo "    substituindo fragmento DLKM por ${DIST_DIR}/initramfs.img"
      else
        echo "    aviso: initramfs.img presente, mas nenhum fragmento DLKM no vendor_boot stock"
      fi
    fi
    python3 "${MKBOOTIMG}" "${final_args[@]}" --vendor_boot "${output}"
    avb_add_footer_like_stock "${stock}" "${output}" vendor_boot
  else
    if [[ "${replaced_kernel}" -ne 1 ]]; then
      final_args+=("--kernel" "${kernel}")
    fi
    python3 "${MKBOOTIMG}" "${final_args[@]}" --output "${output}"
    avb_add_footer_like_stock "${stock}" "${output}" boot
  fi
}

echo "==> Empacotando boot.img"
pack_boot_image "${STOCK_DIR}/boot.img" "${PACK_OUT_DIR}/boot.img" "${DIST_DIR}/Image"

echo "==> Empacotando vendor_boot.img"
pack_boot_image "${STOCK_DIR}/vendor_boot.img" "${PACK_OUT_DIR}/vendor_boot.img" "${DIST_DIR}/Image"

if [[ -f "${STOCK_DIR}/init_boot.img" ]]; then
  cp -p "${STOCK_DIR}/init_boot.img" "${PACK_OUT_DIR}/init_boot.img"
  echo "==> init_boot.img stock copiado como artefato de recuperação (header v4)"
  echo "    Não reflashear em atualização normal — só se a partição estiver corrompida."
fi

echo
echo "Imagens prontas em ${PACK_OUT_DIR}:"
ls -lah "${PACK_OUT_DIR}/"*.img
echo
echo "BLOQUEADOR: NÃO flashear boot.img, vendor_boot.img ou vendor_dlkm.img até"
echo "  ./scripts/audit_kernel_release.sh retornar BUILD_SAFE: SIM (+ PACK + layout para flash)"
