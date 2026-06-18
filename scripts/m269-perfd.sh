#!/system/bin/sh
# m269-perfd v3 — configurador CPU/GPU/display/camera para kernel custom SM-A057M
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
MODDIR="${MODDIR:-${SCRIPT_DIR}}"
API="${SCRIPT_DIR}/lib/m269-perfd-api.sh"
[ -f "${API}" ] || API="${MODDIR}/lib/m269-perfd-api.sh"
# shellcheck source=/dev/null
. "${API}"

m269_init_paths
m269_load_presets

usage() {
	cat <<EOF
Uso: m269-perfd.sh <comando> [args]

Comandos:
  read-state
  apply-boot
  apply-cpu <preset|custom>
  apply-gpu <preset|custom>
  apply-display <preset|custom>
  apply-camera <preset|custom>
  apply-both <cpu> <gpu>
  save-boot <cpu_preset> <gpu_preset>
  save-boot-display <display_preset>
  save-boot-camera <camera_preset>
  save-custom-cpu <hotplug> <max_freq_pct>
  save-custom-gpu <gov_us> <idle_ms> <max_pct> [mod_percent]
  save-custom-display <refresh_hz> <render_scale_pct>
  save-custom-camera <perf_mode>
  diagnose
  restore-stock
  migrate-v1
EOF
}

cmd="${1:-}"
case "${cmd}" in
	read-state)
		m269_emit_read_state_json
		;;
	apply-boot)
		m269_require_root || exit 1
		m269_migrate_v1
		m269_load_settings
		m269_apply_cpu_preset "${BOOT_CPU_PRESET}" boot || exit 1
		m269_apply_gpu_preset "${BOOT_GPU_PRESET}" boot || exit 1
		m269_apply_display_preset "${BOOT_DISPLAY_PRESET}" boot || exit 1
		m269_apply_camera_preset "${BOOT_CAMERA_PRESET}" boot || exit 1
		echo "Boot aplicado: CPU=${BOOT_CPU_PRESET} GPU=${BOOT_GPU_PRESET} DISPLAY=${BOOT_DISPLAY_PRESET} CAMERA=${BOOT_CAMERA_PRESET}"
		;;
	apply-cpu)
		m269_require_root || exit 1
		target="${2:-}"
		case "${target}" in
			custom)
				m269_load_settings
				m269_apply_cpu_custom \
					"${CUSTOM_CPU_HOTPLUG}" \
					"${CUSTOM_CPU_MAX_FREQ_PCT}" manual || exit 1
				;;
			"")
				echo "Uso: apply-cpu <preset|custom>" >&2
				exit 1
				;;
			*)
				m269_apply_cpu_preset "${target}" manual || exit 1
				;;
		esac
		echo "CPU aplicado."
		;;
	apply-gpu)
		m269_require_root || exit 1
		target="${2:-}"
		case "${target}" in
			custom)
				m269_load_settings
				m269_apply_gpu_custom \
					"${CUSTOM_GPU_GOVERNOR_US}" \
					"${CUSTOM_GPU_IDLE_TIMER_MS}" \
					"${CUSTOM_GPU_MAX_GPUCLK_PCT}" \
					"${CUSTOM_GPU_MOD_PERCENT}" manual || exit 1
				;;
			"")
				echo "Uso: apply-gpu <preset|custom>" >&2
				exit 1
				;;
			*)
				m269_apply_gpu_preset "${target}" manual || exit 1
				;;
		esac
		echo "GPU aplicado."
		;;
	apply-display)
		m269_require_root || exit 1
		target="${2:-}"
		case "${target}" in
			custom)
				m269_load_settings
				m269_apply_display_custom \
					"${CUSTOM_DISPLAY_REFRESH_HZ}" \
					"${CUSTOM_DISPLAY_RENDER_SCALE_PCT}" manual || exit 1
				;;
			"")
				echo "Uso: apply-display <preset|custom>" >&2
				exit 1
				;;
			*)
				m269_apply_display_preset "${target}" manual || exit 1
				;;
		esac
		echo "Display aplicado."
		;;
	apply-camera)
		m269_require_root || exit 1
		target="${2:-}"
		case "${target}" in
			custom)
				m269_load_settings
				m269_apply_camera_custom "${CUSTOM_CAMERA_PERF_MODE}" manual || exit 1
				;;
			"")
				echo "Uso: apply-camera <preset|custom>" >&2
				exit 1
				;;
			*)
				m269_apply_camera_preset "${target}" manual || exit 1
				;;
		esac
		echo "Camera aplicada."
		;;
	apply-both)
		m269_require_root || exit 1
		cpu="${2:-}"
		gpu="${3:-}"
		[ -n "${cpu}" ] && [ -n "${gpu}" ] || {
			echo "Uso: apply-both <cpu_preset> <gpu_preset>" >&2
			exit 1
		}
		m269_apply_cpu_preset "${cpu}" manual || exit 1
		m269_apply_gpu_preset "${gpu}" manual || exit 1
		echo "CPU+GPU aplicados."
		;;
	save-boot)
		m269_require_root || exit 1
		cpu="${2:-}"
		gpu="${3:-}"
		m269_valid_cpu_preset "${cpu}" || exit 1
		m269_valid_gpu_preset "${gpu}" || exit 1
		m269_load_settings
		BOOT_CPU_PRESET="${cpu}"
		BOOT_GPU_PRESET="${gpu}"
		m269_write_settings
		echo "Boot padrão: CPU=${cpu} GPU=${gpu}"
		;;
	save-boot-display)
		m269_require_root || exit 1
		display="${2:-}"
		m269_valid_display_preset "${display}" || exit 1
		m269_load_settings
		BOOT_DISPLAY_PRESET="${display}"
		m269_write_settings
		echo "Boot display: DISPLAY=${display}"
		;;
	save-boot-camera)
		m269_require_root || exit 1
		camera="${2:-}"
		m269_valid_camera_preset "${camera}" || exit 1
		m269_load_settings
		BOOT_CAMERA_PRESET="${camera}"
		m269_write_settings
		echo "Boot camera: CAMERA=${camera}"
		;;
	save-custom-cpu)
		m269_require_root || exit 1
		hotplug="${2:-}"
		maxpct="${3:-100}"
		m269_validate_cpu_values "${hotplug}" "${maxpct}" || exit 1
		m269_load_settings
		CUSTOM_CPU_HOTPLUG="${hotplug}"
		CUSTOM_CPU_MAX_FREQ_PCT="${maxpct}"
		m269_write_settings
		echo "Custom CPU salvo: hotplug=${hotplug} max_freq_pct=${maxpct}"
		;;
	save-custom-gpu)
		m269_require_root || exit 1
		gov="${2:-}"
		idle="${3:-}"
		maxpct="${4:-}"
		modpct="${5:-100}"
		m269_validate_gpu_values "${gov}" "${idle}" "${maxpct}" "${modpct}" || exit 1
		m269_load_settings
		CUSTOM_GPU_GOVERNOR_US="${gov}"
		CUSTOM_GPU_IDLE_TIMER_MS="${idle}"
		CUSTOM_GPU_MAX_GPUCLK_PCT="${maxpct}"
		CUSTOM_GPU_MOD_PERCENT="${modpct}"
		m269_write_settings
		echo "Custom GPU salvo."
		;;
	save-custom-display)
		m269_require_root || exit 1
		refresh="${2:-}"
		scale="${3:-}"
		m269_validate_display_values "${refresh}" "${scale}" || exit 1
		m269_load_settings
		CUSTOM_DISPLAY_REFRESH_HZ="${refresh}"
		CUSTOM_DISPLAY_RENDER_SCALE_PCT="${scale}"
		m269_write_settings
		echo "Custom display salvo."
		;;
	save-custom-camera)
		m269_require_root || exit 1
		mode="${2:-}"
		m269_validate_camera_mode "${mode}" || exit 1
		m269_load_settings
		CUSTOM_CAMERA_PERF_MODE="${mode}"
		m269_write_settings
		echo "Custom camera salvo."
		;;
	diagnose)
		m269_emit_diagnostics_text
		;;
	restore-stock)
		m269_require_root || exit 1
		m269_restore_stock
		echo "Stock restaurado."
		;;
	migrate-v1)
		m269_require_root || exit 1
		m269_migrate_v1
		echo "Migração concluída."
		;;
	*)
		usage
		exit 1
		;;
esac
