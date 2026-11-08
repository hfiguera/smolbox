//! One existing-agent OCI pull. Approval/creation authority stays in the engine;
//! this private worker cannot create a runtime, start a VM or select host settings.
use crate::{Error, ErrorCode, ImageObservation, Result};
use serde::{Deserialize, Serialize};

pub(crate) const METADATA_BYTES: u64 = 4096;
pub(crate) const PROGRESS_FRAMES: usize = 4096;
pub(crate) const REPLY_TOTAL_BYTES: usize = 64 * 1024 * 1024;

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
/// Digest-pinned pull intent. Validation supplies neither source approval nor
/// OCI creation authority; the enclosing engine must establish both separately.
pub struct ImagePullRequest {
    pub reference: String,
    pub platform: String,
}
impl ImagePullRequest {
    pub fn validate(&self) -> Result<()> {
        if !matches!(self.platform.as_str(), "linux/amd64" | "linux/arm64")
            || !reference(&self.reference)
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(())
    }
    pub fn matches(&self, image: &ImageObservation) -> bool {
        self.validate().is_ok()
            && image.validate().is_ok()
            && image.reference == self.reference
            && image.digest.starts_with("sha256:")
            && image.os == "linux"
            && image.architecture == self.platform.strip_prefix("linux/").unwrap_or("")
    }
}

// Match Source's public digest-pinned grammar without widening approval to tags,
// schemes, credentials, mirrors or proxy fields. Local/private registry intent
// still requires explicit worker/source/network approval before engine dispatch.
fn reference(value: &str) -> bool {
    if value.len() > 1024 {
        return false;
    }
    let Some((location, digest)) = value.split_once("@sha256:") else {
        return false;
    };
    if !crate::domain::valid_hex(digest, 64) {
        return false;
    }
    let Some((registry, repo)) = location.split_once('/') else {
        return false;
    };
    let host = if let Some((host, port)) = registry.split_once(':') {
        let Ok(number) = port.parse::<u16>() else {
            return false;
        };
        if number == 0 || number.to_string() != port {
            return false;
        }
        host
    } else {
        registry
    };
    let alnum = |b: u8| b.is_ascii_lowercase() || b.is_ascii_digit();
    if host.len() > 253
        || !(host == "localhost" || host.contains('.'))
        || !host.split('.').all(|label| {
            !label.is_empty()
                && label.len() <= 63
                && label.bytes().next().is_some_and(alnum)
                && label.bytes().last().is_some_and(alnum)
                && label.bytes().all(|b| alnum(b) || b == b'-')
        })
    {
        return false;
    }
    repo.split('/').all(|part| {
        let bytes = part.as_bytes();
        let mut offset = 0;
        while offset < bytes.len() && alnum(bytes[offset]) {
            offset += 1;
        }
        if offset == 0 {
            return false;
        }
        while offset < bytes.len() {
            match bytes[offset] {
                b'.' => offset += 1,
                b'_' => {
                    offset += 1;
                    if bytes.get(offset) == Some(&b'_') {
                        offset += 1;
                    }
                }
                b'-' => {
                    while bytes.get(offset) == Some(&b'-') {
                        offset += 1;
                    }
                }
                _ => return false,
            }
            let start = offset;
            while offset < bytes.len() && alnum(bytes[offset]) {
                offset += 1;
            }
            if offset == start {
                return false;
            }
        }
        true
    })
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Metadata {
    pub schema: u32,
    pub request: ImagePullRequest,
    pub deadline_ns: u64,
}
impl Metadata {
    pub(crate) fn validate(&self) -> Result<()> {
        self.request.validate()?;
        if self.schema != 1 || self.deadline_ns == 0 {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(())
    }
    fn remaining(&self) -> Result<std::time::Duration> {
        self.validate()?;
        let remaining = std::time::Duration::from_nanos(
            self.deadline_ns
                .saturating_sub(crate::buffered::monotonic_ns()?),
        );
        if remaining.is_zero() || remaining > std::time::Duration::from_secs(86400) {
            return Err(Error::before(ErrorCode::State));
        }
        Ok(remaining)
    }
}

pub(crate) fn run(
    request: &crate::transfer_worker::Request,
    blob: &crate::transfer_worker::Blob,
    expected: &ImagePullRequest,
) -> Result<ImageObservation> {
    let metadata: Metadata = blob.read(request.owner, METADATA_BYTES)?;
    metadata.validate()?;
    if &metadata.request != expected {
        return Err(Error::before(ErrorCode::Ownership));
    }
    execute(&request.socket, &metadata)
}

pub(crate) fn execute(socket: &std::path::Path, metadata: &Metadata) -> Result<ImageObservation> {
    let expected = &metadata.request;
    metadata.remaining()?;
    let mut connection = crate::agent_io::BoundedAgent::connect_pull(socket)?;
    let _timeout = connection
        .client
        .set_extended_read_timeout(metadata.remaining()?)
        .map_err(|_| Error::uncertain(ErrorCode::Native))?;
    connection
        .client
        .send_raw(&smolvm_protocol::AgentRequest::Pull {
            image: metadata.request.reference.clone(),
            oci_platform: Some(metadata.request.platform.clone()),
            auth: None,
            proxy: None,
            no_proxy: None,
        })
        .map_err(|_| Error::uncertain(ErrorCode::Native))?;
    // The relay consumes bounded progress without exposing strings, settings or
    // credentials. It delivers only one validated and projected final response.
    let smolvm_protocol::AgentResponse::Ok { data: Some(data) } = connection
        .client
        .recv_raw()
        .map_err(|_| Error::uncertain(ErrorCode::Native))?
    else {
        return Err(Error::uncertain(ErrorCode::Native));
    };
    let info: smolvm_protocol::ImageInfo =
        serde_json::from_value(data).map_err(|_| Error::uncertain(ErrorCode::Native))?;
    let image = ImageObservation {
        reference: info.reference,
        digest: info.digest,
        size: info.size,
        architecture: info.architecture,
        os: info.os,
        layer_count: info.layer_count as u64,
    };
    if !expected.matches(&image) || metadata.remaining().is_err() {
        return Err(Error::uncertain(ErrorCode::Native));
    }
    Ok(image)
}

impl crate::Engine {
    /// One pull on an already-running, receipt-bound direct OCI machine. The
    /// enclosing bridge selects the exact approved source and durable command
    /// slot before calling this; no inventory or guest result supplies approval.
    pub fn pull_image_owned(
        &self,
        receipt: &crate::CreationReceipt,
        request: ImagePullRequest,
        deadline: std::time::Instant,
        cancel: crate::Cancellation,
    ) -> Result<ImageObservation> {
        let before = || {
            let remaining = deadline.saturating_duration_since(std::time::Instant::now());
            if remaining.is_zero()
                || remaining > std::time::Duration::from_secs(86400)
                || cancel.is_cancelled()
            {
                return Err(Error::before(ErrorCode::State));
            }
            crate::ReadBudget::new(
                remaining.min(std::time::Duration::from_secs(30)),
                cancel.clone(),
            )
        };
        let budget = before()?;
        receipt.validate(self.binding())?;
        request.validate()?;
        let supervisor = self
            .transfers
            .as_ref()
            .ok_or(Error::before(ErrorCode::Unsupported))?;
        let permit = supervisor.reserve_pull()?;
        let gate = self.gate(&receipt.name)?;
        let machine = gate
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let source = self.source_lease(receipt)?;
        let record = self.qualified_pull_record(receipt, &request, &budget)?;
        if crate::identity::record_state(&record, false) != crate::ObservedState::Running
            || self
                .runtime_pid(&receipt.name)
                .is_some_and(|pid| smolvm::process::is_alive(pid) && record.pid != Some(pid))
        {
            return Err(Error::before(ErrorCode::State));
        }
        before()?;
        let remaining = deadline.saturating_duration_since(std::time::Instant::now());
        let deadline_ns = crate::buffered::monotonic_ns()?
            .checked_add(
                u64::try_from(remaining.as_nanos())
                    .map_err(|_| Error::before(ErrorCode::Validation))?,
            )
            .ok_or(Error::before(ErrorCode::Validation))?;
        let prepared = supervisor.prepare_pull_reserved(
            permit,
            &self.transfer_directory()?,
            self.vm_directory(&receipt.name).join("agent.sock"),
            request.clone(),
            deadline_ns,
        )?;
        before()?;
        let crate::transfer_supervisor::RunResult::Collected(collected) = supervisor.run(
            prepared,
            Box::new((machine, source, self.domain.clone())),
            deadline,
            &cancel,
        )?
        else {
            return Err(Error::uncertain(ErrorCode::Native));
        };
        if !collected.outcome.success() || !collected.outcome.native_acknowledged {
            return Err(Error::uncertain(ErrorCode::Native));
        }
        let image = collected
            .pulled
            .as_ref()
            .filter(|image| request.matches(image))
            .ok_or(Error::uncertain(ErrorCode::Native))?;
        let budget = before().map_err(|e| Error::uncertain(e.code))?;
        let after = self
            .qualified_pull_record(receipt, &request, &budget)
            .map_err(|e| Error::uncertain(e.code))?;
        if after.pid.zip(after.pid_start_time) != record.pid.zip(record.pid_start_time)
            || crate::identity::record_state(&after, false) != crate::ObservedState::Running
        {
            return Err(Error::uncertain(ErrorCode::State));
        }
        budget.check().map_err(|e| Error::uncertain(e.code))?;
        // Collected owns all leases until this final validation/result copy.
        // Pull never updates SDK creation metadata or the immutable receipt.
        Ok(image.clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn request(reference: &str) -> ImagePullRequest {
        ImagePullRequest {
            reference: reference.into(),
            platform: "linux/arm64".into(),
        }
    }
    #[test]
    fn digest_source_grammar_rejects_implicit_auth_tags_and_redirected_intent() {
        let digest = "a".repeat(64);
        for location in [
            "registry.example/team/app",
            "localhost:5000/a__b/c-d.e_f",
            "127.0.0.1/a--b",
        ] {
            assert!(request(&format!("{location}@sha256:{digest}"))
                .validate()
                .is_ok());
        }
        for location in [
            "https://registry.example/app",
            "user:secret@registry.example/app",
            "registry.example/app:tag",
            "registry.example/a___b",
            "registry.example/a..b",
            "registry.example//app",
            "registry.example/a/../b",
            "registry.example/a_",
            "REGISTRY.example/a",
            "registry.example:05000/a",
            "registry.example:0/a",
            "reg/a",
        ] {
            assert!(
                request(&format!("{location}@sha256:{digest}"))
                    .validate()
                    .is_err(),
                "{location}"
            );
        }
    }
    #[test]
    fn pulled_metadata_matches_exact_manifest_intent_but_returns_configuration_digest() {
        let request = request(&format!("registry.example/app@sha256:{}", "a".repeat(64)));
        let image = ImageObservation {
            reference: request.reference.clone(),
            digest: format!("sha256:{}", "b".repeat(64)),
            size: 123,
            architecture: "arm64".into(),
            os: "linux".into(),
            layer_count: 2,
        };
        assert!(request.matches(&image));
        for invalid in [
            ImageObservation {
                digest: "packed".into(),
                ..image.clone()
            },
            ImageObservation {
                architecture: "amd64".into(),
                ..image.clone()
            },
            ImageObservation {
                reference: "different".into(),
                ..image.clone()
            },
        ] {
            assert!(!request.matches(&invalid));
        }
    }
    #[test]
    fn metadata_cannot_add_auth_overrides_or_extend_its_finite_observation_budget() {
        let mut metadata = Metadata {
            schema: 1,
            request: request(&format!("registry.example/app@sha256:{}", "a".repeat(64))),
            deadline_ns: crate::buffered::monotonic_ns().unwrap() + 1_000_000_000,
        };
        assert!(metadata.remaining().is_ok());
        let mut value = serde_json::to_value(&metadata).unwrap();
        value["auth"] = serde_json::json!({"password":"PRIVATE=discard"});
        assert!(serde_json::from_value::<Metadata>(value).is_err());
        metadata.deadline_ns = 1;
        assert!(metadata.remaining().is_err());
        metadata.deadline_ns = crate::buffered::monotonic_ns().unwrap() + 86_401_000_000_000;
        assert!(metadata.remaining().is_err());
    }
}
