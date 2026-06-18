#!/usr/bin/env bash
# Pipeline unico para preparar release flashavel do kernel SM-A057M.
# Nao faz flash. Apenas compila, repacota, audita e declara o estado final.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JOBS="${JOBS:-8}"
CLEAN="${CLEAN:-0}"
RUN_DISCOVER_FLASH_LAYOUT="${RUN_DISCOVER_FLASH_LAYOUT:-1}"
RUN_SEMANTIC="${RUN_SEMANTIC:-1}"
RUN_HOST_PIPELINE="${RUN_HOST_PIPELINE:-0}"
REPORT_DIR="${REPORT_DIR:-${ROOT_DIR}/out/release}"
REPORT="${REPORT:-${REPORT_DIR}/PREPARE_FLASH_REPORT.txt}"
AUDIT_LOG="${REPORT_DIR}/PREPARE_FLASH_AUDIT.txt"

if [[ "${ROOT_DIR}" == *" "* ]]; then
  BUILD_ROOT="${BUILD_ROOT:-$(dirname "${ROOT_DIR}")/Kernel-A15-build}"
else
  BUILD_ROOT="${BUILD_ROOT:-${ROOT_DIR}}"
fi

mkdir -p "${REPORT_DIR}"
: > "${REPORT}"

log() {
  printf '%s\n' "$*"
  printf '%s\n' "$*" >> "${REPORT}"
}

section() {
  log ""
  log "== $* =="
}

run_step() {
  local label="$1"
  shift
  section "${label}"
  log "CMD: $*"
  "$@" 2>&1 | tee -a "${REPORT}"
}

adb_ready() {
  command -v adb >/dev/null || return 1
  [[ "$(adb get-state 2>/dev/null | tr -d '\r' || true)" == "device" ]]
}

extract_gate() {
  local name="$1"
  awk -F: -v key="${name}" '$1 == key {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}' "${AUDIT_LOG}"
}

section "Contexto"
log "Root: ${ROOT_DIR}"
log "Build root: ${BUILD_ROOT}"
log "JOBS: ${JOBS}"
log "CLEAN: ${CLEAN}"
log "RUN_DISCOVER_FLASH_LAYOUT: ${RUN_DISCOVER_FLASH_LAYOUT}"
log "RUN_SEMANTIC: ${RUN_SEMANTIC}"
log "RUN_HOST_PIPELINE: ${RUN_HOST_PIPELINE}"
log "Report: ${REPORT}"

if [[ "${CLEAN}" == "1" ]]; then
  run_step "Build clean diagnostico" \
    env JOBS="${JOBS}" BUILD_ROOT="${BUILD_ROOT}" "${ROOT_DIR}/build_kernel_clean.sh"
else
  run_step "Build incremental ThinLTO" \
    env JOBS="${JOBS}" BUILD_ROOT="${BUILD_ROOT}" "${ROOT_DIR}/build_kernel_thinlto.sh"
fi

run_step "Deploy modules e rebuild de imagens" \
  env BUILD_ROOT="${BUILD_ROOT}" "${ROOT_DIR}/scripts/deploy_kernel_modules.sh"

run_step "Empacotar artifacts de release" \
  env BUILD_ROOT="${BUILD_ROOT}" "${ROOT_DIR}/scripts/package_flash_artifacts.sh"

if [[ "${RUN_SEMANTIC}" == "1" ]]; then
  run_step "Checagens semanticas host" \
    env BUILD_ROOT="${BUILD_ROOT}" "${ROOT_DIR}/scripts/check_semantic_contracts.sh"
fi

if [[ "${RUN_HOST_PIPELINE}" == "1" ]]; then
  run_step "Pipeline host completo" \
    env BUILD_ROOT="${BUILD_ROOT}" "${ROOT_DIR}/scripts/test_host_pipeline.sh"
fi

if [[ "${RUN_DISCOVER_FLASH_LAYOUT}" == "1" ]]; then
  section "Descobrir layout de flash via ADB"
  if adb_ready; then
    log "ADB: device detectado"
    env BUILD_ROOT="${BUILD_ROOT}" "${ROOT_DIR}/scripts/discover_flash_layout.sh" 2>&1 | tee -a "${REPORT}"
  else
    log "ADB: indisponivel/offline. FLASH_LAYOUT_SAFE ficara pendente ate rodar:"
    log "  ./scripts/discover_flash_layout.sh"
  fi
fi

section "Auditoria final"
set +e
env BUILD_ROOT="${BUILD_ROOT}" "${ROOT_DIR}/scripts/audit_kernel_release.sh" 2>&1 | tee "${AUDIT_LOG}" | tee -a "${REPORT}"
audit_rc=${PIPESTATUS[0]}
set -e

build_safe="$(extract_gate BUILD_SAFE || true)"
pack_safe="$(extract_gate PACK_SAFE || true)"
flash_layout_safe="$(extract_gate FLASH_LAYOUT_SAFE || true)"
runtime_validated="$(extract_gate RUNTIME_VALIDATED || true)"
flash_ready="$(extract_gate FLASH_READY || true)"

section "Resumo final"
log "BUILD_SAFE: ${build_safe:-n/a}"
log "PACK_SAFE: ${pack_safe:-n/a}"
log "FLASH_LAYOUT_SAFE: ${flash_layout_safe:-n/a}"
log "RUNTIME_VALIDATED: ${runtime_validated:-n/a}"
log "FLASH_READY: ${flash_ready:-n/a}"
log "Artifacts:"
log "  ${ROOT_DIR}/out/release/AP_KERNEL_CUSTOM.img.tar"
log "  ${ROOT_DIR}/out/release/boot-custom.img.tar"
log "  ${ROOT_DIR}/out/release/vendor_boot-custom.img.tar"
log "  ${ROOT_DIR}/out/release/vendor_dlkm.img"
log "  ${ROOT_DIR}/out/release/STOCK_RECOVERY.img.tar"
log "  ${ROOT_DIR}/out/release/SHA256SUMS"
log "Auditoria: ${AUDIT_LOG}"

if [[ "${build_safe}" == "SIM" && "${pack_safe}" == "SIM" && "${flash_layout_safe}" == "SIM" ]]; then
  log ""
  log "RESULTADO: artifacts prontos para procedimento de flash validado."
  log "Observacao: este script nao valida runtime; apos flash rode ./scripts/validate_modules_adb.sh."
  exit 0
fi

log ""
log "RESULTADO: artifacts gerados, mas NAO declarar flash-ready."
log "Motivo: exige BUILD_SAFE=SIM, PACK_SAFE=SIM e FLASH_LAYOUT_SAFE=SIM."
if [[ "${audit_rc}" -ne 0 ]]; then
  exit "${audit_rc}"
fi
exit 2
