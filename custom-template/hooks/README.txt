Optional rootfs hooks.

If executable files named pre-apt.sh, post-apt.sh, or final.sh exist here,
they are executed by the flash container with these environment variables:
  ROOTFS=/work/downloads/Linux_for_Tegra/rootfs
  L4T_DIR=/work/downloads/Linux_for_Tegra
  CUSTOM_DIR=/work/custom

Hooks execute on the x86_64 host/container, not inside the ARM64 chroot.
Use chroot "$ROOTFS" ... explicitly if needed.
