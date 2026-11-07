#!/usr/bin/env bash
set -Eeuo pipefail
bin=${1:?usage: audit-jetson-link.sh BINARY JETSON_SYSROOT}
sysroot=${2:?usage: audit-jetson-link.sh BINARY JETSON_SYSROOT}

[[ -r "$bin" ]] || { echo "FAIL: binary unreadable: $bin" >&2; exit 1; }
[[ -d "$sysroot/usr" && -r "$sysroot/etc/nv_tegra_release" ]] || { echo "FAIL: invalid Jetson sysroot: $sysroot" >&2; exit 1; }

echo "=== JETSON SYSROOT ==="
head -n 2 "$sysroot/etc/nv_tegra_release"
if [[ -e "$sysroot/lib/aarch64-linux-gnu/libc.so.6" ]]; then
  file -L "$sysroot/lib/aarch64-linux-gnu/libc.so.6"
  file -L "$sysroot/lib/aarch64-linux-gnu/libc.so.6" | grep -Eq 'ARM aarch64|ARM64' || {
    echo 'FAIL: sysroot libc is not AArch64' >&2; exit 1;
  }
fi

echo
echo "=== TARGET RUNTIME SEARCH ==="
readelf -d "$bin" | grep -E 'NEEDED|RPATH|RUNPATH' || true
if readelf -d "$bin" | grep -E 'RPATH|RUNPATH' | grep -qE '/usr/local/cuda/targets/sbsa-linux/lib/stubs|x86_64|/usr/aarch64-linux-gnu'; then
  echo 'FAIL: build-only path leaked into runtime RPATH/RUNPATH' >&2
  exit 1
fi

find_target_lib() {
  local soname=$1
  find \
    "$sysroot/usr/lib/aarch64-linux-gnu" \
    "$sysroot/usr/lib/aarch64-linux-gnu/nvidia" \
    "$sysroot/lib/aarch64-linux-gnu" \
    "$sysroot/usr/local/cuda-13.3" \
    -type f -o -type l 2>/dev/null \
    | awk -v s="/$soname" '$0 ~ s "$" {found=1; print; exit} END{exit !found}'
}

mapfile -t needed < <(readelf -d "$bin" | sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p')
for lib in "${needed[@]}"; do
  case "$lib" in
    libcuda.so*|libcudart.so*|libcublas.so*|libcublasLt.so*|libcudnn.so*|libnvinfer.so*|libnvrtc.so*)
      if hit=$(find_target_lib "$lib"); then
        echo "target-lib PASS: $lib -> ${hit#$sysroot}"
      else
        echo "FAIL: target GPU library not found in Jetson sysroot: $lib" >&2
        exit 1
      fi
      ;;
  esac
done

echo
echo "=== RESULT ==="
echo 'PASS: Jetson sysroot/runtime link audit'
