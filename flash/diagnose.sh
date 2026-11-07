#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/host/usb-common.sh"

TIMEOUT=180
INTERVAL=1
IFACE=""
AUTO_FIX=0
NO_WAIT=0
STATE_FILE=""

usage() {
  cat <<'USAGE'
usage: ./jetsonctl flash diagnose [--fix] [--iface IFACE] [--timeout SEC] [--no-wait]
USAGE
}

while (($#)); do
  case "$1" in
    --iface) IFACE=${2:-}; shift 2 ;;
    --timeout) TIMEOUT=${2:-}; shift 2 ;;
    --interval) INTERVAL=${2:-}; shift 2 ;;
    --fix) AUTO_FIX=1; shift ;;
    --no-wait) NO_WAIT=1; shift ;;
    --state) STATE_FILE=${2:-}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

wait_iface() {
  local deadline=$((SECONDS + TIMEOUT))
  while (( SECONDS < deadline )); do
    IFACE=${IFACE:-$(discover_rndis_iface 2>/dev/null || true)}
    [[ -n "$IFACE" && -e "$SYSFS_ROOT/class/net/$IFACE" ]] && return 0
    (( NO_WAIT == 1 )) && return 2
    echo 'Waiting for Jetson RNDIS+L4T interface...'
    sleep "$INTERVAL"
  done
  return 2
}

ping_gate() {
  if command -v ping >/dev/null 2>&1; then
    ping -6 -c 2 -W 2 "fe80::1%$IFACE" >/dev/null 2>&1
  elif command -v ping6 >/dev/null 2>&1; then
    ping6 -c 2 -W 2 "fe80::1%$IFACE" >/dev/null 2>&1
  else
    return 3
  fi
}

ssh_gate() {
  command -v ssh >/dev/null 2>&1 || return 3
  local out rc
  set +e
  out=$(ssh -6 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=4 "root@fe80::1%$IFACE" true 2>&1)
  rc=$?
  set -e
  [[ $rc -eq 0 ]] && return 0
  grep -Eqi 'permission denied|authentication|publickey|password' <<<"$out" && return 0
  return 1
}

echo '=== INITRD FLASH DIAGNOSE ==='
recovery_summary
if ! wait_iface; then
  echo 'RNDIS+L4T             NOT DETECTED'
  exit 2
fi

echo "RNDIS+L4T             PASS ($IFACE)"
configuration=$(usb_get_udev_attr "$SYSFS_ROOT/class/net/$IFACE" configuration 2>/dev/null || true)
serial=$(usb_get_udev_attr "$SYSFS_ROOT/class/net/$IFACE" serial 2>/dev/null || true)
[[ -n "$configuration" ]] && echo "USB configuration      $configuration"
[[ -n "$serial" ]] && echo "USB serial             $serial"
ip -br link show dev "$IFACE" 2>/dev/null || true
ip -6 addr show dev "$IFACE" 2>/dev/null || true
sysctl "net.ipv6.conf.$IFACE.disable_ipv6" 2>/dev/null || true
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
  zone=$(firewall-cmd --get-zone-of-interface "$IFACE" 2>/dev/null || true)
  echo "firewalld zone         ${zone:-unassigned}"
fi

if (( AUTO_FIX == 1 )); then
  [[ -n "$STATE_FILE" ]] || STATE_FILE=${VOLUME:-/tmp}/state/host-usb-manual.tsv
  mkdir -p "$(dirname "$STATE_FILE")"
  touch "$STATE_FILE"
  sudo "$ROOT/host/usb-guard.sh" --state "$STATE_FILE" --iface "$IFACE" fix-iface
  echo "Manual fix state       $STATE_FILE"
  echo 'Restore with           ./jetsonctl host usb restore'
fi

if ping_gate; then
  echo 'Jetson fe80::1 ping    PASS'
else
  rc=$?
  [[ $rc -eq 3 ]] && echo 'Jetson fe80::1 ping    SKIP (ping absent)' || echo 'Jetson fe80::1 ping    FAIL'
fi

if ssh_gate; then
  echo 'Jetson SSH :22         REACHABLE'
else
  rc=$?
  [[ $rc -eq 3 ]] && echo 'Jetson SSH :22         SKIP (ssh absent)' || echo 'Jetson SSH :22         NOT REACHABLE'
fi

if command -v showmount >/dev/null 2>&1; then
  if showmount -e localhost >/dev/null 2>&1; then echo 'NFS exports            PASS'; else echo 'NFS exports            NOT READY'; fi
else
  echo 'NFS exports            SKIP (showmount absent on host)'
fi
if command -v rpcinfo >/dev/null 2>&1; then
  rpc_out=$(rpcinfo -p localhost 2>/dev/null || true)
  awk '$1==100003 {found=1} END{exit !found}' <<<"$rpc_out" && echo 'NFS rpc 100003         PASS' || echo 'NFS rpc 100003         NOT READY'
  awk '$1==100005 {found=1} END{exit !found}' <<<"$rpc_out" && echo 'mountd rpc 100005      PASS' || echo 'mountd rpc 100005      NOT READY'
fi
