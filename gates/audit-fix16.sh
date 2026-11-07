#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

[[ "$(cat VERSION)" =~ ^2\.0\.0-alpha4-fix1[67]$ ]]
./gates/audit-fix15.sh >/dev/null
echo 'fix12..fix15 inheritance: PASS'

for f in jetsonctl lib/secrets.sh flash/headless.sh; do bash -n "$f"; done

grep -Fq -- '--secret-settings' flash/headless.sh
grep -Fq -- '--secret_settings' flash/headless.sh
grep -Fq 'secret_settings_apply()' flash/headless.sh
grep -Fq 'secret_plane_resolver_needs_build' flash/headless.sh
grep -Fq 'run_secret_ctl build-resolver' flash/headless.sh
grep -Fq 'run_secret_ctl install' flash/headless.sh
grep -Fq 'run_secret_ctl status' flash/headless.sh
grep -Fq 'run_secret_ctl doctor' flash/headless.sh
grep -Fq 'already present (value hidden); keep existing' flash/headless.sh
grep -Fq 'WOULD PROMPT+STORE' flash/headless.sh
grep -Fq 'dry_run == 1 && secret_settings == 1' flash/headless.sh
grep -Fq 'SecretSpec/keyring values are deliberately NEVER persisted' flash/headless.sh
grep -Fq 'secret_plane_resolver_needs_build()' lib/secrets.sh
grep -Fq 'secret_plane_cli_020_ok()' lib/secrets.sh
echo 'fix16 secret-settings static surface: PASS'

# The alias and the canonical spelling must both be visible.
./jetsonctl headless-flash --help | grep -Fq -- '--secret-settings'
./jetsonctl headless-flash --help | grep -Fq -- '--secret_settings'

# Conflict must fail before any host/Docker preflight.
if ./jetsonctl headless-flash --secret-settings --no-secret-plane --dry-run >/tmp/fix16-conflict.out 2>&1; then
  echo 'FAIL: secret-settings/no-secret-plane conflict accepted' >&2
  exit 1
fi
grep -Fq -- '--secret-settings est incompatible avec --no-secret-plane' /tmp/fix16-conflict.out
rm -f /tmp/fix16-conflict.out
echo 'fix16 option/conflict gate: PASS'

# Resolver freshness helper: absent -> build; newer binary -> no build; modified
# source -> build again.
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
mkdir -p "$t/secret-plane/src" "$t/secret-plane/target/release"
printf '[package]\n' > "$t/secret-plane/Cargo.toml"
printf 'pub fn x(){}\n' > "$t/secret-plane/src/lib.rs"
printf 'fn main(){}\n' > "$t/secret-plane/src/main.rs"
ROOT="$t" bash -c '
  set -Eeuo pipefail
  source "$1/lib/secrets.sh"
  secret_plane_resolver_needs_build
' _ "$ROOT"
printf '#!/bin/sh\nexit 0\n' > "$t/secret-plane/target/release/jetson-secret-resolver"
chmod +x "$t/secret-plane/target/release/jetson-secret-resolver"
touch -d '2030-01-01 00:00:00' "$t/secret-plane/target/release/jetson-secret-resolver"
ROOT="$t" bash -c '
  set -Eeuo pipefail
  source "$1/lib/secrets.sh"
  ! secret_plane_resolver_needs_build
' _ "$ROOT"
touch -d '2031-01-01 00:00:00' "$t/secret-plane/src/main.rs"
ROOT="$t" bash -c '
  set -Eeuo pipefail
  source "$1/lib/secrets.sh"
  secret_plane_resolver_needs_build
' _ "$ROOT"
echo 'resolver freshness gate: PASS'

# Full synthetic headless execution. Fake SecretSpec/keyring starts empty; the
# option must create both needed secrets, then resolve them ephemerally, run
# status+doctor and complete the stub flash without persisting either value in
# VOLUME/secrets.
sim="$t/simroot"
cp -a "$ROOT/." "$sim/"
state="$t/keyring"
vol="$t/volume"
bin="$t/bin"
mkdir -p "$state" "$vol/downloads/Linux_for_Tegra/rootfs/usr" "$vol/downloads/Linux_for_Tegra/rootfs/etc" "$vol/custom" "$bin"
printf 'NAME=Ubuntu\n' > "$vol/downloads/Linux_for_Tegra/rootfs/etc/os-release"
printf '# R39 (release), REVISION: 2.1\n' > "$vol/downloads/Linux_for_Tegra/rootfs/etc/nv_tegra_release"

cat > "$bin/secretspec" <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${1:-}" == --version ]]; then echo 'secretspec 0.20.0'; exit 0; fi
case "${1:-}" in
  set)
    name=${2:?}
    mkdir -p "$FAKE_SECRET_STATE"
    printf 'synthetic-%s' "$name" > "$FAKE_SECRET_STATE/$name"
    chmod 600 "$FAKE_SECRET_STATE/$name"
    ;;
  check) printf '%s\n' '{"ok":true}' ;;
  get)
    name=${2:?}; cat "$FAKE_SECRET_STATE/$name"
    ;;
  *) exit 2 ;;
esac
EOS
chmod +x "$bin/secretspec"

mkdir -p "$sim/secret-plane/target/release"
cat > "$sim/secret-plane/target/release/jetson-secret-resolver" <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
  get)
    name=${2:?}
    [[ -s "$FAKE_SECRET_STATE/$name" ]] || exit 3
    cat "$FAKE_SECRET_STATE/$name"
    ;;
  version) echo 'jetson-secret-resolver 0.1.0 secretspec 0.20.0' ;;
  *) exit 2 ;;
esac
EOS
chmod +x "$sim/secret-plane/target/release/jetson-secret-resolver"
touch -d '2035-01-01 00:00:00' "$sim/secret-plane/target/release/jetson-secret-resolver"

cat > "$sim/flash/host-preflight.sh" <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
echo '=== HOST FLASH PREFLIGHT ==='
echo 'Docker: PASS'
echo 'Smart Host Guard: PASS'
echo 'Jetson recovery USB: NOT DETECTED'
EOS
chmod +x "$sim/flash/host-preflight.sh"

cat > "$sim/jetsonctl" <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
  secrets)
    case "${2:-}" in
      status) echo 'JETSON_PASSWORD present (value hidden)'; echo 'WIFI_PSK present (value hidden)' ;;
      doctor) echo 'SecretSpec resolver: PASS'; echo 'keyring provider/preflight: PASS' ;;
      build-resolver|install) echo "UNEXPECTED ${2}" >&2; exit 91 ;;
      *) exit 2 ;;
    esac
    ;;
  flash)
    case "${2:-}" in
      image-status) echo READY ;;
      plan)
        echo 'native_cuda wanted=native'
        echo 'native_cuda applied=native'
        echo 'images=fresh'
        echo 'user wanted=user'
        echo 'user applied=user'
        ;;
      nvme|internal) echo 'SYNTHETIC FLASH PASS' ;;
      *) : ;;
    esac
    ;;
  custom)
    [[ "${2:-}" == status ]] && echo 'custom: APPLIED' || :
    ;;
  native-sdk)
    [[ "${2:-}" == status ]] && echo 'native CUDA SDK: APPLIED' || :
    ;;
  *) : ;;
esac
EOS
chmod +x "$sim/jetsonctl"

FAKE_SECRET_STATE="$state" PATH="$bin:$PATH" VOLUME="$vol" \
  "$sim/flash/headless.sh" \
    --platform orin-nano-super \
    --volume "$vol" \
    --secret-settings \
    --user np \
    --hostname jetson-orin \
    --flash-target nvme \
    --wifi-ssid T6r2 \
    --no-auto-recovery \
    --yes > "$t/headless.out"

grep -Fq '=== FIX16 HEADLESS SECRET SETTINGS ===' "$t/headless.out"
grep -Fq 'JETSON_PASSWORD: STORED (value hidden)' "$t/headless.out"
grep -Fq 'WIFI_PSK: STORED (value hidden)' "$t/headless.out"
grep -Fq '=== SECRET STATUS ===' "$t/headless.out"
grep -Fq '=== SECRET PLANE DOCTOR ===' "$t/headless.out"
grep -Fq 'settings            ready' "$t/headless.out"
grep -Fq 'SYNTHETIC FLASH PASS' "$t/headless.out"
[[ -s "$state/JETSON_PASSWORD" && -s "$state/WIFI_PSK" ]]
[[ ! -e "$vol/secrets/default-password" ]]
[[ ! -e "$vol/secrets/wifi-psk" ]]
[[ ! -e "$vol/secrets/wifi-psk.enc" ]]
# staging must be gone after EXIT trap.
! find "$vol/tmp" -maxdepth 1 -type d -name 'headless-stage.*' | grep -q .
echo 'fix16 synthetic headless secret bootstrap: PASS'

# Second run is idempotent: both keyring entries already exist, so neither is
# requested again.
FAKE_SECRET_STATE="$state" PATH="$bin:$PATH" VOLUME="$vol" \
  "$sim/flash/headless.sh" \
    --platform orin-nano-super \
    --volume "$vol" \
    --secret-settings \
    --user np \
    --hostname jetson-orin \
    --flash-target nvme \
    --wifi-ssid T6r2 \
    --no-auto-recovery \
    --yes > "$t/headless-second.out"
grep -Fq 'JETSON_PASSWORD: already present (value hidden); keep existing' "$t/headless-second.out"
grep -Fq 'WIFI_PSK: already present (value hidden); keep existing' "$t/headless-second.out"
! grep -Fq 'JETSON_PASSWORD: STORED' "$t/headless-second.out"
! grep -Fq 'WIFI_PSK: STORED' "$t/headless-second.out"
echo 'fix16 secret-settings idempotence: PASS'

# Dry-run is strictly read-only even when both secrets are absent.
state_dry="$t/keyring-dry"
vol_dry="$t/volume-dry"
mkdir -p "$state_dry" "$vol_dry"
FAKE_SECRET_STATE="$state_dry" PATH="$bin:$PATH" VOLUME="$vol_dry" \
  "$sim/flash/headless.sh" \
    --platform orin-nano-super \
    --volume "$vol_dry" \
    --secret-settings \
    --user np \
    --hostname jetson-orin \
    --flash-target nvme \
    --wifi-ssid T6r2 \
    --no-auto-recovery \
    --dry-run > "$t/headless-dry.out"
grep -Fq 'WOULD PROMPT+STORE' "$t/headless-dry.out"
grep -Fq 'settings            planned' "$t/headless-dry.out"
[[ ! -e "$state_dry/JETSON_PASSWORD" && ! -e "$state_dry/WIFI_PSK" ]]
echo 'fix16 secret-settings dry-run non-mutation: PASS'

# All the actual flash reliability gates remain inherited.
grep -Fq '100003' host/nfs-guard.sh
grep -Fq '100005' host/nfs-guard.sh
grep -Fq 'fc00:1:1:0::1/64' host/usb-guard.sh
grep -Fq 'fe80::2/64' host/usb-guard.sh
grep -Fq 'firewall-cmd' host/usb-guard.sh
echo 'NFS/IPv6/firewalld inheritance: PASS'

echo 'fix16 gates: PASS'
