#!/usr/bin/env bash
# Audita artefatos no host: localiza .ko custom e classifica first/second-stage.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${DIST_DIR:-${ROOT_DIR}/out/kernel-m269-thinlto/dist}"
STOCK_DIR="${STOCK_DIR:-${ROOT_DIR}/kernel_imgs/FILESKERNEL}"

NM="${NM:-llvm-nm}"
command -v "${NM}" >/dev/null || NM=nm

# shellcheck source=lib/vermagic_check.sh
source "${ROOT_DIR}/scripts/lib/vermagic_check.sh"

section() { echo; echo "=== $* ==="; }

declare -A CUSTOM_KO=(
  [msm_kgsl]="${DIST_DIR}/graphics/msm_kgsl.ko"
  [camera]="${DIST_DIR}/camera/camera.ko"
  [cpu_hotplug]="${DIST_DIR}/cpu_hotplug.ko"
)

classify_stock() {
  local vb_rd="$1" dlkm_root="$2" name="$3"
  local in_vb=0 in_dlkm=0

  [[ -n "${vb_rd}" && -d "${vb_rd}" ]] && \
    find "${vb_rd}" -name "${name}.ko" -print -quit 2>/dev/null | grep -q . && in_vb=1
  [[ -n "${dlkm_root}" && -d "${dlkm_root}" ]] && \
    find "${dlkm_root}" -name "${name}.ko" -print -quit 2>/dev/null | grep -q . && in_dlkm=1

  if [[ "${in_vb}" -eq 1 && "${in_dlkm}" -eq 1 ]]; then
    echo "DUPLICATED"
  elif [[ "${in_vb}" -eq 1 ]]; then
    echo "FIRST_STAGE_VENDOR_BOOT_CONFIRMED"
  elif [[ "${in_dlkm}" -eq 1 ]]; then
    echo "SECOND_STAGE_VENDOR_DLKM_CONFIRMED"
  elif [[ -n "${vb_rd}" ]]; then
    echo "NOT_IN_VENDOR_BOOT_EXPECTED_VENDOR_DLKM"
  else
    echo "NOT_FOUND"
  fi
}

section "Kernel release / vermagic (bloqueador de flash)"
VERMAGIC_ROOT_DIR="${ROOT_DIR}"
audit_vermagic_block "${DIST_DIR}" "${STOCK_DIR}/vendor_boot.img" "${DIST_DIR}/Image" || true

section "Artefatos custom no dist"
for name in msm_kgsl camera cpu_hotplug; do
  ko="${CUSTOM_KO[$name]}"
  if [[ -f "${ko}" ]]; then
    echo "OK  ${name}: ${ko}"
    sha256sum "${ko}" | awk '{print "    sha256:", $1}'
    modinfo -F vermagic "${ko}" 2>/dev/null | sed 's/^/    vermagic: /' || true
    modinfo -F srcversion "${ko}" 2>/dev/null | sed 's/^/    srcversion: /' || true
    modinfo -F depends "${ko}" 2>/dev/null | sed 's/^/    depends: /' || true
    if [[ "${name}" == "msm_kgsl" ]]; then
      modinfo -p "${ko}" 2>/dev/null | grep -i governor | sed 's/^/    param: /' || true
    fi
  else
    echo "MISSING ${name}: ${ko}"
  fi
done

section "Símbolo cpu_hotplug_level nos .ko do dist"
while IFS= read -r -d '' mod; do
  if "${NM}" "${mod}" 2>/dev/null | grep -q 'cpu_hotplug_level'; then
    echo "${mod}"
  fi
done < <(find "${DIST_DIR}" -name '*.ko' -print0 2>/dev/null)

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
# shellcheck source=lib/ramdisk_util.sh
source "${ROOT_DIR}/scripts/lib/ramdisk_util.sh"

VB_RD=""
DLKM_ROOT=""

section "Classificação no vendor_boot stock (first-stage)"
if [[ -f "${STOCK_DIR}/vendor_boot.img" ]]; then
  vendor_boot_unpack_ramdisk "${STOCK_DIR}/vendor_boot.img" "${WORK}/vb" >/dev/null
  VB_RD="${WORK}/vb/vendor_ramdisk_root"
  RD="${VB_RD}/lib/modules"
  for name in msm_kgsl camera cpu_hotplug; do
    if [[ -f "${RD}/${name}.ko" ]]; then
      echo "FIRST_STAGE_VENDOR_BOOT_CONFIRMED  ${name}.ko"
      modinfo -F vermagic "${RD}/${name}.ko" 2>/dev/null | sed 's/^/    vermagic: /'
    else
      echo "NOT_IN_VENDOR_BOOT_EXPECTED_VENDOR_DLKM  ${name}.ko"
    fi
  done
  for meta in modules.load modules.dep modules.alias modules.softdep; do
    [[ -f "${RD}/${meta}" ]] && echo "--- ${meta} (trecho) ---" && \
      grep -iE 'kgsl|camera|hotplug' "${RD}/${meta}" 2>/dev/null || true
  done
else
  echo "vendor_boot.img stock ausente em ${STOCK_DIR}"
fi

section "Classificação no vendor_dlkm stock (second-stage)"
if [[ -f "${STOCK_DIR}/vendor_dlkm.img" ]]; then
  raw="${WORK}/dlkm.raw"
  dlkm_mount="${WORK}/dlkm_root"
  if file "${STOCK_DIR}/vendor_dlkm.img" | grep -q 'Android sparse'; then
    command -v simg2img >/dev/null && simg2img "${STOCK_DIR}/vendor_dlkm.img" "${raw}" || \
      cp "${STOCK_DIR}/vendor_dlkm.img" "${raw}"
  else
    cp "${STOCK_DIR}/vendor_dlkm.img" "${raw}"
  fi
  mkdir -p "${dlkm_mount}"
  if file -b "${raw}" | grep -qi erofs && command -v fsck.erofs >/dev/null; then
    fsck.erofs --extract="${dlkm_mount}" "${raw}"
    DLKM_ROOT="${dlkm_mount}"
    for name in msm_kgsl camera cpu_hotplug; do
      find "${DLKM_ROOT}" -name "${name}.ko" 2>/dev/null | while read -r p; do
        echo "SECOND_STAGE_VENDOR_DLKM_CONFIRMED  ${name}.ko"
        echo "  path: ${p}"
        modinfo -F vermagic "${p}" 2>/dev/null | sed 's/^/  vermagic: /'
      done
    done
  else
    echo "vendor_dlkm: extração erofs indisponível (instale erofs-utils)"
  fi
else
  echo "vendor_dlkm.img stock ausente — classificação second-stage NÃO confirmada para kgsl/camera"
fi

section "Classificação combinada"
for name in cpu_hotplug msm_kgsl camera; do
  printf "%-12s %s\n" "${name}.ko" "$(classify_stock "${VB_RD}" "${DLKM_ROOT}" "${name}")"
done

section "Próximo passo"
echo "Bloqueador: ./scripts/audit_kernel_release.sh  (deve passar antes do deploy)"
echo "Release/KMI:  ./scripts/audit_kernel_release.sh"
echo "Deploy:       ./scripts/deploy_kernel_modules.sh"
echo "Layout:       ./scripts/discover_flash_layout.sh"
echo "Validar:      ./scripts/validate_modules_adb.sh"