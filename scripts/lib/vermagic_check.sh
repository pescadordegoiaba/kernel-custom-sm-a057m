# Funções compartilhadas de vermagic / kernel release.
# shellcheck shell=bash

vermagic_kernel_release() {
  local vm="$1"
  echo "${vm%% *}"
}

image_linux_version() {
  local image="$1"
  strings "${image}" 2>/dev/null | grep -m1 '^Linux version ' || true
}

image_kernel_release() {
  local line
  line="$(image_linux_version "$1")"
  [[ -n "${line}" ]] || return 1
  # Linux version 5.15.167-android13-8-ab (build-user@...) #1 SMP ...
  echo "${line}" | awk '{print $3}'
}

vermagic_compatible() {
  local custom_vm="$1" reference_vm="$2"
  local c_ref r_ref
  c_ref="$(vermagic_kernel_release "${custom_vm}")"
  r_ref="$(vermagic_kernel_release "${reference_vm}")"
  [[ -n "${c_ref}" && -n "${r_ref}" && "${c_ref}" == "${r_ref}" ]]
}

vermagic_matches_image() {
  local custom_vm="$1" image="$2"
  local c_rel i_rel
  c_rel="$(vermagic_kernel_release "${custom_vm}")"
  i_rel="$(image_kernel_release "${image}")"
  [[ -n "${c_rel}" && -n "${i_rel}" && "${c_rel}" == "${i_rel}" ]]
}

audit_vermagic_block() {
  local dist_dir="$1" stock_vb_img="$2" image_path="$3"
  local root_dir="${VERMAGIC_ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  local out_parent="${VERMAGIC_OUT_PARENT:-${root_dir}/out/kernel-m269-thinlto}"
  if [[ "${root_dir}" == *" "* ]]; then
    out_parent="${VERMAGIC_OUT_PARENT:-$(dirname "${root_dir}")/Kernel-A15-build/out/kernel-m269-thinlto}"
  fi
  # shellcheck source=kernel_release_audit.sh
  source "${root_dir}/scripts/lib/kernel_release_audit.sh"
  if audit_build_gate "${root_dir}" "${out_parent}" "${dist_dir}" "${stock_vb_img}"; then
    echo "Pré-checagem BUILD_SAFE: SIM"
    return 0
  fi
  echo "Pré-checagem BUILD_SAFE: NÃO — deploy bloqueado"
  audit_full_report "${root_dir}" "${out_parent}" "${dist_dir}" "${stock_vb_img}" >&2 || true
  return 1
}