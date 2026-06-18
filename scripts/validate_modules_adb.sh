#!/usr/bin/env bash
# Validação estruturada: arquivo na partição vs módulo carregado vs parâmetros custom.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${DIST_DIR:-${ROOT_DIR}/out/kernel-m269-thinlto/dist}"

if ! command -v adb >/dev/null; then
  echo "adb não encontrado." >&2
  exit 1
fi

adb get-state >/dev/null 2>&1 || { echo "Dispositivo adb offline." >&2; exit 1; }

run_su() { adb shell "su -c '$*'" 2>/dev/null; }

PASS=0
FAIL=0
WARN=0

check() {
  local label="$1" result="$2"
  case "${result}" in
    PASS) PASS=$((PASS + 1)); echo "[PASS] ${label}" ;;
    FAIL) FAIL=$((FAIL + 1)); echo "[FAIL] ${label}" ;;
    WARN) WARN=$((WARN + 1)); echo "[WARN] ${label}" ;;
  esac
}

host_sha() {
  local f="$1"
  [[ -f "${f}" ]] && sha256sum "${f}" | awk '{print $1}' || echo ""
}

host_srcversion() {
  modinfo -F srcversion "$1" 2>/dev/null || echo ""
}

section() { echo; echo "=== $* ==="; }

audit_module() {
  local name="$1" host_ko="$2" param_path="${3:-}" expected="${4:-custom}"
  local file_ok=0 loaded=0 src_ok=0 param_ok=0

  section "Módulo: ${name}"

  local host_hash host_src phone_paths phone_hash loaded_mod src_loaded

  host_hash="$(host_sha "${host_ko}")"
  host_src="$(host_srcversion "${host_ko}")"
  echo "Host: ${host_ko}"
  echo "  sha256:      ${host_hash:-n/a}"
  echo "  srcversion:  ${host_src:-n/a}"
  modinfo -F vermagic "${host_ko}" 2>/dev/null | sed 's/^/  vermagic: /' || true
  modinfo -F depends "${host_ko}" 2>/dev/null | sed 's/^/  depends: /' || true

  phone_paths="$(run_su "find /vendor_dlkm /vendor /lib/modules -name ${name}.ko 2>/dev/null" || true)"
  if [[ -n "${phone_paths}" ]]; then
    echo "Arquivos na partição:"
    echo "${phone_paths}" | sed 's/^/  /'
    phone_hash="$(run_su "sha256sum $(echo "${phone_paths}" | head -1)" | awk '{print $1}')"
    echo "  sha256 (primeiro): ${phone_hash}"
    if [[ -n "${host_hash}" && "${host_hash}" == "${phone_hash}" ]]; then
      check "Arquivo ${expected} presente na partição (${name})" PASS
      file_ok=1
    else
      check "Arquivo ${expected} presente na partição (${name})" FAIL
    fi
    local npaths
    npaths="$(echo "${phone_paths}" | wc -l | tr -d ' ')"
    if [[ "${npaths}" -gt 1 ]]; then
      check "Sem duplicata ${name}.ko em múltiplos paths" WARN
    fi
  else
    check "Arquivo ${name}.ko encontrado no FS" FAIL
    phone_hash=""
  fi

  loaded_mod="$(run_su "grep -E \"^${name} \" /proc/modules | head -1" || true)"
  if [[ -n "${loaded_mod}" ]]; then
    check "Módulo ${name} carregado (/proc/modules)" PASS
    loaded=1
    echo "  /proc/modules: ${loaded_mod}"
  else
    check "Módulo ${name} carregado (/proc/modules)" FAIL
  fi

  src_loaded="$(run_su "cat /sys/module/${name}/srcversion 2>/dev/null" || true)"
  if [[ -n "${src_loaded}" ]]; then
    echo "  srcversion carregado: ${src_loaded}"
    if [[ -n "${host_src}" && "${host_src}" == "${src_loaded}" ]]; then
      check "srcversion carregado = host (${name})" PASS
      src_ok=1
    else
      check "srcversion carregado = host (${name})" WARN
    fi
  else
    check "srcversion sysfs (${name})" WARN
  fi

  if [[ -n "${param_path}" ]]; then
    if run_su "test -e ${param_path}"; then
      echo "  parâmetro: $(run_su "cat ${param_path}" 2>/dev/null) (${param_path})"
      check "Parâmetro custom presente (${name})" PASS
      param_ok=1
    else
      check "Parâmetro custom presente (${name})" FAIL
    fi
  fi

  echo "Resumo ${name}:"
  echo "  Arquivo ${expected} na partição: $( [[ ${file_ok} -eq 1 ]] && echo SIM || echo NÃO )"
  echo "  Módulo carregado:           $( [[ ${loaded} -eq 1 ]] && echo SIM || echo NÃO )"
  echo "  srcversion correspondente:  $( [[ ${src_ok} -eq 1 ]] && echo SIM || echo NÃO/N-A )"
  if [[ -n "${param_path}" ]]; then
    echo "  Parâmetro custom presente:  $( [[ ${param_ok} -eq 1 ]] && echo SIM || echo NÃO )"
  fi
}

section "Dispositivo"
adb shell getprop ro.product.model
run_su "uname -r"

section "Origem de carregamento (first-stage hint)"
for name in cpu_hotplug msm_kgsl camera; do
  vb_path="$(run_su "find /lib/modules -maxdepth 2 -name ${name}.ko 2>/dev/null | head -1" || true)"
  dlkm_path="$(run_su "find /vendor_dlkm -name ${name}.ko 2>/dev/null | head -1" || true)"
  echo "${name}: ramdisk/lib=${vb_path:-n/a} vendor_dlkm=${dlkm_path:-n/a}"
done

audit_module "cpu_hotplug" "${DIST_DIR}/cpu_hotplug.ko" \
  "/sys/module/cpu_hotplug/parameters/cpu_hotplug_level"
audit_module "msm_kgsl" "${DIST_DIR}/graphics/msm_kgsl.ko" \
  "/sys/module/msm_kgsl/parameters/governor_call_interval_us"
audit_module "camera" "${DIST_DIR}/camera/camera.ko" \
  "/sys/module/camera/parameters/cam_perf_mode"

section "KGSL comportamento (leitura)"
gov="$(run_su "cat /sys/module/msm_kgsl/parameters/governor_call_interval_us 2>/dev/null" || true)"
idle="$(run_su "cat /sys/class/kgsl/kgsl-3d0/idle_timer 2>/dev/null" || true)"
echo "governor_call_interval_us: ${gov:-n/a} µs (faixa válida: 5000-50000)"
echo "idle_timer: ${idle:-n/a} ms"
echo "Nota: validar governor por comportamento (FPS/latência), não só leitura sysfs."
echo "Teste sugerido: echo 20000 > governor_call_interval_us; observar responsividade GPU."

section "CPU hotplug"
hotplug="$(run_su "cat /sys/module/cpu_hotplug/parameters/cpu_hotplug_level 2>/dev/null" || true)"
echo "cpu_hotplug_level: ${hotplug:-n/a} (0=off experimental, 1=recomendado)"

section "Camera perf"
cam_perf="$(run_su "cat /sys/module/camera/parameters/cam_perf_mode 2>/dev/null" || true)"
echo "cam_perf_mode: ${cam_perf:-n/a} (0=stock, 1=latência, 2=economia)"

section "Layout partições"
run_su "ls -l /dev/block/by-name 2>/dev/null | grep -i dlkm" || true
run_su "getprop ro.boot.slot_suffix" || true

section "Totais"
echo "PASS=${PASS} FAIL=${FAIL} WARN=${WARN}"
if [[ "${FAIL}" -gt 0 ]]; then
  echo "Conclusão: módulos custom NÃO totalmente ativos — revisar deploy e flash."
  exit 1
fi
echo "Conclusão: verificação básica OK (revise WARNs e teste comportamental KGSL)."
