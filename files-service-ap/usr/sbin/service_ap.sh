#!/bin/sh
# Service AP fallback for wifi client (STA) routers.
#
# When the router has no working uplink (no default route, or the gateway
# does not answer ping) for <timeout> seconds, all wifi client interfaces
# are disabled and the service AP is enabled on the lan network, where
# odhcpd hands out addresses. AP and STA share one radio, and an AP on a
# radio with an unconnected STA never comes up, so the STA has to go.
#
# The service AP stays on for <service_time> seconds, whether or not anyone
# is connected. Then the saved wifi clients are re-enabled and the uplink is
# tried again; after another <timeout> seconds without uplink the AP returns.
#
# Config: /etc/config/service_ap. Wifi clients turned off for the service
# mode are listed in /etc/service_ap.sta (survives a reboot in service mode).

. /lib/functions.sh

TAG=service_ap
INTERVAL=10
SECTION=service
STATE=/etc/service_ap.sta

log() { logger -t "$TAG" "$*"; }

load_cfg() {
	config_load service_ap
	config_get_bool enabled main enabled 1
	config_get timeout main timeout 180
	config_get service_time main service_time 600
	config_get ssid main ssid OpenWrt-Service
	config_get key main key ''
	config_get network main network lan
}

sta_collect() {
	local mode disabled
	config_get mode "$1" mode
	config_get disabled "$1" disabled 0
	[ "$mode" = sta ] || return 0
	STA_ALL="$STA_ALL $1"
	[ "$disabled" = 1 ] || STA_ON="$STA_ON $1"
}

wifi_scan_cfg() {
	STA_ALL=
	STA_ON=
	config_load wireless
	config_foreach sta_collect wifi-iface
}

ensure_ap_section() {
	local radio enc
	radio="$(uci show wireless | sed -n 's/^wireless\.\([^.]*\)=wifi-device$/\1/p' | head -n 1)"
	[ -n "$radio" ] || return 1

	if [ -n "$key" ]; then
		enc=psk2
	else
		enc=none
		log "no key in /etc/config/service_ap - service AP is OPEN"
	fi

	uci -q get wireless.$SECTION >/dev/null || {
		uci set wireless.$SECTION=wifi-iface
		uci set wireless.$SECTION.disabled=1
	}
	uci set wireless.$SECTION.device="$radio"
	uci set wireless.$SECTION.mode=ap
	uci set wireless.$SECTION.network="$network"
	uci set wireless.$SECTION.ssid="$ssid"
	uci set wireless.$SECTION.encryption="$enc"
	if [ -n "$key" ]; then
		uci set wireless.$SECTION.key="$key"
	else
		uci -q delete wireless.$SECTION.key
	fi
	[ -n "$(uci changes wireless)" ] && uci commit wireless
	return 0
}

uplink_ok() {
	local gw
	gw="$(ip route show default 2>/dev/null | awk '{print $3; exit}')"
	[ -n "$gw" ] && ping -c 1 -W 3 "$gw" >/dev/null 2>&1
}

travelmate() {
	[ -x /etc/init.d/travelmate ] || return 0
	case "$1" in
	stop) /etc/init.d/travelmate stop ;;
	start) /etc/init.d/travelmate enabled && /etc/init.d/travelmate start ;;
	esac
}

ap_on() {
	local s
	travelmate stop
	echo "$STA_ON" > "$STATE"
	for s in $STA_ON; do
		uci set wireless.$s.disabled=1
	done
	uci set wireless.$SECTION.disabled=0
	uci commit wireless
	wifi reload
	log "service AP '$ssid' on, wifi clients off:$STA_ON"
}

ap_off() {
	local s saved
	saved="$(cat "$STATE" 2>/dev/null)"
	for s in $saved; do
		uci -q get wireless.$s >/dev/null && uci set wireless.$s.disabled=0
	done
	uci set wireless.$SECTION.disabled=1
	uci commit wireless
	rm -f "$STATE"
	wifi reload
	travelmate start
	log "service AP off, wifi clients back on: $saved"
}

service_mode() {
	ap_on
	sleep "$service_time"
	ap_off
}

load_cfg
[ "$enabled" = 1 ] || exit 0
ensure_ap_section || { log "no wifi radio"; sleep 60; exit 0; }

# rebooted in service mode: give the uplink its chance first
if [ -e "$STATE" ] || [ "$(uci -q get wireless.$SECTION.disabled)" != 1 ]; then
	log "service mode left over from before restart - restoring wifi clients"
	ap_off
fi

fail=0
while true; do
	wifi_scan_cfg
	if [ -z "$STA_ALL" ]; then
		fail=0
	elif uplink_ok; then
		fail=0
	else
		fail=$((fail + INTERVAL))
		[ $((fail % 60)) -eq 0 ] && log "no uplink for ${fail}s (limit ${timeout}s)"
	fi

	if [ "$fail" -ge "$timeout" ]; then
		log "no uplink for ${fail}s - starting service AP"
		service_mode
		fail=0
	fi
	sleep $INTERVAL
done
