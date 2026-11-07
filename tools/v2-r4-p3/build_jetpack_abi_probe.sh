#!/usr/bin/env bash
# Use Ubuntu's AArch64 cross toolchain and the signed NVIDIA CUDA runtime
# extracted into the JetPack 7.2.1 thin sysroot. No local PC build or flash.
set -Eeuo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 SYSROOT OUTPUT_BINARY" >&2
  exit 2
fi
sysroot=$(realpath -- "$1")
out=$(realpath -m -- "$2")
test -d "$sysroot"
command -v aarch64-linux-gnu-gcc >/dev/null

# Select the real ELF file, never a linker stub or an x86 host .so.
cuda_runtime=$(find "$sysroot" -type f -name 'libcudart.so.13*' -print -quit)
test -n "$cuda_runtime"
file "$cuda_runtime" | grep -q 'ARM aarch64'

mkdir -p "$(dirname "$out")"
aarch64-linux-gnu-gcc \
  -O2 -Wall -Wextra -Werror -fPIE -pie \
  -o "$out" \
  tools/v2-r4-p3/jetpack_abi_probe.c \
  "$cuda_runtime"

readelf -h "$out" | grep -Eq 'Machine:.*AArch64'
readelf -d "$out" | grep -q 'Shared library: \[libcudart.so.13\]'
if readelf -l "$out" | grep -q '/nix/store'; then
  echo 'Unexpected Nix ELF interpreter in JetPack ABI probe' >&2
  exit 1
fi
echo "R4_P3_UBUNTU_ARM64_CUDART13_LINK=PASS_STATIC_ONLY"
