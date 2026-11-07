#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

./gates/audit-fix17.sh >/dev/null
echo 'inherited fix12..fix17: PASS'

# Distinguish SDK Manager client 26.1 from target JetPack 7.2.1.
grep -Fq 'SDK_MANAGER_APT_VERSION_PREFIX=${SDK_MANAGER_APT_VERSION_PREFIX:-26.1}' profiles/jp721-common.env
grep -Fq 'SDK_MANAGER_IMAGE=${SDK_MANAGER_IMAGE:-fla-or-cross-jetson-sdkm:jp721-sdkm261}' profiles/jp721-common.env
grep -Fq 'ARG SDK_MANAGER_APT_VERSION_PREFIX=26.1' containers/sdkmanager.Dockerfile
grep -Fq 'case "$installed" in "$SDK_MANAGER_APT_VERSION_PREFIX"*)' containers/sdkmanager.Dockerfile
grep -Fq 'SDK_MANAGER_APT_VERSION_PREFIX" { default = "26.1" }' docker-bake.hcl
[[ $(grep -c 'SDK_MANAGER_APT_VERSION_PREFIX' jetsonctl) -ge 4 ]]
grep -Fq -- '--entrypoint sdkmanager "$SDK_MANAGER_IMAGE" --ver' jetsonctl

# Both defaults and old version rollback are independent of the JetPack profile.
line=$(./jetsonctl profile)
grep -Fq 'JETSON_PLATFORM=orin-nano-super' <<<"$line"
[[ $(bash -c 'source profiles/platforms/orin-nano-super.env; printf "%s|%s|%s|%s" "$SDK_MANAGER_APT_VERSION_PREFIX" "$JETPACK" "$L4T" "$CUDA_VERSION"') == '26.1|7.2.1|39.2.1|13.3' ]]
[[ $(SDK_MANAGER_APT_VERSION_PREFIX=2.4.1 SDK_MANAGER_IMAGE=fla-or-cross-jetson-sdkm:jp721 bash -c 'source profiles/platforms/orin-nano-super.env; printf "%s|%s" "$SDK_MANAGER_APT_VERSION_PREFIX" "$SDK_MANAGER_IMAGE"') == '2.4.1|fla-or-cross-jetson-sdkm:jp721' ]]
echo 'SDK Manager 26.1 + rollback + JP721 unchanged: PASS'

# A mocked recovery USB entry is insufficient without a usable /dev node.
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
mkdir -p "$t/sys/bus/usb/devices/1-1" "$t/dev/001"
printf '0955\n' > "$t/sys/bus/usb/devices/1-1/idVendor"
printf '7026\n' > "$t/sys/bus/usb/devices/1-1/idProduct"
printf '1\n' > "$t/sys/bus/usb/devices/1-1/busnum"
printf '2\n' > "$t/sys/bus/usb/devices/1-1/devnum"
SYSFS_ROOT="$t/sys" USB_DEV_ROOT="$t/dev" RECOVERY_USB_PRODUCTS=7026 bash -c '
  set -Eeuo pipefail
  source "$1/host/usb-common.sh"
  dev=$(discover_recovery_sysfs)
  [[ "$dev" == "$2/sys/bus/usb/devices/1-1" ]]
  [[ $(usb_devnode_for_sysfs "$dev") == "$2/dev/001/002" ]]
  ! usb_devnode_available "$dev"
' _ "$ROOT" "$t"
# A symlink to an existing character device simulates a properly mapped node.
ln -s /dev/null "$t/dev/001/002"
SYSFS_ROOT="$t/sys" USB_DEV_ROOT="$t/dev" RECOVERY_USB_PRODUCTS=7026 bash -c '
  set -Eeuo pipefail
  source "$1/host/usb-common.sh"
  dev=$(discover_recovery_sysfs)
  usb_devnode_available "$dev"
' _ "$ROOT"
echo 'USB APX sysfs versus /dev/bus/usb character node: PASS'

# No privilege/hardware is invoked in this gate.
for f in jetsonctl host/usb-common.sh host/usb-guard.sh flash/host-preflight.sh gates/audit-r1.sh; do bash -n "$f"; done
echo 'V2-R1 static and synthetic gate: PASS'
