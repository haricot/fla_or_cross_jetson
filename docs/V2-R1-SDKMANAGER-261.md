# V2-R1 — SDK Manager 26.1 & Flash Reliability

## Scope

This is a **host tooling upgrade only**: SDK Manager 26.1 is the default,
while JetPack **7.2.1**, L4T **R39.2.1**, Ubuntu **24.04** and CUDA
**13.3 cross/native override** remain as proven in `alpha4-fix17`.
The direct BSP download is still the default; SDK Manager is opt-in.
Nothing in R1 changes NVIDIA's NFS/IPv6 initrd flashing mechanism.

NVIDIA release notes (Oct 2026): https://docs.nvidia.com/sdk-manager/release-notes/

## Versioned, non-destructive commands

```sh
./jetsonctl flash image-status
./jetsonctl flash image             # explicitly build/update 26.1 wrapper
./jetsonctl flash sdkmanager-version # must report SDK Manager 26.1.*
./jetsonctl flash download --provider sdkmanager --query
```

`flash image` requires Docker Buildx and a network to NVIDIA's APT repo.
It **fails** if that repo does not offer the requested 26.1 package and
**does not fall back silently** to another SDK Manager version.
There is no claim of a successful Docker image build until one is actually run.

## Explicit rollback to 2.4.1

```sh
export SDK_MANAGER_APT_VERSION_PREFIX=2.4.1
export SDK_MANAGER_IMAGE=fla-or-cross-jetson-sdkm:jp721
./jetsonctl flash image-status
# build only if needed:
./jetsonctl flash image
```

The SDK Manager image tag is intentionally distinct for 26.1, preserving
an existing `:jp721` 2.4.1 image. The build fingerprint includes both the
SDK Manager version and wrapper content, and does not invalidate the cross
Rust/CUDA image. `SDK_MANAGER_APT_DISTRO` remains `ubuntu2404`.

## USB device-node hardening

`host/usb-common.sh` now verifies a character device exists at
`/dev/bus/usb/<busnum>/<devnum>` (using zero-padded 3-digit path components)
before the host-side recovery wait returns PASS. In a container, sysfs alone
is no proof that `tegrarcm_v2` can open that device. `host-preflight.sh`
reports `BLOCKED` for this condition instead of giving a false PASS.
The prior recovery/gadget PID filtering and all NFS, rpcbind, IPv6,
firewalld state preservation and SecretSpec fix17 readers remain unchanged.

## Gates / boundaries

- `./gates/audit-fix17.sh`: inherited, untouched.
- `./gates/audit-r1.sh`: SDK Manager profile, rollback, USB-node synthetic gate.
- `.github/workflows/v2-r1-static.yml`: non-destructive CI and Rust compile.
- **Not tested here**: Docker/SDK Manager 26.1 APT installation; physical
  Orin/Thor RCM, NVIDIA NFS flash, post-boot CUDA. These require separate
  explicit hardware qualification, with a validated backup and correct device.
