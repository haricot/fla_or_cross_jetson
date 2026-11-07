use secrecy::SecretString;
use secretspec::{NamedResolution, Secrets};
use std::error::Error;
use std::fmt;
use std::path::{Path, PathBuf};

/// Stable abstraction used by jetson-side tooling.  The rest of the project
/// does not need to know which secrets backend is active.
pub trait SecretResolver {
    fn resolve(&self, name: &str) -> Result<Option<SecretString>, SecretResolveError>;
}

#[derive(Debug, Clone)]
pub struct SecretResolveError(String);

impl SecretResolveError {
    fn new(message: impl Into<String>) -> Self {
        Self(message.into())
    }
}

impl fmt::Display for SecretResolveError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl Error for SecretResolveError {}

#[derive(Debug, Clone)]
pub struct SecretSpecResolver {
    manifest: PathBuf,
    provider: String,
    profile: String,
    reason: String,
}

impl SecretSpecResolver {
    pub fn new(
        manifest: impl Into<PathBuf>,
        provider: impl Into<String>,
        profile: impl Into<String>,
        reason: impl Into<String>,
    ) -> Self {
        Self {
            manifest: manifest.into(),
            provider: provider.into(),
            profile: profile.into(),
            reason: reason.into(),
        }
    }

    pub fn manifest(&self) -> &Path {
        &self.manifest
    }
}

impl SecretResolver for SecretSpecResolver {
    fn resolve(&self, name: &str) -> Result<Option<SecretString>, SecretResolveError> {
        let mut secrets = Secrets::load_from(&self.manifest)
            .map_err(|e| SecretResolveError::new(format!("SecretSpec manifest: {e}")))?;
        secrets.set_provider(self.provider.clone());
        secrets.set_profile(self.profile.clone());
        let secrets = secrets.with_reason(self.reason.clone());

        match secrets
            .resolve_named(name)
            .map_err(|e| SecretResolveError::new(format!("SecretSpec resolve {name}: {e}")))?
        {
            NamedResolution::Resolved(secret) => {
                if secret.as_path {
                    return Err(SecretResolveError::new(format!(
                        "secret {name} is configured as_path; jetson-secret-plane expects an inline value"
                    )));
                }
                let value = secret.value.ok_or_else(|| {
                    SecretResolveError::new(format!("secret {name} resolved without an inline value"))
                })?;
                Ok(Some(SecretString::from(value)))
            }
            NamedResolution::Missing { .. } | NamedResolution::Undeclared => Ok(None),
        }
    }
}
