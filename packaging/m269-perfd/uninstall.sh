#!/system/bin/sh
MODDIR="${0%/*}"

MODDIR="${MODDIR}" \
STATE_DIR="${MODDIR}/state" \
PRESETS="${MODDIR}/m269-presets.conf" \
	sh "${MODDIR}/m269-perfd.sh" restore-stock 2>/dev/null || true