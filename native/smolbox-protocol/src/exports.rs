//! Path-free export intent and distinct publication/cleanup authority.
use crate::{InvalidMessage, Receipt};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
type Result<T> = std::result::Result<T, InvalidMessage>;
fn check(value: bool) -> Result<()> {
    if value {
        Ok(())
    } else {
        Err(InvalidMessage)
    }
}
fn hash(value: &impl Serialize) -> Result<String> {
    Ok(format!(
        "{:x}",
        Sha256::digest(serde_json::to_vec(value).map_err(|_| InvalidMessage)?)
    ))
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ExportLimits {
    pub staging_bytes: u64,
    pub metadata_bytes: u64,
    pub upload_chunk_bytes: u64,
    pub registry_requests: u64,
    pub record_bytes: u64,
    pub records: u64,
    pub asset_file_bytes: u64,
    pub asset_total_bytes: u64,
    pub control_metadata_bytes: u64,
    pub observation_metadata_bytes: u64,
    pub retirement_metadata_bytes: u64,
}
impl Default for ExportLimits {
    fn default() -> Self {
        Self {
            staging_bytes: 549755813888,
            metadata_bytes: 1048576,
            upload_chunk_bytes: 1048576,
            registry_requests: 1048576,
            record_bytes: 16384,
            records: 256,
            asset_file_bytes: 2147483648,
            asset_total_bytes: 4294967296,
            control_metadata_bytes: 262144,
            observation_metadata_bytes: 131072,
            retirement_metadata_bytes: 33554432,
        }
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ExportRequest {
    pub request_sha256: String,
    pub destination_id: String,
    pub destination_sha256: String,
    pub tag: String,
    pub max_artifact_bytes: u64,
    pub max_staging_bytes: u64,
}
impl ExportRequest {
    pub fn identity_sha256(&self) -> Result<String> {
        self.validate()?;
        hash(&("smolbox-export-intent-v1", self))
    }
    pub fn validate(&self) -> Result<()> {
        crate::wire::hex(&self.request_sha256, 64)?;
        crate::wire::id(&self.destination_id)?;
        crate::wire::hex(&self.destination_sha256, 64)?;
        check(
            tag(&self.tag)
                && self.max_artifact_bytes > 0
                && self.max_artifact_bytes < self.max_staging_bytes
                && self.max_staging_bytes <= ExportLimits::default().staging_bytes,
        )
    }
}
pub fn tag(value: &str) -> bool {
    let bytes = value.as_bytes();
    !bytes.is_empty()
        && bytes.len() <= 100
        && (bytes[0].is_ascii_alphanumeric() || bytes[0] == b'_')
        && bytes
            .iter()
            .all(|byte| byte.is_ascii_alphanumeric() || b"_.-".contains(byte))
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ExportPublicationIdentity {
    pub destination_id: String,
    pub destination_sha256: String,
    pub registry: String,
    pub repository: String,
    pub tag: String,
    pub platform_tag: String,
    pub platform: String,
    pub content_sha256: String,
    pub size_bytes: u64,
    pub config_sha256: String,
    pub manifest_sha256: String,
    pub index_sha256: String,
}
impl ExportPublicationIdentity {
    pub fn validate(&self) -> Result<()> {
        crate::wire::id(&self.destination_id)?;
        for digest in [
            &self.destination_sha256,
            &self.content_sha256,
            &self.config_sha256,
            &self.manifest_sha256,
            &self.index_sha256,
        ] {
            crate::wire::hex(digest, 64)?;
        }
        check(
            self.registry.len() <= 260
                && self.repository.len() <= 256
                && tag(&self.tag)
                && matches!(self.platform.as_str(), "linux/amd64" | "linux/arm64")
                && self.platform_tag == format!("{}-{}", self.tag, self.platform.replace('/', "-"))
                && self.size_bytes > 0
                && self.size_bytes <= ExportLimits::default().staging_bytes,
        )?;
        crate::OciSource {
            reference: format!(
                "{}/{}@sha256:{}",
                self.registry, self.repository, self.manifest_sha256
            ),
            platform: self.platform.clone(),
        }
        .validate()
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ExportPublication {
    pub schema: u8,
    pub source: Receipt,
    pub operation_id: String,
    pub request_sha256: String,
    pub identity: ExportPublicationIdentity,
    pub proof_sha256: String,
}
impl ExportPublication {
    pub fn validate(&self) -> Result<()> {
        self.source.validate_for(2)?;
        crate::wire::id(&self.operation_id)?;
        crate::wire::hex(&self.request_sha256, 64)?;
        self.identity.validate()?;
        check(
            self.schema == 1
                && self.source.material.is_some()
                && self.proof_sha256
                    == hash(&(
                        "smolbox-export-publication-v1",
                        &self.source,
                        &self.operation_id,
                        &self.request_sha256,
                        &self.identity,
                    ))?,
        )
    }
    pub fn matches(&self, source: &Receipt, id: &str, request_sha256: &str) -> Result<()> {
        self.validate()?;
        check(
            self.source == *source
                && self.operation_id == id
                && self.request_sha256 == request_sha256,
        )
    }
    pub fn matches_request(
        &self,
        source: &Receipt,
        id: &str,
        request: &ExportRequest,
    ) -> Result<()> {
        request.validate()?;
        self.matches(source, id, &request.request_sha256)?;
        check(
            self.identity.destination_id == request.destination_id
                && self.identity.destination_sha256 == request.destination_sha256
                && self.identity.tag == request.tag
                && self.identity.size_bytes <= request.max_artifact_bytes,
        )
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ExportStageCleanup {
    pub schema: u8,
    pub source: Receipt,
    pub operation_id: String,
    pub request_sha256: String,
    pub stage_sha256: String,
}
impl ExportStageCleanup {
    pub fn validate(&self) -> Result<()> {
        self.source.validate_for(2)?;
        crate::wire::id(&self.operation_id)?;
        crate::wire::hex(&self.request_sha256, 64)?;
        crate::wire::hex(&self.stage_sha256, 64)?;
        check(self.schema == 1 && self.source.material.is_some())
    }
    pub fn matches(&self, source: &Receipt, id: &str, request_sha256: &str) -> Result<()> {
        self.validate()?;
        check(
            self.source == *source
                && self.operation_id == id
                && self.request_sha256 == request_sha256,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::*;
    fn proof() -> ExportPublication {
        serde_json::from_str::<Vec<ExportPublication>>(include_str!(
            "../fixtures/export-publications-v1.json"
        ))
        .unwrap()
        .remove(0)
    }
    fn request(proof: &ExportPublication) -> ExportRequest {
        ExportRequest {
            request_sha256: proof.request_sha256.clone(),
            destination_id: proof.identity.destination_id.clone(),
            destination_sha256: proof.identity.destination_sha256.clone(),
            tag: proof.identity.tag.clone(),
            max_artifact_bytes: 1024 * 1024,
            max_staging_bytes: 4 * 1024 * 1024,
        }
    }
    fn hello(proof: &ExportPublication, enabled: bool) -> Hello {
        let ServerMessage::Hello { hello } = ServerMessage::decode(
            serde_json::from_str(include_str!("../fixtures/hello-v2.json")).unwrap(),
        )
        .unwrap() else {
            unreachable!()
        };
        let mut hello = *hello;
        hello.domain.target_id = proof.source.target_id.clone();
        hello.domain.generation = proof.source.domain_generation.clone();
        hello.package.platform = "linux".into();
        hello.package.architecture = "x86_64".into();
        if enabled {
            for feature in [
                "exports",
                "job_resources",
                "buffered_exec",
                "compact_creation",
            ] {
                hello
                    .sdk
                    .as_mut()
                    .unwrap()
                    .feature_versions
                    .insert(feature.into(), 1);
            }
            hello.capabilities = hello.sdk.as_ref().unwrap().capabilities();
        }
        hello.limits = Limits::for_sdk(hello.sdk.as_ref().unwrap());
        hello
    }
    #[test]
    fn synthetic_native_publication_and_cleanup_have_distinct_strict_shapes_and_hash_domains() {
        let proof = proof();
        proof.validate().unwrap();
        proof
            .matches_request(&proof.source, &proof.operation_id, &request(&proof))
            .unwrap();
        let encoded = serde_json::to_value(&proof).unwrap();
        for field in [
            "schema",
            "source",
            "operation_id",
            "request_sha256",
            "identity",
            "proof_sha256",
        ] {
            let mut bad = encoded.clone();
            bad.as_object_mut().unwrap().remove(field);
            assert!(serde_json::from_value::<ExportPublication>(bad).is_err());
        }
        for field in [
            "tag",
            "destination_id",
            "content_sha256",
            "size_bytes",
            "config_sha256",
            "manifest_sha256",
            "index_sha256",
        ] {
            let mut bad = encoded.clone();
            bad["identity"][field] = if field == "size_bytes" {
                serde_json::json!(2)
            } else {
                serde_json::json!("changed")
            };
            assert!(serde_json::from_value::<ExportPublication>(bad)
                .unwrap()
                .validate()
                .is_err());
        }
        assert!(serde_json::from_value::<ExportStageCleanup>(encoded).is_err());
        let cleanup: ExportStageCleanup = serde_json::from_str::<Vec<ExportStageCleanup>>(
            include_str!("../fixtures/export-cleanups-v1.json"),
        )
        .unwrap()
        .remove(0);
        cleanup
            .matches(&proof.source, &proof.operation_id, &proof.request_sha256)
            .unwrap();
        assert!(cleanup
            .matches(&proof.source, "foreign", &proof.request_sha256)
            .is_err());
        assert!(serde_json::from_value::<ExportPublication>(
            serde_json::to_value(cleanup).unwrap()
        )
        .is_err());
    }
    #[test]
    fn export_frames_require_feature_bound_limits_exact_request_and_zero_output_without_retaining_token(
    ) {
        let proof = proof();
        let request = request(&proof);
        let operation = Operation::ExportMachine {
            receipt: proof.source.clone(),
            operation_id: proof.operation_id.clone(),
            request,
            push_token: serde_json::from_value(serde_json::json!("private-fixture-token")).unwrap(),
        };
        operation.validate(1000).unwrap();
        assert!(!serde_json::to_string(&operation.sanitized())
            .unwrap()
            .contains("private-fixture-token"));
        for enabled in [false, true] {
            let hello = hello(&proof, enabled);
            let mut session = Session::new(hello.clone()).unwrap();
            session.approve(&hello).unwrap();
            let accepted = session
                .admit(ClientMessage::Request {
                    epoch: hello.epoch.clone(),
                    id: 1,
                    budget_ms: 1000,
                    initial_credit: 0,
                    initial_event_credit: 0,
                    operation: operation.clone(),
                })
                .unwrap();
            if enabled {
                assert!(matches!(accepted, ServerMessage::Accepted { .. }));
                let mut foreign = proof.clone();
                foreign.operation_id = "foreign".into();
                foreign.proof_sha256 = hash(&(
                    "smolbox-export-publication-v1",
                    &foreign.source,
                    &foreign.operation_id,
                    &foreign.request_sha256,
                    &foreign.identity,
                ))
                .unwrap();
                assert!(session
                    .terminal(
                        1,
                        Outcome::Exported {
                            publication: Box::new(foreign)
                        }
                    )
                    .is_err());
                session
                    .terminal(
                        1,
                        Outcome::Exported {
                            publication: Box::new(proof.clone()),
                        },
                    )
                    .unwrap();
            } else {
                assert!(matches!(
                    accepted,
                    ServerMessage::Terminal {
                        outcome: Outcome::Error {
                            code: SafeCode::Unsupported,
                            ..
                        },
                        ..
                    }
                ));
            }
        }
    }
    #[test]
    fn lookup_and_quiesced_cleanup_are_bounded_and_never_substitute_for_publication() {
        let proof = proof();
        let hello = hello(&proof, true);
        let inspect = Operation::InspectExport {
            receipt: proof.source.clone(),
            operation_id: proof.operation_id.clone(),
            request_sha256: proof.request_sha256.clone(),
        };
        assert!(inspect.validate(30001).is_err());
        inspect.validate(30000).unwrap();
        let cleanup = Operation::CleanupExportStaging {
            receipt: proof.source.clone(),
            operation_id: proof.operation_id.clone(),
            request_sha256: proof.request_sha256.clone(),
            quiesced: false,
        };
        assert!(cleanup.validate(1).is_err());
        let mut session = Session::new(hello.clone()).unwrap();
        session.approve(&hello).unwrap();
        session
            .admit(ClientMessage::Request {
                epoch: hello.epoch.clone(),
                id: 1,
                budget_ms: 1000,
                initial_credit: 0,
                initial_event_credit: 0,
                operation: inspect,
            })
            .unwrap();
        assert!(session
            .terminal(
                1,
                Outcome::Exported {
                    publication: Box::new(proof.clone())
                }
            )
            .is_err());
        session
            .terminal(1, Outcome::ExportPresence { publication: None })
            .unwrap();
        let mut value =
            serde_json::to_value(Outcome::ExportPresence { publication: None }).unwrap();
        value.as_object_mut().unwrap().remove("publication");
        assert!(serde_json::from_value::<Outcome>(value).is_err());
        assert!(Outcome::Exported {
            publication: Box::new(proof)
        }
        .validate_for(1)
        .is_err());
    }

    #[test]
    fn admission_is_feature_gated_bounded_and_never_a_publication_acknowledgement() {
        let proof = proof();
        let frozen = request(&proof);
        let identity = frozen.identity_sha256().unwrap();
        let mut changed = frozen.clone();
        changed.max_staging_bytes += 1;
        assert_ne!(identity, changed.identity_sha256().unwrap());
        changed = frozen.clone();
        changed.tag = "different".into();
        assert_ne!(identity, changed.identity_sha256().unwrap());
        let operation = Operation::AdmitExport {
            receipt: proof.source.clone(),
            operation_id: proof.operation_id.clone(),
            request: frozen,
        };
        operation.validate(30000).unwrap();
        assert!(operation.validate(30001).is_err());
        let mut wire = serde_json::to_value(&operation).unwrap();
        wire["push_token"] = serde_json::json!("private-fixture-token");
        assert!(serde_json::from_value::<Operation>(wire).is_err());
        for enabled in [false, true] {
            let hello = hello(&proof, enabled);
            let mut session = Session::new(hello.clone()).unwrap();
            session.approve(&hello).unwrap();
            let response = session
                .admit(ClientMessage::Request {
                    epoch: hello.epoch.clone(),
                    id: 1,
                    budget_ms: 1000,
                    initial_credit: 0,
                    initial_event_credit: 0,
                    operation: operation.clone(),
                })
                .unwrap();
            if enabled {
                assert!(matches!(response, ServerMessage::Accepted { .. }));
                assert!(session
                    .terminal(
                        1,
                        Outcome::Exported {
                            publication: Box::new(proof.clone()),
                        }
                    )
                    .is_err());
                session.terminal(1, Outcome::Qualified).unwrap();
            } else {
                assert!(matches!(
                    response,
                    ServerMessage::Terminal {
                        outcome: Outcome::Error {
                            code: SafeCode::Unsupported,
                            ..
                        },
                        ..
                    }
                ));
            }
        }
    }
}
