#!/usr/bin/env bash
set -Eeuo pipefail

TASK="${TASK:-shell}"
JETPACK="${JETPACK:-6.2.2}"
DOWNLOAD_DIR="/work/downloads"
TOOLCHAIN_DIR="/work/toolchains"
SOURCES_DIR="/work/sources"
HOST_VOLUME="${HOST_VOLUME:-}"
REPO="${REPO:-}"
FLASH_TARGET="${FLASH_TARGET:-internal}"
TOOLCHAIN_URL="${TOOLCHAIN_URL:-}"
RUST_TOOLCHAIN="${RUST_TOOLCHAIN:-stable}"
RUST_TARGET="${RUST_TARGET:-aarch64-unknown-linux-gnu}"
CUDA_COMPUTE_CAP="${CUDA_COMPUTE_CAP:-87}"
MISTRALRS_FEATURES="${MISTRALRS_FEATURES:-}"
NCCL_REPO_DEB="${NCCL_REPO_DEB:-}"
CUDA_TOOLKIT_VERSION="${CUDA_TOOLKIT_VERSION:-}"
CUDA_HOME_OVERRIDE="${CUDA_HOME_OVERRIDE:-}"
CUDA_HOST_TOOLKIT_VERSION="${CUDA_HOST_TOOLKIT_VERSION:-}"
CUDA_HOST_HOME_OVERRIDE="${CUDA_HOST_HOME_OVERRIDE:-}"
MISTRALRS_PACKAGE="${MISTRALRS_PACKAGE:-mistralrs-server}"
MISTRALRS_BIN="${MISTRALRS_BIN:-}"
MISTRALRS_PROFILE="${MISTRALRS_PROFILE:-release}"
MISTRALRS_TARGET_DIR="${MISTRALRS_TARGET_DIR:-}"
MISTRALRS_FORCE_CLEAN="${MISTRALRS_FORCE_CLEAN:-0}"
DEFAULT_USER="${DEFAULT_USER:-}"
DEFAULT_PASSWORD="${DEFAULT_PASSWORD:-}"
DEFAULT_PASSWORD_FILE="${DEFAULT_PASSWORD_FILE:-}"
DEFAULT_HOSTNAME="${DEFAULT_HOSTNAME:-tegra-ubuntu}"
DEFAULT_AUTOLOGIN="${DEFAULT_AUTOLOGIN:-0}"
DEFAULT_LOCALE="${DEFAULT_LOCALE:-}"
DEFAULT_KEYBOARD="${DEFAULT_KEYBOARD:-}"
DEFAULT_WIFI_SSID="${DEFAULT_WIFI_SSID:-}"
DEFAULT_WIFI_PSK_FILE="${DEFAULT_WIFI_PSK_FILE:-}"
DEFAULT_SSH_AUTHORIZED_KEY_FILE="${DEFAULT_SSH_AUTHORIZED_KEY_FILE:-}"
DEFAULT_SSH_KEY_ONLY="${DEFAULT_SSH_KEY_ONLY:-0}"
DEFAULT_SUDO_NOPASSWD="${DEFAULT_SUDO_NOPASSWD:-0}"
HOST_FLASH_IFACE="${HOST_FLASH_IFACE:-}"
HOST_FLASH_IFACE_TIMEOUT="${HOST_FLASH_IFACE_TIMEOUT:-1800}"

L4T_DIR="/work/downloads/Linux_for_Tegra"
if [[ -n "${HOST_VOLUME}" && -d "${HOST_VOLUME}/downloads" ]]; then
  L4T_DIR="${HOST_VOLUME}/downloads/Linux_for_Tegra"
fi
ROOTFS_TBZ="$(find /work/downloads -maxdepth 1 -type f -name 'Tegra_Linux_Sample-Root-Filesystem*_aarch64.tbz2' | head -n1)"
BSP_TBZ="$(find /work/downloads -maxdepth 1 -type f -name 'Jetson_Linux_R*.tbz2' | head -n1)"

download() {
  sdkmanager \
    --cli \
    --action downloadonly \
    --login-type devzone \
    --product Jetson \
    --target-os Linux \
    --version "${JETPACK}" \
    --target JETSON_ORIN_NANO_TARGETS \
    --download-folder "${DOWNLOAD_DIR}" \
    --licenses accept \
    --stay-logged-in true \
    --collect-usage-data disable \
    --exit-on-finish
}

download_interactive() {
  sdkmanager \
    --cli \
    --action downloadonly \
    --download-folder "${DOWNLOAD_DIR}" \
    --license accept \
    --collect-usage-data disable \
    --exit-on-finish
}

ensure_l4t_rootfs() {
  if [[ ! -d "${L4T_DIR}/rootfs/usr" ]]; then
    echo "Rootfs Jetson absent dans ${L4T_DIR}/rootfs. Lance d'abord TASK=prepare." >&2
    exit 1
  fi

  validate_rootfs_ownership
}

validate_rootfs_ownership() {
  local sudo_bin="${L4T_DIR}/rootfs/usr/bin/sudo"
  local sudo_conf="${L4T_DIR}/rootfs/etc/sudo.conf"
  local owner=""

  if [[ -e "${sudo_bin}" ]]; then
    owner="$(stat -c '%u:%g' "${sudo_bin}" 2>/dev/null || true)"
    if [[ "${owner}" != "0:0" ]]; then
      echo "Rootfs corrompue: ${sudo_bin} appartient à ${owner}, attendu 0:0." >&2
      echo "Cause probable: ancien chown récursif sur /work/downloads." >&2
      echo "Supprime ${L4T_DIR} puis relance TASK=prepare avant de reflasher." >&2
      exit 1
    fi
  fi

  if [[ -e "${sudo_conf}" ]]; then
    owner="$(stat -c '%u:%g' "${sudo_conf}" 2>/dev/null || true)"
    if [[ "${owner}" != "0:0" ]]; then
      echo "Rootfs corrompue: ${sudo_conf} appartient à ${owner}, attendu 0:0." >&2
      echo "Cause probable: ancien chown récursif sur /work/downloads." >&2
      echo "Supprime ${L4T_DIR} puis relance TASK=prepare avant de reflasher." >&2
      exit 1
    fi
  fi
}

extract_outer_repo() {
  local repo_deb="$1"
  local cache_dir="/work/tmp/local-repos/$(basename "${repo_deb%.deb}")"

  if [[ ! -d "${cache_dir}" ]]; then
    mkdir -p "${cache_dir}"
    dpkg-deb -x "${repo_deb}" "${cache_dir}"
  fi

  find "${cache_dir}" -type f -name Packages -printf '%h\n' | head -n1
}

extract_matching_repo_debs() {
  local repo_deb="$1"
  local destination="$2"
  shift 2

  local repo_dir=""
  local matched=0
  local pattern=""
  local inner=""

  repo_dir="$(extract_outer_repo "${repo_deb}")"
  if [[ -z "${repo_dir}" ]]; then
    echo "Impossible d'extraire le dépôt local: ${repo_deb}" >&2
    return 1
  fi

  for pattern in "$@"; do
    while IFS= read -r inner; do
      sudo dpkg-deb -x "${inner}" "${destination}"
      matched=1
    done < <(find "${repo_dir}" -maxdepth 1 -type f -name "${pattern}" | sort -u)
  done

  ((matched == 1))
}

latest_cuda_home() {
  local sysroot="$1"

  [[ -d "${sysroot}/usr/local" ]] || return 0
  find "${sysroot}/usr/local" -maxdepth 1 -mindepth 1 -type d -name 'cuda-*' | sort | tail -n1
}

host_cuda_home() {
  find /usr/local -maxdepth 1 -mindepth 1 -type d -name 'cuda-*' | sort | tail -n1
}

ensure_cuda_symlink() {
  local sysroot="$1"
  local latest=""

  if [[ -n "${CUDA_TOOLKIT_VERSION}" && -d "${sysroot}/usr/local/cuda-${CUDA_TOOLKIT_VERSION}" ]]; then
    sudo ln -sfn "cuda-${CUDA_TOOLKIT_VERSION}" "${sysroot}/usr/local/cuda"
    return 0
  fi

  latest="$(latest_cuda_home "${sysroot}")"
  if [[ -n "${latest}" ]]; then
    sudo ln -sfn "$(basename "${latest}")" "${sysroot}/usr/local/cuda"
  fi
}

pick_cuda_home() {
  local sysroot="$1"

  if [[ -n "${CUDA_HOME_OVERRIDE}" && -d "${CUDA_HOME_OVERRIDE}" ]]; then
    printf '%s\n' "${CUDA_HOME_OVERRIDE}"
    return 0
  fi

  if [[ -n "${CUDA_TOOLKIT_VERSION}" ]]; then
    if [[ -d "${sysroot}/usr/local/cuda-${CUDA_TOOLKIT_VERSION}" ]]; then
      printf '%s\n' "${sysroot}/usr/local/cuda-${CUDA_TOOLKIT_VERSION}"
      return 0
    fi
    if [[ -d "/usr/local/cuda-${CUDA_TOOLKIT_VERSION}" ]]; then
      printf '%s\n' "/usr/local/cuda-${CUDA_TOOLKIT_VERSION}"
      return 0
    fi
  fi

  latest_cuda_home "${sysroot}"
}

pick_host_cuda_home() {
  local requested_version="${CUDA_HOST_TOOLKIT_VERSION:-${CUDA_TOOLKIT_VERSION:-}}"

  if [[ -n "${CUDA_HOST_HOME_OVERRIDE}" && -d "${CUDA_HOST_HOME_OVERRIDE}" ]]; then
    printf '%s\n' "${CUDA_HOST_HOME_OVERRIDE}"
    return 0
  fi

  if [[ -n "${requested_version}" && -d "/usr/local/cuda-${requested_version}" ]]; then
    printf '%s\n' "/usr/local/cuda-${requested_version}"
    return 0
  fi

  host_cuda_home
}

sync_host_cuda_into_sysroot() {
  local sysroot="$1"
  local host_cuda="$2"
  local target_dir="${sysroot}/usr/local/$(basename "${host_cuda}")"

  sudo mkdir -p "${sysroot}/usr/local"
  if [[ ! -d "${target_dir}" ]]; then
    sudo cp -a "${host_cuda}" "${sysroot}/usr/local/"
  fi
}

ensure_cuda_ldconfig() {
  local sysroot="$1"
  local cuda_home=""
  local cuda_lib=""

  cuda_home="$(pick_cuda_home "${sysroot}")"
  if [[ -z "${cuda_home}" ]]; then
    return 0
  fi

  cuda_lib="${cuda_home}/targets/aarch64-linux/lib"
  if [[ ! -d "${cuda_lib}" ]]; then
    return 0
  fi

  sudo tee "${sysroot}/etc/ld.so.conf.d/cuda-local.conf" >/dev/null <<EOF
${cuda_lib}
EOF
}

ensure_cudnn_linker_symlinks() {
  local sysroot="$1"
  local libdir="${sysroot}/usr/lib/aarch64-linux-gnu"
  local base=""

  [[ -d "${libdir}" ]] || return 0

  for base in \
    libcudnn \
    libcudnn_adv \
    libcudnn_cnn \
    libcudnn_graph \
    libcudnn_ops \
    libcudnn_heuristic \
    libcudnn_engines_precompiled \
    libcudnn_engines_runtime_compiled; do
    if [[ ! -e "${libdir}/${base}.so" && -e "${libdir}/${base}.so.9" ]]; then
      sudo ln -sfn "${base}.so.9" "${libdir}/${base}.so"
    fi
  done
}

sync_host_nccl_into_sysroot() {
  local sysroot="$1"
  local copied=0

  sudo mkdir -p "${sysroot}/usr/include" "${sysroot}/usr/lib/aarch64-linux-gnu" "${sysroot}/usr/lib/aarch64-linux-gnu/pkgconfig"

  if [[ -f /usr/include/nccl.h ]]; then
    sudo cp -a /usr/include/nccl.h "${sysroot}/usr/include/"
    copied=1
  fi

  while IFS= read -r src; do
    sudo cp -a "${src}" "${sysroot}/usr/lib/aarch64-linux-gnu/"
    copied=1
  done < <(find /usr/lib/aarch64-linux-gnu -maxdepth 1 \( -type f -o -type l \) \( -name 'libnccl.so*' -o -name 'libnccl_static.a' \) 2>/dev/null | sort)

  while IFS= read -r src; do
    sudo cp -a "${src}" "${sysroot}/usr/lib/aarch64-linux-gnu/pkgconfig/"
    copied=1
  done < <(find /usr/lib/aarch64-linux-gnu/pkgconfig -maxdepth 1 -type f -name 'nccl*.pc' 2>/dev/null | sort)

  ((copied == 1))
}

prepare_cuda_sysroot() {
  local sysroot="$1"
  local cuda_repo_deb=""
  local cudnn_repo_deb=""
  local nccl_repo_deb=""
  local cuda_home=""
  local host_cuda=""

  ensure_l4t_rootfs

  cuda_repo_deb="$(find /work/downloads -maxdepth 1 -type f -name 'l4t-cuda-tegra-repo-ubuntu2204-*-local*.deb' | sort | tail -n1)"
  cudnn_repo_deb="$(find /work/downloads -maxdepth 1 -type f -name 'cudnn-local-tegra-repo-ubuntu2204-*.deb' | sort | tail -n1)"
  nccl_repo_deb="${NCCL_REPO_DEB:-$(find /work/downloads -maxdepth 1 -type f -iname '*nccl*repo*.deb' | sort | tail -n1)}"
  cuda_home="$(pick_cuda_home "${sysroot}")"
  host_cuda="$(host_cuda_home)"

  if [[ -n "${host_cuda}" && "${sysroot}" != "${L4T_DIR}/rootfs" && -z "${CUDA_TOOLKIT_VERSION}" && -z "${CUDA_HOME_OVERRIDE}" ]]; then
    sync_host_cuda_into_sysroot "${sysroot}" "${host_cuda}"
    cuda_home="$(pick_cuda_home "${sysroot}")"
  fi

  if ! find "${sysroot}/usr" -type f -name 'libnccl.so*' | grep -q .; then
    sync_host_nccl_into_sysroot "${sysroot}" || true
  fi

  if [[ -n "${cuda_repo_deb}" ]]; then
    extract_matching_repo_debs "${cuda_repo_deb}" "${sysroot}" \
      'cuda-*-12-*_arm64.deb' \
      'cuda-*-12-*_all.deb' \
      'cuda-toolkit*-config-common*_all.deb' \
      'cuda-cudart-12-*_arm64.deb' \
      'cuda-cudart-dev-12-*_arm64.deb' \
      'cuda-nvrtc-12-*_arm64.deb' \
      'cuda-nvrtc-dev-12-*_arm64.deb' \
      'cuda-driver-dev-12-*_arm64.deb' \
      'libcublas-12-*_arm64.deb' \
      'libcublas-dev-12-*_arm64.deb' \
      'libcurand-12-*_arm64.deb' \
      'libcurand-dev-12-*_arm64.deb' \
      'libcusparse-12-*_arm64.deb' \
      'libcusparse-dev-12-*_arm64.deb' \
      'cuda-compat-12-*_arm64.deb' || true
    cuda_home="$(pick_cuda_home "${sysroot}")"
  elif [[ -z "${cuda_home}" ]]; then
    echo "Dépôt CUDA Jetson local introuvable dans /work/downloads." >&2
  fi

  if [[ -n "${cudnn_repo_deb}" ]] && {
    ! find "${sysroot}/usr" \( -type f -o -type l \) -name 'libcudnn.so' | grep -q . ||
    ! find "${sysroot}/usr" \( -type f -o -type l \) -name 'cudnn*.h' | grep -q .;
  }; then
    extract_matching_repo_debs "${cudnn_repo_deb}" "${sysroot}" \
      'libcudnn*_arm64.deb' \
      'cudnn*_arm64.deb' \
      'cudnn*_all.deb' || true
  elif ! find "${sysroot}/usr" \( -type f -o -type l \) -name 'libcudnn.so*' | grep -q .; then
    echo "Dépôt cuDNN Jetson local introuvable dans /work/downloads." >&2
  fi

  if ! find "${sysroot}/usr" \( -type f -o -type l \) -name 'libnccl.so*' | grep -q . && [[ -n "${nccl_repo_deb}" ]]; then
    extract_matching_repo_debs "${nccl_repo_deb}" "${sysroot}" \
      'libnccl*_arm64.deb' \
      'libnccl*_all.deb' \
      'nccl*_arm64.deb' \
      'nccl*_all.deb' || true
  elif ! find "${sysroot}/usr" \( -type f -o -type l \) -name 'libnccl.so*' | grep -q .; then
    echo "NCCL non trouvé dans les téléchargements locaux. Le support nccl restera désactivé tant qu'un dépôt NCCL ne sera pas fourni." >&2
  fi

  ensure_cudnn_linker_symlinks "${sysroot}"
  ensure_cuda_symlink "${sysroot}"
  ensure_cuda_ldconfig "${sysroot}"
  if [[ "${sysroot}" == "${L4T_DIR}/rootfs" ]]; then
    run_rootfs_chroot /sbin/ldconfig || true
  fi
}

write_qemu_nvcc_wrapper() {
  local sysroot="$1"
  local cuda_home="$2"
  local wrapper="/work/tmp/qemu-nvcc"
  local nvcc_binary="${cuda_home}/bin/nvcc"
  local nvcc_file_info=""

  nvcc_file_info="$(file -Lb "${nvcc_binary}" 2>/dev/null || true)"

  if [[ "${nvcc_file_info}" == *"x86-64"* ]]; then
    cat >"${wrapper}" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
exec "${nvcc_binary}" "\$@"
EOF
  else
    cat >"${wrapper}" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
export LD_LIBRARY_PATH="${cuda_home}/targets/aarch64-linux/lib:${sysroot}/usr/lib/aarch64-linux-gnu:${sysroot}/usr/lib/aarch64-linux-gnu/nvidia:${sysroot}/lib/aarch64-linux-gnu:\${LD_LIBRARY_PATH:-}"
exec qemu-aarch64-static -L "${sysroot}" "${nvcc_binary}" "\$@"
EOF
  fi

  chmod +x "${wrapper}"
  printf '%s\n' "${wrapper}"
}

detect_mistralrs_features() {
  local sysroot="$1"

  if [[ -n "${MISTRALRS_FEATURES}" ]]; then
    printf '%s\n' "${MISTRALRS_FEATURES}"
    return 0
  fi

  local features=()
  features+=(cuda flash-attn)

  if find "${sysroot}/usr" -type f -name 'libcudnn.so*' | grep -q .; then
    features+=(cudnn)
  fi

  if find "${sysroot}/usr" -type f -name 'libnccl.so*' | grep -q .; then
    features+=(nccl)
  fi

  printf '%s\n' "${features[*]}"
}

configure_rust_cross_env() {
  local target_rootfs="$1"
  local cuda_home="${2:-}"
  local compiler_sysroot="${3:-}"
  local build_nvcc_home="${4:-}"
  local nvcc_wrapper=""
  local nvcc_home=""
  local build_cuda_include=""
  local build_cuda_lib=""
  local cuda_target_root=""
  local cuda_target_include=""
  local cuda_target_lib=""
  local cuda_target_stub=""
  local rustflags=()
  local bindgen_args=()
  local sysroot_lib_dirs=()
  local include_dirs=()
  local target_cflags=""
  local target_cxxflags=""
  local target_cppflags=""
  local target_ldflags=""
  local target_pkgconfig_libdir=""

  if [[ -z "${compiler_sysroot}" ]]; then
    compiler_sysroot="$("${CC}" -print-sysroot)"
  fi

  if [[ -z "${compiler_sysroot}" || ! -d "${compiler_sysroot}/usr/include" ]]; then
    echo "Sysroot toolchain introuvable pour ${CC}." >&2
    exit 1
  fi

  sysroot_lib_dirs+=("${compiler_sysroot}/usr/lib")
  sysroot_lib_dirs+=("${compiler_sysroot}/lib")
  sysroot_lib_dirs+=("${compiler_sysroot}/usr/lib/aarch64-linux-gnu")
  sysroot_lib_dirs+=("${compiler_sysroot}/lib/aarch64-linux-gnu")
  sysroot_lib_dirs+=("${compiler_sysroot}/usr/lib/aarch64-linux-gnu/nvidia")
  sysroot_lib_dirs+=("${target_rootfs}/usr/lib/aarch64-linux-gnu/nvidia")

  include_dirs+=("${compiler_sysroot}/usr/include")
  include_dirs+=("${compiler_sysroot}/usr/include/aarch64-linux-gnu")
  include_dirs+=("${target_rootfs}/usr/include")
  include_dirs+=("${target_rootfs}/usr/include/aarch64-linux-gnu")

  export PATH="${HOME}/.cargo/bin:${PATH}:${TOOLCHAIN_ROOT}/bin"

  if ! rustup show active-toolchain | grep -q "^${RUST_TOOLCHAIN}"; then
    rustup default "${RUST_TOOLCHAIN}" >/dev/null
  fi

  if ! rustup target list --installed | grep -qx "${RUST_TARGET}"; then
    rustup target add "${RUST_TARGET}" >/dev/null
  fi

  export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER="${CC}"
  export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_RUNNER="qemu-aarch64-static -L ${target_rootfs}"
  export PKG_CONFIG_ALLOW_CROSS=1
  target_pkgconfig_libdir="${compiler_sysroot}/usr/lib/aarch64-linux-gnu/pkgconfig:${compiler_sysroot}/usr/lib/pkgconfig:${compiler_sysroot}/usr/share/pkgconfig:${target_rootfs}/usr/lib/aarch64-linux-gnu/pkgconfig:${target_rootfs}/usr/lib/pkgconfig:${target_rootfs}/usr/share/pkgconfig"

  target_cflags="--sysroot=${compiler_sysroot} -I${compiler_sysroot}/usr/include -I${compiler_sysroot}/usr/include/aarch64-linux-gnu -I${target_rootfs}/usr/include -I${target_rootfs}/usr/include/aarch64-linux-gnu"
  target_cxxflags="${target_cflags}"
  target_cppflags="${target_cflags}"
  target_ldflags="--sysroot=${compiler_sysroot} -L${compiler_sysroot}/usr/lib -L${compiler_sysroot}/lib -L${compiler_sysroot}/usr/lib/aarch64-linux-gnu -L${compiler_sysroot}/lib/aarch64-linux-gnu -L${compiler_sysroot}/usr/lib/aarch64-linux-gnu/nvidia -L${target_rootfs}/usr/lib/aarch64-linux-gnu/nvidia -Wl,-rpath-link,${compiler_sysroot}/usr/lib -Wl,-rpath-link,${compiler_sysroot}/lib -Wl,-rpath-link,${compiler_sysroot}/usr/lib/aarch64-linux-gnu -Wl,-rpath-link,${compiler_sysroot}/lib/aarch64-linux-gnu -Wl,-rpath-link,${compiler_sysroot}/usr/lib/aarch64-linux-gnu/nvidia -Wl,-rpath-link,${target_rootfs}/usr/lib/aarch64-linux-gnu/nvidia"

  export PKG_CONFIG_SYSROOT_DIR_aarch64_unknown_linux_gnu="${compiler_sysroot}"
  export PKG_CONFIG_LIBDIR_aarch64_unknown_linux_gnu="${target_pkgconfig_libdir}"
  export PKG_CONFIG_PATH_aarch64_unknown_linux_gnu="${target_pkgconfig_libdir}"
  export CC_aarch64_unknown_linux_gnu="${CC}"
  export CXX_aarch64_unknown_linux_gnu="${CXX}"
  export AR_aarch64_unknown_linux_gnu="${AR}"
  export CFLAGS_aarch64_unknown_linux_gnu="${target_cflags}"
  export CXXFLAGS_aarch64_unknown_linux_gnu="${target_cxxflags}"
  export CPPFLAGS_aarch64_unknown_linux_gnu="${target_cppflags}"
  export LDFLAGS_aarch64_unknown_linux_gnu="${target_ldflags}"
  export CUDA_COMPUTE_CAP="${CUDA_COMPUTE_CAP}"

  rustflags+=("-C" "link-arg=--sysroot=${compiler_sysroot}")
  for dir in "${sysroot_lib_dirs[@]}"; do
    rustflags+=("-C" "link-arg=-L${dir}")
    rustflags+=("-C" "link-arg=-Wl,-rpath-link,${dir}")
  done

  bindgen_args+=("--sysroot=${compiler_sysroot}")
  for dir in "${include_dirs[@]}"; do
    bindgen_args+=("-I${dir}")
  done

  if [[ -n "${cuda_home}" ]]; then
    if [[ -z "${build_nvcc_home}" ]]; then
      build_nvcc_home="${cuda_home}"
    fi

    build_cuda_include="${build_nvcc_home}/include"
    build_cuda_lib="${build_nvcc_home}/lib64"
    cuda_target_root="${cuda_home}/targets/aarch64-linux"
    cuda_target_include="${cuda_home}/include"
    cuda_target_lib="${cuda_target_root}/lib"
    cuda_target_stub="${cuda_target_lib}/stubs"

    if [[ ! -e "${build_cuda_include}/cuda_runtime.h" && -d "${build_nvcc_home}/targets/x86_64-linux/include" ]]; then
      build_cuda_include="${build_nvcc_home}/targets/x86_64-linux/include"
    fi

    if [[ ! -d "${build_cuda_lib}" && -d "${build_nvcc_home}/targets/x86_64-linux/lib" ]]; then
      build_cuda_lib="${build_nvcc_home}/targets/x86_64-linux/lib"
    fi

    if [[ -d "${cuda_target_root}/include" ]]; then
      cuda_target_include="${cuda_target_root}/include"
    fi

    export CUDA_HOME="${cuda_home}"
    export CUDA_PATH="${cuda_home}"
    export CUDA_ROOT="${cuda_target_root}"
    export CUDA_TOOLKIT_ROOT_DIR="${cuda_target_root}"
    export CUDA_BUILD_HOME="${build_nvcc_home}"
    export CUDA_BUILD_INCLUDE_DIR="${build_cuda_include}"
    export CUDA_BUILD_LIB_DIR="${build_cuda_lib}"
    export CUDNN_LIB="${target_rootfs}/usr/lib/aarch64-linux-gnu"
    export CUDAHOSTCXX="${CXX}"
    export NVCC="${build_nvcc_home}/bin/nvcc"
    export NVCC_CCBIN="${CXX}"
    if [[ -e "${build_cuda_include}/cuda_runtime.h" ]]; then
      export CUDA_INCLUDE_DIR="${build_cuda_include}"
      export NVCC_PREPEND_FLAGS="-I${build_cuda_include}${NVCC_PREPEND_FLAGS:+ ${NVCC_PREPEND_FLAGS}}"
    fi
    export CFLAGS_aarch64_unknown_linux_gnu="-I${cuda_home}/include -I${cuda_target_include} ${CFLAGS_aarch64_unknown_linux_gnu}"
    export CXXFLAGS_aarch64_unknown_linux_gnu="-I${cuda_home}/include -I${cuda_target_include} ${CXXFLAGS_aarch64_unknown_linux_gnu}"
    export CPPFLAGS_aarch64_unknown_linux_gnu="-I${cuda_home}/include -I${cuda_target_include} ${CPPFLAGS_aarch64_unknown_linux_gnu}"
    if [[ -d "${cuda_target_lib}" ]]; then
      export LDFLAGS_aarch64_unknown_linux_gnu="-L${cuda_target_lib} ${LDFLAGS_aarch64_unknown_linux_gnu}"
      rustflags+=("-C" "link-arg=-L${cuda_target_lib}")
      rustflags+=("-C" "link-arg=-Wl,-rpath-link,${cuda_target_lib}")
    fi
    if [[ -d "${cuda_target_stub}" ]]; then
      export LDFLAGS_aarch64_unknown_linux_gnu="-L${cuda_target_stub} ${LDFLAGS_aarch64_unknown_linux_gnu}"
      rustflags+=("-C" "link-arg=-L${cuda_target_stub}")
    fi
    bindgen_args+=("-I${cuda_home}/include")
    if [[ "${cuda_target_include}" != "${cuda_home}/include" ]]; then
      bindgen_args+=("-I${cuda_target_include}")
    fi

    nvcc_home="${build_nvcc_home}"
    if [[ -x "${nvcc_home}/bin/nvcc" ]]; then
      nvcc_wrapper="$(write_qemu_nvcc_wrapper "${target_rootfs}" "${nvcc_home}")"
      export CUDACXX="${nvcc_wrapper}"
    fi
  fi

  export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_RUSTFLAGS="${rustflags[*]} ${CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_RUSTFLAGS:-}"
  export BINDGEN_EXTRA_CLANG_ARGS_aarch64_unknown_linux_gnu="${bindgen_args[*]}"
}

prepare() {
  cd /work/downloads
  if [[ -z "${BSP_TBZ}" ]]; then
    echo "BSP introuvable dans /work/downloads" >&2
    exit 1
  fi
  if [[ ! -d "${L4T_DIR}" ]]; then
    tar xf "${BSP_TBZ}"
  fi
  if [[ -z "${ROOTFS_TBZ}" ]]; then
    echo "Sample RootFS introuvable dans /work/downloads" >&2
    exit 1
  fi
  cd "${L4T_DIR}"
  sudo tar -xpf "${ROOTFS_TBZ}" -C rootfs
  sudo rm -rf rootfs/dev
  sudo mkdir -p rootfs/dev
  sudo env PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" ./apply_binaries.sh
  sudo sed -i '/ssh-keygen -t dsa/d' tools/ota_tools/version_upgrade/ota_make_recovery_img_dtb.sh || true
}

rootfs_ready() {
  [[ -d "${L4T_DIR}/rootfs/usr" ]]
}

default_user_exists_in_rootfs() {
  local rootfs="${L4T_DIR}/rootfs"

  [[ -n "${DEFAULT_USER}" ]] || return 1
  [[ -f "${rootfs}/etc/passwd" ]] || return 1

  awk -F: -v user="${DEFAULT_USER}" '$1 == user {found=1} END {exit(found ? 0 : 1)}' "${rootfs}/etc/passwd"
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

file_readable_maybe_sudo() {
  local path="$1"

  [[ -r "${path}" ]] && return 0
  sudo test -r "${path}"
}

read_first_line_maybe_sudo() {
  local path="$1"
  local line=""

  if [[ -r "${path}" ]]; then
    IFS= read -r line < "${path}" || true
  else
    line="$(sudo sed -n '1p' "${path}" 2>/dev/null || true)"
  fi

  printf '%s\n' "${line%$'\r'}"
}

stream_file_maybe_sudo() {
  local path="$1"

  if [[ -r "${path}" ]]; then
    cat "${path}"
  else
    sudo cat "${path}"
  fi
}

escape_extended_regex() {
  printf '%s\n' "$1" | sed -e 's/[][(){}.^$*+?|\/]/\\&/g'
}

get_udev_attr() {
  local path="$1"
  local attr="$2"

  if ! have_cmd udevadm; then
    return 1
  fi

  udevadm info --attribute-walk "$path" 2>/dev/null \
    | sed -n "0,/^[ ]*ATTRS{$attr}==\"\\(.*\\)\"$/s//\\1/p" \
    | xargs
}

discover_host_flash_iface() {
  local path=""
  local iface=""
  local configuration=""

  if [[ -n "${HOST_FLASH_IFACE}" && -e "/sys/class/net/${HOST_FLASH_IFACE}" ]]; then
    printf '%s\n' "${HOST_FLASH_IFACE}"
    return 0
  fi

  for path in /sys/class/net/*; do
    iface="${path##*/}"
    [[ "${iface}" == "lo" ]] && continue
    [[ "${iface}" == "docker0" ]] && continue
    [[ "${iface}" == veth* ]] && continue
    [[ "${iface}" == br-* ]] && continue

    configuration="$(get_udev_attr "${path}" configuration || true)"
    if [[ "${configuration}" =~ RNDIS\+L4T ]]; then
      printf '%s\n' "${iface}"
      return 0
    fi

    if [[ "${iface}" =~ ^enp[0-9]+s[0-9]+u[0-9]+(i[0-9]+)?$ ]]; then
      printf '%s\n' "${iface}"
      return 0
    fi
  done

  return 1
}

fix_host_flash_iface_ipv6() {
  local iface="$1"

  sudo -n sysctl -w "net.ipv6.conf.${iface}.disable_ipv6=0" >/dev/null 2>&1 || true
  sudo -n ip link set dev "${iface}" up >/dev/null 2>&1 || true

  if ! ip -6 addr show dev "${iface}" | grep -q 'fc00:1:1:0::1/64'; then
    sudo -n ip -6 addr add fc00:1:1:0::1/64 dev "${iface}" 2>/dev/null || true
  fi

  if ! ip -6 addr show dev "${iface}" | grep -q 'fe80::2/64'; then
    sudo -n ip -6 addr add fe80::2/64 dev "${iface}" 2>/dev/null || true
  fi
}

host_flash_iface_watch_loop() {
  local deadline=0
  local iface=""
  local announced=0

  if [[ "${HOST_FLASH_IFACE_TIMEOUT}" =~ ^[0-9]+$ ]] && (( HOST_FLASH_IFACE_TIMEOUT > 0 )); then
    deadline=$((SECONDS + HOST_FLASH_IFACE_TIMEOUT))
  fi

  while (( deadline == 0 || SECONDS < deadline )); do
    iface="$(discover_host_flash_iface || true)"
    if [[ -n "${iface}" && -e "/sys/class/net/${iface}" ]]; then
      HOST_FLASH_IFACE="${iface}"
      fix_host_flash_iface_ipv6 "${iface}"
      if (( announced == 0 )); then
        echo "Flash USB host interface ready: ${iface}"
        announced=1
      fi
    fi

    sleep 1
  done

  if (( announced == 0 )); then
    echo "Flash USB host interface watcher timed out after ${HOST_FLASH_IFACE_TIMEOUT}s" >&2
  fi
}

run_with_host_flash_iface_watcher() {
  local watcher_pid=""
  local rc=0

  host_flash_iface_watch_loop &
  watcher_pid=$!

  "$@" || rc=$?

  if [[ -n "${watcher_pid}" ]] && kill -0 "${watcher_pid}" 2>/dev/null; then
    kill "${watcher_pid}" 2>/dev/null || true
    wait "${watcher_pid}" 2>/dev/null || true
  fi

  return "${rc}"
}

run_rootfs_chroot() {
  local rootfs="${L4T_DIR}/rootfs"
  local qemu_path="/usr/bin/qemu-aarch64-static"
  local copied_qemu=0
  local mounted_sys=0
  local mounted_proc=0
  local mounted_dev=0
  local rc=0

  if [[ ! -x "${qemu_path}" ]]; then
    echo "qemu-aarch64-static introuvable sur l'hôte du conteneur." >&2
    return 1
  fi

  sudo cp -f "${qemu_path}" "${rootfs}/usr/bin/"
  copied_qemu=1

  if ! mountpoint -q "${rootfs}/sys"; then
    sudo mount --bind /sys "${rootfs}/sys"
    mounted_sys=1
  fi

  if ! mountpoint -q "${rootfs}/proc"; then
    sudo mount --bind /proc "${rootfs}/proc"
    mounted_proc=1
  fi

  if ! mountpoint -q "${rootfs}/dev"; then
    sudo mount --bind /dev "${rootfs}/dev"
    mounted_dev=1
  fi

  sudo chroot "${rootfs}" /usr/bin/env LANG=C.UTF-8 "$@" || rc=$?

  if (( mounted_dev == 1 )); then
    sudo umount "${rootfs}/dev" || true
  fi
  if (( mounted_proc == 1 )); then
    sudo umount "${rootfs}/proc" || true
  fi
  if (( mounted_sys == 1 )); then
    sudo umount "${rootfs}/sys" || true
  fi
  if (( copied_qemu == 1 )); then
    sudo rm -f "${rootfs}/usr/bin/qemu-aarch64-static"
  fi

  return "${rc}"
}

apply_rootfs_locale_and_keyboard() {
  local rootfs="${L4T_DIR}/rootfs"
  local locale_entry=""
  local escaped_entry=""

  ensure_l4t_rootfs

  if [[ -z "${DEFAULT_LOCALE}" && -z "${DEFAULT_KEYBOARD}" ]]; then
    return 0
  fi

  if [[ -n "${DEFAULT_KEYBOARD}" ]]; then
    sudo tee "${rootfs}/etc/default/keyboard" >/dev/null <<EOF
# KEYBOARD CONFIGURATION FILE

# Consult the keyboard(5) manual page.

XKBMODEL="pc105"
XKBLAYOUT="${DEFAULT_KEYBOARD}"
XKBVARIANT=""
XKBOPTIONS=""

BACKSPACE="guess"
EOF
    echo "Clavier par défaut configuré: ${DEFAULT_KEYBOARD}"
  fi

  if [[ -n "${DEFAULT_LOCALE}" ]]; then
    locale_entry="${DEFAULT_LOCALE} UTF-8"
    escaped_entry="$(escape_extended_regex "${locale_entry}")"

    if sudo grep -Eq "^#?[[:space:]]*${escaped_entry}$" "${rootfs}/etc/locale.gen"; then
      sudo sed -i -E "s/^#?[[:space:]]*(${escaped_entry})$/\\1/" "${rootfs}/etc/locale.gen"
    else
      printf '%s\n' "${locale_entry}" | sudo tee -a "${rootfs}/etc/locale.gen" >/dev/null
    fi

    printf 'LANG=%s\n' "${DEFAULT_LOCALE}" | sudo tee "${rootfs}/etc/default/locale" >/dev/null

    run_rootfs_chroot /usr/sbin/locale-gen "${DEFAULT_LOCALE}"
    run_rootfs_chroot /usr/sbin/update-locale "LANG=${DEFAULT_LOCALE}"
    echo "Locale par défaut configurée: ${DEFAULT_LOCALE}"
  fi
}

install_rootfs_wifi_connection() {
  local rootfs="${L4T_DIR}/rootfs"
  local connections_dir="${rootfs}/etc/NetworkManager/system-connections"
  local connection_file="${connections_dir}/99-codex-wifi.nmconnection"
  local wifi_psk=""
  local profile_uuid=""

  if [[ -z "${DEFAULT_WIFI_SSID}" && -z "${DEFAULT_WIFI_PSK_FILE}" ]]; then
    return 0
  fi

  if [[ -z "${DEFAULT_WIFI_SSID}" || -z "${DEFAULT_WIFI_PSK_FILE}" ]]; then
    echo "Définis DEFAULT_WIFI_SSID et DEFAULT_WIFI_PSK_FILE ensemble." >&2
    exit 1
  fi

  if ! file_readable_maybe_sudo "${DEFAULT_WIFI_PSK_FILE}"; then
    echo "Impossible de lire DEFAULT_WIFI_PSK_FILE=${DEFAULT_WIFI_PSK_FILE}" >&2
    exit 1
  fi

  wifi_psk="$(read_first_line_maybe_sudo "${DEFAULT_WIFI_PSK_FILE}")"

  if [[ -z "${wifi_psk}" ]]; then
    echo "Le fichier DEFAULT_WIFI_PSK_FILE est vide." >&2
    exit 1
  fi

  profile_uuid="$(cat /proc/sys/kernel/random/uuid)"

  sudo install -d -m 700 "${connections_dir}"
  sudo tee "${connection_file}" >/dev/null <<EOF
[connection]
id=${DEFAULT_WIFI_SSID}
uuid=${profile_uuid}
type=wifi
autoconnect=true
autoconnect-priority=100

[wifi]
mode=infrastructure
ssid=${DEFAULT_WIFI_SSID}

[wifi-security]
auth-alg=open
key-mgmt=wpa-psk
psk=${wifi_psk}

[ipv4]
method=auto

[ipv6]
addr-gen-mode=default
method=auto

[proxy]
EOF
  sudo chmod 600 "${connection_file}"
  sudo chown root:root "${connection_file}"
  echo "Wi-Fi préconfiguré pour le premier boot: ${DEFAULT_WIFI_SSID}"
}

install_default_user_authorized_key() {
  local rootfs="${L4T_DIR}/rootfs"
  local passwd_entry=""
  local uid=""
  local gid=""
  local home_dir=""
  local ssh_dir=""
  local auth_keys=""
  local key_line=""

  if [[ -z "${DEFAULT_SSH_AUTHORIZED_KEY_FILE}" ]]; then
    return 0
  fi

  if ! file_readable_maybe_sudo "${DEFAULT_SSH_AUTHORIZED_KEY_FILE}"; then
    echo "Impossible de lire DEFAULT_SSH_AUTHORIZED_KEY_FILE=${DEFAULT_SSH_AUTHORIZED_KEY_FILE}" >&2
    exit 1
  fi

  passwd_entry="$(awk -F: -v user="${DEFAULT_USER}" '$1 == user {print $3 ":" $4 ":" $6}' "${rootfs}/etc/passwd")"
  if [[ -z "${passwd_entry}" ]]; then
    echo "Utilisateur introuvable dans la rootfs: ${DEFAULT_USER}" >&2
    exit 1
  fi

  IFS=: read -r uid gid home_dir <<< "${passwd_entry}"
  ssh_dir="${rootfs}${home_dir}/.ssh"
  auth_keys="${ssh_dir}/authorized_keys"

  sudo install -d -m 700 "${ssh_dir}"
  sudo touch "${auth_keys}"
  sudo chmod 600 "${auth_keys}"

  while IFS= read -r key_line || [[ -n "${key_line}" ]]; do
    [[ -z "${key_line}" ]] && continue
    if ! sudo grep -Fqx -- "${key_line}" "${auth_keys}"; then
      printf '%s\n' "${key_line}" | sudo tee -a "${auth_keys}" >/dev/null
    fi
  done < <(stream_file_maybe_sudo "${DEFAULT_SSH_AUTHORIZED_KEY_FILE}")

  sudo chown -R "${uid}:${gid}" "${ssh_dir}"
  echo "Clé SSH publique installée pour ${DEFAULT_USER}"
}

configure_ssh_key_only_auth() {
  local rootfs="${L4T_DIR}/rootfs"
  local sshd_config="${rootfs}/etc/ssh/sshd_config"
  local sshd_dropin_dir="${rootfs}/etc/ssh/sshd_config.d"
  local sshd_dropin="${sshd_dropin_dir}/99-codex-key-only.conf"

  if [[ "${DEFAULT_SSH_KEY_ONLY}" != "1" && "${DEFAULT_SSH_KEY_ONLY}" != "true" && "${DEFAULT_SSH_KEY_ONLY}" != "yes" ]]; then
    return 0
  fi

  if [[ -z "${DEFAULT_SSH_AUTHORIZED_KEY_FILE}" ]]; then
    echo "DEFAULT_SSH_KEY_ONLY demande aussi DEFAULT_SSH_AUTHORIZED_KEY_FILE." >&2
    exit 1
  fi

  if [[ -d "${sshd_dropin_dir}" ]]; then
    sudo tee "${sshd_dropin}" >/dev/null <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
EOF
  elif [[ -f "${sshd_config}" ]]; then
    sudo sed -i -E 's/^#?[[:space:]]*PasswordAuthentication[[:space:]]+.*/PasswordAuthentication no/' "${sshd_config}"
    sudo sed -i -E 's/^#?[[:space:]]*KbdInteractiveAuthentication[[:space:]]+.*/KbdInteractiveAuthentication no/' "${sshd_config}" || true
    sudo sed -i -E 's/^#?[[:space:]]*ChallengeResponseAuthentication[[:space:]]+.*/ChallengeResponseAuthentication no/' "${sshd_config}" || true
    sudo sed -i -E 's/^#?[[:space:]]*PubkeyAuthentication[[:space:]]+.*/PubkeyAuthentication yes/' "${sshd_config}" || true
    sudo sed -i -E 's/^#?[[:space:]]*PermitRootLogin[[:space:]]+.*/PermitRootLogin no/' "${sshd_config}" || true
  else
    echo "Configuration SSH introuvable dans la rootfs." >&2
    exit 1
  fi

  echo "Authentification SSH par clé uniquement activée"
}

configure_default_user_sudo_access() {
  local rootfs="${L4T_DIR}/rootfs"
  local sudoers_dir="${rootfs}/etc/sudoers.d"
  local sudoers_file="${sudoers_dir}/99-codex-nopasswd"

  ensure_l4t_rootfs

  if [[ -z "${DEFAULT_USER}" ]]; then
    echo "DEFAULT_USER doit être défini pour configurer sudo." >&2
    exit 1
  fi

  run_rootfs_chroot /usr/sbin/usermod -aG sudo "${DEFAULT_USER}"

  if [[ "${DEFAULT_SUDO_NOPASSWD}" == "1" || "${DEFAULT_SUDO_NOPASSWD}" == "true" || "${DEFAULT_SUDO_NOPASSWD}" == "yes" ]]; then
    sudo install -d -m 755 "${sudoers_dir}"
    sudo tee "${sudoers_file}" >/dev/null <<EOF
${DEFAULT_USER} ALL=(ALL:ALL) NOPASSWD:ALL
EOF
    sudo chmod 440 "${sudoers_file}"
    sudo chown root:root "${sudoers_file}"
    echo "Accès sudo sans mot de passe activé pour ${DEFAULT_USER}"
  else
    sudo rm -f "${sudoers_file}" || true
    echo "Accès sudo activé pour ${DEFAULT_USER}"
  fi
}

resolve_default_password() {
  local confirm_password=""

  if [[ -n "${DEFAULT_PASSWORD}" && -n "${DEFAULT_PASSWORD_FILE}" ]]; then
    echo "Utilise soit DEFAULT_PASSWORD soit DEFAULT_PASSWORD_FILE, pas les deux." >&2
    exit 1
  fi

  if [[ -n "${DEFAULT_PASSWORD_FILE}" ]]; then
    if ! file_readable_maybe_sudo "${DEFAULT_PASSWORD_FILE}"; then
      echo "Impossible de lire DEFAULT_PASSWORD_FILE=${DEFAULT_PASSWORD_FILE}" >&2
      exit 1
    fi
    DEFAULT_PASSWORD="$(read_first_line_maybe_sudo "${DEFAULT_PASSWORD_FILE}")"
  fi

  if [[ -n "${DEFAULT_PASSWORD}" ]]; then
    return 0
  fi

  if [[ -t 0 || -t 1 ]] && [[ -r /dev/tty ]]; then
    read -rsp "Mot de passe pour ${DEFAULT_USER}: " DEFAULT_PASSWORD < /dev/tty
    printf '\n' > /dev/tty
    read -rsp "Confirme le mot de passe: " confirm_password < /dev/tty
    printf '\n' > /dev/tty

    if [[ "${DEFAULT_PASSWORD}" != "${confirm_password}" ]]; then
      echo "Les mots de passe ne correspondent pas." >&2
      exit 1
    fi
  fi

  if [[ -z "${DEFAULT_PASSWORD}" ]]; then
    echo "Définis DEFAULT_PASSWORD_FILE=... ou saisis le mot de passe interactif." >&2
    exit 1
  fi
}

create_default_user() {
  local cmd=()
  local auto_login_arg=()
  local log_file=""
  local user_already_exists=0

  ensure_l4t_rootfs

  if [[ -z "${DEFAULT_USER}" ]]; then
    echo "Définis DEFAULT_USER=... pour bypass oem-config." >&2
    exit 1
  fi

  if default_user_exists_in_rootfs; then
    user_already_exists=1
    echo "Utilisateur déjà présent dans la rootfs: ${DEFAULT_USER}. Réutilisation de cet utilisateur."
  else
    resolve_default_password
  fi

  if (( user_already_exists == 0 )); then
    if [[ ! -x "${L4T_DIR}/tools/l4t_create_default_user.sh" ]]; then
      echo "Script NVIDIA introuvable: ${L4T_DIR}/tools/l4t_create_default_user.sh" >&2
      exit 1
    fi

    if [[ "${DEFAULT_AUTOLOGIN}" == "1" || "${DEFAULT_AUTOLOGIN}" == "true" || "${DEFAULT_AUTOLOGIN}" == "yes" ]]; then
      auto_login_arg=(--autologin)
    fi

    cmd=(
      sudo
      "${L4T_DIR}/tools/l4t_create_default_user.sh"
      --accept-license
      --username "${DEFAULT_USER}"
      --password "${DEFAULT_PASSWORD}"
      --hostname "${DEFAULT_HOSTNAME}"
    )

    if [[ ${#auto_login_arg[@]} -gt 0 ]]; then
      cmd+=("${auto_login_arg[@]}")
    fi

    log_file="$(mktemp)"
    if ! "${cmd[@]}" >"${log_file}" 2>&1; then
      grep -v 'Password -' "${log_file}" >&2 || true
      rm -f "${log_file}"
      exit 1
    fi

    grep -v 'Password -' "${log_file}" || true
    rm -f "${log_file}"
  fi

  apply_rootfs_locale_and_keyboard
  install_rootfs_wifi_connection
  configure_default_user_sudo_access
  install_default_user_authorized_key
  configure_ssh_key_only_auth
  echo "Utilisateur par défaut créé dans la rootfs: ${DEFAULT_USER}@${DEFAULT_HOSTNAME}"
}

prepare_headless_flash() {
  if ! rootfs_ready; then
    prepare
  fi

  prepare_cuda_sysroot "${L4T_DIR}/rootfs"
  create_default_user

  if [[ "${FLASH_TARGET}" == "nvme" ]]; then
    flash_nvme
  else
    flash_internal
  fi
}

ensure_nfs() {
  local nfs_exports="/etc/exports.d/nvidia-initrd-flash.exports"
  local l4t_rootfs="${L4T_DIR}/rootfs"
  local l4t_images="${L4T_DIR}/tools/kernel_flash/images"
  local l4t_tmp="${L4T_DIR}/tools/kernel_flash/tmp"

  sudo mkdir -p /run/rpcbind /run/nvidia_initrd_flash /proc/fs/nfsd /etc/exports.d
  sudo touch /run/nvidia_initrd_flash/docker_host_network

  sudo mkdir -p "${l4t_images}" "${l4t_tmp}"
  sudo chmod 755 "${l4t_rootfs}" "${l4t_images}" "${l4t_tmp}" || true
  sudo chown root:root "${l4t_rootfs}" "${l4t_images}" "${l4t_tmp}" || true

  # Drop old exports first. After repeated generate/flash cycles, stale NFS
  # handles can remain if the client still sees previous incarnations of these
  # directories.
  sudo exportfs -u "*:${l4t_tmp}" 2>/dev/null || true
  sudo exportfs -u "*:${l4t_images}" 2>/dev/null || true
  sudo exportfs -u "*:${l4t_rootfs}" 2>/dev/null || true
  sudo rm -f "${nfs_exports}"
  sudo exportfs -f || true

  sudo service rpcbind restart >/dev/null 2>&1 || {
    if ! pgrep -x rpcbind >/dev/null 2>&1; then
      sudo rpcbind -w || true
    fi
  }

  mountpoint -q /proc/fs/nfsd || sudo mount -t nfsd nfsd /proc/fs/nfsd || true

  cat <<EOF | sudo tee "${nfs_exports}" >/dev/null
# Entries added by sdkmctl for NVIDIA initrd flash in Docker
${l4t_tmp} *(rw,nohide,insecure,no_subtree_check,async,no_root_squash)
${l4t_images} *(rw,nohide,insecure,no_subtree_check,async,no_root_squash)
${l4t_rootfs} *(rw,nohide,insecure,no_subtree_check,async,no_root_squash)
EOF

  sudo service nfs-kernel-server restart >/dev/null 2>&1 || true
  sudo exportfs -rav || true
  sudo rpc.nfsd 8 || true

  if ! showmount -e localhost >/dev/null 2>&1; then
    echo "Le serveur NFS n'exporte rien sur localhost après réinitialisation." >&2
    exit 1
  fi
}

require_flash_package() {
  local required=(
    "${L4T_DIR}/bootloader/flashcmd.txt"
    "${L4T_DIR}/tools/kernel_flash/images/internal/flash.idx"
  )
  local path=""

  if [[ "${FLASH_TARGET}" == "nvme" ]]; then
    required+=("${L4T_DIR}/tools/kernel_flash/images/external/flash.idx")
  fi

  for path in "${required[@]}"; do
    if [[ ! -e "${path}" ]]; then
      echo "Artefact de flash absent: ${path}" >&2
      echo "Lance d'abord TASK=flash ou génère les images avec TASK=prepare puis TASK=flash." >&2
      exit 1
    fi
  done
}

generate_flash_package_internal() {
  cd "${L4T_DIR}"
  lsusb | grep -i nvidia
  sudo ./tools/kernel_flash/l4t_initrd_flash.sh \
    --no-flash \
    --showlogs --network usb0 \
    jetson-orin-nano-devkit-super internal
}

generate_flash_package_nvme() {
  cd "${L4T_DIR}"
  lsusb | grep -i nvidia
  sudo ./tools/kernel_flash/l4t_initrd_flash.sh \
    --no-flash \
    --external-device nvme0n1p1 \
    -c tools/kernel_flash/flash_l4t_t234_nvme.xml \
    -p "-c bootloader/generic/cfg/flash_t234_qspi.xml" \
    --showlogs --network usb0 \
    jetson-orin-nano-devkit-super internal
}

flash_internal() {
  generate_flash_package_internal
  flash_only_internal
}

flash_nvme() {
  generate_flash_package_nvme
  flash_only_nvme
}

flash_only_internal() {
  cd "${L4T_DIR}"
  require_flash_package
  ensure_nfs
  lsusb | grep -i nvidia
  run_with_host_flash_iface_watcher sudo ./tools/kernel_flash/l4t_initrd_flash.sh \
    --flash-only \
    --showlogs --network usb0 \
    jetson-orin-nano-devkit-super internal
}

flash_only_nvme() {
  cd "${L4T_DIR}"
  require_flash_package
  ensure_nfs
  lsusb | grep -i nvidia
  run_with_host_flash_iface_watcher sudo ./tools/kernel_flash/l4t_initrd_flash.sh \
    --flash-only \
    --external-device nvme0n1p1 \
    -c tools/kernel_flash/flash_l4t_t234_nvme.xml \
    -p "-c bootloader/generic/cfg/flash_t234_qspi.xml" \
    --showlogs --network usb0 \
    jetson-orin-nano-devkit-super internal
}

#native arm compiler thorugh QEMU on a powerful x86_64 not cross-compiled toolchain (runs on your normal x86_64 machine and produces arm binaries)
setup_crosscompile_workspace() {
  if [[ -z "${REPO}" ]]; then
    echo "Définis REPO=https://..." >&2
    exit 1
  fi

  mkdir -p "${TOOLCHAIN_DIR}" "${SOURCES_DIR}"
  cd "${TOOLCHAIN_DIR}"

  TOOLCHAIN_ARCHIVE="$(basename "${TOOLCHAIN_URL}")"
  LOCAL_TOOLCHAIN_ARCHIVE="${TOOLCHAIN_DIR}/${TOOLCHAIN_ARCHIVE}"

  # Accept a pre-downloaded toolchain archive from common cache locations.
  if [[ ! -f "${LOCAL_TOOLCHAIN_ARCHIVE}" ]]; then
    for candidate in \
      "${SOURCES_DIR}/${TOOLCHAIN_ARCHIVE}" \
      "/work/${TOOLCHAIN_ARCHIVE}"
    do
      if [[ -f "${candidate}" ]]; then
        cp -f "${candidate}" "${LOCAL_TOOLCHAIN_ARCHIVE}"
        break
      fi
    done
  fi

  if [[ ! -f "${LOCAL_TOOLCHAIN_ARCHIVE}" ]]; then
    wget -O "${LOCAL_TOOLCHAIN_ARCHIVE}" "${TOOLCHAIN_URL}"
  fi

  if [[ ! -d "${TOOLCHAIN_DIR}/aarch64-toolchain" ]]; then
    mkdir -p aarch64-toolchain
    tar -xf "${LOCAL_TOOLCHAIN_ARCHIVE}" -C aarch64-toolchain --strip-components=1
  fi

  export TOOLCHAIN_ROOT="${TOOLCHAIN_DIR}/aarch64-toolchain"
  export PATH="${PATH}:${TOOLCHAIN_ROOT}/bin"
  export CROSS_COMPILE=aarch64-buildroot-linux-gnu-
  export CC="${TOOLCHAIN_ROOT}/bin/${CROSS_COMPILE}gcc"
  export CXX="${TOOLCHAIN_ROOT}/bin/${CROSS_COMPILE}g++"
  export AR="${TOOLCHAIN_ROOT}/bin/${CROSS_COMPILE}ar"
  export LD="${TOOLCHAIN_ROOT}/bin/${CROSS_COMPILE}ld"
  export STRIP="${TOOLCHAIN_ROOT}/bin/${CROSS_COMPILE}strip"

  ensure_l4t_rootfs
  TOOLCHAIN_SYSROOT="$("${CC}" -print-sysroot)"
  export TOOLCHAIN_SYSROOT
  prepare_cuda_sysroot "${L4T_DIR}/rootfs"
  prepare_cuda_sysroot "${TOOLCHAIN_SYSROOT}"
  TARGET_CUDA_HOME="$(pick_cuda_home "${TOOLCHAIN_SYSROOT}")"
  BUILD_CUDA_HOME="$(pick_host_cuda_home)"
  if [[ -z "${BUILD_CUDA_HOME}" ]]; then
    BUILD_CUDA_HOME="${TARGET_CUDA_HOME}"
  fi
  export TARGET_CUDA_HOME BUILD_CUDA_HOME
  configure_rust_cross_env "${L4T_DIR}/rootfs" "${TARGET_CUDA_HOME}" "${TOOLCHAIN_SYSROOT}" "${BUILD_CUDA_HOME}"

  cd "${SOURCES_DIR}"
  REPO_DIR="$(basename "${REPO%.git}")"
  if [[ ! -d "${REPO_DIR}" ]]; then
    git clone "${REPO}"
  fi

  cd "${REPO_DIR}"
}

crosscompile() {
  setup_crosscompile_workspace

  echo "Toolchain prête. Compile ton projet ici."
  echo "CC=${CC}"
  echo "RUST_TARGET=${RUST_TARGET}"
  echo "TOOLCHAIN_SYSROOT=${TOOLCHAIN_SYSROOT}"
  echo "TARGET_ROOTFS=${L4T_DIR}/rootfs"
  echo "TARGET_CUDA_HOME=${TARGET_CUDA_HOME:-}"
  echo "BUILD_CUDA_HOME=${BUILD_CUDA_HOME:-}"
  if [[ "${REPO_DIR}" == "mistral.rs" ]]; then
    echo "Features mistral.rs suggérées: $(detect_mistralrs_features "${L4T_DIR}/rootfs")"
    echo "Exemple:"
    echo "cargo build --release --target ${RUST_TARGET} -p mistralrs-server --features \"$(detect_mistralrs_features "${L4T_DIR}/rootfs")\""
  fi
  exec /bin/bash
}

sanitize_cache_token() {
  printf '%s\n' "$1" | tr ' /:' '_' | tr -cd 'A-Za-z0-9._+-'
}

default_mistralrs_target_dir() {
  local features="$1"
  local package_name="${2:-${MISTRALRS_PACKAGE}}"
  local feature_token=""
  local cuda_token=""
  local package_token=""

  feature_token="$(sanitize_cache_token "${features:-default}")"
  cuda_token="$(sanitize_cache_token "${CUDA_TOOLKIT_VERSION:-auto}")"
  package_token="$(sanitize_cache_token "${package_name}")"

  printf '%s\n' "${SOURCES_DIR}/.build-cache/mistralrs-${package_token}-${RUST_TARGET}-cuda${cuda_token}-${feature_token}"
}

resolve_mistralrs_package_bin() {
  local package_name="${1:-${MISTRALRS_PACKAGE}}"
  local bin_name="${2:-${MISTRALRS_BIN}}"

  case "${package_name}" in
    mistralrs-cli)
      if [[ -z "${bin_name}" ]]; then
        bin_name="mistralrs"
      fi
      ;;
    mistralrs-server)
      if [[ -z "${bin_name}" ]]; then
        bin_name="mistralrs-server"
      fi
      ;;
    *)
      if [[ -z "${bin_name}" ]]; then
        bin_name="${package_name}"
      fi
      ;;
  esac

  printf '%s\n%s\n' "${package_name}" "${bin_name}"
}

build_mistralrs() {
  local features=""
  local cargo_cmd=()
  local profile_dir=""
  local artifact=""
  local target_dir=""
  local resolved_package=""
  local resolved_bin=""

  if [[ -z "${REPO}" ]]; then
    REPO="https://github.com/EricLBuehler/mistral.rs"
  fi

  setup_crosscompile_workspace

  if [[ "${REPO_DIR}" != "mistral.rs" ]]; then
    echo "build_mistralrs attend le dépôt mistral.rs, pas ${REPO_DIR}." >&2
    exit 1
  fi

  mapfile -t resolved_selection < <(resolve_mistralrs_package_bin "${MISTRALRS_PACKAGE}" "${MISTRALRS_BIN}")
  resolved_package="${resolved_selection[0]}"
  resolved_bin="${resolved_selection[1]}"

  features="$(detect_mistralrs_features "${L4T_DIR}/rootfs")"
  profile_dir="${MISTRALRS_PROFILE}"
  target_dir="${MISTRALRS_TARGET_DIR:-$(default_mistralrs_target_dir "${features}" "${resolved_package}")}"
  mkdir -p "${target_dir}"
  export CARGO_TARGET_DIR="${target_dir}"

  if [[ "${MISTRALRS_FORCE_CLEAN}" == "1" || "${MISTRALRS_FORCE_CLEAN}" == "true" || "${MISTRALRS_FORCE_CLEAN}" == "yes" ]]; then
    echo "Nettoyage forcé du cache cargo pour ${target_dir}"
    cargo clean --target-dir "${target_dir}" >/dev/null 2>&1 || true
  fi

  cargo_cmd=(
    env
    -u CC
    -u CXX
    -u AR
    -u LD
    -u CFLAGS
    -u CXXFLAGS
    -u CPPFLAGS
    -u LDFLAGS
    -u LIBRARY_PATH
    -u LD_LIBRARY_PATH
    -u C_INCLUDE_PATH
    -u CPLUS_INCLUDE_PATH
    -u PKG_CONFIG_SYSROOT_DIR
    -u PKG_CONFIG_LIBDIR
    -u PKG_CONFIG_PATH
    cargo build --target "${RUST_TARGET}" -p "${resolved_package}"
  )
  if [[ "${MISTRALRS_PROFILE}" == "release" ]]; then
    cargo_cmd+=(--release)
  else
    cargo_cmd+=(--profile "${MISTRALRS_PROFILE}")
  fi
  if [[ -n "${features}" ]]; then
    cargo_cmd+=(--features "${features}")
  fi

  echo "Compilation de mistral.rs pour Jetson"
  echo "Package=${resolved_package}"
  echo "Binary=${resolved_bin}"
  echo "Target=${RUST_TARGET}"
  echo "Features=${features}"
  echo "TargetDir=${target_dir}"
  echo "TargetCUDA=${TARGET_CUDA_HOME:-}"
  echo "BuildCUDA=${BUILD_CUDA_HOME:-}"
  echo "Commande=${cargo_cmd[*]}"

  "${cargo_cmd[@]}"

  artifact="${target_dir}/${RUST_TARGET}/${profile_dir}/${resolved_bin}"
  if [[ -e "${artifact}" ]]; then
    echo "Binaire généré: ${PWD}/${artifact}"
    file "${artifact}" || true
  else
    echo "Build terminé, mais binaire attendu introuvable: ${artifact}" >&2
    exit 1
  fi
}

case "${TASK}" in
  download) download ;;
  download_interactive) download_interactive ;;
  prepare) prepare ;;
  create_default_user) create_default_user ;;
  prepare_headless_flash) prepare_headless_flash ;;
  flash)
    if [[ "${FLASH_TARGET}" == "nvme" ]]; then
      flash_nvme
    else
      flash_internal
    fi
    ;;
  flash_only)
    if [[ "${FLASH_TARGET}" == "nvme" ]]; then
      flash_only_nvme
    else
      flash_only_internal
    fi
    ;;
  crosscompile) crosscompile ;;
  build_mistralrs) build_mistralrs ;;
  shell) exec /bin/bash ;;
  *)
    echo "TASK invalide: ${TASK}" >&2
    exit 1
    ;;
esac
