#!/usr/bin/env bash
set -Eeuo pipefail
bin=${1:?usage: audit-aarch64.sh PATH_TO_BINARY}

echo "=== TARGET ELF ==="
file "$bin"
file "$bin" | grep -Eq 'ARM aarch64|ARM64' || { echo "FAIL: binary is not AArch64" >&2; exit 1; }

echo
echo "=== ELF HEADER ==="
readelf -h "$bin" | grep -E 'Class:|Data:|Machine:'
readelf -h "$bin" | grep -Eq 'Machine:[[:space:]]+AArch64' || { echo "FAIL: ELF machine is not AArch64" >&2; exit 1; }

echo
echo "=== DYNAMIC NEEDED ==="
readelf -d "$bin" | grep NEEDED || true

echo
echo "=== RPATH/RUNPATH ==="
readelf -d "$bin" | grep -E 'RPATH|RUNPATH' || true
if readelf -d "$bin" | grep -E 'RPATH|RUNPATH' | grep -qE 'x86_64|sbsa-linux/lib/stubs'; then
  echo "FAIL: build-only CUDA path leaked into target runtime search path" >&2
  exit 1
fi

echo
echo "=== RESULT ==="
echo "PASS: AArch64 ELF"
