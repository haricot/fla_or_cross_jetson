# syntax=docker/dockerfile:1.7
ARG SDK_MANAGER_BOOTSTRAP_IMAGE=ubuntu:24.04
FROM ${SDK_MANAGER_BOOTSTRAP_IMAGE}

ARG SDK_MANAGER_APT_DISTRO=ubuntu2404
ARG SDK_MANAGER_APT_VERSION_PREFIX=2.4.1
ARG SDK_MANAGER_IMAGE_FINGERPRINT=unknown

USER root
ENV DEBIAN_FRONTEND=noninteractive

# Base APT tooling + NVIDIA repository. Keep this separate so a later flash-tool
# failure does not force another SDK Manager download.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl gnupg \
    && curl -fL --retry 3 --retry-delay 2 \
      "https://developer.download.nvidia.com/compute/cuda/repos/${SDK_MANAGER_APT_DISTRO}/x86_64/cuda-keyring_1.1-1_all.deb" \
      -o /tmp/cuda-keyring.deb \
    && dpkg -i /tmp/cuda-keyring.deb \
    && rm -f /tmp/cuda-keyring.deb \
    && rm -rf /var/lib/apt/lists/*

# Pin SDK Manager to the requested 2.4.1 package family.
RUN apt-get update \
    && sdkm_version="$(apt-cache madison sdkmanager | awk -v p="${SDK_MANAGER_APT_VERSION_PREFIX}" 'index($3,p)==1 {print $3; exit}')" \
    && test -n "$sdkm_version" \
    && printf 'Selected SDK Manager package: %s\n' "$sdkm_version" \
    && apt-get install -y --no-install-recommends "sdkmanager=${sdkm_version}" \
    && dpkg-query -W -f='Installed SDK Manager: ${Version}\n' sdkmanager \
    && rm -rf /var/lib/apt/lists/*

# Runtime tools required by L4T/initrd flash. Service start is deliberately
# suppressed while building the image; rpcbind/NFS/udev are started or used
# only when the privileged flash container is actually running.
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d \
    && chmod 0755 /usr/sbin/policy-rc.d \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
      bash sudo usbutils iproute2 iputils-ping procps kmod udev libnss-systemd \
      nfs-kernel-server nfs-common rpcbind \
      rsync openssh-client openssl locales keyboard-configuration \
      abootimg binfmt-support binutils bzip2 cpio cpp device-tree-compiler dosfstools \
      file gdisk lbzip2 libxml2-utils lz4 netcat-openbsd parted \
      python-is-python3 python3-yaml sshpass uuid-runtime whois xmlstarlet xxd \
      xz-utils zlib1g zstd \
    && command -v lbzip2 \
    && command -v bzip2 \
    && command -v xz \
    && command -v lz4 \
    && command -v zstd \
    && command -v dtc \
    && command -v xmllint \
    && command -v xmlstarlet \
    && command -v sshpass \
    && command -v cpio \
    && command -v sgdisk \
    && command -v parted \
    && rm -f /usr/sbin/policy-rc.d \
    && rm -rf /var/lib/apt/lists/*

# We need the *static* aarch64 emulator inside the ARM64 rootfs chroot, but we
# do not need or want qemu-user-static's binfmt registration during docker
# build. Extract the package payload directly, avoiding its postinst entirely.
RUN apt-get update \
    && mkdir -p /tmp/qemu-static \
    && cd /tmp/qemu-static \
    && apt-get download qemu-user-static \
    && qemu_deb="$(find . -maxdepth 1 -type f -name 'qemu-user-static_*.deb' -print -quit)" \
    && test -n "$qemu_deb" \
    && dpkg-deb -x "$qemu_deb" / \
    && test -x /usr/bin/qemu-aarch64-static \
    && /usr/bin/qemu-aarch64-static --version | head -n 1 \
    && cd / \
    && rm -rf /tmp/qemu-static /var/lib/apt/lists/*

# Gate the exact archive path used before Linux_for_Tegra exists. Ubuntu's GNU
# tar may select lbzip2 for bzip2-compressed .tbz2 archives, so verify this at
# image-build time instead of discovering it during `flash prepare`.
RUN set -eux; \
    mkdir -p /tmp/tbz2-gate/src /tmp/tbz2-gate/out; \
    printf '%s\n' 'jetson-flash-prereq-gate' > /tmp/tbz2-gate/src/gate.txt; \
    tar -I lbzip2 -cf /tmp/tbz2-gate/gate.tbz2 -C /tmp/tbz2-gate/src gate.txt; \
    tar xf /tmp/tbz2-gate/gate.tbz2 -C /tmp/tbz2-gate/out; \
    test "$(cat /tmp/tbz2-gate/out/gate.txt)" = jetson-flash-prereq-gate; \
    rm -rf /tmp/tbz2-gate

# Ubuntu 24.04 base images may already contain an `ubuntu` account at UID/GID
# 1000. Reuse that identity instead of failing with `UID 1000 is not unique`.
# Keeping UID 1000 is intentional: bind-mounted SDK Manager state under
# $VOLUME/.nvsdkm should remain owned by the normal host user on typical Linux
# installations.
RUN set -eux; \
    existing_user="$(getent passwd 1000 | cut -d: -f1 || true)"; \
    if getent passwd nvidia >/dev/null 2>&1; then \
      test "$(id -u nvidia)" = 1000; \
      if [ "$(getent passwd nvidia | cut -d: -f6)" != /home/nvidia ]; then \
        usermod -d /home/nvidia -m -s /bin/bash nvidia; \
      fi; \
    elif [ -n "$existing_user" ]; then \
      existing_gid="$(id -g "$existing_user")"; \
      existing_group="$(getent group "$existing_gid" | cut -d: -f1)"; \
      if [ "$existing_user" != nvidia ]; then usermod -l nvidia "$existing_user"; fi; \
      if getent group nvidia >/dev/null 2>&1; then \
        usermod -g nvidia nvidia; \
      elif [ -n "$existing_group" ] && [ "$existing_group" != nvidia ]; then \
        groupmod -n nvidia "$existing_group"; \
      fi; \
      usermod -d /home/nvidia -m -s /bin/bash nvidia; \
    else \
      if ! getent group 1000 >/dev/null 2>&1; then groupadd --gid 1000 nvidia; fi; \
      target_group="$(getent group 1000 | cut -d: -f1)"; \
      useradd --create-home --uid 1000 --gid "$target_group" --shell /bin/bash nvidia; \
      if [ "$target_group" != nvidia ] && ! getent group nvidia >/dev/null 2>&1; then \
        groupmod -n nvidia "$target_group"; \
      fi; \
    fi; \
    test "$(id -u nvidia)" = 1000; \
    test "$(getent passwd nvidia | cut -d: -f6)" = /home/nvidia; \
    mkdir -p /home/nvidia; \
    chown -R nvidia:$(id -gn nvidia) /home/nvidia; \
    echo 'nvidia:nvidia' | chpasswd; \
    usermod -aG sudo nvidia; \
    printf '%s\n' 'nvidia ALL=(ALL:ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-nvidia; \
    chmod 440 /etc/sudoers.d/90-nvidia; \
    id nvidia

COPY flash/entrypoint.sh /usr/local/bin/jetson-flash-entrypoint
RUN chmod +x /usr/local/bin/jetson-flash-entrypoint

# Keep freshness metadata at the very end so changing the wrapper fingerprint
# does not invalidate the expensive SDK Manager/APT layers.
LABEL org.haricot.fla.sdkm-wrapper-fingerprint="${SDK_MANAGER_IMAGE_FINGERPRINT}" \
      org.haricot.fla.sdkm-version-prefix="${SDK_MANAGER_APT_VERSION_PREFIX}" \
      org.haricot.fla.sdkm-bootstrap="${SDK_MANAGER_BOOTSTRAP_IMAGE}" \
      org.haricot.fla.sdkm-distro="${SDK_MANAGER_APT_DISTRO}"

ENTRYPOINT ["/usr/local/bin/jetson-flash-entrypoint"]
CMD ["shell"]
