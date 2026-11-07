#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/host/usb-common.sh"

STATE_FILE=""
TIMEOUT=${HOST_FLASH_IFACE_TIMEOUT:-1800}
INTERVAL=1
QUIET=0
PROC_SYS_ROOT=${PROC_SYS_ROOT:-/proc/sys}

usage() {
  cat <<'USAGE'
usage: sudo usb-guard.sh --state FILE <begin|wait-recovery|fix-iface|fix-l4t-iface|restore|status> [options]

Options:
  --state FILE      state snapshot used for restoration
  --timeout SEC     recovery wait timeout (default: 1800)
  --interval SEC    polling interval (default: 1)
  --iface IFACE     explicit RNDIS interface for fix-iface
  --quiet           less output
USAGE
}

log() { (( QUIET == 1 )) || printf '%s\n' "$*"; }
require_root() { [[ $EUID -eq 0 ]] || { echo 'Smart Host Flash Guard requires sudo/root.' >&2; exit 1; }; }

state_key_exists() {
  local kind=$1 key=$2
  [[ -r "$STATE_FILE" ]] && awk -F '\t' -v k="$kind" -v p="$key" '$1==k && $2==p {found=1} END{exit !found}' "$STATE_FILE"
}

record_once() {
  local kind=$1 key=$2 value=$3 extra=${4:-}
  state_key_exists "$kind" "$key" && return 0
  printf '%s\t%s\t%s\t%s\n' "$kind" "$key" "$value" "$extra" >> "$STATE_FILE"
}

snapshot_file() {
  local kind=$1 path=$2
  [[ -r "$path" ]] || return 0
  record_once "$kind" "$path" "$(cat "$path")"
}

write_file() {
  local path=$1 value=$2
  [[ -e "$path" ]] || return 0
  printf '%s' "$value" > "$path" 2>/dev/null || true
}

firewalld_active() {
  command -v firewall-cmd >/dev/null 2>&1     && firewall-cmd --state >/dev/null 2>&1
}

trust_iface_firewalld() {
  local iface=$1 old_zone=""
  firewalld_active || return 0
  if ! state_key_exists firewall-zone "$iface"; then
    old_zone=$(firewall-cmd --get-zone-of-interface "$iface" 2>/dev/null || true)
    [[ -n "$old_zone" ]] || old_zone='__none__'
    record_once firewall-zone "$iface" "$old_zone"
  fi
  firewall-cmd --zone=trusted --change-interface="$iface" >/dev/null
  [[ "$(firewall-cmd --get-zone-of-interface "$iface" 2>/dev/null || true)" == trusted ]] || {
    echo "Impossible de placer $iface dans la zone firewalld trusted." >&2
    return 1
  }
}

snapshot_ipv6_addr() {
  local iface=$1 base=$2 current=""
  current=$(ip -6 -o addr show dev "$iface" 2>/dev/null | awk -v b="$base" '$4 ~ ("^" b "/") {print $4; exit}')
  [[ -n "$current" ]] || current=absent
  record_once iface6-address "$iface|$base" "$current"
}

snapshot_and_power_path() {
  local dev=${1:-} kind ident control old
  [[ -n "$dev" ]] || dev=$(discover_recovery_sysfs 2>/dev/null || discover_l4t_sysfs 2>/dev/null || true)
  [[ -n "$dev" ]] || return 1
  while IFS=$'\t' read -r kind ident control; do
    [[ -e "$control" ]] || continue
    old=$(cat "$control" 2>/dev/null || true)
    record_once control "$control" "$old" "$kind:$ident"
    write_file "$control" on
    log "Power guard: $kind $ident -> on"
  done < <(usb_path_metadata "$dev" 2>/dev/null || true)
}

load_usb_modules() {
  local mod
  for mod in usbnet rndis_host cdc_ether; do
    modprobe "$mod" 2>/dev/null || true
  done
}

apply_global() {
  local auto=/sys/module/usbcore/parameters/autosuspend
  snapshot_file global "$auto"
  write_file "$auto" -1
  local p
  for p in $PROC_SYS_ROOT/net/ipv6/conf/all/disable_ipv6 $PROC_SYS_ROOT/net/ipv6/conf/default/disable_ipv6; do
    snapshot_file global "$p"
    write_file "$p" 0
  done
  load_usb_modules
}

begin_guard() {
  require_root
  mkdir -p "$(dirname "$STATE_FILE")"
  if [[ -s "$STATE_FILE" ]] && grep -q $'^meta\tactive\t1\t' "$STATE_FILE" && ! grep -q $'^meta\trestored\t1\t' "$STATE_FILE"; then
    log 'Previous guard state is still active; restoring it before a new snapshot.'
    restore_guard || true
  fi
  : > "$STATE_FILE"
  printf 'meta\tactive\t1\t%s\n' "$(date -Is 2>/dev/null || date)" >> "$STATE_FILE"
  apply_global
  snapshot_and_power_path || true
  log "Smart Host Flash Guard: ACTIVE"
  log "State: $STATE_FILE"
}

wait_recovery() {
  require_root
  local deadline=$((SECONDS + TIMEOUT)) dev
  while (( SECONDS < deadline )); do
    dev=$(discover_recovery_sysfs 2>/dev/null || true)
    if [[ -n "$dev" ]] && usb_devnode_available "$dev"; then
      snapshot_and_power_path "$dev" || true
      log "Jetson Force Recovery: PASS (${dev##*/}; $(usb_devnode_for_sysfs "$dev"))"
      return 0
    elif [[ -n "$dev" ]]; then
      log "Jetson APX visible in sysfs but /dev/bus/usb node is missing; waiting (container mapping?)."
    fi
    log "Waiting for Jetson Force Recovery USB (APX PID: $(recovery_product_list | xargs))..."
    sleep "$INTERVAL"
  done
  echo "Jetson Force Recovery non détecté après ${TIMEOUT}s." >&2
  return 2
}

fix_iface() {
  require_root
  local iface=${1:-}
  [[ -n "$iface" ]] || iface=$(discover_rndis_iface 2>/dev/null || true)
  [[ -n "$iface" && -e "$SYSFS_ROOT/class/net/$iface" ]] || { echo 'RNDIS+L4T interface not found.' >&2; return 2; }
  local usbdev=""
  usbdev=$(usb_device_ancestor "$SYSFS_ROOT/class/net/$iface" 2>/dev/null || true)
  [[ -n "$usbdev" ]] && snapshot_and_power_path "$usbdev" || true

  local disable="$PROC_SYS_ROOT/net/ipv6/conf/$iface/disable_ipv6" link_state=DOWN
  ip link show dev "$iface" 2>/dev/null | grep -q '<[^>]*UP' && link_state=UP || true
  record_once iface-link "$iface" "$link_state"
  snapshot_file iface-sysctl "$disable"
  snapshot_ipv6_addr "$iface" 'fc00:1:1::1'
  snapshot_ipv6_addr "$iface" 'fe80::2'
  trust_iface_firewalld "$iface"

  [[ -e "$disable" ]] || { echo "IPv6 sysctl absent pour $iface" >&2; return 3; }
  printf '0' > "$disable"
  [[ "$(cat "$disable" 2>/dev/null || true)" == 0 ]] || { echo "IPv6 reste désactivé sur $iface" >&2; return 3; }
  ip link set dev "$iface" up

  # NVIDIA R39 device-instance 0 canonical host addresses.
  ip -6 addr replace fc00:1:1:0::1/64 dev "$iface" nodad
  ip -6 addr replace fe80::2/64 dev "$iface" nodad

  ip -6 -o addr show dev "$iface" | grep -Eq '[[:space:]]fc00:1:1::1/64[[:space:]]' || { echo "Adresse ULA NVIDIA absente sur $iface" >&2; return 4; }
  ip -6 -o addr show dev "$iface" | grep -Eq '[[:space:]]fe80::2/64[[:space:]]' || { echo "Adresse link-local NVIDIA absente sur $iface" >&2; return 4; }
  log "RNDIS IPv6 guard: $iface PASS (disable_ipv6=0, fc00:1:1::1/64, fe80::2/64)"
}

fix_l4t_iface() {
  require_root
  local iface=${1:-} dev link_state=DOWN addr=192.168.55.100/24
  [[ -n "$iface" ]] || iface=$(discover_l4t_iface 2>/dev/null || true)
  [[ -n "$iface" && -e "$SYSFS_ROOT/class/net/$iface" ]] || { echo 'L4T USB gadget interface not found.' >&2; return 2; }
  dev=$(discover_l4t_sysfs 2>/dev/null || true)
  [[ -n "$dev" ]] && snapshot_and_power_path "$dev" || true
  ip link show dev "$iface" 2>/dev/null | grep -q '<[^>]*UP' && link_state=UP || true
  record_once iface-link "$iface" "$link_state"
  if ip -4 addr show dev "$iface" 2>/dev/null | grep -Fq "$addr"; then
    record_once iface4-addr "$iface|$addr" present
  else
    record_once iface4-addr "$iface|$addr" absent
  fi
  ip link set dev "$iface" up 2>/dev/null || true
  ip -4 addr show dev "$iface" 2>/dev/null | grep -Fq "$addr" || ip -4 addr add "$addr" dev "$iface" 2>/dev/null || true
  log "L4T gadget IPv4 guard: $iface host=192.168.55.100/24"
}

restore_guard() {
  require_root
  [[ -r "$STATE_FILE" ]] || { log "No guard state: $STATE_FILE"; return 0; }
  local kind key value extra iface addr
  while IFS=$'\t' read -r kind key value extra; do
    case "$kind" in
      control|global|iface-sysctl)
        [[ -e "$key" ]] && write_file "$key" "$value"
        ;;
      iface6-address)
        iface=${key%%|*}; addr=${key#*|}
        if [[ -e "$SYSFS_ROOT/class/net/$iface" ]]; then
          if [[ "$value" == absent ]]; then
            if [[ "$addr" == 'fc00:1:1::1' ]]; then
              ip -6 addr del fc00:1:1:0::1/64 dev "$iface" 2>/dev/null || true
            else
              ip -6 addr del fe80::2/64 dev "$iface" 2>/dev/null || true
            fi
          else
            ip -6 addr replace "$value" dev "$iface" nodad 2>/dev/null || true
          fi
        fi
        ;;
      firewall-zone)
        if firewalld_active && [[ -e "$SYSFS_ROOT/class/net/$key" ]]; then
          if [[ "$value" == '__none__' ]]; then
            firewall-cmd --zone=trusted --remove-interface="$key" >/dev/null 2>&1 || true
          else
            firewall-cmd --zone="$value" --change-interface="$key" >/dev/null 2>&1 || true
          fi
        fi
        ;;
      iface-addr)
        iface=${key%%|*}; addr=${key#*|}
        if [[ "$value" == absent && -e "$SYSFS_ROOT/class/net/$iface" ]]; then
          ip -6 addr del "$addr" dev "$iface" 2>/dev/null || true
        fi
        ;;
      iface4-addr)
        iface=${key%%|*}; addr=${key#*|}
        if [[ "$value" == absent && -e "$SYSFS_ROOT/class/net/$iface" ]]; then
          ip -4 addr del "$addr" dev "$iface" 2>/dev/null || true
        fi
        ;;
      iface-link)
        if [[ "$value" == DOWN && -e "$SYSFS_ROOT/class/net/$key" ]]; then
          ip link set dev "$key" down 2>/dev/null || true
        fi
        ;;
    esac
  done < <(tac "$STATE_FILE" 2>/dev/null || cat "$STATE_FILE")
  printf 'meta\trestored\t1\t%s\n' "$(date -Is 2>/dev/null || date)" >> "$STATE_FILE"
  log 'Smart Host Flash Guard: RESTORED'
}

status_guard() {
  if [[ -r "$STATE_FILE" ]]; then
    echo "state=$STATE_FILE"
    tail -n 30 "$STATE_FILE"
  else
    echo "state absent: $STATE_FILE"
  fi
}

IFACE=""
args=()
while (($#)); do
  case "$1" in
    --state) STATE_FILE=${2:-}; shift 2 ;;
    --timeout) TIMEOUT=${2:-}; shift 2 ;;
    --interval) INTERVAL=${2:-}; shift 2 ;;
    --iface) IFACE=${2:-}; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    begin|wait-recovery|fix-iface|fix-l4t-iface|restore|status) args+=("$1"); shift ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$STATE_FILE" ]] || { echo '--state FILE is required.' >&2; exit 2; }
cmd=${args[0]:-status}
case "$cmd" in
  begin) begin_guard ;;
  wait-recovery) wait_recovery ;;
  fix-iface) fix_iface "$IFACE" ;;
  fix-l4t-iface) fix_l4t_iface "$IFACE" ;;
  restore) restore_guard ;;
  status) status_guard ;;
  *) usage >&2; exit 2 ;;
esac
