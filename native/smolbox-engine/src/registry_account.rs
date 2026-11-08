//! Operation-local, read-only operator registry setup. No settings migration,
//! token serialization, shared bearer cache, SDK CLI or alternate SDK namespace.
use crate::{Error, ErrorCode, Result};
use reqwest::Url;
use serde::Deserialize;
use smolvm::registry::{PullAuth, RegistryConfig};
use std::collections::HashMap;
use std::fs::OpenOptions;
use std::io::Read;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::Path;
use std::time::Instant;

const CONFIG_BYTES: u64 = 1024 * 1024;
const SECRET_BYTES: usize = 16384;

#[derive(Clone, Copy)]
pub(crate) enum Family {
    Machines,
    Images,
}

#[derive(Default, Deserialize)]
struct AccountFile {
    #[serde(default)]
    machines: RegistryConfig,
    #[serde(default)]
    images: RegistryConfig,
    #[serde(default)]
    smolbox: AccountPolicy,
}
#[derive(Default, Deserialize)]
struct AccountPolicy {
    #[serde(default)]
    registry_token_realms: HashMap<String, String>,
}

pub(crate) enum Credential {
    Anonymous,
    Bearer(String),
    Basic { username: String, password: String },
    Identity { token: String, realm: Option<Url> },
}
impl std::fmt::Debug for Credential {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("RegistryAccountCredential(<redacted>)")
    }
}
impl Credential {
    pub(crate) fn direct_bearer(&self) -> Option<&str> {
        match self {
            Self::Bearer(value) => Some(value),
            _ => None,
        }
    }
    pub(crate) fn approved_realm(&self, origin: &Url, realm: &Url) -> bool {
        if realm.scheme() != "https" {
            return false;
        }
        match self {
            Self::Identity {
                realm: Some(approved),
                ..
            } => approved == realm,
            Self::Identity { realm: None, .. } => {
                realm.origin() == origin.origin()
                    || (origin.host_str() == Some("registry-1.docker.io")
                        && realm.host_str() == Some("auth.docker.io")
                        && realm.port_or_known_default() == Some(443))
            }
            Self::Basic { .. } => basic_realm(origin, realm),
            _ => false,
        }
    }
    fn validate(self) -> Result<Self> {
        let valid = match &self {
            Self::Anonymous => true,
            Self::Bearer(token) | Self::Identity { token, .. } => {
                !token.is_empty()
                    && token.len() <= SECRET_BYTES
                    && reqwest::header::HeaderValue::from_str(&format!("Bearer {token}")).is_ok()
            }
            Self::Basic { username, password } => {
                username.len() <= 1024 && password.len() <= SECRET_BYTES
            }
        };
        if valid {
            Ok(self)
        } else {
            Err(Error::before(ErrorCode::Validation))
        }
    }
}

pub(crate) struct Resolved {
    pub origin: Url,
    pub credential: Credential,
}

pub(crate) struct Context<'a> {
    pub deadline: Instant,
    pub cancel: &'a crate::Cancellation,
    pub pool: &'a crate::jobs::JobPool,
}

pub(crate) fn load(
    registry: &str,
    family: Family,
    explicit_identity: bool,
    context: &Context<'_>,
) -> Result<Resolved> {
    let account = current_account()?;
    let config = match family {
        Family::Machines => &account.machines,
        Family::Images => &account.images,
    };
    let origin = route(registry, config)?;
    let key = if registry.ends_with("smolmachines.com") {
        "registry.smolmachines.com"
    } else {
        registry
    };
    let realm = account
        .smolbox
        .registry_token_realms
        .get(key)
        .or_else(|| account.smolbox.registry_token_realms.get(registry));
    let credential = if explicit_identity {
        Credential::Anonymous
    } else {
        select(config, key, realm.map(String::as_str), || {
            docker_credential(key, context)
        })?
    };
    if matches!(credential, Credential::Identity { .. }) {
        crate::RegistryIdentityCredential::validate_destination(registry)?;
        crate::RegistryIdentityCredential::validate_destination(
            origin.host_str().unwrap_or_default(),
        )?;
        if origin.scheme() != "https" {
            return Err(Error::before(ErrorCode::Validation));
        }
    }
    Ok(Resolved { origin, credential })
}

fn current_account() -> Result<AccountFile> {
    let path = smolvm::settings::SmolSettings::config_path()
        .map_err(|_| Error::before(ErrorCode::Validation))?;
    read_account(&path)
}

pub(crate) fn images_config() -> Result<RegistryConfig> {
    Ok(current_account()?.images)
}

fn route(registry: &str, config: &RegistryConfig) -> Result<Url> {
    // Keep SDK endpoint/mirror routing without loading credentials or migrating
    // settings. A mirror may include a repository prefix.
    let endpoint = smolvm::registry::registry_client(registry, config, &PullAuth::Anonymous);
    let mut origin =
        Url::parse(endpoint.base_url()).map_err(|_| Error::before(ErrorCode::Validation))?;
    if !matches!(origin.scheme(), "http" | "https")
        || origin.host_str().is_none()
        || !origin.username().is_empty()
        || origin.password().is_some()
        || origin.query().is_some()
        || origin.fragment().is_some()
    {
        return Err(Error::before(ErrorCode::Validation));
    }
    if !origin.path().ends_with('/') {
        origin.set_path(&format!("{}/", origin.path()));
    }
    Ok(origin)
}

fn read_account(path: &Path) -> Result<AccountFile> {
    if let Some(bytes) = read_bounded(path)? {
        let text = std::str::from_utf8(&bytes).map_err(|_| Error::before(ErrorCode::Validation))?;
        let account: AccountFile =
            toml::from_str(text).map_err(|_| Error::before(ErrorCode::Validation))?;
        if account.machines.registries.len() > 1024
            || account.images.registries.len() > 1024
            || account.smolbox.registry_token_realms.len() > 32
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        for realm in account.smolbox.registry_token_realms.values() {
            crate::RegistryIdentityCredential::validate_realm(realm)?;
        }
        return Ok(account);
    }
    let Some(parent) = path.parent() else {
        return Ok(AccountFile::default());
    };
    let legacy = parent.join("registries.toml");
    let Some(bytes) = read_bounded(&legacy)? else {
        return Ok(AccountFile::default());
    };
    // The SDK migrates legacy entries into images only. Observe that view
    // without writing config.toml or changing the caller's settings.
    let images: RegistryConfig = std::str::from_utf8(&bytes)
        .ok()
        .and_then(|text| toml::from_str(text).ok())
        .unwrap_or_default();
    if images.registries.len() > 1024 {
        return Err(Error::before(ErrorCode::Validation));
    }
    Ok(AccountFile {
        images,
        ..AccountFile::default()
    })
}

fn read_bounded(path: &Path) -> Result<Option<Vec<u8>>> {
    let resolved = match path.canonicalize() {
        Ok(path) => path,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err(Error::before(ErrorCode::Io)),
    };
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(resolved)
        .map_err(|_| Error::before(ErrorCode::Io))?;
    let before = file.metadata().map_err(|_| Error::before(ErrorCode::Io))?;
    if !before.is_file()
        || before.len() > CONFIG_BYTES
        || !matches!(before.uid(), 0) && before.uid() != unsafe { libc::geteuid() }
        || before.mode() & 0o022 != 0
    {
        return Err(Error::before(ErrorCode::Validation));
    }
    let mut bytes = Vec::new();
    (&mut file)
        .take(CONFIG_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| Error::before(ErrorCode::Io))?;
    let after = file.metadata().map_err(|_| Error::before(ErrorCode::Io))?;
    if bytes.len() > CONFIG_BYTES as usize
        || before.len() != after.len()
        || (
            before.mtime(),
            before.mtime_nsec(),
            before.ctime(),
            before.ctime_nsec(),
        ) != (
            after.mtime(),
            after.mtime_nsec(),
            after.ctime(),
            after.ctime_nsec(),
        )
    {
        return Err(Error::before(ErrorCode::Validation));
    }
    Ok(Some(bytes))
}

fn select(
    config: &RegistryConfig,
    key: &str,
    realm: Option<&str>,
    docker: impl FnOnce() -> Result<Option<smolvm::docker_config::DockerCredential>>,
) -> Result<Credential> {
    let credential = if let Some(token) = config
        .registries
        .get(key)
        .and_then(|entry| entry.identity_token.as_ref())
    {
        let realm = realm
            .map(|value| {
                crate::RegistryIdentityCredential::validate_realm(value)?;
                Url::parse(value).map_err(|_| Error::before(ErrorCode::Validation))
            })
            .transpose()?;
        Credential::Identity {
            token: token.clone(),
            realm,
        }
    } else if let Some(auth) =
        tracing::subscriber::with_default(tracing::subscriber::NoSubscriber::default(), || {
            config.get_credentials(key)
        })
    {
        if auth.username == "token" {
            Credential::Bearer(auth.password)
        } else {
            Credential::Basic {
                username: auth.username,
                password: auth.password,
            }
        }
    } else if let Some(auth) = docker()? {
        if auth.is_identity_token() {
            Credential::Anonymous
        } else {
            Credential::Basic {
                username: auth.username,
                password: auth.secret,
            }
        }
    } else {
        Credential::Anonymous
    };
    credential.validate()
}

pub(crate) fn docker_credential(
    key: &str,
    context: &Context<'_>,
) -> Result<Option<smolvm::docker_config::DockerCredential>> {
    let Some(path) = smolvm::docker_config::config_path() else {
        return Ok(None);
    };
    let Some(bytes) = read_bounded(&path)? else {
        return Ok(None);
    };
    docker_from(&bytes, key, |helper, server| {
        crate::registry_provider::get(helper, server, context)
    })
}

fn docker_from(
    bytes: &[u8],
    key: &str,
    provider: impl FnOnce(&str, &str) -> Result<Option<smolvm::docker_config::DockerCredential>>,
) -> Result<Option<smolvm::docker_config::DockerCredential>> {
    let config = std::str::from_utf8(bytes)
        .ok()
        .and_then(smolvm::docker_config::DockerConfig::from_json);
    let Some(config) = config else {
        return Ok(None);
    };
    if let Some(helper) = config.helper_for(key) {
        if helper.len() > 128
            || !helper
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(&byte))
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        if let Some(credential) = provider(helper, &smolvm::docker_config::server_key(key))? {
            return Ok(Some(credential));
        }
    }
    // Keep the SDK's inline matching/decoding, but do not invoke its subprocess
    // runner. This is an in-memory projection, never an operator-file rewrite.
    let mut inline: serde_json::Value =
        serde_json::from_slice(bytes).map_err(|_| Error::before(ErrorCode::Validation))?;
    if let Some(object) = inline.as_object_mut() {
        object.remove("credsStore");
        object.remove("credHelpers");
    }
    let inline =
        serde_json::to_string(&inline).map_err(|_| Error::before(ErrorCode::Validation))?;
    let inline = smolvm::docker_config::DockerConfig::from_json(&inline)
        .ok_or(Error::before(ErrorCode::Validation))?;
    Ok(tracing::subscriber::with_default(
        tracing::subscriber::NoSubscriber::default(),
        || inline.credential_for(key),
    ))
}

fn basic_realm(origin: &Url, realm: &Url) -> bool {
    let registry = origin.host_str().unwrap_or_default();
    let host = realm.host_str().unwrap_or_default();
    match registry {
        "registry-1.docker.io" => host == "auth.docker.io",
        "ghcr.io" | "quay.io" => host == registry,
        value if value.ends_with(".amazonaws.com") => host.ends_with(".amazonaws.com"),
        value if value == "gcr.io" || value.ends_with(".gcr.io") || value.ends_with(".pkg.dev") => {
            host == "oauth2.googleapis.com"
                || host.ends_with(".gcr.io")
                || host.ends_with(".pkg.dev")
        }
        _ => true,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use smolvm::registry::RegistryEntry;
    use std::os::unix::fs::{symlink, PermissionsExt};

    fn configured(entry: RegistryEntry) -> RegistryConfig {
        RegistryConfig {
            registries: HashMap::from([("registry.example".into(), entry)]),
            ..RegistryConfig::default()
        }
    }
    fn selected(config: &RegistryConfig) -> Credential {
        select(config, "registry.example", None, || {
            panic!("unexpected Docker lookup")
        })
        .unwrap()
    }
    fn write(path: &Path, text: &str) {
        std::fs::write(path, text).unwrap();
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).unwrap();
    }

    #[test]
    fn identity_precedes_password_and_docker_without_disclosing_secrets() {
        let credential = selected(&configured(RegistryEntry {
            identity_token: Some("identity-private".into()),
            username: Some("token".into()),
            password: Some("password-private".into()),
            ..RegistryEntry::default()
        }));
        assert!(
            matches!(&credential, Credential::Identity { token, .. } if token == "identity-private")
        );
        assert_eq!(
            format!("{credential:?}"),
            "RegistryAccountCredential(<redacted>)"
        );
        assert!(credential.direct_bearer().is_none());
    }

    #[test]
    fn docker_provider_precedence_canonical_key_and_inline_fallback_use_sdk_matching() {
        let bytes = br#"{"credsStore":"global","credHelpers":{"https://index.docker.io/v1/":"hub"},"auths":{"https://index.docker.io/v1/":{"username":"inline","password":"inline-private"}}}"#;
        let selected = docker_from(bytes, "docker.io", |helper, key| {
            assert_eq!(helper, "hub");
            assert_eq!(key, "https://index.docker.io/v1/");
            Ok(Some(smolvm::docker_config::DockerCredential {
                username: "provider".into(),
                secret: "provider-private".into(),
            }))
        })
        .unwrap()
        .unwrap();
        assert_eq!(selected.username, "provider");
        let selected = docker_from(bytes, "docker.io", |_, _| Ok(None))
            .unwrap()
            .unwrap();
        assert_eq!(selected.username, "inline");
        assert_eq!(selected.secret, "inline-private");
        let selected = docker_from(
            br#"{"auths":{"https://ghcr.io/v1/":{"username":"user","password":"private"}}}"#,
            "ghcr.io",
            |_, _| panic!("inline cannot launch provider"),
        )
        .unwrap()
        .unwrap();
        assert_eq!(selected.username, "user");
        assert!(
            docker_from(br#"{"credsStore":"../other"}"#, "ghcr.io", |_, _| panic!(
                "invalid helper cannot execute"
            ))
            .is_err()
        );
    }

    #[test]
    fn config_token_is_bearer_but_docker_token_username_is_basic() {
        let credential = selected(&configured(RegistryEntry {
            username: Some("token".into()),
            password: Some("direct-private".into()),
            ..RegistryEntry::default()
        }));
        assert_eq!(credential.direct_bearer(), Some("direct-private"));
        let credential = select(&RegistryConfig::default(), "registry.example", None, || {
            Ok(Some(smolvm::docker_config::DockerCredential {
                username: "token".into(),
                secret: "docker-private".into(),
            }))
        })
        .unwrap();
        assert!(
            matches!(credential, Credential::Basic { username, password }
            if username == "token" && password == "docker-private")
        );
    }

    #[test]
    fn unusable_docker_identity_stays_anonymous_and_invalid_tokens_are_redacted() {
        let credential = select(&RegistryConfig::default(), "registry.example", None, || {
            Ok(Some(smolvm::docker_config::DockerCredential {
                username: "<token>".into(),
                secret: "docker-private".into(),
            }))
        })
        .unwrap();
        assert!(matches!(credential, Credential::Anonymous));
        let result = Credential::Bearer("private\nheader".into()).validate();
        assert!(result.is_err());
        assert!(!format!("{result:?}").contains("private"));
    }

    #[test]
    fn primary_families_and_legacy_images_are_read_without_migration() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        let legacy = dir.path().join("registries.toml");
        let original =
            "[registries.\"registry.example\"]\nusername = 'token'\npassword = 'legacy-private'\n";
        write(&legacy, original);
        let account = read_account(&path).unwrap();
        assert!(account.machines.registries.is_empty());
        assert_eq!(
            selected(&account.images).direct_bearer(),
            Some("legacy-private")
        );
        assert!(!path.exists());
        assert_eq!(std::fs::read_to_string(&legacy).unwrap(), original);
        write(&path, "[machines.registries.\"registry.example\"]\nusername = 'token'\npassword = 'machine-private'\n[images.registries.\"registry.example\"]\nusername = 'token'\npassword = 'image-private'\n");
        let account = read_account(&path).unwrap();
        assert_eq!(
            selected(&account.machines).direct_bearer(),
            Some("machine-private")
        );
        assert_eq!(
            selected(&account.images).direct_bearer(),
            Some("image-private")
        );
    }

    #[test]
    fn rotated_config_symlink_is_resolved_each_operation() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        for (name, token) in [("first", "first-private"), ("second", "second-private")] {
            write(&dir.path().join(name), &format!("[machines.registries.\"registry.example\"]\nusername = 'token'\npassword = '{token}'\n"));
        }
        symlink("first", &path).unwrap();
        let before = selected(&read_account(&path).unwrap().machines);
        std::fs::remove_file(&path).unwrap();
        symlink("second", &path).unwrap();
        let after = selected(&read_account(&path).unwrap().machines);
        assert_eq!(before.direct_bearer(), Some("first-private"));
        assert_eq!(after.direct_bearer(), Some("second-private"));
    }

    #[test]
    fn account_reads_reject_oversize_writable_and_nonregular_inputs() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        write(&path, "");
        std::fs::File::options()
            .write(true)
            .open(&path)
            .unwrap()
            .set_len(CONFIG_BYTES + 1)
            .unwrap();
        assert!(read_bounded(&path).is_err());
        write(&path, "");
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o620)).unwrap();
        assert!(read_bounded(&path).is_err());
        assert!(read_bounded(dir.path()).is_err());
        std::fs::remove_file(&path).unwrap();
        let name = std::ffi::CString::new(path.as_os_str().as_encoded_bytes()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
        assert!(read_bounded(&path).is_err());
    }

    #[test]
    fn sdk_routing_preserves_aliases_mirror_prefix_and_original_credential_key() {
        assert_eq!(
            route("docker.io", &RegistryConfig::default())
                .unwrap()
                .as_str(),
            "https://registry-1.docker.io/"
        );
        assert_eq!(
            route("smolmachines.com", &RegistryConfig::default())
                .unwrap()
                .as_str(),
            "https://registry.smolmachines.com/"
        );
        let config = configured(RegistryEntry {
            mirror: Some("mirror.example/prefix".into()),
            username: Some("token".into()),
            password: Some("original-private".into()),
            ..RegistryEntry::default()
        });
        assert_eq!(
            route("registry.example", &config).unwrap().as_str(),
            "https://mirror.example/prefix/"
        );
        assert_eq!(selected(&config).direct_bearer(), Some("original-private"));
        assert_eq!(
            route("localhost:5000", &RegistryConfig::default())
                .unwrap()
                .scheme(),
            "http"
        );
        for mirror in [
            "user:secret@mirror.example",
            "mirror.example/path?token=private",
            "mirror.example/#private",
        ] {
            assert!(route(
                "registry.example",
                &configured(RegistryEntry {
                    mirror: Some(mirror.into()),
                    ..RegistryEntry::default()
                })
            )
            .is_err());
        }
    }

    #[test]
    fn identity_realms_are_exact_and_basic_obeys_sdk_host_rules() {
        let origin = Url::parse("https://ghcr.io/").unwrap();
        let identity = Credential::Identity {
            token: "private".into(),
            realm: Some(Url::parse("https://auth.example/token").unwrap()),
        };
        assert!(
            identity.approved_realm(&origin, &Url::parse("https://auth.example/token").unwrap())
        );
        assert!(
            !identity.approved_realm(&origin, &Url::parse("https://auth.example/other").unwrap())
        );
        assert!(
            !identity.approved_realm(&origin, &Url::parse("http://auth.example/token").unwrap())
        );
        let basic = Credential::Basic {
            username: "user".into(),
            password: "private".into(),
        };
        assert!(basic.approved_realm(&origin, &Url::parse("https://ghcr.io/token").unwrap()));
        assert!(!basic.approved_realm(&origin, &Url::parse("https://other.example/token").unwrap()));
        assert!(!basic.approved_realm(&origin, &Url::parse("http://ghcr.io/token").unwrap()));
    }
}
