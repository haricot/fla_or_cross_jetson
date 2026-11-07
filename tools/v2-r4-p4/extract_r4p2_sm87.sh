#!/usr/bin/env bash
# Extract *actual* SM87 GPU ELF from the existing R4-P2 AArch64 host binary.
set -Eeuo pipefail
if [[ $# -ne 3 ]]; then
  echo 'Usage: extract_r4p2_sm87.sh CUOBJDUMP R4_P2_AARCH64_ELF OUTPUT_CUBIN' >&2
  exit 2
fi
tool=$(realpath -- "$1")
source_elf=$(realpath -- "$2")
out=$(realpath -m -- "$3")
test -x "$tool" && test -s "$source_elf"
readelf -h "$source_elf" | grep -Eq 'Machine:.*AArch64'
mkdir -p "$(dirname "$out")"
extraction=$(mktemp -d)

"$tool" --list-elf "$source_elf" | tee "$(dirname "$out")/original-fatbin.txt"
grep -q 'sm_87' "$(dirname "$out")/original-fatbin.txt"
pushd "$extraction" >/dev/null
"$tool" --extract-elf all "$source_elf"
mapfile -t candidates < <(find . -maxdepth 1 -type f -name '*sm_87*.cubin' -print)
if (( ${#candidates[@]} != 1 )); then
  echo "R4_P4_REJECT=SM87_CUBIN_COUNT_${#candidates[@]}" >&2
  find . -maxdepth 1 -type f -print >&2
  exit 1
fi
readelf -Ws "${candidates[0]}" | grep -q '_Z5saxpyifPfS_'
cp -- "${candidates[0]}" "$out"
popd >/dev/null
sha256sum "$source_elf" "$out"
echo 'R4_P4_REUSED_R4_P2_SM87_CUBIN=PASS_EXTRACTED_NO_NVCC'
