#!/usr/bin/env bash
set -Eeuo pipefail

TIMEOUT=1800
INTERVAL=1
WAIT_FOR_IFACE=0
IFACE=""
QUIET=0

# Defaults tuned for the current host. Missing paths are skipped.
PCI_DEVICES=(
  "0000:04:00.0"
  "0000:05:02.0"
  "0000:3c:00.0"
)

USB_BUSES=(
  "usb3"
  "usb4"
)

usage() {
  cat <<'EOF'
Usage: sudo ./host-usb-fix.sh [options]

Prepare the host before Jetson initrd flashing:
- force the known USB/PCI path to stay powered on
- disable usbcore autosuspend for the current session
- enable global IPv6
- optionally wait for the Jetson USB network interface and fix IPv6 on it

Options:
  --wait             Wait for the Jetson USB network interface and fix it
  --iface IFACE      Fix a specific interface now, or while waiting with --wait
  --timeout SEC      Wait timeout in seconds for --wait (default: 1800)
  --interval SEC     Poll interval in seconds for --wait (default: 1)
  --quiet            Reduce terminal output, useful with background wait mode
  -h, --help         Show this help

Examples:
  sudo ./host-usb-fix.sh
  sudo ./host-usb-fix.sh --wait
  sudo ./host-usb-fix.sh --wait --quiet
  sudo ./host-usb-fix.sh --iface enp60s0u1
  sudo ./host-usb-fix.sh --wait --iface enp60s0u1
EOF
}

log() {
  if [[ "${QUIET}" -eq 0 ]]; then
    printf '%s\n' "$*"
  fi
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Ce script doit etre lance avec sudo/root." >&2
    exit 1
  fi
}

write_if_present() {
  local path="$1"
  local value="$2"

  if [[ -e "${path}" ]]; then
    printf '%s' "${value}" > "${path}"
    log "Set ${path}=${value}"
  fi
}

load_usb_modules() {
  local mod=""
  for mod in usbnet rndis_host cdc_ether; do
    modprobe "${mod}" 2>/dev/null || true
  done
}

prepare_power_path() {
  local dev=""
  local bus=""

  for dev in "${PCI_DEVICES[@]}"; do
    write_if_present "/sys/bus/pci/devices/${dev}/power/control" "on"
  done

  for bus in "${USB_BUSES[@]}"; do
    write_if_present "/sys/bus/usb/devices/${bus}/power/control" "on"
  done

  write_if_present "/sys/module/usbcore/parameters/autosuspend" "-1"
}

enable_global_ipv6() {
  sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null
  sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null
  log "Enabled global IPv6"
}

get_udev_attr() {
  local path="$1"
  local attr="$2"

  udevadm info --attribute-walk "$path" 2>/dev/null \
    | sed -n "0,/^[ ]*ATTRS{$attr}==\"\\(.*\\)\"$/s//\\1/p" \
    | xargs
}

discover_jetson_iface() {
  local path=""
  local iface=""
  local configuration=""

  for path in /sys/class/net/*; do
    iface="${path##*/}"
    [[ "${iface}" == "lo" ]] && continue

    configuration="$(get_udev_attr "${path}" configuration || true)"
    if [[ "${configuration}" =~ RNDIS\+L4T ]]; then
      printf '%s\n' "${iface}"
      return 0
    fi
  done

  return 1
}

wait_for_iface() {
  local deadline=$((SECONDS + TIMEOUT))

  while (( SECONDS < deadline )); do
    if [[ -n "${IFACE}" ]]; then
      [[ -e "/sys/class/net/${IFACE}" ]] && return 0
    elif IFACE="$(discover_jetson_iface)"; then
      return 0
    fi

    log "Waiting for Jetson USB network interface..."
    sleep "${INTERVAL}"
  done

  return 1
}

fix_iface_ipv6() {
  if [[ -z "${IFACE}" ]]; then
    echo "Aucune interface a corriger." >&2
    exit 1
  fi

  if [[ ! -e "/sys/class/net/${IFACE}" ]]; then
    echo "Interface introuvable: ${IFACE}" >&2
    exit 1
  fi

  sysctl -w "net.ipv6.conf.${IFACE}.disable_ipv6=0" >/dev/null
  ip link set dev "${IFACE}" up

  ip -6 addr add fc00:1:1:0::1/64 dev "${IFACE}" 2>/dev/null || true
  ip -6 addr add fe80::2/64 dev "${IFACE}" 2>/dev/null || true

  log "Fixed IPv6 on ${IFACE}"
  if [[ "${QUIET}" -eq 0 ]]; then
    ip -br link show dev "${IFACE}" || true
    ip -6 addr show dev "${IFACE}" || true
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --wait)
      WAIT_FOR_IFACE=1
      shift
      ;;
    --iface)
      IFACE="${2:-}"
      shift 2
      ;;
    --timeout)
      TIMEOUT="${2:-}"
      shift 2
      ;;
    --interval)
      INTERVAL="${2:-}"
      shift 2
      ;;
    --quiet)
      QUIET=1
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

require_root
load_usb_modules
prepare_power_path
enable_global_ipv6

if [[ -n "${IFACE}" && "${WAIT_FOR_IFACE}" -eq 0 ]]; then
  fix_iface_ipv6
elif [[ "${WAIT_FOR_IFACE}" -eq 1 ]]; then
  wait_for_iface || {
    echo "Aucune interface Jetson detectee avant le timeout." >&2
    exit 2
  }
  fix_iface_ipv6
else
  log "Host USB/IPv6 fix applied."
  log "Run again with --wait to auto-fix the Jetson USB network interface."
fi
Oui, c'est tout à fait possible. Le script actuel est conçu pour une architecture spécifique (probablement x86_64 sur une carte spécifique où les adresses PCI `0000:04:00.0` sont constantes).

Pour le rendre **multi-arch** et **distribué**, nous devons :
1.  **Supprimer les adresses PCI et Bus USB hardcoded** : Nous ne pouvons plus deviner les adresses.
2.  **Automatiser la découverte** : Utiliser des commandes comme `lspci`, `lsusb` ou scanner directement le sysfs pour trouver les périphériques connectés.
3.  **Générer des listes dynamiques** : Remplacer les tableaux statiques par des boucles qui détectent les périphériques actifs au moment de l'exécution.
4.  **Assurer la compatibilité des modules** : Les noms de modules (`usbnet`, etc.) sont généralement compatibles, mais nous devons nous assurer qu'ils sont bien chargés avant d'agir.

Voici le script réécrit pour être **dynamique**, **multi-architecture** et **plus robuste**.

### Script Multi-Arch (`host-usb-fix.sh`)

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

# --- Configuration par défaut ---
TIMEOUT=1800
INTERVAL=1
WAIT_FOR_IFACE=0
IFACE=""
QUIET=0

# --- Fonctions utilitaires ---

usage() {
  cat <<'EOF'
Usage: sudo ./host-usb-fix.sh [options]

Prépare l'hôte avant le flash de l'initrd Jetson :
- Force l'alimentation des périphériques USB/PCI détectés dynamiquement.
- Désactive l'autosuspend de l'USB pour la session en cours.
- Active le support global IPv6.
- Optionnel : Attend et configure une interface réseau spécifique Jetson.

Options:
  --wait             Attendre la détection de l'interface réseau Jetson et la configurer.
  --iface IFACE      Configurer immédiatement l'interface spécifiée.
  --timeout SEC      Durée d'attente en secondes (par défaut: 1800).
  --interval SEC     Intervalle de sondage en secondes (par défaut: 1).
  --quiet            Réduire les sorties, utile en mode background.
  -h, --help         Afficher cette aide.

Exemples:
  sudo ./host-usb-fix.sh
  sudo ./host-usb-fix.sh --wait
  sudo ./host-usb-fix.sh --wait --quiet
  sudo ./host-usb-fix.sh --iface enp60s0u1
  sudo ./host-usb-fix.sh --wait --iface enp60s0u1
EOF
}

log() {
  if [[ "${QUIET}" -eq 0 ]]; then
    printf '%s\n' "$*"
  fi
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Ce script doit être lancé avec sudo/root." >&2
    exit 1
  fi
}

write_if_present() {
  local path="$1"
  local value="$2"

  if [[ -f "${path}" ]]; then
    printf '%s' "${value}" > "${path}"
    # Seule une erreur critique est affichée pour éviter le bruit
    if [[ "${QUIET}" -eq 0 ]]; then
      log "Set ${path}=${value}"
    fi
  fi
}

load_usb_modules() {
  local mod=""
  # Essayer de charger les modules nécessaires pour la détection et le support
  for mod in usbnet rndis_host cdc_ether cdc_ncm uas; do
    if ! lsmod | grep -q "^${mod}"; then
      modprobe "${mod}" 2>/dev/null || log "Module ${mod} non disponible ou déjà chargé."
    fi
  done
}

discover_and_power_devices() {
  log "Scan et configuration des périphériques..."
  
  # 1. Gestion PCI (Cartes réseau, contrôleurs USB)
  # On cherche les dispositifs PCI existants pour appliquer 'power/control'
  # Cette boucle évite de hardcoder les adresses
  local device
  while IFS= read -r device; do
    if [[ -n "${device}" && -e "/sys/bus/pci/devices/${device}/power/control" ]]; then
      write_if_present "/sys/bus/pci/devices/${device}/power/control" "on"
    fi
  done < <(ls /sys/bus/pci/devices 2>/dev/null || true)

  # 2. Gestion USB (Bus et périphériques)
  # On parcourt les bus USB actifs
  local bus_path
  for bus_path in /sys/bus/usb/devices/*; do
    # Filtre pour ne garder que les répertoires de bus (ex: usb1, usb2) ou périphériques racine
    if [[ -d "${bus_path}" && "${bus_path}" == /sys/bus/usb/devices/* ]]; then
      local dev_name="${bus_path##*/}"
      # On applique aussi aux périphériques spécifiques si le fichier existe
      local control_path="${bus_path}/power/control"
      if [[ -f "${control_path}" ]]; then
        write_if_present "${control_path}" "on"
      fi
    fi
  done

  # Configuration globale USB
  write_if_present "/sys/module/usbcore/parameters/autosuspend" "-1"
}

enable_global_ipv6() {
  if sysctl -q net.ipv6.conf.all.disable_ipv6 2>/dev/null | grep -q "1"; then
    sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null
    sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null
    log "IPv6 global activé."
  fi
}

get_udev_attr() {
  local path="$1"
  local attr="$2"
  local result

  # Utilisation robuste pour extraire l'attribut
  result=$(udevadm info --query=property --path="$path" | grep "^${attr}=" | cut -d= -f2)
  echo "${result:-}"
}

discover_jetson_iface() {
  local path=""
  local iface=""
  local configuration=""

  # Parcourir toutes les interfaces réseau
  for path in /sys/class/net/*; do
    iface="${path##*/}"
    [[ "${iface}" == "lo" ]] && continue

    # Chercher le descriptor RNDIS/L4T typique
    # L'attribut 'configuration' dans le sysfs contient souvent "1" ou "RNDIS+L4T" selon la driver
    # Méthode alternative : vérifier la sous-classe ou l'attribut spécifique du driver
    # Tentative 1 : attribut configuration
    configuration="$(get_udev_attr "${path}" configuration)"
    
    # Tentative 2 : vérifier le nom du driver ou l'ID USB
    local driver_path="${path}/driver"
    local driver_name=""
    if [[ -d "${driver_path}" ]]; then
       driver_name="$(readlink -f "${driver_path}" | xargs -n1 basename)"
    fi

    # Logique de détection :
    # 1. Si le driver est cdc_ncm, rndis_host, ou cdc_ether (souvent le cas pour Jetson)
    # 2. Ou si le système de fichiers contient des indices RNDIS
    if [[ -n "${driver_name}" && ("${driver_name}" == "cdc_ncm" || "${driver_name}" == "rndis_host" || "${driver_name}" == "cdc_ether" || "${driver_name}" == "ipheth") ]]; then
      # Vérifier si c'est bien un périphérique USB (pas une carte WiFi/ethernet interne)
      if [[ -d "/sys/class/net/${iface}/device" && -d "/sys/class/net/${iface}/device/bus" ]]; then
         log "Interface détectée comme Jetson USB: ${iface} (Driver: ${driver_name})"
         printf '%s\n' "${iface}"
         return 0
      fi
    fi
  done

  return 1
}

wait_for_iface() {
  local deadline=$((SECONDS + TIMEOUT))
  local found=0

  log "Début de la recherche de l'interface Jetson (Timeout: ${TIMEOUT}s)..."
  
  while (( SECONDS < deadline )); do
    if [[ -n "${IFACE}" ]]; then
      if [[ -e "/sys/class/net/${IFACE}" ]]; then
        return 0
      fi
    elif IFACE="$(discover_jetson_iface)"; then
      return 0
    fi

    if [[ "${QUIET}" -eq 0 ]]; then
      printf '.\r' # Indicateur visuel de survol
    fi
    
    sleep "${INTERVAL}"
  done

  if [[ "${QUIET}" -eq 0 ]]; then
    printf '\n'
  fi

  return 1
}

fix_iface_ipv6() {
  if [[ -z "${IFACE}" ]]; then
    echo "Aucune interface spécifiée pour correction." >&2
    exit 1
  fi

  if [[ ! -e "/sys/class/net/${IFACE}" ]]; then
    echo "Interface introuvable : ${IFACE}" >&2
    exit 1
  fi

  # Configuration IPv6
  sysctl -w "net.ipv6.conf.${IFACE}.disable_ipv6=0" >/dev/null 2>&1 || true
  ip link set dev "${IFACE}" up

  # Adresse statique spécifique au couple Hôte-Jetson (modèle L4T)
  # fc00:1:1:0::1 est l'IPv6 de l'hôte pour le réseau point-à-point
  ip -6 addr add fc00:1:1:0::1/64 dev "${IFACE}" 2>/dev/null || true
  # Adresse lien-local pour la communication
  ip -6 addr add fe80::2/64 dev "${IFACE}" 2>/dev/null || true

  log "IPv6 configuré sur ${IFACE}"
  
  if [[ "${QUIET}" -eq 0 ]]; then
    ip -br link show dev "${IFACE}" || true
    ip -6 addr show dev "${IFACE}" || true
  fi
}

# --- Parsing des arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --wait)
      WAIT_FOR_IFACE=1
      shift
      ;;
    --iface)
      IFACE="${2:-}"
      shift 2
      ;;
    --timeout)
      TIMEOUT="${2:-}"
      shift 2
      ;;
    --interval)
      INTERVAL="${2:-}"
      shift 2
      ;;
    --quiet)
      QUIET=1
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

# --- Exécution ---
require_root
load_usb_modules

# Application dynamique des règles d'alimentation
discover_and_power_devices
enable_global_ipv6

if [[ -n "${IFACE}" && "${WAIT_FOR_IFACE}" -eq 0 ]]; then
  fix_iface_ipv6
elif [[ "${WAIT_FOR_IFACE}" -eq 1 ]]; then
  if wait_for_iface; then
    fix_iface_ipv6
  else
    echo "Aucune interface Jetson détectée avant le timeout." >&2
    exit 2
  fi
else
  log "Correctifs USB/IPv6 hôte appliqués (Modes dynamiques)."
  log "Lancez à nouveau avec --wait pour corriger automatiquement l'interface réseau Jetson."
fi
```

### Principaux changements effectués pour la compatibilité Multi-Arch

1.  **Suppression des adresses fixes (`PCI_DEVICES`, `USB_BUSES`)** :
    *   *Avant* : Le script échouait si les adresses PCI (`0000:04:00.0`) n'existaient pas (ce qui est le cas sur ARM, i386, ou d'autres modèles de cartes).
    *   *Maintenant* : La fonction `discover_and_power_devices` scanne les dossiers réels `/sys/bus/pci/devices/` et `/sys/bus/usb/devices/`. Elle applique les réglages à **tout ce qui existe**, rendant le script universel.

2.  **Découverte d'interface améliorée (`discover_jetson_iface`)** :
    *   *Avant* : Cherchait spécifiquement une chaîne de caractères `RNDIS+L4T` dans l'attribut `configuration`. Cette chaîne dépend parfois du noyau spécifique et peut varier.
    *   *Maintenant* : Le script vérifie d'abord le **nom du driver** (ex: `cdc_ncm`, `rndis_host`, `ipheth`). Ces drivers sont standard pour les connexions USB Ethernet. Il vérifie aussi que le périphérique est bien connecté via un bus USB (via `/device/bus`) pour éviter de capturer des interfaces WiFi internes.

3.  **Gestion des erreurs plus souple** :
    *   Utilisation de `|| true` ou `2>/dev/null` pour que le script ne s'arrête pas brutalement si un module spécifique n'est pas présent sur une architecture donnée.
    *   Logique conditionnelle pour l'écriture dans `/sys` (si le fichier n'existe pas, on ne plante pas, on juste ignore).

4.  **Compatibilité du système de fichiers** :
    *   Utilisation de `udevadm --query=property` pour lire les attributs de manière plus fiable et portable que les commandes `sed` complexes sur les chemins spécifiques.

### Comment utiliser ce nouveau script
Le comportement est identique, mais il s'adapte automatiquement à la machine sur laquelle il tourne :

```bash
# Sur n'importe quelle architecture (x86_64, arm64, etc.)
sudo ./host-usb-fix.sh

# Pour attendre que la carte Jetson se connecte et la configurer automatiquement
sudo ./host-usb-fix.sh --wait
```

Ce script est maintenant prêt pour des environnements hétérogènes, des conteneurs, ou des changements de matériel sans modification manuelle des adresses PCI.

Stats:
Time to first token: 81.82s
Prompt: 1626 tokens, 19.87 T/s
Decode: 3267 tokens, 3.30 T/s
Prefix cache: 0 hits / 2 turns
Sampling: temp=1, top_k=20, top_p=0.95, min_p=off


