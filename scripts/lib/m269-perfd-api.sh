# API compartilhada do m269-perfd v3 — shell Android (/system/bin/sh)
# shellcheck shell=sh

m269_init_paths() {
	SCRIPT_DIR="${SCRIPT_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}"
	PRESETS="${PRESETS:-${SCRIPT_DIR}/m269-presets.conf}"
	MODDIR="${MODDIR:-${SCRIPT_DIR}}"
	STATE_DIR="${STATE_DIR:-${MODDIR}/state}"
	SETTINGS="${STATE_DIR}/settings.conf"
	STOCK_ENV="${STATE_DIR}/stock.env"
	LOG="${STATE_DIR}/apply.log"
	SYSFS_ROOT="${SYSFS_ROOT:-}"
	KGSL_DEV="${SYSFS_ROOT}/sys/class/kgsl/kgsl-3d0"
	KGSL_GOV_PARAM="${SYSFS_ROOT}/sys/module/msm_kgsl/parameters/governor_call_interval_us"
	CPUFREQ_ROOT="${SYSFS_ROOT}/sys/devices/system/cpu/cpufreq"
	CPU_HOTPLUG_PARAM="${SYSFS_ROOT}/sys/module/cpu_hotplug/parameters/cpu_hotplug_level"
	CAMERA_PERF_PARAM="${SYSFS_ROOT}/sys/module/camera/parameters/cam_perf_mode"
}

m269_require_root() {
	if [ "${M269_PERFD_TEST:-0}" = "1" ]; then
		return 0
	fi
	if [ "$(id -u)" -ne 0 ]; then
		echo "Execute como root (su -c)." >&2
		return 1
	fi
}

m269_mkdir_state() {
	mkdir -p "${STATE_DIR}"
}

m269_log() {
	m269_mkdir_state
	echo "[$(date '+%H:%M:%S')] $*" >> "${LOG}" 2>/dev/null || true
}

m269_json_escape() {
	printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

m269_read_path() {
	[ -r "$1" ] && cat "$1" || true
}

m269_cmd_exists() {
	command -v "$1" >/dev/null 2>&1
}

m269_load_presets() {
	if [ -f "${PRESETS}" ]; then
		# shellcheck disable=SC1090
		. "${PRESETS}"
	fi
}

m269_valid_cpu_preset() {
	case "$1" in
		stock|conservative|efficiency|moderate|aggressive|performance|game|off) return 0 ;;
		*) return 1 ;;
	esac
}

m269_valid_gpu_preset() {
	case "$1" in
		stock|responsive|balanced|latency|economy) return 0 ;;
		*) return 1 ;;
	esac
}

m269_valid_display_preset() {
	case "$1" in
		stock|economy|battery_plus|smooth|performance) return 0 ;;
		*) return 1 ;;
	esac
}

m269_valid_camera_preset() {
	case "$1" in
		stock|latency|power) return 0 ;;
		*) return 1 ;;
	esac
}

m269_preset_get() {
	domain="$1"
	preset="$2"
	key="$3"
	default="$4"
	eval "value=\${${domain}_PRESET_${preset}_${key}:-}"
	value="$(printf '%s' "${value}" | tr -d '\r')"
	[ -n "${value}" ] || value="${default}"
	printf '%s\n' "${value}"
}

m269_validate_hotplug() {
	case "$1" in
		0|1|2|3) return 0 ;;
		*) return 1 ;;
	esac
}

m269_validate_pct() {
	case "$1" in
		""|*[!0-9]*) return 1 ;;
	esac
	[ "$1" -ge "$2" ] && [ "$1" -le "$3" ]
}

m269_validate_cpu_values() {
	hotplug="$1"
	maxpct="$2"
	m269_validate_hotplug "${hotplug}" &&
		m269_validate_pct "${maxpct}" 50 100
}

m269_validate_gpu_values() {
	gov="$1"
	idle="$2"
	maxpct="$3"
	modpct="$4"
	case "${gov}:${idle}:${maxpct}:${modpct}" in
		*[!0-9:]*) return 1 ;;
	esac
	[ "${gov}" -ge 5000 ] && [ "${gov}" -le 50000 ] &&
		[ "${idle}" -ge 20 ] && [ "${idle}" -le 500 ] &&
		[ "${maxpct}" -ge 50 ] && [ "${maxpct}" -le 100 ] &&
		[ "${modpct}" -ge 10 ] && [ "${modpct}" -le 1000 ]
}

m269_validate_display_values() {
	refresh="$1"
	scale="$2"
	case "${refresh}:${scale}" in
		*[!0-9:]*) return 1 ;;
	esac
	case "${refresh}" in
		0|60|90) : ;;
		*) return 1 ;;
	esac
	m269_validate_pct "${scale}" 50 100
}

m269_validate_camera_mode() {
	case "$1" in
		0|1|2) return 0 ;;
		*) return 1 ;;
	esac
}

m269_settings_default() {
	BOOT_CPU_PRESET="${BOOT_CPU_PRESET:-conservative}"
	BOOT_GPU_PRESET="${BOOT_GPU_PRESET:-balanced}"
	BOOT_DISPLAY_PRESET="${BOOT_DISPLAY_PRESET:-stock}"
	BOOT_CAMERA_PRESET="${BOOT_CAMERA_PRESET:-stock}"
	RUNTIME_CPU_PRESET="${RUNTIME_CPU_PRESET:-${BOOT_CPU_PRESET}}"
	RUNTIME_CPU_HOTPLUG="${RUNTIME_CPU_HOTPLUG:-1}"
	RUNTIME_CPU_MAX_FREQ_PCT="${RUNTIME_CPU_MAX_FREQ_PCT:-100}"
	RUNTIME_CPU_SOURCE="${RUNTIME_CPU_SOURCE:-boot}"
	RUNTIME_GPU_PRESET="${RUNTIME_GPU_PRESET:-${BOOT_GPU_PRESET}}"
	RUNTIME_GPU_GOVERNOR_US="${RUNTIME_GPU_GOVERNOR_US:-10000}"
	RUNTIME_GPU_IDLE_TIMER_MS="${RUNTIME_GPU_IDLE_TIMER_MS:-80}"
	RUNTIME_GPU_MAX_GPUCLK_PCT="${RUNTIME_GPU_MAX_GPUCLK_PCT:-100}"
	RUNTIME_GPU_MOD_PERCENT="${RUNTIME_GPU_MOD_PERCENT:-100}"
	RUNTIME_GPU_SOURCE="${RUNTIME_GPU_SOURCE:-boot}"
	RUNTIME_DISPLAY_PRESET="${RUNTIME_DISPLAY_PRESET:-${BOOT_DISPLAY_PRESET}}"
	RUNTIME_DISPLAY_REFRESH_HZ="${RUNTIME_DISPLAY_REFRESH_HZ:-0}"
	RUNTIME_DISPLAY_RENDER_SCALE_PCT="${RUNTIME_DISPLAY_RENDER_SCALE_PCT:-100}"
	RUNTIME_DISPLAY_SOURCE="${RUNTIME_DISPLAY_SOURCE:-boot}"
	RUNTIME_CAMERA_PRESET="${RUNTIME_CAMERA_PRESET:-${BOOT_CAMERA_PRESET}}"
	RUNTIME_CAMERA_PERF_MODE="${RUNTIME_CAMERA_PERF_MODE:-0}"
	RUNTIME_CAMERA_SOURCE="${RUNTIME_CAMERA_SOURCE:-boot}"
	CUSTOM_CPU_HOTPLUG="${CUSTOM_CPU_HOTPLUG:-2}"
	CUSTOM_CPU_MAX_FREQ_PCT="${CUSTOM_CPU_MAX_FREQ_PCT:-90}"
	CUSTOM_GPU_GOVERNOR_US="${CUSTOM_GPU_GOVERNOR_US:-10000}"
	CUSTOM_GPU_IDLE_TIMER_MS="${CUSTOM_GPU_IDLE_TIMER_MS:-80}"
	CUSTOM_GPU_MAX_GPUCLK_PCT="${CUSTOM_GPU_MAX_GPUCLK_PCT:-100}"
	CUSTOM_GPU_MOD_PERCENT="${CUSTOM_GPU_MOD_PERCENT:-100}"
	CUSTOM_DISPLAY_REFRESH_HZ="${CUSTOM_DISPLAY_REFRESH_HZ:-60}"
	CUSTOM_DISPLAY_RENDER_SCALE_PCT="${CUSTOM_DISPLAY_RENDER_SCALE_PCT:-100}"
	CUSTOM_CAMERA_PERF_MODE="${CUSTOM_CAMERA_PERF_MODE:-0}"
}

m269_load_settings() {
	m269_settings_default
	if [ -f "${SETTINGS}" ]; then
		# shellcheck disable=SC1090
		. "${SETTINGS}"
	fi
}

m269_write_settings() {
	m269_mkdir_state
	tmp="${SETTINGS}.tmp.$$"
	{
		printf 'BOOT_CPU_PRESET="%s"\n' "${BOOT_CPU_PRESET}"
		printf 'BOOT_GPU_PRESET="%s"\n' "${BOOT_GPU_PRESET}"
		printf 'BOOT_DISPLAY_PRESET="%s"\n' "${BOOT_DISPLAY_PRESET}"
		printf 'BOOT_CAMERA_PRESET="%s"\n' "${BOOT_CAMERA_PRESET}"
		printf 'RUNTIME_CPU_PRESET="%s"\n' "${RUNTIME_CPU_PRESET}"
		printf 'RUNTIME_CPU_HOTPLUG="%s"\n' "${RUNTIME_CPU_HOTPLUG}"
		printf 'RUNTIME_CPU_MAX_FREQ_PCT="%s"\n' "${RUNTIME_CPU_MAX_FREQ_PCT}"
		printf 'RUNTIME_CPU_SOURCE="%s"\n' "${RUNTIME_CPU_SOURCE}"
		printf 'RUNTIME_GPU_PRESET="%s"\n' "${RUNTIME_GPU_PRESET}"
		printf 'RUNTIME_GPU_GOVERNOR_US="%s"\n' "${RUNTIME_GPU_GOVERNOR_US}"
		printf 'RUNTIME_GPU_IDLE_TIMER_MS="%s"\n' "${RUNTIME_GPU_IDLE_TIMER_MS}"
		printf 'RUNTIME_GPU_MAX_GPUCLK_PCT="%s"\n' "${RUNTIME_GPU_MAX_GPUCLK_PCT}"
		printf 'RUNTIME_GPU_MOD_PERCENT="%s"\n' "${RUNTIME_GPU_MOD_PERCENT}"
		printf 'RUNTIME_GPU_SOURCE="%s"\n' "${RUNTIME_GPU_SOURCE}"
		printf 'RUNTIME_DISPLAY_PRESET="%s"\n' "${RUNTIME_DISPLAY_PRESET}"
		printf 'RUNTIME_DISPLAY_REFRESH_HZ="%s"\n' "${RUNTIME_DISPLAY_REFRESH_HZ}"
		printf 'RUNTIME_DISPLAY_RENDER_SCALE_PCT="%s"\n' "${RUNTIME_DISPLAY_RENDER_SCALE_PCT}"
		printf 'RUNTIME_DISPLAY_SOURCE="%s"\n' "${RUNTIME_DISPLAY_SOURCE}"
		printf 'RUNTIME_CAMERA_PRESET="%s"\n' "${RUNTIME_CAMERA_PRESET}"
		printf 'RUNTIME_CAMERA_PERF_MODE="%s"\n' "${RUNTIME_CAMERA_PERF_MODE}"
		printf 'RUNTIME_CAMERA_SOURCE="%s"\n' "${RUNTIME_CAMERA_SOURCE}"
		printf 'CUSTOM_CPU_HOTPLUG="%s"\n' "${CUSTOM_CPU_HOTPLUG}"
		printf 'CUSTOM_CPU_MAX_FREQ_PCT="%s"\n' "${CUSTOM_CPU_MAX_FREQ_PCT}"
		printf 'CUSTOM_GPU_GOVERNOR_US="%s"\n' "${CUSTOM_GPU_GOVERNOR_US}"
		printf 'CUSTOM_GPU_IDLE_TIMER_MS="%s"\n' "${CUSTOM_GPU_IDLE_TIMER_MS}"
		printf 'CUSTOM_GPU_MAX_GPUCLK_PCT="%s"\n' "${CUSTOM_GPU_MAX_GPUCLK_PCT}"
		printf 'CUSTOM_GPU_MOD_PERCENT="%s"\n' "${CUSTOM_GPU_MOD_PERCENT}"
		printf 'CUSTOM_DISPLAY_REFRESH_HZ="%s"\n' "${CUSTOM_DISPLAY_REFRESH_HZ}"
		printf 'CUSTOM_DISPLAY_RENDER_SCALE_PCT="%s"\n' "${CUSTOM_DISPLAY_RENDER_SCALE_PCT}"
		printf 'CUSTOM_CAMERA_PERF_MODE="%s"\n' "${CUSTOM_CAMERA_PERF_MODE}"
	} > "${tmp}"
	mv "${tmp}" "${SETTINGS}"
}

m269_gpu_mod_percent_path() {
	for path in \
		"${KGSL_DEV}/devfreq"/*/mod_percent \
		"${SYSFS_ROOT}/sys/class/devfreq"/*kgsl*/mod_percent \
		"${SYSFS_ROOT}/sys/class/devfreq"/*gpu*/mod_percent; do
		[ -e "${path}" ] || continue
		printf '%s\n' "${path}"
		return 0
	done
	return 1
}

m269_cpu_policies() {
	for policy in "${CPUFREQ_ROOT}"/policy*; do
		[ -d "${policy}" ] || continue
		printf '%s\n' "${policy}"
	done
}

m269_cpu_policy_name() {
	basename "$1"
}

m269_cpu_policy_max_freq() {
	policy="$1"
	max=0
	for freq in $(m269_read_path "${policy}/scaling_available_frequencies"); do
		[ "${freq}" -gt "${max}" ] 2>/dev/null && max="${freq}"
	done
	if [ "${max}" -eq 0 ]; then
		max="$(m269_read_path "${policy}/cpuinfo_max_freq")"
	fi
	case "${max}" in
		""|*[!0-9]*) return 1 ;;
	esac
	printf '%s\n' "${max}"
}

m269_cpu_frequency_for_pct() {
	policy="$1"
	pct="$2"
	max_khz="$(m269_cpu_policy_max_freq "${policy}" || return 1)"
	limit=$((max_khz * pct / 100))
	target=""
	for freq in $(m269_read_path "${policy}/scaling_available_frequencies"); do
		[ "${freq}" -le "${limit}" ] 2>/dev/null || continue
		if [ -z "${target}" ] || [ "${freq}" -gt "${target}" ]; then
			target="${freq}"
		fi
	done
	[ -n "${target}" ] || target="${limit}"
	printf '%s\n' "${target}"
}

m269_cpu_live_max_freqs() {
	out=""
	for policy in $(m269_cpu_policies); do
		name="$(m269_cpu_policy_name "${policy}")"
		value="$(m269_read_path "${policy}/scaling_max_freq")"
		[ -n "${value}" ] || continue
		out="${out}${out:+ }${name}=${value}"
	done
	printf '%s\n' "${out}"
}

m269_cpu_min_live_pct() {
	minpct=""
	for policy in $(m269_cpu_policies); do
		current="$(m269_read_path "${policy}/scaling_max_freq")"
		max="$(m269_cpu_policy_max_freq "${policy}" || true)"
		case "${current}:${max}" in
			*[!0-9:]*|:*|*:) continue ;;
		esac
		[ "${max}" -gt 0 ] || continue
		pct=$((current * 100 / max))
		if [ -z "${minpct}" ] || [ "${pct}" -lt "${minpct}" ]; then
			minpct="${pct}"
		fi
	done
	printf '%s\n' "${minpct}"
}

m269_settings_get() {
	namespace="$1"
	key="$2"
	if m269_cmd_exists settings; then
		settings get "${namespace}" "${key}" 2>/dev/null || true
	fi
}

m269_settings_put_or_delete() {
	namespace="$1"
	key="$2"
	value="$3"
	m269_cmd_exists settings || return 0
	if [ -z "${value}" ] || [ "${value}" = "null" ]; then
		settings delete "${namespace}" "${key}" >/dev/null 2>&1 || true
	else
		settings put "${namespace}" "${key}" "${value}" >/dev/null 2>&1 || true
	fi
}

m269_wm_size_output() {
	m269_cmd_exists wm && wm size 2>/dev/null || true
}

m269_display_physical_size() {
	size="$(m269_wm_size_output | sed -n 's/^Physical size:[[:space:]]*//p' | head -1)"
	[ -n "${size}" ] || size="$(m269_wm_size_output | sed -n 's/^Override size:[[:space:]]*//p' | head -1)"
	printf '%s\n' "${size}"
}

m269_display_apply_size() {
	scale="$1"
	m269_cmd_exists wm || return 0
	if [ "${scale}" = "100" ]; then
		wm size reset >/dev/null 2>&1 || true
		return 0
	fi
	physical="$(m269_display_physical_size)"
	case "${physical}" in
		*x*) : ;;
		*) m269_log "AVISO: wm size físico indisponível; render_scale ignorado"; return 0 ;;
	esac
	width="${physical%x*}"
	height="${physical#*x}"
	case "${width}:${height}" in
		*[!0-9:]*) return 0 ;;
	esac
	target_w=$((width * scale / 100))
	target_h=$((height * scale / 100))
	[ "${target_w}" -gt 0 ] && [ "${target_h}" -gt 0 ] || return 0
	wm size "${target_w}x${target_h}" >/dev/null 2>&1 || true
}

m269_capture_stock() {
	m269_mkdir_state
	stock_gov="$(m269_read_path "${KGSL_GOV_PARAM}")"
	stock_idle="$(m269_read_path "${KGSL_DEV}/idle_timer")"
	stock_hotplug="$(m269_read_path "${CPU_HOTPLUG_PARAM}")"
	stock_maxgpu="$(m269_read_path "${KGSL_DEV}/max_gpuclk")"
	mod_path="$(m269_gpu_mod_percent_path || true)"
	stock_mod=""
	[ -n "${mod_path}" ] && stock_mod="$(m269_read_path "${mod_path}")"
	stock_cpu_max_freqs="$(m269_cpu_live_max_freqs)"
	stock_peak_refresh="$(m269_settings_get system peak_refresh_rate)"
	stock_min_refresh="$(m269_settings_get system min_refresh_rate)"
	stock_wm_size="$(m269_wm_size_output | tr '\n' '|')"
	stock_camera_perf="$(m269_read_path "${CAMERA_PERF_PARAM}")"
	{
		echo "STOCK_GOV='${stock_gov}'"
		echo "STOCK_IDLE='${stock_idle}'"
		echo "STOCK_HOTPLUG='${stock_hotplug}'"
		echo "STOCK_MAX_GPUCLK='${stock_maxgpu}'"
		echo "STOCK_GPU_MOD_PERCENT='${stock_mod}'"
		echo "STOCK_CPU_MAX_FREQS='${stock_cpu_max_freqs}'"
		echo "STOCK_PEAK_REFRESH='${stock_peak_refresh}'"
		echo "STOCK_MIN_REFRESH='${stock_min_refresh}'"
		echo "STOCK_WM_SIZE='${stock_wm_size}'"
		echo "STOCK_CAMERA_PERF_MODE='${stock_camera_perf}'"
	} > "${STOCK_ENV}"
}

m269_load_stock() {
	STOCK_GOV=""
	STOCK_IDLE=""
	STOCK_HOTPLUG=""
	STOCK_MAX_GPUCLK=""
	STOCK_GPU_MOD_PERCENT=""
	STOCK_CPU_MAX_FREQS=""
	STOCK_PEAK_REFRESH=""
	STOCK_MIN_REFRESH=""
	STOCK_WM_SIZE=""
	STOCK_CAMERA_PERF_MODE=""
	if [ -f "${STOCK_ENV}" ]; then
		# shellcheck disable=SC1090
		. "${STOCK_ENV}"
	fi
}

m269_ensure_stock() {
	if [ ! -f "${STOCK_ENV}" ]; then
		m269_capture_stock
	fi
}

m269_write_if_changed() {
	path="$1"
	value="$2"
	[ -w "${path}" ] || return 0
	current="$(m269_read_path "${path}")"
	[ "${current}" = "${value}" ] && return 0
	printf '%s\n' "${value}" > "${path}" 2>/dev/null || {
		m269_log "AVISO: falha ao escrever ${path}"
		return 1
	}
}

m269_gpu_max_hz() {
	max_hz=0
	for freq in $(m269_read_path "${KGSL_DEV}/gpu_available_frequencies"); do
		[ "${freq}" -gt "${max_hz}" ] 2>/dev/null && max_hz="${freq}"
	done
	[ "${max_hz}" -gt 0 ] || return 1
	printf '%s\n' "${max_hz}"
}

m269_gpu_frequency_for_pct() {
	pct="$1"
	max_hz="$(m269_gpu_max_hz || return 1)"
	limit=$((max_hz * pct / 100))
	target=""
	for freq in $(m269_read_path "${KGSL_DEV}/gpu_available_frequencies"); do
		[ "${freq}" -le "${limit}" ] 2>/dev/null || continue
		if [ -z "${target}" ] || [ "${freq}" -gt "${target}" ]; then
			target="${freq}"
		fi
	done
	[ -n "${target}" ] || target="${max_hz}"
	printf '%s\n' "${target}"
}

m269_apply_cpu_hotplug() {
	hotplug="$1"
	m269_validate_hotplug "${hotplug}" || return 1
	m269_ensure_stock
	m269_write_if_changed "${CPU_HOTPLUG_PARAM}" "${hotplug}"
}

m269_apply_cpu_freq_pct() {
	pct="$1"
	m269_validate_pct "${pct}" 50 100 || return 1
	m269_ensure_stock
	for policy in $(m269_cpu_policies); do
		[ -w "${policy}/scaling_max_freq" ] || continue
		target="$(m269_cpu_frequency_for_pct "${policy}" "${pct}" || true)"
		[ -n "${target}" ] && m269_write_if_changed "${policy}/scaling_max_freq" "${target}"
	done
}

m269_apply_cpu_values() {
	hotplug="$1"
	maxpct="$2"
	m269_validate_cpu_values "${hotplug}" "${maxpct}" || return 1
	m269_apply_cpu_hotplug "${hotplug}" || return 1
	m269_apply_cpu_freq_pct "${maxpct}" || return 1
}

m269_apply_gpu_values() {
	gov="$1"
	idle="$2"
	maxpct="$3"
	modpct="$4"
	m269_validate_gpu_values "${gov}" "${idle}" "${maxpct}" "${modpct}" || return 1
	m269_ensure_stock
	m269_write_if_changed "${KGSL_GOV_PARAM}" "${gov}"
	m269_write_if_changed "${KGSL_DEV}/idle_timer" "${idle}"
	if [ -r "${KGSL_DEV}/gpu_available_frequencies" ] &&
	   [ -w "${KGSL_DEV}/max_gpuclk" ]; then
		target="$(m269_gpu_frequency_for_pct "${maxpct}" || true)"
		[ -n "${target}" ] && m269_write_if_changed "${KGSL_DEV}/max_gpuclk" "${target}"
	fi
	mod_path="$(m269_gpu_mod_percent_path || true)"
	[ -n "${mod_path}" ] && m269_write_if_changed "${mod_path}" "${modpct}"
}

m269_apply_display_values() {
	refresh="$1"
	scale="$2"
	m269_validate_display_values "${refresh}" "${scale}" || return 1
	m269_ensure_stock
	if [ "${refresh}" = "0" ]; then
		m269_settings_put_or_delete system peak_refresh_rate "${STOCK_PEAK_REFRESH}"
		m269_settings_put_or_delete system min_refresh_rate "${STOCK_MIN_REFRESH}"
	else
		m269_settings_put_or_delete system peak_refresh_rate "${refresh}"
		m269_settings_put_or_delete system min_refresh_rate "${refresh}"
	fi
	m269_display_apply_size "${scale}"
}

m269_apply_camera_mode() {
	mode="$1"
	m269_validate_camera_mode "${mode}" || return 1
	m269_ensure_stock
	if [ -e "${CAMERA_PERF_PARAM}" ]; then
		m269_write_if_changed "${CAMERA_PERF_PARAM}" "${mode}"
	else
		m269_log "AVISO: cam_perf_mode indisponível; camera.ko custom não carregado"
	fi
}

m269_cpu_values_for_preset() {
	preset="$1"
	m269_valid_cpu_preset "${preset}" || return 1
	hotplug="$(m269_preset_get CPU "${preset}" hotplug 1)"
	maxpct="$(m269_preset_get CPU "${preset}" max_freq_pct 100)"
	printf '%s %s\n' "${hotplug}" "${maxpct}"
}

m269_gpu_values_for_preset() {
	preset="$1"
	m269_valid_gpu_preset "${preset}" || return 1
	gov="$(m269_preset_get GPU "${preset}" governor_us 10000)"
	idle="$(m269_preset_get GPU "${preset}" idle_timer_ms 80)"
	maxpct="$(m269_preset_get GPU "${preset}" max_gpuclk_pct 100)"
	modpct="$(m269_preset_get GPU "${preset}" mod_percent 100)"
	printf '%s %s %s %s\n' "${gov}" "${idle}" "${maxpct}" "${modpct}"
}

m269_display_values_for_preset() {
	preset="$1"
	m269_valid_display_preset "${preset}" || return 1
	refresh="$(m269_preset_get DISPLAY "${preset}" refresh_hz 0)"
	scale="$(m269_preset_get DISPLAY "${preset}" render_scale_pct 100)"
	printf '%s %s\n' "${refresh}" "${scale}"
}

m269_camera_values_for_preset() {
	preset="$1"
	m269_valid_camera_preset "${preset}" || return 1
	mode="$(m269_preset_get CAMERA "${preset}" perf_mode 0)"
	printf '%s\n' "${mode}"
}

m269_apply_cpu_preset() {
	preset="$1"
	source="${2:-preset}"
	set -- $(m269_cpu_values_for_preset "${preset}") || return 1
	m269_apply_cpu_values "$1" "$2" || return 1
	m269_load_settings
	RUNTIME_CPU_PRESET="${preset}"
	RUNTIME_CPU_HOTPLUG="$1"
	RUNTIME_CPU_MAX_FREQ_PCT="$2"
	RUNTIME_CPU_SOURCE="${source}"
	m269_write_settings
	m269_log "CPU preset ${preset} hotplug=$1 max_freq_pct=$2 source=${source}"
	return 0
}

m269_apply_cpu_custom() {
	hotplug="$1"
	maxpct="$2"
	source="${3:-manual}"
	m269_apply_cpu_values "${hotplug}" "${maxpct}" || return 1
	m269_load_settings
	RUNTIME_CPU_PRESET="custom"
	RUNTIME_CPU_HOTPLUG="${hotplug}"
	RUNTIME_CPU_MAX_FREQ_PCT="${maxpct}"
	RUNTIME_CPU_SOURCE="${source}"
	CUSTOM_CPU_HOTPLUG="${hotplug}"
	CUSTOM_CPU_MAX_FREQ_PCT="${maxpct}"
	m269_write_settings
	m269_log "CPU custom hotplug=${hotplug} max_freq_pct=${maxpct} source=${source}"
	return 0
}

m269_apply_gpu_preset() {
	preset="$1"
	source="${2:-preset}"
	set -- $(m269_gpu_values_for_preset "${preset}") || return 1
	m269_apply_gpu_values "$1" "$2" "$3" "$4" || return 1
	m269_load_settings
	RUNTIME_GPU_PRESET="${preset}"
	RUNTIME_GPU_GOVERNOR_US="$1"
	RUNTIME_GPU_IDLE_TIMER_MS="$2"
	RUNTIME_GPU_MAX_GPUCLK_PCT="$3"
	RUNTIME_GPU_MOD_PERCENT="$4"
	RUNTIME_GPU_SOURCE="${source}"
	m269_write_settings
	m269_log "GPU preset ${preset} gov=$1 idle=$2 max=$3 mod=$4 source=${source}"
	return 0
}

m269_apply_gpu_custom() {
	gov="$1"
	idle="$2"
	maxpct="$3"
	modpct="$4"
	source="${5:-manual}"
	m269_apply_gpu_values "${gov}" "${idle}" "${maxpct}" "${modpct}" || return 1
	m269_load_settings
	RUNTIME_GPU_PRESET="custom"
	RUNTIME_GPU_GOVERNOR_US="${gov}"
	RUNTIME_GPU_IDLE_TIMER_MS="${idle}"
	RUNTIME_GPU_MAX_GPUCLK_PCT="${maxpct}"
	RUNTIME_GPU_MOD_PERCENT="${modpct}"
	RUNTIME_GPU_SOURCE="${source}"
	CUSTOM_GPU_GOVERNOR_US="${gov}"
	CUSTOM_GPU_IDLE_TIMER_MS="${idle}"
	CUSTOM_GPU_MAX_GPUCLK_PCT="${maxpct}"
	CUSTOM_GPU_MOD_PERCENT="${modpct}"
	m269_write_settings
	m269_log "GPU custom ${gov}/${idle}/${maxpct}/${modpct} source=${source}"
	return 0
}

m269_apply_display_preset() {
	preset="$1"
	source="${2:-preset}"
	set -- $(m269_display_values_for_preset "${preset}") || return 1
	m269_apply_display_values "$1" "$2" || return 1
	m269_load_settings
	RUNTIME_DISPLAY_PRESET="${preset}"
	RUNTIME_DISPLAY_REFRESH_HZ="$1"
	RUNTIME_DISPLAY_RENDER_SCALE_PCT="$2"
	RUNTIME_DISPLAY_SOURCE="${source}"
	m269_write_settings
	m269_log "Display preset ${preset} refresh=$1 scale=$2 source=${source}"
	return 0
}

m269_apply_display_custom() {
	refresh="$1"
	scale="$2"
	source="${3:-manual}"
	m269_apply_display_values "${refresh}" "${scale}" || return 1
	m269_load_settings
	RUNTIME_DISPLAY_PRESET="custom"
	RUNTIME_DISPLAY_REFRESH_HZ="${refresh}"
	RUNTIME_DISPLAY_RENDER_SCALE_PCT="${scale}"
	RUNTIME_DISPLAY_SOURCE="${source}"
	CUSTOM_DISPLAY_REFRESH_HZ="${refresh}"
	CUSTOM_DISPLAY_RENDER_SCALE_PCT="${scale}"
	m269_write_settings
	m269_log "Display custom refresh=${refresh} scale=${scale} source=${source}"
	return 0
}

m269_apply_camera_preset() {
	preset="$1"
	source="${2:-preset}"
	mode="$(m269_camera_values_for_preset "${preset}")" || return 1
	m269_apply_camera_mode "${mode}" || return 1
	m269_load_settings
	RUNTIME_CAMERA_PRESET="${preset}"
	RUNTIME_CAMERA_PERF_MODE="${mode}"
	RUNTIME_CAMERA_SOURCE="${source}"
	m269_write_settings
	m269_log "Camera preset ${preset} mode=${mode} source=${source}"
	return 0
}

m269_apply_camera_custom() {
	mode="$1"
	source="${2:-manual}"
	m269_apply_camera_mode "${mode}" || return 1
	m269_load_settings
	RUNTIME_CAMERA_PRESET="custom"
	RUNTIME_CAMERA_PERF_MODE="${mode}"
	RUNTIME_CAMERA_SOURCE="${source}"
	CUSTOM_CAMERA_PERF_MODE="${mode}"
	m269_write_settings
	m269_log "Camera custom mode=${mode} source=${source}"
	return 0
}

m269_restore_cpu_stock() {
	for item in ${STOCK_CPU_MAX_FREQS}; do
		name="${item%%=*}"
		value="${item#*=}"
		[ -n "${name}" ] && [ -n "${value}" ] || continue
		m269_write_if_changed "${CPUFREQ_ROOT}/${name}/scaling_max_freq" "${value}"
	done
}

m269_restore_display_stock() {
	m269_settings_put_or_delete system peak_refresh_rate "${STOCK_PEAK_REFRESH}"
	m269_settings_put_or_delete system min_refresh_rate "${STOCK_MIN_REFRESH}"
	if m269_cmd_exists wm; then
		override="$(printf '%s' "${STOCK_WM_SIZE}" | tr '|' '\n' | sed -n 's/^Override size:[[:space:]]*//p' | head -1)"
		if [ -n "${override}" ]; then
			wm size "${override}" >/dev/null 2>&1 || true
		else
			wm size reset >/dev/null 2>&1 || true
		fi
	fi
}

m269_restore_stock() {
	m269_load_stock
	m269_log "Restaurando stock"
	[ -n "${STOCK_GOV}" ] && m269_write_if_changed "${KGSL_GOV_PARAM}" "${STOCK_GOV}"
	[ -n "${STOCK_IDLE}" ] && m269_write_if_changed "${KGSL_DEV}/idle_timer" "${STOCK_IDLE}"
	[ -n "${STOCK_HOTPLUG}" ] && m269_write_if_changed "${CPU_HOTPLUG_PARAM}" "${STOCK_HOTPLUG}"
	[ -n "${STOCK_MAX_GPUCLK}" ] &&
		m269_write_if_changed "${KGSL_DEV}/max_gpuclk" "${STOCK_MAX_GPUCLK}"
	mod_path="$(m269_gpu_mod_percent_path || true)"
	[ -n "${mod_path}" ] && [ -n "${STOCK_GPU_MOD_PERCENT}" ] &&
		m269_write_if_changed "${mod_path}" "${STOCK_GPU_MOD_PERCENT}"
	m269_restore_cpu_stock
	m269_restore_display_stock
	[ -e "${CAMERA_PERF_PARAM}" ] && [ -n "${STOCK_CAMERA_PERF_MODE}" ] &&
		m269_write_if_changed "${CAMERA_PERF_PARAM}" "${STOCK_CAMERA_PERF_MODE}"
}

m269_emit_cpu_presets_json() {
	first=1
	printf '['
	for preset in stock conservative efficiency moderate aggressive performance game off; do
		name="$(m269_preset_get CPU "${preset}" name "${preset}")"
		set -- $(m269_cpu_values_for_preset "${preset}") || continue
		[ "${first}" -eq 1 ] || printf ','
		first=0
		printf '{"id":"%s","name":"%s","hotplug":%s,"max_freq_pct":%s}' \
			"${preset}" "$(m269_json_escape "${name}")" "$1" "$2"
	done
	printf ']'
}

m269_emit_gpu_presets_json() {
	first=1
	printf '['
	for preset in stock responsive balanced latency economy; do
		name="$(m269_preset_get GPU "${preset}" name "${preset}")"
		set -- $(m269_gpu_values_for_preset "${preset}") || continue
		[ "${first}" -eq 1 ] || printf ','
		first=0
		printf '{"id":"%s","name":"%s","governor_us":%s,"idle_timer_ms":%s,"max_gpuclk_pct":%s,"mod_percent":%s}' \
			"${preset}" "$(m269_json_escape "${name}")" "$1" "$2" "$3" "$4"
	done
	printf ']'
}

m269_emit_display_presets_json() {
	first=1
	printf '['
	for preset in stock economy battery_plus smooth performance; do
		name="$(m269_preset_get DISPLAY "${preset}" name "${preset}")"
		set -- $(m269_display_values_for_preset "${preset}") || continue
		[ "${first}" -eq 1 ] || printf ','
		first=0
		printf '{"id":"%s","name":"%s","refresh_hz":%s,"render_scale_pct":%s}' \
			"${preset}" "$(m269_json_escape "${name}")" "$1" "$2"
	done
	printf ']'
}

m269_emit_camera_presets_json() {
	first=1
	printf '['
	for preset in stock latency power; do
		name="$(m269_preset_get CAMERA "${preset}" name "${preset}")"
		mode="$(m269_camera_values_for_preset "${preset}" || true)"
		[ -n "${mode}" ] || continue
		[ "${first}" -eq 1 ] || printf ','
		first=0
		printf '{"id":"%s","name":"%s","perf_mode":%s}' \
			"${preset}" "$(m269_json_escape "${name}")" "${mode}"
	done
	printf ']'
}

m269_emit_read_state_json() {
	m269_load_presets
	m269_load_settings
	m269_load_stock

	live_gov="$(m269_read_path "${KGSL_GOV_PARAM}")"
	live_idle="$(m269_read_path "${KGSL_DEV}/idle_timer")"
	live_hotplug="$(m269_read_path "${CPU_HOTPLUG_PARAM}")"
	live_cpu_max_freqs="$(m269_cpu_live_max_freqs)"
	live_cpu_maxpct="$(m269_cpu_min_live_pct)"
	live_maxgpu="$(m269_read_path "${KGSL_DEV}/max_gpuclk")"
	live_maxpct=""
	if [ -r "${KGSL_DEV}/gpu_available_frequencies" ] && [ -n "${live_maxgpu}" ]; then
		max_hz="$(m269_gpu_max_hz || true)"
		[ -n "${max_hz}" ] && [ "${max_hz}" -gt 0 ] &&
			live_maxpct="$((live_maxgpu * 100 / max_hz))"
	fi
	mod_path="$(m269_gpu_mod_percent_path || true)"
	live_modpct=""
	[ -n "${mod_path}" ] && live_modpct="$(m269_read_path "${mod_path}")"
	live_peak="$(m269_settings_get system peak_refresh_rate)"
	live_min="$(m269_settings_get system min_refresh_rate)"
	live_wm="$(m269_wm_size_output | tr '\n' '|')"
	live_cam="$(m269_read_path "${CAMERA_PERF_PARAM}")"
	cpu_presets="$(m269_emit_cpu_presets_json)"
	gpu_presets="$(m269_emit_gpu_presets_json)"
	display_presets="$(m269_emit_display_presets_json)"
	camera_presets="$(m269_emit_camera_presets_json)"

	printf '{"boot":{"cpu_preset":"%s","gpu_preset":"%s","display_preset":"%s","camera_preset":"%s"},"runtime":{"cpu":{"preset":"%s","hotplug":"%s","max_freq_pct":"%s","source":"%s"},"gpu":{"preset":"%s","governor_us":"%s","idle_timer_ms":"%s","max_gpuclk_pct":"%s","mod_percent":"%s","source":"%s"},"display":{"preset":"%s","refresh_hz":"%s","render_scale_pct":"%s","source":"%s"},"camera":{"preset":"%s","perf_mode":"%s","source":"%s"}},"custom":{"cpu":{"hotplug":"%s","max_freq_pct":"%s"},"gpu":{"governor_us":"%s","idle_timer_ms":"%s","max_gpuclk_pct":"%s","mod_percent":"%s"},"display":{"refresh_hz":"%s","render_scale_pct":"%s"},"camera":{"perf_mode":"%s"}},"live":{"governor_us":"%s","idle_timer_ms":"%s","cpu_hotplug":"%s","cpu_max_freqs":"%s","cpu_max_freq_pct":"%s","max_gpuclk":"%s","max_gpuclk_pct":"%s","gpu_mod_percent":"%s","display_peak_refresh":"%s","display_min_refresh":"%s","wm_size":"%s","camera_perf_mode":"%s"},"stock":{"governor_us":"%s","idle_timer_ms":"%s","cpu_hotplug":"%s","cpu_max_freqs":"%s","max_gpuclk":"%s","gpu_mod_percent":"%s","display_peak_refresh":"%s","display_min_refresh":"%s","wm_size":"%s","camera_perf_mode":"%s"},"cpu_presets":%s,"gpu_presets":%s,"display_presets":%s,"camera_presets":%s,"paths":{"settings":"%s","log":"%s","presets":"%s","camera_perf":"%s"}}\n' \
		"$(m269_json_escape "${BOOT_CPU_PRESET}")" "$(m269_json_escape "${BOOT_GPU_PRESET}")" "$(m269_json_escape "${BOOT_DISPLAY_PRESET}")" "$(m269_json_escape "${BOOT_CAMERA_PRESET}")" \
		"$(m269_json_escape "${RUNTIME_CPU_PRESET}")" "$(m269_json_escape "${RUNTIME_CPU_HOTPLUG}")" "$(m269_json_escape "${RUNTIME_CPU_MAX_FREQ_PCT}")" "$(m269_json_escape "${RUNTIME_CPU_SOURCE}")" \
		"$(m269_json_escape "${RUNTIME_GPU_PRESET}")" "$(m269_json_escape "${RUNTIME_GPU_GOVERNOR_US}")" "$(m269_json_escape "${RUNTIME_GPU_IDLE_TIMER_MS}")" "$(m269_json_escape "${RUNTIME_GPU_MAX_GPUCLK_PCT}")" "$(m269_json_escape "${RUNTIME_GPU_MOD_PERCENT}")" "$(m269_json_escape "${RUNTIME_GPU_SOURCE}")" \
		"$(m269_json_escape "${RUNTIME_DISPLAY_PRESET}")" "$(m269_json_escape "${RUNTIME_DISPLAY_REFRESH_HZ}")" "$(m269_json_escape "${RUNTIME_DISPLAY_RENDER_SCALE_PCT}")" "$(m269_json_escape "${RUNTIME_DISPLAY_SOURCE}")" \
		"$(m269_json_escape "${RUNTIME_CAMERA_PRESET}")" "$(m269_json_escape "${RUNTIME_CAMERA_PERF_MODE}")" "$(m269_json_escape "${RUNTIME_CAMERA_SOURCE}")" \
		"$(m269_json_escape "${CUSTOM_CPU_HOTPLUG}")" "$(m269_json_escape "${CUSTOM_CPU_MAX_FREQ_PCT}")" \
		"$(m269_json_escape "${CUSTOM_GPU_GOVERNOR_US}")" "$(m269_json_escape "${CUSTOM_GPU_IDLE_TIMER_MS}")" "$(m269_json_escape "${CUSTOM_GPU_MAX_GPUCLK_PCT}")" "$(m269_json_escape "${CUSTOM_GPU_MOD_PERCENT}")" \
		"$(m269_json_escape "${CUSTOM_DISPLAY_REFRESH_HZ}")" "$(m269_json_escape "${CUSTOM_DISPLAY_RENDER_SCALE_PCT}")" "$(m269_json_escape "${CUSTOM_CAMERA_PERF_MODE}")" \
		"$(m269_json_escape "${live_gov}")" "$(m269_json_escape "${live_idle}")" "$(m269_json_escape "${live_hotplug}")" "$(m269_json_escape "${live_cpu_max_freqs}")" "$(m269_json_escape "${live_cpu_maxpct}")" \
		"$(m269_json_escape "${live_maxgpu}")" "$(m269_json_escape "${live_maxpct}")" "$(m269_json_escape "${live_modpct}")" "$(m269_json_escape "${live_peak}")" "$(m269_json_escape "${live_min}")" "$(m269_json_escape "${live_wm}")" "$(m269_json_escape "${live_cam}")" \
		"$(m269_json_escape "${STOCK_GOV}")" "$(m269_json_escape "${STOCK_IDLE}")" "$(m269_json_escape "${STOCK_HOTPLUG}")" "$(m269_json_escape "${STOCK_CPU_MAX_FREQS}")" "$(m269_json_escape "${STOCK_MAX_GPUCLK}")" "$(m269_json_escape "${STOCK_GPU_MOD_PERCENT}")" "$(m269_json_escape "${STOCK_PEAK_REFRESH}")" "$(m269_json_escape "${STOCK_MIN_REFRESH}")" "$(m269_json_escape "${STOCK_WM_SIZE}")" "$(m269_json_escape "${STOCK_CAMERA_PERF_MODE}")" \
		"${cpu_presets}" "${gpu_presets}" "${display_presets}" "${camera_presets}" \
		"$(m269_json_escape "${SETTINGS}")" "$(m269_json_escape "${LOG}")" "$(m269_json_escape "${PRESETS}")" "$(m269_json_escape "${CAMERA_PERF_PARAM}")"
}

m269_emit_diagnostics_text() {
	m269_load_settings
	m269_load_stock
	echo "m269-perfd v3 diagnostics"
	echo "kernel=$(uname -r 2>/dev/null || true)"
	echo "boot_completed=$(getprop sys.boot_completed 2>/dev/null || true)"
	echo
	echo "[cpu]"
	echo "hotplug=$(m269_read_path "${CPU_HOTPLUG_PARAM}")"
	echo "max_freq_pct=$(m269_cpu_min_live_pct)"
	echo "max_freqs=$(m269_cpu_live_max_freqs)"
	for policy in $(m269_cpu_policies); do
		echo "$(m269_cpu_policy_name "${policy}") available=$(m269_read_path "${policy}/scaling_available_frequencies") max=$(m269_read_path "${policy}/scaling_max_freq")"
	done
	echo
	echo "[gpu]"
	echo "governor_us=$(m269_read_path "${KGSL_GOV_PARAM}")"
	echo "idle_timer_ms=$(m269_read_path "${KGSL_DEV}/idle_timer")"
	echo "max_gpuclk=$(m269_read_path "${KGSL_DEV}/max_gpuclk")"
	echo "available=$(m269_read_path "${KGSL_DEV}/gpu_available_frequencies")"
	mod_path="$(m269_gpu_mod_percent_path || true)"
	echo "mod_percent_path=${mod_path}"
	[ -n "${mod_path}" ] && echo "mod_percent=$(m269_read_path "${mod_path}")"
	echo
	echo "[display]"
	m269_cmd_exists wm && wm size 2>/dev/null || echo "wm indisponível"
	m269_cmd_exists wm && wm density 2>/dev/null || true
	echo "peak_refresh_rate=$(m269_settings_get system peak_refresh_rate)"
	echo "min_refresh_rate=$(m269_settings_get system min_refresh_rate)"
	echo
	echo "[camera]"
	echo "cam_perf_param=${CAMERA_PERF_PARAM}"
	echo "cam_perf_mode=$(m269_read_path "${CAMERA_PERF_PARAM}")"
	pidof cameraserver 2>/dev/null | sed 's/^/cameraserver_pid=/' || true
	pidof android.hardware.camera.provider@2.4-service_64 2>/dev/null | sed 's/^/camera_provider_pid=/' || true
	ls /dev/video* /dev/media* 2>/dev/null | wc -l | sed 's/^/media_nodes=/'
	echo
	echo "[touch]"
	if [ -r /proc/bus/input/devices ]; then
		grep -i -A4 -B1 'touch' /proc/bus/input/devices 2>/dev/null || true
	else
		echo "/proc/bus/input/devices indisponível"
	fi
}

m269_migrate_v1() {
	legacy_conf="${MODDIR}/m269-profiles.conf"
	legacy_default="${MODDIR}/default_profile"
	[ -f "${SETTINGS}" ] && return 0
	[ -f "${legacy_conf}" ] || {
		m269_load_settings
		m269_write_settings
		return 0
	}
	# shellcheck disable=SC1090
	. "${legacy_conf}"
	old_default="balanced"
	if [ -f "${legacy_default}" ]; then
		old_default="$(cat "${legacy_default}" 2>/dev/null || echo balanced)"
	fi
	case "${old_default}" in
		auto|balanced) cpu=conservative; gpu=balanced ;;
		performance) cpu=performance; gpu=responsive ;;
		game) cpu=game; gpu=latency ;;
		camera) cpu=performance; gpu=balanced ;;
		powersave) cpu=efficiency; gpu=economy ;;
		*) cpu=conservative; gpu=balanced ;;
	esac
	m269_load_settings
	BOOT_CPU_PRESET="${cpu}"
	BOOT_GPU_PRESET="${gpu}"
	RUNTIME_CPU_PRESET="${cpu}"
	RUNTIME_GPU_PRESET="${gpu}"
	set -- $(m269_cpu_values_for_preset "${cpu}")
	RUNTIME_CPU_HOTPLUG="$1"
	RUNTIME_CPU_MAX_FREQ_PCT="$2"
	set -- $(m269_gpu_values_for_preset "${gpu}")
	RUNTIME_GPU_GOVERNOR_US="$1"
	RUNTIME_GPU_IDLE_TIMER_MS="$2"
	RUNTIME_GPU_MAX_GPUCLK_PCT="$3"
	RUNTIME_GPU_MOD_PERCENT="$4"
	RUNTIME_CPU_SOURCE="migrated"
	RUNTIME_GPU_SOURCE="migrated"
	m269_write_settings
	m269_log "Migrado v1 default=${old_default} -> cpu=${cpu} gpu=${gpu}"
}
