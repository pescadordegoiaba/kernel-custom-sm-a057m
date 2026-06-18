#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGES_DIR="${IMAGES_DIR:-${ROOT_DIR}/out/release}"
BACKUP_ROOT="${BACKUP_ROOT:-${ROOT_DIR}/out/device-backup}"
REMOTE_DIR="${REMOTE_DIR:-/data/local/tmp/kernel-custom-dd}"
EXPECTED_MODEL="${EXPECTED_MODEL:-SM-A057M}"
EXPECTED_FIRMWARE="${EXPECTED_FIRMWARE:-A057MUBSADYG1}"
CONFIRM_TOKEN="SM-A057M-DD-FLASH"
REPORT="${ROOT_DIR}/out/flash/dd_flash_report.txt"
PARTITIONS=(boot vendor_boot vendor_dlkm)

declare -A BLOCK_PATH
declare -A PART_SIZE
declare -A IMAGE_SIZE
declare -A IMAGE_SHA

die() {
  echo "ERRO: $*" >&2
  exit 1
}

log() {
  echo "$*"
  echo "$*" >> "${REPORT}"
}

require_command() {
  command -v "$1" >/dev/null || die "Comando ausente: $1"
}

root_mode=""
root_cmd() {
  local command="$1"
  case "${root_mode}" in
    direct) adb shell "${command}" 2>/dev/null ;;
    su) adb shell "su -c '${command}'" 2>/dev/null ;;
    *) die "Modo root não inicializado" ;;
  esac
}

root_exec_out() {
  local command="$1"
  case "${root_mode}" in
    direct) adb exec-out "${command}" ;;
    su) adb exec-out "su -c '${command}'" ;;
    *) die "Modo root não inicializado" ;;
  esac
}

device_prop() {
  adb shell "getprop $1" 2>/dev/null | tr -d '\r'
}

resolve_part() {
  local part="$1"
  root_cmd "
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

init_root() {
  local uid
  uid="$(adb shell id -u 2>/dev/null | tr -d '\r' || true)"
  if [[ "${uid}" == "0" ]]; then
    root_mode="direct"
    return
  fi
  uid="$(adb shell "su -c 'id -u'" 2>/dev/null | tr -d '\r' || true)"
  [[ "${uid}" == "0" ]] || die "Root indisponível no shell adb."
  root_mode="su"
}

validate_local_images() {
  local part image
  for part in "${PARTITIONS[@]}"; do
    image="${IMAGES_DIR}/${part}.img"
    [[ -f "${image}" ]] || die "Imagem ausente: ${image}"
    IMAGE_SIZE["${part}"]="$(stat -c '%s' "${image}")"
    IMAGE_SHA["${part}"]="$(sha256sum "${image}" | awk '{print $1}')"
  done

  avbtool info_image --image "${IMAGES_DIR}/boot.img" >/dev/null ||
    die "boot.img sem AVB válido"
  avbtool info_image --image "${IMAGES_DIR}/vendor_boot.img" >/dev/null ||
    die "vendor_boot.img sem AVB válido"
  avbtool info_image --image "${IMAGES_DIR}/vendor_dlkm.img" |
    grep -q 'Hashtree descriptor:' ||
    die "vendor_dlkm.img sem AVB hashtree"
  avbtool verify_image --image "${IMAGES_DIR}/vendor_dlkm.img" >/dev/null ||
    die "vendor_dlkm.img falhou na verificação AVB/hashtree"
  fsck.erofs "${IMAGES_DIR}/vendor_dlkm.img" >/dev/null ||
    die "vendor_dlkm.img falhou na verificação EROFS"
}

validate_device_identity() {
  local model fingerprint firmware
  model="$(device_prop ro.product.model)"
  fingerprint="$(device_prop ro.build.fingerprint)"
  firmware="$(device_prop ro.build.version.incremental)"

  log "Modelo: ${model:-n/a}"
  log "Firmware: ${firmware:-n/a}"
  log "Fingerprint: ${fingerprint:-n/a}"

  [[ "${model}" == "${EXPECTED_MODEL}" ]] ||
    die "Modelo divergente: ${model:-n/a}; esperado ${EXPECTED_MODEL}"
  if [[ "${firmware}" != "${EXPECTED_FIRMWARE}" &&
        "${fingerprint}" != *"/${EXPECTED_FIRMWARE}:"* ]]; then
    [[ "${ALLOW_FIRMWARE_MISMATCH:-0}" == "1" ]] ||
      die "Firmware divergente; esperado ${EXPECTED_FIRMWARE}"
    log "AVISO: firmware divergente autorizado."
  fi
}

validate_boot_state() {
  local locked device_state verified
  locked="$(device_prop ro.boot.flash.locked)"
  device_state="$(device_prop ro.boot.vbmeta.device_state)"
  verified="$(device_prop ro.boot.verifiedbootstate)"
  log "ro.boot.flash.locked: ${locked:-n/a}"
  log "ro.boot.vbmeta.device_state: ${device_state:-n/a}"
  log "ro.boot.verifiedbootstate: ${verified:-n/a}"

  if [[ "${locked}" != "0" && "${device_state}" != "unlocked" &&
        "${verified}" != "orange" ]]; then
    die "Bootloader desbloqueado/estado AVB permissivo não confirmado."
  fi
}

validate_partition_layout() {
  local part block size ro image_size mount_info
  for part in "${PARTITIONS[@]}"; do
    block="$(resolve_part "${part}")"
    [[ -n "${block}" ]] || die "Partição ${part} não encontrada."
    size="$(root_cmd "blockdev --getsize64 ${block}" | tr -d '\r')"
    ro="$(root_cmd "blockdev --getro ${block}" | tr -d '\r')"
    image_size="${IMAGE_SIZE[${part}]}"

    BLOCK_PATH["${part}"]="${block}"
    PART_SIZE["${part}"]="${size}"
    log "${part}: block=${block} partition=${size} image=${image_size} ro=${ro}"

    [[ "${size}" =~ ^[0-9]+$ ]] || die "Tamanho inválido para ${part}"
    [[ "${image_size}" -eq "${size}" ]] ||
      die "${part}: imagem deve ter exatamente o tamanho da partição"
    [[ "${ro}" == "0" ]] ||
      die "${part}: bloco somente leitura; use recovery/fastbootd apropriado"
  done

  mount_info="$(root_cmd "grep -E \"[[:space:]]/vendor_dlkm[[:space:]]\" /proc/mounts" |
    tr -d '\r' || true)"
  if [[ -n "${mount_info}" ]]; then
    log "vendor_dlkm montado: ${mount_info}"
    die "vendor_dlkm está montado. Reinicie em recovery antes do dd."
  fi

  if [[ "${BLOCK_PATH[vendor_dlkm]}" == /dev/block/dm-* ||
        "${BLOCK_PATH[vendor_dlkm]}" == /dev/block/mapper/* ]]; then
    log "vendor_dlkm é partição lógica/dm: ${BLOCK_PATH[vendor_dlkm]}"
  fi
}

check_remote_space() {
  local total=0 line available_kb required_kb part
  for part in "${PARTITIONS[@]}"; do
    total=$((total + IMAGE_SIZE[${part}]))
  done
  line="$(root_cmd "df -k /data | tail -1" | tr -d '\r')"
  available_kb="$(awk '{print $4}' <<< "${line}")"
  required_kb=$(((total + 268435456) / 1024))
  [[ "${available_kb}" =~ ^[0-9]+$ ]] || die "Não foi possível medir espaço em /data"
  (( available_kb >= required_kb )) ||
    die "Espaço insuficiente em /data: ${available_kb} KiB; necessário ${required_kb} KiB"
}

backup_partitions() {
  local backup_dir="$1" part block output size
  mkdir -p "${backup_dir}"
  for part in "${PARTITIONS[@]}"; do
    block="${BLOCK_PATH[${part}]}"
    output="${backup_dir}/${part}.img"
    log "Backup ${part} -> ${output}"
    root_exec_out "dd if=${block} bs=4194304 2>/dev/null" > "${output}"
    size="$(stat -c '%s' "${output}")"
    [[ "${size}" -eq "${PART_SIZE[${part}]}" ]] ||
      die "Backup ${part} incompleto: ${size}/${PART_SIZE[${part}]}"
  done
  (
    cd "${backup_dir}"
    sha256sum boot.img vendor_boot.img vendor_dlkm.img > SHA256SUMS
  )
}

stage_images() {
  local part image remote remote_sha
  root_cmd "rm -rf ${REMOTE_DIR} && mkdir -p ${REMOTE_DIR} && chmod 777 ${REMOTE_DIR}"
  for part in "${PARTITIONS[@]}"; do
    image="${IMAGES_DIR}/${part}.img"
    remote="${REMOTE_DIR}/${part}.img"
    log "Staging ${part}.img"
    adb push "${image}" "${remote}" >/dev/null
    remote_sha="$(root_cmd "sha256sum ${remote}" | awk '{print $1}' | tr -d '\r')"
    [[ "${remote_sha}" == "${IMAGE_SHA[${part}]}" ]] ||
      die "SHA-256 divergente no staging de ${part}"
  done
}

flash_partitions() {
  local part block remote actual_sha
  for part in "${PARTITIONS[@]}"; do
    block="${BLOCK_PATH[${part}]}"
    remote="${REMOTE_DIR}/${part}.img"
    log "Gravando ${part}: ${remote} -> ${block}"
    root_cmd "dd if=${remote} of=${block} bs=4194304 2>/dev/null && sync && blockdev --flushbufs ${block}"
    actual_sha="$(root_cmd "sha256sum ${block}" | awk '{print $1}' | tr -d '\r')"
    [[ "${actual_sha}" == "${IMAGE_SHA[${part}]}" ]] ||
      die "Verificação pós-dd falhou em ${part}"
    log "${part}: SHA-256 pós-dd OK"
  done
  root_cmd "rm -rf ${REMOTE_DIR}"
}

main() {
  require_command adb
  require_command avbtool
  require_command fsck.erofs
  require_command sha256sum
  adb get-state >/dev/null 2>&1 || die "Dispositivo adb offline."

  mkdir -p "$(dirname "${REPORT}")"
  : > "${REPORT}"
  log "Flash dd SM-A057M — $(date -Iseconds)"

  init_root
  validate_local_images
  validate_device_identity
  validate_boot_state
  validate_partition_layout

  log "PREFLIGHT_DD_SAFE: SIM"
  if [[ "${FLASH_CONFIRM:-}" != "${CONFIRM_TOKEN}" ]]; then
    log "DRY RUN concluído; nenhuma partição foi modificada."
    log "Para gravar: FLASH_CONFIRM=${CONFIRM_TOKEN} $0"
    exit 0
  fi

  check_remote_space
  backup_dir="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
  backup_partitions "${backup_dir}"
  stage_images
  flash_partitions

  log "DD_FLASH_COMPLETE: SIM"
  log "Backup stock/current: ${backup_dir}"
  log "Reinicie e execute: ./scripts/validate_modules_adb.sh"
  if [[ "${REBOOT_AFTER:-0}" == "1" ]]; then
    adb reboot
  fi
}

main "$@"
