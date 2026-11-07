#!/usr/bin/env bash
set -Eeuo pipefail

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    echo "loop-guard doit être exécuté en root." >&2
    exit 1
  fi
}

require_root
command -v modprobe >/dev/null 2>&1 || { echo "modprobe absent sur l'hôte." >&2; exit 1; }
command -v losetup >/dev/null 2>&1 || { echo "losetup absent sur l'hôte." >&2; exit 1; }

modprobe loop 2>/dev/null || true

if [[ ! -c /dev/loop-control ]]; then
  echo "Loop device: FAIL (/dev/loop-control absent après modprobe loop)." >&2
  exit 1
fi

free_loop=$(losetup --find 2>/dev/null || true)
if [[ -z "$free_loop" ]]; then
  echo "Loop device: FAIL (aucun /dev/loopN libre/créable)." >&2
  exit 1
fi

tmp=$(mktemp /tmp/jetson-loop-gate.XXXXXX.img)
loopdev=""
cleanup() {
  if [[ -n "$loopdev" ]]; then
    losetup -d "$loopdev" 2>/dev/null || true
  fi
  rm -f "$tmp"
}
trap cleanup EXIT INT TERM HUP
truncate -s 1M "$tmp"
loopdev=$(losetup --find --show "$tmp")
[[ -b "$loopdev" ]] || { echo "Loop device: FAIL ($loopdev n'est pas un block device)." >&2; exit 1; }
echo "Loop device: PASS ($loopdev attach/detach)"
losetup -d "$loopdev"
loopdev=""
rm -f "$tmp"
trap - EXIT INT TERM HUP
