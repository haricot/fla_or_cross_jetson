#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VOLUME="${VOLUME:-}"
DEFAULT_USER="${DEFAULT_USER:-}"
DEFAULT_HOSTNAME="${DEFAULT_HOSTNAME:-tegra-ubuntu}"
DEFAULT_AUTOLOGIN="${DEFAULT_AUTOLOGIN:-1}"
FLASH_TARGET="${FLASH_TARGET:-nvme}"
DEFAULT_PASSWORD_FILE="${DEFAULT_PASSWORD_FILE:-}"
DEFAULT_LOCALE="${DEFAULT_LOCALE:-}"
DEFAULT_KEYBOARD="${DEFAULT_KEYBOARD:-}"
DEFAULT_SSH_PUBLIC_KEY_FILE="${DEFAULT_SSH_PUBLIC_KEY_FILE:-}"
DEFAULT_SSH_KEY_ONLY="${DEFAULT_SSH_KEY_ONLY:-0}"
DEFAULT_SUDO_NOPASSWD="${DEFAULT_SUDO_NOPASSWD:-0}"
DEFAULT_WIFI_SSID="${DEFAULT_WIFI_SSID:-}"
DEFAULT_WIFI_PSK_FILE="${DEFAULT_WIFI_PSK_FILE:-}"
DEFAULT_WIFI_PSK_OPENSSL_FILE="${DEFAULT_WIFI_PSK_OPENSSL_FILE:-}"
HOST_FLASH_IFACE="${HOST_FLASH_IFACE:-}"
HOST_FLASH_IFACE_TIMEOUT="${HOST_FLASH_IFACE_TIMEOUT:-1800}"
WAIT_LOG="/tmp/host-usb-fix.$$.log"
WAIT_PID=""
TEMP_WIFI_PSK_FILE=""

usage() {
  cat <<'EOF'
Usage: ./headless-flash.sh [options]

Prepare a headless Jetson flash by:
- fixing host USB/IPv6 state
- starting a quiet background watcher for the Jetson USB network interface
- running `docker compose ... sdkm prepare_headless_flash`

Options:
  --volume PATH          Host sdk_manager directory. Can also come from VOLUME.
  --user NAME            Default Jetson username. Can also come from DEFAULT_USER.
  --hostname NAME        Default Jetson hostname. Default: tegra-ubuntu
  --autologin 0|1        Enable autologin. Default: 1
  --locale VALUE         Default Jetson locale, e.g. fr_FR.UTF-8
  --keyboard VALUE       Default Jetson keyboard layout, e.g. fr
  --flash-target NAME    internal or nvme. Default: nvme
  --password-file PATH   Host path to a password file. Optional.
  --wifi-ssid VALUE      Wi-Fi SSID to preconfigure on the Jetson first boot.
  --wifi-psk-file PATH   Host path to the Wi-Fi PSK file. Required with --wifi-ssid.
  --wifi-psk-openssl-file
                        Host path to an OpenSSL-encrypted Wi-Fi PSK file.
  --host-flash-iface     Force the host USB network interface used for initrd flash.
  --host-flash-timeout   Watch timeout in seconds for host USB fix. Default: 1800
  --ssh-public-key-file  Host path to a public SSH key to install for the user.
  --ssh-key-only         Disable password SSH auth on the Jetson and keep key auth only.
  --sudo-nopasswd        Allow passwordless sudo for the created user.
  -h, --help             Show this help

Examples:
  VOLUME=/path/to/your/storage/sdk_manager ./headless-flash.sh --volume "${VOLUME}" --user jetson
  VOLUME=/path/to/your/storage/sdk_manager ./headless-flash.sh --volume "${VOLUME}" --user jetson \
    --locale fr_FR.UTF-8 --keyboard fr \
    --wifi-ssid MonReseau --wifi-psk-openssl-file "${VOLUME}"/tmp/wifi_psk.enc \
    --host-flash-iface enp60s0u1 \
    --ssh-public-key-file ~/.ssh/id_ed25519.pub \
    --password-file "${VOLUME}"/tmp/jetson_password
EOF
}

cleanup() {
  if [[ -n "${TEMP_WIFI_PSK_FILE}" && -f "${TEMP_WIFI_PSK_FILE}" ]]; then
    rm -f "${TEMP_WIFI_PSK_FILE}" || true
  fi
  if [[ -n "${WAIT_PID}" ]] && kill -0 "${WAIT_PID}" 2>/dev/null; then
    kill "${WAIT_PID}" 2>/dev/null || true
    wait "${WAIT_PID}" 2>/dev/null || true
  fi
}

require_cmd() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || {
    echo "Commande introuvable: ${cmd}" >&2
    exit 1
  }
}

decrypt_wifi_psk_if_needed() {
  local openssl_passphrase=""

  if [[ -z "${DEFAULT_WIFI_PSK_OPENSSL_FILE}" ]]; then
    return 0
  fi

  require_cmd openssl

  if [[ -n "${DEFAULT_WIFI_PSK_FILE}" ]]; then
    echo "Utilise soit --wifi-psk-file soit --wifi-psk-openssl-file, pas les deux." >&2
    exit 1
  fi

  if [[ ! -r "${DEFAULT_WIFI_PSK_OPENSSL_FILE}" ]]; then
    echo "Fichier Wi-Fi OpenSSL introuvable ou illisible: ${DEFAULT_WIFI_PSK_OPENSSL_FILE}" >&2
    exit 1
  fi

  if [[ ! -r /dev/tty ]]; then
    echo "Impossible de demander la passphrase OpenSSL sur /dev/tty." >&2
    exit 1
  fi

  read -rsp "Passphrase OpenSSL pour le Wi-Fi: " openssl_passphrase < /dev/tty
  printf '\n' > /dev/tty

  if [[ -z "${openssl_passphrase}" ]]; then
    echo "Passphrase OpenSSL vide." >&2
    exit 1
  fi

  TEMP_WIFI_PSK_FILE="$(mktemp /tmp/jetson_wifi_psk.XXXXXX)"
  chmod 600 "${TEMP_WIFI_PSK_FILE}"

  if ! printf '%s' "${openssl_passphrase}" | openssl enc -d -aes-256-cbc -pbkdf2 \
    -pass stdin \
    -in "${DEFAULT_WIFI_PSK_OPENSSL_FILE}" \
    -out "${TEMP_WIFI_PSK_FILE}"
  then
    echo "Echec du déchiffrement OpenSSL du fichier Wi-Fi." >&2
    exit 1
  fi

  DEFAULT_WIFI_PSK_FILE="${TEMP_WIFI_PSK_FILE}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --volume)
      VOLUME="${2:-}"
      shift 2
      ;;
    --user)
      DEFAULT_USER="${2:-}"
      shift 2
      ;;
    --hostname)
      DEFAULT_HOSTNAME="${2:-}"
      shift 2
      ;;
    --autologin)
      DEFAULT_AUTOLOGIN="${2:-}"
      shift 2
      ;;
    --locale)
      DEFAULT_LOCALE="${2:-}"
      shift 2
      ;;
    --keyboard)
      DEFAULT_KEYBOARD="${2:-}"
      shift 2
      ;;
    --flash-target)
      FLASH_TARGET="${2:-}"
      shift 2
      ;;
    --password-file)
      DEFAULT_PASSWORD_FILE="${2:-}"
      shift 2
      ;;
    --wifi-ssid)
      DEFAULT_WIFI_SSID="${2:-}"
      shift 2
      ;;
    --wifi-psk-file)
      DEFAULT_WIFI_PSK_FILE="${2:-}"
      shift 2
      ;;
    --wifi-psk-openssl-file)
      DEFAULT_WIFI_PSK_OPENSSL_FILE="${2:-}"
      shift 2
      ;;
    --host-flash-iface)
      HOST_FLASH_IFACE="${2:-}"
      shift 2
      ;;
    --host-flash-timeout)
      HOST_FLASH_IFACE_TIMEOUT="${2:-}"
      shift 2
      ;;
    --ssh-public-key-file)
      DEFAULT_SSH_PUBLIC_KEY_FILE="${2:-}"
      shift 2
      ;;
    --ssh-key-only)
      DEFAULT_SSH_KEY_ONLY=1
      shift
      ;;
    --sudo-nopasswd)
      DEFAULT_SUDO_NOPASSWD=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Option inconnue: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "${VOLUME}" ]]; then
  echo "Définis --volume ou VOLUME." >&2
  exit 1
fi

if [[ -z "${DEFAULT_USER}" ]]; then
  echo "Définis --user ou DEFAULT_USER." >&2
  exit 1
fi

if [[ ! -d "${VOLUME}" ]]; then
  echo "Répertoire VOLUME introuvable: ${VOLUME}" >&2
  exit 1
fi

if [[ -n "${DEFAULT_PASSWORD_FILE}" && ! -r "${DEFAULT_PASSWORD_FILE}" ]]; then
  echo "Fichier mot de passe introuvable ou illisible: ${DEFAULT_PASSWORD_FILE}" >&2
  exit 1
fi

if [[ -n "${DEFAULT_WIFI_PSK_OPENSSL_FILE}" && ! -r "${DEFAULT_WIFI_PSK_OPENSSL_FILE}" ]]; then
  echo "Fichier PSK Wi-Fi chiffré introuvable ou illisible: ${DEFAULT_WIFI_PSK_OPENSSL_FILE}" >&2
  exit 1
fi

if [[ -n "${DEFAULT_WIFI_PSK_FILE}" && ! -r "${DEFAULT_WIFI_PSK_FILE}" ]]; then
  echo "Fichier PSK Wi-Fi introuvable ou illisible: ${DEFAULT_WIFI_PSK_FILE}" >&2
  exit 1
fi

if [[ -n "${DEFAULT_SSH_PUBLIC_KEY_FILE}" && ! -r "${DEFAULT_SSH_PUBLIC_KEY_FILE}" ]]; then
  echo "Clé publique SSH introuvable ou illisible: ${DEFAULT_SSH_PUBLIC_KEY_FILE}" >&2
  exit 1
fi

if [[ -n "${DEFAULT_WIFI_SSID}" && -z "${DEFAULT_WIFI_PSK_FILE}" ]]; then
  if [[ -z "${DEFAULT_WIFI_PSK_OPENSSL_FILE}" ]]; then
    echo "--wifi-ssid demande aussi --wifi-psk-file ou --wifi-psk-openssl-file." >&2
    exit 1
  fi
fi

if [[ -z "${DEFAULT_WIFI_SSID}" && ( -n "${DEFAULT_WIFI_PSK_FILE}" || -n "${DEFAULT_WIFI_PSK_OPENSSL_FILE}" ) ]]; then
  echo "--wifi-psk-file/--wifi-psk-openssl-file demande aussi --wifi-ssid." >&2
  exit 1
fi

if [[ -n "${DEFAULT_WIFI_PSK_FILE}" && -n "${DEFAULT_WIFI_PSK_OPENSSL_FILE}" ]]; then
  echo "Utilise soit --wifi-psk-file soit --wifi-psk-openssl-file." >&2
  exit 1
fi

if [[ "${DEFAULT_SSH_KEY_ONLY}" == "1" && -z "${DEFAULT_SSH_PUBLIC_KEY_FILE}" ]]; then
  echo "--ssh-key-only demande aussi --ssh-public-key-file." >&2
  exit 1
fi

require_cmd docker
require_cmd sudo

trap cleanup EXIT

cd "${SCRIPT_DIR}"

decrypt_wifi_psk_if_needed

sudo -v
sudo "${SCRIPT_DIR}/host-usb-fix.sh"
wait_cmd=(
  sudo -n "${SCRIPT_DIR}/host-usb-fix.sh"
  --wait
  --quiet
  --timeout "${HOST_FLASH_IFACE_TIMEOUT}"
)

if [[ -n "${HOST_FLASH_IFACE}" ]]; then
  wait_cmd+=(--iface "${HOST_FLASH_IFACE}")
fi

"${wait_cmd[@]}" >"${WAIT_LOG}" 2>&1 &
WAIT_PID="$!"

echo "Background host USB watcher log: ${WAIT_LOG}"

compose_cmd=(
  docker compose run --rm
  -e "DEFAULT_USER=${DEFAULT_USER}"
  -e "DEFAULT_HOSTNAME=${DEFAULT_HOSTNAME}"
  -e "DEFAULT_AUTOLOGIN=${DEFAULT_AUTOLOGIN}"
  -e "FLASH_TARGET=${FLASH_TARGET}"
)

if [[ -n "${DEFAULT_LOCALE}" ]]; then
  compose_cmd+=(-e "DEFAULT_LOCALE=${DEFAULT_LOCALE}")
fi

if [[ -n "${DEFAULT_KEYBOARD}" ]]; then
  compose_cmd+=(-e "DEFAULT_KEYBOARD=${DEFAULT_KEYBOARD}")
fi

if [[ -n "${DEFAULT_WIFI_SSID}" ]]; then
  compose_cmd+=(-e "DEFAULT_WIFI_SSID=${DEFAULT_WIFI_SSID}")
fi

if [[ -n "${HOST_FLASH_IFACE}" ]]; then
  compose_cmd+=(-e "HOST_FLASH_IFACE=${HOST_FLASH_IFACE}")
fi

if [[ -n "${HOST_FLASH_IFACE_TIMEOUT}" ]]; then
  compose_cmd+=(-e "HOST_FLASH_IFACE_TIMEOUT=${HOST_FLASH_IFACE_TIMEOUT}")
fi

if [[ "${DEFAULT_SSH_KEY_ONLY}" == "1" ]]; then
  compose_cmd+=(-e "DEFAULT_SSH_KEY_ONLY=1")
fi

if [[ "${DEFAULT_SUDO_NOPASSWD}" == "1" ]]; then
  compose_cmd+=(-e "DEFAULT_SUDO_NOPASSWD=1")
fi

if [[ -n "${DEFAULT_PASSWORD_FILE}" ]]; then
  compose_cmd+=(
    -v "${DEFAULT_PASSWORD_FILE}:/run/secrets/jetson_password:ro"
    -e "DEFAULT_PASSWORD_FILE=/run/secrets/jetson_password"
  )
fi

if [[ -n "${DEFAULT_WIFI_PSK_FILE}" ]]; then
  compose_cmd+=(
    -v "${DEFAULT_WIFI_PSK_FILE}:/run/secrets/jetson_wifi_psk:ro"
    -e "DEFAULT_WIFI_PSK_FILE=/run/secrets/jetson_wifi_psk"
  )
fi

if [[ -n "${DEFAULT_SSH_PUBLIC_KEY_FILE}" ]]; then
  compose_cmd+=(
    -v "${DEFAULT_SSH_PUBLIC_KEY_FILE}:/run/secrets/jetson_authorized_key.pub:ro"
    -e "DEFAULT_SSH_AUTHORIZED_KEY_FILE=/run/secrets/jetson_authorized_key.pub"
  )
fi

compose_cmd+=(
  sdkm
  prepare_headless_flash
)

env VOLUME="${VOLUME}" "${compose_cmd[@]}"
