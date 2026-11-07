#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/host/usb-common.sh"

SSH_HOST=${RECOVERY_SSH_HOST:-192.168.55.1}
SSH_USER=${RECOVERY_SSH_USER:-jetson}
SSH_IDENTITY=${RECOVERY_SSH_IDENTITY:-}
TIMEOUT=${RECOVERY_AUTO_TIMEOUT:-90}
CONNECT_TIMEOUT=${RECOVERY_SSH_CONNECT_TIMEOUT:-6}

usage() {
  cat <<'USAGE'
usage: enter-recovery.sh [options]

Request Force Recovery from a normally booted Jetson exposed as NVIDIA L4T USB gadget.
The remote sudo password, if required, is entered directly through SSH's TTY and is
never captured by this script.

Options:
  --host HOST       current Jetson SSH address (default: 192.168.55.1)
  --user USER       current Jetson SSH user (default: jetson)
  --identity PATH   SSH private key; otherwise SSH agent/default identities are used
  --timeout SEC     wait for APX/RCM after reboot request (default: 90)
  -h, --help        help
USAGE
}

while (($#)); do
  case "$1" in
    --host) [[ $# -ge 2 ]] || { echo '--host requires a value' >&2; exit 2; }; SSH_HOST=$2; shift 2 ;;
    --user) [[ $# -ge 2 ]] || { echo '--user requires a value' >&2; exit 2; }; SSH_USER=$2; shift 2 ;;
    --identity) [[ $# -ge 2 ]] || { echo '--identity requires a path' >&2; exit 2; }; SSH_IDENTITY=$2; shift 2 ;;
    --timeout) [[ $# -ge 2 ]] || { echo '--timeout requires seconds' >&2; exit 2; }; TIMEOUT=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v ssh >/dev/null 2>&1 || { echo 'ssh client absent on host.' >&2; exit 1; }

if discover_recovery_sysfs >/dev/null 2>&1; then
  echo 'Automatic Force Recovery: already in APX/RCM.'
  exit 0
fi

l4t_dev=$(discover_l4t_sysfs 2>/dev/null || true)
if [[ -z "$l4t_dev" ]]; then
  echo 'Automatic Force Recovery: no supported L4T USB gadget detected.' >&2
  exit 3
fi

iface=$(discover_l4t_iface 2>/dev/null || true)
product_id=$(cat "$l4t_dev/idProduct" 2>/dev/null || true)
product=$(cat "$l4t_dev/product" 2>/dev/null || true)

echo '=== AUTOMATIC FORCE RECOVERY ==='
printf 'L4T USB              0955:%s %s\n' "$product_id" "${product:-}"
printf 'SSH target           %s@%s\n' "$SSH_USER" "$SSH_HOST"
[[ -n "$iface" ]] && printf 'USB network iface    %s\n' "$iface"
if [[ -n "$SSH_IDENTITY" ]]; then
  [[ -r "$SSH_IDENTITY" ]] || { echo "SSH identity unreadable: $SSH_IDENTITY" >&2; exit 4; }
  printf 'SSH identity         %s\n' "$SSH_IDENTITY"
else
  echo 'SSH identity         agent/default identities'
fi

# 192.168.55.1 is NVIDIA's normal USB-gadget address. When we use it, ensure
# routing actually points at the L4T gadget interface rather than another network.
if [[ "$SSH_HOST" == 192.168.55.1 && -n "$iface" ]]; then
  route=$(ip -4 route get "$SSH_HOST" 2>/dev/null || true)
  if [[ -n "$route" && "$route" != *" dev $iface "* && "$route" != *" dev $iface" ]]; then
    echo "Automatic Force Recovery: route to $SSH_HOST is not via $iface: $route" >&2
    exit 5
  fi
fi

ssh_opts=(
  -tt
  -o "ConnectTimeout=${CONNECT_TIMEOUT}"
  -o ConnectionAttempts=2
  -o ServerAliveInterval=3
  -o ServerAliveCountMax=2
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
)
[[ -n "$SSH_IDENTITY" ]] && ssh_opts+=( -i "$SSH_IDENTITY" )

cat <<EOF2
Requesting software Force Recovery.
If SSH or sudo needs authentication, type it in the terminal; input is masked by SSH/sudo.
EOF2

set +e
ssh "${ssh_opts[@]}" "$SSH_USER@$SSH_HOST" \
  'if sudo -n true 2>/dev/null; then echo "Remote sudo: PASS (non-interactive)"; sudo -n reboot --force forced-recovery; else echo "Remote sudo authentication required."; sudo reboot --force forced-recovery; fi'
ssh_rc=$?
set -e

# A successful reboot often tears SSH down before it can return status 0. APX
# enumeration is therefore the authoritative success gate.
echo "Waiting for APX/RCM (PID: $(recovery_product_list | xargs))..."
deadline=$((SECONDS + TIMEOUT))
while (( SECONDS < deadline )); do
  if dev=$(discover_recovery_sysfs 2>/dev/null); then
    pid=$(cat "$dev/idProduct" 2>/dev/null || true)
    echo "Automatic Force Recovery: PASS (0955:${pid}, ${dev##*/})"
    exit 0
  fi
  sleep 1
done

echo "Automatic Force Recovery: FAILED (ssh rc=$ssh_rc, APX not detected after ${TIMEOUT}s)." >&2
echo 'Manual fallback: enter Force Recovery with the button header/jumper and power cycle.' >&2
exit 6
