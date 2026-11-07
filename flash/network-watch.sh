#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/host/usb-common.sh"

STATE_FILE=""
TIMEOUT=${HOST_FLASH_IFACE_TIMEOUT:-1800}
INTERVAL=${HOST_FLASH_IFACE_INTERVAL:-0.25}
KEEPALIVE_INTERVAL=${HOST_FLASH_KEEPALIVE_INTERVAL:-0.5}
IFACE=${HOST_FLASH_IFACE:-}
READY_FILE=""

while (($#)); do
  case "$1" in
    --state) STATE_FILE=${2:-}; shift 2 ;;
    --timeout) TIMEOUT=${2:-}; shift 2 ;;
    --interval) INTERVAL=${2:-}; shift 2 ;;
    --iface) IFACE=${2:-}; shift 2 ;;
    --ready-file) READY_FILE=${2:-}; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$STATE_FILE" ]] || { echo '--state required' >&2; exit 2; }

ping_ok() {
  [[ -n "$IFACE" ]] || return 1
  if command -v ping >/dev/null 2>&1; then ping -6 -c 1 -W 1 "fe80::1%$IFACE" >/dev/null 2>&1
  elif command -v ping6 >/dev/null 2>&1; then ping6 -c 1 -W 1 "fe80::1%$IFACE" >/dev/null 2>&1
  else return 1
  fi
}

apply_iface() {
  "$ROOT/host/usb-guard.sh" --state "$STATE_FILE" --iface "$IFACE" --quiet fix-iface
}

deadline=$((SECONDS + TIMEOUT))
announced=0
ready=0
failures=0
while (( SECONDS < deadline )); do
  if [[ -z "$IFACE" || ! -e "$SYSFS_ROOT/class/net/$IFACE" ]]; then
    IFACE=$(discover_rndis_iface 2>/dev/null || true)
    announced=0
  fi
  if [[ -n "$IFACE" && -e "$SYSFS_ROOT/class/net/$IFACE" ]]; then
    if apply_iface; then
      failures=0
      if (( announced == 0 )); then
        echo "RNDIS+L4T detected: $IFACE"
        announced=1
      fi
      if ping_ok; then
        echo "INITRD NETWORK READY: fe80::1%$IFACE reachable"
        [[ -n "$READY_FILE" ]] && printf '%s\n' "$IFACE" > "$READY_FILE"
        ready=1
        break
      fi
    else
      failures=$((failures + 1))
      if (( failures == 1 || failures % 10 == 0 )); then
        echo "INITRD network guard re-apply failed on $IFACE (count=$failures)" >&2
      fi
    fi
  fi
  sleep "$INTERVAL"
done

if (( ready == 0 )); then
  echo "INITRD network watcher timed out after ${TIMEOUT}s" >&2
  exit 2
fi

# Keep winning races against NetworkManager/udev while NVIDIA transitions from
# the link-local ping gate to global SSH/NFS. Re-discover after re-enumeration.
failures=0
while true; do
  if [[ -z "$IFACE" || ! -e "$SYSFS_ROOT/class/net/$IFACE" ]]; then
    IFACE=$(discover_rndis_iface 2>/dev/null || true)
  fi
  if [[ -n "$IFACE" && -e "$SYSFS_ROOT/class/net/$IFACE" ]]; then
    if apply_iface; then
      failures=0
    else
      failures=$((failures + 1))
      if (( failures == 1 || failures % 20 == 0 )); then
        echo "INITRD network keepalive failed on $IFACE (count=$failures)" >&2
      fi
    fi
  fi
  sleep "$KEEPALIVE_INTERVAL"
done
