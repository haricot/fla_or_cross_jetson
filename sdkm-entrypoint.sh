#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

mkdir -p /work/downloads /work/tmp /work/toolchains /work/sources
sudo chown nvidia:root /work /work/downloads /work/tmp /work/toolchains /work/sources /home/nvidia/.nvsdkm || true

if ! mountpoint -q /proc/sys/fs/binfmt_misc; then
  sudo mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc || true
fi
sudo update-binfmts --enable qemu-aarch64 || true

# Some Rust build scripts are linked for the x86_64 host inside the container.
# rust-lld may resolve common glibc DSOs through /lib64, but the base image only
# exposes them under /lib/x86_64-linux-gnu. Provide compatibility symlinks.
if [[ -d /usr/lib64 ]]; then
  for lib in \
    libc.so.6 \
    libc_nonshared.a \
    libm.so.6 \
    libpthread.so.0 \
    libpthread_nonshared.a \
    libdl.so.2 \
    librt.so.1 \
    libutil.so.1 \
    libgcc_s.so.1 \
    libstdc++.so.6 \
    crt1.o \
    Scrt1.o \
    Mcrt1.o \
    rcrt1.o \
    crti.o \
    crtn.o
  do
    if [[ -e "/usr/lib64/${lib}" ]]; then
      continue
    fi

    if [[ -e "/lib/x86_64-linux-gnu/${lib}" ]]; then
      sudo ln -s "/lib/x86_64-linux-gnu/${lib}" "/usr/lib64/${lib}" || true
      continue
    fi

    if [[ -e "/usr/lib/x86_64-linux-gnu/${lib}" ]]; then
      sudo ln -s "/usr/lib/x86_64-linux-gnu/${lib}" "/usr/lib64/${lib}" || true
    fi
  done
fi

if (($# > 0)); then
  case "$1" in
    download|download_interactive|prepare|create_default_user|prepare_headless_flash|flash|flash_only|crosscompile|build_mistralrs|shell)
      export TASK="$1"
      shift
      ;;
    *)
      exec "$@"
      ;;
  esac
fi

exec /usr/local/bin/sdkmctl
