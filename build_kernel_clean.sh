#!/usr/bin/env bash
# Clean build diagnóstico: apaga output antigo, recompila (mrproper) e roda auditoria.
#
# Uso:
#   ./build_kernel_clean.sh
#   JOBS=8 ./build_kernel_clean.sh
#   BUILD_LOG=./logs/meu_build.log ./build_kernel_clean.sh
#
# Log padrão: build_kernel_clean.log (na raiz do projeto)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOBS="${JOBS:-8}"
SKIP_MRPROPER="${SKIP_MRPROPER:-0}"
FAST_BUILD="${FAST_BUILD:-0}"
if [[ -n "${BUILD_LOG:-}" ]]; then
  case "${BUILD_LOG}" in
    /*) ;;
    *) BUILD_LOG="${ROOT_DIR}/${BUILD_LOG#./}" ;;
  esac
else
  BUILD_LOG="${ROOT_DIR}/build_kernel_clean.log"
fi
mkdir -p "$(dirname "${BUILD_LOG}")"

if [[ "${ROOT_DIR}" == *" "* ]]; then
  BUILD_ROOT="${BUILD_ROOT:-$(dirname "${ROOT_DIR}")/Kernel-A15-build}"
else
  BUILD_ROOT="${BUILD_ROOT:-${ROOT_DIR}}"
fi

OUT_LOCAL="${ROOT_DIR}/out/kernel-m269-thinlto"
OUT_MIRROR="${BUILD_ROOT}/out/kernel-m269-thinlto"

log() {
  echo "$*"
}

on_exit() {
  local code=$?
  log ""
  log "==> Build diagnóstico encerrado: $(date -Iseconds) (exit ${code})"
  log "    Log completo: ${BUILD_LOG}"
}
trap on_exit EXIT

: > "${BUILD_LOG}"
exec > >(tee -a "${BUILD_LOG}") 2>&1

log "==> Build diagnóstico iniciado: $(date -Iseconds)"
log "    Root:          ${ROOT_DIR}"
log "    Build root:    ${BUILD_ROOT}"
log "    JOBS:          ${JOBS}"
log "    SKIP_MRPROPER: ${SKIP_MRPROPER}"
log "    FAST_BUILD:    ${FAST_BUILD}"
log "    Log:           ${BUILD_LOG}"
log ""

log "==> Limpando output antigo"
rm -rf "${OUT_LOCAL}" "${OUT_MIRROR}"
log "    removido: ${OUT_LOCAL}"
log "    removido: ${OUT_MIRROR}"
log ""

log "==> Compilando kernel (clean)"
SKIP_MRPROPER="${SKIP_MRPROPER}" \
FAST_BUILD="${FAST_BUILD}" \
JOBS="${JOBS}" \
"${ROOT_DIR}/build_kernel_thinlto.sh"
log ""

log "==> Auditoria kernel release / gates (BUILD_SAFE … FLASH_READY)"
set +e
"${ROOT_DIR}/scripts/audit_kernel_release.sh"
audit_rc=$?
set -e
log ""

if [[ "${audit_rc}" -eq 0 ]]; then
  log "==> Resultado: BUILD_SAFE: SIM — build compatível no host; flash pendente PACK + layout"
  exit 0
fi

log "==> Resultado: BUILD_SAFE: NÃO — não deployar nem flashear até alinhar release/KMI"
exit "${audit_rc}"