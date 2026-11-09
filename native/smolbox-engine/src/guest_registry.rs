//! Parent-selected OCI pull setup. Serialized only into the owned worker's
//! anonymous input pipe; never a metadata spool, receipt, argv or environment.
use crate::{Error, ErrorCode, ImagePullRequest, Result};
use serde::{Deserialize, Serialize};
use smolvm::registry::RegistryConfig;

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Plan {
    source: ImagePullRequest,
    effective_reference: String,
    auth: Option<Auth>,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Auth {
    username: String,
    password: String,
}
impl std::fmt::Debug for Plan {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("GuestRegistryPlan(<redacted>)")
    }
}
impl Plan {
    pub(crate) fn resolve(
        source: &ImagePullRequest,
        context: &crate::registry_account::Context<'_>,
    ) -> Result<Self> {
        source.validate()?;
        if context.cancel.is_cancelled()
            || std::time::Instant::now() >= context.deadline
            || !context.pool.available()
        {
            return Err(Error::before(ErrorCode::State));
        }
        let config = crate::registry_account::images_config()?;
        let plan = select(source, &config, |key| {
            crate::registry_account::docker_credential(key, context)
        })?;
        if context.cancel.is_cancelled()
            || std::time::Instant::now() >= context.deadline
            || !context.pool.available()
        {
            return Err(Error::before(ErrorCode::State));
        }
        Ok(plan)
    }
    pub(crate) fn validate(&self, expected: &ImagePullRequest) -> Result<()> {
        expected.validate()?;
        let effective = ImagePullRequest {
            reference: self.effective_reference.clone(),
            platform: expected.platform.clone(),
        };
        effective.validate()?;
        let repository = expected
            .reference
            .split_once('/')
            .ok_or(Error::before(ErrorCode::Validation))?
            .1;
        if &self.source != expected
            || !self
                .effective_reference
                .ends_with(&format!("/{repository}"))
            || self
                .effective_reference
                .rsplit_once('@')
                .map(|(_, digest)| digest)
                != expected
                    .reference
                    .rsplit_once('@')
                    .map(|(_, digest)| digest)
            || self
                .auth
                .as_ref()
                .is_some_and(|auth| auth.username.len() > 1024 || auth.password.len() > 16384)
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(())
    }
    pub(crate) fn request(
        &self,
        expected: &ImagePullRequest,
    ) -> Result<smolvm_protocol::AgentRequest> {
        self.validate(expected)?;
        Ok(smolvm_protocol::AgentRequest::Pull {
            image: self.effective_reference.clone(),
            oci_platform: Some(expected.platform.clone()),
            auth: self
                .auth
                .as_ref()
                .map(|auth| smolvm_protocol::RegistryAuth {
                    username: auth.username.clone(),
                    password: auth.password.clone(),
                }),
            proxy: None,
            no_proxy: None,
            cache_as: None,
        })
    }
}

fn select(
    source: &ImagePullRequest,
    config: &RegistryConfig,
    docker: impl FnOnce(&str) -> Result<Option<smolvm::docker_config::DockerCredential>>,
) -> Result<Plan> {
    // Match AgentClient::pull(use_registry_config), which intentionally differs
    // from host registry_client(FromConfig): identity_token config is not a
    // guest auth field, username "token" remains a pair, and Docker identities
    // are usable by the guest. Keep the original registry key for credentials.
    let registry = smolvm::registry::extract_registry(&source.reference);
    let configured =
        tracing::subscriber::with_default(tracing::subscriber::NoSubscriber::default(), || {
            config.get_credentials(&registry)
        });
    let auth = if let Some(auth) = configured {
        Some(Auth {
            username: auth.username,
            password: auth.password,
        })
    } else {
        docker(&registry)?.map(|auth| Auth {
            username: auth.username,
            password: auth.secret,
        })
    };
    let effective_reference = config
        .get_mirror(&registry)
        .map(|mirror| smolvm::registry::rewrite_image_registry(&source.reference, mirror))
        .unwrap_or_else(|| source.reference.clone());
    let plan = Plan {
        source: source.clone(),
        effective_reference,
        auth,
    };
    plan.validate(source)?;
    Ok(plan)
}

#[cfg(test)]
mod tests {
    use super::*;
    use smolvm::registry::RegistryEntry;
    use std::collections::HashMap;

    fn source() -> ImagePullRequest {
        ImagePullRequest {
            reference: format!("registry.example/team/app@sha256:{}", "a".repeat(64)),
            platform: "linux/amd64".into(),
        }
    }
    fn config(entry: RegistryEntry) -> RegistryConfig {
        RegistryConfig {
            registries: HashMap::from([("registry.example".into(), entry)]),
            ..RegistryConfig::default()
        }
    }
    #[test]
    fn guest_pair_precedes_docker_and_mirror_preserves_original_approval_and_digest() {
        let source = source();
        let plan = select(
            &source,
            &config(RegistryEntry {
                identity_token: Some("host-only-private".into()),
                username: Some("token".into()),
                password: Some("guest-private".into()),
                mirror: Some("mirror.example/prefix".into()),
                ..RegistryEntry::default()
            }),
            |_| panic!("configured pair precedes Docker"),
        )
        .unwrap();
        let smolvm_protocol::AgentRequest::Pull {
            image,
            auth,
            proxy,
            no_proxy,
            ..
        } = plan.request(&source).unwrap()
        else {
            panic!()
        };
        assert_eq!(
            image,
            source
                .reference
                .replace("registry.example", "mirror.example/prefix")
        );
        assert_eq!(auth.unwrap().username, "token");
        assert!(proxy.is_none() && no_proxy.is_none());
        assert!(plan.source == source);
        assert!(!format!("{plan:?}").contains("private"));
        assert!(!serde_json::to_string(&plan)
            .unwrap()
            .contains("host-only-private"));
    }
    #[test]
    fn docker_identity_is_preserved_for_guest_without_host_identity_exchange_rules() {
        let source = source();
        let plan = select(
            &source,
            &config(RegistryEntry {
                identity_token: Some("host-only-private".into()),
                ..RegistryEntry::default()
            }),
            |key| {
                assert_eq!(key, "registry.example");
                Ok(Some(smolvm::docker_config::DockerCredential {
                    username: "<token>".into(),
                    secret: "docker-private".into(),
                }))
            },
        )
        .unwrap();
        let smolvm_protocol::AgentRequest::Pull { auth, .. } = plan.request(&source).unwrap()
        else {
            panic!()
        };
        assert_eq!(auth.unwrap().username, "<token>");
    }
    #[test]
    fn guest_rotation_is_operation_local_and_crossed_sources_or_unpinned_mirrors_fail() {
        let source = source();
        for secret in ["first-private", "second-private"] {
            let plan = select(&source, &RegistryConfig::default(), |_| {
                Ok(Some(smolvm::docker_config::DockerCredential {
                    username: "user".into(),
                    secret: secret.into(),
                }))
            })
            .unwrap();
            let smolvm_protocol::AgentRequest::Pull { auth, .. } = plan.request(&source).unwrap()
            else {
                panic!()
            };
            assert_eq!(auth.unwrap().password, secret);
            let mut crossed = source.clone();
            crossed.reference = crossed.reference.replace("team/app", "other/app");
            assert!(plan.validate(&crossed).is_err());
        }
        for mirror in [
            "https://mirror.example",
            "user:password@mirror.example",
            "mirror.example/../other",
            "mirror.example:0",
        ] {
            assert!(select(
                &source,
                &config(RegistryEntry {
                    mirror: Some(mirror.into()),
                    ..RegistryEntry::default()
                }),
                |_| Ok(None)
            )
            .is_err());
        }
    }
}
