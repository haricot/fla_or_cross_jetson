#!/usr/bin/env bash
# Run on the actual Jetson Orin Nano Super only after JetPack 7.2.1 boot.
# No installation, root rights, network access, firmware change, or flash.
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
if [[ $(uname -m) != aarch64 ]]; then
  echo 'R4_P4_REJECT=NOT_AARCH64_HOST' >&2
  exit 2
fi
if [[ ! -r /etc/nv_tegra_release ]] || \
   ! grep -Eq '^# R39 \(release\), REVISION: 2\.1' /etc/nv_tegra_release; then
  echo 'R4_P4_REJECT=JETPACK_7_2_1_L4T_39_2_1_NOT_VERIFIED' >&2
  exit 2
fi
sha256sum --check --strict SHA256SUMS
if [[ ! -x ./jetpack-sm87-smoke || ! -s ./saxpy-sm87.cubin ]]; then
  echo 'R4_P4_REJECT=MISSING_ARTIFACT' >&2
  exit 2
fi
echo 'R4_P4_PRECHECK=PASS_AARCH64_L4T39_2_1_SHA256'
exec ./jetpack-sm87-smoke ./saxpy-sm87.cubin
