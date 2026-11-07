#!/usr/bin/env bash
# Download official JetPack CUDA 13.2 ARM64 *link-time* libcuda stub.
# This library must never be shipped or used on the device at runtime.
set -Eeuo pipefail
if [[ $# -ne 1 ]]; then
  echo 'Usage: prepare_driver_link_stub.sh OUTPUT_DIRECTORY' >&2
  exit 2
fi
out=$(realpath -m -- "$1")
mkdir -p "$out/debs" "$out/extracted" "$out/evidence"
temp_apt=$(mktemp -d)
chmod 755 "$temp_apt"
mkdir -p "$temp_apt/lists/partial" "$temp_apt/archives/partial"
chmod 755 "$temp_apt/lists" "$temp_apt/lists/partial" "$temp_apt/archives" "$temp_apt/archives/partial"
curl --fail --location --silent --show-error --retry 3 \
  https://repo.download.nvidia.com/jetson/jetson-ota-public.asc \
  | gpg --batch --yes --dearmor --output "$temp_apt/nvidia.gpg"
tee "$temp_apt/sources.list" >/dev/null <<EOF
deb [arch=arm64 signed-by=$temp_apt/nvidia.gpg] https://repo.download.nvidia.com/jetson/common r39.2 main
EOF
apt_opts=(
  -o "Dir::Etc::sourcelist=$temp_apt/sources.list"
  -o Dir::Etc::sourceparts=-
  -o "Dir::State::lists=$temp_apt/lists"
  -o "Dir::Cache::archives=$temp_apt/archives"
  -o APT::Architecture=arm64
  -o APT::Architectures=arm64
  -o Acquire::AllowInsecureRepositories=false
)
apt-get "${apt_opts[@]}" update
apt-cache "${apt_opts[@]}" policy cuda-driver-dev-13-2 > "$out/evidence/driver-dev-apt-policy.txt"
size=$(apt-cache "${apt_opts[@]}" show cuda-driver-dev-13-2:arm64 | awk '/^Size:/{print $2; exit}')
[[ "$size" =~ ^[0-9]+$ ]] && (( size < 50 * 1024 * 1024 )) || {
  echo 'R4_P4_REJECT=DRIVER_STUB_UNAVAILABLE_OR_OVERSIZE' >&2
  exit 1
}
pushd "$out/debs" >/dev/null
apt-get "${apt_opts[@]}" download cuda-driver-dev-13-2:arm64
archive=$(find . -maxdepth 1 -type f -name '*.deb' -print -quit)
test -n "$archive"
version=$(dpkg-deb --field "$archive" Version)
[[ "$version" == 13.2.* ]] || {
  echo "R4_P4_REJECT=WRONG_DRIVER_STUB_VERSION_$version" >&2
  exit 1
}
sha256sum "$archive" > "$out/evidence/driver-dev-deb-sha256.txt"
dpkg-deb --extract "$archive" "$out/extracted"
popd >/dev/null
stub=$(find "$out/extracted" -name libcuda.so -print -quit)
test -n "$stub" && test -e "$stub"
readelf -h "$stub" | grep -Eq 'Machine:.*AArch64'
readelf -d "$stub" | grep -q 'SONAME.*\[libcuda.so.1\]'
printf '%s\n' "$stub" > "$out/evidence/stub-path.txt"
printf 'R4_P4_DRIVER_LINK_STUB=VERIFIED_SIGNED_ARM64_13_2 version=%s\n' "$version"
