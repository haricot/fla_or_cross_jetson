# jetson-secret-plane

Petit adapter Rust de `fla_or_cross_jetson` entre le trait stable `SecretResolver` et SecretSpec 0.20.

Dépendances volontairement minimales :

- `secretspec = =0.20.0`, `default-features = false`, feature `keyring` ;
- `secrecy = =0.10.3`.

Le provider `systemd-credential` est intégré au cœur SecretSpec et ne nécessite pas de feature supplémentaire.

Build :

```bash
./jetsonctl secrets build-resolver
```

Lecture host/keyring :

```bash
secret-plane/target/release/jetson-secret-resolver \
  probe WIFI_PSK \
  --manifest ./secretspec.toml \
  --provider keyring \
  --profile headless \
  --reason manual-probe
```

`get` est une frontière d'exposition volontaire : sa sortie stdout contient uniquement la valeur et doit être redirigée vers un fichier temporaire `0600`. Les scripts de fix15 font cette redirection automatiquement et ne journalisent jamais la valeur.
