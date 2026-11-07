#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/host/usb-common.sh"

cmd=${1:-status}
case "$cmd" in
  recovery-sysfs)
    discover_recovery_sysfs
    ;;
  rndis-iface)
    discover_rndis_iface
    ;;
  l4t-sysfs)
    discover_l4t_sysfs
    ;;
  l4t-iface)
    discover_l4t_iface
    ;;
  path)
    dev=$(discover_recovery_sysfs)
    usb_path_metadata "$dev"
    ;;
  status)
    echo '=== SMART HOST USB STATUS ==='
    recovery_summary
    auto=/sys/module/usbcore/parameters/autosuspend
    [[ -r "$auto" ]] && printf 'usbcore autosuspend    %s\n' "$(cat "$auto")" || printf 'usbcore autosuspend    unavailable\n'
    for scope in all default; do
      p="/proc/sys/net/ipv6/conf/$scope/disable_ipv6"
      [[ -r "$p" ]] && printf 'IPv6 %-16s %s\n' "$scope" "$(cat "$p")"
    done
    iface=$(discover_rndis_iface 2>/dev/null || true)
    if [[ -n "$iface" ]]; then
      printf 'RNDIS+L4T iface        %s\n' "$iface"
      ip -br link show dev "$iface" 2>/dev/null || true
      ip -6 addr show dev "$iface" 2>/dev/null || true
    else
      echo 'RNDIS+L4T iface        not present yet'
    fi
    ;;
  *)
    echo "usage: usb-discover.sh {status|recovery-sysfs|l4t-sysfs|l4t-iface|rndis-iface|path}" >&2
    exit 2
    ;;
esac
