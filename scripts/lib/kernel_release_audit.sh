# Auditoria kernel release / vermagic / KMI — funções compartilhadas.
# shellcheck shell=bash

# shellcheck source=module_abi.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/module_abi.sh"

audit_read_release_file() {
  local f="$1"
  [[ -f "${f}" ]] && tr -d '\n' < "${f}" || echo ""
}

audit_read_utsrelease() {
  local f="$1"
  [[ -f "${f}" ]] || return 0
  grep -o '"[^"]*"' "${f}" 2>/dev/null | head -1 | tr -d '"' || true
}

audit_makefile_sublevel() {
  local mf="$1"
  local v p s e
  [[ -f "${mf}" ]] || return 1
  v="$(grep -E '^VERSION[[:space:]]*=' "${mf}" | head -1 | sed 's/.*= *//;s/ *$//')"
  p="$(grep -E '^PATCHLEVEL[[:space:]]*=' "${mf}" | head -1 | sed 's/.*= *//;s/ *$//')"
  s="$(grep -E '^SUBLEVEL[[:space:]]*=' "${mf}" | head -1 | sed 's/.*= *//;s/ *$//')"
  e="$(grep -E '^EXTRAVERSION[[:space:]]*=' "${mf}" | head -1 | sed 's/.*= *//;s/ *$//' | tr -d '"')"
  echo "${v}.${p}.${s}${e}"
}

audit_find_out_release() {
  local out_root="$1" tree_name="$2"
  find "${out_root}" -path "*/${tree_name}/*/include/config/kernel.release" -print -quit 2>/dev/null \
    | head -1
}

audit_image_kernel_release() {
  local image="$1"
  local line
  line="$(strings "${image}" 2>/dev/null | grep -m1 '^Linux version ' || true)"
  [[ -n "${line}" ]] && echo "${line}" | awk '{print $3}' || true
}

audit_vermagic_release() {
  local vm="$1"
  echo "${vm%% *}"
}

audit_release_base_match() {
  local a="$1" b="$2"
  [[ -n "${a}" && -n "${b}" && "${a}" == "${b}" ]]
}

audit_release_exact_match() {
  local a="$1" b="$2"
  [[ -n "${a}" && -n "${b}" && "${a}" == "${b}" ]]
}

audit_collect_releases() {
  local root_dir="$1" out_parent="$2"
  local gki_mf="${root_dir}/kernel_platform/common/Makefile"
  local vendor_mf="${root_dir}/kernel_platform/msm-kernel/Makefile"
  local gki_rel_file vendor_rel_file

  GKI_SOURCE_RELEASE="$(audit_makefile_sublevel "${gki_mf}")"
  VENDOR_SOURCE_RELEASE="$(audit_makefile_sublevel "${vendor_mf}")"

  gki_rel_file="$(audit_find_out_release "${out_parent}" "gki_kernel")"
  [[ -z "${gki_rel_file}" ]] && gki_rel_file="$(find "${out_parent}" -path '*/gki_kernel/*/include/config/kernel.release' -print -quit 2>/dev/null)"
  GKI_OUTPUT_RELEASE="$(audit_read_release_file "${gki_rel_file}")"

  vendor_rel_file="$(audit_find_out_release "${out_parent}" "msm-kernel")"
  [[ -z "${vendor_rel_file}" ]] && vendor_rel_file="$(find "${out_parent}" -path '*/msm-kernel/include/config/kernel.release' -print -quit 2>/dev/null)"
  VENDOR_OUTPUT_RELEASE="$(audit_read_release_file "${vendor_rel_file}")"

  local image="${DIST_DIR:-${out_parent}/dist}/Image"
  [[ -f "${image}" ]] && IMAGE_OUTPUT_RELEASE="$(audit_image_kernel_release "${image}")" || IMAGE_OUTPUT_RELEASE=""
}

audit_resolve_target_image_release() {
  if [[ -n "${IMAGE_OUTPUT_RELEASE:-}" ]]; then
    TARGET_IMAGE_RELEASE="${IMAGE_OUTPUT_RELEASE}"
    TARGET_IMAGE_SOURCE="IMAGE_OUTPUT_RELEASE (dist/Image)"
  elif [[ -n "${GKI_OUTPUT_RELEASE:-}" ]]; then
    TARGET_IMAGE_RELEASE="${GKI_OUTPUT_RELEASE}"
    TARGET_IMAGE_SOURCE="GKI_OUTPUT_RELEASE (fallback)"
  else
    TARGET_IMAGE_RELEASE=""
    TARGET_IMAGE_SOURCE="n/a"
  fi
}

audit_print_release_block() {
  echo "GKI_SOURCE_RELEASE:       ${GKI_SOURCE_RELEASE:-n/a}"
  echo "GKI_OUTPUT_RELEASE:       ${GKI_OUTPUT_RELEASE:-n/a}"
  echo "IMAGE_OUTPUT_RELEASE:     ${IMAGE_OUTPUT_RELEASE:-n/a}"
  echo "TARGET_IMAGE_RELEASE:     ${TARGET_IMAGE_RELEASE:-n/a}  (${TARGET_IMAGE_SOURCE:-n/a})"
  echo "STOCK_REFERENCE_RELEASE:  ${STOCK_REFERENCE_RELEASE:-n/a}  (${STOCK_REFERENCE_SOURCE:-n/a})"
  echo "VENDOR_SOURCE_RELEASE:    ${VENDOR_SOURCE_RELEASE:-n/a}"
  echo "VENDOR_OUTPUT_RELEASE:    ${VENDOR_OUTPUT_RELEASE:-n/a}"
}

audit_print_kernel_release_files() {
  local out_parent="$1"
  echo ""
  echo "== kernel.release / utsrelease.h =="
  find "${out_parent}" \( -path '*/include/config/kernel.release' -o -path '*/include/generated/utsrelease.h' \) \
    2>/dev/null | sort | while read -r f; do
    echo "--- ${f#${out_parent}/} ---"
    cat "${f}"
    echo ""
  done
}

audit_symvers_lookup() {
  local symvers="$1" sym="$2"
  local line crc provider
  [[ -f "${symvers}" && -n "${sym}" ]] || return 1
  line="$(grep -E "[[:space:]]${sym}[[:space:]]" "${symvers}" 2>/dev/null | head -1 || true)"
  [[ -n "${line}" ]] || return 1
  crc="$(echo "${line}" | awk '{print $1}')"
  provider="$(echo "${line}" | awk '{print $3}')"
  echo "${crc}|${provider}"
  return 0
}

audit_module_stage_label() {
  local name="$1"
  case "${name}" in
    cpu_hotplug) echo "FIRST_STAGE (vendor_boot)" ;;
    msm_kgsl|camera) echo "SECOND_STAGE (vendor_dlkm)" ;;
    *) echo "UNKNOWN" ;;
  esac
}

audit_check_unresolved_symbols() {
  local ko="$1" symvers="$2"
  local nm="${NM:-llvm-nm}"
  command -v "${nm}" >/dev/null || nm=nm
  [[ -f "${ko}" && -f "${symvers}" ]] || return 0

  local missing=0 sym
  while IFS= read -r sym; do
    [[ -z "${sym}" ]] && continue
    if ! grep -q "${sym}" "${symvers}" 2>/dev/null; then
      echo "    UNRESOLVED: ${sym}"
      missing=$((missing + 1))
    fi
  done < <("${nm}" -u "${ko}" 2>/dev/null | awk '{print $3}' | sort -u)

  [[ "${missing}" -gt 0 ]] && return 1
  return 0
}

audit_check_unresolved_symbols_detail() {
  local ko="$1" symvers="$2" stage="$3"
  local nm="${NM:-llvm-nm}"
  command -v "${nm}" >/dev/null || nm=nm
  [[ -f "${ko}" && -f "${symvers}" ]] || return 0

  local missing=0 sym lookup

  while IFS= read -r sym; do
    [[ -z "${sym}" ]] && continue
    lookup="$(audit_symvers_lookup "${symvers}" "${sym}" || true)"
    if [[ -z "${lookup}" ]]; then
      echo "    UNRESOLVED: ${sym}"
      echo "      módulo provedor: (ausente em Module.symvers)"
      echo "      CRC esperado:    n/a"
      echo "      CRC fornecido:   n/a"
      echo "      estágio:         ${stage}"
      missing=$((missing + 1))
    fi
  done < <("${nm}" -u "${ko}" 2>/dev/null | awk '{print $3}' | sort -u)
  if [[ "${missing}" -eq 0 ]]; then
    echo "    (nenhum símbolo indefinido fora de Module.symvers)"
  fi

  [[ "${missing}" -gt 0 ]] && return 1
  return 0
}

audit_module_layout_crc() {
  local ko="$1" ref_ko="$2" label="$3"
  local custom_crc ref_crc
  command -v modprobe >/dev/null || { echo "  ${label}: modprobe ausente — skip module_layout"; return 0; }

  custom_crc="$(modprobe --dump-modversions "${ko}" 2>/dev/null | grep -E '^module_layout' | awk '{print $2}' || true)"
  if [[ -z "${custom_crc}" ]]; then
    echo "  ${label}: module_layout CRC indisponível (modprobe) — registrar, não bloqueia BUILD_SAFE"
    return 0
  fi
  echo "  ${label}: module_layout CRC custom = ${custom_crc}"

  if [[ -f "${ref_ko}" ]]; then
    ref_crc="$(modprobe --dump-modversions "${ref_ko}" 2>/dev/null | grep -E '^module_layout' | awk '{print $2}' || true)"
    if [[ -n "${ref_crc}" ]]; then
      echo "  ${label}: module_layout CRC referência (${ref_ko##*/}) = ${ref_crc}"
      if [[ "${custom_crc}" == "${ref_crc}" ]]; then
        echo "  ${label}: module_layout CRC = OK"
        return 0
      fi
      echo "  ${label}: module_layout CRC = DIVERGE"
      return 1
    fi
  fi
  echo "  ${label}: referência module_layout indisponível — CRC custom registrado, comparação pendente"
  return 0
}

audit_classify_case() {
  local cases=()
  AUDIT_CASE_PRIMARY="BUILD_SAFE"

  if [[ -n "${VENDOR_SOURCE_RELEASE}" && -n "${VENDOR_OUTPUT_RELEASE}" ]]; then
    if [[ "${VENDOR_OUTPUT_RELEASE}" != "${VENDOR_SOURCE_RELEASE}"* ]]; then
      cases+=("CASE_STALE_VENDOR_OUT")
    fi
  fi

  if [[ -n "${GKI_OUTPUT_RELEASE}" && -n "${VENDOR_SOURCE_RELEASE}" ]]; then
    local gki_base="${GKI_OUTPUT_RELEASE%%-*}"
    if [[ "${gki_base}" != "${VENDOR_SOURCE_RELEASE}" ]]; then
      cases+=("CASE_VENDOR_SOURCE_TOO_OLD")
    fi
  fi

  if [[ -n "${STOCK_REFERENCE_RELEASE}" && -n "${TARGET_IMAGE_RELEASE}" ]]; then
    if ! audit_release_exact_match "${TARGET_IMAGE_RELEASE}" "${STOCK_REFERENCE_RELEASE}"; then
      cases+=("CASE_TARGET_IMAGE_LOCALVERSION_MISMATCH")
    fi
  fi

  local ext_rel ko rel
  for ko in "${DIST_DIR}/graphics/msm_kgsl.ko" "${DIST_DIR}/camera/camera.ko"; do
    [[ -f "${ko}" ]] || continue
    ext_rel="$(audit_vermagic_release "$(modinfo -F vermagic "${ko}" 2>/dev/null || true)")"
    if [[ -n "${VENDOR_OUTPUT_RELEASE}" && -n "${ext_rel}" && "${ext_rel}" != "${VENDOR_OUTPUT_RELEASE}" ]]; then
      cases+=("CASE_EXT_MODULE_WRONG_OUTPUT")
      break
    fi
  done

  if [[ -n "${TARGET_IMAGE_RELEASE}" ]]; then
    for ko in "${DIST_DIR}/cpu_hotplug.ko" "${DIST_DIR}/graphics/msm_kgsl.ko" "${DIST_DIR}/camera/camera.ko"; do
      [[ -f "${ko}" ]] || continue
      rel="$(audit_vermagic_release "$(modinfo -F vermagic "${ko}" 2>/dev/null || true)")"
      if [[ -n "${rel}" ]] && ! audit_release_exact_match "${rel}" "${TARGET_IMAGE_RELEASE}"; then
        cases+=("CASE_MODULE_LOCALVERSION_MISMATCH")
        break
      fi
    done
  fi

  if [[ "${KMI_CHECK_FAILED:-0}" -eq 1 ]]; then
    cases+=("CASE_KMI_SYMBOL_MISMATCH")
  fi

  if [[ "${CUSTOM_FEATURE_CHECK_FAILED:-0}" -eq 1 ]]; then
    cases+=("CASE_CUSTOM_FEATURE_MISSING")
  fi

  if [[ ${#cases[@]} -eq 0 ]]; then
    AUDIT_CASE_PRIMARY="BUILD_SAFE"
    return 0
  fi

  AUDIT_CASE_PRIMARY="${cases[0]}"
  AUDIT_CASES=("${cases[@]}")
  return 1
}

audit_adb_device_release() {
  RUNNING_DEVICE_RELEASE=""
  DEVICE_CPU_HOTPLUG_VM=""
  command -v adb >/dev/null || return 0
  adb get-state >/dev/null 2>&1 || return 0
  RUNNING_DEVICE_RELEASE="$(adb shell uname -r 2>/dev/null | tr -d '\r')"
  local ko_path
  ko_path="$(adb shell "su -c 'find /lib/modules /vendor_dlkm -name cpu_hotplug.ko 2>/dev/null | head -1'" 2>/dev/null | tr -d '\r')"
  if [[ -n "${ko_path}" ]]; then
    DEVICE_CPU_HOTPLUG_VM="$(adb shell "su -c 'modinfo -F vermagic ${ko_path} 2>/dev/null'" 2>/dev/null | tr -d '\r')"
    STOCK_MODULE_RELEASE="$(audit_vermagic_release "${DEVICE_CPU_HOTPLUG_VM}")"
  fi
}

audit_pick_stock_reference_release() {
  # Prioridade: módulo stock do firmware > uname -r (se parecer stock) > GKI
  if [[ -n "${STOCK_MODULE_RELEASE}" ]]; then
    STOCK_REFERENCE_RELEASE="${STOCK_MODULE_RELEASE}"
    STOCK_REFERENCE_SOURCE="STOCK_MODULE_VERMAGIC (firmware A057MUBSADYG1)"
  elif [[ -n "${RUNNING_DEVICE_RELEASE}" ]]; then
    STOCK_REFERENCE_RELEASE="${RUNNING_DEVICE_RELEASE}"
    STOCK_REFERENCE_SOURCE="RUNNING_DEVICE_RELEASE (uname -r)"
    if [[ "${RUNNING_DEVICE_RELEASE}" != *android* && "${RUNNING_DEVICE_RELEASE}" != *A057* ]]; then
      STOCK_REFERENCE_WARN="uname -r não parece kernel stock Samsung — preferir extrair vermagic de módulo stock"
    fi
  elif [[ -n "${GKI_OUTPUT_RELEASE}" ]]; then
    STOCK_REFERENCE_RELEASE="${GKI_OUTPUT_RELEASE}"
    STOCK_REFERENCE_SOURCE="GKI_OUTPUT_RELEASE (fallback)"
  else
    STOCK_REFERENCE_RELEASE=""
    STOCK_REFERENCE_SOURCE="n/a"
  fi
  REFERENCE_RELEASE="${STOCK_REFERENCE_RELEASE}"
  REFERENCE_SOURCE="${STOCK_REFERENCE_SOURCE}"
}

audit_kmi_gate() {
  local dist_dir="$1" out_parent="$2"
  KMI_CHECK_FAILED=0

  echo ""
  echo "== KMI / símbolos =="

  local gki_symvers="${out_parent}/gki_kernel/common/Module.symvers"
  [[ -f "${gki_symvers}" ]] || gki_symvers="$(find "${out_parent}" -path '*/gki_kernel/*/Module.symvers' -print -quit 2>/dev/null)"
  local vendor_symvers="${out_parent}/msm-kernel/Module.symvers"
  [[ -f "${vendor_symvers}" ]] || vendor_symvers="$(find "${out_parent}" -path '*/msm-kernel/Module.symvers' -print -quit 2>/dev/null)"

  echo "vmlinux.symvers (GKI): ${gki_symvers:-n/a}"
  echo "Module.symvers (vendor): ${vendor_symvers:-n/a}"

  local -a kos=(
    "${dist_dir}/cpu_hotplug.ko"
    "${dist_dir}/graphics/msm_kgsl.ko"
    "${dist_dir}/camera/camera.ko"
  )
  local stock_hotplug_ko="${AUDIT_WORK_DIR}/stock_vm/vendor_ramdisk_root/lib/modules/cpu_hotplug.ko"
  local ko name fail=0 stage layout_checked=0 layout_mismatch=0
  echo ""
  echo "== module_layout CRC (pré-flash) =="
  for ko in "${kos[@]}"; do
    [[ -f "${ko}" ]] || continue
    name="$(basename "${ko}" .ko)"
    stage="$(audit_module_stage_label "${name}")"
    echo "--- ${name}.ko (${stage}) ---"
    modinfo -F depends "${ko}" 2>/dev/null | sed 's/^/  depends: /' || true
    if [[ -f "${gki_symvers}" ]]; then
      echo "  símbolos indefinidos (detalhe):"
      if audit_check_unresolved_symbols_detail "${ko}" "${gki_symvers}" "${stage}"; then
        echo "  símbolos vs GKI Module.symvers: OK"
      else
        echo "  símbolos vs GKI Module.symvers: FALHA"
        fail=1
      fi
    fi
  done
  for ko in "${kos[@]}"; do
    [[ -f "${ko}" ]] || continue
    name="$(basename "${ko}" .ko)"
    if audit_module_layout_crc "${ko}" "${stock_hotplug_ko}" "${name}"; then
      :
    else
      local custom_crc
      custom_crc="$(modprobe --dump-modversions "${ko}" 2>/dev/null | grep -E '^module_layout' | awk '{print $2}' || true)"
      if [[ -n "${custom_crc}" ]]; then
        layout_mismatch=1
      fi
    fi
    layout_checked=1
  done
  [[ "${layout_mismatch}" -eq 1 ]] && fail=1
  [[ "${layout_checked}" -eq 1 && "${layout_mismatch}" -eq 0 ]] && \
    echo "  module_layout: OK ou pendente (CRC indisponível não bloqueia gate básico)"

  echo ""
  echo "== ABI modversions stock/custom =="
  local stock_dlkm_root="${AUDIT_ROOT_DIR}/vendor_dlkm/extracted/lib/modules"
  local -a abi_pairs=(
    "cpu_hotplug:${stock_hotplug_ko}:${dist_dir}/cpu_hotplug.ko"
    "msm_kgsl:${stock_dlkm_root}/msm_kgsl.ko:${dist_dir}/graphics/msm_kgsl.ko"
  )
  local entry reference_ko candidate_ko mismatches
  for entry in "${abi_pairs[@]}"; do
    name="${entry%%:*}"
    entry="${entry#*:}"
    reference_ko="${entry%%:*}"
    candidate_ko="${entry#*:}"
    if [[ ! -f "${reference_ko}" || ! -f "${candidate_ko}" ]]; then
      echo "  ${name}: referencia ou candidato ausente"
      fail=1
      continue
    fi
    if mismatches="$(module_abi_common_crc_mismatches "${reference_ko}" "${candidate_ko}")"; then
      echo "  ${name}: CRCs comuns compativeis com o firmware stock"
    else
      echo "  ${name}: CRCs comuns DIVERGEM do firmware stock"
      echo "${mismatches}" | sed 's/^/    /'
      fail=1
    fi
  done

  echo ""
  echo "== CONFIG modpost / GKI =="
  local gki_cfg="${out_parent}/gki_kernel/common/.config"
  [[ -f "${gki_cfg}" ]] || gki_cfg="$(find "${out_parent}" -path '*/gki_kernel/*/.config' -print -quit 2>/dev/null)"
  if [[ -f "${gki_cfg}" ]]; then
    echo "--- ${gki_cfg#${out_parent}/} ---"
    grep -E '^CONFIG_(MODVERSIONS|MODULES|MODULE_UNLOAD|CFI_CLANG|LTO_CLANG|LTO_CLANG_THIN|TRIM_UNUSED_KSYMS)=' \
      "${gki_cfg}" 2>/dev/null || true
  else
    echo "  GKI .config: n/a"
  fi
  for cfg in "${out_parent}/msm-kernel/.config"; do
    [[ -f "${cfg}" ]] || continue
    echo "--- ${cfg#${out_parent}/} ---"
    grep -E '^CONFIG_(MODVERSIONS|MODULES|MODULE_UNLOAD|CFI_CLANG|LTO_CLANG|LTO_CLANG_THIN)=' "${cfg}" 2>/dev/null || true
  done
  echo "  Nota: gate básico OK não substitui CRC completo de todos os tipos (KBUILD_SYMTYPES=1 se divergir)."

  KMI_CHECK_FAILED="${fail}"
}

audit_custom_feature_gate() {
  local root_dir="$1" out_parent="$2" dist_dir="$3"
  local fail=0
  local gki_cfg="${out_parent}/gki_kernel/common/.config"
  local system_map="${dist_dir}/System.map"

  CUSTOM_FEATURE_CHECK_FAILED=0
  echo ""
  echo "== Funcionalidades custom obrigatórias =="

  [[ -f "${gki_cfg}" ]] || gki_cfg="$(find "${out_parent}" -path '*/gki_kernel/*/.config' -print -quit 2>/dev/null)"

  for config in CONFIG_KSU=y CONFIG_KPM=y CONFIG_KSU_MANUAL_SU=y; do
    if [[ -f "${gki_cfg}" ]] && grep -qx "${config}" "${gki_cfg}"; then
      echo "  ${config}: OK"
    else
      echo "  ${config}: AUSENTE"
      fail=1
    fi
  done

  if [[ -f "${gki_cfg}" ]] && grep -qx 'CONFIG_KSU_SUSFS=y' "${gki_cfg}"; then
    if [[ "${ALLOW_UNVALIDATED_SUSFS_CORE:-0}" == "1" ]]; then
      echo "  CONFIG_KSU_SUSFS=y: AVISO — core SUSFS experimental por ALLOW_UNVALIDATED_SUSFS_CORE=1"
    else
      echo "  CONFIG_KSU_SUSFS=y: BLOQUEADO — core SUSFS ainda causa bootloop sem log/runtime validado"
      fail=1
    fi

    local -a unvalidated_susfs_hooks=(
      CONFIG_KSU_SUSFS_SUS_PATH
      CONFIG_KSU_SUSFS_SUS_MOUNT
      CONFIG_KSU_SUSFS_SUS_KSTAT
      CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS
      CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
      CONFIG_KSU_SUSFS_OPEN_REDIRECT
      CONFIG_KSU_SUSFS_SUS_MAP
    )
    local hook enabled_unvalidated_hook=0

    for hook in "${unvalidated_susfs_hooks[@]}"; do
      if grep -qx "${hook}=y" "${gki_cfg}"; then
        if [[ "${ALLOW_UNVALIDATED_SUSFS_HOOKS:-0}" == "1" ]]; then
          echo "  ${hook}=y: AVISO — override experimental ALLOW_UNVALIDATED_SUSFS_HOOKS=1"
        else
          echo "  ${hook}=y: BLOQUEADO — hook SUSFS ainda sem validação runtime pós-M02R"
          enabled_unvalidated_hook=1
        fi
      else
        echo "  ${hook}: OK (desativado no perfil boot-safe)"
      fi
    done

    if (( enabled_unvalidated_hook != 0 )); then
      fail=1
    fi
  else
    echo "  CONFIG_KSU_SUSFS: OK (desativado; SUSFS em quarentena pós-bootloop)"
  fi

  if [[ "${LOGSK_BUILD:-0}" == "1" ]]; then
    if [[ -f "${gki_cfg}" ]] && grep -qx 'CONFIG_LOGSK_BOOTLOGGER=y' "${gki_cfg}"; then
      echo "  CONFIG_LOGSK_BOOTLOGGER=y: OK (debug LOGSK)"
    else
      echo "  CONFIG_LOGSK_BOOTLOGGER=y: AUSENTE no build LOGSK_BUILD=1"
      fail=1
    fi
  elif [[ -f "${gki_cfg}" ]] && grep -qx 'CONFIG_LOGSK_BOOTLOGGER=y' "${gki_cfg}"; then
    echo "  CONFIG_LOGSK_BOOTLOGGER=y: AVISO — logger debug presente no Image"
  else
    echo "  CONFIG_LOGSK_BOOTLOGGER: OK (debug desativado)"
  fi

  for symbol in kernelsu_init kernelsu_exit apply_kernelsu_rules; do
    if [[ -f "${system_map}" ]] &&
       grep -Eq "[[:space:]][Tt][[:space:]]${symbol}$" "${system_map}"; then
      echo "  KernelSU símbolo ${symbol}: OK"
    else
      echo "  KernelSU símbolo ${symbol}: AUSENTE"
      fail=1
    fi
  done

  local hotplug_ko="${dist_dir}/cpu_hotplug.ko"
  local kgsl_ko="${dist_dir}/graphics/msm_kgsl.ko"
  local camera_ko="${dist_dir}/camera/camera.ko"
  if [[ -f "${hotplug_ko}" ]] &&
     modinfo -p "${hotplug_ko}" 2>/dev/null |
       grep -q 'cpu_hotplug_level:Maximum CPUs kept offline'; then
    echo "  cpu_hotplug_level (limite global 0-3): OK"
  else
    echo "  cpu_hotplug_level funcional: AUSENTE ou binário antigo"
    fail=1
  fi

  if [[ -f "${kgsl_ko}" ]] &&
     modinfo -p "${kgsl_ko}" 2>/dev/null |
       grep -q 'governor_call_interval_us:.*5000-50000'; then
    echo "  governor_call_interval_us (5000-50000 us): OK"
  else
    echo "  governor_call_interval_us funcional: AUSENTE"
    fail=1
  fi

  if [[ -f "${camera_ko}" ]] &&
     modinfo -p "${camera_ko}" 2>/dev/null |
       grep -q 'cam_perf_mode:Camera clock vote policy'; then
    echo "  cam_perf_mode (0 stock, 1 latência, 2 economia): OK"
  else
    echo "  cam_perf_mode funcional: AUSENTE"
    fail=1
  fi

  if sh -n "${root_dir}/scripts/m269-perfd.sh" 2>/dev/null &&
     grep -q '^#!/system/bin/sh$' "${root_dir}/scripts/m269-perfd.sh"; then
    echo "  m269-perfd compatível com shell Android: OK"
  else
    echo "  m269-perfd compatível com shell Android: FALHA"
    fail=1
  fi

  CUSTOM_FEATURE_CHECK_FAILED="${fail}"
}

audit_load_stock_vermagic_host() {
  local stock_vb_img="$1"
  [[ -f "${stock_vb_img}" ]] || return 0
  local work="${AUDIT_WORK_DIR:-}"
  [[ -n "${work}" ]] || return 0
  ROOT_DIR="${AUDIT_ROOT_DIR}"
  # shellcheck source=ramdisk_util.sh
  source "${ROOT_DIR}/scripts/lib/ramdisk_util.sh"
  vendor_boot_unpack_ramdisk "${stock_vb_img}" "${work}/stock_vm" >/dev/null 2>&1 || true
  local stock_ko="${work}/stock_vm/vendor_ramdisk_root/lib/modules/cpu_hotplug.ko"
  if [[ -f "${stock_ko}" ]]; then
    STOCK_HOTPLUG_HOST="$(modinfo -F vermagic "${stock_ko}" 2>/dev/null || true)"
    STOCK_MODULE_RELEASE_HOST="$(audit_vermagic_release "${STOCK_HOTPLUG_HOST}")"
    if [[ -z "${STOCK_MODULE_RELEASE}" ]]; then
      STOCK_HOTPLUG_FULL="${STOCK_HOTPLUG_HOST}"
      STOCK_MODULE_RELEASE="${STOCK_MODULE_RELEASE_HOST}"
    fi
  fi
}

audit_module_vermagic_block() {
  local dist_dir="$1"
  local -a custom_kos=(
    "cpu_hotplug:${dist_dir}/cpu_hotplug.ko"
    "msm_kgsl:${dist_dir}/graphics/msm_kgsl.ko"
    "camera:${dist_dir}/camera/camera.ko"
  )

  echo ""
  echo "== MODULE_VERMAGIC =="

  if [[ -n "${STOCK_HOTPLUG_HOST:-}" ]]; then
    echo "STOCK_MODULE_VERMAGIC (host vendor_boot):"
    echo "  ${STOCK_HOTPLUG_HOST}"
  fi

  if [[ -n "${DEVICE_CPU_HOTPLUG_VM}" ]]; then
    echo "STOCK_MODULE_VERMAGIC (device carregado):"
    echo "  ${DEVICE_CPU_HOTPLUG_VM}"
  fi

  local name path vm target="${TARGET_IMAGE_RELEASE}" stock="${STOCK_REFERENCE_RELEASE}"
  for entry in "${custom_kos[@]}"; do
    name="${entry%%:*}"
    path="${entry#*:}"
    [[ -f "${path}" ]] || { echo "  ${name}: AUSENTE"; MODULE_CHECK_FAIL=1; continue; }
    vm="$(modinfo -F vermagic "${path}" 2>/dev/null || true)"
    echo "  ${name}:"
    echo "    vermagic: ${vm}"
    local rel="$(audit_vermagic_release "${vm}")"
    if [[ -n "${target}" ]]; then
      if audit_release_exact_match "${rel}" "${target}"; then
        echo "    vs TARGET_IMAGE_RELEASE: OK (exato)"
      elif [[ "${rel%%-*}" == "${target%%-*}" || "${rel}" == "${target%%-*}" ]]; then
        echo "    vs TARGET_IMAGE_RELEASE: PARCIAL (base OK, sufixo diverge)"
        echo "      módulo: ${rel}"
        echo "      alvo:   ${target}"
        MODULE_CHECK_FAIL=1
      else
        echo "    vs TARGET_IMAGE_RELEASE: DIVERGE"
        echo "      módulo: ${rel}"
        echo "      alvo:   ${target}"
        MODULE_CHECK_FAIL=1
      fi
    fi
    if [[ -n "${stock}" && "${stock}" != "${target}" ]]; then
      if audit_release_exact_match "${rel}" "${stock}"; then
        echo "    vs STOCK_REFERENCE_RELEASE: OK (exato)"
      else
        echo "    vs STOCK_REFERENCE_RELEASE: diverge (esperado após migração)"
        echo "      módulo: ${rel}"
        echo "      stock:  ${stock}"
      fi
    fi
  done
}

audit_eval_pack_safe() {
  local root_dir="$1" dist_dir="$2"
  local flash_out="${FLASH_OUT:-${root_dir}/out/flash}"
  local boot_img="${flash_out}/boot.img"
  local vb_img="${flash_out}/vendor_boot.img"
  local dlkm_img="${flash_out}/vendor_dlkm.img"
  local deploy_report="${flash_out}/module_deploy_report.txt"
  local stock_dir="${STOCK_DIR:-${root_dir}/kernel_imgs/FILESKERNEL}"
  local stock_boot="${stock_dir}/boot.img"
  local stock_vb="${stock_dir}/vendor_boot.img"
  local stock_dlkm="${stock_dir}/vendor_dlkm.img"
  [[ -f "${stock_dlkm}" ]] ||
    stock_dlkm="${root_dir}/vendor_dlkm/vendor_dlkm.img"
  local fail=0

  PACK_SAFE="PENDENTE"
  echo ""
  echo "== PACK_SAFE (imagens finais empacotadas) =="

  [[ -f "${boot_img}" ]] || { echo "  boot.img: AUSENTE"; fail=1; }
  [[ -f "${vb_img}" ]] || { echo "  vendor_boot.img: AUSENTE"; fail=1; }
  [[ -f "${dlkm_img}" ]] || { echo "  vendor_dlkm.img: AUSENTE (gerar com deploy_kernel_modules.sh)"; fail=1; }
  [[ -f "${deploy_report}" ]] || { echo "  module_deploy_report.txt: AUSENTE"; fail=1; }

  if [[ "${fail}" -ne 0 ]]; then
    echo "  PACK_SAFE: PENDENTE — executar PULL=1 ./scripts/deploy_kernel_modules.sh"
    return 1
  fi

  echo "  boot.img:          $(stat -c '%s' "${boot_img}" 2>/dev/null || echo n/a) bytes"
  echo "  vendor_boot.img:   $(stat -c '%s' "${vb_img}" 2>/dev/null || echo n/a) bytes"
  echo "  vendor_dlkm.img:   $(stat -c '%s' "${dlkm_img}" 2>/dev/null || echo n/a) bytes"

  if grep -qiE 'BLOQUEIO|Deploy abortado|NÃO encontrado — risco Unknown symbol|PACK PARCIAL' \
      "${deploy_report}" 2>/dev/null; then
    echo "  deploy report: problemas de vermagic/deps detectados"
    PACK_SAFE="PENDENTE"
    return 1
  fi

  local artifact
  for artifact in \
    "${dist_dir}/Image" \
    "${dist_dir}/cpu_hotplug.ko" \
    "${dist_dir}/graphics/msm_kgsl.ko" \
    "${vb_img}" \
    "${dlkm_img}"; do
    if [[ "${artifact}" -nt "${deploy_report}" ]]; then
      echo "  deploy report: OBSOLETO em relação a ${artifact}"
      fail=1
    fi
  done

  local image
  for image in "${boot_img}" "${vb_img}" "${dlkm_img}"; do
    if command -v avbtool >/dev/null &&
       avbtool info_image --image "${image}" >/dev/null 2>&1; then
      echo "  $(basename "${image}") AVB: presente"
    else
      echo "  $(basename "${image}") AVB: AUSENTE/INVÁLIDO"
      fail=1
    fi
  done
  if [[ -f "${stock_boot}" ]] &&
     [[ "$(stat -c '%s' "${boot_img}")" != "$(stat -c '%s' "${stock_boot}")" ]]; then
    echo "  boot.img tamanho de partição: DIVERGE do stock"
    fail=1
  fi
  if [[ -f "${stock_vb}" ]] &&
     [[ "$(stat -c '%s' "${vb_img}")" != "$(stat -c '%s' "${stock_vb}")" ]]; then
    echo "  vendor_boot.img tamanho de partição: DIVERGE do stock"
    fail=1
  fi
  if [[ -f "${stock_dlkm}" ]] &&
     [[ "$(stat -c '%s' "${dlkm_img}")" != "$(stat -c '%s' "${stock_dlkm}")" ]]; then
    echo "  vendor_dlkm.img tamanho de partição: DIVERGE do stock"
    fail=1
  fi
  if avbtool info_image --image "${dlkm_img}" 2>/dev/null |
       grep -q 'Hashtree descriptor:'; then
    echo "  vendor_dlkm AVB hashtree: presente"
  else
    echo "  vendor_dlkm AVB hashtree: AUSENTE"
    fail=1
  fi
  if avbtool info_image --image "${dlkm_img}" 2>/dev/null |
       grep -q 'FEC num roots:.*2'; then
    echo "  vendor_dlkm FEC: 2 raízes"
  else
    echo "  vendor_dlkm FEC: DIVERGE do stock"
    fail=1
  fi
  if avbtool verify_image --image "${dlkm_img}" >/dev/null 2>&1; then
    echo "  vendor_dlkm AVB/hashtree: verificado"
  else
    echo "  vendor_dlkm AVB/hashtree: FALHOU"
    fail=1
  fi
  local compressed_files dlkm_xattr_size
  compressed_files="$(dump.erofs -S "${dlkm_img}" 2>/dev/null |
    awk -F: '/Filesystem compressed files:/ {gsub(/[[:space:]]/, "", $2); print $2}')"
  if [[ "${compressed_files:-n/a}" == "0" ]]; then
    echo "  vendor_dlkm EROFS: sem compressão, como stock"
  else
    echo "  vendor_dlkm EROFS: compressão diverge do stock (${compressed_files:-n/a} arquivos)"
    fail=1
  fi
  dlkm_xattr_size="$(dump.erofs --path=/lib/modules/msm_kgsl.ko "${dlkm_img}" 2>/dev/null |
    sed -n 's/.*Xattr size:[[:space:]]*\([0-9][0-9]*\).*/\1/p')"
  if [[ "${dlkm_xattr_size:-0}" -gt 0 ]]; then
    echo "  vendor_dlkm SELinux xattr: presente"
  else
    echo "  vendor_dlkm SELinux xattr: AUSENTE"
    fail=1
  fi

  local work="${AUDIT_WORK_DIR}/pack"
  ROOT_DIR="${root_dir}"
  # shellcheck source=ramdisk_util.sh
  source "${root_dir}/scripts/lib/ramdisk_util.sh"
  vendor_boot_unpack_ramdisk "${vb_img}" "${work}/vb" >/dev/null 2>&1 || true
  local vb_ko="${work}/vb/vendor_ramdisk_root/lib/modules/cpu_hotplug.ko"
  if [[ -f "${vb_ko}" ]]; then
    local rel="$(audit_vermagic_release "$(modinfo -F vermagic "${vb_ko}" 2>/dev/null || true)")"
    if audit_release_exact_match "${rel}" "${TARGET_IMAGE_RELEASE}"; then
      echo "  cpu_hotplug em vendor_boot.img: vermagic OK"
    else
      echo "  cpu_hotplug em vendor_boot.img: vermagic DIVERGE (${rel})"
      fail=1
    fi
  else
    echo "  cpu_hotplug em vendor_boot.img: não encontrado no ramdisk"
    fail=1
  fi

  local unpack_py="${root_dir}/kernel_platform/tools/mkbootimg/unpack_bootimg.py"
  local boot_unpack="${work}/boot"
  mkdir -p "${boot_unpack}"
  python3 "${unpack_py}" --boot_img "${boot_img}" --out "${boot_unpack}" \
    >/dev/null 2>&1 || true
  if [[ -f "${boot_unpack}/kernel" ]] &&
     cmp -s "${boot_unpack}/kernel" "${dist_dir}/Image"; then
    echo "  Image dentro de boot.img: OK"
  else
    echo "  Image dentro de boot.img: DIVERGE"
    fail=1
  fi

  local extract_ikconfig="${root_dir}/kernel_platform/common/scripts/extract-ikconfig"
  local boot_cfg="${boot_unpack}/kernel.config"
  if [[ -x "${extract_ikconfig}" && -f "${boot_unpack}/kernel" ]] &&
     "${extract_ikconfig}" "${boot_unpack}/kernel" > "${boot_cfg}" 2>"${boot_unpack}/extract_ikconfig.err"; then
    local required_config pstore_bytes
    for required_config in CONFIG_KSU=y CONFIG_KPM=y CONFIG_KSU_MANUAL_SU=y; do
      if grep -qx "${required_config}" "${boot_cfg}"; then
        echo "  boot.img config ${required_config}: OK"
      else
        echo "  boot.img config ${required_config}: AUSENTE"
        fail=1
      fi
    done
    if grep -qx 'CONFIG_KSU_SUSFS=y' "${boot_cfg}"; then
      echo "  boot.img config CONFIG_KSU_SUSFS=y: BLOQUEADO no perfil AP boot-safe"
      fail=1
    else
      echo "  boot.img config CONFIG_KSU_SUSFS: OK (desativado)"
    fi
    if grep -qx 'CONFIG_MODULE_REL_CRCS=y' "${boot_cfg}"; then
      echo "  boot.img config CONFIG_MODULE_REL_CRCS=y: BLOQUEADO (não bate com AP que sobe)"
      fail=1
    else
      echo "  boot.img config CONFIG_MODULE_REL_CRCS: OK (ausente/desativado)"
    fi
    if [[ "${LOGSK_BUILD:-0}" == "1" ]]; then
      if grep -qx 'CONFIG_LOGSK_BOOTLOGGER=y' "${boot_cfg}"; then
        echo "  boot.img config CONFIG_LOGSK_BOOTLOGGER=y: OK"
      else
        echo "  boot.img config CONFIG_LOGSK_BOOTLOGGER=y: AUSENTE no build LOGSK_BUILD=1"
        fail=1
      fi
    elif grep -qx 'CONFIG_LOGSK_BOOTLOGGER=y' "${boot_cfg}"; then
      echo "  boot.img config CONFIG_LOGSK_BOOTLOGGER=y: AVISO — logger debug presente"
    else
      echo "  boot.img config CONFIG_LOGSK_BOOTLOGGER: OK (debug desativado)"
    fi
    pstore_bytes="$(sed -n 's/^CONFIG_PSTORE_DEFAULT_KMSG_BYTES=//p' "${boot_cfg}" | head -1)"
    if [[ "${pstore_bytes}" == "10240" ]]; then
      echo "  boot.img config PSTORE_DEFAULT_KMSG_BYTES=10240: OK"
    else
      echo "  boot.img config PSTORE_DEFAULT_KMSG_BYTES=${pstore_bytes:-n/a}: DIVERGE do AP que sobe"
      fail=1
    fi
  else
    echo "  boot.img config: não foi possível extrair IKCONFIG"
    fail=1
  fi

  if [[ -f "${stock_boot}" ]]; then
    local stock_boot_unpack="${work}/stock_boot"
    mkdir -p "${stock_boot_unpack}"
    python3 "${unpack_py}" --boot_img "${stock_boot}" --out "${stock_boot_unpack}" \
      >/dev/null 2>&1 || true
    if [[ -f "${boot_unpack}/ramdisk" && -f "${stock_boot_unpack}/ramdisk" ]] &&
       cmp -s "${boot_unpack}/ramdisk" "${stock_boot_unpack}/ramdisk"; then
      echo "  boot.img ramdisk: stock preservado"
    else
      echo "  boot.img ramdisk: DIVERGE do stock"
      fail=1
    fi
  fi

  if [[ -f "${stock_vb}" ]]; then
    local stock_unpack="${work}/stock_vb"
    mkdir -p "${stock_unpack}"
    python3 "${unpack_py}" --boot_img "${stock_vb}" --out "${stock_unpack}" \
      >/dev/null 2>&1 || true
    if [[ -f "${stock_unpack}/dtb" && -f "${work}/vb/vb_unpacked/dtb" ]] &&
       cmp -s "${stock_unpack}/dtb" "${work}/vb/vb_unpacked/dtb"; then
      echo "  DTB vendor_boot: stock preservado"
    elif [[ "${ALLOW_CUSTOM_DTB:-0}" == "1" ]]; then
      echo "  DTB vendor_boot: custom autorizado por ALLOW_CUSTOM_DTB=1"
    else
      echo "  DTB vendor_boot: DIVERGE do stock (validar SKU antes de autorizar)"
      fail=1
    fi
  fi

  if command -v fsck.erofs >/dev/null && [[ -f "${dlkm_img}" ]]; then
    local dlkm_root="${work}/dlkm"
    local stock_dlkm_root="${work}/stock_dlkm"
    mkdir -p "${dlkm_root}"
    if ! fsck.erofs --extract="${dlkm_root}" "${dlkm_img}" >/dev/null 2>&1; then
      echo "  vendor_dlkm EROFS: extração/integridade FALHOU"
      fail=1
    fi
    mkdir -p "${stock_dlkm_root}"
    if ! fsck.erofs --extract="${stock_dlkm_root}" "${stock_dlkm}" >/dev/null 2>&1; then
      echo "  vendor_dlkm stock: extração/integridade FALHOU"
      fail=1
    fi
    if grep -qx 'ro.product.vendor_dlkm.model=SM-A057M' \
         "${dlkm_root}/etc/build.prop" 2>/dev/null &&
       grep -qx 'ro.vendor_dlkm.build.version.incremental=A057MUBSADYG1' \
         "${dlkm_root}/etc/build.prop" 2>/dev/null; then
      echo "  vendor_dlkm identidade: SM-A057M/A057MUBSADYG1"
    else
      echo "  vendor_dlkm identidade: DIVERGE"
      fail=1
    fi
    for pair in \
      "cpu_hotplug:custom:cpu_hotplug.ko" \
      "msm_kgsl:custom:graphics/msm_kgsl.ko" \
      "camera:custom:camera/camera.ko"; do
      local mname="${pair%%:*}" expected relpath
      pair="${pair#*:}"
      expected="${pair%%:*}"
      relpath="${pair#*:}"
      local found source_ko
      found="$(find "${dlkm_root}" -name "${mname}.ko" -print -quit 2>/dev/null || true)"
      if [[ "${expected}" == "stock" ]]; then
        source_ko="${stock_dlkm_root}/lib/modules/${mname}.ko"
      else
        source_ko="${flash_out}/prepared_modules/${mname}.ko"
      fi
      if [[ -n "${found}" ]]; then
        rel="$(audit_vermagic_release "$(modinfo -F vermagic "${found}" 2>/dev/null || true)")"
        if audit_release_exact_match "${rel}" "${TARGET_IMAGE_RELEASE}"; then
          echo "  ${mname} em vendor_dlkm.img: vermagic OK"
        else
          echo "  ${mname} em vendor_dlkm.img: vermagic DIVERGE"
          fail=1
        fi
        if [[ -f "${source_ko}" ]] && cmp -s "${found}" "${source_ko}"; then
          echo "  ${mname} em vendor_dlkm.img: binário ${expected} exato"
        else
          echo "  ${mname} em vendor_dlkm.img: binário DIVERGE do esperado (${expected})"
          fail=1
        fi
      else
        echo "  ${mname} em vendor_dlkm.img: não encontrado (confirmar nome/path no stock)"
        fail=1
      fi
    done
  else
    echo "  vendor_dlkm conteúdo: auditoria interna pendente (fsck.erofs ausente ou imagem inválida)"
    fail=1
  fi

  if [[ "${fail}" -eq 0 ]]; then
    PACK_SAFE="SIM"
    echo "  PACK_SAFE: SIM"
    return 0
  fi
  PACK_SAFE="PENDENTE"
  echo "  PACK_SAFE: PENDENTE"
  return 1
}

audit_eval_flash_layout_safe() {
  local root_dir="$1"
  local report="${FLASH_OUT:-${root_dir}/out/flash}/flash_layout_report.txt"

  FLASH_LAYOUT_SAFE="PENDENTE"
  echo ""
  echo "== FLASH_LAYOUT_SAFE (partições / slot / AVB) =="

  if [[ ! -f "${report}" ]]; then
    echo "  flash_layout_report.txt: AUSENTE"
    echo "  Executar: ./scripts/discover_flash_layout.sh"
    echo "  FLASH_LAYOUT_SAFE: PENDENTE"
    return 1
  fi

  local has_dlkm=0 has_slot=0 unlocked=0 sizes=0 boot_state="NÃO CONFIRMADO"
  local unlock_report unlock_source boot_prop_state vendor_boot_prop_state verified_prop_state
  local bc_verified bc_ulcnt bc_warranty boot_key_match vb_key_match
  grep -qx 'VENDOR_DLKM_PRESENT: SIM' "${report}" && has_dlkm=1
  grep -qE '^SLOT_SUFFIX: (_a|_b|NONE)$' "${report}" && has_slot=1
  unlock_report="$(sed -n 's/^BOOTLOADER_UNLOCKED: //p' "${report}" | tail -1)"
  unlock_source="$(sed -n 's/^BOOTLOADER_UNLOCK_SOURCE: //p' "${report}" | tail -1)"
  boot_prop_state="$(sed -n 's/^ro.boot.vbmeta.device_state: //p' "${report}" | tail -1)"
  vendor_boot_prop_state="$(sed -n 's/^vendor.boot.vbmeta.device_state: //p' "${report}" | tail -1)"
  verified_prop_state="$(sed -n 's/^ro.boot.verifiedbootstate: //p' "${report}" | tail -1)"
  bc_verified="$(sed -n 's/^bootconfig.androidboot.verifiedbootstate: //p' "${report}" | tail -1)"
  bc_ulcnt="$(sed -n 's/^bootconfig.androidboot.ulcnt: //p' "${report}" | tail -1)"
  bc_warranty="$(sed -n 's/^bootconfig.androidboot.warranty_bit: //p' "${report}" | tail -1)"
  boot_key_match="$(sed -n 's/^boot_avb_key_matches_stock: //p' "${report}" | tail -1)"
  vb_key_match="$(sed -n 's/^vendor_boot_avb_key_matches_stock: //p' "${report}" | tail -1)"
  if [[ "${unlock_report}" == "SIM" ]]; then
    unlocked=1
    boot_state="SIM"
  elif [[ "${unlock_report}" == "NÃO" ]]; then
    boot_state="NÃO"
  fi
  grep -qx 'PARTITION_SIZES_VALID: SIM' "${report}" && sizes=1

  echo "  Relatório: ${report}"
  echo "  vendor_dlkm identificado: $([[ ${has_dlkm} -eq 1 ]] && echo SIM || echo NÃO)"
  echo "  Slot identificado:        $([[ ${has_slot} -eq 1 ]] && echo SIM || echo NÃO)"
  echo "  Bootloader desbloqueado:  ${boot_state}"
  echo "  Fonte unlock:             ${unlock_source:-n/a}"
  echo "  getprop vbmeta/device:    ${boot_prop_state:-n/a}/${vendor_boot_prop_state:-n/a}"
  echo "  getprop verified state:   ${verified_prop_state:-n/a}"
  echo "  bootconfig verified:      ${bc_verified:-n/a}"
  echo "  bootconfig ulcnt/warranty:${bc_ulcnt:-n/a}/${bc_warranty:-n/a}"
  echo "  boot/vendor_boot AVB key: ${boot_key_match:-n/a}/${vb_key_match:-n/a}"
  echo "  Tamanhos validados:       $([[ ${sizes} -eq 1 ]] && echo SIM || echo NÃO)"

  if [[ "${has_dlkm}" -eq 1 && "${has_slot}" -eq 1 &&
        "${unlocked}" -eq 1 && "${sizes}" -eq 1 ]]; then
    FLASH_LAYOUT_SAFE="SIM"
    echo "  FLASH_LAYOUT_SAFE: SIM"
    return 0
  fi

  if [[ "${boot_state}" == "NÃO" ]]; then
    FLASH_LAYOUT_SAFE="NÃO"
    echo "  FLASH_LAYOUT_SAFE: NÃO — bootloader/vbmeta reportado como bloqueado"
    return 1
  fi

  if [[ "${has_dlkm}" -eq 1 && "${has_slot}" -eq 1 && "${sizes}" -eq 1 ]]; then
    echo "  FLASH_LAYOUT_SAFE: PENDENTE — layout confirmado; estado bootloader/AVB não confirmado"
  else
    echo "  FLASH_LAYOUT_SAFE: PENDENTE — completar descoberta de layout"
  fi
  return 1
}

audit_eval_runtime_validated() {
  KERNEL_RUNTIME_VALIDATED="NÃO"
  RUNTIME_VALIDATED="NÃO"
  echo ""
  echo "== RUNTIME_VALIDATED (boot + módulos carregados) =="

  command -v adb >/dev/null || { echo "  adb: ausente"; return 1; }
  adb get-state >/dev/null 2>&1 || { echo "  dispositivo: offline"; return 1; }

  local running boot_completed loaded_hotplug loaded_kgsl loaded_camera
  running="$(adb shell uname -r 2>/dev/null | tr -d '\r')"
  boot_completed="$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')"
  echo "  uname -r: ${running}"
  echo "  sys.boot_completed: ${boot_completed:-n/a}"

  if [[ -n "${TARGET_IMAGE_RELEASE}" && "${running}" == "${TARGET_IMAGE_RELEASE}" &&
        "${boot_completed}" == "1" ]]; then
    echo "  kernel release: OK"
    KERNEL_RUNTIME_VALIDATED="SIM"
    echo "  KERNEL_RUNTIME_VALIDATED: SIM"
  else
    echo "  kernel release: diverge do TARGET_IMAGE_RELEASE (${TARGET_IMAGE_RELEASE:-n/a})"
    return 1
  fi

  loaded_hotplug="$(adb shell "su -c 'grep cpu_hotplug /proc/modules'" 2>/dev/null | tr -d '\r' || true)"
  loaded_kgsl="$(adb shell "su -c 'grep msm_kgsl /proc/modules'" 2>/dev/null | tr -d '\r' || true)"
  loaded_camera="$(adb shell "su -c 'grep -E \"^camera |/camera\\.ko\" /proc/modules'" 2>/dev/null | tr -d '\r' || true)"

  [[ -n "${loaded_hotplug}" ]] && echo "  cpu_hotplug: carregado" || echo "  cpu_hotplug: NÃO carregado"
  [[ -n "${loaded_kgsl}" ]] && echo "  msm_kgsl: carregado" || echo "  msm_kgsl: NÃO carregado"
  [[ -n "${loaded_camera}" ]] && echo "  camera: carregado" || echo "  camera: NÃO carregado"

  local exact_modules=1 spec name host_ko phone_path host_hash phone_hash expected
  for spec in \
    "cpu_hotplug:custom:${FLASH_OUT:-${AUDIT_ROOT_DIR}/out/flash}/prepared_modules/cpu_hotplug.ko" \
    "msm_kgsl:custom:${FLASH_OUT:-${AUDIT_ROOT_DIR}/out/flash}/prepared_modules/msm_kgsl.ko" \
    "camera:custom:${FLASH_OUT:-${AUDIT_ROOT_DIR}/out/flash}/prepared_modules/camera.ko"; do
    name="${spec%%:*}"
    spec="${spec#*:}"
    expected="${spec%%:*}"
    host_ko="${spec#*:}"
    phone_path="$(adb shell "su -c 'find /vendor_dlkm -name ${name}.ko 2>/dev/null | head -1'" \
      2>/dev/null | tr -d '\r' || true)"
    host_hash="$(sha256sum "${host_ko}" 2>/dev/null | awk '{print $1}' || true)"
    phone_hash=""
    [[ -n "${phone_path}" ]] && \
      phone_hash="$(adb shell "su -c 'sha256sum ${phone_path}'" 2>/dev/null |
        awk '{print $1}' | tr -d '\r' || true)"
    if [[ -n "${host_hash}" && "${phone_hash}" == "${host_hash}" ]]; then
      echo "  ${name}: binário ${expected} exato em vendor_dlkm"
    else
      echo "  ${name}: binário ativo na partição NÃO corresponde ao esperado (${expected})"
      exact_modules=0
    fi
  done

  local hotplug_param kgsl_param camera_param
  hotplug_param="$(adb shell "su -c 'cat /sys/module/cpu_hotplug/parameters/cpu_hotplug_level 2>/dev/null'" \
    2>/dev/null | tr -d '\r' || true)"
  kgsl_param="$(adb shell "su -c 'cat /sys/module/msm_kgsl/parameters/governor_call_interval_us 2>/dev/null'" \
    2>/dev/null | tr -d '\r' || true)"
  camera_param="$(adb shell "su -c 'cat /sys/module/camera/parameters/cam_perf_mode 2>/dev/null'" \
    2>/dev/null | tr -d '\r' || true)"
  [[ -n "${hotplug_param}" ]] && echo "  cpu_hotplug_level: ${hotplug_param}" ||
    echo "  cpu_hotplug_level: AUSENTE"
  [[ -n "${kgsl_param}" ]] && echo "  governor_call_interval_us: ${kgsl_param}" ||
    echo "  governor_call_interval_us: AUSENTE"
  [[ -n "${camera_param}" ]] && echo "  cam_perf_mode: ${camera_param}" ||
    echo "  cam_perf_mode: AUSENTE"

  local dmesg_err
  dmesg_err="$(adb shell "su -c 'dmesg | grep -iE \"Unknown symbol|invalid module format\" | tail -5'" 2>/dev/null | tr -d '\r' || true)"
  if [[ -n "${dmesg_err}" ]]; then
    echo "  dmesg erros módulo:"
    echo "${dmesg_err}" | sed 's/^/    /'
    return 1
  fi

  if [[ -n "${loaded_hotplug}" && -n "${loaded_kgsl}" && -n "${loaded_camera}" &&
        "${exact_modules}" -eq 1 && -n "${hotplug_param}" && -n "${kgsl_param}" &&
        -n "${camera_param}" ]]; then
    RUNTIME_VALIDATED="SIM"
    echo "  RUNTIME_VALIDATED: SIM"
    return 0
  fi

  echo "  RUNTIME_VALIDATED: NÃO — kernel iniciou; DLKM custom e parâmetros ainda pendentes"
  return 1
}

audit_print_gate_summary() {
  local build_ok="${1:-0}"
  FLASH_READY="NÃO"
  [[ "${PACK_SAFE:-PENDENTE}" == "SIM" && "${FLASH_LAYOUT_SAFE:-PENDENTE}" == "SIM" ]] && FLASH_READY="SIM"

  echo ""
  echo "== Gates de deploy / flash =="
  echo "BUILD_SAFE:          $([[ ${build_ok} -eq 0 ]] && echo SIM || echo NÃO)"
  echo "PACK_SAFE:           ${PACK_SAFE:-PENDENTE}"
  echo "FLASH_LAYOUT_SAFE:   ${FLASH_LAYOUT_SAFE:-PENDENTE}"
  echo "KERNEL_RUNTIME_VALIDATED: ${KERNEL_RUNTIME_VALIDATED:-NÃO}"
  echo "RUNTIME_VALIDATED:   ${RUNTIME_VALIDATED:-NÃO}"
  echo ""
  echo "FLASH_READY:         ${FLASH_READY}"
  echo ""
  if [[ "${build_ok}" -eq 0 ]]; then
    echo "  Build compatível no host (BUILD_SAFE: SIM)."
    if [[ "${FLASH_READY}" == "SIM" ]]; then
      echo "  Imagens empacotadas e layout conhecidos — elegível para flash incremental."
      echo "  NÃO equivale a RUNTIME_VALIDATED — validar boot e módulos após cada partição."
    elif [[ "${PACK_SAFE:-PENDENTE}" == "SIM" ]]; then
      echo "  Imagens empacotadas; falta confirmar layout/slot ou estado bootloader/AVB."
      echo "  Consulte: out/flash/flash_layout_report.txt"
    else
      echo "  Flash pendente de PACK_SAFE + FLASH_LAYOUT_SAFE."
      echo "  Próximo: PULL=1 ./scripts/deploy_kernel_modules.sh && ./scripts/discover_flash_layout.sh"
    fi
  else
    echo "  BUILD_SAFE: NÃO — não gerar nem flashear imagens até alinhar release/KMI."
  fi
}

audit_build_gate() {
  local root_dir="$1" out_parent="$2" dist_dir="$3" stock_vb="$4"
  AUDIT_BUILD_ONLY=1
  audit_full_report "${root_dir}" "${out_parent}" "${dist_dir}" "${stock_vb}" >/dev/null
  unset AUDIT_BUILD_ONLY
  [[ "${BUILD_SAFE:-NÃO}" == "SIM" ]]
}

audit_full_report() {
  local root_dir="$1" out_parent="$2" dist_dir="$3" stock_vb="$4"
  local build_fail=0
  BUILD_SAFE="NÃO"
  PACK_SAFE="PENDENTE"
  FLASH_LAYOUT_SAFE="PENDENTE"
  KERNEL_RUNTIME_VALIDATED="NÃO"
  RUNTIME_VALIDATED="NÃO"
  FLASH_READY="NÃO"

  DIST_DIR="${dist_dir}"
  AUDIT_ROOT_DIR="${root_dir}"
  AUDIT_WORK_DIR="$(mktemp -d)"
  MODULE_CHECK_FAIL=0
  KMI_CHECK_FAILED=0
  CUSTOM_FEATURE_CHECK_FAILED=0
  TARGET_IMAGE_RELEASE=""
  TARGET_IMAGE_SOURCE=""
  STOCK_REFERENCE_RELEASE=""
  STOCK_REFERENCE_SOURCE=""
  REFERENCE_RELEASE=""
  STOCK_MODULE_RELEASE=""
  STOCK_HOTPLUG_FULL=""
  DEVICE_CPU_HOTPLUG_VM=""
  RUNNING_DEVICE_RELEASE=""

  echo "Auditoria kernel release / vermagic / KMI"
  echo "Root:   ${root_dir}"
  echo "Out:    ${out_parent}"
  echo "Dist:   ${dist_dir}"
  echo ""

  audit_collect_releases "${root_dir}" "${out_parent}"
  audit_resolve_target_image_release
  audit_adb_device_release
  audit_load_stock_vermagic_host "${stock_vb}"

  audit_pick_stock_reference_release
  echo "== Releases (5 níveis + alvo/stock) =="
  audit_print_release_block
  [[ -n "${STOCK_REFERENCE_WARN:-}" ]] && echo "  AVISO stock: ${STOCK_REFERENCE_WARN}"
  echo ""
  echo "Regra central: MODULE_VERMAGIC == TARGET_IMAGE_RELEASE"
  echo "Compatibilidade stock: TARGET_IMAGE_RELEASE == STOCK_REFERENCE_RELEASE"

  if [[ -n "${RUNNING_DEVICE_RELEASE}" ]]; then
    echo "RUNNING_DEVICE_RELEASE: ${RUNNING_DEVICE_RELEASE}"
    command -v adb >/dev/null && adb shell uname -a 2>/dev/null | sed 's/^/  /' || true
  else
    echo "RUNNING_DEVICE_RELEASE: n/a (adb offline ou sem permissão)"
  fi

  audit_print_kernel_release_files "${out_parent}"

  audit_module_vermagic_block "${dist_dir}"
  audit_kmi_gate "${dist_dir}" "${out_parent}"
  audit_custom_feature_gate "${root_dir}" "${out_parent}" "${dist_dir}"

  echo ""
  echo "== Classificação =="
  if audit_classify_case; then
    echo "DIAGNÓSTICO: BUILD_SAFE"
  else
    echo "DIAGNÓSTICO: ${AUDIT_CASE_PRIMARY}"
    for c in "${AUDIT_CASES[@]}"; do
      echo "  - ${c}"
    done
    build_fail=1
  fi

  case "${AUDIT_CASE_PRIMARY}" in
    CASE_STALE_VENDOR_OUT)
      echo "  → Output vendor antigo; rodar clean build (SKIP_MRPROPER=0 FAST_BUILD=0)."
      ;;
    CASE_VENDOR_SOURCE_TOO_OLD)
      echo "  → msm-kernel source (${VENDOR_SOURCE_RELEASE}) atrás do GKI (${GKI_OUTPUT_RELEASE})."
      echo "  → Alinhar release vendor ao GKI via mixed build (SUBLEVEL + artefatos gki_kernel/dist)."
      ;;
    CASE_EXT_MODULE_WRONG_OUTPUT)
      echo "  → camera/kgsl compilados com O= ou mirror desatualizado."
      ;;
    CASE_TARGET_IMAGE_LOCALVERSION_MISMATCH)
      echo "  → Image custom (${TARGET_IMAGE_RELEASE}) não usa o release exato dos módulos stock."
      echo "  → boot.img custom bloqueado — stock first-stage rejeitará módulos com sufixo divergente."
      echo "  → Configurar release completo e recompilar Image + módulos."
      ;;
    CASE_MODULE_LOCALVERSION_MISMATCH)
      echo "  → Módulo custom não corresponde ao TARGET_IMAGE_RELEASE (${TARGET_IMAGE_RELEASE})."
      echo "  → Regra: MODULE_VERMAGIC == TARGET_IMAGE_RELEASE."
      ;;
    CASE_KMI_SYMBOL_MISMATCH)
      echo "  → Símbolos não resolvidos em Module.symvers — problema KMI, não só vermagic."
      ;;
    CASE_CUSTOM_FEATURE_MISSING)
      echo "  → Uma funcionalidade custom obrigatória não está no binário final."
      ;;
  esac

  [[ "${MODULE_CHECK_FAIL}" -eq 1 ]] && build_fail=1
  [[ "${KMI_CHECK_FAILED:-0}" -eq 1 ]] && build_fail=1
  [[ "${CUSTOM_FEATURE_CHECK_FAILED:-0}" -eq 1 ]] && build_fail=1
  [[ -z "${TARGET_IMAGE_RELEASE}" ]] && build_fail=1

  if [[ "${build_fail}" -eq 0 ]]; then
    BUILD_SAFE="SIM"
    echo ""
    echo "BUILD_SAFE: SIM"
    echo "  TARGET_IMAGE_RELEASE conhecido:           SIM"
    echo "  TARGET_IMAGE_RELEASE == stock (preservar): SIM"
    echo "  módulos custom == TARGET_IMAGE_RELEASE:   SIM"
    echo "  KMI básico (+ module_layout):             SIM"
    echo ""
    echo "  Estado: BUILD COMPATÍVEL NO HOST — elegível para deploy/empacotamento."
    echo "  NÃO equivale a flash seguro nem runtime validado."
  else
    BUILD_SAFE="NÃO"
    echo ""
    echo "BUILD_SAFE: NÃO"
    echo "  Não prosseguir com deploy/flash até alinhar release, vermagic e KMI."
  fi

  if [[ "${AUDIT_BUILD_ONLY:-0}" == "1" ]]; then
    if [[ "${build_fail}" -eq 0 ]]; then
      rm -rf "${AUDIT_WORK_DIR}"
      return 0
    fi
    if [[ "${ALLOW_VERMAGIC_MISMATCH:-0}" == "1" ]]; then
      rm -rf "${AUDIT_WORK_DIR}"
      return 0
    fi
    rm -rf "${AUDIT_WORK_DIR}"
    return 1
  fi

  audit_eval_pack_safe "${root_dir}" "${dist_dir}" || true
  audit_eval_flash_layout_safe "${root_dir}" || true
  audit_eval_runtime_validated || true
  audit_print_gate_summary "${build_fail}"

  if [[ "${build_fail}" -eq 0 ]]; then
    rm -rf "${AUDIT_WORK_DIR}"
    if [[ "${REQUIRE_FLASH_READY:-0}" == "1" && "${FLASH_READY}" != "SIM" ]]; then
      return 2
    fi
    return 0
  fi

  if [[ "${ALLOW_VERMAGIC_MISMATCH:-0}" == "1" ]]; then
    echo "ALLOW_VERMAGIC_MISMATCH=1 — modo dev (NÃO usar no aparelho principal)."
    rm -rf "${AUDIT_WORK_DIR}"
    return 0
  fi
  rm -rf "${AUDIT_WORK_DIR}"
  return 1
}
