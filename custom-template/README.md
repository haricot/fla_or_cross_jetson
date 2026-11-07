# Persistent rootfs customization

`./jetsonctl custom init` copies this template to `$VOLUME/custom` once.
The persistent copy is intentionally outside the ZIP so upgrades of the tooling do not overwrite your custom image definition.

- `packages.txt`: packages installed with apt in an ARM64 chroot via qemu-user-static.
- `overlay/`: files copied into the target rootfs. Baseline ownership is normalized to root:root.
- `services-enable.txt`: systemd units enabled inside the target rootfs.
- `hooks/`: optional host-side customization hooks.

Secrets do **not** belong here. Put them under `$VOLUME/secrets`.


Fix13: CUDA 13.3 n'a pas besoin d'être ajouté dans `packages.txt`. Le stage `native-sdk` séparé installe automatiquement le toolkit/compat Orin et participe au fingerprint des images.
