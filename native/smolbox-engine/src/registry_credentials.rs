//! Transient registry identity credentials, kept separate from source identity.
use crate::{Error, ErrorCode, Result};
use reqwest::Url;

/// Host-approved token endpoint and identity token for one registry operation.
/// Deliberately not Clone/Serialize/Deserialize; bridges use protected IPC.
pub struct RegistryIdentityCredential {
    token: String,
    realm: Url,
}
impl std::fmt::Debug for RegistryIdentityCredential {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("RegistryIdentityCredential(<redacted>)")
    }
}
impl RegistryIdentityCredential {
    pub fn new(token: String, realm: &str) -> Result<Self> {
        if !valid_token(&token) {
            return Err(Error::before(ErrorCode::Validation));
        }
        let realm = approved_realm(realm)?;
        Ok(Self { token, realm })
    }
    /// Validate a non-secret operator token endpoint without manufacturing a token.
    pub fn validate_realm(realm: &str) -> Result<()> {
        approved_realm(realm).map(|_| ())
    }
    /// Validate an explicit-token registry destination without token bytes.
    pub fn validate_destination(reference: &str) -> Result<()> {
        let registry = reference
            .split('/')
            .next()
            .ok_or(Error::before(ErrorCode::Validation))?;
        let url = Url::parse(&format!("https://{registry}"))
            .map_err(|_| Error::before(ErrorCode::Validation))?;
        if !public_host(&url) {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(())
    }
    pub(crate) fn validate_registry(&self, origin: &Url) -> Result<()> {
        if origin.scheme() != "https" || !public_host(origin) {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(())
    }
    pub(crate) fn accepts(&self, realm: &Url) -> bool {
        self.realm == *realm
    }
    pub(crate) fn token(&self) -> &str {
        &self.token
    }
}
fn approved_realm(realm: &str) -> Result<Url> {
    if realm.len() > 2048 {
        return Err(Error::before(ErrorCode::Validation));
    }
    let realm = Url::parse(realm).map_err(|_| Error::before(ErrorCode::Validation))?;
    if realm.scheme() != "https"
        || !realm.username().is_empty()
        || realm.password().is_some()
        || realm.query().is_some()
        || realm.fragment().is_some()
        || !public_host(&realm)
    {
        return Err(Error::before(ErrorCode::Validation));
    }
    Ok(realm)
}
fn valid_token(token: &str) -> bool {
    if token.is_empty() || token.len() > 16384 {
        return false;
    }
    let body = token.trim_end_matches('=');
    !body.is_empty()
        && body
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"._~+/-".contains(&byte))
}
fn public_host(url: &Url) -> bool {
    let Some(host) = url.host_str() else {
        return false;
    };
    if host == "localhost" || host.ends_with(".localhost") {
        return false;
    }
    let bare = host.trim_start_matches('[').trim_end_matches(']');
    match bare.parse::<std::net::IpAddr>() {
        Ok(std::net::IpAddr::V4(ip)) => {
            !(ip.is_private() || ip.is_loopback() || ip.is_link_local() || ip.is_unspecified())
        }
        Ok(std::net::IpAddr::V6(ip)) => {
            let first = ip.segments()[0];
            !ip.is_loopback()
                && !ip.is_unspecified()
                && first & 0xffc0 != 0xfe80
                && first & 0xfe00 != 0xfc00
                && ip.to_ipv4_mapped().is_none_or(|ip| {
                    !(ip.is_private()
                        || ip.is_loopback()
                        || ip.is_link_local()
                        || ip.is_unspecified())
                })
        }
        Err(_) => true,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn identity_token_grammar_bounds_and_diagnostics_are_redacted() {
        for token in [
            "",
            "=",
            "a=b",
            "with space",
            "line\nbreak",
            "é",
            "token:bad",
        ] {
            assert!(
                RegistryIdentityCredential::new(token.into(), "https://auth.example/token")
                    .is_err()
            );
        }
        assert!(
            RegistryIdentityCredential::new("a".repeat(16385), "https://auth.example/token")
                .is_err()
        );
        let credential =
            RegistryIdentityCredential::new("safe._~+/-==".into(), "https://auth.example/token")
                .unwrap();
        assert_eq!(
            format!("{credential:?}"),
            "RegistryIdentityCredential(<redacted>)"
        );
        assert!(credential.accepts(&Url::parse("https://auth.example/token").unwrap()));
        assert!(!credential.accepts(&Url::parse("https://auth.example/other").unwrap()));
    }
    #[test]
    fn identity_credential_rejects_private_plaintext_and_ambiguous_destinations() {
        for realm in [
            "http://auth.example/token",
            "https://user:pass@auth.example/token",
            "https://auth.example/token?extra=1",
            "https://auth.example/token#fragment",
            "https://localhost/token",
            "https://127.0.0.1/token",
            "https://10.0.0.1/token",
            "https://169.254.169.254/token",
            "https://[::1]/token",
            "https://[fc00::1]/token",
            "https://[::ffff:127.0.0.1]/token",
        ] {
            assert!(
                RegistryIdentityCredential::new("secret".into(), realm).is_err(),
                "{realm}"
            );
        }
        let credential =
            RegistryIdentityCredential::new("secret".into(), "https://auth.example/token").unwrap();
        for origin in [
            "http://registry.example",
            "https://localhost",
            "https://192.168.1.2",
            "https://172.16.1.2",
            "https://0.0.0.0",
        ] {
            assert!(credential
                .validate_registry(&Url::parse(origin).unwrap())
                .is_err());
        }
        assert!(credential
            .validate_registry(&Url::parse("https://registry.example").unwrap())
            .is_ok());
    }
}
