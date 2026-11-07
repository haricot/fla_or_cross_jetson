# alpha4-fix17 — SecretSpec EOF-safe staging

- Corrige l'arrêt silencieux de `flash create-user` après `rootfs: PASS` avec les secrets SecretSpec sans LF final.
- Garde le resolver byte-exact (`print!`, aucun newline artificiel).
- Rend les lectures password / Wi-Fi PSK / OpenSSL PSK EOF-safe sous `set -e`.
- Rejette toujours explicitement les fichiers secrets réellement vides.
- Conserve intégralement fix12..fix16 (NFS/RPC, IPv6, firewalld, SecretSpec, platform, CUDA, Generic Cross).

# alpha4-fix16 — Headless Secret Settings Bootstrap

- Ajoute `headless-flash --secret-settings` avec alias `--secret_settings`.
- Build du resolver uniquement s'il est absent ou plus ancien que `Cargo.toml`/`Cargo.lock`/`src/*.rs`.
- Installe SecretSpec CLI 0.20.x uniquement lorsqu'un secret absent doit être écrit dans le keyring.
- Ne redemande jamais `JETSON_PASSWORD`/`WIFI_PSK` s'ils sont déjà présents.
- Les sources explicites password/Wi-Fi restent prioritaires et désactivent le prompt keyring correspondant.
- `--dry-run --secret-settings` est non-mutant et ne fait que décrire les actions.
- `status` + `doctor` sont exécutés avant le preflight flash après initialisation.
- Aucun secret SecretSpec n'est persisté dans `$VOLUME/secrets`; staging 0700/0600 fix15 conservé.
- NFS/RPC, IPv6, firewalld, native CUDA, platform et Generic Cross restent hérités.

# alpha4-fix15 — SecretSpec Secret Plane

- SecretSpec est pinne a `=0.20.0`; `secrecy` a `=0.10.3`.
- Provider host par defaut : `keyring://`.
- Provider runtime Jetson : `systemd-credential://` (read-only).
- `trait SecretResolver` isole le coeur du projet de l'API SecretSpec.
- Les secrets headless SecretSpec sont stages en `0600`, jamais persistes dans `$VOLUME/secrets`.
- Compatibilite legacy conservee pour password/Wi-Fi files et OpenSSL.
- `GITHUB_TOKEN`/`GHCR_TOKEN` sont declares dans le profil `cross`, mais restent optionnels pour les repos/images publics.
- Pas de serveur, pas de `age`, pas de SOPS requis.
- Tous les gates fix12 NFS/RPC + IPv6/firewalld et fix13/fix14 CUDA/platform restent actifs.

## alpha4-fix14 — Multi-Jetson Platform Profiles

- Ajoute `--platform` comme sélecteur global sans utiliser la variable générique Docker `PLATFORM`; l'état interne est `JETSON_PLATFORM`.
- Ajoute 9 profils R39.2.1 : Orin Nano/NX normal+Super, AGX Orin normal/Super/Industrial, Thor T5000/T4000.
- Résout board config, PID APX, flash layout, compute capability (`sm87`/`sm110`) et CUDA Upgrade Package (`compat_orin`/`compat`).
- Conserve `orin-nano-super` comme défaut et comme seule plateforme actuellement validée end-to-end par ce projet.
- Le Smart Host Guard reçoit désormais explicitement les PID plateforme à travers `sudo`; NFS/RPC, IPv6, firewalld et restauration fix12 restent inchangés.
- Le Generic Cross devient une image AArch64/SBSA commune qui valide à la construction `sm87` et `sm110`; le gate compile ensuite l'architecture de la plateforme sélectionnée.
- Thor utilise le flow R39.2.1 `<board> internal` pour le NVMe; son auto Force Recovery/post-flash gadget gate reste désactivé par défaut jusqu'à validation hardware.

## alpha4-fix13 — Jetson Native SDK + Generic Cross

- Ajoute un stage `native-sdk` fingerprinté au rootfs : `cuda-toolkit-13-3` + `cuda-compat-orin-13-3`, appliqué automatiquement par `headless-flash` avant génération des images.
- Ajoute `/etc/profile.d/fla-cuda-13.3.sh` pour sélectionner le toolkit versionné et `compat_orin` en session.
- Ajoute Rust dans l'image cross x86_64 et le target `aarch64-unknown-linux-gnu`.
- Ajoute `jetsonctl cross cargo` générique (`repo/ref/package/bin/features`) avec le vrai `Linux_for_Tegra/rootfs` monté comme sysroot target.
- Conserve `jetsonctl build mistralrs` comme wrapper de compatibilité.
- Ajoute `cross deploy` et `target gate`; ce dernier compile/exécute un mini programme CUDA `sm_87` sur le Jetson.
- Les images sont désormais invalidées aussi quand le stage CUDA natif change.

## alpha4-fix12 — Dynamic Initrd Network + NFS Recovery + Provisioning Gates

- Flash matériel R39.2.1 validé jusqu'à `Flash is successful` sur Orin Nano Super + NVMe.
- Corrige le blocage réel `mount.nfs .../tools/kernel_flash/images /mnt` en restaurant la logique V1 de pile NFS complète : `/proc/fs/nfsd`, restart `rpcbind`/`nfs-server`, `exportfs -rav`, `rpc.nfsd`, gates `rpcinfo` 100003/100005, puis restauration de l'état initial.
- Corrige la course `disable_ipv6=1` sur l'interface RNDIS : application stricte/readback, adresses NVIDIA `/64`, watcher 250 ms/500 ms et re-découverte après re-enumeration.
- Ajoute snapshot/restauration runtime de la zone firewalld et `trusted` uniquement pendant le flash initrd.
- Ajoute un gate post-flash L4T (`0955:7020`) qui pose `192.168.55.100/24` en adresse secondaire et teste `192.168.55.1` / `fe80::1%iface`.
- Corrige SSH key-only avec un drop-in `00-fla-hardening.conf`; root SSH est toujours interdit.
- Corrige le provisioning Wi-Fi : dérivation WPA 64-hex, sérialisation SSID par `nmcli --offline`, validations secret-safe du keyfile.
- Invalide explicitement le provisioning fix11 via `provisioning_schema=alpha4-fix12-v1` afin de réappliquer les nouveaux invariants sur un rootfs existant.


## alpha4-fix11 — Host-Canonical NFS + Correct Flash-Only

- Corrige `l4t_initrd_flash.sh: .../--flash-only.conf`: le second passage fournit désormais explicitement `$BOARD $FLASH_ROOTDEV`.
- NFS initrd : abandon de la gestion des exports depuis le namespace du conteneur. Un `host/nfs-guard.sh` installe temporairement trois exports sous leurs chemins hôte réels puis les restaure.
- `DOWNLOAD_DIR` devient configurable et Compose monte `$VOLUME/downloads` à son chemin absolu identique dans le conteneur, tout en conservant `/work/downloads` comme alias de compatibilité.
- Gate synthétique `begin -> verify -> restore` du NFS guard validé.

# Notes — 2.0.0-alpha4-fix8

## Automatic Force Recovery

- `0955:7020` est identifié comme gadget L4T booté, pas comme Force Recovery.
- `0955:7523/7623` reste le gate APX/RCM autorisant le flash.
- ajout de `host/enter-recovery.sh` ;
- ajout de `jetsonctl flash enter-recovery` ;
- `headless-flash` tente automatiquement `sudo reboot --force forced-recovery` via SSH sur `192.168.55.1` lorsque le gadget L4T est présent ;
- l'interface USB du gadget est découverte par ascendance sysfs et reçoit temporairement `192.168.55.100/24` si nécessaire ;
- le succès n'est jamais déduit du code retour SSH : seule l'apparition d'un PID APX attendu valide la bascule ;
- la clé privée de recovery reste côté hôte et n'est jamais copiée dans `$VOLUME` ;
- les prompts SSH/sudo restent interactifs et masqués ;
- fallback physique conservé si le système actuel n'est pas joignable.

Gates synthétiques validés :

```text
0955:7020 -> software-recovery eligible
USB iface  -> auto-discovery PASS
SSH reboot -> simulated disconnect rc=255
0955:7523 -> APX/RCM PASS
```

---



## Smart Host Flash Guard

`alpha4-fix1` reprend les deux comportements V1 importants :

```text
host-usb-fix.sh   -> host/usb-guard.sh + host/usb-discover.sh
flash-diagnose.sh -> flash/diagnose.sh + flash/network-watch.sh
```

Différences V2 :

- aucune liste PCI/USB propre à une machine n'est codée en dur ; le chemin est découvert depuis le périphérique NVIDIA Recovery `0955` dans sysfs ;
- le chemin USB est remonté jusqu'au root hub puis au contrôleur PCI/xHCI ;
- `power/control`, `usbcore.autosuspend` et l'état IPv6 sont snapshotés avant modification ;
- l'interface `RNDIS+L4T` est découverte dynamiquement et corrigée dès son apparition ;
- les modifications hôte sont restaurées après le flash ;
- en cas d'échec backend, un diagnostic est écrit dans `$VOLUME/logs/flash/.../diagnose.txt` ;
- le watcher historique dans le conteneur reste disponible comme fallback si le conteneur est lancé sans `jetsonctl`.

Commandes :

```text
jetsonctl host usb status
jetsonctl host usb fix [--wait-recovery]
jetsonctl host usb restore
jetsonctl flash diagnose [--fix]
```

`flash doctor` est maintenant lecture seule : il ne bootstrappe plus silencieusement l'image de runtime si elle est absente/stale.

## Pivot download providers

`alpha4` sépare la provenance des artefacts NVIDIA de la préparation/flash :

```text
direct      BSP + Sample RootFS R39.2.1
sdkmanager  catalogue/composants JetPack/SDK additionnels
local       validation/reuse sans réseau
```

Le flash standard ne dépend plus du device-login SDK Manager.

## Direct provider

Destination :

```text
$VOLUME/downloads/jetson-linux/R39.2.1/
```

Le téléchargement reprend les `.part` et valide les tarballs avant renommage final.

Valeurs du profil :

```text
L4T_DIRECT_BASE_URL=https://developer.download.nvidia.com/embedded/L4T/r39_Release_v2.1/release
L4T_BSP_FILE=Jetson_Linux_R39.2.1_aarch64.tbz2
L4T_ROOTFS_FILE=Tegra_Linux_Sample-Root-Filesystem_R39.2.1_aarch64.tbz2
```

Les URLs restent surchargeables pour éviter de figer définitivement l'arborescence NVIDIA.

## SDK Manager provider

Destination :

```text
$VOLUME/sdkmanager/downloads/
$VOLUME/sdkmanager/catalog/
```

`--query` appelle :

```text
sdkmanager --query non-interactive --login-type devzone --product Jetson
```

Les sélections sont passées telles quelles via :

```text
--select
--deselect
--additional-sdk
--host
```

La session reste persistante sous `$VOLUME/.nvsdkm`.

## Local provider

Ne télécharge rien. Il valide les deux tarballs attendus, qu'ils proviennent du store direct ou SDK Manager.

## Headless

Le profil définit :

```text
DOWNLOAD_PROVIDER=direct
```

`headless-flash --download-provider local` devient bloquant si les archives sont absentes, ce qui est intentionnel.

## Compatibilité flash

Le backend de préparation utilise toujours `Linux_for_Tegra` R39.2.1, `apply_binaries.sh` et `l4t_initrd_flash.sh` avec la configuration `jetson-orin-nano-devkit-super`.


## alpha4-fix2 — Flash Prerequisites Baked

- Fixe l'échec `tar (child): lbzip2: Cannot exec` pendant `flash prepare`.
- Préinstalle dans l'image runtime les dépendances de flash L4T usuelles avant extraction du BSP : `lbzip2`, `bzip2`, `xz-utils`, `lz4`, `zstd`, `abootimg`, `binutils`, `cpio`, `device-tree-compiler`, `dosfstools`, `gdisk`, `libxml2-utils`, `netcat-openbsd`, `parted`, `python3-yaml`, `sshpass`, `uuid-runtime`, `xmlstarlet`, `xxd`, etc.
- Conserve l'extraction sans postinst de `qemu-user-static` pour fournir `qemu-aarch64-static` sans dépendre de `binfmt_misc` pendant `docker build`.
- Ajoute un gate Docker qui crée puis ré-extrait réellement un `.tbz2` avec `lbzip2`.
- Le fingerprint du runtime change automatiquement : une image alpha4-fix1 est donc détectée `STALE_REBUILD_REQUIRED`, mais BuildKit réutilise les couches compatibles.

## alpha4-fix3 — Secret-safe default user creation

- le vrai mot de passe Jetson n'est plus passé à `l4t_create_default_user.sh --password`;
- le helper NVIDIA reçoit uniquement un mot de passe bootstrap non secret et sa sortie est capturée;
- le vrai mot de passe est appliqué ensuite via `chpasswd` depuis un fichier temporaire `0600` dans le rootfs hors ligne;
- le fichier temporaire est supprimé sur succès et échec;
- si l'application du mot de passe final échoue, le compte bootstrap est verrouillé avant abandon;
- les diagnostics d'échec filtrent toute ligne évoquant password/passwd/credential/secret.

## alpha4-fix5 — Root-safe NVIDIA flash runtime

- Force le service Docker de flash à `user: "0:0"`.
- `jetsonctl` ajoute aussi `docker compose run --user 0:0` pour rendre le comportement explicite même si Compose/les réglages Docker changent.
- Ajoute un gate `EUID=0` avant `prepare`, `custom-apply`, `create-user`, `generate-images`, `flash-only` et les prérequis NVIDIA.
- `flash doctor` affiche désormais `container root: PASS/FAIL`.
- Le diagnostic `RNDIS+L4T NOT DETECTED` après un échec de génération d'images n'est pas un blocage réseau : l'initrd n'a pas encore été démarré.

## alpha4-fix6 — NVIDIA USER=root compatibility

- Corrige le cas où Docker exécute le conteneur avec `EUID=0` mais conserve `USER=nvidia` dans l'environnement.
- `l4t_create_images_for_kernel_flash.sh` vérifie littéralement `USER == root`; fix6 normalise donc `USER=root`, `LOGNAME=root` et `HOME=/root` pour le runtime de flash.
- Le gate root vérifie désormais aussi `id -un == root`.
- `flash doctor` affiche le contexte complet `EUID/id/USER/LOGNAME/HOME`.
- Les appels SDK Manager qui doivent rester non-root passent explicitement `USER=nvidia LOGNAME=nvidia HOME=/home/nvidia`.



## alpha4-fix7 — True RCM Detection

- Ne considère plus tout périphérique NVIDIA `0955:*` comme Force Recovery.
- Profil Orin Nano: APX/RCM attendu `0955:7523` (8 Go) ou `0955:7623` (4 Go).
- `0955:7020 ... L4T (Linux for Tegra) running on Tegra` est classé `WRONG MODE`, pas `PASS`.
- `host-preflight`, Smart Host Guard et le conteneur utilisent la même liste `RECOVERY_USB_PRODUCTS`.
- Le flash refuse avant `flash.sh` si le Jetson n'est pas réellement en APX/RCM.
- Réintègre l'idempotence des secrets lorsque source et destination sont le même fichier.

## alpha4-fix9 — Recovery CLI argument forwarding

- Corrige `./jetsonctl flash enter-recovery`: les options `--recovery-ssh-host`, `--recovery-ssh-user` et `--recovery-ssh-key` n'étaient pas transmises et les valeurs par défaut (`jetson@192.168.55.1`) étaient utilisées.
- Accepte aussi les alias courts du helper: `--host`, `--user`, `--identity`.
- Préserve le code retour réel du helper de bascule logicielle.
- La commande dédiée échoue maintenant immédiatement si SSH/reboot n'atteint pas APX/RCM, au lieu d'attendre silencieusement le fallback manuel pendant 1800 s.
- `--wait-manual` réactive explicitement l'attente du fallback physique.
- Aucun changement du runtime Docker: une image fix7/fix8 `READY` reste utilisable.

## alpha4-fix10 — Live Loop Devices

- Fix `losetup: system.img: failed to set up loop device: No such file or directory` during NVIDIA `system.img` generation.
- Bind-mount host `/dev` live into the privileged flash runtime (`/dev:/dev`) so loop devices allocated after container start remain visible.
- Smart Host Flash Guard loads/checks the host `loop` subsystem and performs a safe 1 MiB attach/detach gate after user confirmation.
- `flash doctor` reports container loop visibility.
- `generate-images` refuses early if `/dev/loop-control` or a free `/dev/loopN` is not visible.
