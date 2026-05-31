#!/usr/bin/env bash
set -Eeuo pipefail

TIMEOUT=1800
INTERVAL=1
WAIT_FOR_IFACE=0
IFACE=""
QUIET=0

# Defaults tuned for the current host. Missing paths are skipped.
PCI_DEVICES=(
  "0000:04:00.0"
  "0000:05:02.0"
  "0000:3c:00.0"
)

USB_BUSES=(
  "usb3"
  "usb4"
)

usage() {
  cat <<'EOF'
Usage: sudo ./host-usb-fix.sh [options]

Prepare the host before Jetson initrd flashing:
- force the known USB/PCI path to stay powered on
- disable usbcore autosuspend for the current session
- enable global IPv6
- optionally wait for the Jetson USB network interface and fix IPv6 on it

Options:
  --wait             Wait for the Jetson USB network interface and fix it
  --iface IFACE      Fix a specific interface now, or while waiting with --wait
  --timeout SEC      Wait timeout in seconds for --wait (default: 1800)
  --interval SEC     Poll interval in seconds for --wait (default: 1)
  --quiet            Reduce terminal output, useful with background wait mode
  -h, --help         Show this help

Examples:
  sudo ./host-usb-fix.sh
  sudo ./host-usb-fix.sh --wait
  sudo ./host-usb-fix.sh --wait --quiet
  sudo ./host-usb-fix.sh --iface enp60s0u1
  sudo ./host-usb-fix.sh --wait --iface enp60s0u1
EOF
}

log() {
  if [[ "${QUIET}" -eq 0 ]]; then
    printf '%s\n' "$*"
  fi
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Ce script doit etre lance avec sudo/root." >&2
    exit 1
  fi
}

write_if_present() {
  local path="$1"
  local value="$2"

  if [[ -e "${path}" ]]; then
    printf '%s' "${value}" > "${path}"
    log "Set ${path}=${value}"
  fi
}

load_usb_modules() {
  local mod=""
  for mod in usbnet rndis_host cdc_ether; do
    modprobe "${mod}" 2>/dev/null || true
  done
}

prepare_power_path() {
  local dev=""
  local bus=""

  for dev in "${PCI_DEVICES[@]}"; do
    write_if_present "/sys/bus/pci/devices/${dev}/power/control" "on"
  done

  for bus in "${USB_BUSES[@]}"; do
    write_if_present "/sys/bus/usb/devices/${bus}/power/control" "on"
  done

  write_if_present "/sys/module/usbcore/parameters/autosuspend" "-1"
}

enable_global_ipv6() {
  sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null
  sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null
  log "Enabled global IPv6"
}

get_udev_attr() {
  local path="$1"
  local attr="$2"

  udevadm info --attribute-walk "$path" 2>/dev/null \
    | sed -n "0,/^[ ]*ATTRS{$attr}==\"\\(.*\\)\"$/s//\\1/p" \
    | xargs
}

discover_jetson_iface() {
  local path=""
  local iface=""
  local configuration=""

  for path in /sys/class/net/*; do
    iface="${path##*/}"
    [[ "${iface}" == "lo" ]] && continue

    configuration="$(get_udev_attr "${path}" configuration || true)"
    if [[ "${configuration}" =~ RNDIS\+L4T ]]; then
      printf '%s\n' "${iface}"
      return 0
    fi
  done

  return 1
}

wait_for_iface() {
  local deadline=$((SECONDS + TIMEOUT))

  while (( SECONDS < deadline )); do
    if [[ -n "${IFACE}" ]]; then
      [[ -e "/sys/class/net/${IFACE}" ]] && return 0
    elif IFACE="$(discover_jetson_iface)"; then
      return 0
    fi

    log "Waiting for Jetson USB network interface..."
    sleep "${INTERVAL}"
  done

  return 1
}

fix_iface_ipv6() {
  if [[ -z "${IFACE}" ]]; then
    echo "Aucune interface a corriger." >&2
    exit 1
  fi

  if [[ ! -e "/sys/class/net/${IFACE}" ]]; then
    echo "Interface introuvable: ${IFACE}" >&2
    exit 1
  fi

  sysctl -w "net.ipv6.conf.${IFACE}.disable_ipv6=0" >/dev/null
  ip link set dev "${IFACE}" up

  ip -6 addr add fc00:1:1:0::1/64 dev "${IFACE}" 2>/dev/null || true
  ip -6 addr add fe80::2/64 dev "${IFACE}" 2>/dev/null || true

  log "Fixed IPv6 on ${IFACE}"
  if [[ "${QUIET}" -eq 0 ]]; then
    ip -br link show dev "${IFACE}" || true
    ip -6 addr show dev "${IFACE}" || true
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --wait)
      WAIT_FOR_IFACE=1
      shift
      ;;
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
    --quiet)
      QUIET=1
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

require_root
load_usb_modules
prepare_power_path
enable_global_ipv6

if [[ -n "${IFACE}" && "${WAIT_FOR_IFACE}" -eq 0 ]]; then
  fix_iface_ipv6
elif [[ "${WAIT_FOR_IFACE}" -eq 1 ]]; then
  wait_for_iface || {
    echo "Aucune interface Jetson detectee avant le timeout." >&2
    exit 2
  }
  fix_iface_ipv6
else
  log "Host USB/IPv6 fix applied."
  log "Run again with --wait to auto-fix the Jetson USB network interface."
fi
