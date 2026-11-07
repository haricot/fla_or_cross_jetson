# Persistent layout — 2.0.0-alpha4-fix14

```text
$VOLUME/
├── downloads/
│   ├── jetson-linux/
│   │   └── R39.2.1/             # provider direct
│   └── Linux_for_Tegra/         # BSP préparé
├── sdkmanager/
│   ├── downloads/               # provider sdkmanager
│   ├── catalog/                 # --query
│   ├── response-files/
│   └── manifests/
├── .nvsdkm/                     # login/session SDK Manager
├── sources/                       # checkouts git persistants (générique + mistral.rs)
├── tmp/
├── custom/
├── secrets/
├── dist/
├── state/
│   └── host-usb-manual.tsv      # état du guard manuel
├── logs/
│   └── flash/                   # logs/snapshots par run
└── cache/
    ├── cargo-home/
    ├── cargo-target/              # target dirs MistralRS + generic cross
    └── buildkit/
        ├── cross/
        └── sdkmanager/
```

`cache clean all` ne supprime pas les downloads, le catalogue SDK Manager, les sources, le custom ou les secrets.

Le stockage interne Docker reste dans le `data-root` Docker de l'hôte sauf configuration Docker séparée.

`logs/flash` et `state` sont persistants hors ZIP. Ils ne contiennent pas les mots de passe/PSK ; les secrets restent sous `$VOLUME/secrets`.
