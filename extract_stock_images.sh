#!/usr/bin/env bash
# Pull boot/vendor_boot/init_boot partition images from a rooted phone via adb.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/kernel_imgs/FILESKERNEL}"

if ! command -v adb >/dev/null; then
  echo "adb não encontrado." >&2
  exit 1
fi

mkdir -p "${OUT_DIR}"

partition_path() {
  local name="$1"
  adb shell "su -c '
    if [ -e /dev/block/by-name/${name} ]; then
      readlink -f /dev/block/by-name/${name}
      exit
    fi
    slot=\$(getprop ro.boot.slot_suffix)
    if [ -n \"\$slot\" ] && [ -e /dev/block/by-name/${name}\$slot ]; then
      readlink -f /dev/block/by-name/${name}\$slot
    fi
  '" 2>/dev/null | tr -d '\r' | head -1
}

pull_partition() {
  local name="$1"
  local block
  block="$(partition_path "${name}")"
  [[ -n "${block}" ]] || {
    echo "Partição ${name} não encontrada (incluindo slot ativo)." >&2
    return 1
  }
  echo "==> Extraindo ${name} (${block})"
  adb exec-out "su -c 'dd if=${block} bs=4194304 2>/dev/null'" \
    > "${OUT_DIR}/${name}.img"
  [[ -s "${OUT_DIR}/${name}.img" ]] || {
    echo "Extração vazia: ${name}" >&2
    return 1
  }
}

pull_partition boot
pull_partition vendor_boot
pull_partition init_boot

if [[ -n "$(partition_path vendor_dlkm)" ]]; then
  pull_partition vendor_dlkm
else
  echo "AVISO: partição vendor_dlkm não encontrada em by-name/slot ativo"
fi

echo
echo "Imagens stock salvas em ${OUT_DIR}"
ls -lah "${OUT_DIR}/"*.img
