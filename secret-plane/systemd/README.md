# SecretSpec + systemd credentials on the Jetson

The `runtime` profile in the repository `secretspec.toml` uses the read-only
`systemd-credential://` provider. The application must be started by systemd.

Example unit fragment:

```ini
[Service]
LoadCredentialEncrypted=HF_TOKEN:/etc/credstore.encrypted/hf-token
LoadCredentialEncrypted=API_TOKEN:/etc/credstore.encrypted/api-token
Environment=SECRETSPEC_FILE=/opt/fla-or-cross-jetson/secretspec.toml
Environment=SECRETSPEC_PROFILE=runtime
Environment=SECRETSPEC_PROVIDER=systemd-credential
```

An application linked with `secret-plane` can then construct a
`SecretSpecResolver` with provider `systemd-credential` and profile `runtime`.
The credential value remains in systemd's runtime credential directory and is
not written to `/etc/environment`.

Create encrypted systemd credentials on the target with `systemd-creds encrypt`
according to the target's key policy. Do not commit the plaintext input.
