# syntax=docker/dockerfile:1.7
ARG CUDA_VERSION_FULL=13.3.0
FROM --platform=linux/amd64 nvidia/cuda:${CUDA_VERSION_FULL}-devel-ubuntu24.04

ARG CUDA_VERSION=13.3
ARG CUDA_CROSS_PACKAGE=cuda-cross-sbsa-13-3
ARG CUDA_CROSS_REPO=https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/cross-linux-sbsa
ARG CUDA_KEYRING_VERSION=1.1-1
ARG CROSS_IMAGE_FINGERPRINT=unknown
LABEL org.haricot.fla.cross-wrapper-fingerprint="${CROSS_IMAGE_FINGERPRINT}"
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl wget git pkg-config \
    build-essential gcc-aarch64-linux-gnu g++-aarch64-linux-gnu \
    libc6-dev-arm64-cross binutils-aarch64-linux-gnu \
    clang libclang-dev cmake ninja-build patchelf \
    python3 python3-pip qemu-user-static file xz-utils zstd \
    libssl-dev protobuf-compiler perl \
    && rm -rf /var/lib/apt/lists/*

# CUDA 13.3 cross repository: use NVIDIA's documented network-repository path.
# This avoids fragile local-installer archive URLs that may disappear or move.
RUN curl -fL --retry 3 --retry-delay 2 \
      "${CUDA_CROSS_REPO}/cuda-keyring_${CUDA_KEYRING_VERSION}_all.deb" \
      -o /tmp/cuda-keyring.deb \
    && dpkg -i /tmp/cuda-keyring.deb \
    && rm -f /tmp/cuda-keyring.deb \
    && apt-get update \
    && apt-cache policy "${CUDA_CROSS_PACKAGE}" \
    && apt-get install -y --no-install-recommends "${CUDA_CROSS_PACKAGE}" \
    && rm -rf /var/lib/apt/lists/*

ARG RUST_TOOLCHAIN=stable
ENV RUSTUP_HOME=/opt/rustup \
    CARGO_HOME=/opt/cargo \
    PATH=/opt/cargo/bin:${PATH}

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --profile minimal --default-toolchain "${RUST_TOOLCHAIN}" \
    && /opt/cargo/bin/rustup target add aarch64-unknown-linux-gnu \
    && /opt/cargo/bin/rustc --version \
    && /opt/cargo/bin/cargo --version

ENV CUDA_HOME=/usr/local/cuda \
    CUDA_PATH=/usr/local/cuda \
    NVCC=/usr/local/cuda/bin/nvcc \
    NVCC_CCBIN=/usr/bin/aarch64-linux-gnu-g++ \
    CUDA_SBSA_ROOT=/usr/local/cuda/targets/sbsa-linux \
    CUDA_TARGET_ROOT=/usr/local/cuda/targets/sbsa-linux \
    CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc \
    CC_aarch64_unknown_linux_gnu=aarch64-linux-gnu-gcc \
    CXX_aarch64_unknown_linux_gnu=aarch64-linux-gnu-g++ \
    AR_aarch64_unknown_linux_gnu=aarch64-linux-gnu-ar \
    PKG_CONFIG_ALLOW_CROSS=1 \
    LIBRARY_PATH=/usr/local/cuda/targets/sbsa-linux/lib:/usr/local/cuda/targets/sbsa-linux/lib/stubs:/usr/aarch64-linux-gnu/lib \
    BINDGEN_EXTRA_CLANG_ARGS_aarch64_unknown_linux_gnu="--target=aarch64-linux-gnu -I/usr/aarch64-linux-gnu/include -I/usr/local/cuda/targets/sbsa-linux/include"

RUN test -x /usr/local/cuda/bin/nvcc \
    && test -x /usr/bin/aarch64-linux-gnu-g++ \
    && test -d /usr/local/cuda/targets/sbsa-linux/lib \
    && test -f /usr/local/cuda/targets/sbsa-linux/lib/libcudart.so \
    && test -f /usr/local/cuda/targets/sbsa-linux/lib/stubs/libcublas.so \
    && file -L /usr/local/cuda/targets/sbsa-linux/lib/libcudart.so | grep -q 'ARM aarch64' \
    && file -L /usr/local/cuda/targets/sbsa-linux/lib/stubs/libcublas.so | grep -q 'ARM aarch64' \
    && /usr/local/cuda/bin/nvcc --version \
    && aarch64-linux-gnu-g++ --version

# Fail-fast proof that the generic AArch64 image can emit device code for both
# Jetson families supported by fix14: Orin sm_87 and Thor sm_110.
RUN for arch in 87 110; do \
      printf '%s\n' \
        'extern "C" __global__ void gate(float *x) { x[threadIdx.x] += 1.0f; }' \
        'extern "C" void launch_gate(float *x) { gate<<<1,32>>>(x); }' \
        > /tmp/sm_gate.cu; \
      /usr/local/cuda/bin/nvcc -arch=sm_${arch} \
        -ccbin /usr/bin/aarch64-linux-gnu-g++ \
        -Xcompiler -fPIC -c /tmp/sm_gate.cu -o /tmp/sm_gate_${arch}.o; \
      file /tmp/sm_gate_${arch}.o | grep -q 'ARM aarch64'; \
      readelf -h /tmp/sm_gate_${arch}.o | grep -q 'Machine:.*AArch64'; \
      cuobjdump --list-elf /tmp/sm_gate_${arch}.o | grep -q "sm_${arch}"; \
    done \
    && rm -f /tmp/sm_gate.cu /tmp/sm_gate_87.o /tmp/sm_gate_110.o
