#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

[[ "$(cat VERSION)" =~ ^2\.0\.0-alpha4-fix1[4567]$ ]]

./gates/audit-fix12.sh >/dev/null
./gates/audit-fix13.sh >/dev/null

echo 'fix12/fix13 inheritance: PASS'

for f in lib/platform.sh profiles/jp721-common.env profiles/platforms/*.env; do
  bash -n "$f"
done

mapfile -t names < <(./jetsonctl platform list | awk 'NR>1 {print $1}')
expected=(
  agx-orin
  agx-orin-industrial
  agx-orin-super
  agx-thor-t4000
  agx-thor-t5000
  orin-nano
  orin-nano-super
  orin-nx
  orin-nx-super
)
[[ "${names[*]}" == "${expected[*]}" ]]
echo 'platform registry: PASS (9 profiles)'

profile_value() {
  local name=$1 key=$2
  env -i PATH="$PATH" HOME=/tmp bash -c 'set -a; source "$1"; set +a; printf "%s" "${!2-}"' _ "$ROOT/profiles/platforms/$name.env" "$key"
}

[[ "$(profile_value orin-nano-super BOARD)" == jetson-orin-nano-devkit-super ]]
[[ "$(profile_value orin-nano-super RECOVERY_USB_PRODUCTS)" == 7523,7623 ]]
[[ "$(profile_value orin-nano-super CUDA_COMPUTE_CAP)" == 87 ]]
[[ "$(profile_value orin-nano-super PLATFORM_HARDWARE_TESTED)" == yes ]]

[[ "$(profile_value orin-nx RECOVERY_USB_PRODUCTS)" == 7323,7423 ]]
[[ "$(profile_value agx-orin BOARD)" == jetson-agx-orin-devkit ]]
[[ "$(profile_value agx-orin RECOVERY_USB_PRODUCTS)" == 7023 ]]
[[ "$(profile_value agx-orin-super RECOVERY_USB_PRODUCTS)" == 7223 ]]
[[ "$(profile_value agx-orin-industrial BOARD)" == jetson-agx-orin-devkit-industrial ]]

[[ "$(profile_value agx-thor-t5000 BOARD)" == jetson-agx-thor-devkit ]]
[[ "$(profile_value agx-thor-t5000 RECOVERY_USB_PRODUCTS)" == 7026 ]]
[[ "$(profile_value agx-thor-t5000 CUDA_COMPUTE_CAP)" == 110 ]]
[[ "$(profile_value agx-thor-t5000 NATIVE_CUDA_COMPAT_PACKAGE)" == cuda-compat-13-3 ]]
[[ "$(profile_value agx-thor-t5000 NATIVE_CUDA_COMPAT_DIR)" == /usr/local/cuda-13.3/compat ]]
[[ "$(profile_value agx-thor-t5000 POST_FLASH_USB_GATE)" == 0 ]]
[[ "$(profile_value agx-thor-t4000 RECOVERY_USB_PRODUCTS)" == 7226 ]]
echo 'platform metadata: PASS'

# Docker/BuildKit commonly exports PLATFORM=linux/amd64. It must not influence
# the Jetson selector.
current=$(PLATFORM=linux/amd64 ./jetsonctl platform current | sed -n 's/^platform=//p')
[[ "$current" == orin-nano-super ]]
show=$(./jetsonctl platform show agx-thor-t5000)
grep -Fq 'BOARD=jetson-agx-thor-devkit' <<<"$show"
grep -Fq 'CUDA_COMPUTE_CAP=110' <<<"$show"
grep -Fq 'RECOVERY_USB_PRODUCTS=7026' <<<"$show"
./jetsonctl cross cargo --platform agx-thor-t5000 --help >/dev/null
echo 'platform CLI/no-collision: PASS'

plan_for() {
  local name=$1 target=${2:-}
  local tmp
  tmp=$(mktemp -d)
  env -i PATH="$PATH" HOME=/root USER=root LOGNAME=root \
    bash -c '
      set -Eeuo pipefail
      set -a; source "$1"; set +a
      [[ -n "$4" ]] && export FLASH_TARGET="$4"
      export DOWNLOAD_DIR="$2" SDKM_DOWNLOAD_DIR="$2/sdkm" USER=root LOGNAME=root HOME=/root
      "$3" plan
    ' _ "$ROOT/profiles/platforms/$name.env" "$tmp" "$ROOT/flash/entrypoint.sh" "$target"
  rm -rf "$tmp"
}

p=$(plan_for orin-nano-super)
grep -Fq -- '--external-device nvme0n1p1' <<<"$p"
grep -Fq -- 'flash_l4t_t234_nvme.xml' <<<"$p"
grep -Fq -- 'flash_t234_qspi.xml' <<<"$p"
grep -Fq -- 'jetson-orin-nano-devkit-super external' <<<"$p"

p=$(plan_for agx-orin nvme)
grep -Fq -- '--external-device nvme0n1p1' <<<"$p"
grep -Fq -- 'jetson-agx-orin-devkit external' <<<"$p"
! grep -Fq -- 'flash_t234_qspi.xml' <<<"$p"

p=$(plan_for agx-thor-t5000)
grep -Fq -- 'jetson-agx-thor-devkit internal' <<<"$p"
! grep -Fq -- '--external-device' <<<"$p"
echo 'platform flash plans: PASS'

# Platform PID must survive helpers executed under sudo/env. Also ensure an
# intentionally empty Thor gadget PID list does not fall back to 7020.
fake=$(mktemp -d)
mkdir -p "$fake/bus/usb/devices/1-1"
printf '0955\n' > "$fake/bus/usb/devices/1-1/idVendor"
printf '7026\n' > "$fake/bus/usb/devices/1-1/idProduct"
SYSFS_ROOT="$fake" RECOVERY_USB_PRODUCTS=7026 L4T_GADGET_USB_PRODUCTS= bash -c '
  set -Eeuo pipefail
  source "$1/host/usb-common.sh"
  discover_recovery_sysfs >/dev/null
  [[ -z "$(l4t_gadget_product_list | xargs)" ]]
' _ "$ROOT"
rm -rf "$fake"
grep -Fq 'platform_sudo()' jetsonctl
grep -Fq 'L4T_GADGET_USB_PRODUCTS=${L4T_GADGET_USB_PRODUCTS-7020}' host/usb-common.sh
echo 'platform USB propagation: PASS'

grep -Fq 'for arch in 87 110' containers/cross.Dockerfile
grep -Fq '"$CROSS_IMAGE" "$CUDA_COMPUTE_CAP"' jetsonctl
grep -Fq 'sm_${cap}' gates/audit-cross-image.sh
echo 'generic cross sm87/sm110: PASS'

python3 - <<'PY'
import yaml
with open('flash/compose.yaml', encoding='utf-8') as f:
    yaml.safe_load(f)
print('compose YAML: PASS')
PY

echo 'fix14 static/synthetic gates: PASS'
