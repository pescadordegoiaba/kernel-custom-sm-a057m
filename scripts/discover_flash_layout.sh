#!/usr/bin/env bash
# Descobre layout de partições DLKM / super no SM-A057M (via adb + su).
# Grava relatório em out/flash/flash_layout_report.txt (consumido por FLASH_LAYOUT_SAFE).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLASH_OUT="${FLASH_OUT:-${ROOT_DIR}/out/flash}"
REPORT="${FLASH_OUT}/flash_layout_report.txt"

if ! command -v adb >/dev/null; then
  echo "adb não encontrado." >&2
  exit 1
fi

adb get-state >/dev/null 2>&1 || { echo "Dispositivo offline." >&2; exit 1; }

mkdir -p "${FLASH_OUT}"
: > "${REPORT}"

log() {
  echo "$*"
  echo "$*" >> "${REPORT}"
}

shell_uid="$(adb shell id -u 2>/dev/null | tr -d '\r' || true)"
if [[ "${shell_uid}" == "0" ]]; then
  run_su() { adb shell "$*" 2>/dev/null; }
else
  run_su() { adb shell "su -c '$*'" 2>/dev/null; }
fi

bootconfig_value() {
  local key="$1"
  awk -F= -v k="${key}" '
    $1 ~ "^[[:space:]]*" k "[[:space:]]*$" {
      v=$2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      gsub(/^"|"$/, "", v)
      print v
      exit
    }' <<< "${BOOTCONFIG_TEXT:-}"
}

avb_key_sha1() {
  local image="$1"
  avbtool info_image --image "${image}" 2>/dev/null |
    awk -F: '/Public key \(sha1\):/ {
      sub(/^[[:space:]]*/, "", $2)
      print $2
      exit
    }'
}

resolve_part() {
  local part="$1"
  run_su "
    slot=\$(getprop ro.boot.slot_suffix)
    if [ -n \"\$slot\" ] && [ -e /dev/block/by-name/${part}\$slot ]; then
      readlink -f /dev/block/by-name/${part}\$slot
      exit
    fi
    if [ -e /dev/block/by-name/${part} ]; then
      readlink -f /dev/block/by-name/${part}
      exit
    fi
    if [ -e /dev/block/mapper/${part}\$slot ]; then
      readlink -f /dev/block/mapper/${part}\$slot
      exit
    fi
    if [ -e /dev/block/mapper/${part} ]; then
      readlink -f /dev/block/mapper/${part}
    fi
  " | tr -d '\r' | head -1
}

section() {
  log ""
  log "=== $* ==="
}

section "Identificação"
log "$(adb shell getprop ro.product.model | tr -d '\r')"
log "$(adb shell getprop ro.build.fingerprint | tr -d '\r')"
slot="$(adb shell getprop ro.boot.slot_suffix | tr -d '\r')"
[[ -n "${slot}" ]] || slot="NONE"
log "SLOT_SUFFIX: ${slot}"

BOOTCONFIG_TEXT="$(run_su "cat /proc/bootconfig 2>/dev/null" | tr -d '\r' || true)"
flash_locked="$(adb shell getprop ro.boot.flash.locked | tr -d '\r')"
vbmeta_state="$(adb shell getprop ro.boot.vbmeta.device_state | tr -d '\r')"
vendor_vbmeta_state="$(adb shell getprop vendor.boot.vbmeta.device_state | tr -d '\r')"
verified_state="$(adb shell getprop ro.boot.verifiedbootstate | tr -d '\r')"
warranty_bit="$(adb shell getprop ro.boot.warranty_bit | tr -d '\r')"
bc_verified_state="$(bootconfig_value androidboot.verifiedbootstate)"
bc_ulcnt="$(bootconfig_value androidboot.ulcnt)"
bc_warranty_bit="$(bootconfig_value androidboot.warranty_bit)"
log "ro.boot.flash.locked: ${flash_locked:-n/a}"
log "ro.boot.vbmeta.device_state: ${vbmeta_state:-n/a}"
log "vendor.boot.vbmeta.device_state: ${vendor_vbmeta_state:-n/a}"
log "ro.boot.verifiedbootstate: ${verified_state:-n/a}"
log "ro.boot.warranty_bit: ${warranty_bit:-n/a}"
log "bootconfig.androidboot.verifiedbootstate: ${bc_verified_state:-n/a}"
log "bootconfig.androidboot.ulcnt: ${bc_ulcnt:-n/a}"
log "bootconfig.androidboot.warranty_bit: ${bc_warranty_bit:-n/a}"
if [[ "${flash_locked}" == "0" || "${vbmeta_state}" == "unlocked" ||
      "${vendor_vbmeta_state}" == "unlocked" || "${verified_state}" == "orange" ||
      "${bc_verified_state}" == "orange" || "${bc_ulcnt}" == "1" ||
      "${bc_warranty_bit}" == "1" || "${warranty_bit}" == "1" ]]; then
  bootloader_unlocked="SIM"
  if [[ "${bc_verified_state}" == "orange" || "${bc_ulcnt}" == "1" ||
        "${bc_warranty_bit}" == "1" ]]; then
    bootloader_unlock_source="bootconfig"
  else
    bootloader_unlock_source="getprop"
  fi
elif [[ "${flash_locked}" == "1" && "${vbmeta_state}" == "locked" &&
        "${vendor_vbmeta_state:-locked}" == "locked" &&
        "${verified_state}" == "green" && "${bc_verified_state:-green}" == "green" &&
        "${bc_ulcnt:-0}" == "0" && "${bc_warranty_bit:-0}" == "0" &&
        "${warranty_bit:-0}" == "0" ]]; then
  bootloader_unlocked="NÃO"
  bootloader_unlock_source="locked_signals"
else
  bootloader_unlocked="NÃO CONFIRMADO"
  bootloader_unlock_source="inconclusivo"
fi
log "BOOTLOADER_UNLOCKED: ${bootloader_unlocked}"
log "BOOTLOADER_UNLOCK_SOURCE: ${bootloader_unlock_source}"

section "Partições by-name / mapper (dlkm / boot / super)"
run_su "ls -l /dev/block/by-name" | grep -iE 'dlkm|boot|super|vendor' | tee -a "${REPORT}" || true
run_su "ls -l /dev/block/mapper" | grep -iE 'dlkm|boot|super|vendor' | tee -a "${REPORT}" || true

section "Tamanhos de partição (bytes)"
sizes_valid="SIM"
dd_blocks_writable="SIM"
for part in boot vendor_boot vendor_dlkm init_boot; do
  block="$(resolve_part "${part}")"
  sz="" ro=""
  [[ -n "${block}" ]] && \
    sz="$(run_su "blockdev --getsize64 ${block} 2>/dev/null" | tr -d '\r' || true)"
  [[ -n "${block}" ]] && \
    ro="$(run_su "blockdev --getro ${block} 2>/dev/null" | tr -d '\r' || true)"
  log "${part}_block: ${block:-n/a}"
  log "${part}_partition_size: ${sz:-n/a}"
  log "${part}_read_only: ${ro:-n/a}"
  if [[ "${part}" != "init_boot" && "${ro}" != "0" ]]; then
    dd_blocks_writable="NÃO"
  fi
  custom="${FLASH_OUT}/${part}.img"
  if [[ "${part}" != "init_boot" ]]; then
    if [[ -f "${custom}" && -n "${sz}" ]]; then
      image_size="$(stat -c '%s' "${custom}")"
      log "${part}_image_size: ${image_size}"
      if (( image_size > sz )); then
        log "${part}_size_check: FALHA"
        sizes_valid="NÃO"
      else
        log "${part}_size_check: OK"
      fi
    else
      log "${part}_size_check: PENDENTE"
      sizes_valid="NÃO"
    fi
  fi
done
log "PARTITION_SIZES_VALID: ${sizes_valid}"

vendor_dlkm_block="$(resolve_part vendor_dlkm)"
if [[ -n "${vendor_dlkm_block}" ]]; then
  log "VENDOR_DLKM_PRESENT: SIM"
else
  log "VENDOR_DLKM_PRESENT: NÃO"
fi

section "lpdump (dynamic partitions)"
run_su "lpdump 2>/dev/null" | grep -iE 'vendor_dlkm|odm_dlkm|super|slot' | tee -a "${REPORT}" || \
  log "lpdump indisponível ou sem permissão"

section "Montagens relevantes"
run_su "mount | grep -iE 'dlkm|vendor|by-name'" | tee -a "${REPORT}" || true
vendor_dlkm_mount="$(run_su "grep -E \"[[:space:]]/vendor_dlkm[[:space:]]\" /proc/mounts" |
  tr -d '\r' || true)"
if [[ -n "${vendor_dlkm_mount}" ]]; then
  log "VENDOR_DLKM_MOUNTED: SIM"
  vendor_dlkm_unmounted="NÃO"
else
  log "VENDOR_DLKM_MOUNTED: NÃO"
  vendor_dlkm_unmounted="SIM"
fi
if [[ "${sizes_valid}" == "SIM" && "${dd_blocks_writable}" == "SIM" &&
      "${vendor_dlkm_unmounted}" == "SIM" &&
      "${bootloader_unlocked}" == "SIM" ]]; then
  log "DD_FLASH_SAFE: SIM"
else
  log "DD_FLASH_SAFE: NÃO"
fi

section "Módulos no filesystem"
for ko in msm_kgsl camera cpu_hotplug; do
  log "--- ${ko} ---"
  run_su "find /vendor_dlkm /vendor /lib/modules -name '${ko}.ko' 2>/dev/null" | tee -a "${REPORT}" || true
done

section "AVB / vbmeta (indicativo)"
run_su "ls -l /dev/block/by-name | grep -i vbmeta" | tee -a "${REPORT}" || true
custom_boot_key="n/a"
custom_vendor_boot_key="n/a"
custom_vendor_dlkm_key="n/a"
stock_boot_key="n/a"
stock_vendor_boot_key="n/a"
stock_vendor_dlkm_key="n/a"
if command -v avbtool >/dev/null; then
  for part in boot vendor_boot vendor_dlkm; do
    stock_image="${ROOT_DIR}/kernel_imgs/FILESKERNEL/${part}.img"
    if [[ "${part}" == "vendor_dlkm" && ! -f "${stock_image}" &&
          -f "${ROOT_DIR}/vendor_dlkm/vendor_dlkm.img" ]]; then
      stock_image="${ROOT_DIR}/vendor_dlkm/vendor_dlkm.img"
    fi
    custom_image="${FLASH_OUT}/${part}.img"
    stock_key="n/a"
    custom_key="n/a"
    [[ -f "${stock_image}" ]] && stock_key="$(avb_key_sha1 "${stock_image}")"
    [[ -f "${custom_image}" ]] && custom_key="$(avb_key_sha1 "${custom_image}")"
    log "${part}_stock_avb_key_sha1: ${stock_key:-n/a}"
    log "${part}_custom_avb_key_sha1: ${custom_key:-n/a}"
    if [[ -n "${stock_key}" && -n "${custom_key}" && "${stock_key}" == "${custom_key}" ]]; then
      log "${part}_avb_key_matches_stock: SIM"
    elif [[ -n "${stock_key}" && -n "${custom_key}" ]]; then
      log "${part}_avb_key_matches_stock: NÃO"
    else
      log "${part}_avb_key_matches_stock: PENDENTE"
    fi
    case "${part}" in
      boot)
        custom_boot_key="${custom_key:-n/a}"
        stock_boot_key="${stock_key:-n/a}"
        ;;
      vendor_boot)
        custom_vendor_boot_key="${custom_key:-n/a}"
        stock_vendor_boot_key="${stock_key:-n/a}"
        ;;
      vendor_dlkm)
        custom_vendor_dlkm_key="${custom_key:-n/a}"
        stock_vendor_dlkm_key="${stock_key:-n/a}"
        ;;
    esac
  done
fi
if [[ "${custom_boot_key}" != "n/a" && "${stock_boot_key}" != "n/a" &&
      "${custom_boot_key}" != "${stock_boot_key}" &&
      "${custom_vendor_boot_key}" != "n/a" &&
      "${stock_vendor_boot_key}" != "n/a" &&
      "${custom_vendor_boot_key}" != "${stock_vendor_boot_key}" ]]; then
  boot_vendor_avb_mode="BOOT_VENDOR_BOOT_CUSTOM_KEY"
else
  boot_vendor_avb_mode="BOOT_VENDOR_BOOT_STOCK_OR_UNKNOWN_KEY"
fi
if [[ "${custom_vendor_dlkm_key}" != "n/a" && "${stock_vendor_dlkm_key}" != "n/a" &&
      "${custom_vendor_dlkm_key}" != "${stock_vendor_dlkm_key}" ]]; then
  dlkm_avb_mode="VENDOR_DLKM_CUSTOM_KEY"
else
  dlkm_avb_mode="VENDOR_DLKM_STOCK_OR_UNKNOWN_KEY"
fi
log "CUSTOM_AVB_MODE: ${boot_vendor_avb_mode}; ${dlkm_avb_mode}"

section "Aviso de flash"
cat <<'EOF' | tee -a "${REPORT}"
NÃO execute fastboot flash vendor_dlkm antes de confirmar:
  1. Nome exato da partição (pode ser logical em super)
  2. Slot A/B ativo (ro.boot.slot_suffix)
  3. Modo fastbootd vs bootloader
  4. AVB / vbmeta para partições DLKM
  5. Tamanho real das imagens custom vs partição

Para dd, execute scripts/flash_via_dd.sh primeiro sem FLASH_CONFIRM.
O script recusa vendor_dlkm montado e blocos somente leitura. Em partição
lógica/dynamic, use recovery com adb root ou fastbootd; não grave o DLKM
montado pelo Android em execução.
EOF

log ""
log "Relatório salvo: ${REPORT}"
log "Re-auditar: ./scripts/audit_kernel_release.sh  (FLASH_LAYOUT_SAFE)"
