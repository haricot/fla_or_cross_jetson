#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/lib/platform.sh"
source "$ROOT/lib/secrets.sh"

# Direct invocation compatibility: jetsonctl consumes --platform globally, but
# flash/headless.sh also accepts it when called directly.
HEADLESS_PLATFORM_CLI=""
_headless_args=()
while (($#)); do
  case "$1" in
    --platform)
      [[ $# -ge 2 ]] || { echo '--platform demande NAME' >&2; exit 2; }
      HEADLESS_PLATFORM_CLI=$2; shift 2 ;;
    *) _headless_args+=("$1"); shift ;;
  esac
done
set -- "${_headless_args[@]}"
unset _headless_args
platform_load "$ROOT" "$HEADLESS_PLATFORM_CLI"

usage() {
  cat <<'USAGE'
usage: ./jetsonctl headless-flash [options]

Orchestre le parcours headless complet sans dupliquer les backends flash/custom:
  preflight/status -> confirmation y/N -> custom -> user -> images -> flash

Options:
  --platform NAME                 profil matériel intégré (défaut: orin-nano-super)
  --nvidia-board-config NAME      override avancé du board config NVIDIA
  --volume PATH                    stockage persistant V2
  --locale LOCALE                  ex. fr_FR.UTF-8
  --keyboard LAYOUT                ex. fr
  --user NAME                      utilisateur Jetson; vide = conserver oem-config
  --hostname NAME                  hostname Jetson
  --autologin [0|1]                active l'autologin; sans valeur = 1
  --no-autologin                   désactive l'autologin
  --flash-target nvme|internal     cible de flash
  --download-provider NAME         direct (défaut), sdkmanager ou local

  --auto-recovery                  si L4T USB est booté, demande Force Recovery par SSH (défaut)
  --no-auto-recovery               désactive la bascule logicielle vers APX/RCM
  --recovery-ssh-host HOST         cible SSH actuelle (défaut: 192.168.55.1 USB gadget)
  --recovery-ssh-user USER         utilisateur SSH du système actuellement booté
  --recovery-ssh-key PATH          clé privée SSH du système actuel (jamais copiée dans VOLUME)

  --password-interactive           force la saisie masquée sur /dev/tty
  --password-file PATH             source fichier explicite legacy/non-interactive
  --password-secret NAME           SecretSpec key (défaut: JETSON_PASSWORD)

  --secret-provider PROVIDER       provider SecretSpec host (défaut: keyring)
  --secret-profile PROFILE         profil SecretSpec headless (défaut: headless)
  --secret-settings                prépare automatiquement le Secret Plane requis avant le preflight
  --secret_settings                alias de compatibilité de --secret-settings
  --no-secret-plane                désactive la résolution SecretSpec pour ce flash

  --ssh-public-key-file PATH       clé publique à installer
  --ssh-key-only                   désactive l'auth SSH par mot de passe
  --sudo-nopasswd                  sudo sans mot de passe

  --wifi-ssid SSID                 SSID Wi-Fi
  --wifi-psk-secret NAME           SecretSpec key (défaut: WIFI_PSK)
  --wifi-psk-openssl-file PATH     source OpenSSL legacy
  --wifi-psk-file PATH             source fichier clair explicite legacy

  --native-cuda-sdk                installe CUDA 13.3 + paquet de compatibilité plateforme (défaut)
  --no-native-cuda-sdk             n'installe pas le toolkit CUDA natif dans l'image Jetson

  --dry-run                        affiche status et plan, ne modifie rien et ne flashe rien
  --yes                            saute seulement la confirmation y/N; les secrets interactifs restent interactifs
  -h, --help                       aide

Alias de compatibilité:
  --interactive-create-user-password
  --interactive-create-user_password

Exemple:
  ./jetsonctl headless-flash \
    --platform orin-nano-super \
    --volume "$VOLUME" \
    --locale fr_FR.UTF-8 \
    --keyboard fr \
    --user jetson \
    --hostname jetson-orin \
    --autologin 1 \
    --flash-target nvme \
    --ssh-public-key-file ~/.ssh/id_ed25519.pub \
    --ssh-key-only \
    --wifi-ssid MonReseau

Préparation automatique optionnelle (aucune valeur secrète dans argv):
  --secret-settings

Ou préparation manuelle:
  ./jetsonctl secrets set-password
  ./jetsonctl secrets set-wifi
USAGE
}

fail() { echo "headless-flash: $*" >&2; exit 1; }
yn() { [[ "$1" == 1 || "$1" == true || "$1" == yes ]]; }

VOLUME=${VOLUME:-$HOME/.cache/fla_or_cross_jetson/$PROFILE_NAME}
locale=${DEFAULT_LOCALE:-fr_FR.UTF-8}
keyboard=${DEFAULT_KEYBOARD:-fr}
user=${DEFAULT_USER:-}
hostname=${DEFAULT_HOSTNAME:-jetson-orin}
autologin=${DEFAULT_AUTOLOGIN:-0}
flash_target=${FLASH_TARGET:-nvme}
download_provider=${DOWNLOAD_PROVIDER:-direct}
ssh_key_only=${DEFAULT_SSH_KEY_ONLY:-0}
sudo_nopasswd=${DEFAULT_SUDO_NOPASSWD:-0}
wifi_ssid=${DEFAULT_WIFI_SSID:-}
secret_plane_enable=${SECRET_PLANE_ENABLE:-1}
secret_settings=0
secret_settings_state=disabled
secret_provider=${SECRET_PLANE_PROVIDER:-keyring}
secret_profile=${SECRET_PLANE_PROFILE:-headless}
password_secret_name=${JETSON_PASSWORD_SECRET:-JETSON_PASSWORD}
wifi_secret_name=${WIFI_PSK_SECRET:-WIFI_PSK}
secret_reason=${SECRET_PLANE_REASON:-headless-flash:${PLATFORM_NAME:-unknown}}
native_cuda_enable=${NATIVE_CUDA_ENABLE:-1}
profile_board=${BOARD}
board_config=${BOARD}
auto_force_recovery=${AUTO_FORCE_RECOVERY:-1}
recovery_ssh_host=${RECOVERY_SSH_HOST:-192.168.55.1}
recovery_ssh_user=${RECOVERY_SSH_USER:-}
recovery_ssh_identity=${RECOVERY_SSH_IDENTITY:-}

password_mode=auto
password_file_host=""
ssh_key_host=""
wifi_enc_host=""
wifi_plain_host=""
wifi_source_mode=none
password_secret_resolved=0
wifi_secret_resolved=0
dry_run=0
yes_mode=0

while (($#)); do
  case "$1" in
    --volume) [[ $# -ge 2 ]] || fail "--volume demande PATH"; VOLUME=$2; shift 2 ;;
    --nvidia-board-config) [[ $# -ge 2 ]] || fail "--nvidia-board-config demande NAME"; board_config=$2; shift 2 ;;
    --locale) [[ $# -ge 2 ]] || fail "--locale demande une valeur"; locale=$2; shift 2 ;;
    --keyboard) [[ $# -ge 2 ]] || fail "--keyboard demande une valeur"; keyboard=$2; shift 2 ;;
    --user) [[ $# -ge 2 ]] || fail "--user demande un nom"; user=$2; shift 2 ;;
    --hostname) [[ $# -ge 2 ]] || fail "--hostname demande un nom"; hostname=$2; shift 2 ;;
    --autologin)
      if [[ $# -ge 2 && "${2:-}" =~ ^(0|1|true|false|yes|no)$ ]]; then autologin=$2; shift 2; else autologin=1; shift; fi
      ;;
    --no-autologin) autologin=0; shift ;;
    --flash-target) [[ $# -ge 2 ]] || fail "--flash-target demande nvme|internal"; flash_target=$2; shift 2 ;;
    --download-provider) [[ $# -ge 2 ]] || fail "--download-provider demande direct|sdkmanager|local"; download_provider=$2; shift 2 ;;
    --auto-recovery) auto_force_recovery=1; shift ;;
    --no-auto-recovery) auto_force_recovery=0; shift ;;
    --recovery-ssh-host) [[ $# -ge 2 ]] || fail "--recovery-ssh-host demande HOST"; recovery_ssh_host=$2; shift 2 ;;
    --recovery-ssh-user) [[ $# -ge 2 ]] || fail "--recovery-ssh-user demande USER"; recovery_ssh_user=$2; shift 2 ;;
    --recovery-ssh-key) [[ $# -ge 2 ]] || fail "--recovery-ssh-key demande PATH"; recovery_ssh_identity=$2; shift 2 ;;
    --password-interactive|--interactive-create-user-password|--interactive-create-user_password)
      [[ "$password_mode" != file ]] || fail "utilise soit --password-interactive soit --password-file"
      password_mode=interactive; shift
      ;;
    --password-file)
      [[ $# -ge 2 ]] || fail "--password-file demande PATH"
      [[ "$password_mode" != interactive ]] || fail "utilise soit --password-interactive soit --password-file"
      password_mode=file; password_file_host=$2; shift 2
      ;;
    --password-secret) [[ $# -ge 2 ]] || fail "--password-secret demande NAME"; password_secret_name=$2; shift 2 ;;
    --secret-provider) [[ $# -ge 2 ]] || fail "--secret-provider demande PROVIDER"; secret_provider=$2; shift 2 ;;
    --secret-profile) [[ $# -ge 2 ]] || fail "--secret-profile demande PROFILE"; secret_profile=$2; shift 2 ;;
    --secret-settings|--secret_settings) secret_settings=1; shift ;;
    --no-secret-plane) secret_plane_enable=0; shift ;;
    --ssh-public-key-file) [[ $# -ge 2 ]] || fail "--ssh-public-key-file demande PATH"; ssh_key_host=$2; shift 2 ;;
    --ssh-key-only) ssh_key_only=1; shift ;;
    --sudo-nopasswd) sudo_nopasswd=1; shift ;;
    --wifi-ssid) [[ $# -ge 2 ]] || fail "--wifi-ssid demande SSID"; wifi_ssid=$2; shift 2 ;;
    --wifi-psk-secret) [[ $# -ge 2 ]] || fail "--wifi-psk-secret demande NAME"; wifi_secret_name=$2; shift 2 ;;
    --wifi-psk-openssl-file)
      [[ $# -ge 2 ]] || fail "--wifi-psk-openssl-file demande PATH"
      [[ -z "$wifi_plain_host" ]] || fail "utilise soit --wifi-psk-openssl-file soit --wifi-psk-file"
      wifi_enc_host=$2; wifi_source_mode=openssl-file; shift 2
      ;;
    --wifi-psk-file)
      [[ $# -ge 2 ]] || fail "--wifi-psk-file demande PATH"
      [[ -z "$wifi_enc_host" ]] || fail "utilise soit --wifi-psk-openssl-file soit --wifi-psk-file"
      wifi_plain_host=$2; wifi_source_mode=explicit-file; shift 2
      ;;
    --native-cuda-sdk) native_cuda_enable=1; shift ;;
    --no-native-cuda-sdk) native_cuda_enable=0; shift ;;
    --dry-run) dry_run=1; shift ;;
    --yes|-y) yes_mode=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "option inconnue: $1" ;;
  esac
done

case "$flash_target" in nvme|internal) ;; *) fail "--flash-target doit être nvme ou internal" ;; esac
platform_target_allowed "$flash_target" "${PLATFORM_SUPPORTED_FLASH_TARGETS:-nvme,internal}"   || fail "--flash-target $flash_target non supporté par ${PLATFORM_NAME:-platform}; autorisés=${PLATFORM_SUPPORTED_FLASH_TARGETS:-nvme,internal}"
[[ "$board_config" =~ ^[A-Za-z0-9._+-]+$ ]] || fail "--nvidia-board-config contient des caractères invalides"
BOARD=$board_config
export BOARD
case "$download_provider" in direct|sdkmanager|local) ;; *) fail "--download-provider doit être direct, sdkmanager ou local" ;; esac
case "$autologin" in 1|true|yes) autologin=1 ;; 0|false|no) autologin=0 ;; *) fail "--autologin attend 0|1" ;; esac
case "$auto_force_recovery" in 1|true|yes) auto_force_recovery=1 ;; 0|false|no) auto_force_recovery=0 ;; *) fail "--auto-recovery attend booléen" ;; esac
case "$native_cuda_enable" in 1|true|yes) native_cuda_enable=1 ;; 0|false|no) native_cuda_enable=0 ;; *) fail "NATIVE_CUDA_ENABLE attend 0|1" ;; esac
case "$secret_plane_enable" in 1|true|yes) secret_plane_enable=1 ;; 0|false|no) secret_plane_enable=0 ;; *) fail "SECRET_PLANE_ENABLE attend 0|1" ;; esac
case "$secret_settings" in 1|true|yes) secret_settings=1 ;; 0|false|no) secret_settings=0 ;; *) fail "--secret-settings attend un booléen interne" ;; esac
if (( secret_settings == 1 && secret_plane_enable == 0 )); then fail "--secret-settings est incompatible avec --no-secret-plane"; fi
if (( secret_settings == 1 )) && [[ "$secret_provider" != keyring ]]; then
  fail "--secret-settings automatise uniquement le provider host writable keyring; provider demandé=$secret_provider"
fi
[[ "$password_secret_name" =~ ^[A-Z][A-Z0-9_]*$ ]] || fail "--password-secret: nom SecretSpec invalide"
[[ "$wifi_secret_name" =~ ^[A-Z][A-Z0-9_]*$ ]] || fail "--wifi-psk-secret: nom SecretSpec invalide"
[[ -n "$recovery_ssh_user" ]] || recovery_ssh_user=${user:-jetson}
if [[ -z "$recovery_ssh_identity" && -n "$ssh_key_host" && "$ssh_key_host" == *.pub && -r "${ssh_key_host%.pub}" ]]; then
  recovery_ssh_identity=${ssh_key_host%.pub}
fi

if [[ -z "$user" && "$password_mode" != auto ]]; then fail "une option de mot de passe demande aussi --user"; fi
if [[ "$ssh_key_only" == 1 && -z "$ssh_key_host" && ! -s "$VOLUME/secrets/authorized_key.pub" ]]; then
  fail "--ssh-key-only demande --ssh-public-key-file ou $VOLUME/secrets/authorized_key.pub"
fi
if [[ -z "$wifi_ssid" && ( -n "$wifi_enc_host" || -n "$wifi_plain_host" ) ]]; then fail "un PSK Wi-Fi demande aussi --wifi-ssid"; fi

for f in "$password_file_host" "$ssh_key_host" "$wifi_enc_host" "$wifi_plain_host" "$recovery_ssh_identity"; do
  [[ -z "$f" || -r "$f" ]] || fail "fichier introuvable ou illisible: $f"
done

run_secret_ctl() {
  env \
    VOLUME="$VOLUME" \
    SECRET_PLANE_PROVIDER="$secret_provider" \
    SECRET_PLANE_PROFILE="$secret_profile" \
    SECRET_PLANE_REASON="$secret_reason" \
    "$ROOT/jetsonctl" secrets "$@"
}

secret_settings_preview() {
  echo "=== SECRET SETTINGS PLAN (DRY-RUN) ==="
  if secret_plane_resolver_needs_build; then
    echo "resolver             WOULD BUILD"
  else
    echo "resolver             READY"
  fi
  if [[ -n "$user" && "$password_mode" == auto ]]; then
    if secret_plane_probe "$password_secret_name" "$secret_profile" "$secret_provider"; then
      echo "$password_secret_name     present (value hidden)"
    else
      echo "$password_secret_name     WOULD PROMPT+STORE"
    fi
  else
    echo "password secret      SKIP (no user or explicit password source)"
  fi
  if [[ -n "$wifi_ssid" && -z "$wifi_enc_host" && -z "$wifi_plain_host" ]]; then
    if secret_plane_probe "$wifi_secret_name" "$secret_profile" "$secret_provider"; then
      echo "$wifi_secret_name          present (value hidden)"
    else
      echo "$wifi_secret_name          WOULD PROMPT+STORE"
    fi
  else
    echo "Wi-Fi secret         SKIP (no SSID or explicit PSK source)"
  fi
  echo "status/doctor        WOULD RUN"
}

secret_settings_apply() {
  echo "=== FIX16 HEADLESS SECRET SETTINGS ==="

  echo
  echo "=== BUILD RUST SECRET RESOLVER ==="
  if secret_plane_resolver_needs_build; then
    run_secret_ctl build-resolver
  else
    echo "Secret resolver: READY (build not required)"
  fi

  local need_write=0
  if [[ -n "$user" && "$password_mode" == auto ]]; then
    if secret_plane_probe "$password_secret_name" "$secret_profile" "$secret_provider"; then
      echo
      echo "=== STORE JETSON PASSWORD ==="
      echo "$password_secret_name: already present (value hidden); keep existing"
    else
      need_write=1
    fi
  fi
  if [[ -n "$wifi_ssid" && -z "$wifi_enc_host" && -z "$wifi_plain_host" ]]; then
    if secret_plane_probe "$wifi_secret_name" "$secret_profile" "$secret_provider"; then
      echo
      echo "=== STORE WIFI PSK ==="
      echo "$wifi_secret_name: already present (value hidden); keep existing"
    else
      need_write=1
    fi
  fi

  # The Rust resolver is sufficient for reads. The SecretSpec CLI is installed
  # only when an interactive keyring write is actually needed.
  if (( need_write == 1 )); then
    [[ -r /dev/tty ]] || fail "--secret-settings doit créer un secret absent mais aucun TTY n'est disponible"
  fi
  if (( need_write == 1 )) && ! secret_plane_cli_020_ok; then
    echo
    echo "=== INSTALL SECRETSPEC 0.20.x FOR KEYRING WRITES ==="
    run_secret_ctl install
  fi

  if [[ -n "$user" && "$password_mode" == auto ]] && \
      ! secret_plane_probe "$password_secret_name" "$secret_profile" "$secret_provider"; then
    echo
    echo "=== STORE JETSON PASSWORD ==="
    secret_plane_set "$password_secret_name" "$secret_profile" "$secret_provider"
    secret_plane_probe "$password_secret_name" "$secret_profile" "$secret_provider" \
      || fail "$password_secret_name absent après SecretSpec set"
    echo "$password_secret_name: STORED (value hidden)"
  fi

  if [[ -n "$wifi_ssid" && -z "$wifi_enc_host" && -z "$wifi_plain_host" ]] && \
      ! secret_plane_probe "$wifi_secret_name" "$secret_profile" "$secret_provider"; then
    echo
    echo "=== STORE WIFI PSK ==="
    secret_plane_set "$wifi_secret_name" "$secret_profile" "$secret_provider"
    secret_plane_probe "$wifi_secret_name" "$secret_profile" "$secret_provider" \
      || fail "$wifi_secret_name absent après SecretSpec set"
    echo "$wifi_secret_name: STORED (value hidden)"
  fi

  echo
  echo "=== SECRET STATUS ==="
  run_secret_ctl status

  echo
  echo "=== SECRET PLANE DOCTOR ==="
  run_secret_ctl doctor
  secret_settings_state=ready
}

if (( secret_settings == 1 )); then
  if (( dry_run == 1 )); then
    secret_settings_state=planned
    secret_settings_preview
  else
    secret_settings_apply
  fi
fi

mkdir -p "$VOLUME" "$VOLUME/tmp"
stage="$VOLUME/tmp/headless-stage.$$"
mkdir -p "$stage"
chmod 700 "$stage"
cleanup() { rm -rf "$stage" 2>/dev/null || true; }
trap cleanup EXIT

# fix15 precedence: explicit CLI/file > SecretSpec/keyring > interactive password.
# Values resolved from SecretSpec live only in this 0700 staging directory and
# are deleted by the EXIT trap. They are never copied to VOLUME/secrets.
if [[ -n "$user" && "$password_mode" == auto ]]; then
  if (( secret_plane_enable == 1 )) && secret_plane_get_to_file \
      "$password_secret_name" "$stage/default-password" "$secret_profile" "$secret_provider" "$secret_reason" \
      >/dev/null 2>&1; then
    password_mode=secretspec
    password_file_host="$stage/default-password"
    password_secret_resolved=1
  else
    if (( dry_run == 1 && secret_settings == 1 )); then password_mode=secret-settings-pending; else password_mode=interactive; fi
  fi
fi

if [[ -n "$wifi_ssid" && -z "$wifi_enc_host" && -z "$wifi_plain_host" ]]; then
  if (( secret_plane_enable == 1 )) && secret_plane_get_to_file \
      "$wifi_secret_name" "$stage/wifi-psk" "$secret_profile" "$secret_provider" "$secret_reason" \
      >/dev/null 2>&1; then
    wifi_plain_host="$stage/wifi-psk"
    wifi_source_mode=secretspec
    wifi_secret_resolved=1
  elif [[ -s "$VOLUME/secrets/wifi-psk" ]]; then
    wifi_source_mode=persisted-plain
  elif [[ -s "$VOLUME/secrets/wifi-psk.enc" ]]; then
    wifi_source_mode=persisted-openssl
  else
    if (( dry_run == 1 && secret_settings == 1 )); then
      wifi_source_mode=secret-settings-pending
    else
      fail "--wifi-ssid: ${wifi_secret_name} absent du SecretSpec/keyring et aucune source legacy; lance ./jetsonctl secrets set-wifi ou utilise --secret-settings"
    fi
  fi
fi

stage_one() {
  local src=$1 name=$2 dst
  dst="$stage/$name"
  [[ -n "$src" ]] || return 0
  if [[ -e "$dst" && "$src" -ef "$dst" ]]; then
    chmod 600 "$dst"
    return 0
  fi
  cp -f -- "$src" "$dst"
  chmod 600 "$dst"
}
stage_one "$password_file_host" default-password
stage_one "$ssh_key_host" authorized_key.pub
stage_one "$wifi_enc_host" wifi-psk.enc
stage_one "$wifi_plain_host" wifi-psk

container_stage="/work/tmp/$(basename "$stage")"
password_container=""
ssh_container="/work/secrets/authorized_key.pub"
wifi_enc_container="/work/secrets/wifi-psk.enc"
wifi_plain_container=""

if [[ "$password_mode" == file || "$password_mode" == secretspec ]]; then password_container="$container_stage/default-password"; fi
if [[ -n "$ssh_key_host" ]]; then ssh_container="$container_stage/authorized_key.pub"; fi
if [[ -n "$wifi_enc_host" ]]; then wifi_enc_container="$container_stage/wifi-psk.enc"; fi
if [[ -n "$wifi_plain_host" ]]; then wifi_plain_container="$container_stage/wifi-psk"; wifi_enc_container=""; fi
if [[ -z "$wifi_enc_host" && -z "$wifi_plain_host" ]]; then
  if [[ -s "$VOLUME/secrets/wifi-psk" ]]; then wifi_plain_container=/work/secrets/wifi-psk; wifi_enc_container=""; fi
fi

run_ctl_stage() {
  env \
    PROFILE="$PROFILE" JETSON_PLATFORM="${PLATFORM_NAME:-${JETSON_PLATFORM:-}}" VOLUME="$VOLUME" \
    BOARD="$board_config" FLASH_TARGET="$flash_target" \
    DEFAULT_USER="$user" DEFAULT_HOSTNAME="$hostname" DEFAULT_AUTOLOGIN="$autologin" \
    DEFAULT_LOCALE="$locale" DEFAULT_KEYBOARD="$keyboard" \
    DEFAULT_PASSWORD_FILE="$password_container" \
    DEFAULT_SSH_AUTHORIZED_KEY_FILE="$ssh_container" DEFAULT_SSH_KEY_ONLY="$ssh_key_only" \
    DEFAULT_SUDO_NOPASSWD="$sudo_nopasswd" \
    DEFAULT_WIFI_SSID="$wifi_ssid" DEFAULT_WIFI_PSK_FILE="$wifi_plain_container" \
    DEFAULT_WIFI_PSK_OPENSSL_FILE="$wifi_enc_container" \
    NATIVE_CUDA_ENABLE="$native_cuda_enable" \
    AUTO_FORCE_RECOVERY="$auto_force_recovery" RECOVERY_SSH_HOST="$recovery_ssh_host" \
    RECOVERY_SSH_USER="$recovery_ssh_user" RECOVERY_SSH_IDENTITY="$recovery_ssh_identity" \
    "$ROOT/jetsonctl" "$@"
}

run_ctl_persisted() {
  local pfile="" wplain="" wenc=""
  case "$password_mode" in
    secretspec) pfile="$container_stage/default-password" ;;
    file) pfile=/work/secrets/default-password ;;
  esac
  if [[ -n "$wifi_ssid" ]]; then
    case "$wifi_source_mode" in
      secretspec) wplain="$container_stage/wifi-psk" ;;
      explicit-file|persisted-plain) wplain=/work/secrets/wifi-psk ;;
      openssl-file|persisted-openssl) wenc=/work/secrets/wifi-psk.enc ;;
      *)
        if [[ -s "$VOLUME/secrets/wifi-psk" ]]; then wplain=/work/secrets/wifi-psk
        elif [[ -s "$VOLUME/secrets/wifi-psk.enc" ]]; then wenc=/work/secrets/wifi-psk.enc
        fi
        ;;
    esac
  fi
  env \
    PROFILE="$PROFILE" JETSON_PLATFORM="${PLATFORM_NAME:-${JETSON_PLATFORM:-}}" VOLUME="$VOLUME" \
    BOARD="$board_config" FLASH_TARGET="$flash_target" \
    DEFAULT_USER="$user" DEFAULT_HOSTNAME="$hostname" DEFAULT_AUTOLOGIN="$autologin" \
    DEFAULT_LOCALE="$locale" DEFAULT_KEYBOARD="$keyboard" \
    DEFAULT_PASSWORD_FILE="$pfile" \
    DEFAULT_SSH_AUTHORIZED_KEY_FILE=/work/secrets/authorized_key.pub DEFAULT_SSH_KEY_ONLY="$ssh_key_only" \
    DEFAULT_SUDO_NOPASSWD="$sudo_nopasswd" \
    DEFAULT_WIFI_SSID="$wifi_ssid" DEFAULT_WIFI_PSK_FILE="$wplain" DEFAULT_WIFI_PSK_OPENSSL_FILE="$wenc" \
    NATIVE_CUDA_ENABLE="$native_cuda_enable" \
    AUTO_FORCE_RECOVERY="$auto_force_recovery" RECOVERY_SSH_HOST="$recovery_ssh_host" \
    RECOVERY_SSH_USER="$recovery_ssh_user" RECOVERY_SSH_IDENTITY="$recovery_ssh_identity" \
    "$ROOT/jetsonctl" "$@"
}

file_state() { [[ -s "$1" ]] && printf 'PASS' || printf 'ABSENT'; }
rootfs_host="$VOLUME/downloads/Linux_for_Tegra/rootfs"
bsp_host=$(find "$VOLUME/downloads" "$VOLUME/sdkmanager/downloads" -type f -name "$L4T_BSP_FILE" -print -quit 2>/dev/null || true)
rootfs_archive_host=$(find "$VOLUME/downloads" "$VOLUME/sdkmanager/downloads" -type f -name "$L4T_ROOTFS_FILE" -print -quit 2>/dev/null || true)
rootfs_present=0; [[ -d "$rootfs_host/usr" && -r "$rootfs_host/etc/os-release" ]] && rootfs_present=1

secret_changed=0
if [[ -n "$ssh_key_host" ]] && ! cmp -s "$ssh_key_host" "$VOLUME/secrets/authorized_key.pub" 2>/dev/null; then secret_changed=1; fi
if [[ "$wifi_source_mode" == openssl-file && -n "$wifi_enc_host" ]] && ! cmp -s "$wifi_enc_host" "$VOLUME/secrets/wifi-psk.enc" 2>/dev/null; then secret_changed=1; fi
if [[ "$wifi_source_mode" == explicit-file && -n "$wifi_plain_host" ]] && ! cmp -s "$wifi_plain_host" "$VOLUME/secrets/wifi-psk" 2>/dev/null; then secret_changed=1; fi
if [[ "$password_mode" == file && -n "$password_file_host" ]] && ! cmp -s "$password_file_host" "$VOLUME/secrets/default-password" 2>/dev/null; then secret_changed=1; fi

host_preflight_out=""
if ! host_preflight_out=$("$ROOT/flash/host-preflight.sh" 2>&1); then
  printf '%s\n' "$host_preflight_out" >&2
  fail "préflight hôte en échec"
fi
host_recovery=0
host_recovery_wrong_mode=0
host_recovery_software=0
if grep -q 'Jetson recovery USB: PASS' <<<"$host_preflight_out"; then host_recovery=1; fi
if grep -q 'Jetson recovery USB: WRONG MODE' <<<"$host_preflight_out"; then host_recovery_wrong_mode=1; fi
if grep -q 'Software recovery: ELIGIBLE' <<<"$host_preflight_out"; then host_recovery_software=1; fi

sdkm_raw_state=$(env PROFILE="$PROFILE" JETSON_PLATFORM="${PLATFORM_NAME:-${JETSON_PLATFORM:-}}" BOARD="$board_config" VOLUME="$VOLUME" "$ROOT/jetsonctl" flash image-status 2>/dev/null || printf 'ABSENT')
case "$sdkm_raw_state" in
  READY) sdkm_image_state=READY ;;
  STALE) sdkm_image_state=STALE_REBUILD_REQUIRED ;;
  ABSENT) sdkm_image_state=AUTO_BUILD_REQUIRED ;;
  *) sdkm_image_state=AUTO_BUILD_REQUIRED ;;
esac

custom_state="UNKNOWN"
native_cuda_state="UNKNOWN"
images_state="unknown"
user_state="UNKNOWN"
plan_out=""
if (( rootfs_present == 1 )); then
  if [[ ! -d "$VOLUME/custom" ]]; then
    custom_state=UNINITIALIZED
    native_cuda_state=RECHECK_AFTER_CUSTOM
    images_state=unknown
    [[ -z "$user" ]] && user_state=OEM || user_state=RECHECK_AFTER_CUSTOM
  elif [[ "$sdkm_image_state" != READY ]]; then
    # Dry-run/preflight must never build the SDK Manager image implicitly.
    custom_state=RECHECK_AFTER_SDKM
    native_cuda_state=RECHECK_AFTER_SDKM
    images_state=unknown
    [[ -z "$user" ]] && user_state=OEM || user_state=RECHECK_AFTER_SDKM
  else
    custom_out=$(run_ctl_stage custom status 2>&1 || true)
    if grep -q 'custom: APPLIED' <<<"$custom_out"; then custom_state=APPLIED; else custom_state=DIRTY; fi
    plan_out=$(run_ctl_stage flash plan 2>&1 || true)
    native_cuda_wanted=$(sed -n 's/^native_cuda wanted=//p' <<<"$plan_out" | tail -n1)
    native_cuda_applied=$(sed -n 's/^native_cuda applied=//p' <<<"$plan_out" | tail -n1)
    if [[ -n "$native_cuda_wanted" && "$native_cuda_wanted" == "$native_cuda_applied" ]]; then native_cuda_state=APPLIED; else native_cuda_state=DIRTY; fi
    images_state=$(sed -n 's/^images=//p' <<<"$plan_out" | tail -n1)
    [[ -n "$images_state" ]] || images_state=unknown
    if [[ -z "$user" ]]; then
      user_state=OEM
    else
      user_wanted=$(sed -n 's/^user wanted=//p' <<<"$plan_out" | tail -n1)
      user_applied=$(sed -n 's/^user applied=//p' <<<"$plan_out" | tail -n1)
      if [[ -n "$user_wanted" && "$user_wanted" == "$user_applied" && $secret_changed -eq 0 ]]; then user_state=APPLIED; else user_state=DIRTY; fi
    fi
  fi
else
  custom_state=NEEDS_PREPARE
  native_cuda_state=NEEDS_PREPARE
  images_state=absent
  [[ -z "$user" ]] && user_state=OEM || user_state=NEEDS_PREPARE
fi

prepare_needed=0
(( rootfs_present == 0 )) && prepare_needed=1
custom_needed=0
[[ "$custom_state" != APPLIED ]] && custom_needed=1
native_cuda_needed=0
[[ "$native_cuda_state" != APPLIED ]] && native_cuda_needed=1
user_needed=0
[[ -n "$user" && "$user_state" != APPLIED ]] && user_needed=1
images_need_regen=0
[[ "$images_state" != fresh || $prepare_needed -eq 1 || $custom_needed -eq 1 || $native_cuda_needed -eq 1 || $user_needed -eq 1 || $secret_changed -eq 1 ]] && images_need_regen=1

download_needed=0
if (( prepare_needed == 1 )) && { [[ -z "$bsp_host" ]] || [[ -z "$rootfs_archive_host" ]]; }; then
  download_needed=1
fi

# Missing archives are first-run work for direct/sdkmanager. Provider=local requires them to exist already.
blocker=0
if (( download_needed == 1 )) && [[ "$download_provider" == local ]]; then blocker=1; fi

printf '\n=== HEADLESS FLASH PREFLIGHT ===\n\n'
printf 'Platform\n'
printf '  name                %s\n' "${PLATFORM_NAME:-unknown}"
printf '  family              %s\n' "${PLATFORM_FAMILY:-unknown}"
printf '  model               %s\n' "${PLATFORM_MODEL:-unknown}"
printf '  hardware tested     %s\n' "${PLATFORM_HARDWARE_TESTED:-no}"
printf '  NVIDIA board        %s\n' "$board_config"
[[ "$board_config" != "$profile_board" ]] && printf '  board override       YES (profile=%s)\n' "$profile_board"
printf '  recovery PID(s)     %s\n' "${RECOVERY_USB_PRODUCTS:-unknown}"
printf '  CUDA arch           sm_%s\n' "${CUDA_COMPUTE_CAP:-unknown}"
printf '  flash layout        %s\n' "${FLASH_LAYOUT:-unknown}"
printf '\nProfile\n'
printf '  JetPack             %s\n' "$JETPACK"
printf '  L4T                 %s\n' "$L4T"
printf '  target              %s\n' "$flash_target"
[[ "$flash_target" == nvme ]] && printf '  external device     %s\n' "$EXTERNAL_DEVICE"

printf '\nDownload\n'
printf '  provider            %s\n' "$download_provider"
printf '  BSP URL             %s\n' "$( [[ "$download_provider" == direct ]] && echo "$L4T_BSP_URL" || echo '-' )"

printf '\nHost / flash runtime\n'
printf '  Docker              PASS\n'
printf '  runtime image       %s\n' "$sdkm_image_state"
printf '  image contents      %s\n' "$SDK_MANAGER_BOOTSTRAP_IMAGE + flash tools + SDK Manager ${SDK_MANAGER_APT_VERSION_PREFIX}*"
if (( host_recovery == 1 )); then
  recovery_display='PASS (APX/RCM)'
elif (( host_recovery_software == 1 && auto_force_recovery == 1 )); then
  recovery_display="L4T GADGET -> AUTO Force Recovery via ${recovery_ssh_user}@${recovery_ssh_host}"
elif (( host_recovery_wrong_mode == 1 )); then
  recovery_display='WRONG MODE (not APX; manual recovery required)'
else
  recovery_display='NOT DETECTED (will wait after confirmation)'
fi
printf '  recovery USB        %s\n' "$recovery_display"
printf '  Smart Host Guard    ENABLED (auto-discovery + restore)\n'
printf '  Auto Force Recovery %s\n' "$( (( auto_force_recovery == 1 )) && echo enabled || echo disabled )"
printf '  RNDIS watcher       AUTO after confirmation\n'

printf '\nStorage\n'
printf '  VOLUME              %s\n' "$VOLUME"
printf '  BSP archive         %s\n' "$( [[ -n "$bsp_host" ]] && echo PASS || echo 'DOWNLOAD REQUIRED' )"
printf '  RootFS archive      %s\n' "$( [[ -n "$rootfs_archive_host" ]] && echo PASS || echo 'DOWNLOAD REQUIRED' )"
printf '  Linux_for_Tegra     %s\n' "$( (( rootfs_present == 1 )) && echo PASS || echo ABSENT )"

printf '\nCustom rootfs\n'
printf '  state               %s\n' "$custom_state"
if [[ -d "$VOLUME/custom" ]]; then
  printf '  packages            %s\n' "$(sed -e 's/#.*$//' -e '/^[[:space:]]*$/d' "$VOLUME/custom/packages.txt" 2>/dev/null | wc -l)"
  printf '  overlay files       %s\n' "$(find "$VOLUME/custom/overlay" -type f 2>/dev/null | wc -l)"
fi

printf '\nNative CUDA SDK\n'
printf '  enabled             %s\n' "$( (( native_cuda_enable == 1 )) && echo yes || echo no )"
printf '  version             %s\n' "${NATIVE_CUDA_VERSION:-13.3}"
printf '  toolkit package     %s\n' "${NATIVE_CUDA_TOOLKIT_PACKAGE:-cuda-toolkit-13-3}"
printf '  compat package      %s\n' "${NATIVE_CUDA_COMPAT_PACKAGE:-unknown}"
printf '  state               %s\n' "$native_cuda_state"

printf '\nUser\n'
printf '  username            %s\n' "${user:-OEM/oem-config}"
printf '  hostname            %s\n' "$hostname"
printf '  locale              %s\n' "$locale"
printf '  keyboard            %s\n' "$keyboard"
printf '  autologin           %s\n' "$( (( autologin == 1 )) && echo yes || echo no )"
case "$password_mode" in
  secretspec) password_display="SecretSpec:${secret_provider}/${password_secret_name}" ;;
  file) password_display="FILE (legacy/explicit)" ;;
  interactive) password_display="INTERACTIVE" ;;
  secret-settings-pending) password_display="SecretSpec:keyring (WOULD PROMPT+STORE)" ;;
  *) password_display="n/a" ;;
esac
printf '  password            %s\n' "$( [[ -z "$user" ]] && echo n/a || echo "$password_display" )"
printf '  state               %s\n' "$user_state"

printf '\nSSH\n'
if [[ -n "$ssh_key_host" ]]; then
  printf '  public key           %s\n' "$ssh_key_host"
  printf '  key readable         PASS\n'
elif [[ -s "$VOLUME/secrets/authorized_key.pub" ]]; then
  printf '  public key           %s\n' "$VOLUME/secrets/authorized_key.pub"
else
  printf '  public key           absent\n'
fi
printf '  key only             %s\n' "$( (( ssh_key_only == 1 )) && echo yes || echo no )"

printf '\nSecret plane\n'
printf '  enabled             %s\n' "$( (( secret_plane_enable == 1 )) && echo yes || echo no )"
printf '  provider            %s\n' "$secret_provider"
printf '  profile             %s\n' "$secret_profile"
printf '  SecretSpec          %s\n' "$(secret_plane_cli_version 2>/dev/null || { secret_plane_resolver_bin >/dev/null 2>&1 && echo 'embedded resolver 0.20.0' || echo 'unavailable'; })"
printf '  settings            %s\n' "$secret_settings_state"

printf '\nWi-Fi\n'
printf '  SSID                 %s\n' "${wifi_ssid:--}"
case "$wifi_source_mode" in
  secretspec)
    printf '  PSK                  SecretSpec:%s/%s (ephemeral stage)\n' "$secret_provider" "$wifi_secret_name"
    ;;
  openssl-file)
    printf '  PSK                  OpenSSL encrypted file (legacy/explicit)\n'
    ;;
  explicit-file)
    printf '  PSK                  plaintext file (legacy/explicit, mode 0600 recommended)\n'
    ;;
  persisted-openssl)
    printf '  PSK                  OpenSSL encrypted (legacy persisted)\n'
    ;;
  persisted-plain)
    printf '  PSK                  plaintext file (legacy persisted)\n'
    ;;
  secret-settings-pending)
    printf '  PSK                  SecretSpec:keyring (WOULD PROMPT+STORE)\n'
    ;;
  *)
    printf '  PSK                  -\n'
    ;;
esac

printf '\nFlash\n'
printf '  network              %s\n' "$FLASH_NETWORK"
printf '  erase all            %s\n' "$FLASH_ERASE_ALL"
printf '  existing images      %s\n' "$images_state"
printf '  generation           %s\n' "$( (( images_need_regen == 1 )) && echo REQUIRED || echo REUSE )"
if [[ "$flash_target" == nvme ]]; then
  if [[ "${FLASH_USE_QSPI_XML:-0}" == 1 ]]; then
    printf '  QSPI                 WILL FLASH (explicit QSPI XML)\n'
  else
    printf '  QSPI                 board-config managed\n'
  fi
  printf '  NVMe                 WILL ERASE/FLASH\n'
fi

printf '\nActions\n'
step=0
if [[ "$download_provider" == sdkmanager && "$sdkm_image_state" != READY && $download_needed -eq 1 ]]; then step=$((step+1)); printf '  %d. build flash/SDK Manager runtime image %s\n' "$step" "$SDK_MANAGER_APT_VERSION_PREFIX"; fi
if (( download_needed == 1 )); then step=$((step+1)); printf '  %d. download Jetson Linux %s archives via provider=%s\n' "$step" "$L4T" "$download_provider"; fi
if [[ "$download_provider" != sdkmanager && "$sdkm_image_state" != READY ]]; then step=$((step+1)); printf '  %d. build flash runtime image (SDK Manager kept optional)\n' "$step"; fi
if (( prepare_needed == 1 )); then step=$((step+1)); printf '  %d. prepare BSP/rootfs\n' "$step"; fi
if (( custom_needed == 1 )); then step=$((step+1)); printf '  %d. apply custom rootfs\n' "$step"; fi
if (( native_cuda_needed == 1 )); then step=$((step+1)); printf '  %d. apply native CUDA SDK %s to rootfs\n' "$step" "${NATIVE_CUDA_VERSION:-13.3}"; fi
if (( user_needed == 1 )); then step=$((step+1)); printf '  %d. create/update default user and headless settings\n' "$step"; fi
if (( host_recovery_software == 1 && auto_force_recovery == 1 )); then step=$((step+1)); printf '  %d. request software Force Recovery over USB SSH\n' "$step"; fi
if (( images_need_regen == 1 )); then step=$((step+1)); printf '  %d. generate fresh flash images\n' "$step"; else step=$((step+1)); printf '  %d. reuse validated flash images\n' "$step"; fi
step=$((step+1)); printf '  %d. flash %s\n' "$step" "$flash_target"

if (( blocker == 1 )); then
  printf '\nBLOCKER(S): préflight hôte/paramètres invalides, ou provider=local sans archives requises.\n'
  exit 1
fi

if (( dry_run == 1 )); then
  printf '\nDRY-RUN: aucune modification rootfs/custom/keyring/secrets, aucune attente recovery, aucun flash.\n'
  exit 0
fi

printf '\nWARNING: le flash peut effacer le média cible.\n'
if (( yes_mode == 0 )); then
  [[ -r /dev/tty ]] || fail "TTY requis pour confirmation; utilise --yes uniquement si c'est intentionnel"
  answer=""
  read -r -p "Continue? [y/N]: " answer < /dev/tty
  case "$answer" in y|Y|yes|YES|o|O|oui|OUI) ;; *) echo "Annulé."; exit 0 ;; esac
else
  echo "Confirmation: --yes"
fi

# Persist only after confirmation. No secret value appears on argv or in shell history.
mkdir -p "$VOLUME/secrets"
chmod 700 "$VOLUME/secrets" 2>/dev/null || true
persist_secret() {
  local src=$1 dst=$2 target="$VOLUME/secrets/$2"
  [[ -n "$src" ]] || return 0
  if [[ -e "$target" && "$src" -ef "$target" ]]; then
    chmod 600 "$target"
    return 0
  fi
  install -m 600 "$src" "$target"
}
# SecretSpec/keyring values are deliberately NEVER persisted in $VOLUME/secrets.
# They exist only in the mode-0600 stage directory for the lifetime of this flash.
if [[ "$password_mode" == file ]]; then
  persist_secret "$password_file_host" default-password
fi
persist_secret "$ssh_key_host" authorized_key.pub
if [[ "$wifi_source_mode" == openssl-file ]]; then
  persist_secret "$wifi_enc_host" wifi-psk.enc
  rm -f "$VOLUME/secrets/wifi-psk"
elif [[ "$wifi_source_mode" == explicit-file ]]; then
  persist_secret "$wifi_plain_host" wifi-psk
  rm -f "$VOLUME/secrets/wifi-psk.enc"
fi

# Download provider is independent from the flash flow. SDK Manager needs its runtime image first; direct/local do not.
if (( download_needed == 1 )) && [[ "$download_provider" == sdkmanager && "$sdkm_image_state" != READY ]]; then
  run_ctl_persisted flash image
  sdkm_image_state=READY
fi
if (( download_needed == 1 )); then
  run_ctl_persisted flash download --provider "$download_provider"
fi

# Prepare/flash still uses the containerized flash runtime.
if [[ "$sdkm_image_state" != READY ]]; then
  run_ctl_persisted flash image
fi

# Prepare creates Linux_for_Tegra/rootfs only when needed.
if (( prepare_needed == 1 )); then
  run_ctl_persisted flash prepare
fi

# Re-evaluate custom after prepare because a new rootfs has no applied digest.
custom_now=$(run_ctl_persisted custom status 2>&1 || true)
if ! grep -q 'custom: APPLIED' <<<"$custom_now"; then
  run_ctl_persisted custom apply
fi

# fix13/fix14/fix15: native CUDA is a first-class image layer, independent from the user's
# custom directory, but applied in the same offline rootfs phase.
native_now=$(run_ctl_persisted native-sdk status 2>&1 || true)
if ! grep -q 'native CUDA SDK: APPLIED' <<<"$native_now"; then
  run_ctl_persisted native-sdk apply
fi

# Re-evaluate user after custom/native SDK and persisted secrets.
if [[ -n "$user" ]]; then
  plan_now=$(run_ctl_persisted flash plan 2>&1 || true)
  user_wanted=$(sed -n 's/^user wanted=//p' <<<"$plan_now" | tail -n1)
  user_applied=$(sed -n 's/^user applied=//p' <<<"$plan_now" | tail -n1)
  if [[ -z "$user_wanted" || "$user_wanted" != "$user_applied" ]]; then
    run_ctl_persisted flash create-user
  else
    echo "Utilisateur/headless: déjà à jour; pas de nouvelle saisie de mot de passe."
  fi
fi

# If rootfs/user/custom changes invalidated images, regenerate+flash in one backend call.
final_plan=$(run_ctl_persisted flash plan 2>&1 || true)
final_images=$(sed -n 's/^images=//p' <<<"$final_plan" | tail -n1)
if [[ "$final_images" == fresh ]]; then
  echo "Images: FRESH -> flash-only"
  run_ctl_persisted flash "$flash_target" --reuse-images
else
  echo "Images: ${final_images:-unknown} -> génération + flash"
  run_ctl_persisted flash "$flash_target"
fi
