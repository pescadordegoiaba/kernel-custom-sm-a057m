#!/usr/bin/env bash
# Host-side semantic contract checks across scripts, Python, C/C++ headers and
# kernel module ABI metadata. This script never flashes.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${BUILD_ROOT:-$(dirname "${ROOT_DIR}")/Kernel-A15-build}"
OUT_PARENT="${OUT_PARENT:-${BUILD_ROOT}/out/kernel-m269-thinlto}"
DIST_DIR="${DIST_DIR:-${ROOT_DIR}/out/kernel-m269-thinlto/dist}"
REPORT="${REPORT:-${ROOT_DIR}/out/semantic/semantic_report.txt}"
TOOLCHAIN_DIR="${TOOLCHAIN_DIR:-${BUILD_ROOT}/kernel_platform/prebuilts/clang/host/linux-x86/clang-r450784e}"

# shellcheck source=lib/module_abi.sh
source "${ROOT_DIR}/scripts/lib/module_abi.sh"

mkdir -p "$(dirname "${REPORT}")"
exec > >(tee "${REPORT}") 2>&1

fail_count=0

fail() {
  echo "[FAIL] $*"
  fail_count=$((fail_count + 1))
}

pass() {
  echo "[PASS] $*"
}

require_file() {
  [[ -f "$1" ]] || {
    fail "arquivo ausente: $1"
    return 1
  }
}

tool() {
  local name="$1"
  if [[ -x "${TOOLCHAIN_DIR}/bin/${name}" ]]; then
    printf '%s\n' "${TOOLCHAIN_DIR}/bin/${name}"
  else
    command -v "${name}" || true
  fi
}

check_shell_syntax() {
  local script
  local -a bash_scripts=(
    "${ROOT_DIR}/build_kernel_thinlto.sh"
    "${ROOT_DIR}/build_ext_modules.sh"
    "${ROOT_DIR}/pack_flash_images.sh"
  )

  while IFS= read -r -d '' script; do
    bash_scripts+=("${script}")
  done < <(find "${ROOT_DIR}/scripts" -type f -name '*.sh' -print0)

  for script in "${bash_scripts[@]}"; do
    bash -n "${script}" || fail "sintaxe bash: ${script#${ROOT_DIR}/}"
  done
  sh -n "${ROOT_DIR}/scripts/m269-perfd.sh" ||
    fail "sintaxe sh: scripts/m269-perfd.sh"
  pass "scripts shell sintaticamente válidos"
}

check_python_syntax() {
  local py
  while IFS= read -r -d '' py; do
    python3 -m py_compile "${py}" || fail "py_compile: ${py#${ROOT_DIR}/}"
  done < <(find "${ROOT_DIR}/scripts/lib" -type f -name '*.py' -print0)
  pass "bibliotecas Python compilam"
}

check_android_bp_sources() {
  if python3 - "${ROOT_DIR}" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
allowed_prefixes = (
    pathlib.Path("art/dt_fd_forward"),
    pathlib.Path("art/openjdkjvm"),
    pathlib.Path("system/bpfprogs"),
)
missing = []
for bp in root.rglob("Android.bp"):
    if any(part in {"out", ".git"} for part in bp.parts):
        continue
    rel_bp = bp.relative_to(root)
    if not any(rel_bp.is_relative_to(prefix) for prefix in allowed_prefixes):
        continue
    text = bp.read_text(errors="ignore")
    for match in re.finditer(r'"([^"]+\.(?:c|cc|cpp))"', text):
        ref = match.group(1)
        if ref.startswith(":") or "*" in ref:
            continue
        if not (bp.parent / ref).exists():
            missing.append(f"{rel_bp}: {ref}")
if missing:
    print("\n".join(missing))
    sys.exit(1)
PY
  then
    pass "Android.bp referencia fontes presentes"
  else
    fail "Android.bp referencia fonte ausente"
  fi
}

check_cpp_contracts() {
  local cxx
  cxx="$(tool clang++)"
  [[ -n "${cxx}" ]] || {
    fail "clang++ ausente para contratos C++"
    return
  }

  local work
  work="$(mktemp -d)"
  trap 'rm -rf "${work}"' RETURN

  cat > "${work}/fd_transport_contract.cc" <<'EOF'
#include "fd_transport.h"

#include <cstring>
#include <type_traits>

static_assert(std::is_standard_layout<dt_fd_forward::FdSet>::value,
              "FdSet must stay standard-layout for fd transport sharing");
static_assert(dt_fd_forward::FdSet::kDataLength == sizeof(int) * 3,
              "FdSet wire size drift");

int main() {
  char data[dt_fd_forward::FdSet::kDataLength] = {};
  dt_fd_forward::FdSet in{3, 4, 5};
  in.WriteData(data);
  dt_fd_forward::FdSet out = dt_fd_forward::FdSet::ReadData(data);
  return (out.read_fd_ == 3 && out.write_fd_ == 4 &&
          out.write_lock_fd_ == 5) ? 0 : 1;
}
EOF
  "${cxx}" -std=c++17 -Wall -Wextra -Werror -fsyntax-only \
    -I"${ROOT_DIR}/art/dt_fd_forward/export" \
    "${work}/fd_transport_contract.cc" ||
    fail "contrato C++ fd_transport.h"

  if [[ -f "${ROOT_DIR}/tools/fec/fec.cpp" ]]; then
    "${cxx}" -std=c++17 -Wall -Wextra -Werror -fsyntax-only \
      "${ROOT_DIR}/tools/fec/fec.cpp" ||
      fail "semântica C++ tools/fec/fec.cpp"
  fi
  pass "contratos C++ host-side"
}

check_module_semantics() {
  local gki_symvers="${OUT_PARENT}/gki_kernel/common/Module.symvers"
  local vendor_symvers="${OUT_PARENT}/msm-kernel/Module.symvers"
  require_file "${gki_symvers}" || return
  require_file "${vendor_symvers}" || return

  local name ko mismatches
  local -a module_specs=(
    "cpu_hotplug:${DIST_DIR}/cpu_hotplug.ko"
    "msm_kgsl:${DIST_DIR}/graphics/msm_kgsl.ko"
    "camera:${DIST_DIR}/camera/camera.ko"
  )

  for spec in "${module_specs[@]}"; do
    name="${spec%%:*}"
    ko="${spec#*:}"
    require_file "${ko}" || continue
    if mismatches="$(module_abi_symvers_mismatches "${ko}" "${gki_symvers}" "${vendor_symvers}")"; then
      echo "  ${name}: modversions vs Module.symvers OK"
    else
      fail "${name}: modversions divergem de Module.symvers"
      [[ -n "${mismatches}" ]] && echo "${mismatches}" | sed 's/^/    /'
    fi
  done
  pass "contratos semânticos de módulos avaliados"
}

check_audit_gate() {
  if "${ROOT_DIR}/scripts/audit_kernel_release.sh" >/tmp/check_semantic_audit.log 2>&1; then
    pass "audit_kernel_release.sh retorna sucesso"
  else
    fail "audit_kernel_release.sh falhou"
    tail -n 80 /tmp/check_semantic_audit.log
  fi
}

echo "Semantic contracts report: ${REPORT}"
check_shell_syntax
check_python_syntax
check_android_bp_sources
check_cpp_contracts
check_module_semantics
check_audit_gate

if [[ "${fail_count}" -eq 0 ]]; then
  echo "SEMANTIC_SAFE: SIM"
  exit 0
fi

echo "SEMANTIC_SAFE: NÃO (${fail_count} falha(s))"
exit 1
