#!/system/bin/sh
MODDIR="${0%/*}"

chmod 0755 "${MODDIR}/m269-perfd.sh" 2>/dev/null || true
[ -d "${MODDIR}/lib" ] && chmod 0755 "${MODDIR}/lib/"*.sh 2>/dev/null || true

until [ "$(getprop sys.boot_completed)" = "1" ]; do
	sleep 5
done

MODDIR="${MODDIR}" \
STATE_DIR="${MODDIR}/state" \
PRESETS="${MODDIR}/m269-presets.conf" \
	sh "${MODDIR}/m269-perfd.sh" apply-boot