# fla_or_cross_jetson V2

> Version: `2.0.0-alpha4-fix17` — SecretSpec EOF-safe staging + Headless Secret Settings Bootstrap.

Cible matériellement validée : **JetPack 7.2.1 / Jetson Linux R39.2.1 / Jetson Orin Nano Super / NVMe**. Fix14 ajoute des profils R39.2.1 pour les autres Orin et Thor, sans prétendre à une validation hardware tant qu’un run réel n’a pas été effectué.

La V2 garde le gate cross CUDA 13.3/sm87 déjà validé et fix14 étend le Generic Cross à sm110 pour Thor. `alpha4-fix8` conserve les providers, le **Smart Host Flash Guard**, la détection APX stricte et ajoute une bascule logicielle automatique vers Force Recovery lorsqu'un Jetson déjà booté est visible comme gadget L4T USB.

## V2-R1 — SDK Manager 26.1 (branche de fiabilisation)

Cette branche sélectionne **SDK Manager 26.1** par défaut, sans changer le BSP JetPack 7.2.1 / L4T R39.2.1 ni la toolchain CUDA 13.3 de fix17. L'image SDK Manager utilise un nouveau tag (`:jp721-sdkm261`) pour conserver l'ancienne 2.4.1. La disponibilité de 26.1 dans le dépôt APT NVIDIA est contrôlée explicitement ; aucune substitution silencieuse n'est autorisée.

```sh
./jetsonctl flash image-status
./jetsonctl flash image               # construction explicite du conteneur
./jetsonctl flash sdkmanager-version  # version du client dans l'image READY
./gates/audit-r1.sh                 # validations non destructives
```

Le chemin NFS/RPC/IPv6 reste en place. Le contrôle host recovery refuse désormais un périphérique APX détecté uniquement via sysfs si son nœud USB dans `/dev/bus/usb` est absent. Pour revenir temporairement à SDK Manager 2.4.1, définir **les deux** variables `SDK_MANAGER_APT_VERSION_PREFIX=2.4.1` et `SDK_MANAGER_IMAGE=fla-or-cross-jetson-sdkm:jp721`. Voir [docs/V2-R1-SDKMANAGER-261.md](docs/V2-R1-SDKMANAGER-261.md).


## alpha4-fix17 — SecretSpec EOF-safe staging

Fix17 corrige un arrêt silencieux observé en vrai après `native CUDA SDK: APPLIED`. Le resolver Rust écrit volontairement le secret exact via `print!()` sans ajouter de LF. Bash `read` retourne 1 à EOF pour une dernière ligne non terminée par LF, même si la variable a été remplie; avec `set -e`, `create-user` quittait juste après `rootfs: PASS`.

Les lecteurs du mot de passe et du PSK Wi-Fi tolèrent maintenant EOF sans LF lorsqu'une valeur non vide a bien été lue, tout en rejetant explicitement un fichier réellement vide. Aucun octet n'est ajouté au secret.

Après mise à jour vers fix17, relancer exactement la même commande `headless-flash --secret-settings`; les secrets keyring et le CUDA natif déjà appliqué sont réutilisés.

## alpha4-fix16 — Headless Secret Settings Bootstrap

Fix16 ajoute `--secret-settings` au `headless-flash` (`--secret_settings` est accepté comme alias). Cette option prépare le Secret Plane **avant le preflight flash**, mais uniquement lorsque nécessaire :

```text
resolver absent/stale
  -> cargo build --release secret-plane

JETSON_PASSWORD absent + --user actif
  -> SecretSpec CLI 0.20.x installé si nécessaire
  -> prompt SecretSpec/keyring
  -> store (value hidden)

WIFI_PSK absent + --wifi-ssid actif
  -> SecretSpec CLI 0.20.x installé si nécessaire
  -> prompt SecretSpec/keyring
  -> store (value hidden)

puis
  -> secrets status
  -> secrets doctor
  -> résolution éphémère 0700/0600
  -> preflight headless normal
```

Un secret déjà présent est conservé sans nouvelle saisie. Une source explicite (`--password-file`, `--password-interactive`, `--wifi-psk-file`, `--wifi-psk-openssl-file`) reste prioritaire et empêche le prompt keyring correspondant.

Exemple recommandé pour un premier flash/reflash reproductible :

```bash
./jetsonctl headless-flash \
  --platform orin-nano-super \
  --volume "$VOLUME" \
  --download-provider local \
  --secret-settings \
  --locale fr_FR.UTF-8 \
  --keyboard fr \
  --user np \
  --hostname jetson-orin \
  --autologin 1 \
  --flash-target nvme \
  --native-cuda-sdk \
  --ssh-public-key-file ~/.ssh/id_ed25519_jetson.pub \
  --ssh-key-only \
  --wifi-ssid T6r2 \
  --recovery-ssh-user np \
  --recovery-ssh-host 192.168.55.1
```

`--secret-settings` automatise le setup, mais ne place toujours aucune valeur secrète dans argv ni dans `$VOLUME/secrets`. Le resolver et le CLI ne sont reconstruits/installés que si requis. Si un secret manque, un TTY est obligatoire pour le prompt keyring.

`--dry-run --secret-settings` est strictement non-mutant : il affiche `WOULD BUILD`, `WOULD PROMPT+STORE` et `WOULD RUN` sans compiler, installer ou écrire dans le keyring.

`--secret-settings` est incompatible avec `--no-secret-plane` et automatise volontairement uniquement le provider host writable `keyring`.


## alpha4-fix15 — SecretSpec Secret Plane

Fix15 conserve **tous** les correctifs fix12/fix13/fix14 (NFS/RPC, IPv6 initrd, firewalld, provisioning Wi-Fi/SSH, CUDA 13.3 natif, Generic Cross et `--platform`) et remplace le chemin recommandé de gestion des secrets hôte par **SecretSpec 0.20 + keyring**. Le runtime Jetson dispose d'un profil `systemd-credential` pour les applications gérées par systemd.

Architecture :

```text
jetsonctl / headless-flash
        |
        v
trait SecretResolver
        |
        +-- SecretSpec 0.20
        |      +-- keyring://              host Linux
        |      +-- systemd-credential://   services Jetson
        |
        +-- secrecy::SecretString          frontière mémoire Rust
```

Aucun serveur, `age` ou SOPS n'est requis. `secretspec.toml` contient seulement le **contrat** et les routes de providers, jamais les valeurs.

Installer les outils sur l'hôte :

```bash
./jetsonctl secrets install
./jetsonctl secrets build-resolver
./jetsonctl secrets doctor
```

`secrets install` installe SecretSpec `0.20.0` avec seulement les features CLI + keyring. `build-resolver` compile le petit adapter Rust `SecretResolver`; le reste de `jetsonctl` ne dépend donc pas directement de l'API SecretSpec.

Provisionner le keyring, avec saisie masquée et aucune valeur sur argv :

```bash
./jetsonctl secrets set-password
./jetsonctl secrets set-wifi
./jetsonctl secrets status
```

Le headless peut ensuite être lancé sans fichier de mot de passe ni PSK :

```bash
./jetsonctl headless-flash \
  --platform orin-nano-super \
  --volume "$VOLUME" \
  --locale fr_FR.UTF-8 \
  --keyboard fr \
  --user np \
  --hostname jetson-orin \
  --autologin 1 \
  --flash-target nvme \
  --ssh-public-key-file ~/.ssh/id_ed25519_jetson.pub \
  --ssh-key-only \
  --wifi-ssid T6r2
```

Priorité de résolution :

```text
source fichier/option CLI explicite
        -> SecretSpec/keyring
        -> prompt interactif (mot de passe seulement)
        -> échec explicite si un PSK Wi-Fi demandé reste absent
```

Les valeurs lues depuis SecretSpec sont copiées uniquement dans un répertoire de staging `0700`, sous fichiers `0600`, pour la durée de la commande. Elles ne sont **jamais** recopiées dans `$VOLUME/secrets`. Les anciennes options `--password-file`, `--wifi-psk-file` et `--wifi-psk-openssl-file` restent disponibles pour compatibilité.

Le manifeste définit aussi un profil `cross` :

```text
GITHUB_TOKEN
GHCR_TOKEN
```

Ils sont optionnels : un dépôt public comme `haricot/mistral.rs` se clone sans secret. Pour un dépôt GitHub privé, SecretSpec 0.20 peut configurer son credential helper avec le manifeste du projet, sans mettre le token dans l'URL ou l'historique shell.

```bash
./jetsonctl secrets set-github-token

secretspec --file "$PWD/secretspec.toml" git configure \
  --url https://github.com \
  --token-secret GITHUB_TOKEN \
  --profile cross \
  --provider keyring \
  --username YOUR_GITHUB_USERNAME \
  --global
```

La modification Git globale demande confirmation. Le Generic Cross clone ensuite normalement avec `git`; aucun token n'est injecté dans l'URL. Pour GHCR, le même principe est disponible via `secretspec docker configure` et `GHCR_TOKEN`.

Enfin le profil `runtime` utilise :

```text
systemd-credential://
  HF_TOKEN
  API_TOKEN
```

Une application Jetson peut donc recevoir des secrets via `LoadCredential=` ou `LoadCredentialEncrypted=` puis les résoudre avec le même `SecretSpecResolver`. Voir `secret-plane/systemd/README.md`.


## alpha4-fix14 — Multi-Jetson Platform Profiles

Fix14 ajoute un niveau matériel explicite `--platform`. Le sélecteur ne change pas seulement le nom du board : il résout le **board config NVIDIA**, le SoC, les PID APX/RCM, la stratégie de flash, la compute capability CUDA, le CUDA Upgrade Package natif et les gates post-flash.

Lister les profils :

```bash
./jetsonctl platform list
./jetsonctl platform current
./jetsonctl platform show agx-thor-t5000
```

Profils intégrés :

| `--platform` | NVIDIA config | APX PID(s) | CUDA | état projet |
|---|---|---|---|---|
| `orin-nano` | `jetson-orin-nano-devkit` | `7523,7623` | sm87 | non testé hardware |
| `orin-nano-super` | `jetson-orin-nano-devkit-super` | `7523,7623` | sm87 | **testé end-to-end** |
| `orin-nx` | `jetson-orin-nano-devkit` | `7323,7423` | sm87 | non testé hardware |
| `orin-nx-super` | `jetson-orin-nano-devkit-super` | `7323,7423` | sm87 | non testé hardware |
| `agx-orin` | `jetson-agx-orin-devkit` | `7023` | sm87 | non testé hardware |
| `agx-orin-super` | `jetson-agx-orin-devkit-super` | `7223` | sm87 | non testé hardware |
| `agx-orin-industrial` | `jetson-agx-orin-devkit-industrial` | `7023` | sm87 | non testé hardware |
| `agx-thor-t5000` | `jetson-agx-thor-devkit` | `7026` | sm110 | non testé hardware |
| `agx-thor-t4000` | `jetson-agx-thor-t4000` | `7226` | sm110 | non testé hardware |

Le profil par défaut reste `orin-nano-super`, afin qu’un script fix13 continue à utiliser exactement la plateforme déjà validée.

Headless :

```bash
./jetsonctl headless-flash \
  --platform orin-nano-super \
  --volume "$VOLUME" \
  --user np \
  --hostname jetson-orin \
  --flash-target nvme \
  --native-cuda-sdk \
  --ssh-public-key-file ~/.ssh/id_ed25519_jetson.pub \
  --ssh-key-only
```

Un override expert du fichier `.conf` NVIDIA reste possible :

```bash
./jetsonctl headless-flash \
  --platform orin-nano-super \
  --nvidia-board-config jetson-orin-nano-devkit-super \
  ...
```

`--platform` est global : il peut aussi être placé sur le Generic Cross :

```bash
./jetsonctl cross cargo \
  --platform orin-nano-super \
  --repo https://github.com/haricot/mistral.rs \
  --ref lfm25_dspark \
  --package mistralrs-cli \
  --bin mistralrs \
  --features 'cuda,flash-attn'
```

Pour Thor, la même commande sélectionne `sm_110` et le CUDA Upgrade Package `cuda-compat-13-3`; pour Orin elle sélectionne `sm_87` et `cuda-compat-orin-13-3`. L'image cross elle-même est générique AArch64/SBSA et vérifie à sa construction qu'elle sait émettre les deux architectures.

Les stratégies de flash sont distinctes :

```text
orin-nx-nano + nvme
  -> --external-device nvme0n1p1
  -> flash_l4t_t234_nvme.xml
  -> QSPI XML explicite (chemin validé sur Orin Nano Super)

agx-orin + internal
  -> <board> internal

agx-orin + nvme
  -> --external-device nvme0n1p1
  -> flash_l4t_t234_nvme.xml
  -> <board> external

thor + nvme
  -> <board> internal
  -> board config R39.2.1 gère QSPI + NVMe
```

Les corrections fix12 **NFS/RPC, IPv6 initrd, firewalld et restauration d'état restent actives**. Les PID APX sont maintenant injectés jusqu'aux helpers lancés via `sudo`, afin que le Smart Host Flash Guard ne retombe pas silencieusement sur les PID Orin Nano. Pour Thor, le gate gadget USB post-boot et l'auto Force Recovery sont désactivés par défaut tant que leurs sémantiques n'ont pas été validées matériellement par ce projet.

Le nom interne est `JETSON_PLATFORM`; l'outil n'utilise volontairement pas la variable générique `PLATFORM`, souvent définie par Docker/BuildKit (`linux/amd64`).


## alpha4-fix13 — Jetson Native SDK + Generic Cross

Fix13 conserve tous les gates matériels de fix12 et ajoute deux piliers indépendants mais alignés sur **CUDA 13.3 / sm87** :

1. **Native SDK target** : le headless installe par défaut `cuda-toolkit-13-3` + `cuda-compat-orin-13-3` directement dans `Linux_for_Tegra/rootfs` avant la génération des images. Le stage est fingerprinté (`native-cuda.digest`), audité et invalide automatiquement les images si sa configuration change.
2. **Generic cross** : l'image x86_64 contient Rust + target `aarch64-unknown-linux-gnu`, GCC AArch64 et `cuda-cross-sbsa-13-3`. Le vrai rootfs Jetson est monté read-only sous `/opt/jetson-sysroot` pour fournir les bibliothèques target NVIDIA/Ubuntu lors du link.

Le headless standard suffit :

```bash
./jetsonctl headless-flash \
  --volume "$VOLUME" \
  --user np \
  --hostname jetson-orin \
  --flash-target nvme \
  --native-cuda-sdk \
  --ssh-public-key-file ~/.ssh/id_ed25519_jetson.pub \
  --ssh-key-only \
  --wifi-ssid T6r2 \
  --wifi-psk-openssl-file "$VOLUME/secrets/wifi-psk.enc"
```

`--native-cuda-sdk` est activé par défaut dans le profil fix13. Pour une image L4T minimale sans toolkit natif :

```bash
./jetsonctl headless-flash ... --no-native-cuda-sdk
```

Le stage peut aussi être piloté séparément :

```bash
./jetsonctl native-sdk status
./jetsonctl native-sdk apply
```

Après boot, l'environnement de login sélectionne `/usr/local/cuda-13.3` et ajoute `/usr/local/cuda-13.3/compat_orin` au `LD_LIBRARY_PATH`, conformément au mécanisme CUDA Upgrade Package pour Orin.

### Cross générique

Exemple MistralRS sur une branche spéciale :

```bash
./jetsonctl build-image cross
./jetsonctl gate cross

./jetsonctl cross cargo \
  --repo https://github.com/haricot/mistral.rs \
  --ref lfm25_dspark \
  --package mistralrs-cli \
  --bin mistralrs \
  --features 'cuda,flash-attn' \
  --artifact-name mistralrs-lfm25-sm87
```

Le résultat est copié sous :

```text
$VOLUME/dist/mistralrs-lfm25-sm87
```

et subit deux audits : ELF AArch64 + absence de chemins build/stubs dans le runtime, puis résolution des bibliothèques GPU dans le sysroot Jetson.

Le wrapper historique reste disponible :

```bash
MISTRALRS_REPO=https://github.com/haricot/mistral.rs \
MISTRALRS_REF=lfm25_dspark \
MISTRALRS_FEATURES='cuda,flash-attn' \
./jetsonctl build mistralrs
```

Déploiement sans `scp` (fonctionne aussi avec une adresse IPv6 link-local scopée) :

```bash
./jetsonctl cross deploy \
  --artifact "$VOLUME/dist/mistralrs-lfm25-sm87" \
  --host 'fe80::1%enp60s0u1' \
  --user np \
  --identity ~/.ssh/id_ed25519_jetson
```

Le binaire est déposé par défaut dans `~/.local/bin/` sur le Jetson.

Gate natif après boot :

```bash
./jetsonctl target gate \
  --host 'fe80::1%enp60s0u1' \
  --user np \
  --identity ~/.ssh/id_ed25519_jetson
```

Ce gate compile **sur le Jetson** un mini programme CUDA avec `nvcc -arch=sm_87`, l'exécute avec `compat_orin`, et exige `cc=8.7`.


## alpha4-fix12 — Dynamic Initrd Network + NFS Recovery + Provisioning Gates

Fix12 est basé sur un flash matériel R39.2.1 réellement mené jusqu'à `Flash is successful` sur Orin Nano Super/NVMe. Il corrige les blocages observés pendant et après ce run :

- **NFS/RPC hôte** : snapshot de l'état initial, montage de `/proc/fs/nfsd`, redémarrage temporaire de `rpcbind` et `nfs-server`, `exportfs -rav`, puis gates `rpcinfo` pour NFS `100003` et `mountd` `100005`; l'état de services/export est restauré ensuite sans modifier leur enablement permanent.
- **RNDIS initrd dynamique** : `disable_ipv6=0` est vérifié après écriture, `fc00:1:1:0::1/64` et `fe80::2/64` sont appliquées avec `ip addr replace ... nodad`, le watcher réagit toutes les 250 ms jusqu'au gate puis toutes les 500 ms pendant le flash.
- **firewalld** : l'interface RNDIS/L4T est placée temporairement dans la zone runtime `trusted`; sa zone précédente est snapshotée et restaurée.
- **post-flash USB** : après restauration du guard, le gadget `0955:7020` est redétecté et l'hôte reçoit `192.168.55.100/24` comme adresse secondaire, sans supprimer une éventuelle adresse NetworkManager `10.42.0.1/24`; `192.168.55.1` et `fe80::1%iface` sont testés.
- **SSH** : `00-fla-hardening.conf` remplace l'ancien `60-*`; `PermitRootLogin no` est toujours appliqué, et `--ssh-key-only` ajoute `PasswordAuthentication no` + `KbdInteractiveAuthentication no` avant les snippets cloud-init.
- **Wi-Fi** : le PSK chiffré est déchiffré sans log, converti en PSK WPA 64-hex pour éviter les problèmes d'échappement du keyfile, le reste du profil est sérialisé via `nmcli --offline`, puis le fichier est validé (`0600`, root:root, `key-mgmt`, PSK présent exactement une fois, parse NetworkManager).
- **migration fix11 -> fix12** : un nouveau `provisioning_schema` force la réapplication du provisioning même si un ancien `user.digest` existe; les artefacts SSH/Wi-Fi sont aussi contrôlés avant de considérer l'état utilisateur comme appliqué.

Le chemin critique devient :

```text
APX/RCM
  -> NFS/RPC/mountd gates
  -> initrd boot
  -> firewalld trusted + IPv6 canonical
  -> fe80::1 ping gate
  -> global SSH fc00:1:1::2
  -> NFS mounts
  -> QSPI + NVMe
  -> Flash is successful
  -> restore host flash state
  -> 0955:7020 post-flash management gate
```


## alpha4-fix11 — Host-Canonical NFS + Correct Flash-Only

Fix11 corrige la phase qui suit la génération des images initrd :

- `Linux_for_Tegra` est monté dans le conteneur sous le **même chemin absolu que sur l’hôte** (`$VOLUME/downloads/Linux_for_Tegra`).
- le Smart Host Flash Guard installe temporairement `/etc/exports.d/fla-or-cross-jetson.exports` avec `rootfs`, `tools/kernel_flash/images` et `tools/kernel_flash/tmp`, puis restaure l’état précédent après le flash ;
- les anciens exports `sdk_manager` sont signalés mais jamais supprimés arbitrairement ;
- le conteneur ne tente plus de piloter `/etc/exports` dans son propre mount namespace : il vérifie les exports du véritable serveur NFS hôte ;
- `--flash-only` reçoit explicitement `jetson-orin-nano-devkit-super external`, conformément au contrat NVIDIA séparé génération/flash.

Le flux devient :

```text
generate images
  -> Smart Host NFS Guard
  -> exact host/container L4T path
  -> NFS export gate
  -> l4t_initrd_flash.sh --flash-only <board> <rootdev>
  -> initrd USB/RNDIS
  -> QSPI + NVMe
```

## Automatic Force Recovery — alpha4-fix8

Le mode APX/RCM reste le seul état accepté pour lancer les outils NVIDIA de flash. En revanche, lorsqu'un Jetson déjà booté apparaît comme gadget USB L4T (`0955:7020`), `headless-flash` tente maintenant d'entrer en Force Recovery sans intervention physique.

Flux par défaut :

```text
0955:7020 L4T gadget
  -> détecter l'interface USB réseau
  -> host 192.168.55.100/24 temporaire si nécessaire
  -> SSH vers 192.168.55.1
  -> sudo reboot --force forced-recovery
  -> attendre disparition du gadget L4T
  -> attendre APX 0955:7523/7623
  -> APX/RCM gate PASS
  -> génération/flash NVIDIA
```

La commande dédiée est :

```bash
./jetsonctl flash enter-recovery \
  --recovery-ssh-user old_user \
  --recovery-ssh-host 192.168.55.1
```

La commande dédiée transmet réellement ces options à la bascule SSH. Si l'authentification par mot de passe fonctionne, `--recovery-ssh-key` peut être omis. Par défaut, un échec automatique retourne immédiatement; ajoute `--wait-manual` uniquement si tu veux garder la commande ouverte en attendant un passage physique en APX/RCM.

`headless-flash` l'utilise automatiquement. Les options de contrôle sont :

```text
--auto-recovery             activé par défaut
--no-auto-recovery          désactive la bascule logicielle
--recovery-ssh-host HOST    défaut 192.168.55.1
--recovery-ssh-user USER    utilisateur du système actuellement booté
--recovery-ssh-key PATH     clé privée SSH; elle n'est jamais copiée dans VOLUME
```

Si `--ssh-public-key-file ~/.ssh/id_ed25519_jetson.pub` est fourni et que `~/.ssh/id_ed25519_jetson` existe, la clé privée correspondante est automatiquement proposée au client SSH. Si SSH ou `sudo` demande une authentification, la saisie passe directement par le TTY distant et n'est pas capturée par `jetsonctl`.

Si la bascule logicielle échoue, le guard continue d'attendre un vrai APX/RCM et affiche le fallback manuel J14/power-cycle.

## Stockage persistant

```bash
export VOLUME=/chemin/ssd/jetson-v2
mkdir -p "$VOLUME"
```

```text
$VOLUME/
├── downloads/
│   └── jetson-linux/
│       └── R39.2.1/            # provider direct
├── sdkmanager/
│   ├── downloads/              # provider sdkmanager
│   ├── catalog/                # sorties --query
│   ├── response-files/
│   └── manifests/
├── .nvsdkm/                    # session SDK Manager persistante
├── custom/
├── secrets/
├── tmp/
└── cache/
```

## Download providers

### 1. `direct` — défaut

Télécharge uniquement le BSP et le Sample RootFS requis par le profil, directement depuis NVIDIA.

```bash
./jetsonctl flash download --provider direct
```

Les fichiers attendus sont :

```text
Jetson_Linux_R39.2.1_aarch64.tbz2
Tegra_Linux_Sample-Root-Filesystem_R39.2.1_aarch64.tbz2
```

Les téléchargements partiels utilisent un fichier `.part` et sont repris avec `curl --continue-at -`. Un fichier final existant et lisible par `tar` est réutilisé.

Le profil expose :

```text
L4T_DIRECT_BASE_URL
L4T_BSP_URL
L4T_ROOTFS_URL
```

pour permettre de remplacer facilement les URLs si NVIDIA change son arborescence.

### 2. `sdkmanager` — volontaire / catalogue complet

SDK Manager n'est plus déclenché automatiquement par `headless-flash`. Il reste disponible pour télécharger ou comparer les composants JetPack et SDK additionnels.

Catalogue disponible pour le compte NVIDIA :

```bash
./jetsonctl flash download --provider sdkmanager --query
```

Le résultat est aussi conservé sous :

```text
$VOLUME/sdkmanager/catalog/
```

Afficher aussi les versions archivées/secondaires :

```bash
./jetsonctl flash download \
  --provider sdkmanager \
  --query \
  --show-all-versions
```

Téléchargement SDK Manager standard :

```bash
./jetsonctl flash download --provider sdkmanager
```

Sélection fine après inspection du `--query` :

```bash
./jetsonctl flash download \
  --provider sdkmanager \
  --select "Jetson SDK Components"
```

Les options suivantes sont transmises à SDK Manager et peuvent être répétées :

```text
--select TITLE
--deselect TITLE
--additional-sdk "TITLE VERSION"
--host
```

Les titres exacts doivent venir du `--query`; ils ne sont pas codés en dur par fla_or_cross_jetson.

### 3. `local` — aucun réseau

Vérifie seulement qu'un BSP et un Sample RootFS valides existent déjà sous `downloads/` ou `sdkmanager/downloads/` :

```bash
./jetsonctl flash download --provider local
```

Aucun téléchargement n'est effectué.

## Headless flash

Le provider de téléchargement par défaut est maintenant `direct`.

```bash
./jetsonctl headless-flash \
  --volume "${VOLUME}" \
  --locale fr_FR.UTF-8 \
  --keyboard fr \
  --user jetson \
  --hostname jetson-orin \
  --autologin 1 \
  --flash-target nvme \
  --password-interactive \
  --ssh-public-key-file ~/.ssh/id_ed25519.pub \
  --ssh-key-only \
  --wifi-ssid MonReseau \
  --wifi-psk-openssl-file "${VOLUME}/secrets/wifi-psk.enc"
```

S'il manque les archives, `headless-flash` utilise automatiquement :

```text
--download-provider direct
```

On peut le rendre explicite :

```bash
./jetsonctl headless-flash \
  --download-provider direct \
  ...
```

ou imposer uniquement des archives déjà présentes :

```bash
./jetsonctl headless-flash \
  --download-provider local \
  ...
```

`sdkmanager` reste possible explicitement :

```bash
./jetsonctl headless-flash \
  --download-provider sdkmanager \
  ...
```

mais ce mode peut demander le device-login NVIDIA. Pour un flash normal il est recommandé de télécharger auparavant les extras via SDK Manager, puis de laisser `headless-flash` utiliser `direct`/`local` pour le BSP.


## Smart Host Flash Guard

Le parcours `headless-flash` reprend les heuristiques éprouvées de la V1 (`host-usb-fix.sh` + `flash-diagnose.sh`) mais les orchestre automatiquement.

Avant le flash, le guard :

```text
Force Recovery 0955
  -> découvre le périphérique USB réel dans sysfs
  -> remonte vers le root-hub USB
  -> remonte vers le contrôleur PCI/xHCI
  -> snapshot power/control
  -> force uniquement ce chemin à on

usbcore.autosuspend
  -> snapshot
  -> -1 pendant le flash

IPv6 global/default
  -> snapshot
  -> enable pendant le flash
```

Quand l'initrd expose `RNDIS+L4T`, le watcher hôte :

```text
RNDIS+L4T
  -> interface UP
  -> IPv6 enabled
  -> fc00:1:1:0::1/64
  -> fe80::2/64
  -> ping fe80::1%iface
```

Après succès, erreur ou interruption, les valeurs hôte snapshotées sont restaurées. Les runs sont journalisés sous :

```text
$VOLUME/logs/flash/YYYYMMDD-HHMMSS-PID/
├── host-state.tsv
├── network-watch.log
├── network-ready          # présent si l'initrd a répondu
└── diagnose.txt           # créé automatiquement en cas d'échec backend
```

Le `--dry-run` reste strictement non modifiant : le guard n'est activé qu'après la confirmation `y/N`.

### Commandes manuelles

Diagnostic lecture seule :

```bash
./jetsonctl host usb status
./jetsonctl flash doctor
./jetsonctl flash diagnose
```

Appliquer temporairement les corrections V1 hors d'un flash :

```bash
./jetsonctl host usb fix --wait-recovery
```

Puis restaurer explicitement :

```bash
./jetsonctl host usb restore
```

Diagnostic initrd avec correction de l'interface :

```bash
./jetsonctl flash diagnose --fix
```

Le state utilisé par le mode manuel est `$VOLUME/state/host-usb-manual.tsv`.

### Dépendances hôte

Le host peut rester Arch/Manjaro, Debian/Ubuntu, Fedora, etc. Le guard attend seulement les utilitaires Linux usuels : Docker, `lsusb`, `ip`, `udevadm`, `sysctl` et `sudo`. Le runtime NVIDIA reste Ubuntu 24.04 dans le conteneur.

## Dry-run

```bash
./jetsonctl headless-flash \
  --volume "$VOLUME" \
  --download-provider direct \
  --flash-target nvme \
  --dry-run
```

Aucun téléchargement, aucune modification rootfs/secrets, aucune attente Recovery et aucun flash.

## Custom rootfs

```bash
./jetsonctl custom init
./jetsonctl custom show
```

Le contenu persistant est sous :

```text
$VOLUME/custom/
├── packages.txt
├── services-enable.txt
├── overlay/
└── hooks/
```

Préparation manuelle détaillée :

```bash
./jetsonctl flash prepare
./jetsonctl custom apply
./jetsonctl native-sdk apply
./jetsonctl flash create-user
./jetsonctl flash generate-images
./jetsonctl flash nvme --reuse-images
```

Les images sont fingerprintées et `--reuse-images` est refusé si le rootfs/custom/native-sdk/user a changé.

## Secrets

Mot de passe Jetson : interactif par défaut, masqué sur `/dev/tty`.

Wi-Fi chiffré au repos :

```bash
./jetsonctl secrets wifi-encrypt
```

Clé SSH publique :

```bash
cp ~/.ssh/id_ed25519.pub "$VOLUME/secrets/authorized_key.pub"
chmod 600 "$VOLUME/secrets/authorized_key.pub"
```

## Cross CUDA 13.3

Le gate de l'image cross valide maintenant **Rust + AArch64 + CUDA/cuBLAS + sm87** :

```bash
./jetsonctl build-image cross
./jetsonctl gate cross
```

Le sysroot cible par défaut est :

```text
$VOLUME/downloads/Linux_for_Tegra/rootfs
```

Il peut être surchargé avec `JETSON_SYSROOT=/chemin/rootfs`. Le builder n'exécute pas les binaires ARM via QEMU : Rust compile sur x86_64, GCC produit l'ELF AArch64, et NVCC produit le device code `sm_87`.

## Notes alpha4-fix2

- `direct`, `sdkmanager`, `local` restent des providers explicites.
- Smart Host Flash Guard reprend les corrections USB/PCI/IPv6 de la V1 avec auto-discovery et restauration.
- `headless-flash` ne lance plus SDK Manager par défaut pour obtenir BSP/rootfs.
- SDK Manager reste un provider avancé pour le catalogue, les groupes et les SDK additionnels.
- Les downloads SDK Manager sont séparés des archives directes.
- `prepare` recherche les archives dans les deux stores.
- `local` évite tout téléchargement BSP/rootfs. Avec fix13, le stage native CUDA 13.3 utilise encore le dépôt NVIDIA; pour un flash strictement offline, pré-provisionne ce SDK dans le custom/cache ou utilise `--no-native-cuda-sdk`.
- Le runtime de flash reste containerisé Ubuntu 24.04 pour conserver l'objectif « host distro agnostic ».


### Flash runtime prerequisites

`alpha4-fix2` bake les prérequis L4T nécessaires avant l'extraction initiale du BSP. Cela inclut notamment `lbzip2`, nécessaire aux archives `.tbz2`. Le script NVIDIA `tools/l4t_flash_prerequisites.sh` reste exécuté après extraction comme validation/upstream completion, mais le bootstrap ne dépend plus de lui pour pouvoir ouvrir les archives.

### Confidentialité du mot de passe utilisateur

Depuis alpha4-fix3, le mot de passe saisi avec `--password-interactive` n'est jamais transmis au helper NVIDIA dans ses arguments. Le helper crée le compte avec une valeur bootstrap non secrète, puis `jetsonctl` applique le vrai mot de passe à l'intérieur du rootfs hors ligne via `chpasswd`. La sortie brute du helper NVIDIA n'est pas affichée. Ceci évite l'exposition du secret dans les logs et dans la ligne de commande visible via `ps`/`/proc`.

### Root requirement for NVIDIA initrd flash

The flash runtime is forced to container UID/GID `0:0`. NVIDIA image generation (`l4t_initrd_flash.sh` / `l4t_create_images_for_kernel_flash.sh`) requires root privileges. `./jetsonctl flash doctor` reports `container root: PASS (EUID=0)` when the runtime is correct.

### alpha4-fix6 — NVIDIA USER=root compatibility

Le runtime de flash normalise l'identité root complète (`uid 0`, `id -un=root`, `USER=root`, `LOGNAME=root`, `HOME=/root`) car les scripts kernel-flash NVIDIA vérifient aussi la variable `USER`. SDK Manager continue à être exécuté sous l'utilisateur `nvidia`.



### Force Recovery strict (alpha4-fix7)

Pour le profil Orin Nano, `jetsonctl` distingue désormais un vrai périphérique APX/RCM d'un gadget L4T normal. `0955:7020` n'est plus accepté comme preuve de Force Recovery. Les PID attendus par défaut sont `7523` (Orin Nano 8 Go) et `7623` (4 Go), configurables via `RECOVERY_USB_PRODUCTS`.

### Live loop devices (alpha4-fix10)

NVIDIA image generation maps `system.img` through `losetup`. The flash runtime bind-mounts host `/dev` so dynamically allocated loop devices remain visible after the container has started. Smart Host Flash Guard validates loop support before invoking the NVIDIA backend.
