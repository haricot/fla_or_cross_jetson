#!/usr/bin/env bash
set -Eeuo pipefail
image=${1:?usage: audit-cross-image.sh IMAGE [CUDA_COMPUTE_CAP]}
cap=${2:-87}
[[ "$cap" =~ ^[0-9]{2,3}$ ]] || { echo "invalid CUDA_COMPUTE_CAP: $cap" >&2; exit 2; }

docker run --rm -e CUDA_COMPUTE_CAP="$cap" "$image" bash -lc '
set -Eeuo pipefail
cuda_target=/usr/local/cuda/targets/sbsa-linux
cap=${CUDA_COMPUTE_CAP:?}

echo "=== CUDA CROSS TOOLCHAIN ==="
nvcc --version | tail -n 3
aarch64-linux-gnu-g++ --version | head -n 1

echo
echo "=== RUST CROSS TOOLCHAIN ==="
rustc --version
cargo --version
rustup target list --installed | grep -Fxq aarch64-unknown-linux-gnu

echo
echo "=== TARGET CUDA ABI ==="
echo "libcudart.so -> $(readlink -f "$cuda_target/lib/libcudart.so")"
file -L "$cuda_target/lib/libcudart.so"
file -L "$cuda_target/lib/stubs/libcublas.so"
file -L "$cuda_target/lib/libcudart.so" | grep -q "ARM aarch64"
file -L "$cuda_target/lib/stubs/libcublas.so" | grep -q "ARM aarch64"

echo
echo "=== SM${cap} CROSS COMPILE ==="
cat >/tmp/sm_gate.cu <<"EOF_CUDA"
extern "C" __global__ void platform_gate(float *x) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    x[i] += 1.0f;
}
extern "C" void launch_platform_gate(float *x) {
    platform_gate<<<1, 32>>>(x);
}
EOF_CUDA
nvcc "-arch=sm_${cap}" -ccbin /usr/bin/aarch64-linux-gnu-g++ \
  -Xcompiler -fPIC -c /tmp/sm_gate.cu -o /tmp/sm_gate.o
file /tmp/sm_gate.o
readelf -h /tmp/sm_gate.o | grep -E "Class:|Machine:"
file /tmp/sm_gate.o | grep -q "ARM aarch64"
readelf -h /tmp/sm_gate.o | grep -q "Machine:.*AArch64"
cuobjdump --list-elf /tmp/sm_gate.o
cuobjdump --list-elf /tmp/sm_gate.o | grep -q "sm_${cap}"

echo
echo "=== CUBLAS CROSS LINK ==="
cat >/tmp/cublas_gate.cpp <<"EOF_CPP"
#include <cublas_v2.h>
int main() {
    cublasHandle_t handle = nullptr;
    return static_cast<int>(cublasCreate(&handle));
}
EOF_CPP
aarch64-linux-gnu-g++ /tmp/cublas_gate.cpp \
  -I"$cuda_target/include" \
  -L"$cuda_target/lib" -L"$cuda_target/lib/stubs" \
  -Wl,-rpath-link,"$cuda_target/lib" \
  -Wl,-rpath-link,"$cuda_target/lib/stubs" \
  -lcublas -lcudart -o /tmp/cublas_gate
file /tmp/cublas_gate
readelf -h /tmp/cublas_gate | grep -E "Class:|Machine:"
readelf -d /tmp/cublas_gate | grep NEEDED || true
file /tmp/cublas_gate | grep -q "ARM aarch64"
readelf -h /tmp/cublas_gate | grep -q "Machine:.*AArch64"
if readelf -d /tmp/cublas_gate | grep -E "RPATH|RUNPATH" | grep -q "stubs"; then
  echo "FAIL: stub path leaked into target runtime search path" >&2
  exit 1
fi

echo
echo "=== RESULT ==="
echo "PASS: AArch64 + sm_${cap} + CUDA/cuBLAS target link"
'
