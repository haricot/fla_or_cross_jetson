#!/usr/bin/env bash
# SecretSpec 0.20 secret-plane glue. This file never logs secret values.

: "${SECRET_PLANE_PROVIDER:=keyring}"
: "${SECRET_PLANE_PROFILE:=headless}"
: "${SECRET_PLANE_REASON:=fla-or-cross-jetson}"

secret_plane_manifest() {
  printf '%s\n' "${SECRETSPEC_FILE:-$ROOT/secretspec.toml}"
}

secret_plane_resolver_path() {
  printf '%s\n' "$ROOT/secret-plane/target/release/jetson-secret-resolver"
}

secret_plane_resolver_needs_build() {
  local bin src
  bin=$(secret_plane_resolver_path)
  [[ -x "$bin" ]] || return 0
  for src in \
    "$ROOT/secret-plane/Cargo.toml" \
    "$ROOT/secret-plane/Cargo.lock" \
    "$ROOT/secret-plane/src/lib.rs" \
    "$ROOT/secret-plane/src/main.rs"; do
    [[ -e "$src" && "$src" -nt "$bin" ]] && return 0
  done
  return 1
}

secret_plane_cli_020_ok() {
  local version
  version=$(secret_plane_cli_version 2>/dev/null || true)
  [[ "$version" =~ (^|[[:space:]])0\.20\.[0-9]+([[:space:]]|$) ]]
}

secret_plane_resolver_bin() {
  local candidate="${JETSON_SECRET_RESOLVER_BIN:-}"
  if [[ -n "$candidate" && -x "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  candidate="$ROOT/secret-plane/target/release/jetson-secret-resolver"
  if [[ -x "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  return 1
}

secret_plane_cli_version() {
  command -v secretspec >/dev/null 2>&1 || return 1
  secretspec --version 2>/dev/null | head -n1
}

secret_plane_available() {
  secret_plane_resolver_bin >/dev/null 2>&1 && return 0
  local version
  version=$(secret_plane_cli_version 2>/dev/null || true)
  [[ "$version" =~ (^|[[:space:]])0\.20\.[0-9]+([[:space:]]|$) ]]
}

secret_plane_get_to_file() {
  local name=$1 out=$2
  local profile=${3:-$SECRET_PLANE_PROFILE}
  local provider=${4:-$SECRET_PLANE_PROVIDER}
  local reason=${5:-$SECRET_PLANE_REASON}
  local manifest tmp resolver
  manifest=$(secret_plane_manifest)
  [[ -r "$manifest" ]] || return 4
  mkdir -p "$(dirname "$out")"
  umask 077
  tmp="${out}.tmp.$$"
  rm -f "$tmp"

  if resolver=$(secret_plane_resolver_bin 2>/dev/null); then
    if ! "$resolver" get "$name" \
      --manifest "$manifest" --provider "$provider" --profile "$profile" --reason "$reason" \
      >"$tmp"; then
      rm -f "$tmp"
      return 3
    fi
  elif secret_plane_available; then
    if ! env \
      SECRETSPEC_FILE="$manifest" \
      SECRETSPEC_PROVIDER="$provider" \
      SECRETSPEC_PROFILE="$profile" \
      SECRETSPEC_REASON="$reason" \
      secretspec get "$name" >"$tmp"; then
      rm -f "$tmp"
      return 3
    fi
  else
    rm -f "$tmp"
    return 127
  fi

  [[ -s "$tmp" ]] || { rm -f "$tmp"; return 3; }
  chmod 600 "$tmp"
  mv -f "$tmp" "$out"
  chmod 600 "$out"
}

secret_plane_probe() {
  local name=$1 profile=${2:-$SECRET_PLANE_PROFILE} provider=${3:-$SECRET_PLANE_PROVIDER}
  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/fla-secret-probe.XXXXXX")
  chmod 600 "$tmp"
  if secret_plane_get_to_file "$name" "$tmp" "$profile" "$provider" "secret-probe" >/dev/null 2>&1; then
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

secret_plane_set() {
  local name=$1 profile=${2:-$SECRET_PLANE_PROFILE} provider=${3:-$SECRET_PLANE_PROVIDER}
  local manifest
  manifest=$(secret_plane_manifest)
  command -v secretspec >/dev/null 2>&1 || {
    echo "SecretSpec CLI 0.20.x requis; lance: ./jetsonctl secrets install" >&2
    return 127
  }
  env \
    SECRETSPEC_FILE="$manifest" \
    SECRETSPEC_PROVIDER="$provider" \
    SECRETSPEC_PROFILE="$profile" \
    SECRETSPEC_REASON="secret-provision" \
    secretspec set "$name"
}

secret_plane_status_line() {
  local name=$1 profile=${2:-headless} provider=${3:-keyring}
  if ! secret_plane_available; then
    printf '%-20s %s\n' "$name" 'UNKNOWN (SecretSpec unavailable)'
  elif secret_plane_probe "$name" "$profile" "$provider"; then
    printf '%-20s %s\n' "$name" 'present (value hidden)'
  else
    printf '%-20s %s\n' "$name" 'absent'
  fi
}
