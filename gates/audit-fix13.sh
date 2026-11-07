#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

[[ "$(cat VERSION)" =~ ^2\.0\.0-alpha4-fix1[34567]$ ]]

grep -Fq 'NATIVE_CUDA_ENABLE=${NATIVE_CUDA_ENABLE:-1}' profiles/jp721-common.env
grep -Fq 'NATIVE_CUDA_TOOLKIT_PACKAGE=${NATIVE_CUDA_TOOLKIT_PACKAGE:-cuda-toolkit-13-3}' profiles/jp721-common.env
grep -Fq 'NATIVE_CUDA_COMPAT_PACKAGE=${NATIVE_CUDA_COMPAT_PACKAGE:-cuda-compat-orin-13-3}' profiles/platforms/orin-nano-super.env

grep -Fq 'native_sdk_apply()' flash/entrypoint.sh
grep -Fq 'cuda-toolkit-13-3' flash/entrypoint.sh
grep -Fq 'printf '\''native_cuda=%s\n' flash/entrypoint.sh
grep -Fq 'require_native_sdk_current' flash/entrypoint.sh

grep -Fq -- '--native-cuda-sdk' flash/headless.sh
grep -Fq -- '--no-native-cuda-sdk' flash/headless.sh
grep -Fq 'run_ctl_persisted native-sdk apply' flash/headless.sh

grep -Fq 'rustup target add aarch64-unknown-linux-gnu' containers/cross.Dockerfile
grep -Fq 'org.haricot.fla.cross-wrapper-fingerprint' containers/cross.Dockerfile
grep -Fq 'cross_image_fingerprint()' jetsonctl
grep -Fq 'ensure_cross_image()' jetsonctl
grep -Fq 'cross_cargo()' jetsonctl
grep -Fq 'JETSON_SYSROOT=/opt/jetson-sysroot' jetsonctl
grep -Fq 'CUDA_NVCC_FLAGS="-arch=sm_${CUDA_COMPUTE_CAP}"' jetsonctl
grep -Fq 'audit-jetson-link.sh' jetsonctl
grep -Fq 'cross_deploy()' jetsonctl
grep -Fq 'target_gate()' jetsonctl
grep -Fq '"-arch=sm_${EXPECT_ARCH}"' jetsonctl

bash -n jetsonctl
bash -n flash/entrypoint.sh
bash -n flash/headless.sh
bash -n gates/audit-jetson-link.sh

VOLUME=$(mktemp -d) ./jetsonctl cross cargo --help >/dev/null

echo 'fix13 inheritance gates: PASS'
