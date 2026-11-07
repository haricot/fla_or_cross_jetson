#!/usr/bin/env bash
# Platform resolver for JetPack 7.2.1 profiles.

platform_default() { printf '%s\n' orin-nano-super; }

platform_profile_path() {
  local root=$1 name=$2
  printf '%s/profiles/platforms/%s.env\n' "$root" "$name"
}

platform_exists() {
  local root=$1 name=$2
  [[ -r "$(platform_profile_path "$root" "$name")" ]]
}

platform_names() {
  local root=$1 f
  for f in "$root"/profiles/platforms/*.env; do
    [[ -r "$f" ]] || continue
    basename "$f" .env
  done | LC_ALL=C sort
}

platform_load() {
  local root=$1 requested=${2:-}
  local chosen profile_path

  if [[ -n "$requested" ]]; then
    chosen=$requested
    profile_path=$(platform_profile_path "$root" "$chosen")
    [[ -r "$profile_path" ]] || {
      echo "platform inconnue: $chosen" >&2
      echo "platforms disponibles: $(platform_names "$root" | xargs)" >&2
      return 2
    }
    PROFILE=$profile_path
  elif [[ -n "${JETSON_PLATFORM:-}" ]]; then
    chosen=$JETSON_PLATFORM
    profile_path=$(platform_profile_path "$root" "$chosen")
    [[ -r "$profile_path" ]] || {
      echo "platform inconnue via JETSON_PLATFORM=$chosen" >&2
      return 2
    }
    PROFILE=$profile_path
  elif [[ -n "${PROFILE:-}" ]]; then
    profile_path=$PROFILE
    [[ -r "$profile_path" ]] || { echo "profil absent: $profile_path" >&2; return 1; }
  else
    chosen=$(platform_default)
    profile_path=$(platform_profile_path "$root" "$chosen")
    PROFILE=$profile_path
  fi

  set -a
  # shellcheck disable=SC1090
  source "$profile_path"
  set +a

  JETSON_PLATFORM=${PLATFORM_NAME:-${chosen:-custom}}
  export JETSON_PLATFORM PROFILE
}

platform_target_allowed() {
  local target=$1 allowed=${2:-}
  local t
  for t in ${allowed//,/ }; do
    [[ "$t" == "$target" ]] && return 0
  done
  return 1
}

platform_summary() {
  cat <<EOF_SUMMARY
platform=${PLATFORM_NAME:-${JETSON_PLATFORM:-unknown}}
family=${PLATFORM_FAMILY:-unknown}
model=${PLATFORM_MODEL:-unknown}
hardware_tested=${PLATFORM_HARDWARE_TESTED:-no}
board=${BOARD:-unknown}
soc=${SOC:-unknown}
recovery_pids=${RECOVERY_USB_PRODUCTS:-unknown}
flash_layout=${FLASH_LAYOUT:-unknown}
flash_targets=${PLATFORM_SUPPORTED_FLASH_TARGETS:-unknown}
flash_target_default=${FLASH_TARGET:-unknown}
cuda_compute_cap=${CUDA_COMPUTE_CAP:-unknown}
native_cuda_compat=${NATIVE_CUDA_COMPAT_PACKAGE:-unknown}
native_cuda_compat_dir=${NATIVE_CUDA_COMPAT_DIR:-unknown}
post_flash_usb_gate=${POST_FLASH_USB_GATE:-unknown}
EOF_SUMMARY
}
