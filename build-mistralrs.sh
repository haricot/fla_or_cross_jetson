#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VOLUME="${VOLUME:-}"
REPO="${REPO:-https://github.com/EricLBuehler/mistral.rs}"
CUDA_COMPUTE_CAP="${CUDA_COMPUTE_CAP:-87}"

usage() {
  cat <<'EOF'
Usage: ./build-mistralrs.sh [options]

Build mistral.rs for Jetson using the Docker cross-compilation environment.

Options:
  --volume PATH     Host sdk_manager directory. Can also come from VOLUME.
  --repo URL        Repository URL. Default: https://github.com/EricLBuehler/mistral.rs
  -h, --help        Show this help

Environment overrides:
  MISTRALRS_FEATURES   Force features instead of auto-detection
  MISTRALRS_PACKAGE    Cargo package to build. Default: mistralrs-server
  MISTRALRS_BIN        Expected binary name. Default depends on package
  MISTRALRS_PROFILE    Cargo profile. Default: release
  MISTRALRS_TARGET_DIR Dedicated cargo target dir for reusable builds
  MISTRALRS_FORCE_CLEAN Force a clean build in the selected target dir
  CUDA_COMPUTE_CAP     Default: 87
  CUDA_TOOLKIT_VERSION Force CUDA version (e.g. 12.6)
  CUDA_HOME_OVERRIDE   Force CUDA home path (e.g. /usr/local/cuda-12.6)
  CUDA_HOST_TOOLKIT_VERSION Force native host CUDA toolkit version when available
  CUDA_HOST_HOME_OVERRIDE   Force native host CUDA toolkit path when available
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --volume)
      VOLUME="${2:-}"
      shift 2
      ;;
    --repo)
      REPO="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Option inconnue: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "${VOLUME}" ]]; then
  echo "Définis --volume ou VOLUME." >&2
  exit 1
fi

cd "${SCRIPT_DIR}"

compose_cmd=(
  docker compose run --rm
  -e "REPO=${REPO}"
  -e "CUDA_COMPUTE_CAP=${CUDA_COMPUTE_CAP}"
)

for env_name in MISTRALRS_FEATURES MISTRALRS_PACKAGE MISTRALRS_BIN MISTRALRS_PROFILE MISTRALRS_TARGET_DIR MISTRALRS_FORCE_CLEAN CUDA_TOOLKIT_VERSION CUDA_HOME_OVERRIDE CUDA_HOST_TOOLKIT_VERSION CUDA_HOST_HOME_OVERRIDE; do
  if [[ -n "${!env_name:-}" ]]; then
    compose_cmd+=(-e "${env_name}=${!env_name}")
  fi
done

compose_cmd+=(
  sdkm
  build_mistralrs
)

env VOLUME="${VOLUME}" "${compose_cmd[@]}"
