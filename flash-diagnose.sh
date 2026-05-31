#!/usr/bin/env bash
set -Eeuo pipefail

TIMEOUT=180
INTERVAL=1
IFACE=""
AUTO_FIX=0
WANT_SSH=1
PATTERN='RNDIS\+L4T'

usage() {
  cat <<'EOF'
Usage: ./flash-diagnose.sh [options]

Wait for the Jetson initrd USB network interface, inspect IPv6 state,
then test ping6 and optional SSH reachability.

Options:
  --iface IFACE       Use a specific interface instead of auto-detection
  --timeout SEC       Wait time for auto-detection (default: 180)
  --interval SEC      Poll interval (default: 1)
  --fix               Enable IPv6 on the interface and add host IPv6 addresses
  --no-ssh            Skip the SSH test
  -h, --help          Show this help

Examples:
  ./flash-diagnose.sh
  ./flash-diagnose.sh --fix
  ./flash-diagnose.sh --iface enp60s0u1i5 --fix
EOF
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

get_udev_attr() {
  local path="$1"
  local attr="$2"

  udevadm info --attribute-walk "$path" 2>/dev/null \
    | sed -n "0,/^[ ]*ATTRS{$attr}==\"\\(.*\\)\"$/s//\\1/p" \
    | xargs
}

discover_iface_once() {
  local path=""
  local iface=""
  local configuration=""

  for path in /sys/class/net/*; do
    iface="${path##*/}"
    [[ "${iface}" == "lo" ]] && continue
    configuration="$(get_udev_attr "${path}" configuration || true)"
    if [[ "${configuration}" =~ ${PATTERN} ]]; then
      printf '%s\n' "${iface}"
      return 0
    fi
  done

  return 1
}

wait_for_iface() {
  local deadline=$((SECONDS + TIMEOUT))

  while (( SECONDS < deadline )); do
    if IFACE="$(discover_iface_once)"; then
      return 0
    fi
    printf 'Waiting for Jetson USB network interface matching %s...\n' "${PATTERN}"
    sleep "${INTERVAL}"
  done

  return 1
}

require_iface() {
  if [[ -n "${IFACE}" ]]; then
    [[ -e "/sys/class/net/${IFACE}" ]] || {
      echo "Interface ${IFACE} introuvable." >&2
      exit 1
    }
    return 0
  fi

  wait_for_iface || {
    echo "Aucune interface Jetson RNDIS+L4T détectée avant le timeout." >&2
    exit 2
  }
}

show_iface_info() {
  local path="/sys/class/net/${IFACE}"
  local configuration=""
  local serial=""

  configuration="$(get_udev_attr "${path}" configuration || true)"
  serial="$(get_udev_attr "${path}" serial || true)"

  printf 'Interface: %s\n' "${IFACE}"
  [[ -n "${configuration}" ]] && printf 'Configuration USB: %s\n' "${configuration}"
  [[ -n "${serial}" ]] && printf 'Serial USB: %s\n' "${serial}"
  printf '\n'

  ip -br link show dev "${IFACE}" || true
  printf '\n'
  ip -6 addr show dev "${IFACE}" || true
  printf '\n'
  sysctl "net.ipv6.conf.${IFACE}.disable_ipv6" || true
  printf '\n'
}

fix_iface() {
  local ipv6_disabled=""

  ipv6_disabled="$(sysctl -n "net.ipv6.conf.${IFACE}.disable_ipv6" 2>/dev/null || echo 0)"

  printf 'Applying interface fixes on %s...\n' "${IFACE}"
  sudo ip link set dev "${IFACE}" up

  if [[ "${ipv6_disabled}" == "1" ]]; then
    sudo sysctl -w "net.ipv6.conf.${IFACE}.disable_ipv6=0"
  fi

  if ! ip -6 addr show dev "${IFACE}" | grep -q 'fc00:1:1:0::1/64'; then
    sudo ip -6 addr add fc00:1:1:0::1/64 dev "${IFACE}" 2>/dev/null || true
  fi

  if ! ip -6 addr show dev "${IFACE}" | grep -q 'fe80::2/64'; then
    sudo ip -6 addr add fe80::2/64 dev "${IFACE}" 2>/dev/null || true
  fi

  printf '\n'
}

test_ping() {
  printf 'Testing ping6 to fe80::1%%%s...\n' "${IFACE}"
  if ping6 -c 3 "fe80::1%${IFACE}"; then
    echo "PING OK"
    return 0
  fi

  echo "PING NOK" >&2
  return 1
}

test_ssh() {
  if (( WANT_SSH == 0 )); then
    return 0
  fi

  if ! have_cmd sshpass; then
    echo "sshpass absent, test SSH ignoré." >&2
    return 0
  fi

  printf 'Testing SSH to root@fe80::1%%%s...\n' "${IFACE}"
  if sshpass -p root ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=5 \
    "root@fe80::1%${IFACE}" \
    'echo SSH ready'
  then
    echo "SSH OK"
    return 0
  fi

  echo "SSH NOK" >&2
  return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iface)
      IFACE="${2:-}"
      shift 2
      ;;
    --timeout)
      TIMEOUT="${2:-}"
      shift 2
      ;;
    --interval)
      INTERVAL="${2:-}"
      shift 2
      ;;
    --fix)
      AUTO_FIX=1
      shift
      ;;
    --no-ssh)
      WANT_SSH=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Option inconnue: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

require_iface
show_iface_info

if (( AUTO_FIX == 1 )); then
  fix_iface
  show_iface_info
fi

test_ping
test_ssh
