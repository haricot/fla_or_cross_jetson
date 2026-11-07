#!/usr/bin/env bash
# Reproduce a small JetPack 7.2.1 ABI reference on a disposable x86_64 CI runner.
# Downloads signed Ubuntu noble ARM64 + NVIDIA r39.2 ARM64 APT packages only.
# No package is installed, no BSP is applied, and no device is flashed.
set -Eeuo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 OUTPUT_DIRECTORY" >&2
  exit 2
fi

out_dir=$(realpath -m -- "$1")
mkdir -p "$out_dir/debs" "$out_dir/sysroot" "$out_dir/evidence"
apt_workdir=$(mktemp -d)
chmod 755 "$apt_workdir"
mkdir -p "$apt_workdir/lists/partial" "$apt_workdir/archives/partial"
chmod 755 "$apt_workdir/lists" "$apt_workdir/lists/partial" "$apt_workdir/archives" "$apt_workdir/archives/partial"

# Import the vendor key only into a disposable local keyring; APT verifies
# repository Release signatures. No host-global trusted key is modified.
curl --fail --location --silent --show-error --retry 3 \
  https://repo.download.nvidia.com/jetson/jetson-ota-public.asc \
  | gpg --batch --yes --dearmor --output "$apt_workdir/nvidia-jetson.gpg"
gpg --show-keys --with-fingerprint "$apt_workdir/nvidia-jetson.gpg" > "$out_dir/evidence/nvidia-key.txt"

tee "$apt_workdir/sources.list" >/dev/null <<EOF
deb [arch=arm64 signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] https://ports.ubuntu.com/ubuntu-ports noble main universe
deb [arch=arm64 signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] https://ports.ubuntu.com/ubuntu-ports noble-updates main universe
deb [arch=arm64 signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] https://ports.ubuntu.com/ubuntu-ports noble-security main universe
deb [arch=arm64 signed-by=$apt_workdir/nvidia-jetson.gpg] https://repo.download.nvidia.com/jetson/common r39.2 main
deb [arch=arm64 signed-by=$apt_workdir/nvidia-jetson.gpg] https://repo.download.nvidia.com/jetson/som r39.2 main
EOF

apt_opts=(
  -o "Dir::Etc::sourcelist=$apt_workdir/sources.list"
  -o Dir::Etc::sourceparts=-
  -o "Dir::State::lists=$apt_workdir/lists"
  -o "Dir::Cache::archives=$apt_workdir/archives"
  -o APT::Architecture=arm64
  -o APT::Architectures=arm64
  -o Acquire::AllowInsecureRepositories=false
)

apt-get "${apt_opts[@]}" update
packages=(
  libc6 libgcc-s1 libstdc++6
  cuda-cudart-13-2 libcublas-13-2
  nvidia-l4t-cuda nvidia-l4t-cuda-nvgpu
)
apt-cache "${apt_opts[@]}" policy "${packages[@]}" > "$out_dir/evidence/apt-policy.txt"

# Guard against accidentally downloading gigabytes when NVIDIA changes a
# package. Only the small ABI subset is needed, not the full CUDA toolkit.
total_bytes=0
for pkg in "${packages[@]}"; do
  candidate_size=$(apt-cache "${apt_opts[@]}" show "${pkg}:arm64" | awk '/^Size:/{print $2; exit}')
  [[ "$candidate_size" =~ ^[0-9]+$ ]] || { echo "Missing APT size for $pkg" >&2; exit 1; }
  total_bytes=$((total_bytes + candidate_size))
done
echo "R4_P3_SIGNED_APT_DOWNLOAD_ESTIMATE_BYTES=$total_bytes"
(( total_bytes < 600 * 1024 * 1024 )) || { echo 'ABI subset exceeds 600 MiB safety limit' >&2; exit 1; }

pushd "$out_dir/debs" >/dev/null
for pkg in "${packages[@]}"; do
  apt-get "${apt_opts[@]}" download "${pkg}:arm64"
done

printf 'package\tversion\tarchitecture\tsha256\tfilename\n' > "$out_dir/evidence/package-manifest.tsv"
for archive in ./*.deb; do
  pkg=$(dpkg-deb --field "$archive" Package)
  ver=$(dpkg-deb --field "$archive" Version)
  arch=$(dpkg-deb --field "$archive" Architecture)
  [[ "$arch" == arm64 ]] || { echo "Non-ARM64 package: $archive" >&2; exit 1; }
  if [[ "$pkg" == nvidia-l4t-cuda || "$pkg" == nvidia-l4t-cuda-nvgpu ]]; then
    [[ "$ver" == 39.2.1-* ]] || { echo "Expected L4T 39.2.1, got $ver" >&2; exit 1; }
  fi
  if [[ "$pkg" == cuda-cudart-13-2 || "$pkg" == libcublas-13-2 ]]; then
    [[ "$ver" == 13.2.* ]] || { echo "Expected CUDA 13.2, got $ver" >&2; exit 1; }
  fi
  sha=$(sha256sum "$archive")
  printf '%s\t%s\t%s\t%s\t%s\n' "$pkg" "$ver" "$arch" "${sha%% *}" "${archive#./}" \
    >> "$out_dir/evidence/package-manifest.tsv"
  dpkg-deb --extract "$archive" "$out_dir/sysroot"
done
popd >/dev/null

test -e "$out_dir/sysroot/lib/aarch64-linux-gnu/libc.so.6" \
  || test -e "$out_dir/sysroot/usr/lib/aarch64-linux-gnu/libc.so.6"
test -n "$(find "$out_dir/sysroot" -name 'libcudart.so*' -print -quit)"
test -n "$(find "$out_dir/sysroot" -name 'libcublas.so*' -print -quit)"
test -n "$(find "$out_dir/sysroot" -name 'libcublasLt.so*' -print -quit)"
test -n "$(find "$out_dir/sysroot" -name 'libcuda.so*' -print -quit)"
tar -C "$out_dir/sysroot" -czf "$out_dir/jetpack721-thin-sysroot.tgz" .
echo "R4_P3_THIN_SYSROOT=PREPARED_SIGNED_APT_ARM64_JP721"
du -sh "$out_dir/sysroot" "$out_dir/debs" "$out_dir/jetpack721-thin-sysroot.tgz"
