#!/usr/bin/env bash
set -Eeuo pipefail

DOWNLOAD_DIR=${DOWNLOAD_DIR:-/work/downloads}
SDKM_DOWNLOAD_DIR=${SDKM_DOWNLOAD_DIR:-/work/sdkmanager/downloads}
SDKM_CATALOG_DIR=${SDKM_CATALOG_DIR:-/work/sdkmanager/catalog}
CUSTOM_DIR=/work/custom
SECRETS_DIR=/work/secrets
STATE_DIR=/work/tmp/state
L4T_DIR=${DOWNLOAD_DIR}/Linux_for_Tegra
ROOTFS=${L4T_DIR}/rootfs
JETPACK=${JETPACK:-7.2.1}
L4T=${L4T:-39.2.1}
TARGET_UBUNTU=${TARGET_UBUNTU:-24.04}
PLATFORM_NAME=${PLATFORM_NAME:-orin-nano-super}
PLATFORM_FAMILY=${PLATFORM_FAMILY:-orin}
PLATFORM_HARDWARE_TESTED=${PLATFORM_HARDWARE_TESTED:-no}
BOARD=${BOARD:-jetson-orin-nano-devkit-super}
SOC=${SOC:-t234}
RECOVERY_USB_PRODUCTS=${RECOVERY_USB_PRODUCTS:-7523,7623}
SDKM_TARGET=${SDKM_TARGET:-JETSON_ORIN_NANO_TARGETS}
FLASH_LAYOUT=${FLASH_LAYOUT:-orin-nx-nano}
FLASH_TARGET=${FLASH_TARGET:-nvme}
EXTERNAL_DEVICE=${EXTERNAL_DEVICE:-nvme0n1p1}
FLASH_NETWORK=${FLASH_NETWORK:-usb0}
FLASH_ROOTDEV=${FLASH_ROOTDEV:-external}
FLASH_ERASE_ALL=${FLASH_ERASE_ALL:-1}
NVME_XML=${NVME_XML:-tools/kernel_flash/flash_l4t_t234_nvme.xml}
QSPI_XML=${QSPI_XML:-bootloader/generic/cfg/flash_t234_qspi.xml}
FLASH_USE_QSPI_XML=${FLASH_USE_QSPI_XML:-1}
L4T_BSP_FILE=${L4T_BSP_FILE:-Jetson_Linux_R39.2.1_aarch64.tbz2}
L4T_ROOTFS_FILE=${L4T_ROOTFS_FILE:-Tegra_Linux_Sample-Root-Filesystem_R39.2.1_aarch64.tbz2}
HOST_FLASH_IFACE_TIMEOUT=${HOST_FLASH_IFACE_TIMEOUT:-1800}
HOST_FLASH_WATCH_EXTERNAL=${HOST_FLASH_WATCH_EXTERNAL:-0}
ALLOW_STALE_IMAGES=${ALLOW_STALE_IMAGES:-0}
mkdir -p "$STATE_DIR"

need() { command -v "$1" >/dev/null || { echo "$1 est requis dans l'image flash" >&2; exit 1; }; }

require_loop_device() {
  need losetup
  if [[ ! -c /dev/loop-control ]]; then
    echo "loop device unavailable in flash runtime: /dev/loop-control absent" >&2
    echo "The flash runtime must bind-mount host /dev live." >&2
    exit 1
  fi
  local free_loop
  free_loop=$(losetup --find 2>/dev/null || true)
  if [[ -z "$free_loop" || ! -b "$free_loop" ]]; then
    echo "loop device unavailable in flash runtime: no free /dev/loopN visible" >&2
    exit 1
  fi
  echo "container loop device: PASS ($free_loop available)"
}

require_container_root() {
  local login_user
  login_user="$(id -un 2>/dev/null || true)"
  if [[ "${EUID}" -ne 0 || "${login_user}" != "root" ]]; then
    echo "Le runtime flash doit être exécuté en root réel; EUID=${EUID}, id_user=${login_user:-unknown}." >&2
    echo "NVIDIA l4t_initrd_flash/l4t_create_images_for_kernel_flash exige root." >&2
    exit 77
  fi

  # NVIDIA's l4t_create_images_for_kernel_flash.sh additionally checks
  # the USER environment variable literally (`USER == root`). Docker can
  # run uid 0 while retaining USER=nvidia from the image environment.
  export USER=root
  export LOGNAME=root
  export HOME=/root
}


ensure_container_hostname_resolution() {
  local hn
  hn="$(hostname 2>/dev/null || true)"
  [[ -n "$hn" ]] || return 0
  if ! getent hosts "$hn" >/dev/null 2>&1; then
    printf '127.0.1.1\t%s\n' "$hn" >> /etc/hosts 2>/dev/null || true
  fi
}

find_download() {
  local name=$1
  find "$DOWNLOAD_DIR" "$SDKM_DOWNLOAD_DIR" -type f -name "$name" -print -quit 2>/dev/null
}

rootfs_ready() {
  [[ -d "$ROOTFS/usr" && -r "$ROOTFS/etc/os-release" ]]
}

require_rootfs() {
  rootfs_ready || { echo "rootfs non préparé: lance ./jetsonctl flash prepare" >&2; exit 1; }
}

recovery_usb_present() {
  local pid
  for pid in ${RECOVERY_USB_PRODUCTS//,/ }; do
    lsusb -d "0955:${pid}" >/dev/null 2>&1 && return 0
  done
  return 1
}

require_recovery() {
  if recovery_usb_present; then
    return 0
  fi
  echo "Jetson non détecté en vrai Force Recovery/APX (attendu PID: ${RECOVERY_USB_PRODUCTS//,/ })." >&2
  if lsusb -d 0955: >/dev/null 2>&1; then
    echo "Périphérique NVIDIA présent, mais mauvais mode:" >&2
    lsusb -d 0955: >&2 || true
    echo "Un gadget L4T booté n'est pas le mode RCM/APX requis." >&2
  fi
  exit 78
}

invalidate_images() {
  rm -f "$STATE_DIR/generated-images.fingerprint"
}

hash_file_if_present() {
  local p=$1
  if [[ -f "$p" ]]; then sha256sum "$p" | awk '{print $1}'; else printf '%s\n' '-'; fi
}

custom_digest() {
  if [[ ! -d "$CUSTOM_DIR" ]]; then printf '%s\n' none; return; fi
  (
    cd "$CUSTOM_DIR"
    find . -type f -print0 | LC_ALL=C sort -z | while IFS= read -r -d '' f; do
      printf '%s  %s\n' "$(sha256sum "$f" | awk '{print $1}')" "$f"
    done
  ) | sha256sum | awk '{print $1}'
}

applied_custom_digest() {
  if [[ -r "$ROOTFS/etc/fla-or-cross-jetson/custom.digest" ]]; then
    sed -n '1p' "$ROOTFS/etc/fla-or-cross-jetson/custom.digest"
  else
    printf '%s\n' none
  fi
}

native_sdk_digest() {
  {
    printf 'schema=%s\n' 'alpha4-fix14-native-sdk-v2'
    printf 'platform=%s|%s\n' "${PLATFORM_NAME:-unknown}" "${PLATFORM_FAMILY:-unknown}"
    printf 'enabled=%s\n' "${NATIVE_CUDA_ENABLE:-1}"
    printf 'version=%s\n' "${NATIVE_CUDA_VERSION:-13.3}"
    printf 'repo=%s\n' "${NATIVE_CUDA_REPO:-}"
    printf 'keyring=%s\n' "${NATIVE_CUDA_KEYRING_VERSION:-1.1-1}"
    printf 'toolkit=%s\n' "${NATIVE_CUDA_TOOLKIT_PACKAGE:-cuda-toolkit-13-3}"
    printf 'compat=%s\n' "${NATIVE_CUDA_COMPAT_PACKAGE:-cuda-compat-orin-13-3}"
    printf 'root=%s\n' "${NATIVE_CUDA_ROOT:-/usr/local/cuda-13.3}"
    printf 'compat_dir=%s\n' "${NATIVE_CUDA_COMPAT_DIR:-/usr/local/cuda-13.3/compat_orin}"
  } | sha256sum | awk '{print $1}'
}

native_sdk_artifacts_ok() {
  [[ "${NATIVE_CUDA_ENABLE:-1}" == 1 ]] || return 0
  local cuda_root="${NATIVE_CUDA_ROOT:-/usr/local/cuda-13.3}"
  local compat_dir="${NATIVE_CUDA_COMPAT_DIR:-/usr/local/cuda-13.3/compat_orin}"
  [[ -x "$ROOTFS${cuda_root}/bin/nvcc" ]] || return 1
  [[ -d "$ROOTFS${cuda_root}/include" ]] || return 1
  [[ -e "$ROOTFS${cuda_root}/lib64/libcudart.so" || -e "$ROOTFS${cuda_root}/targets/sbsa-linux/lib/libcudart.so" ]] || return 1
  [[ -d "$ROOTFS${compat_dir}" ]] || return 1
  [[ -e "$ROOTFS${compat_dir}/libcuda.so.1" || -e "$ROOTFS${compat_dir}/libcuda.so" ]] || return 1
  [[ -r "$ROOTFS/etc/profile.d/fla-cuda-${NATIVE_CUDA_VERSION:-13.3}.sh" ]] || return 1
  return 0
}

applied_native_sdk_digest() {
  local marker="$ROOTFS/etc/fla-or-cross-jetson/native-cuda.digest"
  if [[ -r "$marker" ]] && native_sdk_artifacts_ok; then
    sed -n '1p' "$marker"
  elif [[ -r "$marker" ]]; then
    printf '%s\n' invalid-artifacts
  else
    printf '%s\n' none
  fi
}

native_sdk_status() {
  local want have
  want=$(native_sdk_digest); have=$(applied_native_sdk_digest)
  echo "native_cuda_enabled=${NATIVE_CUDA_ENABLE:-1}"
  echo "native_cuda_version=${NATIVE_CUDA_VERSION:-13.3}"
  echo "native_cuda_toolkit=${NATIVE_CUDA_TOOLKIT_PACKAGE:-cuda-toolkit-13-3}"
  echo "native_cuda_compat=${NATIVE_CUDA_COMPAT_PACKAGE:-cuda-compat-orin-13-3}"
  echo "native_cuda_digest=$want"
  echo "applied_native_cuda_digest=$have"
  if [[ "$want" == "$have" ]]; then echo 'native CUDA SDK: APPLIED'; else echo 'native CUDA SDK: DIRTY'; fi
}

native_sdk_apply() {
  require_container_root
  require_rootfs

  local enabled="${NATIVE_CUDA_ENABLE:-1}"
  case "$enabled" in 0|1) ;; *) echo 'NATIVE_CUDA_ENABLE doit être 0 ou 1' >&2; exit 2 ;; esac

  mkdir -p "$ROOTFS/etc/fla-or-cross-jetson"
  if [[ "$enabled" == 0 ]]; then
    native_sdk_digest > "$ROOTFS/etc/fla-or-cross-jetson/native-cuda.digest"
    invalidate_images
    echo 'Native CUDA SDK: DISABLED'
    native_sdk_status
    return 0
  fi

  need curl
  local repo="${NATIVE_CUDA_REPO:?NATIVE_CUDA_REPO absent}"
  local keyring_ver="${NATIVE_CUDA_KEYRING_VERSION:-1.1-1}"
  local toolkit="${NATIVE_CUDA_TOOLKIT_PACKAGE:-cuda-toolkit-13-3}"
  local compat="${NATIVE_CUDA_COMPAT_PACKAGE:-cuda-compat-orin-13-3}"
  local cuda_root="${NATIVE_CUDA_ROOT:-/usr/local/cuda-13.3}"
  local compat_dir="${NATIVE_CUDA_COMPAT_DIR:-/usr/local/cuda-13.3/compat_orin}"
  local keyring_rel="cuda-keyring_${keyring_ver}_all.deb"
  local keyring_host="$ROOTFS/tmp/fla-${keyring_rel}"

  mkdir -p "$ROOTFS/tmp"
  echo "Native CUDA SDK: repo=$repo toolkit=$toolkit compat=$compat"
  curl -fL --retry 3 --retry-delay 2 "$repo/$keyring_rel" -o "$keyring_host"
  chmod 0644 "$keyring_host"

  local policy="$ROOTFS/usr/sbin/policy-rc.d" policy_saved=""
  mkdir -p "$ROOTFS/usr/sbin"
  if [[ -e "$policy" ]]; then policy_saved=$(mktemp); cp -a "$policy" "$policy_saved"; fi
  printf '#!/bin/sh\nexit 101\n' > "$policy"; chmod 755 "$policy"

  local rc=0
  chroot_exec "export DEBIAN_FRONTEND=noninteractive; test \"\$(dpkg --print-architecture)\" = arm64; dpkg -i /tmp/$(basename "$keyring_host"); apt-get update; apt-cache show $(printf '%q' "$toolkit") >/dev/null; apt-cache show $(printf '%q' "$compat") >/dev/null; apt-get install -y --no-install-recommends $(printf '%q' "$toolkit") $(printf '%q' "$compat")" || rc=$?

  rm -f "$keyring_host" "$policy"
  if [[ -n "$policy_saved" ]]; then cp -a "$policy_saved" "$policy"; rm -f "$policy_saved"; fi
  (( rc == 0 )) || { echo "Installation native CUDA échouée rc=$rc" >&2; exit "$rc"; }

  # Prefer the requested toolkit in interactive/login shells while keeping the
  # original JetPack CUDA driver available. NVIDIA requires compat_orin in
  # LD_LIBRARY_PATH when using the CUDA 13.3 upgrade package on Orin.
  if [[ ! -e "$ROOTFS/usr/local/cuda" || -L "$ROOTFS/usr/local/cuda" ]]; then
    ln -sfn "$(basename "$cuda_root")" "$ROOTFS/usr/local/cuda"
  fi
  cat > "$ROOTFS/etc/profile.d/fla-cuda-${NATIVE_CUDA_VERSION:-13.3}.sh" <<EOT
export CUDA_HOME=${cuda_root}
export CUDA_PATH=${cuda_root}
case ":\${PATH}:" in *":${cuda_root}/bin:"*) ;; *) export PATH=${cuda_root}/bin:\${PATH} ;; esac
if [ -d ${compat_dir} ]; then
  case ":\${LD_LIBRARY_PATH:-}:" in *":${compat_dir}:"*) ;; *) export LD_LIBRARY_PATH=${compat_dir}:${cuda_root}/lib64\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH} ;; esac
fi
EOT
  chmod 0644 "$ROOTFS/etc/profile.d/fla-cuda-${NATIVE_CUDA_VERSION:-13.3}.sh"

  chroot_exec "dpkg-query -W -f='\${Status}\\n' $(printf '%q' "$toolkit") | grep -Fxq 'install ok installed'; dpkg-query -W -f='\${Status}\\n' $(printf '%q' "$compat") | grep -Fxq 'install ok installed'" \
    || { echo 'Native CUDA package gate: FAIL' >&2; exit 1; }
  native_sdk_artifacts_ok || { echo 'Native CUDA artifact gate: FAIL' >&2; exit 1; }
  chroot_exec "${cuda_root}/bin/nvcc --version | grep -q 'release ${NATIVE_CUDA_VERSION:-13.3}'" \
    || { echo 'Native CUDA nvcc version gate: FAIL' >&2; exit 1; }

  native_sdk_digest > "$ROOTFS/etc/fla-or-cross-jetson/native-cuda.digest"
  invalidate_images
  echo "Native CUDA SDK: PASS (${NATIVE_CUDA_VERSION:-13.3}, toolkit+compat_orin)"
  native_sdk_status
}

user_config_digest() {
  {
    # Bump this whenever offline provisioning semantics change. This forces an
    # existing fix11 rootfs to re-apply SSH/Wi-Fi provisioning under fix12.
    printf 'provisioning_schema=%s\n' 'alpha4-fix12-v1'
    printf 'user=%s\n' "${DEFAULT_USER:-}"
    printf 'hostname=%s\n' "${DEFAULT_HOSTNAME:-}"
    printf 'autologin=%s\n' "${DEFAULT_AUTOLOGIN:-0}"
    printf 'locale=%s\n' "${DEFAULT_LOCALE:-}"
    printf 'keyboard=%s\n' "${DEFAULT_KEYBOARD:-}"
    printf 'sudo_nopasswd=%s\n' "${DEFAULT_SUDO_NOPASSWD:-0}"
    printf 'ssh_key_only=%s\n' "${DEFAULT_SSH_KEY_ONLY:-0}"
    printf 'wifi_ssid=%s\n' "${DEFAULT_WIFI_SSID:-}"
    if [[ -n "${DEFAULT_PASSWORD_FILE:-}" ]]; then
      printf 'password_source_sha=%s\n' "$(hash_file_if_present "${DEFAULT_PASSWORD_FILE}")"
    else
      printf 'password_source_sha=%s\n' 'interactive'
    fi
    printf 'ssh_key_sha=%s\n' "$(hash_file_if_present "${DEFAULT_SSH_AUTHORIZED_KEY_FILE:-}")"
    if [[ -r "${DEFAULT_WIFI_PSK_FILE:-}" ]]; then
      printf 'wifi_psk_source=plain:%s\n' "$(hash_file_if_present "${DEFAULT_WIFI_PSK_FILE}")"
    elif [[ -r "${DEFAULT_WIFI_PSK_OPENSSL_FILE:-}" ]]; then
      printf 'wifi_psk_source=openssl:%s\n' "$(hash_file_if_present "${DEFAULT_WIFI_PSK_OPENSSL_FILE}")"
    else
      printf 'wifi_psk_source=-\n'
    fi
  } | sha256sum | awk '{print $1}'
}

user_artifacts_ok() {
  local user=${DEFAULT_USER:-}
  [[ -n "$user" ]] || return 0
  [[ -r "$ROOTFS/etc/passwd" ]] || return 1
  awk -F: -v u="$user" '$1==u{found=1} END{exit !found}' "$ROOTFS/etc/passwd" || return 1

  local hard="$ROOTFS/etc/ssh/sshd_config.d/00-fla-hardening.conf"
  [[ -r "$hard" ]] || return 1
  grep -Fxq 'PermitRootLogin no' "$hard" || return 1
  grep -Fxq 'PubkeyAuthentication yes' "$hard" || return 1
  if [[ "${DEFAULT_SSH_KEY_ONLY:-0}" == 1 ]]; then
    local home
    home=$(awk -F: -v u="$user" '$1==u{print $6}' "$ROOTFS/etc/passwd")
    [[ -n "$home" && -s "$ROOTFS$home/.ssh/authorized_keys" ]] || return 1
    grep -Fxq 'PasswordAuthentication no' "$hard" || return 1
    grep -Fxq 'KbdInteractiveAuthentication no' "$hard" || return 1
  fi

  if [[ -n "${DEFAULT_WIFI_SSID:-}" ]]; then
    local wifi="$ROOTFS/etc/NetworkManager/system-connections/fla-wifi.nmconnection"
    [[ -r "$wifi" ]] || return 1
    [[ "$(stat -c '%a:%u:%g' "$wifi" 2>/dev/null || true)" == '600:0:0' ]] || return 1
    grep -q '^key-mgmt=wpa-psk$' "$wifi" || return 1
    grep -Eq '^psk=[0-9a-f]{64}$' "$wifi" || return 1
    [[ "$(grep -Ec '^psk=' "$wifi")" == 1 ]] || return 1
  fi
  return 0
}

applied_user_digest() {
  if [[ -r "$ROOTFS/etc/fla-or-cross-jetson/user.digest" ]] && user_artifacts_ok; then
    sed -n '1p' "$ROOTFS/etc/fla-or-cross-jetson/user.digest"
  elif [[ -r "$ROOTFS/etc/fla-or-cross-jetson/user.digest" ]]; then
    printf '%s\n' invalid-artifacts
  else
    printf '%s\n' none
  fi
}

rootfs_fingerprint() {
  require_rootfs
  {
    printf 'profile=%s|%s|%s|%s|%s|%s\n' "$JETPACK" "$L4T" "$TARGET_UBUNTU" "${PLATFORM_NAME:-unknown}" "$BOARD" "${FLASH_LAYOUT:-unknown}"
    printf 'custom=%s\n' "$(applied_custom_digest)"
    printf 'native_cuda=%s\n' "$(applied_native_sdk_digest)"
    printf 'user=%s\n' "$(applied_user_digest)"
    hash_file_if_present "$ROOTFS/etc/os-release"
    hash_file_if_present "$ROOTFS/etc/nv_tegra_release"
    hash_file_if_present "$ROOTFS/boot/extlinux/extlinux.conf"
  } | sha256sum | awk '{print $1}'
}

images_state() {
  if [[ ! -r "$STATE_DIR/generated-images.fingerprint" ]]; then
    printf '%s\n' absent
    return
  fi
  local generated current
  generated=$(sed -n '1p' "$STATE_DIR/generated-images.fingerprint")
  current=$(rootfs_fingerprint)
  if [[ "$generated" == "$current" ]]; then printf '%s\n' fresh; else printf '%s\n' stale; fi
}

download() {
  local provider="${1:-sdkmanager}"
  if [[ "$provider" == "--provider" ]]; then
    provider=${2:-}; shift 2 || true
  else
    shift || true
  fi
  [[ "$provider" == sdkmanager ]] || { echo "entrypoint download provider supporté ici: sdkmanager" >&2; exit 2; }

  mkdir -p "$SDKM_DOWNLOAD_DIR" "$SDKM_CATALOG_DIR" /home/nvidia/.nvsdkm
  chown -R nvidia:nvidia /home/nvidia/.nvsdkm "$SDKM_DOWNLOAD_DIR" "$SDKM_CATALOG_DIR"

  local query_mode=0 show_all=0 host_mode=0
  local -a selects=() deselects=() additional_sdks=()
  while (($#)); do
    case "$1" in
      --query) query_mode=1; shift ;;
      --show-all-versions) show_all=1; shift ;;
      --host) host_mode=1; shift ;;
      --select) [[ $# -ge 2 ]] || { echo "--select demande un titre" >&2; exit 2; }; selects+=("$2"); shift 2 ;;
      --deselect) [[ $# -ge 2 ]] || { echo "--deselect demande un titre" >&2; exit 2; }; deselects+=("$2"); shift 2 ;;
      --additional-sdk) [[ $# -ge 2 ]] || { echo "--additional-sdk demande un titre/version" >&2; exit 2; }; additional_sdks+=("$2"); shift 2 ;;
      *) echo "option sdkmanager download inconnue: $1" >&2; exit 2 ;;
    esac
  done

  if (( query_mode == 1 )); then
    local stamp out
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    out="$SDKM_CATALOG_DIR/query-${stamp}.txt"
    local -a q=(sdkmanager --query non-interactive --login-type devzone --product Jetson)
    (( show_all == 1 )) && q+=(--show-all-versions)
    echo "SDK Manager query -> $out"
    set +e
    sudo -u nvidia -H env USER=nvidia LOGNAME=nvidia HOME=/home/nvidia "${q[@]}" | tee "$out"
    local rc=${PIPESTATUS[0]}
    set -e
    return "$rc"
  fi

  if ! sudo -u nvidia test -w "$SDKM_DOWNLOAD_DIR"; then
    echo "SDK Manager (uid 1000) ne peut pas écrire dans $SDKM_DOWNLOAD_DIR." >&2
    exit 1
  fi

  local -a cmd=(
    sdkmanager --cli
    --action downloadonly
    --login-type devzone
    --product Jetson
    --target-os Linux
    --version "$JETPACK"
    --target "$SDKM_TARGET"
    --download-folder "$SDKM_DOWNLOAD_DIR"
    --license accept
    --stay-logged-in true
    --collect-usage-data disable
    --exit-on-finish
  )
  (( host_mode == 1 )) && cmd+=(--host)
  local x
  for x in "${selects[@]}"; do cmd+=(--select "$x"); done
  for x in "${deselects[@]}"; do cmd+=(--deselect "$x"); done
  for x in "${additional_sdks[@]}"; do cmd+=(--additional-sdk "$x"); done

  echo "SDK Manager provider: download folder=$SDKM_DOWNLOAD_DIR"
  sudo -u nvidia -H env USER=nvidia LOGNAME=nvidia HOME=/home/nvidia "${cmd[@]}"
}

ensure_flash_prerequisites() {
  require_container_root
  require_rootfs
  cd "$L4T_DIR"
  [[ -x tools/l4t_flash_prerequisites.sh ]] || { echo "l4t_flash_prerequisites.sh absent" >&2; exit 1; }
  ./tools/l4t_flash_prerequisites.sh
}

prepare() {
  require_container_root
  local reset=0
  if [[ "${1:-}" == "--reset" ]]; then reset=1; shift; fi
  (($# == 0)) || { echo "usage: prepare [--reset]" >&2; exit 2; }

  local bsp rootfs_archive
  bsp=$(find_download "$L4T_BSP_FILE")
  rootfs_archive=$(find_download "$L4T_ROOTFS_FILE")
  [[ -n "$bsp" ]] || { echo "BSP absent: $L4T_BSP_FILE" >&2; exit 1; }
  [[ -n "$rootfs_archive" ]] || { echo "Rootfs absent: $L4T_ROOTFS_FILE" >&2; exit 1; }

  if (( reset == 1 )); then
    echo "Reset du rootfs et invalidation des images générées."
    rm -rf "$ROOTFS"
    invalidate_images
  fi

  if [[ ! -d "$L4T_DIR" ]]; then
    tar xf "$bsp" -C "$DOWNLOAD_DIR"
  fi
  mkdir -p "$ROOTFS"

  local extracted=0
  if [[ ! -e "$ROOTFS/etc/os-release" ]]; then
    tar xpf "$rootfs_archive" -C "$ROOTFS"
    extracted=1
  fi

  cd "$L4T_DIR"
  ./tools/l4t_flash_prerequisites.sh
  if (( extracted == 1 )) || [[ ! -r "$ROOTFS/etc/fla-or-cross-jetson/bsp-applied" ]]; then
    ./apply_binaries.sh
    mkdir -p "$ROOTFS/etc/fla-or-cross-jetson"
    printf '%s\n' "$L4T" > "$ROOTFS/etc/fla-or-cross-jetson/bsp-applied"
    invalidate_images
  fi
  validate_rootfs
}

validate_rootfs() {
  require_rootfs
  local version_id=""
  version_id=$(sed -n 's/^VERSION_ID="\{0,1\}\([^" ]*\)"\{0,1\}$/\1/p' "$ROOTFS/etc/os-release" | head -n1)
  [[ -z "$version_id" || "$version_id" == "$TARGET_UBUNTU" ]] || {
    echo "rootfs Ubuntu inattendu: VERSION_ID=$version_id attendu=$TARGET_UBUNTU" >&2; exit 1;
  }
  for p in usr/bin/sudo etc/sudo.conf; do
    [[ -e "$ROOTFS/$p" ]] || continue
    local owner
    owner=$(stat -c '%u:%g' "$ROOTFS/$p")
    [[ "$owner" == "0:0" ]] || { echo "rootfs invalide: $p appartient à $owner" >&2; exit 1; }
  done
  [[ -r "$ROOTFS/etc/fla-or-cross-jetson/bsp-applied" ]] || echo "warning: marqueur apply_binaries absent" >&2
  echo "rootfs: PASS (Ubuntu=${version_id:-unknown}, L4T=$L4T)"
}

run_hook() {
  local name=$1
  local hook="$CUSTOM_DIR/hooks/$name"
  if [[ -f "$hook" ]]; then
    [[ -x "$hook" ]] || { echo "hook non exécutable: $hook" >&2; exit 1; }
    echo "hook: $name"
    ROOTFS="$ROOTFS" L4T_DIR="$L4T_DIR" CUSTOM_DIR="$CUSTOM_DIR" "$hook"
  fi
}

chroot_exec() {
  local cmd=$1
  require_rootfs
  need qemu-aarch64-static
  local qemu_dst="$ROOTFS/usr/bin/qemu-aarch64-static"
  local copied_qemu=0 mounted_proc=0 mounted_sys=0 mounted_dev=0
  local resolv_backup_dir=""
  if [[ ! -e "$qemu_dst" ]]; then cp /usr/bin/qemu-aarch64-static "$qemu_dst"; copied_qemu=1; fi

  mkdir -p "$ROOTFS/proc" "$ROOTFS/sys" "$ROOTFS/dev" "$ROOTFS/etc"
  if ! mountpoint -q "$ROOTFS/proc"; then mount -t proc proc "$ROOTFS/proc"; mounted_proc=1; fi
  if ! mountpoint -q "$ROOTFS/sys"; then mount --rbind /sys "$ROOTFS/sys"; mount --make-rslave "$ROOTFS/sys"; mounted_sys=1; fi
  if ! mountpoint -q "$ROOTFS/dev"; then mount --rbind /dev "$ROOTFS/dev"; mount --make-rslave "$ROOTFS/dev"; mounted_dev=1; fi

  if [[ -e "$ROOTFS/etc/resolv.conf" || -L "$ROOTFS/etc/resolv.conf" ]]; then
    resolv_backup_dir=$(mktemp -d)
    cp -a "$ROOTFS/etc/resolv.conf" "$resolv_backup_dir/resolv.conf" 2>/dev/null || true
    rm -f "$ROOTFS/etc/resolv.conf"
  fi
  cp -L /etc/resolv.conf "$ROOTFS/etc/resolv.conf"

  local rc=0
  chroot "$ROOTFS" /usr/bin/qemu-aarch64-static /bin/bash -lc "$cmd" || rc=$?

  rm -f "$ROOTFS/etc/resolv.conf"
  if [[ -n "$resolv_backup_dir" && -e "$resolv_backup_dir/resolv.conf" || -n "$resolv_backup_dir" && -L "$resolv_backup_dir/resolv.conf" ]]; then
    cp -a "$resolv_backup_dir/resolv.conf" "$ROOTFS/etc/resolv.conf"
  fi
  [[ -n "$resolv_backup_dir" ]] && rm -rf "$resolv_backup_dir"
  (( mounted_dev == 1 )) && umount -R "$ROOTFS/dev" 2>/dev/null || true
  (( mounted_sys == 1 )) && umount -R "$ROOTFS/sys" 2>/dev/null || true
  (( mounted_proc == 1 )) && umount "$ROOTFS/proc" 2>/dev/null || true
  (( copied_qemu == 1 )) && rm -f "$qemu_dst"
  return "$rc"
}

custom_status() {
  require_rootfs
  local want have
  want=$(custom_digest); have=$(applied_custom_digest)
  echo "custom_dir=$CUSTOM_DIR"
  echo "custom_digest=$want"
  echo "applied_custom_digest=$have"
  if [[ "$want" == "$have" ]]; then echo "custom: APPLIED"; else echo "custom: DIRTY"; fi
  echo "images=$(images_state)"
}

custom_apply() {
  require_container_root
  require_rootfs
  [[ -d "$CUSTOM_DIR" ]] || { echo "custom dir absent: $CUSTOM_DIR" >&2; exit 1; }
  run_hook pre-apt.sh

  local packages=()
  if [[ -r "$CUSTOM_DIR/packages.txt" ]]; then
    mapfile -t packages < <(sed -e 's/#.*$//' -e '/^[[:space:]]*$/d' "$CUSTOM_DIR/packages.txt" | tr ' \t' '\n' | sed '/^$/d')
  fi
  if ((${#packages[@]})); then
    echo "Installation ARM64: ${packages[*]}"
    local quoted=""
    printf -v quoted ' %q' "${packages[@]}"
    mkdir -p "$ROOTFS/usr/sbin"
    local policy="$ROOTFS/usr/sbin/policy-rc.d" policy_saved=""
    if [[ -e "$policy" ]]; then policy_saved=$(mktemp); cp -a "$policy" "$policy_saved"; fi
    printf '#!/bin/sh\nexit 101\n' > "$policy"; chmod 755 "$policy"
    chroot_exec "export DEBIAN_FRONTEND=noninteractive; apt-get update; apt-get install -y --no-install-recommends${quoted}"
    rm -f "$policy"
    if [[ -n "$policy_saved" ]]; then cp -a "$policy_saved" "$policy"; rm -f "$policy_saved"; fi
  fi

  run_hook post-apt.sh

  if [[ -d "$CUSTOM_DIR/overlay" ]]; then
    echo "Application overlay -> rootfs"
    rsync -aHAX --chown=0:0 "$CUSTOM_DIR/overlay/" "$ROOTFS/"
  fi

  if [[ -r "$CUSTOM_DIR/services-enable.txt" ]]; then
    local units=()
    mapfile -t units < <(sed -e 's/#.*$//' -e '/^[[:space:]]*$/d' "$CUSTOM_DIR/services-enable.txt" | awk '{$1=$1;print}')
    if ((${#units[@]})); then
      local unit_args=""
      printf -v unit_args ' %q' "${units[@]}"
      chroot_exec "systemctl enable${unit_args}"
    fi
  fi

  run_hook final.sh
  mkdir -p "$ROOTFS/etc/fla-or-cross-jetson"
  custom_digest > "$ROOTFS/etc/fla-or-cross-jetson/custom.digest"
  invalidate_images
  validate_rootfs
  custom_status
}

write_user_state() {
  mkdir -p "$ROOTFS/etc/fla-or-cross-jetson"
  user_config_digest > "$ROOTFS/etc/fla-or-cross-jetson/user.digest"
  {
    printf 'user=%s\n' "${DEFAULT_USER:-}"
    printf 'hostname=%s\n' "${DEFAULT_HOSTNAME:-}"
    printf 'locale=%s\n' "${DEFAULT_LOCALE:-}"
    printf 'keyboard=%s\n' "${DEFAULT_KEYBOARD:-}"
    printf 'wifi_ssid=%s\n' "${DEFAULT_WIFI_SSID:-}"
  } > "$ROOTFS/etc/fla-or-cross-jetson/user.conf"
}

create_user() {
  require_container_root
  local user=${DEFAULT_USER:-}
  local passfile=${DEFAULT_PASSWORD_FILE:-}
  [[ -n "$user" ]] || { echo "DEFAULT_USER est vide: OEM configuration sera conservée. Rien à faire."; return 0; }
  validate_rootfs

  local pass="" confirm=""
  if [[ -n "$passfile" ]]; then
    [[ -r "$passfile" ]] || { echo "Fichier mot de passe illisible: $passfile" >&2; exit 1; }
    # SecretSpec's Rust resolver intentionally writes the exact secret bytes
    # with no synthetic trailing newline. Bash read(1) returns 1 at EOF when
    # the last line is not newline-terminated even though it populated `pass`;
    # do not let `set -e` treat that valid secret as a command failure.
    if ! IFS= read -r pass < "$passfile"; then
      [[ -n "$pass" ]] || { echo "Fichier mot de passe vide: $passfile" >&2; exit 1; }
    fi
  elif [[ -r /dev/tty ]]; then
    read -rsp "Mot de passe pour ${user}: " pass < /dev/tty
    printf '\n' > /dev/tty
    read -rsp "Confirme le mot de passe: " confirm < /dev/tty
    printf '\n' > /dev/tty
    [[ "$pass" == "$confirm" ]] || { unset pass confirm; echo "Les mots de passe ne correspondent pas." >&2; exit 1; }
    unset confirm
  else
    echo "Aucun TTY pour saisir le mot de passe. Utilise DEFAULT_PASSWORD_FILE pour un mode non interactif." >&2
    exit 1
  fi
  [[ -n "$pass" && "$pass" != *$'\n'* ]] || { unset pass; echo "mot de passe vide/invalide" >&2; exit 1; }

  secure_set_user_password() {
    local target_user=$1
    local target_pass=$2
    local pass_tmp="$ROOTFS/tmp/.fla-chpasswd.$$"
    mkdir -p "$ROOTFS/tmp"
    umask 077
    printf '%s:%s\n' "$target_user" "$target_pass" > "$pass_tmp"
    chmod 600 "$pass_tmp"
    if ! chroot_exec "chpasswd < /tmp/$(basename "$pass_tmp")"; then
      rm -f "$pass_tmp"
      unset target_pass
      return 1
    fi
    rm -f "$pass_tmp"
    unset target_pass
  }

  if awk -F: -v u="$user" '$1==u{found=1} END{exit !found}' "$ROOTFS/etc/passwd"; then
    echo "Utilisateur existant: $user"
    if ! secure_set_user_password "$user" "$pass"; then
      unset pass
      echo "Impossible de mettre à jour le mot de passe de $user." >&2
      exit 1
    fi
  else
    # Never pass the real user secret to NVIDIA's helper: it may echo its
    # --password argument and the argument is observable through /proc/ps.
    # Create the account with a disposable, non-secret bootstrap password,
    # suppress helper output, then replace it inside the offline rootfs.
    local bootstrap_pass='FlaBootstrapOnly-DoNotUse-9x!'
    local create_log
    create_log=$(mktemp /tmp/fla-create-user.XXXXXX)
    chmod 600 "$create_log"
    local cmd=("$L4T_DIR/tools/l4t_create_default_user.sh" --accept-license --username "$user" --password "$bootstrap_pass" --hostname "${DEFAULT_HOSTNAME:-jetson-orin}")
    [[ "${DEFAULT_AUTOLOGIN:-0}" == "1" ]] && cmd+=(--autologin)
    if ! "${cmd[@]}" >"$create_log" 2>&1; then
      echo "Échec de l4t_create_default_user.sh (sortie sensible filtrée):" >&2
      grep -viE 'password|passwd|credential|secret' "$create_log" >&2 || true
      rm -f "$create_log"
      unset pass bootstrap_pass
      exit 1
    fi
    rm -f "$create_log"
    unset bootstrap_pass

    if ! secure_set_user_password "$user" "$pass"; then
      # Defensive lock: never leave the predictable bootstrap password active
      # in an image that could later be flashed after manual intervention.
      chroot_exec "passwd -l $(printf '%q' "$user")" >/dev/null 2>&1 || true
      unset pass
      echo "Compte $user créé mais mot de passe final non appliqué; compte verrouillé." >&2
      exit 1
    fi
    echo "Utilisateur créé: $user (mot de passe appliqué sans exposition CLI/log)"
  fi
  unset pass

  chroot_exec "usermod -aG sudo $(printf '%q' "$user")"

  local home="$ROOTFS/home/$user" uid gid
  uid=$(awk -F: -v u="$user" '$1==u{print $3}' "$ROOTFS/etc/passwd")
  gid=$(awk -F: -v u="$user" '$1==u{print $4}' "$ROOTFS/etc/passwd")
  [[ -n "$uid" && -n "$gid" ]] || { echo "UID/GID introuvable pour $user" >&2; exit 1; }

  if [[ -r "${DEFAULT_SSH_AUTHORIZED_KEY_FILE:-}" ]]; then
    mkdir -p "$home/.ssh"
    cat "$DEFAULT_SSH_AUTHORIZED_KEY_FILE" > "$home/.ssh/authorized_keys"
    chmod 700 "$home/.ssh"; chmod 600 "$home/.ssh/authorized_keys"
    chown -R "$uid:$gid" "$home/.ssh"
  elif [[ "${DEFAULT_SSH_KEY_ONLY:-0}" == "1" ]]; then
    echo "DEFAULT_SSH_KEY_ONLY=1 mais aucune clé publique lisible." >&2; exit 1
  fi

  # Ubuntu may ship 50-cloud-init.conf. OpenSSH uses the first value it
  # encounters for these scalar options, so a 60-* drop-in can be too late.
  # Always forbid root SSH; key-only additionally disables password/keyboard
  # authentication. Remove the obsolete fix11 file.
  mkdir -p "$ROOTFS/etc/ssh/sshd_config.d"
  rm -f "$ROOTFS/etc/ssh/sshd_config.d/60-fla-key-only.conf"
  cat > "$ROOTFS/etc/ssh/sshd_config.d/00-fla-hardening.conf" <<'EOT'
PermitRootLogin no
PubkeyAuthentication yes
EOT
  if [[ "${DEFAULT_SSH_KEY_ONLY:-0}" == "1" ]]; then
    cat >> "$ROOTFS/etc/ssh/sshd_config.d/00-fla-hardening.conf" <<'EOT'
PasswordAuthentication no
KbdInteractiveAuthentication no
EOT
  fi
  chmod 0644 "$ROOTFS/etc/ssh/sshd_config.d/00-fla-hardening.conf"

  grep -Fxq 'PermitRootLogin no' "$ROOTFS/etc/ssh/sshd_config.d/00-fla-hardening.conf" || { echo 'SSH hardening gate: PermitRootLogin missing' >&2; exit 1; }
  grep -Fxq 'PubkeyAuthentication yes' "$ROOTFS/etc/ssh/sshd_config.d/00-fla-hardening.conf" || { echo 'SSH hardening gate: PubkeyAuthentication missing' >&2; exit 1; }
  if [[ "${DEFAULT_SSH_KEY_ONLY:-0}" == "1" ]]; then
    grep -Fxq 'PasswordAuthentication no' "$ROOTFS/etc/ssh/sshd_config.d/00-fla-hardening.conf" || { echo 'SSH hardening gate: PasswordAuthentication missing' >&2; exit 1; }
    grep -Fxq 'KbdInteractiveAuthentication no' "$ROOTFS/etc/ssh/sshd_config.d/00-fla-hardening.conf" || { echo 'SSH hardening gate: KbdInteractiveAuthentication missing' >&2; exit 1; }
    echo 'SSH hardening: PASS (root=no, key-only=yes)'
  else
    echo 'SSH hardening: PASS (root=no, key-only=no)'
  fi

  mkdir -p "$ROOTFS/etc/sudoers.d"
  if [[ "${DEFAULT_SUDO_NOPASSWD:-0}" == "1" ]]; then
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$user" > "$ROOTFS/etc/sudoers.d/90-$user-nopasswd"
    chmod 440 "$ROOTFS/etc/sudoers.d/90-$user-nopasswd"
  else
    rm -f "$ROOTFS/etc/sudoers.d/90-$user-nopasswd"
  fi

  if [[ -n "${DEFAULT_LOCALE:-}" ]]; then
    chroot_exec "locale-gen $(printf '%q' "$DEFAULT_LOCALE") >/dev/null 2>&1 || true; update-locale LANG=$(printf '%q' "$DEFAULT_LOCALE") || true"
    printf 'LANG=%s\n' "$DEFAULT_LOCALE" > "$ROOTFS/etc/default/locale"
  fi
  if [[ -n "${DEFAULT_KEYBOARD:-}" ]]; then
    cat > "$ROOTFS/etc/default/keyboard" <<EOT
XKBMODEL="pc105"
XKBLAYOUT="${DEFAULT_KEYBOARD}"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOT
  fi

  if [[ -n "${DEFAULT_WIFI_SSID:-}" ]]; then
    [[ "$DEFAULT_WIFI_SSID" != *$'\n'* && "$DEFAULT_WIFI_SSID" != *$'\r'* ]] || { echo "SSID invalide" >&2; exit 1; }
    local ssid_bytes
    ssid_bytes=$(printf '%s' "$DEFAULT_WIFI_SSID" | LC_ALL=C wc -c | tr -d '[:space:]')
    [[ "$ssid_bytes" =~ ^[0-9]+$ ]] && (( ssid_bytes >= 1 && ssid_bytes <= 32 )) \
      || { echo "SSID Wi-Fi invalide: 1..32 octets requis." >&2; exit 1; }
    local psk="" wifi_tmp="" derived_psk="" wifi_profile=""
    if [[ -r "${DEFAULT_WIFI_PSK_FILE:-}" ]]; then
      if ! IFS= read -r psk < "$DEFAULT_WIFI_PSK_FILE"; then
        [[ -n "$psk" ]] || { echo "Fichier PSK Wi-Fi vide: $DEFAULT_WIFI_PSK_FILE" >&2; exit 1; }
      fi
    elif [[ -r "${DEFAULT_WIFI_PSK_OPENSSL_FILE:-}" ]]; then
      need openssl
      [[ -r /dev/tty ]] || { echo "Le PSK Wi-Fi est chiffré mais aucun TTY n'est disponible pour la passphrase OpenSSL." >&2; exit 1; }
      local openssl_passphrase=""
      read -rsp "Passphrase OpenSSL pour le Wi-Fi: " openssl_passphrase < /dev/tty
      printf '\n' > /dev/tty
      [[ -n "$openssl_passphrase" ]] || { echo "Passphrase OpenSSL vide." >&2; exit 1; }
      wifi_tmp=$(mktemp /work/tmp/jetson_wifi_psk.XXXXXX)
      chmod 600 "$wifi_tmp"
      if ! openssl enc -d -aes-256-cbc -pbkdf2 \
          -pass fd:3 \
          -in "$DEFAULT_WIFI_PSK_OPENSSL_FILE" \
          -out "$wifi_tmp" 3<<<"$openssl_passphrase"; then
        rm -f "$wifi_tmp"
        unset openssl_passphrase
        echo "Échec du déchiffrement OpenSSL du PSK Wi-Fi." >&2
        exit 1
      fi
      unset openssl_passphrase
      if ! IFS= read -r psk < "$wifi_tmp"; then
        [[ -n "$psk" ]] || { rm -f "$wifi_tmp"; echo "PSK Wi-Fi déchiffré vide." >&2; exit 1; }
      fi
      rm -f "$wifi_tmp"
    else
      echo "PSK Wi-Fi absent. Fournis DEFAULT_WIFI_PSK_FILE ou DEFAULT_WIFI_PSK_OPENSSL_FILE." >&2
      exit 1
    fi

    # WPA-PSK accepts 8..63 byte passphrases or an already-derived 64-hex PSK.
    # Store a derived 64-hex value in the NetworkManager keyfile. Besides being
    # accepted by NetworkManager, this avoids all GLib keyfile escaping hazards
    # from arbitrary plaintext passphrase characters.
    if [[ "$psk" =~ ^[0-9A-Fa-f]{64}$ ]]; then
      derived_psk=${psk,,}
    else
      local psk_len=${#psk}
      (( psk_len >= 8 && psk_len <= 63 )) || { unset psk; echo "PSK Wi-Fi invalide: WPA-PSK attend 8..63 caractères ou 64 hex." >&2; exit 1; }
      need python3
      derived_psk=$(printf '%s' "$psk" | python3 -c '
import hashlib, sys
ssid = sys.argv[1].encode("utf-8")
psk = sys.stdin.buffer.read()
if not (1 <= len(ssid) <= 32):
    raise SystemExit("SSID must be 1..32 bytes")
if not (8 <= len(psk) <= 63):
    raise SystemExit("PSK must be 8..63 bytes")
sys.stdout.write(hashlib.pbkdf2_hmac("sha1", psk, ssid, 4096, 32).hex())
' "$DEFAULT_WIFI_SSID") || { unset psk derived_psk; echo "Impossible de dériver le PSK Wi-Fi." >&2; exit 1; }
    fi
    unset psk
    [[ "$derived_psk" =~ ^[0-9a-f]{64}$ ]] || { unset derived_psk; echo "Wi-Fi PSK derivation gate: FAIL" >&2; exit 1; }

    mkdir -p "$ROOTFS/etc/NetworkManager/system-connections"
    wifi_profile="$ROOTFS/etc/NetworkManager/system-connections/fla-wifi.nmconnection"

    # Let NetworkManager itself serialize the non-secret keyfile fields so SSID
    # escaping is correct. nmcli --offline needs no daemon and is suitable for
    # image provisioning. The secret is inserted afterwards as 64-hex only.
    if [[ -x "$ROOTFS/usr/bin/nmcli" ]]; then
      local ssid_q
      printf -v ssid_q '%q' "$DEFAULT_WIFI_SSID"
      chroot_exec "umask 077; nmcli --offline connection add type wifi con-name fla-wifi ssid ${ssid_q} connection.autoconnect yes ipv4.method auto ipv6.method auto > /etc/NetworkManager/system-connections/fla-wifi.base"
      local base="$ROOTFS/etc/NetworkManager/system-connections/fla-wifi.base"
      : > "${wifi_profile}.tmp"
      while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == '[ipv4]' ]]; then
          printf '%s\n' '[wifi-security]' >> "${wifi_profile}.tmp"
          printf '%s\n' 'key-mgmt=wpa-psk' >> "${wifi_profile}.tmp"
          printf 'psk=%s\n' "$derived_psk" >> "${wifi_profile}.tmp"
          printf '%s\n\n' 'psk-flags=0' >> "${wifi_profile}.tmp"
        fi
        printf '%s\n' "$line" >> "${wifi_profile}.tmp"
      done < "$base"
      rm -f "$base"
      mv -f "${wifi_profile}.tmp" "$wifi_profile"
    else
      # Conservative fallback. SSID is restricted to values safe for an INI
      # value; current Jetson rootfs should normally take the nmcli path above.
      [[ "$DEFAULT_WIFI_SSID" != *'#'* && "$DEFAULT_WIFI_SSID" != *';'* && "$DEFAULT_WIFI_SSID" != *$'\r'* ]] \
        || { unset derived_psk; echo "SSID nécessite nmcli --offline pour un échappement sûr." >&2; exit 1; }
      cat > "$wifi_profile" <<EOT
[connection]
id=fla-wifi
type=wifi
autoconnect=true

[wifi]
mode=infrastructure
ssid=${DEFAULT_WIFI_SSID}

[wifi-security]
key-mgmt=wpa-psk
psk=${derived_psk}
psk-flags=0

[ipv4]
method=auto

[ipv6]
method=auto
EOT
    fi
    unset derived_psk
    chmod 600 "$wifi_profile"
    chown 0:0 "$wifi_profile"

    # Secret-safe provisioning gates: never print the psk value.
    [[ "$(stat -c '%a:%u:%g' "$wifi_profile")" == '600:0:0' ]] || { echo "Wi-Fi profile permissions gate: FAIL" >&2; exit 1; }
    grep -q '^\[wifi-security\]$' "$wifi_profile" || { echo "Wi-Fi profile security gate: FAIL" >&2; exit 1; }
    grep -q '^key-mgmt=wpa-psk$' "$wifi_profile" || { echo "Wi-Fi key-mgmt gate: FAIL" >&2; exit 1; }
    grep -Eq '^psk=[0-9a-f]{64}$' "$wifi_profile" || { echo "Wi-Fi PSK storage gate: FAIL" >&2; exit 1; }
    grep -q '^psk-flags=0$' "$wifi_profile" || { echo "Wi-Fi PSK flags gate: FAIL" >&2; exit 1; }
    [[ "$(grep -Ec '^psk=' "$wifi_profile")" == 1 ]] || { echo "Wi-Fi PSK uniqueness gate: FAIL" >&2; exit 1; }
    if [[ -x "$ROOTFS/usr/bin/nmcli" ]]; then
      chroot_exec "nmcli --offline connection modify connection.autoconnect yes < /etc/NetworkManager/system-connections/fla-wifi.nmconnection >/dev/null"         || { echo "Wi-Fi NetworkManager parse gate: FAIL" >&2; exit 1; }
    fi
    echo "Wi-Fi provisioning: PASS (profile=fla-wifi, SSID=$DEFAULT_WIFI_SSID, PSK=stored-derived, mode=0600)"
  fi

  write_user_state
  invalidate_images
  echo "Utilisateur/headless préparé: $user"
  echo "user_digest=$(applied_user_digest)"
}

require_custom_current() {
  local want have
  want=$(custom_digest); have=$(applied_custom_digest)
  [[ "$want" == "$have" ]] || {
    echo "Custom rootfs non appliqué ou modifié depuis la dernière application." >&2
    echo "attendu=$want appliqué=$have" >&2
    echo "Lance: ./jetsonctl custom apply" >&2
    exit 1
  }
}

require_native_sdk_current() {
  local want have
  want=$(native_sdk_digest); have=$(applied_native_sdk_digest)
  [[ "$want" == "$have" ]] || {
    echo "Native CUDA SDK non appliqué ou configuration modifiée." >&2
    echo "attendu=$want appliqué=$have" >&2
    echo "Lance: ./jetsonctl native-sdk apply" >&2
    exit 1
  }
}

require_user_current() {
  [[ -n "${DEFAULT_USER:-}" ]] || return 0
  local want have
  want=$(user_config_digest); have=$(applied_user_digest)
  [[ "$want" == "$have" ]] || {
    echo "Configuration utilisateur/headless modifiée depuis la dernière application." >&2
    echo "Lance: ./jetsonctl flash create-user" >&2
    exit 1
  }
}

discover_iface() {
  if [[ -n "${HOST_FLASH_IFACE:-}" && -e "/sys/class/net/${HOST_FLASH_IFACE}" ]]; then echo "$HOST_FLASH_IFACE"; return 0; fi
  local p i configuration
  for p in /sys/class/net/*; do
    i=${p##*/}
    [[ "$i" == lo || "$i" == docker0 || "$i" == veth* || "$i" == br-* ]] && continue
    configuration=$(udevadm info --attribute-walk "$p" 2>/dev/null | sed -n '0,/ATTRS{configuration}=="\(.*\)"/s//\1/p' | head -n1 || true)
    if [[ "$configuration" =~ RNDIS\+L4T ]]; then echo "$i"; return 0; fi
    if [[ "$i" =~ ^enp[0-9]+s[0-9]+u[0-9]+(i[0-9]+)?$ ]]; then echo "$i"; return 0; fi
  done
  return 1
}

fix_iface() {
  local i=$1
  sysctl -w "net.ipv6.conf.${i}.disable_ipv6=0" >/dev/null 2>&1 || true
  ip link set dev "$i" up >/dev/null 2>&1 || true
  ip -6 addr show dev "$i" | grep -q 'fc00:1:1:0::1/64' || ip -6 addr add fc00:1:1:0::1/64 dev "$i" 2>/dev/null || true
  ip -6 addr show dev "$i" | grep -q 'fe80::2/64' || ip -6 addr add fe80::2/64 dev "$i" 2>/dev/null || true
}

watch_iface() {
  local deadline=$((SECONDS + HOST_FLASH_IFACE_TIMEOUT)) i announced=0
  while (( SECONDS < deadline )); do
    i=$(discover_iface || true)
    if [[ -n "$i" ]]; then
      fix_iface "$i"
      if (( announced == 0 )); then echo "Interface initrd hôte: $i"; announced=1; fi
    fi
    sleep 1
  done
}

ensure_nfs() {
  # NFS is a host service. The Smart Host Flash Guard installs the exports
  # using the same absolute Linux_for_Tegra path that is mounted here.
  # Do not manage /etc/exports from the container: its mount namespace can
  # otherwise register paths that do not exist in the host namespace.
  mkdir -p /run/nvidia_initrd_flash "$L4T_DIR/tools/kernel_flash/images" "$L4T_DIR/tools/kernel_flash/tmp"
  touch /run/nvidia_initrd_flash/docker_host_network
  need showmount

  local exports_out required missing=0
  exports_out=$(showmount -e localhost 2>/dev/null || true)
  for required in \
    "$L4T_DIR/tools/kernel_flash/tmp" \
    "$L4T_DIR/tools/kernel_flash/images" \
    "$ROOTFS"
  do
    if awk 'NR > 1 {print $1}' <<<"$exports_out" | grep -Fxq -- "$required"; then
      echo "Host NFS export: PASS ($required)"
    else
      echo "Host NFS export: FAIL ($required)" >&2
      missing=1
    fi
  done
  if (( missing != 0 )); then
    echo "Smart Host NFS Guard did not expose all canonical paths." >&2
    echo "container L4T_DIR=$L4T_DIR" >&2
    exit 112
  fi
}

flash_effective_rootdev() {
  case "${FLASH_LAYOUT}:${FLASH_TARGET}" in
    orin-nx-nano:nvme|agx-orin:nvme) printf '%s\n' external ;;
    orin-nx-nano:internal|agx-orin:internal|thor:nvme|thor:internal) printf '%s\n' internal ;;
    *) printf '%s\n' "${FLASH_ROOTDEV:-external}" ;;
  esac
}

flash_uses_external_images() {
  case "${FLASH_LAYOUT}:${FLASH_TARGET}" in
    orin-nx-nano:nvme|agx-orin:nvme) return 0 ;;
    *) return 1 ;;
  esac
}

build_generate_args() {
  FLASH_CMD_ARGS=(--no-flash)
  local rootdev
  rootdev=$(flash_effective_rootdev)
  case "${FLASH_LAYOUT}:${FLASH_TARGET}" in
    orin-nx-nano:nvme)
      FLASH_CMD_ARGS+=(--external-device "$EXTERNAL_DEVICE" -c "$NVME_XML")
      if [[ "${FLASH_USE_QSPI_XML:-1}" == 1 ]]; then
        [[ -n "${QSPI_XML:-}" ]] || { echo 'QSPI_XML requis par ce platform' >&2; return 2; }
        FLASH_CMD_ARGS+=(-p "-c $QSPI_XML")
      fi
      ;;
    agx-orin:nvme)
      FLASH_CMD_ARGS+=(--external-device "$EXTERNAL_DEVICE" -c "$NVME_XML")
      ;;
    thor:nvme|thor:internal|orin-nx-nano:internal|agx-orin:internal)
      ;;
    *)
      if [[ "$FLASH_TARGET" == nvme ]]; then
        FLASH_CMD_ARGS+=(--external-device "$EXTERNAL_DEVICE" -c "$NVME_XML")
        if [[ "${FLASH_USE_QSPI_XML:-0}" == 1 && -n "${QSPI_XML:-}" ]]; then FLASH_CMD_ARGS+=(-p "-c $QSPI_XML"); fi
      fi
      ;;
  esac
  FLASH_CMD_ARGS+=(--showlogs --network "$FLASH_NETWORK")
  [[ "$FLASH_ERASE_ALL" == 1 ]] && FLASH_CMD_ARGS+=(--erase-all)
  FLASH_CMD_ARGS+=("$BOARD" "$rootdev")
}

build_flash_only_args() {
  local rootdev
  rootdev=$(flash_effective_rootdev)
  FLASH_CMD_ARGS=(--showlogs --network "$FLASH_NETWORK" --flash-only)
  [[ "$FLASH_ERASE_ALL" == 1 ]] && FLASH_CMD_ARGS+=(--erase-all)
  FLASH_CMD_ARGS+=("$BOARD" "$rootdev")
}

print_flash_command() {
  local mode=${1:-generate} arg
  if [[ "$mode" == flash ]]; then build_flash_only_args; else build_generate_args; fi
  printf './tools/kernel_flash/l4t_initrd_flash.sh'
  for arg in "${FLASH_CMD_ARGS[@]}"; do printf ' %q' "$arg"; done
  printf '\n'
}

plan() {
  echo "=== PROFILE ==="
  echo "JetPack=$JETPACK L4T=$L4T Ubuntu=$TARGET_UBUNTU"
  echo "platform=$PLATFORM_NAME family=$PLATFORM_FAMILY tested=$PLATFORM_HARDWARE_TESTED"
  echo "board=$BOARD soc=$SOC layout=$FLASH_LAYOUT flash_target=$FLASH_TARGET rootdev=$(flash_effective_rootdev)"
  echo "downloads=$DOWNLOAD_DIR"
  echo "custom=$CUSTOM_DIR secrets=$SECRETS_DIR"
  echo
  echo "=== ROOTFS ==="
  if rootfs_ready; then
    validate_rootfs
    echo "custom wanted=$(custom_digest)"
    echo "custom applied=$(applied_custom_digest)"
    echo "native_cuda wanted=$(native_sdk_digest)"
    echo "native_cuda applied=$(applied_native_sdk_digest)"
    if [[ -n "${DEFAULT_USER:-}" ]]; then
      echo "user wanted=$(user_config_digest)"
      echo "user applied=$(applied_user_digest)"
    else
      echo "default user: OEM configuration retained"
    fi
    echo "images=$(images_state)"
  else
    echo "rootfs: absent"
  fi
  echo
  echo "=== GENERATE COMMAND ==="
  print_flash_command generate
  echo
  echo "=== FLASH-ONLY COMMAND ==="
  print_flash_command flash
  echo
  echo "NOTE: platform hardware-tested=${PLATFORM_HARDWARE_TESTED:-no}; only orin-nano-super has been end-to-end validated by this project so far."
  [[ "${PLATFORM_FAMILY:-}" == thor ]] && echo "NOTE: Thor R39.2.1 assumes NVMe >= ${PLATFORM_MIN_STORAGE_GIB:-234} GiB for the default layout."
}

generate_images() {
  require_container_root
  require_loop_device
  require_recovery
  validate_rootfs
  require_custom_current
  require_native_sdk_current
  require_user_current
  ensure_flash_prerequisites
  cd "$L4T_DIR"
  build_generate_args
  ./tools/kernel_flash/l4t_initrd_flash.sh "${FLASH_CMD_ARGS[@]}"
  rootfs_fingerprint > "$STATE_DIR/generated-images.fingerprint"
  echo "generated_images_fingerprint=$(cat "$STATE_DIR/generated-images.fingerprint")"
}

require_images() {
  [[ -e "$L4T_DIR/bootloader/flashcmd.txt" ]] || { echo "Images absentes: lance ./jetsonctl flash generate-images" >&2; exit 1; }
  [[ -e "$L4T_DIR/tools/kernel_flash/images/internal/flash.idx" ]] || { echo "flash.idx internal absent." >&2; exit 1; }
  if flash_uses_external_images; then
    [[ -e "$L4T_DIR/tools/kernel_flash/images/external/flash.idx" ]] || { echo "flash.idx external absent." >&2; exit 1; }
  fi
  local state
  state=$(images_state)
  if [[ "$state" != fresh ]]; then
    if [[ "$ALLOW_STALE_IMAGES" == 1 ]]; then
      echo "WARNING: images=$state mais ALLOW_STALE_IMAGES=1" >&2
    else
      echo "Images de flash $state par rapport au rootfs actuel; refus de --flash-only." >&2
      echo "Régénère avec: ./jetsonctl flash generate-images" >&2
      exit 1
    fi
  fi
}

flash_only() {
  require_container_root
  require_recovery
  require_images
  ensure_flash_prerequisites
  ensure_nfs
  local watcher=""
  if [[ "$HOST_FLASH_WATCH_EXTERNAL" != 1 ]]; then
    watch_iface & watcher=$!
  else
    echo "Host RNDIS watcher: external Smart Host Flash Guard"
  fi
  cd "$L4T_DIR"
  local rc=0
  build_flash_only_args
  ./tools/kernel_flash/l4t_initrd_flash.sh "${FLASH_CMD_ARGS[@]}" || rc=$?
  if [[ -n "$watcher" ]]; then
    kill "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true
  fi
  return "$rc"
}

mark_dirty() {
  invalidate_images
  echo "Images marquées invalides. Utilise ceci après toute modification manuelle de Linux_for_Tegra/rootfs."
}

doctor() {
  echo "profile: platform=$PLATFORM_NAME JetPack=$JETPACK L4T=$L4T board=$BOARD layout=$FLASH_LAYOUT target=$FLASH_TARGET"
  local doctor_id_user
  doctor_id_user="$(id -un 2>/dev/null || true)"
  if [[ "${EUID}" -eq 0 && "${doctor_id_user}" == "root" && "${USER:-}" == "root" ]]; then
    echo "container root context: PASS (EUID=0 id=root USER=root)"
  else
    echo "container root context: FAIL (EUID=${EUID} id=${doctor_id_user:-unknown} USER=${USER:-unset})"
  fi
  echo "container env: LOGNAME=${LOGNAME:-unset} HOME=${HOME:-unset}"
  command -v sdkmanager >/dev/null && echo "sdkmanager: PASS" || echo "sdkmanager: FAIL"
  command -v lsusb >/dev/null && echo "usbutils: PASS" || echo "usbutils: FAIL"
  command -v exportfs >/dev/null && echo "nfs-utils: PASS" || echo "nfs-utils: FAIL"
  command -v qemu-aarch64-static >/dev/null && echo "qemu-aarch64-static: PASS" || echo "qemu-aarch64-static: FAIL"
  if [[ -c /dev/loop-control ]] && free_loop=$(losetup --find 2>/dev/null) && [[ -b "$free_loop" ]]; then
    echo "loop device: PASS ($free_loop available)"
  else
    echo "loop device: FAIL (live /dev or host loop support missing)"
  fi
  if recovery_usb_present; then
    echo "Jetson recovery USB: PASS (APX/RCM)"
    local pid
    for pid in ${RECOVERY_USB_PRODUCTS//,/ }; do lsusb -d "0955:${pid}" 2>/dev/null || true; done
  elif lsusb -d 0955: >/dev/null 2>&1; then
    echo "Jetson recovery USB: WRONG MODE"
    lsusb -d 0955: || true
    echo "Expected APX PID(s): ${RECOVERY_USB_PRODUCTS//,/ }"
  else
    echo "Jetson recovery USB: NOT DETECTED"
  fi
  local i; i=$(discover_iface || true)
  if [[ -n "$i" ]]; then echo "initrd iface candidate: $i"; else echo "initrd iface candidate: not present yet"; fi
  if rootfs_ready; then
    validate_rootfs || true
    custom_status || true
    native_sdk_status || true
    if [[ -n "${DEFAULT_USER:-}" ]]; then
      echo "user_config_digest=$(user_config_digest)"
      echo "applied_user_digest=$(applied_user_digest)"
    fi
  else
    echo "Linux_for_Tegra/rootfs: absent"
  fi
}

ensure_container_hostname_resolution

case "${1:-shell}" in
  download) shift; download "$@" ;;
  prepare) shift; prepare "$@" ;;
  validate-rootfs) shift; validate_rootfs "$@" ;;
  custom-status) shift; custom_status "$@" ;;
  custom-apply) shift; custom_apply "$@" ;;
  native-sdk-status) shift; native_sdk_status "$@" ;;
  native-sdk-apply) shift; native_sdk_apply "$@" ;;
  mark-dirty) shift; mark_dirty "$@" ;;
  create-user) shift; create_user "$@" ;;
  plan) shift; plan "$@" ;;
  generate-images) shift; generate_images "$@" ;;
  flash-only) shift; flash_only "$@" ;;
  flash) shift; generate_images "$@"; flash_only ;;
  doctor) shift; doctor "$@" ;;
  shell) exec bash ;;
  *) exec "$@" ;;
esac
