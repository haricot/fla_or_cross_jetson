#!/usr/bin/env bash
# Extract x86_64 cuobjdump from NVIDIA's signed JetPack 7.2.1 host APT repo.
# Never installs NVIDIA packages or alters global APT configuration.
set -Eeuo pipefail
if [[ $# -ne 1 ]]; then
  echo 'Usage: prepare_host_cuobjdump.sh OUTPUT_DIRECTORY' >&2
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
deb [arch=amd64 signed-by=$temp_apt/nvidia.gpg] https://repo.download.nvidia.com/jetson/x86_64/noble r39.2 main
EOF
apt_opts=(
  -o "Dir::Etc::sourcelist=$temp_apt/sources.list"
  -o Dir::Etc::sourceparts=-
  -o "Dir::State::lists=$temp_apt/lists"
  -o "Dir::Cache::archives=$temp_apt/archives"
  -o APT::Architecture=amd64
  -o APT::Architectures=amd64
  -o Acquire::AllowInsecureRepositories=false
)
apt-get "${apt_opts[@]}" update
apt-cache "${apt_opts[@]}" policy cuda-cuobjdump-13-2 > "$out/evidence/cuobjdump-apt-policy.txt"
size=$(apt-cache "${apt_opts[@]}" show cuda-cuobjdump-13-2:amd64 | awk '/^Size:/{print $2; exit}')
[[ "$size" =~ ^[0-9]+$ ]] && (( size < 150 * 1024 * 1024 )) || {
  echo 'R4_P4_REJECT=CUOBJDUMP_UNAVAILABLE_OR_OVERSIZE' >&2
  exit 1
}
pushd "$out/debs" >/dev/null
apt-get "${apt_opts[@]}" download cuda-cuobjdump-13-2:amd64
archive=$(find . -maxdepth 1 -type f -name '*.deb' -print -quit)
test -n "$archive"
version=$(dpkg-deb --field "$archive" Version)
[[ "$version" == 13.2.* ]] || {
  echo "R4_P4_REJECT=WRONG_CUOBJDUMP_VERSION_$version" >&2
  exit 1
}
sha256sum "$archive" > "$out/evidence/cuobjdump-deb-sha256.txt"
dpkg-deb --extract "$archive" "$out/extracted"
popd >/dev/null
cuobjdump=$(find "$out/extracted" -type f -name cuobjdump -print -quit)
test -n "$cuobjdump"
chmod +x "$cuobjdump"
"$cuobjdump" --help >/dev/null
printf 'R4_P4_HOST_CUOBJDUMP=VERIFIED_SIGNED_AMD64_13_2 version=%s\n' "$version"
printf '%s\n' "$cuobjdump" > "$out/evidence/cuobjdump-path.txt"
