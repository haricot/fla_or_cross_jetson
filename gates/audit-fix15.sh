#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

[[ "$(cat VERSION)" =~ ^2\.0\.0-alpha4-fix1[567]$ ]]
./gates/audit-fix14.sh >/dev/null
echo 'fix12/fix13/fix14 inheritance: PASS'

for f in jetsonctl lib/secrets.sh flash/headless.sh; do
  bash -n "$f"
done

echo 'shell syntax: PASS'

python3 - <<'PY'
import pathlib, tomllib
root = pathlib.Path('.')
spec = tomllib.loads((root/'secretspec.toml').read_text())
assert spec['project']['name'] == 'fla-or-cross-jetson'
assert spec['project']['revision'] == '1.0'
assert spec['project']['require_reason'] is True
assert spec['providers']['workstation'] == 'keyring://'
assert spec['providers']['runtime'] == 'systemd-credential://'
for profile in ('headless','cross','runtime'):
    defaults = spec['profiles'][profile]['defaults']
    assert defaults['inherit'] is False
    assert defaults['required'] is False
assert spec['profiles']['headless']['defaults']['providers'] == ['workstation']
assert {'JETSON_PASSWORD','WIFI_PSK'} <= set(spec['profiles']['headless'])
assert {'GITHUB_TOKEN','GHCR_TOKEN'} <= set(spec['profiles']['cross'])
assert spec['profiles']['runtime']['defaults']['providers'] == ['runtime']
assert {'HF_TOKEN','API_TOKEN'} <= set(spec['profiles']['runtime'])

cargo = tomllib.loads((root/'secret-plane/Cargo.toml').read_text())
deps = cargo['dependencies']
ss = deps['secretspec']
assert ss['version'] == '=0.20.0'
assert ss['default-features'] is False
assert ss['features'] == ['keyring']
assert deps['secrecy'] == '=0.10.3'
print('SecretSpec manifest/Cargo pins: PASS')
PY

grep -Fq 'pub trait SecretResolver' secret-plane/src/lib.rs
grep -Fq 'pub struct SecretSpecResolver' secret-plane/src/lib.rs
grep -Fq 'Secrets::load_from' secret-plane/src/lib.rs
grep -Fq '.resolve_named(name)' secret-plane/src/lib.rs
grep -Fq 'SecretString::from' secret-plane/src/lib.rs
grep -Fq 'ExposeSecret' secret-plane/src/main.rs
echo 'Rust SecretResolver/secrecy boundary: PASS'

# Headless integration: explicit source wins; SecretSpec values remain ephemeral;
# legacy sources are retained only as opt-in compatibility.
grep -Fq 'fix15 precedence: explicit CLI/file > SecretSpec/keyring > interactive password' flash/headless.sh
grep -Fq 'password_mode=secretspec' flash/headless.sh
grep -Fq 'wifi_source_mode=secretspec' flash/headless.sh
grep -Fq 'SecretSpec/keyring values are deliberately NEVER persisted' flash/headless.sh
grep -Fq 'if [[ "$password_mode" == file ]]' flash/headless.sh
grep -Fq 'if [[ "$wifi_source_mode" == openssl-file ]]' flash/headless.sh
grep -Fq 'elif [[ "$wifi_source_mode" == explicit-file ]]' flash/headless.sh
# A SecretSpec mode must use the staging mount, never /work/secrets.
grep -Fq 'secretspec) pfile="$container_stage/default-password"' flash/headless.sh
grep -Fq 'secretspec) wplain="$container_stage/wifi-psk"' flash/headless.sh
echo 'headless ephemeral-secret policy: PASS'

# Synthetic SecretSpec CLI: prove helper writes value only to a mode-0600 file
# and never emits the value itself through the helper's stdout.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/secretspec" <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${1:-}" == --version ]]; then echo 'secretspec 0.20.0'; exit 0; fi
case "${1:-}" in
  get)
    [[ "${2:-}" == WIFI_PSK ]] || exit 3
    printf '%s' 'synthetic-super-secret'
    ;;
  check) printf '%s\n' '{"ok":true}' ;;
  set) exit 0 ;;
  *) exit 2 ;;
esac
EOS
chmod +x "$tmp/secretspec"
ROOT="$ROOT" PATH="$tmp:$PATH" SECRETSPEC_FILE="$ROOT/secretspec.toml" bash -c '
  set -Eeuo pipefail
  source "$ROOT/lib/secrets.sh"
  out="$1/value"
  noise=$(secret_plane_get_to_file WIFI_PSK "$out" headless keyring synthetic-test)
  [[ -z "$noise" ]]
  [[ "$(cat "$out")" == synthetic-super-secret ]]
  [[ "$(stat -c %a "$out")" == 600 ]]
' _ "$tmp"
echo 'SecretSpec staged-file synthetic gate: PASS'

# fix15 CLI surface.
grep -Fq 'secrets install' jetsonctl
grep -Fq 'secrets doctor' jetsonctl
grep -Fq 'secrets set-password' jetsonctl
grep -Fq 'secrets set-wifi' jetsonctl
grep -Fq 'systemd-credential' jetsonctl
echo 'secret-plane CLI surface: PASS'

# Confirm all real flash reliability fixes are still inherited.
grep -Fq '100003' host/nfs-guard.sh
grep -Fq '100005' host/nfs-guard.sh
grep -Fq 'fc00:1:1:0::1/64' host/usb-guard.sh
grep -Fq 'fe80::2/64' host/usb-guard.sh
grep -Fq 'firewall-cmd' host/usb-guard.sh
echo 'NFS/IPv6/firewalld inheritance: PASS'

if command -v cargo >/dev/null 2>&1; then
  cargo check --manifest-path secret-plane/Cargo.toml
  echo 'Rust resolver compile: PASS'
else
  echo 'Rust resolver compile: SKIP (cargo unavailable in audit environment)'
fi

echo 'fix15 static/synthetic gates: PASS'
