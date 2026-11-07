#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/host/usb-common.sh"

TIMEOUT=${POST_FLASH_USB_TIMEOUT:-120}
INTERVAL=${POST_FLASH_USB_INTERVAL:-1}
IFACE=""

while (($#)); do
  case "$1" in
    --timeout) TIMEOUT=${2:-}; shift 2 ;;
    --interval) INTERVAL=${2:-}; shift 2 ;;
    --iface) IFACE=${2:-}; shift 2 ;;
    -h|--help)
      echo 'usage: sudo post-flash-network.sh [--timeout SEC] [--iface IFACE]'
      exit 0
      ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ ${EUID} -eq 0 ]] || { echo 'post-flash-network.sh requires root.' >&2; exit 1; }
command -v ip >/dev/null 2>&1 || { echo 'ip absent.' >&2; exit 1; }

deadline=$((SECONDS + TIMEOUT))
while (( SECONDS < deadline )); do
  if [[ -z "$IFACE" || ! -e "$SYSFS_ROOT/class/net/$IFACE" ]]; then
    IFACE=$(discover_l4t_iface 2>/dev/null || true)
  fi
  if [[ -n "$IFACE" && -e "$SYSFS_ROOT/class/net/$IFACE" ]]; then
    break
  fi
  sleep "$INTERVAL"
done

[[ -n "$IFACE" && -e "$SYSFS_ROOT/class/net/$IFACE" ]] || {
  echo "Post-flash L4T gadget: NOT DETECTED after ${TIMEOUT}s" >&2
  exit 2
}

# Do not remove NetworkManager's own address (for example 10.42.0.1/24).
# Add NVIDIA's management address as a secondary host address instead.
[[ -e "/proc/sys/net/ipv6/conf/$IFACE/disable_ipv6" ]] && printf '0' > "/proc/sys/net/ipv6/conf/$IFACE/disable_ipv6"
ip link set dev "$IFACE" up
ip -4 addr replace 192.168.55.100/24 dev "$IFACE"
ip -6 addr replace fe80::2/64 dev "$IFACE" nodad

echo "Post-flash L4T gadget: PASS ($IFACE)"
echo "Host management IPv4: 192.168.55.100/24"

v4=FAIL
v6=FAIL
reach_timeout=${POST_FLASH_REACHABILITY_TIMEOUT:-30}
reach_deadline=$((SECONDS + reach_timeout))
while (( SECONDS < reach_deadline )); do
  # Re-assert the management addresses because NetworkManager may rewrite the
  # freshly re-enumerated gadget during the first seconds after boot.
  [[ -e "/proc/sys/net/ipv6/conf/$IFACE/disable_ipv6" ]] && printf '0' > "/proc/sys/net/ipv6/conf/$IFACE/disable_ipv6"
  ip link set dev "$IFACE" up
  ip -4 addr replace 192.168.55.100/24 dev "$IFACE"
  ip -6 addr replace fe80::2/64 dev "$IFACE" nodad

  v4=FAIL
  v6=FAIL
  if command -v ping >/dev/null 2>&1; then
    ping -c 1 -W 1 -I "$IFACE" 192.168.55.1 >/dev/null 2>&1 && v4=PASS || true
    ping -6 -c 1 -W 1 "fe80::1%$IFACE" >/dev/null 2>&1 && v6=PASS || true
  elif command -v ping6 >/dev/null 2>&1; then
    ping6 -c 1 -W 1 "fe80::1%$IFACE" >/dev/null 2>&1 && v6=PASS || true
  fi
  [[ "$v4" == PASS && "$v6" == PASS ]] && break
  sleep "$INTERVAL"
done

printf 'Jetson 192.168.55.1: %s\n' "$v4"
printf 'Jetson fe80::1%%%s: %s\n' "$IFACE" "$v6"
printf '%s\n' "$IFACE"
[[ "$v4" == PASS && "$v6" == PASS ]] || exit 3
