#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KP_DIR="${ROOT_DIR}/kernel_platform"
SUKISU_REF="${SUKISU_REF:-f74582a4}"
SETUP_URL="https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh"
KSU_REPO="${KP_DIR}/KernelSU"
VENDOR_KSU_REPO="${KP_DIR}/msm-kernel/KernelSU"

# Mixed GKI builds ship Image/vmlinux from common/, not msm-kernel/.
COMMON_KSU="${KP_DIR}/common/drivers/kernelsu"

ensure_sukisu_ref() {
  local repo="$1"
  local expected actual
  expected="$(git -C "${repo}" rev-parse "${SUKISU_REF}^{commit}")"
  actual="$(git -C "${repo}" rev-parse HEAD)"
  if [[ "${actual}" == "${expected}" ]]; then
    return
  fi
  if [[ -n "$(git -C "${repo}" status --porcelain)" ]]; then
    echo "SukiSU local possui alteracoes em ${repo}; recusando trocar ${actual} por ${expected}." >&2
    exit 1
  fi
  echo "==> Ajustando SukiSU em ${repo} para ${SUKISU_REF} (${expected})"
  git -C "${repo}" switch --detach "${expected}"
}

if [[ -d "${KSU_REPO}/.git" ]]; then
  ensure_sukisu_ref "${KSU_REPO}"
elif [[ -e "${COMMON_KSU}" ]]; then
  echo "SukiSU integrado sem repositorio verificavel em ${KSU_REPO}." >&2
  exit 1
fi
if [[ -d "${VENDOR_KSU_REPO}/.git" ]]; then
  ensure_sukisu_ref "${VENDOR_KSU_REPO}"
fi

if [[ ! -e "${COMMON_KSU}" ]]; then
  echo "==> Integrando SukiSU-Ultra (${SUKISU_REF}) no kernel GKI (common/)"
  chmod u+w "${KP_DIR}/common/drivers/Makefile" "${KP_DIR}/common/drivers/Kconfig" 2>/dev/null || true
  cd "${KP_DIR}"
  curl -LSs "${SETUP_URL}" | bash -s "${SUKISU_REF}"
fi

[[ "$(readlink -f "${COMMON_KSU}")" == "${KSU_REPO}/kernel" ]] || {
  echo "Integracao SukiSU aponta para uma arvore inesperada: ${COMMON_KSU}" >&2
  exit 1
}

echo "==> SukiSU GKI fixado em $(git -C "${KSU_REPO}" describe --tags --always)"
