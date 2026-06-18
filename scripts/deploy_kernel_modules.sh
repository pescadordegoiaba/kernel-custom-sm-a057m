#!/usr/bin/env bash
# Repack vendor_boot (first-stage) + vendor_dlkm (second-stage) com modulos custom.
#
# Modulos custom de producao:
#   cpu_hotplug.ko  - first-stage e second-stage
#   msm_kgsl.ko     - second-stage
#   camera.ko       - second-stage, cam_perf_mode default-off
#
# Bloqueia deploy se BUILD_SAFE falhar (use ALLOW_VERMAGIC_MISMATCH=1 só em dev).
#
# Uso:
#   ./scripts/audit_kernel_release.sh
#   ./scripts/audit_host_modules.sh
#   PULL=1 ./scripts/deploy_kernel_modules.sh
#   ./scripts/discover_flash_layout.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/ramdisk_util.sh
source "${ROOT_DIR}/scripts/lib/ramdisk_util.sh"
# shellcheck source=lib/vermagic_check.sh
source "${ROOT_DIR}/scripts/lib/vermagic_check.sh"
# shellcheck source=lib/avb_util.sh
source "${ROOT_DIR}/scripts/lib/avb_util.sh"
# shellcheck source=lib/module_abi.sh
source "${ROOT_DIR}/scripts/lib/module_abi.sh"
# shellcheck source=lib/module_prepare.sh
source "${ROOT_DIR}/scripts/lib/module_prepare.sh"

if [[ "${ROOT_DIR}" == *" "* ]]; then
  BUILD_ROOT="${BUILD_ROOT:-$(dirname "${ROOT_DIR}")/Kernel-A15-build}"
else
  BUILD_ROOT="${BUILD_ROOT:-${ROOT_DIR}}"
fi
OUT_PARENT="${KERNEL_OUT:-${BUILD_ROOT}/out/kernel-m269-thinlto}"
DIST_DIR="${DIST_DIR:-${ROOT_DIR}/out/kernel-m269-thinlto/dist}"
STOCK_DIR="${STOCK_DIR:-${ROOT_DIR}/kernel_imgs/FILESKERNEL}"
FLASH_OUT="${FLASH_OUT:-${ROOT_DIR}/out/flash}"
WORK="$(mktemp -d)"
VERMAGIC_WORK_DIR="${WORK}"
trap 'rm -rf "${WORK}"' EXIT

MKBOOTIMG="${MKBOOTIMG:-${ROOT_DIR}/kernel_platform/tools/mkbootimg/mkbootimg.py}"
UNPACK="${UNPACK:-${ROOT_DIR}/kernel_platform/tools/mkbootimg/unpack_bootimg.py}"

declare -A CUSTOM_SRC=(
  [cpu_hotplug]="${CUSTOM_CPU_HOTPLUG_SRC:-${DIST_DIR}/cpu_hotplug.ko}"
  [msm_kgsl]="${CUSTOM_MSM_KGSL_SRC:-${DIST_DIR}/graphics/msm_kgsl.ko}"
  [camera]="${CUSTOM_CAMERA_SRC:-${DIST_DIR}/camera/camera.ko}"
)

DEFAULT_VENDOR_DLKM_IMG="${STOCK_DIR}/vendor_dlkm.img"
if [[ ! -f "${DEFAULT_VENDOR_DLKM_IMG}" &&
      -f "${ROOT_DIR}/vendor_dlkm/vendor_dlkm.img" ]]; then
  DEFAULT_VENDOR_DLKM_IMG="${ROOT_DIR}/vendor_dlkm/vendor_dlkm.img"
fi
VENDOR_DLKM_IMG="${VENDOR_DLKM_IMG:-${DEFAULT_VENDOR_DLKM_IMG}}"
VENDOR_BOOT_IMG="${VENDOR_BOOT_IMG:-${STOCK_DIR}/vendor_boot.img}"
REPORT="${FLASH_OUT}/module_deploy_report.txt"
CUSTOM_VENDOR_DLKM_MODULES="${CUSTOM_VENDOR_DLKM_MODULES-cpu_hotplug msm_kgsl camera}"

log() { echo "$*" | tee -a "${REPORT}"; }
log_err() { echo "$*" | tee -a "${REPORT}" >&2; }

require_file() { [[ -f "$1" ]] || { echo "Ausente: $1" >&2; exit 1; }; }

custom_vendor_dlkm_enabled() {
  local name="$1"
  [[ " ${CUSTOM_VENDOR_DLKM_MODULES} " == *" ${name} "* ]]
}

count_vendor_ramdisk_fragments() {
  local args_file="$1"
  local n=0
  [[ -f "${args_file}" ]] || { echo 0; return; }
  while IFS= read -r -d '' arg; do
    [[ "${arg}" == "--vendor_ramdisk_fragment" ]] && n=$((n + 1))
  done < "${args_file}"
  echo "${n}"
}

audit_vendor_boot_headers() {
  local stock="$1" custom="$2"
  local stock_u="${WORK}/hdr/stock" custom_u="${WORK}/hdr/custom"
  mkdir -p "${stock_u}" "${custom_u}"

  python3 "${UNPACK}" --boot_img "${stock}" --out "${stock_u}" --format=mkbootimg -0 \
    > "${stock_u}/args.txt" 2>/dev/null || true
  [[ -f "${custom}" ]] && python3 "${UNPACK}" --boot_img "${custom}" --out "${custom_u}" \
    --format=mkbootimg -0 > "${custom_u}/args.txt" 2>/dev/null || true

  local sf cf
  sf="$(count_vendor_ramdisk_fragments "${stock_u}/args.txt")"
  cf="$(count_vendor_ramdisk_fragments "${custom_u}/args.txt")"

  log "==> Auditoria header vendor_boot v4"
  log "  Ramdisk fragments stock:  ${sf}"
  log "  Ramdisk fragments custom: ${cf:-n/a (ainda não gerado)}"
  grep -m1 '^--header_version' "${stock_u}/args.txt" 2>/dev/null | sed 's/^/  /' || log "  header_version: n/a"
  grep -m1 '^--pagesize' "${stock_u}/args.txt" 2>/dev/null | sed 's/^/  /' || true
  grep -m1 '^--board' "${stock_u}/args.txt" 2>/dev/null | sed 's/^/  /' || true

  if [[ -f "${stock_u}/dtb" ]]; then
    log "  DTB stock SHA-256:  $(sha256sum "${stock_u}/dtb" | awk '{print $1}')"
  fi
  if [[ -f "${custom_u}/dtb" ]]; then
    log "  DTB custom SHA-256: $(sha256sum "${custom_u}/dtb" | awk '{print $1}')"
  fi

  log "  vendor_boot stock size:  $(stat -c '%s' "${stock}" 2>/dev/null || echo n/a) bytes"
  [[ -f "${custom}" ]] && log "  vendor_boot custom size: $(stat -c '%s' "${custom}" 2>/dev/null) bytes"

  if [[ "${sf}" != "${cf}" && -f "${custom}" ]]; then
    log_err "  AVISO: contagem de fragments diverge — revisar repack"
  fi
}

report_module_dependencies() {
  local ko="$1" modules_root="$2"
  local deps dep
  deps="$(modinfo -F depends "${ko}" 2>/dev/null || true)"
  [[ -n "${deps}" ]] || return 0
  log "  depends (${ko##*/}): ${deps}"
  IFS=',' read -ra dep_arr <<< "${deps}"
  for dep in "${dep_arr[@]}"; do
    dep="${dep// /}"
    [[ -z "${dep}" ]] && continue
    if find "${modules_root}" "${DIST_DIR}" -name "${dep}.ko" -print -quit 2>/dev/null | grep -q .; then
      log "    ${dep}.ko: encontrado no tree"
    else
      log_err "    ${dep}.ko: NÃO encontrado — risco Unknown symbol"
    fi
  done
}

check_vermagic_strict() {
  local new_ko="$1" old_ko="$2"
  local nv ov
  nv="$(modinfo -F vermagic "${new_ko}" 2>/dev/null || true)"
  ov="$(modinfo -F vermagic "${old_ko}" 2>/dev/null || true)"
  if [[ -z "${nv}" || -z "${ov}" ]]; then
    log_err "  vermagic indisponível para comparação"
    return 1
  fi
  if vermagic_compatible "${nv}" "${ov}"; then
    return 0
  fi
  log_err "BLOQUEIO vermagic: ${new_ko##*/}"
  log_err "  custom: ${nv}"
  log_err "  stock:  ${ov}"
  if [[ "${ALLOW_VERMAGIC_MISMATCH:-0}" != "1" ]]; then
    log_err "Deploy abortado. Alinhe Image/módulos ou use ALLOW_VERMAGIC_MISMATCH=1 (somente dev)."
    exit 1
  fi
  log_err "ALLOW_VERMAGIC_MISMATCH=1 — substituindo mesmo assim (NÃO flashear no aparelho)."
  return 1
}

check_module_abi_strict() {
  local new_ko="$1" old_ko="$2"
  local mismatches

  if mismatches="$(module_abi_common_crc_mismatches "${old_ko}" "${new_ko}")"; then
    log "  modversions comuns (${new_ko##*/}): OK"
    return 0
  fi

  log_err "BLOQUEIO ABI modversions: ${new_ko##*/}"
  if [[ -n "${mismatches}" ]]; then
    while IFS= read -r line; do
      log_err "    ${line}"
    done <<< "${mismatches}"
  else
    log_err "    nao foi possivel comparar CRCs do modulo stock e custom"
  fi

  if [[ "${ALLOW_MODULE_ABI_MISMATCH:-0}" != "1" ]]; then
    log_err "Deploy abortado. Alinhe os tipos exportados pelo firmware stock."
    exit 1
  fi
  log_err "ALLOW_MODULE_ABI_MISMATCH=1 - imagem somente para diagnostico; NAO flashear."
  return 1
}

classify_module() {
  local vb_root="$1" dlkm_root="$2" name="$3"
  local in_vb=0 in_dlkm=0

  [[ -n "${vb_root}" && -d "${vb_root}" ]] && \
    find "${vb_root}" -name "${name}.ko" -print -quit 2>/dev/null | grep -q . && in_vb=1
  [[ -n "${dlkm_root}" && -d "${dlkm_root}" ]] && \
    find "${dlkm_root}" -name "${name}.ko" -print -quit 2>/dev/null | grep -q . && in_dlkm=1

  if [[ "${in_vb}" -eq 1 && "${in_dlkm}" -eq 1 ]]; then
    echo "DUPLICATED"
  elif [[ "${in_vb}" -eq 1 ]]; then
    echo "FIRST_STAGE_VENDOR_BOOT_CONFIRMED"
  elif [[ "${in_dlkm}" -eq 1 ]]; then
    echo "SECOND_STAGE_VENDOR_DLKM_CONFIRMED"
  elif [[ "${in_vb}" -eq 0 && -z "${dlkm_root}" ]]; then
    echo "NOT_IN_VENDOR_BOOT_EXPECTED_VENDOR_DLKM"
  else
    echo "NOT_FOUND"
  fi
}

grep_modules_metadata() {
  local modules_root="$1"
  local dep
  dep="$(find "${modules_root}" -name modules.dep 2>/dev/null | head -1 || true)"
  [[ -n "${dep}" ]] || return 0
  log "  modules.dep (camera|kgsl|hotplug):"
  grep -E 'camera|msm_kgsl|cpu_hotplug' "${dep}" 2>/dev/null | sed 's/^/    /' || \
    log "    (sem entradas)"
}

replace_ko_in_tree() {
  local tree="$1" name="$2" src="$3" prepare_dlkm="${4:-0}"
  local dst ref_ko="" install_src prepared
  REPLACE_KO_COUNT=0

  require_file "${src}"
  while IFS= read -r -d '' dst; do
    ref_ko="${dst}"
    install_src="${src}"
    if [[ "${prepare_dlkm}" == "1" ]]; then
      prepared="${WORK}/${name}.prepared.ko"
      module_prepare_for_dlkm "${src}" "${dst}" "${prepared}"
      install_src="${prepared}"
      log "  modulo preparado para DLKM: $(stat -c '%s' "${install_src}") bytes"
    fi
    check_vermagic_strict "${install_src}" "${dst}"
    check_module_abi_strict "${install_src}" "${dst}"
    log_err "  substituindo ${dst}"
    cp -p "${install_src}" "${dst}"
    if [[ "${prepare_dlkm}" == "1" ]]; then
      mkdir -p "${FLASH_OUT}/prepared_modules"
      cp -p "${install_src}" "${FLASH_OUT}/prepared_modules/${name}.ko"
    fi
    REPLACE_KO_COUNT=$((REPLACE_KO_COUNT + 1))
  done < <(find "${tree}" -name "${name}.ko" -print0 2>/dev/null)

  [[ -n "${ref_ko}" ]] && report_module_dependencies "${install_src}" "${tree}"
}

regenerate_module_metadata() {
  local modules_root="$1"
  local kver_dir kver

  if ! command -v depmod >/dev/null; then
    log "AVISO: depmod ausente; metadata não regenerada em ${modules_root}"
    return
  fi

  if [[ -d "${modules_root}/lib/modules" ]]; then
    kver_dir="$(find "${modules_root}/lib/modules" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1 || true)"
    if [[ -n "${kver_dir}" ]]; then
      kver="$(basename "${kver_dir}")"
      log "  depmod -b ${modules_root} ${kver}"
      depmod -b "${modules_root}" "${kver}"
      return
    fi
    log "  layout flat: modules.dep stock preservado (nomes/dependências inalterados)"
  fi
}

device_partition_path() {
  local part="$1"
  adb shell "su -c '
    if [ -e /dev/block/by-name/${part} ]; then
      readlink -f /dev/block/by-name/${part}
      exit
    fi
    slot=\$(getprop ro.boot.slot_suffix)
    if [ -n \"\$slot\" ] && [ -e /dev/block/by-name/${part}\$slot ]; then
      readlink -f /dev/block/by-name/${part}\$slot
    fi
  '" 2>/dev/null | tr -d '\r' | head -1
}

pull_partition() {
  local part="$1" dest="$2"
  command -v adb >/dev/null || { echo "adb necessário para PULL=1" >&2; exit 1; }
  adb get-state >/dev/null 2>&1 || { echo "Dispositivo adb offline." >&2; exit 1; }
  local block
  block="$(device_partition_path "${part}")"
  [[ -n "${block}" ]] || {
    echo "Partição ${part} não encontrada em /dev/block/by-name (incluindo slot ativo)." >&2
    exit 1
  }
  log "==> Extraindo ${part} do aparelho (${block})"
  mkdir -p "$(dirname "${dest}")"
  adb exec-out "su -c 'dd if=${block} bs=4194304 2>/dev/null'" > "${dest}"
  [[ -s "${dest}" ]] || { echo "Extração vazia de ${part}." >&2; exit 1; }
}

img_to_raw() {
  local src="$1" dst="$2"
  if file "${src}" | grep -q 'Android sparse'; then
    command -v simg2img >/dev/null || { echo "Instale simg2img." >&2; exit 1; }
    simg2img "${src}" "${dst}"
  else
    cp -p "${src}" "${dst}"
  fi
}

extract_erofs_or_mount() {
  local raw="$1" mountpoint="$2"
  mkdir -p "${mountpoint}"
  local ftype
  ftype="$(file -b "${raw}")"
  log "Tipo vendor_dlkm: ${ftype}"

  if echo "${ftype}" | grep -qi erofs; then
    command -v fsck.erofs >/dev/null || { echo "Instale erofs-utils." >&2; exit 1; }
    fsck.erofs --extract="${mountpoint}" "${raw}"
    return 0
  fi
  if echo "${ftype}" | grep -qi 'ext[234]'; then
    echo "vendor_dlkm ext4 detectado. Repack ext4 ainda não é seguro neste pipeline;" >&2
    echo "preservar formato, fs_config, SELinux e tamanho exige ferramentas do firmware." >&2
    exit 1
  fi
  echo "Formato vendor_dlkm não suportado: ${ftype}" >&2
  exit 1
}

validate_vendor_dlkm_identity() {
  local root="$1"
  local prop="${root}/etc/build.prop"
  local expected_model="${EXPECTED_MODEL:-SM-A057M}"
  local expected_firmware="${EXPECTED_FIRMWARE:-A057MUBSADYG1}"
  local model firmware

  [[ -f "${prop}" ]] || {
    log_err "BLOQUEIO: vendor_dlkm sem etc/build.prop para validar identidade."
    return 1
  }
  model="$(sed -n 's/^ro.product.vendor_dlkm.model=//p' "${prop}" | head -1)"
  firmware="$(sed -n 's/^ro.vendor_dlkm.build.version.incremental=//p' "${prop}" | head -1)"
  log "  vendor_dlkm modelo:   ${model:-n/a}"
  log "  vendor_dlkm firmware: ${firmware:-n/a}"

  if [[ "${model}" == "${expected_model}" && "${firmware}" == "${expected_firmware}" ]]; then
    return 0
  fi
  if [[ "${ALLOW_VENDOR_DLKM_MISMATCH:-0}" == "1" ]]; then
    log_err "  AVISO: identidade divergente autorizada por ALLOW_VENDOR_DLKM_MISMATCH=1"
    return 0
  fi
  log_err "BLOQUEIO: vendor_dlkm não corresponde a ${expected_model}/${expected_firmware}."
  return 1
}

deploy_vendor_boot() {
  local stock="$1" out_img="$2"
  require_file "${stock}"

  log "==> Deploy first-stage: vendor_boot ramdisk"
  vendor_boot_unpack_ramdisk "${stock}" "${WORK}/vb" >/dev/null
  local rd_root="${WORK}/vb/vendor_ramdisk_root"
  local frag_count
  local -a ramdisk_replacements=()
  local -a changed_entries=()
  frag_count="$(count_vendor_ramdisk_fragments "${WORK}/vb/vendor_boot.args")"
  log "  vendor_ramdisk fragments no stock args: ${frag_count}"

  for name in cpu_hotplug msm_kgsl camera; do
    local cls count dst rel
    cls="$(classify_module "${rd_root}" "" "${name}")"
    log "${name}.ko classificação (vendor_boot): ${cls}"
    [[ "${cls}" == "FIRST_STAGE_VENDOR_BOOT_CONFIRMED" || "${cls}" == "DUPLICATED" ]] || continue
    [[ -f "${CUSTOM_SRC[$name]}" ]] || { log "  SKIP (custom ausente)"; continue; }
    while IFS= read -r -d '' dst; do
      rel="${dst#"${rd_root}/"}"
      ramdisk_replacements+=("${rel}" "${CUSTOM_SRC[$name]}")
      changed_entries+=("${rel}")
    done < <(find "${rd_root}" -name "${name}.ko" -print0 2>/dev/null)
    replace_ko_in_tree "${rd_root}" "${name}" "${CUSTOM_SRC[$name]}"
    count="${REPLACE_KO_COUNT}"
    [[ "${count}" -gt 0 ]] || log "  AVISO: ${name}.ko não substituído no ramdisk"
  done

  [[ "${#ramdisk_replacements[@]}" -gt 0 ]] || {
    echo "Nenhum modulo elegivel encontrado no vendor ramdisk stock" >&2
    exit 1
  }
  grep_modules_metadata "${rd_root}"

  local new_frag="${WORK}/vb/vendor_ramdisk00.new"
  ramdisk_patch_lz4_cpio \
    "${VENDOR_BOOT_RAMDISK_FRAGMENT}" \
    "${new_frag}" \
    "${ramdisk_replacements[@]}"
  log "  CPIO preservado; payloads alterados: ${changed_entries[*]}"

  declare -a args=()
  while IFS= read -r -d '' arg; do args+=("${arg}"); done < "${WORK}/vb/vendor_boot.args"

  local -a final=() i=0 replaced=0 frag_idx=0
  while (( i < ${#args[@]} )); do
    if [[ "${args[i]}" == "--vendor_ramdisk_fragment" ]]; then
      if [[ "${frag_idx}" -eq 0 ]]; then
        final+=("--vendor_ramdisk_fragment" "${new_frag}")
        replaced=1
      else
        final+=("${args[i]}" "${args[i + 1]}")
      fi
      frag_idx=$((frag_idx + 1))
      i=$((i + 2))
      continue
    fi
    if [[ "${args[i]}" == "--output" || "${args[i]}" == "-o" ]]; then
      i=$((i + 2)); continue
    fi
    final+=("${args[i]}")
    i=$((i + 1))
  done

  [[ "${replaced}" -eq 1 ]] || { echo "Falha ao injetar ramdisk em vendor_boot args" >&2; exit 1; }
  python3 "${MKBOOTIMG}" "${final[@]}" --vendor_boot "${out_img}"
  avb_add_footer_like_stock "${stock}" "${out_img}" vendor_boot | tee -a "${REPORT}"
  log "vendor_boot custom: ${out_img}"
}

deploy_vendor_dlkm_partition() {
  local stock="$1" out_img="$2"
  [[ -f "${stock}" ]] || return 2

  log "==> Deploy second-stage: vendor_dlkm"
  local raw="${WORK}/dlkm.raw"
  local root="${WORK}/dlkm_root"
  img_to_raw "${stock}" "${raw}"
  extract_erofs_or_mount "${raw}" "${root}"
  validate_vendor_dlkm_identity "${root}"

  local vb_rd="${WORK}/vb/vendor_ramdisk_root"
  for name in cpu_hotplug msm_kgsl camera; do
    local cls count
    cls="$(classify_module "${vb_rd}" "${root}" "${name}")"
    log "${name}.ko classificação global: ${cls}"
    if ! custom_vendor_dlkm_enabled "${name}"; then
      log "  preservando ${name}.ko stock (politica de producao)"
      continue
    fi
    [[ "${cls}" == "NOT_FOUND" || "${cls}" == "NOT_IN_VENDOR_BOOT_EXPECTED_VENDOR_DLKM" ]] && continue
    [[ "${cls}" == "FIRST_STAGE_VENDOR_BOOT_CONFIRMED" ]] && continue
    [[ -f "${CUSTOM_SRC[$name]}" ]] || { log "  SKIP (custom ausente)"; continue; }
    replace_ko_in_tree "${root}" "${name}" "${CUSTOM_SRC[$name]}" 1
    count="${REPLACE_KO_COUNT}"
    [[ "${count}" -gt 0 ]] || log "  AVISO: ${name}.ko não substituído em vendor_dlkm"
  done

  regenerate_module_metadata "${root}"
  grep_modules_metadata "${root}"

  command -v mkfs.erofs >/dev/null || {
    rm -rf "${FLASH_OUT}/vendor_dlkm_staging"
    cp -a "${root}" "${FLASH_OUT}/vendor_dlkm_staging"
    log_err "mkfs.erofs ausente; staging salvo em ${FLASH_OUT}/vendor_dlkm_staging"
    return 1
  }
  local fs_uuid fs_timestamp dlkm_tar
  fs_uuid="$(dump.erofs -s "${raw}" 2>/dev/null |
    sed -n 's/^Filesystem UUID:[[:space:]]*//p' | head -1)"
  fs_timestamp="$(stat -c '%Y' "${root}")"
  dlkm_tar="${WORK}/vendor_dlkm.tar"
  "${ROOT_DIR}/scripts/lib/vendor_dlkm_tar.py" \
    --timestamp "${fs_timestamp}" "${root}" "${dlkm_tar}"

  local -a mkfs_args=(
    -x0
    "-E^xattr-name-filter"
    --tar=f
    "-T${fs_timestamp}"
    --mkfs-time
  )
  [[ -n "${fs_uuid}" ]] && mkfs_args+=("-U${fs_uuid}")
  mkfs.erofs "${mkfs_args[@]}" "${out_img}" "${dlkm_tar}"
  fsck.erofs "${out_img}" >/dev/null

  local compressed_files xattr_size
  compressed_files="$(dump.erofs -S "${out_img}" 2>/dev/null |
    awk -F: '/Filesystem compressed files:/ {gsub(/[[:space:]]/, "", $2); print $2}')"
  xattr_size="$(dump.erofs --path=/lib/modules/msm_kgsl.ko "${out_img}" 2>/dev/null |
    sed -n 's/.*Xattr size:[[:space:]]*\([0-9][0-9]*\).*/\1/p')"
  [[ "${compressed_files:-1}" == "0" ]] || {
    log_err "BLOQUEIO EROFS: imagem custom contém arquivos comprimidos."
    exit 1
  }
  [[ "${xattr_size:-0}" -gt 0 ]] || {
    log_err "BLOQUEIO EROFS: security.selinux não foi preservado."
    exit 1
  }
  log "  EROFS stock-like: sem compressao; SELinux xattr presente (${xattr_size} bytes)"

  avb_add_footer_like_stock "${stock}" "${out_img}" vendor_dlkm | tee -a "${REPORT}"
  log "vendor_dlkm custom: ${out_img}"
}

main() {
  mkdir -p "${FLASH_OUT}"
  rm -rf "${FLASH_OUT}/prepared_modules"
  : > "${REPORT}"
  local stock_preserved="" name
  for name in cpu_hotplug msm_kgsl camera; do
    if ! custom_vendor_dlkm_enabled "${name}"; then
      stock_preserved="${stock_preserved}${stock_preserved:+ }${name}"
    fi
  done
  [[ -n "${stock_preserved}" ]] || stock_preserved="nenhum dos módulos principais"

  log "Relatório deploy_kernel_modules — $(date -Iseconds)"
  log "Dist: ${DIST_DIR}"
  log "Modulos custom no vendor_dlkm: ${CUSTOM_VENDOR_DLKM_MODULES}"
  log "Modulos preservados stock: ${stock_preserved}"

  log "==> Pré-checagem BUILD_SAFE (release/vermagic/KMI — obrigatória)"
  VERMAGIC_OUT_PARENT="${OUT_PARENT}"
  VERMAGIC_ROOT_DIR="${ROOT_DIR}"
  if ! audit_vermagic_block "${DIST_DIR}" "${VENDOR_BOOT_IMG}" "${DIST_DIR}/Image" >> "${REPORT}" 2>&1; then
    if [[ "${ALLOW_VERMAGIC_MISMATCH:-0}" != "1" ]]; then
      cat "${REPORT}"
      exit 1
    fi
  fi

  [[ "${PULL:-0}" == "1" ]] && pull_partition vendor_boot "${VENDOR_BOOT_IMG}"
  [[ "${PULL:-0}" == "1" ]] && pull_partition vendor_dlkm "${VENDOR_DLKM_IMG}"

  require_file "${VENDOR_BOOT_IMG}"
  require_file "${CUSTOM_SRC[cpu_hotplug]}"
  for name in ${CUSTOM_VENDOR_DLKM_MODULES}; do
    require_file "${CUSTOM_SRC[$name]}"
  done

  deploy_vendor_boot "${VENDOR_BOOT_IMG}" "${FLASH_OUT}/vendor_boot.img"
  audit_vendor_boot_headers "${VENDOR_BOOT_IMG}" "${FLASH_OUT}/vendor_boot.img"
  if [[ -f "${VENDOR_DLKM_IMG}" ]]; then
    deploy_vendor_dlkm_partition "${VENDOR_DLKM_IMG}" "${FLASH_OUT}/vendor_dlkm.img"
  elif [[ "${ALLOW_PARTIAL_PACK:-0}" == "1" ]]; then
    rm -f "${FLASH_OUT}/vendor_dlkm.img"
    log_err "PACK PARCIAL: vendor_dlkm.img stock ausente; câmera/KGSL não foram empacotados."
  else
    log_err "BLOQUEIO: vendor_dlkm.img stock ausente."
    log_err "Conecte o aparelho e use PULL=1, ou defina VENDOR_DLKM_IMG."
    log_err "ALLOW_PARTIAL_PACK=1 gera somente vendor_boot para diagnóstico."
    exit 2
  fi

  log ""
  log "Concluído. Relatório: ${REPORT}"
  if [[ "${ALLOW_VERMAGIC_MISMATCH:-0}" == "1" ]]; then
    log "AVISO: imagens geradas com vermagic divergente — NÃO flashear no aparelho principal."
  fi
  log "Antes do flash: ./scripts/discover_flash_layout.sh"
  log "Após flash:     ./scripts/validate_modules_adb.sh"
  ls -lah "${FLASH_OUT}/"*.img 2>/dev/null || true
}

main "$@"
