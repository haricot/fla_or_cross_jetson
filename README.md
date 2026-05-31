# Jetson SDK Manager Docker Flash Any Distros

Piloter `sdkmanager` et flasher Jetson Orin Nano depuis Docker vers NVMe, cross-compiler avec n'importe quelle distribution linux (optionnel via disque externe).

⚠️ **DRAFT MODE** marche pour moi

Le répertoire `VOLUME` contient les données persistantes:
- `downloads/`
- `tmp/`
- `.nvsdkm/`
- `toolchains/`
- `sources/`

L'idée est de garder les gros artefacts sur un disque dédié, par exemple un disque externe ou un stockage NAS, et non sur le disque système.

## Pré-requis

- Docker avec `docker compose`
- Un répertoire persistant pour `VOLUME`
- Le Jetson branché en mode recovery via USB
- Sur l'hôte: `sudo` fonctionnel

Exemple:

```bash
export VOLUME=/path/to/your/storage/sdk_manager
mkdir -p "$VOLUME"/{downloads,tmp,.nvsdkm,toolchains,sources}
```

## Construction de l'image

```bash
export VOLUME=/path/to/your/storage/sdk_manager
env VOLUME="$VOLUME" \
docker compose build \
  --build-arg FROM_IMAGE=sdkmanager:2.4.0.13236-Ubuntu_24.04 \
  --build-arg JETPACK=6.2.2
```

Remarque: les scripts `sdkmctl.sh` et `sdkm-entrypoint.sh` sont montés dans le conteneur. Modifier ces scripts ne demande pas forcément de rebuild.
L'image embarque maintenant `cuda-12.9` et `cuda-12.6` en x86_64 côté hôte, ce qui permet de sélectionner `CUDA_HOST_TOOLKIT_VERSION=12.6` pour éviter `qemu` sur la phase `nvcc` quand un build Jetson doit matcher CUDA 12.6.

## Flux recommandé

### 1. Téléchargement

```bash
env VOLUME="$VOLUME" docker compose run --rm sdkm download
```

### 2. Préparation du BSP/rootfs

```bash
env VOLUME="$VOLUME" docker compose run --rm sdkm prepare
```

### 3. Flash NVMe

```bash
env VOLUME="$VOLUME" \
docker compose run --rm -e FLASH_TARGET=nvme sdkm flash
```

### 4. Reflash rapide sans régénérer les images

Si les images de flash existent déjà:

```bash
env VOLUME="$VOLUME" \
docker compose run --rm -e FLASH_TARGET=nvme sdkm flash_only
```

## Flux headless recommandé

Le wrapper `headless-flash.sh` prépare l'hôte, surveille l'interface USB du Jetson, crée l'utilisateur par défaut et lance le flash.

Exemple simple:

```bash
./headless-flash.sh \
  --volume "${VOLUME}" \
  --locale fr_FR.UTF-8 \
  --keyboard fr \
  --user jetson \
  --hostname jetson-orin \
  --autologin 1 \
  --flash-target nvme
```

Exemple avec clé SSH et Wi-Fi:

```bash
./headless-flash.sh \
  --volume "${VOLUME}" \
  --locale fr_FR.UTF-8 \
  --keyboard fr \
  --user jetson \
  --hostname jetson-orin \
  --autologin 1 \
  --flash-target nvme \
  --password-file "${VOLUME}"/tmp/jetson_password \
  --ssh-public-key-file ~/.ssh/id_ed25519.pub \
  --ssh-key-only \
  --wifi-ssid MonReseau \
  --wifi-psk-openssl-file "${VOLUME}"/tmp/wifi_psk.enc
```

Si l'interface USB du Jetson est connue et stable sur l'hôte:

```bash
./headless-flash.sh \
  --volume "${VOLUME}" \
  --user jetson \
  --flash-target nvme \
  --host-flash-iface enp60s0u1
```

## Scripts utiles

- `headless-flash.sh`: wrapper principal pour le flash headless
- `host-usb-fix.sh`: corrige l'état USB/PCI et IPv6 côté hôte
- `flash-diagnose.sh`: diagnostic manuel de l'interface initrd USB du Jetson
- `sdkmctl.sh`: logique principale `download`, `prepare`, `flash`, `flash_only`, `crosscompile`

## Secrets Wi-Fi

Le mode le plus simple reste un fichier en clair:

```bash
printf '%s\n' 'VotreMotDePasseWifi' > "${VOLUME}"/tmp/wifi_psk
```

Mais si vous ne voulez pas stocker la PSK en clair sur disque, vous pouvez utiliser OpenSSL:

```bash
printf '%s\n' 'VotreMotDePasseWifi' > /tmp/wifi_psk
openssl enc -aes-256-cbc -pbkdf2 -salt \
  -in /tmp/wifi_psk \
  -out "${VOLUME}"/tmp/wifi_psk.enc
rm -f /tmp/wifi_psk
```

Puis lancer:

```bash
./headless-flash.sh \
  --volume "${VOLUME}" \
  --user jetson \
  --flash-target nvme \
  --wifi-ssid MonReseau \
  --wifi-psk-openssl-file "${VOLUME}"/tmp/wifi_psk.enc
```

Le script demandera la passphrase OpenSSL, déchiffrera le contenu dans un fichier temporaire local, puis supprimera ce fichier à la fin.

## Sudo de l'utilisateur créé

L'utilisateur créé par le flux headless est maintenant explicitement ajouté au groupe `sudo`. Il peut donc faire:

```bash
sudo -i
```

avec son mot de passe utilisateur.

Si vous voulez un accès `sudo` sans mot de passe:

```bash
./headless-flash.sh \
  --volume "${VOLUME}" \
  --user jetson \
  --flash-target nvme \
  --sudo-nopasswd
```

## Cross-compile

```
env VOLUME=/path/to/your/storage/sdk_manager \
  CUDA_COMPUTE_CAP=87 \
  MISTRALRS_FEATURES='cuda flash-attn nccl' \
  ./build-mistralrs.sh
```
  
```
env VOLUME=/path/to/your/storage/sdk_manager \
  CUDA_TOOLKIT_VERSION=12.6
  CUDA_HOST_TOOLKIT_VERSION=12.6 \
  CUDA_COMPUTE_CAP=87 \
  MISTRALRS_PACKAGE='mistralrs-cli' \
  MISTRALRS_FEATURES='cuda cudnn flash-attn' \
  MISTRALRS_FORCE_CLEAN=1 \
 ./build-mistralrs.sh
```



## Problèmes connus

### 1. USB autosuspend / gestion d'énergie côté hôte

Symptômes possibles:
- timeout USB pendant `tegrarcm_v2`
- APX visible puis disparition
- blocage sur `Waiting for target to boot-up...`
- instabilité lors du passage recovery -> initrd flash

Cause observée:
- autosuspend USB
- contrôleur PCI/USB laissé en `power/control=auto`

Contournement:
- utiliser `host-usb-fix.sh`
- ou `headless-flash.sh`, qui le lance automatiquement

Commande manuelle:

```bash
sudo ./host-usb-fix.sh
sudo ./host-usb-fix.sh --wait --iface enp60s0u1
```

### 2. IPv6 désactivé sur l'interface USB du Jetson

Symptômes observés:

```text
Waiting for device to expose ssh ...
net.ipv6.conf.enp60s0u1.disable_ipv6 = 1
IPv6 is disabled. Please enable ipv6 to use this tool
Error: ipv6: IPv6 is disabled on this device.
```

Le flash initrd NVIDIA a besoin de cette connectivité IPv6 sur l'interface USB du Jetson.

Contournement manuel:

```bash
sudo sysctl -w net.ipv6.conf.enp60s0u1.disable_ipv6=0
sudo ip link set dev enp60s0u1 up
sudo ip -6 addr add fc00:1:1:0::1/64 dev enp60s0u1 2>/dev/null || true
sudo ip -6 addr add fe80::2/64 dev enp60s0u1 2>/dev/null || true
ping6 -c 3 fe80::1%enp60s0u1
```

Ce dépôt automatise maintenant ce point:
- via `host-usb-fix.sh --wait`
- via `headless-flash.sh`
- via un watcher intégré dans `sdkmctl.sh` pendant `flash` et `flash_only`

### 3. Message `Unknown device "/sys/class/net/usb0"`

Ce message peut apparaître dans les logs NVIDIA. Dans les cas observés ici, ce n'était pas le vrai blocage.

Le vrai problème était plutôt:
- l'interface hôte réelle n'était pas `usb0`
- ou l'IPv6 était désactivé sur l'interface USB détectée, par exemple `enp60s0u1`

### 4. Erreur SSH après reflash

Après un reflash, la clé hôte SSH du Jetson change. L'hôte peut alors refuser la connexion:

```text
WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!
```

Corriger avec:

```bash
ssh-keygen -R 192.168.55.1
ssh jetson@192.168.55.1
```

### 5. NFS requis pour l'initrd flash

Le flash initrd NVIDIA attend que les répertoires suivants soient exportés:
- `rootfs`
- `tools/kernel_flash/images`
- `tools/kernel_flash/tmp`

Le script `sdkmctl.sh` gère maintenant les exports nécessaires côté conteneur/hôte Docker.

### 6. Capacité disque

Les artefacts Jetson sont volumineux. Si `VOLUME` pointe mal ou si les montages Docker ne sont pas corrects, les données peuvent finir sur le disque système.

Toujours vérifier:

```bash
df -h
```

et utiliser un `VOLUME` situé sur le disque de stockage prévu.

## Diagnostic manuel

Pour observer l'interface USB initrd après le boot recovery:

```bash
./flash-diagnose.sh --fix
```

Pour surveiller le réseau:

```bash
watch -n 1 'ip -br link; echo; ip -6 addr'
```

## Connexion après flash

Une fois le flash terminé, les accès les plus courants sont:

```bash
ssh jetson@192.168.55.1
```

ou, si le Wi-Fi a été préconfiguré, via l'adresse IP du Jetson sur votre réseau local.

## Rootfs custom: concepts, méthode et exemples

### Qu'est-ce que le rootfs?

Le **rootfs** (root filesystem) est l'arborescence complète du système de fichiers Linux qui sera montée en `/` au boot du Jetson. Il contient:

- le système de base Ubuntu (libc, systemd, apt, NetworkManager…)
- les drivers NVIDIA et les bibliothèques BSP (CUDA runtime, cuDNN, TensorRT, V4L2…)
- les modules noyau (`/lib/modules/...`)
- les fichiers de configuration (`/etc/...`)
- les utilisateurs, services, et logiciels applicatifs

NVIDIA fournit un **sample rootfs** (`Tegra_Linux_Sample-Root-Filesystem_*_aarch64.tbz2`), un Ubuntu 22.04 minimal préconfiguré. La commande `prepare` de ce dépôt l'extrait dans `Linux_for_Tegra/rootfs/`, puis exécute `apply_binaries.sh` pour y injecter les composants BSP.

### Pourquoi personnaliser le rootfs?

Cas d'usage typiques:

| Objectif | Approche |
|---|---|
| Pré-installer des paquets (Python, Docker, clés SSH…) | Overlay sur le sample rootfs |
| Reproduire un environnement de production identique | Rootfs capturé depuis un Jetson existant |
| Minimiser la taille (pas de GUI, pas d'outils dev) | Rootfs construit depuis un conteneur Docker/OCI |
| Inclure un applicatif métier embarqué | N'importe laquelle des approches ci-dessus |

### Rôle de `apply_binaries.sh`

Le script `apply_binaries.sh` fourni par NVIDIA dans `Linux_for_Tegra/` est **indispensable** si le contenu de `rootfs/` a été remplacé intégralement. Il copie dans le rootfs:

1. Les **modules noyau** correspondant à la version L4T/JetPack
2. Les **firmware blobs** GPU/display/codec
3. Les **bibliothèques NVIDIA** (libcuda, libnvos, libnvrm…)
4. Les **fichiers de configuration Tegra** (udev rules, xorg, etc.)
5. Les **overlays noyau** (device-tree overlays)

> [!CAUTION]
> Si vous ne relancez pas `apply_binaries.sh` après avoir remplacé le rootfs, le Jetson bootera sur un Linux qui ne reconnaîtra pas son GPU, ses codecs vidéo, ni ses interfaces spécifiques.

> [!IMPORTANT]
> `apply_binaries.sh` doit s'exécuter en tant que `root` (via `sudo`), car il doit fixer les permissions, les suid bits, et les propriétaires de certains fichiers système (notamment `/usr/bin/sudo`).

### Contrainte de cohérence de version

Le firmware QSPI, le noyau, les modules et le rootfs doivent tous provenir de la **même version JetPack/L4T**:

```
JetPack 6.2.2 → L4T R36.x
  ├── QSPI/bootloader   ← doit être 6.2.2
  ├── noyau + DTB        ← doit être 6.2.2
  ├── modules noyau      ← doit être 6.2.2
  └── rootfs utilisateur ← doit être compatible 6.2.2
```

> [!WARNING]
> Ne mélangez jamais un firmware JetPack 6 avec un rootfs construit sur JetPack 5 (ou inversement). Les modules noyau ne correspondent pas, les ABI des drivers changent, et le Jetson refusera probablement de démarrer ou aura des comportements erratiques (GPU invisible, CUDA inutilisable).

---

### Workflow complet: flash JetPack 6.2 avec rootfs custom

Cas typique:
- Jetson Orin Nano neuf, ou upgrade depuis un firmware JetPack antérieur
- objectif: flasher JetPack 6.2.2
- stockage racine sur NVMe
- rootfs personnalisé à flasher directement

#### 1. Construire l'image Docker

```bash
export VOLUME=/path/to/your/storage/sdk_manager
env VOLUME="$VOLUME" \
docker compose build \
  --build-arg FROM_IMAGE=sdkmanager:2.4.0.13236-Ubuntu_24.04 \
  --build-arg JETPACK=6.2.2
```

#### 2. Télécharger les artefacts NVIDIA

```bash
env VOLUME="$VOLUME" docker compose run --rm sdkm download
```

#### 3. Préparer `Linux_for_Tegra`

Cette étape extrait le BSP et le sample rootfs, puis exécute `apply_binaries.sh`:

```bash
env VOLUME="$VOLUME" docker compose run --rm sdkm prepare
```

À ce stade, `${VOLUME}/downloads/Linux_for_Tegra/rootfs/` contient un rootfs Ubuntu fonctionnel avec les composants NVIDIA.

#### 4. Injecter le rootfs custom

C'est ici qu'intervient la personnalisation. Trois approches principales sont décrites ci-dessous.

---

### Approche A: overlay sur le sample rootfs (recommandé pour débuter)

La méthode la plus simple: garder le sample rootfs NVIDIA tel quel, et y appliquer vos modifications par-dessus.

```bash
L4T="${VOLUME}/downloads/Linux_for_Tegra"

# Installer des paquets via chroot + qemu
sudo cp /usr/bin/qemu-aarch64-static "${L4T}/rootfs/usr/bin/"
sudo mount --bind /proc "${L4T}/rootfs/proc"
sudo mount --bind /sys  "${L4T}/rootfs/sys"
sudo mount --bind /dev  "${L4T}/rootfs/dev"

sudo chroot "${L4T}/rootfs" /bin/bash -c '
  apt-get update
  apt-get install -y python3-pip htop tmux
  pip3 install numpy
  systemctl enable ssh
'

sudo umount "${L4T}/rootfs/dev"
sudo umount "${L4T}/rootfs/sys"
sudo umount "${L4T}/rootfs/proc"
sudo rm -f "${L4T}/rootfs/usr/bin/qemu-aarch64-static"

# Copier des fichiers de configuration supplémentaires
sudo cp mon-service.service "${L4T}/rootfs/etc/systemd/system/"
sudo mkdir -p "${L4T}/rootfs/opt/mon-app"
sudo cp -r mon-app/* "${L4T}/rootfs/opt/mon-app/"
```

> [!NOTE]
> Pas besoin de relancer `apply_binaries.sh` ici: le rootfs d'origine n'a pas été remplacé, les binaires NVIDIA sont déjà en place.

---

### Approche B: rootfs complet remplacé (depuis zéro ou depuis un Jetson existant)

Si vous remplacez **tout** le contenu de `rootfs/`, il faut relancer `apply_binaries.sh`.

**Depuis un Jetson existant (capture):**

```bash
# Sur le Jetson, créer une archive du système de fichiers
sudo tar czpf /tmp/jetson-rootfs.tar.gz \
  --exclude=/proc --exclude=/sys --exclude=/dev \
  --exclude=/run --exclude=/tmp --exclude=/mnt \
  --exclude=/media --exclude=/lost+found \
  /

# Transférer l'archive sur la machine hôte
scp jetson@192.168.55.1:/tmp/jetson-rootfs.tar.gz .
```

```bash
# Sur la machine hôte, remplacer le rootfs
L4T="${VOLUME}/downloads/Linux_for_Tegra"

sudo rm -rf "${L4T}/rootfs"
sudo mkdir -p "${L4T}/rootfs"
sudo tar xzpf jetson-rootfs.tar.gz -C "${L4T}/rootfs"

# Recréer les répertoires spéciaux
sudo mkdir -p "${L4T}/rootfs"/{proc,sys,dev,run,tmp,mnt,media}

# OBLIGATOIRE: réinjecter les composants BSP
cd "${L4T}"
sudo ./apply_binaries.sh
```

**Depuis un conteneur Docker/OCI (rootfs minimal):**

```bash
# Exporter un conteneur comme rootfs
docker create --name jetson-rootfs arm64v8/ubuntu:22.04
docker export jetson-rootfs | sudo tar xpf - -C "${L4T}/rootfs"
docker rm jetson-rootfs

# OBLIGATOIRE: réinjecter les composants BSP
cd "${L4T}"
sudo ./apply_binaries.sh
```

> [!WARNING]
> Un rootfs exporté depuis Docker ne contient ni kernel, ni modules, ni les blobs NVIDIA. Sans `apply_binaries.sh`, le Jetson n'aura pas de support GPU. Pensez aussi à installer les paquets de base nécessaires au boot (systemd, network-manager, sudo, etc.).

---

### Approche C: rsync d'un rootfs pré-construit

Si vous maintenez un rootfs JetPack 6.2.2 dans un répertoire ou un partage réseau:

```bash
L4T="${VOLUME}/downloads/Linux_for_Tegra"

sudo rsync -aHAX --delete /chemin/vers/mon-rootfs-custom/ "${L4T}/rootfs/"

# Relancer apply_binaries.sh si le rootfs a été reconstruit
cd "${L4T}"
sudo ./apply_binaries.sh
```

Drapeaux `rsync` importants:
- `-a`: mode archive (récursif, permissions, timestamps, liens symboliques)
- `-H`: préserver les hard links
- `-A`: préserver les ACL
- `-X`: préserver les attributs étendus (xattr, capabilities)
- `--delete`: supprimer les fichiers destination absents de la source

> [!IMPORTANT]
> Le trailing `/` sur le chemin source est crucial avec rsync. `source/` copie le **contenu** du répertoire; `source` (sans slash) copie le répertoire lui-même à l'intérieur de la destination.

---

#### 5. Flasher firmware + NVMe avec le rootfs custom

Après injection du rootfs personnalisé, flasher l'ensemble cohérent en une fois:

```bash
env VOLUME="$VOLUME" \
docker compose run --rm -e FLASH_TARGET=nvme sdkm flash
```

Ce workflow:
- met à jour le QSPI/firmware JetPack 6.2.x
- prépare l'environnement initrd
- flashe le NVMe avec votre rootfs custom

#### 6. Reflash rapide si les images existent déjà

Si vous n'avez modifié que peu de choses et que les images sont déjà générées:

```bash
env VOLUME="$VOLUME" \
docker compose run --rm -e FLASH_TARGET=nvme sdkm flash_only
```

> [!NOTE]
> `flash_only` réutilise les images déjà générées par un `flash` précédent. Si vous avez modifié le rootfs entre-temps, il faut relancer `flash` (et non `flash_only`) pour régénérer les images.

---

### Intégration avec `headless-flash.sh`

Le wrapper `headless-flash.sh` supporte nativement le rootfs custom: il suffit de modifier le contenu de `rootfs/` **avant** de lancer le script. Le flux `headless-flash.sh` appelle `prepare` uniquement si le BSP n'existe pas encore, puis crée l'utilisateur par défaut directement dans le rootfs avant de flasher.

```bash
# 1. Préparer le BSP + sample rootfs
env VOLUME="$VOLUME" docker compose run --rm sdkm prepare

# 2. Personnaliser le rootfs (approche A, B ou C ci-dessus)
# ...

# 3. Flasher en mode headless — l'utilisateur sera créé dans votre rootfs custom
./headless-flash.sh \
  --volume "${VOLUME}" \
  --user jetson \
  --hostname jetson-orin \
  --flash-target nvme
```

---

### Troubleshooting rootfs custom

| Symptôme | Cause probable | Solution |
|---|---|---|
| `sudo: /usr/bin/sudo must be owned by uid 0` au boot | `chown` récursif incorrect sur `rootfs/` | Supprimer `Linux_for_Tegra/`, relancer `prepare`, réappliquer le custom |
| GPU invisible (`nvidia-smi` échoue) | `apply_binaries.sh` non exécuté | `cd Linux_for_Tegra && sudo ./apply_binaries.sh` |
| Kernel panic au boot | Modules noyau absents ou incompatibles | Vérifier la cohérence de version JetPack/L4T |
| Pas de réseau après boot | NetworkManager absent du rootfs | Installer `network-manager` via chroot avant le flash |
| `Rootfs corrompue: .../sudo appartient à X:Y` | Ce dépôt le détecte automatiquement | Supprimer `Linux_for_Tegra/` et recommencer |

> [!TIP]
> Le script `sdkmctl.sh` valide automatiquement les permissions du rootfs avant le flash (voir la fonction `validate_rootfs_ownership`). Si `/usr/bin/sudo` ou `/etc/sudo.conf` n'appartiennent pas à `root:root`, le flash sera bloqué avec un message explicite.

### Recommandation générale

Pour une machine encore en JetPack 5.x, il est possible en théorie de ne flasher que le QSPI/firmware d'abord, puis le rootfs ensuite. Mais dans ce dépôt, le workflow recommandé reste:
- préparer un BSP JetPack 6.2.2 complet
- injecter le rootfs custom compatible
- flasher firmware + support de boot + rootfs dans la même opération

Cela évite les incohérences entre:
- version du bootloader UEFI/QSPI
- overlays BSP
- noyau/modules
- rootfs utilisateur
