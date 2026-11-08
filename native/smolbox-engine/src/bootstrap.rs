//! Owned, bounded agent-side OCI bootstrap. VMM launch/enrollment stays in Engine.
use crate::{Error, ErrorCode, ImageObservation, ImagePullRequest, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

pub(crate) const METADATA_BYTES: u64 = 8 * 1024 * 1024;
pub(crate) const LAUNCH_OUTPUT_BYTES: u64 = 16 * 1024;
pub(crate) const LAUNCH_FRAMES: usize = 4096;
pub(crate) const LAUNCH_REPLY_BYTES: usize = 8 * 1024 * 1024;

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Launch {
    pub argv: Vec<String>,
    pub env: Vec<(String, String)>,
    pub user: Option<String>,
    pub workdir: Option<String>,
    pub mounts: Vec<(String, String, bool)>,
    pub overlay: String,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
/// Agent-side launch plan; construction/validation grant no machine ownership.
/// Engine must supply a receipt-bound record and retain its lifecycle leases.
pub struct Metadata {
    schema: u32,
    machine: String,
    source: ImagePullRequest,
    launch: Launch,
    deadline_ns: u64,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Expected {
    pub source: ImagePullRequest,
    pub machine: String,
    pub metadata_sha256: String,
    pub launch_required: bool,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Proof {
    pub image: ImageObservation,
    pub metadata_sha256: String,
    pub container_id: Option<String>,
}
impl Proof {
    pub(crate) fn matches(&self, expected: &Expected) -> bool {
        self.metadata_sha256 == expected.metadata_sha256
            && expected.source.matches(&self.image)
            && self.container_id.is_some() == expected.launch_required
            && self.container_id.as_ref().is_none_or(|id| {
                !id.is_empty()
                    && id.len() <= 128
                    && id
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
            })
    }
}
impl Metadata {
    pub fn from_record(record: &smolvm::config::VmRecord, deadline_ns: u64) -> Result<Self> {
        if record.source_smolmachine.is_some()
            || record.stop_on_exit
            || !record.remote_volumes.is_empty()
        {
            return Err(Error::before(ErrorCode::Unsupported));
        }
        let image = record
            .image
            .clone()
            .ok_or(Error::before(ErrorCode::Unsupported))?;
        let metadata = Self {
            schema: 1,
            machine: record.name.clone(),
            source: ImagePullRequest {
                reference: image,
                platform: crate::oci::native_oci_platform().into(),
            },
            launch: Launch {
                argv: record
                    .entrypoint
                    .iter()
                    .chain(&record.cmd)
                    .cloned()
                    .collect(),
                env: record.env.clone(),
                user: record.user.clone(),
                workdir: record.workdir.clone(),
                mounts: smolvm::workload::record_mounts_to_bindings(record),
                overlay: smolvm::workload::persistent_overlay_owner_with_lineage(
                    &record.name,
                    record.golden.as_deref(),
                    record.fork_overlay_owner.as_deref(),
                ),
            },
            deadline_ns,
        };
        metadata.validate()?;
        Ok(metadata)
    }
    pub(crate) fn expected(&self) -> Result<Expected> {
        self.validate()?;
        let bytes = serde_json::to_vec(self).map_err(|_| Error::before(ErrorCode::Validation))?;
        if bytes.len() as u64 > METADATA_BYTES {
            return Err(Error::before(ErrorCode::OutputLimit));
        }
        Ok(Expected {
            source: self.source.clone(),
            machine: self.machine.clone(),
            metadata_sha256: hex::encode(Sha256::digest(bytes)),
            launch_required: !self.launch.argv.is_empty(),
        })
    }
    fn validate(&self) -> Result<()> {
        self.source.validate()?;
        let text = |value: &str, max| value.len() <= max && !value.contains('\0');
        if self.schema != 1
            || self.deadline_ns == 0
            || !crate::domain::valid_id(&self.machine)
            || !crate::domain::valid_id(&self.launch.overlay)
            || self.launch.argv.first().is_some_and(String::is_empty)
            || self.launch.argv.iter().any(|v| !text(v, 1024 * 1024))
            || self.launch.env.iter().any(|(k, v)| {
                k.is_empty() || k.contains('=') || !text(k, 16384) || !text(v, 1024 * 1024)
            })
            || self
                .launch
                .env
                .iter()
                .map(|(k, _)| k)
                .collect::<std::collections::BTreeSet<_>>()
                .len()
                != self.launch.env.len()
            || self
                .launch
                .workdir
                .as_ref()
                .is_some_and(|v| !v.starts_with('/') || !text(v, 4096))
            || self
                .launch
                .user
                .as_ref()
                .is_some_and(|v| v.is_empty() || !text(v, 16384))
            || self.launch.mounts.len() > 64
            || self.launch.mounts.iter().any(|(tag, path, _)| {
                tag.is_empty() || !text(tag, 128) || !path.starts_with('/') || !text(path, 4096)
            })
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        let bytes = serde_json::to_vec(&self.request())
            .map_err(|_| Error::before(ErrorCode::Validation))?;
        if bytes.len() > crate::AGENT_REQUEST_BYTES {
            return Err(Error::before(ErrorCode::OutputLimit));
        }
        Ok(())
    }
    fn request(&self) -> smolvm_protocol::AgentRequest {
        smolvm_protocol::AgentRequest::Run {
            image: self.source.reference.clone(),
            command: self.launch.argv.clone(),
            env: self.launch.env.clone(),
            workdir: self.launch.workdir.clone(),
            user: self.launch.user.clone(),
            mounts: self.launch.mounts.clone(),
            timeout_ms: None,
            interactive: false,
            tty: false,
            detached: true,
            unprivileged: false,
            persistent_overlay_id: Some(self.launch.overlay.clone()),
            stdin_data: None,
            background: false,
            s3_volumes: vec![],
            stop_vm_on_exit: false,
        }
    }
    fn remaining(&self) -> Result<std::time::Duration> {
        let duration = std::time::Duration::from_nanos(
            self.deadline_ns
                .saturating_sub(crate::buffered::monotonic_ns()?),
        );
        if duration.is_zero() || duration > std::time::Duration::from_secs(86400) {
            return Err(Error::before(ErrorCode::State));
        }
        Ok(duration)
    }
}

pub(crate) fn run(
    request: &crate::transfer_worker::Request,
    blob: &crate::transfer_worker::Blob,
    expected: &Expected,
) -> Result<Proof> {
    let metadata: Metadata = blob.read(request.owner, METADATA_BYTES)?;
    if metadata.expected()? != *expected {
        return Err(Error::before(ErrorCode::Ownership));
    }
    metadata.remaining()?;
    let pull = crate::image_pull::Metadata {
        schema: 1,
        request: metadata.source.clone(),
        deadline_ns: metadata.deadline_ns,
    };
    let image = crate::image_pull::execute(&request.socket, &pull)?;
    if metadata.launch.argv.is_empty() {
        metadata.remaining()?;
        return Ok(Proof {
            image,
            metadata_sha256: expected.metadata_sha256.clone(),
            container_id: None,
        });
    }
    let mut agent = crate::agent_io::BoundedAgent::connect_bootstrap_launch(&request.socket)?;
    let _timeout = agent
        .client
        .set_extended_read_timeout(metadata.remaining()?)
        .map_err(|_| Error::uncertain(ErrorCode::Native))?;
    agent
        .client
        .send_raw(&metadata.request())
        .map_err(|_| Error::uncertain(ErrorCode::Native))?;
    metadata.remaining().map_err(|e| Error::uncertain(e.code))?;
    let response = agent
        .client
        .recv_raw()
        .map_err(|_| Error::uncertain(ErrorCode::Native))?;
    let smolvm_protocol::AgentResponse::Completed {
        exit_code: 0,
        stdout,
        ..
    } = response
    else {
        return Err(Error::uncertain(ErrorCode::Native));
    };
    let container_id =
        String::from_utf8(stdout).map_err(|_| Error::uncertain(ErrorCode::Native))?;
    let proof = Proof {
        image,
        metadata_sha256: expected.metadata_sha256.clone(),
        container_id: Some(container_id),
    };
    if !proof.matches(expected) {
        return Err(Error::uncertain(ErrorCode::Native));
    }
    metadata.remaining().map_err(|e| Error::uncertain(e.code))?;
    Ok(proof)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    pub(crate) fn plan(empty: bool) -> Metadata {
        let source = crate::oci::tests::verified();
        let mut features = crate::oci::tests::features();
        features.workload = Some(crate::StartupWorkload {
            entrypoint: vec![],
            cmd: vec![],
            env: std::collections::BTreeMap::from([("A".into(), "override".into())]),
            workdir: None,
        });
        let mut record = source
            .record(
                "owned",
                crate::Resources {
                    cpus: 1,
                    memory_mib: 256,
                    storage_gib: 1,
                    overlay_gib: 1,
                },
                std::collections::BTreeMap::new(),
                &features,
            )
            .unwrap();
        if empty {
            record.entrypoint.clear();
            record.cmd.clear();
        }
        Metadata::from_record(
            &record,
            crate::buffered::monotonic_ns().unwrap() + 30_000_000_000,
        )
        .unwrap()
    }
    #[test]
    fn plan_preserves_workload_arguments_environment_user_and_overlay_without_implicit_helpers() {
        let metadata = plan(false);
        let smolvm_protocol::AgentRequest::Run {
            command,
            env,
            user,
            workdir,
            detached,
            background,
            interactive,
            tty,
            timeout_ms,
            stdin_data,
            persistent_overlay_id,
            stop_vm_on_exit,
            s3_volumes,
            ..
        } = metadata.request()
        else {
            panic!()
        };
        assert_eq!(command, vec!["/app", "serve"]);
        assert_eq!(
            env,
            vec![("A".into(), "override".into()), ("B".into(), "base".into())]
        );
        assert_eq!(user.as_deref(), Some("1234:2345"));
        assert_eq!(workdir.as_deref(), Some("/workspace"));
        assert_eq!(persistent_overlay_id.as_deref(), Some("owned"));
        assert!(detached && !background && !interactive && !tty && !stop_vm_on_exit);
        assert!(timeout_ms.is_none() && stdin_data.is_none() && s3_volumes.is_empty());
        assert!(metadata.expected().unwrap().launch_required);
        assert!(!plan(true).expected().unwrap().launch_required);
    }
    #[test]
    fn proof_binds_private_launch_intent_and_cannot_turn_startup_ack_into_exit_or_readiness() {
        let metadata = plan(false);
        let expected = metadata.expected().unwrap();
        let image = ImageObservation {
            reference: metadata.source.reference.clone(),
            digest: format!("sha256:{}", "b".repeat(64)),
            size: 123,
            architecture: metadata.source.platform.trim_start_matches("linux/").into(),
            os: "linux".into(),
            layer_count: 2,
        };
        let proof = Proof {
            image,
            metadata_sha256: expected.metadata_sha256.clone(),
            container_id: Some("smolvm-fixture".into()),
        };
        assert!(proof.matches(&expected));
        assert!(!Proof {
            container_id: None,
            ..proof.clone()
        }
        .matches(&expected));
        assert!(!Proof {
            container_id: Some("../foreign".into()),
            ..proof.clone()
        }
        .matches(&expected));
        assert!(!Proof {
            metadata_sha256: "a".repeat(64),
            ..proof
        }
        .matches(&expected));
        let mut changed = metadata;
        changed.launch.env[0].1 = "different".into();
        assert_ne!(
            changed.expected().unwrap().metadata_sha256,
            expected.metadata_sha256
        );
    }
    #[test]
    fn oversized_or_changed_launch_data_rejects_before_any_agent_entry() {
        let mut metadata = plan(false);
        metadata.launch.env.push(metadata.launch.env[0].clone());
        assert!(metadata.expected().is_err());
        metadata = plan(false);
        metadata.launch.argv[0] = "bad\0argument".into();
        assert!(metadata.expected().is_err());
        metadata = plan(false);
        metadata.launch.argv = vec!["x".repeat(1024 * 1024); 5];
        assert!(metadata.expected().is_err());
    }
}
