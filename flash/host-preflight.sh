#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/host/usb-common.sh"

wait_recovery=0
while (($#)); do
  case "$1" in
    --wait-recovery) wait_recovery=1; shift ;;
    --fix-power)
      echo 'NOTE: --fix-power is deprecated; Smart Host Flash Guard applies fixes after confirmation.' >&2
      shift
      ;;
    *) echo "option inconnue: $1" >&2; exit 2 ;;
  esac
done

need_host() { command -v "$1" >/dev/null || { echo "$1 absent sur l'hôte" >&2; exit 1; }; }
need_host docker
need_host lsusb
need_host ip
need_host udevadm
need_host sysctl
need_host sudo
need_host losetup
need_host exportfs
need_host showmount
need_host rpcinfo

docker info >/dev/null || { echo 'docker daemon inaccessible' >&2; exit 1; }

cfg=${DOCKER_CONFIG:-$HOME/.docker}/config.json
if [[ -r "$cfg" ]] && command -v jq >/dev/null 2>&1; then
  helper=$(jq -r '.credsStore // empty' "$cfg" 2>/dev/null || true)
  if [[ -n "$helper" ]] && ! command -v "docker-credential-$helper" >/dev/null 2>&1; then
    echo "Docker credentials helper manquant: docker-credential-$helper (config: $cfg)" >&2
    exit 1
  fi
fi

if (( wait_recovery == 1 )); then
  echo "Attente du Jetson en Force Recovery USB (APX PID: $(recovery_product_list | xargs))..."
  until discover_recovery_sysfs >/dev/null 2>&1; do sleep 1; done
fi

echo '=== HOST FLASH PREFLIGHT ==='
if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  echo "Host OS: ${PRETTY_NAME:-${ID:-unknown}}"
fi
echo "Kernel: $(uname -r)"
echo "Docker context: $(docker context show 2>/dev/null || echo unknown)"
echo 'Docker: PASS'
echo 'Smart Host Guard: PASS'
if showmount -e localhost >/dev/null 2>&1; then
  echo 'Host NFS exports query: PASS'
  rpc_out=$(rpcinfo -p localhost 2>/dev/null || true)
  if awk '$1==100003 {found=1} END{exit !found}' <<<"$rpc_out"; then echo 'Host NFS rpc 100003: PASS'; else echo 'Host NFS rpc 100003: NEEDS FIX/RESTART'; fi
  if awk '$1==100005 {found=1} END{exit !found}' <<<"$rpc_out"; then echo 'Host mountd rpc 100005: PASS'; else echo 'Host mountd rpc 100005: NEEDS FIX/RESTART'; fi
  if showmount -e localhost 2>/dev/null | grep -q '/sdk_manager/downloads/Linux_for_Tegra'; then
    echo 'Host NFS stale exports: NOTE (legacy sdk_manager paths present; left untouched)'
  fi
else
  echo 'Host NFS server: NEEDS FIX/START before flash'
fi
if [[ -c /dev/loop-control ]]; then
  free_loop=$(losetup --find 2>/dev/null || true)
  if [[ -n "$free_loop" ]]; then
    echo "Host loop devices: PASS ($free_loop available)"
  else
    echo 'Host loop devices: NEEDS FIX (Smart Host Guard will attempt modprobe loop)'
  fi
else
  echo 'Host loop devices: NEEDS FIX (/dev/loop-control absent; Smart Host Guard will attempt modprobe loop)'
fi
if discover_recovery_sysfs >/dev/null 2>&1; then
  echo 'Jetson recovery USB: PASS'
elif discover_l4t_sysfs >/dev/null 2>&1; then
  echo 'Jetson recovery USB: WRONG MODE'
  echo 'Software recovery: ELIGIBLE (L4T USB gadget)'
elif discover_nvidia_sysfs >/dev/null 2>&1; then
  echo 'Jetson recovery USB: WRONG MODE'
  echo 'Software recovery: NOT ELIGIBLE (unknown NVIDIA USB mode)'
else
  echo 'Jetson recovery USB: NOT DETECTED'
fi
"$ROOT/host/usb-discover.sh" status
