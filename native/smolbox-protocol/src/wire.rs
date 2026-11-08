//! Versioned bridge DTOs. These are intentionally separate from engine types.
//! No DTO implements Debug: commands, receipts and file bytes are sensitive.
use base64::{engine::general_purpose::STANDARD, Engine as _};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

pub const PROTOCOL_MAJOR: u16 = 1;
pub const PROTOCOL_MINOR: u16 = 4;
pub const PARITY_PROTOCOL_MAJOR: u16 = 2;
pub const PARITY_PROTOCOL_MINOR: u16 = 0;
pub const CANCEL_GRACE_MS: u64 = 3000;
pub const MAX_CHUNK_BYTES: usize = 64 * 1024;
pub const MAX_IN_FLIGHT: usize = 32;
pub const MAX_EVENTS_PER_REQUEST: u64 = 65536;
pub const INITIAL_CREDIT_BYTES: u64 = 256 * 1024;
pub const INITIAL_CREDIT_EVENTS: u64 = 64;
pub const MAX_TRANSFER_BYTES: u64 = 16 * 1024 * 1024;
/// Separate bounded artifact allowance; ordinary command/file caps stay fixed.
pub const MAX_CAPTURE_EVENTS: u64 = 64 * 1024 * 1024 * 1024 + 1;
pub const MAX_SAFE_INTEGER: u64 = (1 << 53) - 1;

/// Redacted wire validation error, independent of native diagnostics.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct InvalidMessage;
impl std::fmt::Display for InvalidMessage {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("invalid Port protocol message")
    }
}
impl std::error::Error for InvalidMessage {}
type Result<T> = std::result::Result<T, InvalidMessage>;

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PackageIdentity {
    pub engine_version: String,
    pub smolvm_revision: String,
    pub source_sha256: String,
    pub build_sha256: String,
    pub assets_sha256: String,
    pub platform: String,
    pub architecture: String,
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DomainIdentity {
    pub target_id: String,
    pub generation: String,
}

#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Capability {
    Volumes,
    PrepareArtifact,
    ListImages,
    PullImage,
    ExpandDisks,
    InspectGrowth,
    QualifyGrowth,
    TerminalOpen,
    TerminalPreflight,
    ExecStream,
    Logs,
    ExecBackground,
    ExecBuffered,
    Health,
    Capacity,
    Metrics,
    Readiness,
    List,
    Measurements,
    Create,
    Inspect,
    Start,
    Stop,
    Delete,
    Exec,
    ReadFile,
    WriteFile,
    QualifyCreation,
    InspectCreation,
}

#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SafeCode {
    NotFound,
    OutputLimit,
    PortConflict,
    Validation,
    Unsupported,
    Conflict,
    Ownership,
    Database,
    State,
    Native,
    Io,
    Overload,
    Package,
    Deadline,
    Cancelled,
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "status", rename_all = "snake_case", deny_unknown_fields)]
pub enum Preflight {
    Ready,
    Rejected { code: SafeCode },
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Limits {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exports: Option<Box<crate::ExportLimits>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub volumes: Option<Box<crate::VolumeLimits>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub terminals: Option<Box<crate::TerminalLimits>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub logs: Option<Box<LogLimits>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub buffered: Option<Box<BufferedLimits>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub jobs: Option<Box<JobLimits>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub creation: Option<Box<CreationLimits>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub observations: Option<Box<ObservationLimits>>,
    pub cancel_grace_ms: u64,
    pub frame_bytes: u64,
    pub chunk_bytes: u64,
    pub in_flight: u64,
    pub work_workers: u64,
    pub control_workers: u64,
    pub input_queue_encoded_bytes: u64,
    pub upload_spool_bytes: u64,
    pub credit_grace_ms: u64,
    pub writer_grace_ms: u64,
    pub events_per_request: u64,
    pub initial_credit_bytes: u64,
    pub initial_credit_events: u64,
    pub event_queue_decoded_bytes: u64,
    pub event_queue_encoded_bytes: u64,
    pub transfer_bytes: u64,
    pub command_ms: u64,
    pub file_ms: u64,
    pub cpus_min: u8,
    pub cpus_max: u8,
    pub memory_mib_min: u32,
    pub memory_mib_max: u32,
    pub disk_gib_min: u64,
    pub disk_gib_max: u64,
}
impl Default for Limits {
    fn default() -> Self {
        Self {
            exports: None,
            volumes: None,
            terminals: None,
            logs: None,
            creation: None,
            buffered: None,
            jobs: None,
            observations: None,
            cancel_grace_ms: CANCEL_GRACE_MS,
            frame_bytes: crate::MAX_FRAME_BYTES as u64,
            chunk_bytes: MAX_CHUNK_BYTES as u64,
            in_flight: MAX_IN_FLIGHT as u64,
            work_workers: 4,
            control_workers: 2,
            input_queue_encoded_bytes: 4 * 1024 * 1024,
            upload_spool_bytes: 128 * 1024 * 1024,
            credit_grace_ms: 1000,
            writer_grace_ms: 5000,
            events_per_request: MAX_EVENTS_PER_REQUEST,
            initial_credit_bytes: INITIAL_CREDIT_BYTES,
            initial_credit_events: INITIAL_CREDIT_EVENTS,
            event_queue_decoded_bytes: 8 * 1024 * 1024,
            event_queue_encoded_bytes: 12 * 1024 * 1024,
            transfer_bytes: MAX_TRANSFER_BYTES,
            command_ms: 86_400_000,
            file_ms: 600_000,
            cpus_min: 1,
            cpus_max: 16,
            memory_mib_min: 64,
            memory_mib_max: 65536,
            disk_gib_min: 1,
            disk_gib_max: 1024,
        }
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ObservationLimits {
    pub records: u64,
    pub record_bytes: u64,
    pub snapshot_bytes: u64,
    pub cpu_sample_ms: u64,
    pub disk_entries: u64,
    pub disk_depth: u64,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CreationLimits {
    pub schema: u8,
    pub payload_bytes: u64,
    pub chunks: u64,
    pub chunk_bytes: u64,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct JobLimits {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub metadata_bytes: Option<u64>,
    pub work_slots: u64,
    pub observation_slots: u64,
    pub worker_children: u64,
    pub staging_bytes: u64,
    pub descriptors: u64,
    pub control_fd_headroom: u64,
    pub agent_request_bytes: u64,
    pub agent_reply_overhead_bytes: u64,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BufferedLimits {
    pub payload_bytes: u64,
    pub chunks: u64,
    pub metadata_bytes: u64,
    pub stdin_bytes: u64,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LogLimits {
    pub raw_line_bytes: u64,
    pub lines: u64,
    pub line_bytes: u64,
    pub output_bytes: u64,
    pub memory_bytes: u64,
    pub poll_ms: u64,
}
impl Limits {
    pub fn for_sdk(sdk: &SdkIdentity) -> Self {
        let mut limits = Self::default();
        if sdk.feature_versions.get("exports") == Some(&1) {
            limits.exports = Some(Box::default());
        }
        if sdk.feature_versions.get("volumes") == Some(&1) {
            limits.volumes = Some(Box::default());
        }
        if sdk.feature_versions.get("terminals") == Some(&1) {
            limits.terminals = Some(Box::default());
        }
        if sdk.feature_versions.get("logs") == Some(&1) {
            limits.logs = Some(Box::new(LogLimits {
                lines: 10000,
                line_bytes: 131064,
                output_bytes: 8388608,
                memory_bytes: 6291456,
                raw_line_bytes: 1048576,
                poll_ms: 100,
            }));
        }
        if sdk.feature_versions.get("buffered_exec") == Some(&1) {
            limits.buffered = Some(Box::new(BufferedLimits {
                payload_bytes: crate::COMMAND_PAYLOAD_BYTES as u64,
                chunks: 11,
                metadata_bytes: 8388608,
                stdin_bytes: 65536,
            }));
        }
        if sdk.feature_versions.get("job_resources") == Some(&1) {
            limits.jobs = Some(Box::new(JobLimits {
                metadata_bytes: if limits.buffered.is_some() {
                    Some(33554432)
                } else {
                    None
                },
                work_slots: 4,
                observation_slots: 2,
                worker_children: 4,
                staging_bytes: 67108864,
                descriptors: 32,
                control_fd_headroom: 8,
                agent_request_bytes: 4194304,
                agent_reply_overhead_bytes: 65536,
            }));
        }
        if sdk.feature_versions.get("compact_creation") == Some(&1) {
            limits.creation = Some(Box::new(CreationLimits {
                schema: 1,
                payload_bytes: crate::MAX_CREATION_PAYLOAD as u64,
                chunks: crate::MAX_CREATION_CHUNKS as u64,
                chunk_bytes: MAX_CHUNK_BYTES as u64,
            }));
        }
        if sdk.feature_versions.get("observability") == Some(&1) {
            limits.observations = Some(Box::new(ObservationLimits {
                records: 1024,
                record_bytes: if limits.creation.is_some() {
                    8388608
                } else {
                    262144
                },
                snapshot_bytes: if limits.creation.is_some() {
                    33554432
                } else {
                    4194304
                },
                cpu_sample_ms: 25,
                disk_entries: 65536,
                disk_depth: 32,
            }));
        }
        limits
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Hello {
    pub major: u16,
    pub minor: u16,
    pub epoch: String,
    pub domain: DomainIdentity,
    pub package: PackageIdentity,
    pub capabilities: Vec<Capability>,
    pub limits: Limits,
    pub preflight: Preflight,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sdk: Option<Box<SdkIdentity>>,
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SdkIdentity {
    pub sdk_version: String,
    pub source_revision: String,
    pub feature_versions: BTreeMap<String, u16>,
}

impl SdkIdentity {
    /// Ordered handshake contract shared with the Elixir approved descriptor.
    pub fn capabilities(&self) -> Vec<Capability> {
        let mut capabilities = vec![
            Capability::Create,
            Capability::Inspect,
            Capability::Start,
            Capability::Stop,
            Capability::Delete,
            Capability::Exec,
            Capability::ReadFile,
            Capability::WriteFile,
            Capability::QualifyCreation,
            Capability::InspectCreation,
        ];
        if self.feature_versions.get("observability") == Some(&1) {
            let mut observations = vec![
                Capability::Health,
                Capability::Capacity,
                Capability::Metrics,
                Capability::Readiness,
                Capability::List,
                Capability::Measurements,
            ];
            observations.extend(capabilities);
            capabilities = observations;
        }
        for (feature, capability) in [
            ("volumes", Capability::Volumes),
            ("remote_sources", Capability::PrepareArtifact),
            ("logs", Capability::Logs),
            ("background_exec", Capability::ExecBackground),
            ("buffered_exec", Capability::ExecBuffered),
            ("streaming_exec", Capability::ExecStream),
            ("terminals", Capability::TerminalOpen),
            ("terminal_preflight", Capability::TerminalPreflight),
            ("disk_growth", Capability::QualifyGrowth),
            ("disk_growth", Capability::InspectGrowth),
            ("disk_growth", Capability::ExpandDisks),
            ("images", Capability::PullImage),
            ("images", Capability::ListImages),
        ] {
            if self.feature_versions.get(feature) == Some(&1) {
                capabilities.insert(0, capability);
            }
        }
        capabilities
    }

    pub fn validate(&self) -> Result<()> {
        text(&self.sdk_version, 64, false)?;
        hex(&self.source_revision, 40)?;
        require(self.feature_versions.len() <= 32)?;
        require(self.feature_versions.get("material_proofs") == Some(&2))?;
        for (feature, version) in &self.feature_versions {
            require(matches!(
                feature.as_str(),
                "lifecycle"
                    | "foreground_exec"
                    | "extended_exec"
                    | "files"
                    | "extended_files"
                    | "material_proofs"
                    | "observability"
                    | "networking"
                    | "ports"
                    | "workloads"
                    | "compact_creation"
                    | "job_resources"
                    | "buffered_exec"
                    | "streaming_exec"
                    | "remote_sources"
                    | "images"
                    | "background_exec"
                    | "logs"
                    | "terminals"
                    | "terminal_preflight"
                    | "volumes"
                    | "disk_growth"
                    | "checkpoints"
                    | "exports"
                    | "branches"
                    | "partial_cleanup_resolution"
                    | "partial_collection_preflight"
            ))?;
            require(*version == if feature == "material_proofs" { 2 } else { 1 })?;
        }
        require(
            self.feature_versions.get("partial_collection_preflight") != Some(&1)
                || self.feature_versions.get("branches") == Some(&1),
        )?;
        require(
            self.feature_versions.get("partial_cleanup_resolution") != Some(&1)
                || self.feature_versions.get("branches") == Some(&1),
        )?;
        require(
            self.feature_versions.get("buffered_exec") != Some(&1)
                || self.feature_versions.get("job_resources") == Some(&1),
        )?;
        require(
            self.feature_versions.get("background_exec") != Some(&1)
                || self.feature_versions.get("buffered_exec") == Some(&1),
        )?;
        require(
            self.feature_versions.get("logs") != Some(&1)
                || self.feature_versions.get("buffered_exec") == Some(&1),
        )?;
        require(
            self.feature_versions.get("streaming_exec") != Some(&1)
                || self.feature_versions.get("buffered_exec") == Some(&1),
        )?;
        require(
            self.feature_versions.get("images") != Some(&1)
                || self.feature_versions.get("job_resources") == Some(&1),
        )?;
        require(
            self.feature_versions.get("remote_sources") != Some(&1)
                || ["job_resources", "buffered_exec", "compact_creation"]
                    .iter()
                    .all(|name| self.feature_versions.get(*name) == Some(&1)),
        )?;
        require(
            self.feature_versions.get("disk_growth") != Some(&1)
                || self.feature_versions.get("job_resources") == Some(&1),
        )?;
        require(
            self.feature_versions.get("volumes") != Some(&1)
                || ["job_resources", "buffered_exec", "compact_creation"]
                    .iter()
                    .all(|name| self.feature_versions.get(*name) == Some(&1)),
        )?;
        require(
            self.feature_versions.get("terminal_preflight") != Some(&1)
                || self.feature_versions.get("terminals") == Some(&1),
        )?;
        require(
            self.feature_versions.get("terminals") != Some(&1)
                || self.feature_versions.get("buffered_exec") == Some(&1),
        )?;
        require(
            self.feature_versions.get("exports") != Some(&1)
                || ["job_resources", "buffered_exec", "compact_creation"]
                    .iter()
                    .all(|name| self.feature_versions.get(*name) == Some(&1)),
        )?;
        Ok(())
    }
}

impl Hello {
    pub fn validate(&self) -> Result<()> {
        match (self.major, self.minor, &self.sdk) {
            (PROTOCOL_MAJOR, PROTOCOL_MINOR, None) => {}
            (PARITY_PROTOCOL_MAJOR, PARITY_PROTOCOL_MINOR, Some(sdk)) => {
                sdk.validate()?;
                require(sdk.source_revision == self.package.smolvm_revision)?;
                require(self.package.engine_version == "0.2.0")?;
            }
            _ => return Err(InvalidMessage),
        }
        hex(&self.epoch, 32)?;
        id(&self.domain.target_id)?;
        hex(&self.domain.generation, 32)?;
        text(&self.package.engine_version, 64, false)?;
        hex(&self.package.smolvm_revision, 40)?;
        for hash in [
            &self.package.source_sha256,
            &self.package.build_sha256,
            &self.package.assets_sha256,
        ] {
            hex(hash, 64)?;
        }
        require(matches!(self.package.platform.as_str(), "linux" | "macos"))?;
        if self
            .sdk
            .as_ref()
            .is_some_and(|sdk| sdk.feature_versions.get("volumes") == Some(&1))
        {
            require(self.package.platform == "linux")?;
        }
        require(matches!(
            self.package.architecture.as_str(),
            "x86_64" | "aarch64"
        ))?;
        let expected_limits = self
            .sdk
            .as_ref()
            .map_or_else(Limits::default, |sdk| Limits::for_sdk(sdk));
        require(
            self.limits == expected_limits
                && self.capabilities.len() <= if self.major == 1 { 10 } else { 32 },
        )?;
        for (index, capability) in self.capabilities.iter().enumerate() {
            if *capability == Capability::PrepareArtifact {
                require(
                    self.major == 2
                        && self.sdk.as_ref().is_some_and(|sdk| {
                            sdk.feature_versions.get("remote_sources") == Some(&1)
                        }),
                )?;
            }
            if matches!(
                capability,
                Capability::ExpandDisks | Capability::InspectGrowth | Capability::QualifyGrowth
            ) {
                require(
                    self.major == 2
                        && self
                            .sdk
                            .as_ref()
                            .is_some_and(|sdk| sdk.feature_versions.get("disk_growth") == Some(&1)),
                )?;
            }
            if *capability == Capability::TerminalPreflight {
                require(
                    self.major == 2
                        && self.sdk.as_ref().is_some_and(|sdk| {
                            sdk.feature_versions.get("terminal_preflight") == Some(&1)
                        }),
                )?;
            }
            if *capability == Capability::TerminalOpen {
                require(
                    self.major == 2
                        && self.sdk.as_ref().is_some_and(|sdk| {
                            sdk.feature_versions.get("terminals") == Some(&1)
                                && sdk.feature_versions.get("buffered_exec") == Some(&1)
                        }),
                )?;
            }
            if *capability == Capability::ExecStream {
                require(
                    self.major == 2
                        && self.sdk.as_ref().is_some_and(|sdk| {
                            sdk.feature_versions.get("streaming_exec") == Some(&1)
                        }),
                )?;
            }
            if matches!(capability, Capability::ListImages | Capability::PullImage) {
                require(
                    self.major == 2
                        && self
                            .sdk
                            .as_ref()
                            .is_some_and(|sdk| sdk.feature_versions.get("images") == Some(&1)),
                )?;
            }
            if *capability == Capability::Logs {
                require(
                    self.major == 2
                        && self
                            .sdk
                            .as_ref()
                            .is_some_and(|sdk| sdk.feature_versions.get("logs") == Some(&1)),
                )?;
            }
            if *capability == Capability::ExecBackground {
                require(
                    self.major == 2
                        && self.sdk.as_ref().is_some_and(|sdk| {
                            sdk.feature_versions.get("background_exec") == Some(&1)
                        }),
                )?;
            }
            if *capability == Capability::ExecBuffered {
                require(
                    self.major == 2
                        && self.sdk.as_ref().is_some_and(|sdk| {
                            sdk.feature_versions.get("buffered_exec") == Some(&1)
                        }),
                )?;
            }
            require(!self.capabilities[..index].contains(capability))?;
            if matches!(
                capability,
                Capability::Health
                    | Capability::Capacity
                    | Capability::Metrics
                    | Capability::Readiness
                    | Capability::List
                    | Capability::Measurements
            ) {
                require(
                    self.major == 2
                        && self.sdk.as_ref().is_some_and(|sdk| {
                            sdk.feature_versions.get("observability") == Some(&1)
                        }),
                )?;
            }
        }
        Ok(())
    }
    /// The bridge echoes the exact locally approved tuple before any request.
    /// A failed preflight is useful diagnostics but cannot authorize work.
    pub fn approve(&self, approved: &Hello) -> Result<()> {
        self.validate()?;
        approved.validate()?;
        require(self == approved && self.preflight == Preflight::Ready)
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Receipt {
    pub target_id: String,
    pub domain_generation: String,
    pub name: String,
    pub owner_token: String,
    pub incarnation: String,
    pub material_sha256: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub material: Option<Box<MaterialProof>>,
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MaterialProof {
    pub schema: u8,
    pub revision: u32,
    pub record_sha256: String,
    pub chain_sha256: String,
    #[serde(deserialize_with = "required_nullable")]
    pub operation_id: Option<String>,
    #[serde(deserialize_with = "required_nullable")]
    pub request_sha256: Option<String>,
}

impl MaterialProof {
    pub fn validate(&self) -> Result<()> {
        require(self.schema == 2 && self.revision <= 1024)?;
        hex(&self.record_sha256, 64)?;
        hex(&self.chain_sha256, 64)?;
        if self.revision == 0 {
            require(self.operation_id.is_none() && self.request_sha256.is_none())?;
        } else {
            id(self.operation_id.as_deref().ok_or(InvalidMessage)?)?;
            hex(self.request_sha256.as_deref().ok_or(InvalidMessage)?, 64)?;
        }
        Ok(())
    }
}

impl Receipt {
    pub fn validate(&self) -> Result<()> {
        id(&self.target_id)?;
        id(&self.name)?;
        hex(&self.domain_generation, 32)?;
        hex(&self.owner_token, 64)?;
        hex(&self.incarnation, 32)?;
        hex(&self.material_sha256, 64)?;
        if let Some(material) = &self.material {
            material.validate()?;
            require(material.revision != 0 || material.record_sha256 == self.material_sha256)?;
        }
        Ok(())
    }

    pub fn validate_for(&self, major: u16) -> Result<()> {
        self.validate()?;
        require(matches!(major, PROTOCOL_MAJOR | PARITY_PROTOCOL_MAJOR))?;
        require(self.material.is_some() == (major == PARITY_PROTOCOL_MAJOR))
    }
    pub fn matches_domain(&self, domain: &DomainIdentity) -> bool {
        self.target_id == domain.target_id && self.domain_generation == domain.generation
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Resources {
    pub cpus: u8,
    pub memory_mib: u32,
    pub storage_gib: u64,
    pub overlay_gib: u64,
}
impl Resources {
    pub fn validate(&self) -> Result<()> {
        require(
            (1..=16).contains(&self.cpus)
                && (64..=65536).contains(&self.memory_mib)
                && (1..=1024).contains(&self.storage_gib)
                && (1..=1024).contains(&self.overlay_gib),
        )
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Artifact {
    pub path: String,
    pub sha256: String,
    pub max_bytes: u64,
    pub guest_platform: String,
}
impl Artifact {
    fn validate(&self) -> Result<()> {
        absolute_path(&self.path)?;
        hex(&self.sha256, 64)?;
        require(self.max_bytes > 0 && self.max_bytes <= 32 * 1024 * 1024 * 1024)?;
        require(matches!(
            self.guest_platform.as_str(),
            "linux/arm64" | "linux/amd64"
        ))
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Create {
    pub name: String,
    pub owner_token: String,
    pub incarnation: String,
    pub artifact: Artifact,
    pub resources: Resources,
    pub labels: BTreeMap<String, String>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "present_optional"
    )]
    pub checkpointable: Option<bool>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "present_optional"
    )]
    pub features: Option<Box<CreationFeatures>>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "present_optional"
    )]
    pub volume_mounts: Option<Vec<crate::VolumeMount>>,
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct OciIdentity {
    pub kind: String,
    pub id: String,
    pub sha256: String,
    pub architecture: String,
    pub reference: String,
}
impl OciIdentity {
    pub fn request(&self) -> OciSource {
        OciSource {
            reference: self.reference.clone(),
            platform: match self.architecture.as_str() {
                "x86_64" => "linux/amd64",
                "aarch64" => "linux/arm64",
                _ => "",
            }
            .into(),
        }
    }
    pub fn validate(&self) -> Result<()> {
        require(self.kind == "oci")?;
        id(&self.id)?;
        hex(&self.sha256, 64)?;
        self.request().validate()?;
        require(
            self.reference
                .rsplit_once("@sha256:")
                .map(|(_, digest)| digest)
                == Some(self.sha256.as_str()),
        )
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CheckpointIdentity {
    pub kind: String,
    pub id: String,
    pub sha256: String,
    pub architecture: String,
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CheckpointCreate {
    pub name: String,
    pub owner_token: String,
    pub incarnation: String,
    pub source: CheckpointIdentity,
    pub resources: Resources,
    pub labels: BTreeMap<String, String>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "present_optional"
    )]
    pub checkpointable: Option<bool>,
}
impl CheckpointCreate {
    pub fn validate(&self) -> Result<()> {
        id(&self.name)?;
        hex(&self.owner_token, 64)?;
        hex(&self.incarnation, 32)?;
        self.source.validate()?;
        self.resources.validate()?;
        require(self.labels.is_empty())
            .and_then(|()| checkpointable_mode(self.checkpointable, None, None))
    }
}
impl CheckpointIdentity {
    pub fn validate(&self) -> Result<()> {
        require(self.kind == "checkpoint")?;
        id(&self.id)?;
        hex(&self.sha256, 64)?;
        require(matches!(self.architecture.as_str(), "x86_64" | "aarch64"))
    }
    pub fn guest_platform(&self) -> &str {
        match self.architecture.as_str() {
            "x86_64" => "linux/amd64",
            "aarch64" => "linux/arm64",
            _ => "",
        }
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct OciCreate {
    pub name: String,
    pub owner_token: String,
    pub incarnation: String,
    pub source: OciIdentity,
    pub resources: Resources,
    pub labels: BTreeMap<String, String>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "present_optional"
    )]
    pub features: Option<Box<CreationFeatures>>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "present_optional"
    )]
    pub volume_mounts: Option<Vec<crate::VolumeMount>>,
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RegistryIdentity {
    pub kind: String,
    pub id: String,
    pub sha256: String,
    pub architecture: String,
    pub reference: String,
    pub content_sha256: String,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "present_optional"
    )]
    pub credential_ref: Option<String>,
}
impl RegistryIdentity {
    pub fn request(&self) -> RegistrySource {
        RegistrySource {
            reference: self.reference.clone(),
            platform: match self.architecture.as_str() {
                "x86_64" => "linux/amd64",
                "aarch64" => "linux/arm64",
                _ => "",
            }
            .into(),
            content_sha256: self.content_sha256.clone(),
        }
    }
    pub fn validate(&self) -> Result<()> {
        require(self.kind == "registry")?;
        id(&self.id)?;
        hex(&self.sha256, 64)?;
        self.request().validate()?;
        require(
            self.reference.rsplit_once("@sha256:").map(|(_, hash)| hash)
                == Some(self.sha256.as_str()),
        )?;
        if let Some(reference) = &self.credential_ref {
            id(reference)?;
        }
        Ok(())
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RegistryCreate {
    pub name: String,
    pub owner_token: String,
    pub incarnation: String,
    pub source: RegistryIdentity,
    pub resources: Resources,
    pub labels: BTreeMap<String, String>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "present_optional"
    )]
    pub checkpointable: Option<bool>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "present_optional"
    )]
    pub features: Option<Box<CreationFeatures>>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "present_optional"
    )]
    pub volume_mounts: Option<Vec<crate::VolumeMount>>,
}
impl RegistryCreate {
    pub fn validate(&self) -> Result<()> {
        id(&self.name)?;
        hex(&self.owner_token, 64)?;
        hex(&self.incarnation, 32)?;
        self.source.validate()?;
        self.resources.validate()?;
        require(self.labels.is_empty())?;
        checkpointable_mode(
            self.checkpointable,
            self.features.as_deref(),
            self.volume_mounts.as_deref(),
        )?;
        if let Some(features) = &self.features {
            features.validate()?;
        }
        if let Some(mounts) = &self.volume_mounts {
            crate::VolumeMount::validate_set(mounts)?;
        }
        Ok(())
    }
}
impl OciCreate {
    pub fn validate(&self) -> Result<()> {
        id(&self.name)?;
        hex(&self.owner_token, 64)?;
        hex(&self.incarnation, 32)?;
        self.source.validate()?;
        self.resources.validate()?;
        require(self.labels.is_empty())?;
        if let Some(features) = &self.features {
            features.validate()?;
        }
        if let Some(mounts) = &self.volume_mounts {
            crate::VolumeMount::validate_set(mounts)?;
        }
        Ok(())
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NetworkPolicy {
    pub enabled: bool,
    pub hosts: Vec<String>,
    pub cidrs: Vec<String>,
}
#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PortMapping {
    pub host: u16,
    pub guest: u16,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StartupWorkload {
    pub entrypoint: Vec<String>,
    pub cmd: Vec<String>,
    pub env: BTreeMap<String, String>,
    pub workdir: Option<String>,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CreationFeatures {
    #[serde(skip)]
    pub compact: bool,
    pub network: NetworkPolicy,
    pub ports: Vec<PortMapping>,
    pub workload: Option<StartupWorkload>,
}
impl CreationFeatures {
    pub fn validate(&self) -> Result<()> {
        require(
            self.network.hosts.len() <= 32
                && self.network.cidrs.len() <= 32
                && self.ports.len() <= 32,
        )?;
        require(
            self.network.enabled
                == (!self.network.hosts.is_empty() || !self.network.cidrs.is_empty()),
        )?;
        require(
            self.network.hosts.windows(2).all(|pair| pair[0] < pair[1])
                && self.network.cidrs.windows(2).all(|pair| pair[0] < pair[1]),
        )?;
        for host in &self.network.hosts {
            text(host, 253, false)?;
        }
        for cidr in &self.network.cidrs {
            text(cidr, 49, false)?;
        }
        require(
            self.ports.iter().all(|p| p.host > 0 && p.guest > 0)
                && self
                    .ports
                    .windows(2)
                    .all(|pair| pair[0].host < pair[1].host),
        )?;
        if let Some(workload) = &self.workload {
            require(
                workload.entrypoint.len() + workload.cmd.len() <= 255 && workload.env.len() <= 64,
            )?;
            require(
                workload.entrypoint.first().is_none_or(|v| !v.is_empty())
                    && workload.cmd.first().is_none_or(|v| !v.is_empty()),
            )?;
            let mut bytes = 0;
            for arg in workload.entrypoint.iter().chain(&workload.cmd) {
                text(arg, 16384, true)?;
                bytes += arg.len();
            }
            require(bytes <= 65532)?;
            for (key, value) in &workload.env {
                text(key, 128, false)?;
                text(value, 8192, true)?;
                let mut name = key.bytes();
                require(
                    name.next()
                        .is_some_and(|b| b.is_ascii_alphabetic() || b == b'_')
                        && name.all(|b| b.is_ascii_alphanumeric() || b == b'_'),
                )?;
                bytes += key.len() + value.len();
            }
            require(bytes <= 65532 + 64 * (128 + 8192))?;
            if let Some(path) = &workload.workdir {
                text(path, 4096, false)?;
                require(path.starts_with('/'))?;
            }
        }
        Ok(())
    }
    pub fn approved(&self, hello: &Hello) -> bool {
        hello.major == 2
            && hello.sdk.as_ref().is_some_and(|sdk| {
                if self.compact && sdk.feature_versions.get("compact_creation") != Some(&1) {
                    return false;
                }
                if !["networking", "ports", "workloads"]
                    .iter()
                    .any(|name| sdk.feature_versions.get(*name) == Some(&1))
                {
                    return false;
                }
                (!self.network.enabled || sdk.feature_versions.get("networking") == Some(&1))
                    && (self.ports.is_empty() || sdk.feature_versions.get("ports") == Some(&1))
                    && (self.workload.is_none()
                        || sdk.feature_versions.get("workloads") == Some(&1))
            })
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MachineConfiguration {
    pub network: NetworkPolicy,
    pub ports: Vec<PortMapping>,
    pub backend: Option<String>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "present_optional"
    )]
    pub mounts: Option<Vec<ObservedMount>>,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ObservedMount {
    pub source: String,
    pub target: String,
    pub readonly: bool,
    pub staged: bool,
}
impl ObservedMount {
    fn path(value: &str) -> bool {
        (2..=4096).contains(&value.len())
            && value.starts_with('/')
            && !value.ends_with('/')
            && !value.contains(['\0', '\\'])
            && !value.contains("//")
            && !value.split('/').any(|part| matches!(part, "." | ".."))
    }
    fn validate_set(mounts: &[Self]) -> Result<()> {
        require(!mounts.is_empty() && mounts.len() <= 8)?;
        for (index, mount) in mounts.iter().enumerate() {
            require(
                Self::path(&mount.source)
                    && Self::path(&mount.target)
                    && mount.target.starts_with("/mnt/volumes/")
                    && !mount.staged,
            )?;
            for previous in &mounts[..index] {
                require(
                    previous.source != mount.source
                        && previous.target < mount.target
                        && !mount.target.starts_with(&format!("{}/", previous.target)),
                )?;
            }
        }
        Ok(())
    }
}
impl MachineConfiguration {
    fn validate(&self) -> Result<()> {
        if let Some(mounts) = &self.mounts {
            ObservedMount::validate_set(mounts)?;
        }
        CreationFeatures {
            compact: false,
            network: self.network.clone(),
            ports: self.ports.clone(),
            workload: None,
        }
        .validate()?;
        require(
            self.backend.as_deref() == Some("virtio-net")
                || (self.backend.is_none() && !self.network.enabled && self.ports.is_empty()),
        )
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Command {
    pub argv: Vec<String>,
    pub env: BTreeMap<String, String>,
    pub workdir: Option<String>,
    pub user: Option<String>,
    pub max_output_bytes: u64,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BufferedCommand {
    pub argv: Vec<String>,
    pub env: BTreeMap<String, String>,
    pub workdir: Option<String>,
    pub user: Option<String>,
    pub stdin: Option<String>,
    pub max_output_bytes: u64,
}
impl BufferedCommand {
    pub fn validate(&self) -> Result<()> {
        require(!self.argv.is_empty() && self.argv.len() <= 256 && !self.argv[0].is_empty())?;
        let mut size = 0;
        for arg in &self.argv {
            text(arg, 16384, true)?;
            size += arg.len();
        }
        require(size <= 65536)?;
        require(self.env.len() <= 64)?;
        for (key, value) in &self.env {
            text(key, 128, false)?;
            text(value, 8192, true)?;
            let mut name = key.bytes();
            require(
                name.next()
                    .is_some_and(|b| b.is_ascii_alphabetic() || b == b'_')
                    && name.all(|b| b.is_ascii_alphanumeric() || b == b'_'),
            )?;
        }
        if let Some(path) = &self.workdir {
            absolute_path(path)?;
        }
        if let Some(user) = &self.user {
            text(user, 128, false)?;
        }
        if let Some(stdin) = &self.stdin {
            require(stdin.len() <= 65536)?;
        }
        require(self.max_output_bytes > 0 && self.max_output_bytes <= MAX_TRANSFER_BYTES)
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FileOptions {
    pub guest_path: String,
    pub max_bytes: u64,
    pub mode: Option<u32>,
}

/// Exact credential-free sidecar source. Operator byte/cache policy is selected
/// from helper config; request callers cannot alter it or select host paths.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RegistrySource {
    pub reference: String,
    pub platform: String,
    pub content_sha256: String,
}

/// Bounded ephemeral identity token. No Debug or source identity field exposes
/// its bytes; bridges discard it from session/handle state after admission.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct RegistryToken(String);
impl std::fmt::Debug for RegistryToken {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("RegistryToken(<redacted>)")
    }
}
impl RegistryToken {
    pub fn validate(&self) -> Result<()> {
        let body = self.0.trim_end_matches('=');
        require(
            !body.is_empty()
                && self.0.len() <= 16384
                && body
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"._~+/-".contains(&b)),
        )
    }
    pub fn into_secret(self) -> String {
        self.0
    }
}
impl RegistrySource {
    pub fn validate(&self) -> Result<()> {
        OciSource {
            reference: self.reference.clone(),
            platform: self.platform.clone(),
        }
        .validate()?;
        hex(&self.content_sha256, 64)
    }
}

/// Credential-free exact OCI target; full registry/repository eligibility is
/// checked by helper catalog loading and the shared engine before guest entry.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct OciSource {
    pub reference: String,
    pub platform: String,
}
impl OciSource {
    pub fn validate(&self) -> Result<()> {
        text(&self.reference, 1024, false)?;
        require(matches!(
            self.platform.as_str(),
            "linux/amd64" | "linux/arm64"
        ))?;
        require(valid_oci_reference(&self.reference))
    }
}
fn valid_oci_reference(value: &str) -> bool {
    if value.len() > 1024 {
        return false;
    }
    let Some((location, digest)) = value.split_once("@sha256:") else {
        return false;
    };
    if hex(digest, 64).is_err() {
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

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ImageObservation {
    pub reference: String,
    pub digest: String,
    pub size: u64,
    pub architecture: String,
    pub os: String,
    pub layer_count: u64,
}
impl ImageObservation {
    pub fn validate(&self) -> Result<()> {
        text(&self.reference, 1024, false)?;
        text(&self.architecture, 64, false)?;
        text(&self.os, 64, false)?;
        if self.digest != "packed" {
            hex(
                self.digest.strip_prefix("sha256:").ok_or(InvalidMessage)?,
                64,
            )?;
        }
        require(self.size <= i64::MAX as u64 && self.layer_count <= 65536)
    }
    pub fn matches(&self, source: &OciSource) -> Result<()> {
        self.validate()?;
        source.validate()?;
        require(
            self.reference == source.reference
                && self.digest != "packed"
                && self.os == "linux"
                && Some(self.architecture.as_str()) == source.platform.strip_prefix("linux/"),
        )
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "operation", rename_all = "snake_case", deny_unknown_fields)]
pub enum Operation {
    PublishCollectedBranchMaterial {
        request: Box<crate::BranchCreateRequest>,
        quiesced: bool,
    },
    InspectUnbootedBranchDisposal {
        request: Box<crate::BranchCreateRequest>,
        quiesced: bool,
    },
    DisposeUnbootedBranch {
        request: Box<crate::UnbootedBranchDisposalRequest>,
    },
    ResolveUnbootedBranchDisposal {
        request: Box<crate::UnbootedBranchDisposalRequest>,
    },
    ReleaseUnbootedBranchBacking {
        request: Box<crate::UnbootedBranchBackingReleaseRequest>,
    },
    ReleasePartialBranchBacking {
        request: Box<crate::PartialBranchBackingReleaseRequest>,
    },
    RetirePreparedBranch {
        request: Box<crate::PreparedBranchRetirementRequest>,
    },
    ContinueHeldBranchDeletion {
        request: Box<crate::HeldBranchDeletionActionRequest>,
    },
    CleanupHeldBranchDeletion {
        request: Box<crate::HeldBranchDeletionActionRequest>,
    },
    ContinueReleasedBranchDeletion {
        request: Box<crate::ReleasedBranchDeletionContinuationRequest>,
    },
    DisposePartialBranch {
        request: Box<crate::PartialBranchDisposalRequest>,
    },
    ResolvePartialBranchDisposal {
        request: Box<crate::PartialBranchDisposalRequest>,
    },
    QualifyPartialBranchCleanup {
        request: Box<crate::PartialBranchDisposalRequest>,
    },
    CleanupPartialBranchDisposal {
        request: Box<crate::PartialBranchDisposalCleanupRequest>,
    },
    ResolvePartialBranchCleanup {
        request: Box<crate::PartialBranchDisposalCleanupRequest>,
    },
    InspectPartialBranchCollection {
        request: Box<crate::PartialBranchCollectionRequest>,
    },
    CollectPartialBranch {
        request: Box<crate::PartialBranchCollectionRequest>,
    },
    CollectBranchDeletion {
        request: Box<crate::BranchDeletionCollectionRequest>,
    },
    CleanupReleasedBranchDeletion {
        request: Box<crate::ReleasedBranchDeletionCleanupRequest>,
    },
    ResolveReleasedBranchDeletion {
        request: Box<crate::ReleasedBranchDeletionRequest>,
    },
    ResolveHeldBranchDeletion {
        request: Box<crate::HeldBranchDeletionRequest>,
    },
    ReleaseBranchBacking {
        request: Box<crate::BranchBackingReleaseRequest>,
    },
    QualifyUnbootedBranchChildAbsence {
        request: Box<crate::UnbootedBranchChildAbsenceRequest>,
    },
    QualifyPartialBranchChildAbsence {
        request: Box<crate::PartialBranchChildAbsenceRequest>,
    },
    QualifyBranchChildAbsence {
        request: Box<crate::BranchChildAbsenceRequest>,
    },
    ReleaseHeldBranch {
        request: Box<crate::BranchHeldReleaseRequest>,
    },
    QualifyHeldBranchRelease {
        request: Box<crate::BranchHeldReleaseRequest>,
    },
    CreateBranch {
        request: Box<crate::BranchCreateRequest>,
    },
    InspectBranchCompletion {
        request: Box<crate::BranchCreateRequest>,
    },
    ResolveReadyBranchCompletion {
        request: Box<crate::BranchCreateRequest>,
        quiesced: bool,
    },
    BranchPreflight {
        receipt: Receipt,
    },
    QualifyExport {
        receipt: Receipt,
        request: crate::ExportRequest,
    },
    AdmitExport {
        receipt: Receipt,
        operation_id: String,
        request: crate::ExportRequest,
    },
    ExportMachine {
        receipt: Receipt,
        operation_id: String,
        request: crate::ExportRequest,
        push_token: RegistryToken,
    },
    InspectExport {
        receipt: Receipt,
        operation_id: String,
        request_sha256: String,
    },
    CleanupExportStaging {
        receipt: Receipt,
        operation_id: String,
        request_sha256: String,
        quiesced: bool,
    },
    QualifyAbortedCaptureSource {
        receipt: Receipt,
        operation_id: String,
        request: crate::CaptureRequest,
        quiesced: bool,
    },
    AbortCaptureStaging {
        receipt: Receipt,
        operation_id: String,
        request: crate::CaptureRequest,
        quiesced: bool,
    },
    CleanupCaptureStaging {
        receipt: Receipt,
        operation_id: String,
        request: crate::CaptureRequest,
        quiesced: bool,
    },
    ResolveCapture {
        receipt: Receipt,
        operation_id: String,
        request: crate::CaptureRequest,
        quiesced: bool,
    },
    InspectCaptureResolution {
        receipt: Receipt,
        operation_id: String,
        request: crate::CaptureRequest,
    },
    CaptureCheckpoint {
        receipt: Receipt,
        operation_id: String,
        request: crate::CaptureRequest,
        #[serde(
            default,
            skip_serializing_if = "Option::is_none",
            deserialize_with = "present_optional"
        )]
        chunk_bytes: Option<u64>,
    },
    InspectCapture {
        receipt: Receipt,
        operation_id: String,
        request: crate::CaptureRequest,
    },
    StartCheckpointable {
        receipt: Receipt,
    },
    CheckpointPreflight {
        receipt: Receipt,
    },
    QualifyCheckpointCreation {
        source: CheckpointIdentity,
        resources: Resources,
        #[serde(
            default,
            skip_serializing_if = "Option::is_none",
            deserialize_with = "present_optional"
        )]
        checkpointable: Option<bool>,
    },
    CreateCheckpoint {
        create: CheckpointCreate,
    },
    InspectCheckpointCreation {
        create: CheckpointCreate,
    },
    Volume {
        request: crate::VolumeRequest,
    },
    QualifyRegistryCreation {
        source: RegistryIdentity,
        resources: Resources,
        user: Option<String>,
        #[serde(
            default,
            skip_serializing_if = "Option::is_none",
            deserialize_with = "present_optional"
        )]
        checkpointable: Option<bool>,
        #[serde(
            default,
            skip_serializing_if = "Option::is_none",
            deserialize_with = "present_optional"
        )]
        features: Option<Box<CreationFeatures>>,
    },
    CreateRegistryPrepared {
        create: RegistryCreate,
        size_bytes: u64,
    },
    InspectRegistryCreation {
        create: RegistryCreate,
    },
    PrepareArtifact {
        source: RegistrySource,
        #[serde(
            default,
            skip_serializing_if = "Option::is_none",
            deserialize_with = "present_optional"
        )]
        credential_ref: Option<String>,
        #[serde(
            default,
            skip_serializing_if = "Option::is_none",
            deserialize_with = "present_optional"
        )]
        identity_token: Option<RegistryToken>,
    },
    StartOci {
        receipt: Receipt,
        source: OciIdentity,
    },
    CreateOci {
        create: OciCreate,
    },
    InspectOciCreation {
        create: OciCreate,
    },
    QualifyOciCreation {
        source: OciIdentity,
        resources: Resources,
        user: Option<String>,
        #[serde(
            default,
            skip_serializing_if = "Option::is_none",
            deserialize_with = "present_optional"
        )]
        features: Option<Box<CreationFeatures>>,
    },
    PullImage {
        receipt: Receipt,
        source: OciSource,
    },
    ListImages {
        receipt: Receipt,
    },
    ExpandDisks {
        receipt: Receipt,
        operation_id: String,
        request: crate::GrowDisks,
        previous: crate::DiskSizes,
    },
    InspectGrowth {
        receipt: Receipt,
        operation_id: String,
        request: crate::GrowDisks,
        previous: crate::DiskSizes,
    },
    QualifyGrowth {
        receipt: Receipt,
        operation_id: String,
        request: crate::GrowDisks,
        previous: crate::DiskSizes,
        quiesced: bool,
    },
    TerminalPreflight {
        receipt: Receipt,
    },
    TerminalOpen {
        receipt: Receipt,
        terminal: crate::TerminalSpec,
    },
    ExecStream {
        receipt: Receipt,
        command: BufferedCommand,
    },
    Logs {
        receipt: Receipt,
        tail: u64,
        follow: bool,
        max_bytes: u64,
    },
    ExecBackground {
        receipt: Receipt,
        command: BufferedCommand,
    },
    ExecBuffered {
        receipt: Receipt,
        command: BufferedCommand,
    },
    Health,
    Capacity,
    Metrics,
    Readiness,
    List,
    Measurements {
        receipt: Receipt,
    },
    QualifyCreation {
        artifact: Artifact,
        resources: Resources,
        user: Option<String>,
        #[serde(
            default,
            skip_serializing_if = "Option::is_none",
            deserialize_with = "present_optional"
        )]
        checkpointable: Option<bool>,
        #[serde(
            default,
            skip_serializing_if = "Option::is_none",
            deserialize_with = "present_optional"
        )]
        features: Option<Box<CreationFeatures>>,
    },
    Create {
        create: Create,
    },
    InspectCreation {
        create: Create,
    },
    Inspect {
        receipt: Receipt,
    },
    Start {
        receipt: Receipt,
    },
    Stop {
        receipt: Receipt,
    },
    Delete {
        receipt: Receipt,
    },
    Exec {
        receipt: Receipt,
        command: Command,
    },
    ReadFile {
        receipt: Receipt,
        options: FileOptions,
    },
    WriteFile {
        receipt: Receipt,
        options: FileOptions,
        total_bytes: u64,
    },
}
impl Operation {
    pub fn held_deletion_action_request(&self) -> Option<&crate::HeldBranchDeletionActionRequest> {
        match self {
            Self::ContinueHeldBranchDeletion { request }
            | Self::CleanupHeldBranchDeletion { request } => Some(request),
            _ => None,
        }
    }
    pub fn branch_epoch(&self) -> Option<&str> {
        match self {
            Self::QualifyUnbootedBranchChildAbsence { request } => Some(
                &request
                    .disposal
                    .publication
                    .change
                    .child_origin
                    .intent
                    .epoch,
            ),
            Self::QualifyPartialBranchChildAbsence { request } => Some(
                &request
                    .disposal
                    .publication
                    .change
                    .child_origin
                    .intent
                    .epoch,
            ),
            Self::ReleasePartialBranchBacking { request } => Some(
                &request
                    .disposal
                    .publication
                    .change
                    .child_origin
                    .intent
                    .epoch,
            ),
            _ => None,
        }
    }
    pub fn branch_platform(&self) -> Option<&str> {
        if let Self::ReleasePartialBranchBacking { request } = self {
            return Some(&request.disposal.publication.change.platform);
        }
        if let Self::ReleaseUnbootedBranchBacking { request } = self {
            return Some(&request.disposal.publication.change.platform);
        }
        if let Some(request) = self.held_deletion_action_request() {
            return Some(&request.completion.publication.change.platform);
        }
        if let Self::ContinueReleasedBranchDeletion { request } = self {
            return Some(&request.completion.publication.change.platform);
        }
        if let Self::CleanupReleasedBranchDeletion { request } = self {
            return Some(&request.completion.publication.change.platform);
        }
        if let Self::CollectBranchDeletion { request } = self {
            return Some(&request.completion.publication.change.platform);
        }
        if let Self::ResolveReleasedBranchDeletion { request } = self {
            return Some(&request.completion.publication.change.platform);
        }
        if let Self::ResolveHeldBranchDeletion { request } = self {
            return Some(&request.completion.publication.change.platform);
        }
        if let Self::ReleaseBranchBacking { request } = self {
            return Some(&request.completion.publication.change.platform);
        }
        if let Self::QualifyUnbootedBranchChildAbsence { request } = self {
            return Some(&request.disposal.publication.change.platform);
        }
        if let Self::QualifyPartialBranchChildAbsence { request } = self {
            return Some(&request.disposal.publication.change.platform);
        }
        if let Self::QualifyBranchChildAbsence { request } = self {
            return Some(&request.completion.publication.change.platform);
        }
        self.held_branch_request()
            .map(|request| request.completion.publication.change.platform.as_str())
    }
    pub fn partial_disposal_request(&self) -> Option<&crate::PartialBranchDisposalRequest> {
        match self {
            Self::DisposePartialBranch { request }
            | Self::ResolvePartialBranchDisposal { request } => Some(request),
            _ => None,
        }
    }
    pub fn branch_approval(&self) -> Option<&crate::BranchApproval> {
        if let Self::QualifyPartialBranchCleanup { request } = self {
            return Some(&request.collection_request.creation.approval);
        }
        if let Self::CleanupPartialBranchDisposal { request }
        | Self::ResolvePartialBranchCleanup { request } = self
        {
            return Some(
                &request
                    .disposal_request
                    .collection_request
                    .creation
                    .approval,
            );
        }
        if let Self::InspectUnbootedBranchDisposal { request, .. } = self {
            return Some(&request.approval);
        }
        if let Some(request) = self.unbooted_disposal_request() {
            return Some(&request.creation.approval);
        }
        if let Self::ReleasePartialBranchBacking { request } = self {
            return Some(request.approval());
        }
        if let Self::ReleaseUnbootedBranchBacking { request } = self {
            return Some(&request.disposal.creation.approval);
        }
        if let Self::RetirePreparedBranch { request } = self {
            return Some(&request.creation.approval);
        }
        if let Some(request) = self.held_deletion_action_request() {
            return Some(request.approval());
        }
        if let Self::ContinueReleasedBranchDeletion { request } = self {
            return Some(request.approval());
        }
        if let Self::CleanupReleasedBranchDeletion { request } = self {
            return Some(request.approval());
        }
        if let Some(request) = self.partial_disposal_request() {
            return Some(&request.collection_request.creation.approval);
        }
        if let Self::CollectPartialBranch { request }
        | Self::InspectPartialBranchCollection { request } = self
        {
            return Some(&request.creation.approval);
        }
        if let Self::CollectBranchDeletion { request } = self {
            return Some(request.approval());
        }
        if let Self::ResolveReleasedBranchDeletion { request } = self {
            return Some(request.approval());
        }
        if let Self::ResolveHeldBranchDeletion { request } = self {
            return Some(request.approval());
        }
        if let Self::ReleaseBranchBacking { request } = self {
            return Some(request.approval());
        }
        if let Self::QualifyUnbootedBranchChildAbsence { request } = self {
            return Some(request.approval());
        }
        if let Self::QualifyPartialBranchChildAbsence { request } = self {
            return Some(request.approval());
        }
        if let Self::QualifyBranchChildAbsence { request } = self {
            return Some(request.approval());
        }
        if let Some(request) = self.held_branch_request() {
            return Some(request.approval());
        }
        self.branch_request().map(|request| &request.approval)
    }
    pub fn unbooted_disposal_request(&self) -> Option<&crate::UnbootedBranchDisposalRequest> {
        match self {
            Self::DisposeUnbootedBranch { request }
            | Self::ResolveUnbootedBranchDisposal { request } => Some(request),
            _ => None,
        }
    }
    pub fn held_branch_request(&self) -> Option<&crate::BranchHeldReleaseRequest> {
        match self {
            Self::ReleaseHeldBranch { request } | Self::QualifyHeldBranchRelease { request } => {
                Some(request)
            }
            _ => None,
        }
    }
    pub fn branch_request(&self) -> Option<&crate::BranchCreateRequest> {
        match self {
            Self::CreateBranch { request }
            | Self::InspectBranchCompletion { request }
            | Self::PublishCollectedBranchMaterial { request, .. }
            | Self::ResolveReadyBranchCompletion { request, .. } => Some(request),
            _ => None,
        }
    }
    pub fn checkpointable(&self) -> Option<bool> {
        match self {
            Self::QualifyCreation { checkpointable, .. }
            | Self::QualifyRegistryCreation { checkpointable, .. }
            | Self::QualifyCheckpointCreation { checkpointable, .. } => *checkpointable,
            Self::Create { create } | Self::InspectCreation { create } => create.checkpointable,
            Self::CreateRegistryPrepared { create, .. }
            | Self::InspectRegistryCreation { create } => create.checkpointable,
            Self::CreateCheckpoint { create } | Self::InspectCheckpointCreation { create } => {
                create.checkpointable
            }
            _ => None,
        }
    }
    pub fn sanitized(&self) -> Self {
        match self {
            Self::ExportMachine {
                receipt,
                operation_id,
                request,
                ..
            } => Self::ExportMachine {
                receipt: receipt.clone(),
                operation_id: operation_id.clone(),
                request: request.clone(),
                push_token: RegistryToken(String::new()),
            },
            Self::PrepareArtifact {
                source,
                credential_ref,
                ..
            } => Self::PrepareArtifact {
                source: source.clone(),
                credential_ref: credential_ref.clone(),
                identity_token: None,
            },
            _ => self.clone(),
        }
    }
    pub fn registry_source(&self) -> Option<&RegistrySource> {
        match self {
            Self::PrepareArtifact { source, .. } => Some(source),
            _ => None,
        }
    }
    pub fn checkpoint_source(&self) -> Option<(&CheckpointIdentity, &Resources)> {
        match self {
            Self::QualifyCheckpointCreation {
                source, resources, ..
            } => Some((source, resources)),
            Self::CreateCheckpoint { create } | Self::InspectCheckpointCreation { create } => {
                Some((&create.source, &create.resources))
            }
            _ => None,
        }
    }
    pub fn registry_identity(&self) -> Option<&RegistryIdentity> {
        match self {
            Self::QualifyRegistryCreation { source, .. } => Some(source),
            Self::CreateRegistryPrepared { create, .. }
            | Self::InspectRegistryCreation { create } => Some(&create.source),
            _ => None,
        }
    }
    pub fn oci_source(&self) -> Option<OciSource> {
        match self {
            Self::StartOci { source, .. } => Some(source.request()),
            Self::CreateOci { create } | Self::InspectOciCreation { create } => {
                Some(create.source.request())
            }
            Self::QualifyOciCreation { source, .. } => Some(source.request()),
            Self::PullImage { source, .. } => Some(source.clone()),
            _ => None,
        }
    }
    pub fn requires_remote_source(&self) -> bool {
        matches!(
            self,
            Self::StartOci { .. }
                | Self::PrepareArtifact { .. }
                | Self::CreateRegistryPrepared { .. }
                | Self::InspectRegistryCreation { .. }
                | Self::QualifyRegistryCreation { .. }
                | Self::CreateOci { .. }
                | Self::InspectOciCreation { .. }
                | Self::QualifyOciCreation { .. }
        )
    }
    pub fn requires_exports(&self) -> bool {
        matches!(
            self,
            Self::QualifyExport { .. }
                | Self::AdmitExport { .. }
                | Self::ExportMachine { .. }
                | Self::InspectExport { .. }
                | Self::CleanupExportStaging { .. }
        )
    }
    pub fn requires_checkpoints(&self) -> bool {
        self.checkpoint_source().is_some()
            || self.checkpointable() == Some(true)
            || matches!(
                self,
                Self::StartCheckpointable { .. }
                    | Self::CheckpointPreflight { .. }
                    | Self::InspectCapture { .. }
                    | Self::InspectCaptureResolution { .. }
                    | Self::ResolveCapture { .. }
                    | Self::QualifyAbortedCaptureSource { .. }
                    | Self::AbortCaptureStaging { .. }
                    | Self::CleanupCaptureStaging { .. }
                    | Self::CaptureCheckpoint { .. }
            )
    }
    pub fn requires_branches(&self) -> bool {
        matches!(
            self,
            Self::InspectUnbootedBranchDisposal { .. }
                | Self::PublishCollectedBranchMaterial { .. }
                | Self::BranchPreflight { .. }
                | Self::DisposeUnbootedBranch { .. }
                | Self::ResolveUnbootedBranchDisposal { .. }
                | Self::ReleaseUnbootedBranchBacking { .. }
                | Self::ReleasePartialBranchBacking { .. }
                | Self::RetirePreparedBranch { .. }
                | Self::ReleaseHeldBranch { .. }
                | Self::QualifyHeldBranchRelease { .. }
                | Self::QualifyUnbootedBranchChildAbsence { .. }
                | Self::QualifyPartialBranchChildAbsence { .. }
                | Self::QualifyBranchChildAbsence { .. }
                | Self::ReleaseBranchBacking { .. }
                | Self::ContinueReleasedBranchDeletion { .. }
                | Self::DisposePartialBranch { .. }
                | Self::ResolvePartialBranchDisposal { .. }
                | Self::CleanupPartialBranchDisposal { .. }
                | Self::ResolvePartialBranchCleanup { .. }
                | Self::QualifyPartialBranchCleanup { .. }
                | Self::CollectPartialBranch { .. }
                | Self::InspectPartialBranchCollection { .. }
                | Self::CollectBranchDeletion { .. }
                | Self::CleanupReleasedBranchDeletion { .. }
                | Self::ResolveReleasedBranchDeletion { .. }
                | Self::ResolveHeldBranchDeletion { .. }
                | Self::ContinueHeldBranchDeletion { .. }
                | Self::CleanupHeldBranchDeletion { .. }
                | Self::CreateBranch { .. }
                | Self::InspectBranchCompletion { .. }
                | Self::ResolveReadyBranchCompletion { .. }
        )
    }
    pub fn command_limit(&self) -> Option<u64> {
        match self {
            Self::Exec { command, .. } => Some(command.max_output_bytes),
            Self::ExecBuffered { command, .. } => Some(command.max_output_bytes),
            Self::ExecStream { command, .. } => Some(command.max_output_bytes),
            _ => None,
        }
    }
    pub fn creation_mounts(&self) -> Option<&[crate::VolumeMount]> {
        match self {
            Self::Create { create } | Self::InspectCreation { create } => {
                create.volume_mounts.as_deref()
            }
            Self::CreateOci { create } | Self::InspectOciCreation { create } => {
                create.volume_mounts.as_deref()
            }
            Self::CreateRegistryPrepared { create, .. }
            | Self::InspectRegistryCreation { create } => create.volume_mounts.as_deref(),
            _ => None,
        }
    }
    pub fn creation_features(&self) -> Option<&CreationFeatures> {
        match self {
            Self::QualifyRegistryCreation { features, .. } => features.as_deref(),
            Self::CreateRegistryPrepared { create, .. }
            | Self::InspectRegistryCreation { create } => create.features.as_deref(),
            Self::CreateOci { create } | Self::InspectOciCreation { create } => {
                create.features.as_deref()
            }
            Self::QualifyOciCreation { features, .. } => features.as_deref(),
            Self::Create { create } | Self::InspectCreation { create } => {
                create.features.as_deref()
            }
            Self::QualifyCreation { features, .. } => features.as_deref(),
            _ => None,
        }
    }
    pub fn capability(&self) -> Capability {
        match self {
            Self::QualifyUnbootedBranchChildAbsence { .. }
            | Self::QualifyPartialBranchChildAbsence { .. } => Capability::Inspect,
            Self::InspectUnbootedBranchDisposal { .. }
            | Self::InspectPartialBranchCollection { .. } => Capability::Inspect,
            Self::DisposeUnbootedBranch { .. } => Capability::Delete,
            Self::ResolveUnbootedBranchDisposal { .. }
            | Self::ReleaseUnbootedBranchBacking { .. }
            | Self::ReleasePartialBranchBacking { .. } => Capability::Inspect,
            Self::RetirePreparedBranch { .. }
            | Self::QualifyBranchChildAbsence { .. }
            | Self::ReleaseBranchBacking { .. }
            | Self::ResolveReleasedBranchDeletion { .. }
            | Self::ResolveHeldBranchDeletion { .. } => Capability::Inspect,
            Self::DisposePartialBranch { .. } | Self::CleanupPartialBranchDisposal { .. } => {
                Capability::Delete
            }
            Self::ResolvePartialBranchDisposal { .. }
            | Self::QualifyPartialBranchCleanup { .. }
            | Self::ResolvePartialBranchCleanup { .. } => Capability::Inspect,
            Self::CollectPartialBranch { .. }
            | Self::CollectBranchDeletion { .. }
            | Self::CleanupReleasedBranchDeletion { .. }
            | Self::ContinueReleasedBranchDeletion { .. }
            | Self::ContinueHeldBranchDeletion { .. }
            | Self::CleanupHeldBranchDeletion { .. } => Capability::Delete,
            Self::ReleaseHeldBranch { .. } => Capability::Exec,
            Self::QualifyHeldBranchRelease { .. } => Capability::Inspect,
            Self::CreateBranch { .. } | Self::PublishCollectedBranchMaterial { .. } => {
                Capability::Create
            }
            Self::InspectBranchCompletion { .. } | Self::ResolveReadyBranchCompletion { .. } => {
                Capability::Inspect
            }
            Self::BranchPreflight { .. } => Capability::Inspect,
            Self::QualifyExport { .. }
            | Self::AdmitExport { .. }
            | Self::InspectExport { .. }
            | Self::CleanupExportStaging { .. } => Capability::Inspect,
            Self::ExportMachine { .. } => Capability::ReadFile,
            Self::InspectCapture { .. }
            | Self::InspectCaptureResolution { .. }
            | Self::ResolveCapture { .. }
            | Self::QualifyAbortedCaptureSource { .. }
            | Self::AbortCaptureStaging { .. }
            | Self::CleanupCaptureStaging { .. } => Capability::Inspect,
            Self::CaptureCheckpoint { .. } => Capability::ReadFile,
            Self::StartCheckpointable { .. } => Capability::Start,
            Self::CheckpointPreflight { .. } => Capability::Inspect,
            Self::QualifyCheckpointCreation { .. } => Capability::QualifyCreation,
            Self::CreateCheckpoint { .. } => Capability::Create,
            Self::InspectCheckpointCreation { .. } => Capability::InspectCreation,
            Self::Volume { .. } => Capability::Volumes,
            Self::QualifyRegistryCreation { .. } => Capability::QualifyCreation,
            Self::CreateRegistryPrepared { .. } => Capability::Create,
            Self::InspectRegistryCreation { .. } => Capability::InspectCreation,
            Self::PrepareArtifact { .. } => Capability::PrepareArtifact,
            Self::StartOci { .. } => Capability::Start,
            Self::CreateOci { .. } => Capability::Create,
            Self::InspectOciCreation { .. } => Capability::InspectCreation,
            Self::QualifyOciCreation { .. } => Capability::QualifyCreation,
            Self::PullImage { .. } => Capability::PullImage,
            Self::ListImages { .. } => Capability::ListImages,
            Self::ExpandDisks { .. } => Capability::ExpandDisks,
            Self::InspectGrowth { .. } => Capability::InspectGrowth,
            Self::QualifyGrowth { .. } => Capability::QualifyGrowth,
            Self::TerminalOpen { .. } => Capability::TerminalOpen,
            Self::TerminalPreflight { .. } => Capability::TerminalPreflight,
            Self::Logs { .. } => Capability::Logs,
            Self::Health => Capability::Health,
            Self::Capacity => Capability::Capacity,
            Self::Metrics => Capability::Metrics,
            Self::Readiness => Capability::Readiness,
            Self::List => Capability::List,
            Self::Measurements { .. } => Capability::Measurements,
            Self::QualifyCreation { .. } => Capability::QualifyCreation,
            Self::Create { .. } => Capability::Create,
            Self::InspectCreation { .. } => Capability::InspectCreation,
            Self::Inspect { .. } => Capability::Inspect,
            Self::Start { .. } => Capability::Start,
            Self::Stop { .. } => Capability::Stop,
            Self::Delete { .. } => Capability::Delete,
            Self::Exec { .. } => Capability::Exec,
            Self::ExecBuffered { .. } => Capability::ExecBuffered,
            Self::ExecStream { .. } => Capability::ExecStream,
            Self::ExecBackground { .. } => Capability::ExecBackground,
            Self::ReadFile { .. } => Capability::ReadFile,
            Self::WriteFile { .. } => Capability::WriteFile,
        }
    }
    pub fn receipt(&self) -> Option<&Receipt> {
        match self {
            Self::InspectUnbootedBranchDisposal { request, .. } => Some(&request.source),
            Self::DisposeUnbootedBranch { request }
            | Self::ResolveUnbootedBranchDisposal { request } => Some(&request.creation.source),
            Self::ReleaseUnbootedBranchBacking { request } => Some(&request.child),
            Self::ReleasePartialBranchBacking { request } => Some(&request.child),
            Self::RetirePreparedBranch { request } => Some(&request.creation.source),
            Self::QualifyUnbootedBranchChildAbsence { request } => {
                Some(&request.disposal.creation.source)
            }
            Self::QualifyPartialBranchChildAbsence { request } => {
                Some(&request.disposal.request.collection_request.creation.source)
            }
            Self::QualifyBranchChildAbsence { request } => Some(&request.child),
            Self::ReleaseBranchBacking { request } => Some(&request.child),
            Self::ContinueReleasedBranchDeletion { request } => Some(&request.child),
            Self::DisposePartialBranch { request }
            | Self::ResolvePartialBranchDisposal { request } => {
                Some(&request.collection_request.creation.source)
            }
            Self::QualifyPartialBranchCleanup { request } => {
                Some(&request.collection_request.creation.source)
            }
            Self::CleanupPartialBranchDisposal { request }
            | Self::ResolvePartialBranchCleanup { request } => {
                Some(&request.disposal_request.collection_request.creation.source)
            }
            Self::CollectPartialBranch { request }
            | Self::InspectPartialBranchCollection { request } => Some(&request.creation.source),
            Self::CollectBranchDeletion { request } => Some(&request.child),
            Self::CleanupReleasedBranchDeletion { request } => Some(&request.child),
            Self::ResolveReleasedBranchDeletion { request } => Some(&request.child),
            Self::ResolveHeldBranchDeletion { request } => Some(&request.child),
            Self::ContinueHeldBranchDeletion { request }
            | Self::CleanupHeldBranchDeletion { request } => Some(&request.child),
            Self::ReleaseHeldBranch { request } | Self::QualifyHeldBranchRelease { request } => {
                Some(&request.source)
            }
            Self::CreateBranch { request }
            | Self::InspectBranchCompletion { request }
            | Self::PublishCollectedBranchMaterial { request, .. }
            | Self::ResolveReadyBranchCompletion { request, .. } => Some(&request.source),
            Self::QualifyCheckpointCreation { .. }
            | Self::CreateCheckpoint { .. }
            | Self::InspectCheckpointCreation { .. } => None,
            Self::Volume { .. } => None,
            Self::QualifyRegistryCreation { .. } => None,
            Self::CreateRegistryPrepared { .. } | Self::InspectRegistryCreation { .. } => None,
            Self::PrepareArtifact { .. } => None,
            Self::CreateOci { .. }
            | Self::InspectOciCreation { .. }
            | Self::QualifyOciCreation { .. } => None,
            Self::Health | Self::Capacity | Self::Metrics | Self::Readiness | Self::List => None,
            Self::Create { .. } | Self::InspectCreation { .. } | Self::QualifyCreation { .. } => {
                None
            }
            Self::BranchPreflight { receipt }
            | Self::QualifyExport { receipt, .. }
            | Self::AdmitExport { receipt, .. }
            | Self::ExportMachine { receipt, .. }
            | Self::InspectExport { receipt, .. }
            | Self::CleanupExportStaging { receipt, .. }
            | Self::StartOci { receipt, .. }
            | Self::InspectCapture { receipt, .. }
            | Self::InspectCaptureResolution { receipt, .. }
            | Self::ResolveCapture { receipt, .. }
            | Self::QualifyAbortedCaptureSource { receipt, .. }
            | Self::AbortCaptureStaging { receipt, .. }
            | Self::CleanupCaptureStaging { receipt, .. }
            | Self::CaptureCheckpoint { receipt, .. }
            | Self::StartCheckpointable { receipt }
            | Self::CheckpointPreflight { receipt }
            | Self::PullImage { receipt, .. }
            | Self::ListImages { receipt }
            | Self::ExpandDisks { receipt, .. }
            | Self::InspectGrowth { receipt, .. }
            | Self::QualifyGrowth { receipt, .. }
            | Self::Inspect { receipt }
            | Self::Logs { receipt, .. }
            | Self::Measurements { receipt }
            | Self::Start { receipt }
            | Self::Stop { receipt }
            | Self::Delete { receipt }
            | Self::Exec { receipt, .. }
            | Self::ExecBuffered { receipt, .. }
            | Self::ExecStream { receipt, .. }
            | Self::TerminalOpen { receipt, .. }
            | Self::TerminalPreflight { receipt }
            | Self::ExecBackground { receipt, .. }
            | Self::ReadFile { receipt, .. }
            | Self::WriteFile { receipt, .. } => Some(receipt),
        }
    }
    pub fn validate(&self, budget_ms: u64) -> Result<()> {
        require(budget_ms > 0 && budget_ms <= 86_400_000)?;
        checkpointable_mode(
            self.checkpointable(),
            self.creation_features(),
            self.creation_mounts(),
        )?;
        if let Some(receipt) = self.receipt() {
            receipt.validate()?;
        }
        if let Some(mounts) = self.creation_mounts() {
            crate::VolumeMount::validate_set(mounts)?;
        }
        if let Some(features) = self.creation_features() {
            features.validate()?;
        }
        match self {
            Self::InspectUnbootedBranchDisposal { request, quiesced } => {
                request.validate()?;
                require(
                    *quiesced
                        && budget_ms <= 30000
                        && serde_json::to_vec(request)
                            .map_err(|_| InvalidMessage)?
                            .len()
                            <= 16 * 1024,
                )?;
            }
            Self::DisposeUnbootedBranch { request }
            | Self::ResolveUnbootedBranchDisposal { request } => {
                request.validate()?;
                require(budget_ms <= 30000)?;
            }
            Self::ReleaseUnbootedBranchBacking { request } => {
                request.validate()?;
                require(budget_ms <= 30000)?;
            }
            Self::ReleasePartialBranchBacking { request } => {
                request.validate()?;
                require(budget_ms <= 30000)?;
            }
            Self::RetirePreparedBranch { request } => {
                request.validate()?;
                require(budget_ms <= 30000)?;
            }

            Self::ContinueHeldBranchDeletion { request }
            | Self::CleanupHeldBranchDeletion { request } => {
                request.require_action(
                    if matches!(self, Self::ContinueHeldBranchDeletion { .. }) {
                        crate::HeldBranchDeletionAction::Continue
                    } else {
                        crate::HeldBranchDeletionAction::Cleanup
                    },
                )?;
                require(budget_ms <= 30000)?;
            }
            Self::ContinueReleasedBranchDeletion { request } => {
                request.validate()?;
                require(budget_ms <= 30000)?;
            }
            Self::CleanupReleasedBranchDeletion { request } => {
                request.validate()?;
                require(budget_ms <= 30000)?;
            }
            Self::DisposePartialBranch { request }
            | Self::ResolvePartialBranchDisposal { request } => {
                request.validate()?;
                require(budget_ms <= 30000)?;
            }
            Self::QualifyPartialBranchCleanup { request } => {
                request.validate()?;
                require(budget_ms <= 30000)?;
            }
            Self::CleanupPartialBranchDisposal { request }
            | Self::ResolvePartialBranchCleanup { request } => {
                request.validate()?;
                require(budget_ms <= 30000)?;
            }
            Self::CollectPartialBranch { request }
            | Self::InspectPartialBranchCollection { request } => {
                request.validate()?;
                require(budget_ms <= 30000)?;
            }
            Self::CollectBranchDeletion { request } => {
                request.validate()?;
                require(budget_ms <= 30000)?;
            }
            Self::ResolveReleasedBranchDeletion { request } => {
                request.validate()?;
                require(budget_ms <= 30000)?;
            }
            Self::ResolveHeldBranchDeletion { request } => {
                request.validate()?;
                require(budget_ms <= 30000)?;
            }
            Self::ReleaseBranchBacking { request } => {
                request.validate()?;
                require(budget_ms <= 30000)?;
            }
            Self::QualifyUnbootedBranchChildAbsence { request } => {
                request.validate()?;
                require(budget_ms <= 30000)?;
            }
            Self::QualifyPartialBranchChildAbsence { request } => {
                request.validate()?;
                require(budget_ms <= 30000)?;
            }
            Self::QualifyBranchChildAbsence { request } => {
                request.validate()?;
                require(budget_ms <= 30000)?;
            }
            Self::ReleaseHeldBranch { request } | Self::QualifyHeldBranchRelease { request } => {
                request.validate()?;
                require(
                    budget_ms
                        <= if matches!(self, Self::ReleaseHeldBranch { .. }) {
                            900000
                        } else {
                            30000
                        },
                )?;
            }
            Self::ResolveReadyBranchCompletion { request, quiesced }
            | Self::PublishCollectedBranchMaterial { request, quiesced } => {
                request.validate()?;
                require(*quiesced && budget_ms <= 30000)?;
                require(
                    serde_json::to_vec(request)
                        .map_err(|_| InvalidMessage)?
                        .len()
                        <= 16 * 1024,
                )?;
            }
            Self::CreateBranch { request } | Self::InspectBranchCompletion { request } => {
                request.validate()?;
                require(
                    budget_ms
                        <= if matches!(self, Self::CreateBranch { .. }) {
                            900000
                        } else {
                            30000
                        },
                )?;
            }
            Self::BranchPreflight { receipt } => {
                receipt.validate_for(2)?;
                require(receipt.material.is_some() && budget_ms <= 30000)?;
            }
            Self::QualifyExport { receipt, request } => {
                receipt.validate_for(2)?;
                require(receipt.material.is_some() && budget_ms <= 30000)?;
                request.validate()?;
            }
            Self::AdmitExport {
                receipt,
                operation_id,
                request,
            } => {
                receipt.validate_for(2)?;
                require(receipt.material.is_some() && budget_ms <= 30000)?;
                id(operation_id)?;
                request.validate()?;
            }
            Self::ExportMachine {
                receipt,
                operation_id,
                request,
                push_token,
            } => {
                receipt.validate_for(2)?;
                require(receipt.material.is_some())?;
                id(operation_id)?;
                request.validate()?;
                push_token.validate()?;
            }
            Self::InspectExport {
                receipt,
                operation_id,
                request_sha256,
            }
            | Self::CleanupExportStaging {
                receipt,
                operation_id,
                request_sha256,
                ..
            } => {
                receipt.validate_for(2)?;
                require(receipt.material.is_some() && budget_ms <= 30000)?;
                id(operation_id)?;
                hex(request_sha256, 64)?;
                if let Self::CleanupExportStaging { quiesced, .. } = self {
                    require(*quiesced)?;
                }
            }
            Self::StartCheckpointable { receipt } => receipt.validate_for(2)?,
            Self::CheckpointPreflight { receipt } => {
                receipt.validate_for(2)?;
                require(budget_ms <= 30000)?;
            }
            Self::InspectCapture {
                receipt,
                operation_id,
                request,
            }
            | Self::InspectCaptureResolution {
                receipt,
                operation_id,
                request,
            } => {
                receipt.validate_for(2)?;
                id(operation_id)?;
                request.validate()?;
                require(budget_ms <= 30000)?;
            }
            Self::ResolveCapture {
                receipt,
                operation_id,
                request,
                quiesced,
            }
            | Self::QualifyAbortedCaptureSource {
                receipt,
                operation_id,
                request,
                quiesced,
            }
            | Self::AbortCaptureStaging {
                receipt,
                operation_id,
                request,
                quiesced,
            }
            | Self::CleanupCaptureStaging {
                receipt,
                operation_id,
                request,
                quiesced,
            } => {
                receipt.validate_for(2)?;
                id(operation_id)?;
                request.validate()?;
                require(*quiesced && budget_ms <= 30000)?;
            }
            Self::CaptureCheckpoint {
                receipt,
                operation_id,
                request,
                chunk_bytes,
            } => {
                receipt.validate_for(2)?;
                id(operation_id)?;
                request.validate()?;
                require(
                    chunk_bytes.is_none_or(|limit| limit > 0 && limit <= MAX_CHUNK_BYTES as u64),
                )?;
            }
            Self::QualifyCheckpointCreation {
                source, resources, ..
            } => {
                source.validate()?;
                resources.validate()?;
            }
            Self::CreateCheckpoint { create } => create.validate()?,
            Self::InspectCheckpointCreation { create } => {
                create.validate()?;
                require(budget_ms <= 30000)?;
            }
            Self::Volume { request } => request.validate(budget_ms)?,
            Self::QualifyRegistryCreation {
                source,
                resources,
                user,
                ..
            } => {
                source.validate()?;
                resources.validate()?;
                require(budget_ms <= 30000)?;
                if let Some(user) = user {
                    text(user, 16384, false)?;
                }
            }
            Self::CreateRegistryPrepared { create, size_bytes } => {
                create.validate()?;
                require(*size_bytes > 0 && *size_bytes <= 32 * 1024 * 1024 * 1024)?;
            }
            Self::InspectRegistryCreation { create } => {
                create.validate()?;
                require(budget_ms <= 30000)?;
            }
            Self::PrepareArtifact {
                source,
                credential_ref,
                identity_token,
            } => {
                source.validate()?;
                require(credential_ref.is_some() == identity_token.is_some())?;
                if let Some(reference) = credential_ref {
                    id(reference)?;
                }
                if let Some(token) = identity_token {
                    token.validate()?;
                }
            }
            Self::StartOci { receipt, source } => {
                receipt.validate_for(2)?;
                source.validate()?;
            }
            Self::CreateOci { create } | Self::InspectOciCreation { create } => {
                create.validate()?;
                if matches!(self, Self::InspectOciCreation { .. }) {
                    require(budget_ms <= 30_000)?;
                }
            }
            Self::QualifyOciCreation {
                source,
                resources,
                user,
                ..
            } => {
                require(budget_ms <= 30_000)?;
                source.validate()?;
                resources.validate()?;
                if let Some(user) = user {
                    text(user, 16384, false)?;
                }
            }
            Self::ExpandDisks {
                receipt,
                operation_id,
                request,
                previous,
            }
            | Self::InspectGrowth {
                receipt,
                operation_id,
                request,
                previous,
            }
            | Self::QualifyGrowth {
                receipt,
                operation_id,
                request,
                previous,
                ..
            } => {
                receipt.validate_for(2)?;
                id(operation_id)?;
                request.targets(*previous)?;
                require(
                    budget_ms
                        <= if matches!(
                            self,
                            Self::InspectGrowth { .. } | Self::QualifyGrowth { .. }
                        ) {
                            30000
                        } else {
                            600000
                        },
                )?;
                if let Self::QualifyGrowth { quiesced, .. } = self {
                    require(*quiesced)?;
                }
            }
            Self::PullImage { receipt, source } => {
                receipt.validate_for(2)?;
                source.validate()?;
                require(budget_ms <= 86400000)?;
            }
            Self::ListImages { receipt } => {
                receipt.validate_for(2)?;
                require(budget_ms <= 30000)?;
            }
            Self::TerminalPreflight { receipt } => {
                receipt.validate_for(2)?;
                require(budget_ms <= 30_000)?;
            }
            Self::TerminalOpen { terminal, .. } => {
                terminal.validate()?;
                require(budget_ms <= terminal.session_ms)?;
            }
            Self::Logs {
                tail, max_bytes, ..
            } => require(
                *tail <= 10000 && *max_bytes > 0 && *max_bytes <= 8388608 && budget_ms <= 300000,
            )?,
            Self::Health
            | Self::Capacity
            | Self::Metrics
            | Self::List
            | Self::Measurements { .. } => require(budget_ms <= 30_000)?,
            Self::Readiness => require(budget_ms <= 2000)?,
            Self::QualifyCreation {
                artifact,
                resources,
                user,
                ..
            } => {
                require(budget_ms <= 30_000)?;
                artifact.validate()?;
                resources.validate()?;
                if let Some(user) = user {
                    text(user, 16384, false)?;
                }
            }
            Self::Create { create } | Self::InspectCreation { create } => {
                if matches!(self, Self::InspectCreation { .. }) {
                    require(budget_ms <= 30_000)?;
                }
                id(&create.name)?;
                hex(&create.owner_token, 64)?;
                hex(&create.incarnation, 32)?;
                create.resources.validate()?;
                create.artifact.validate()?;
                require(create.labels.len() <= 64)?;
                for (key, value) in &create.labels {
                    text(key, 128, false)?;
                    text(value, 1024, true)?;
                    require(!key.starts_with("smolbox."))?;
                }
            }
            Self::ExecBuffered { command, .. } => command.validate()?,
            Self::ExecStream { command, .. } => {
                command.validate()?;
                require(command.stdin.is_none())?;
            }
            Self::ExecBackground { command, .. } => {
                command.validate()?;
                require(command.stdin.is_none())?;
            }
            Self::Exec { command, .. } => {
                require(
                    !command.argv.is_empty()
                        && command.argv.len() <= 256
                        && command.env.len() <= 256,
                )?;
                let mut total = 0;
                for (index, arg) in command.argv.iter().enumerate() {
                    text(arg, 16384, index != 0)?;
                    total += arg.len();
                }
                for (key, value) in &command.env {
                    text(key, 16384, false)?;
                    text(value, 16384, true)?;
                    require(!key.contains('='))?;
                    total += key.len() + value.len();
                }
                require(total <= 128 * 1024)?;
                if let Some(workdir) = &command.workdir {
                    absolute_path(workdir)?;
                }
                if let Some(user) = &command.user {
                    text(user, 16384, false)?;
                }
                require(
                    command.max_output_bytes > 0 && command.max_output_bytes <= MAX_TRANSFER_BYTES,
                )?;
            }
            Self::ReadFile { options, .. } | Self::WriteFile { options, .. } => {
                require(budget_ms <= 600_000)?;
                absolute_path(&options.guest_path)?;
                require(
                    options.guest_path != "/"
                        && !options.guest_path.ends_with('/')
                        && options.max_bytes > 0
                        && options.max_bytes <= MAX_TRANSFER_BYTES
                        && options.mode.is_none_or(|mode| mode <= 0o777),
                )?;
                if matches!(self, Self::ReadFile { .. }) {
                    require(options.mode.is_none())?;
                }
                if let Self::WriteFile { total_bytes, .. } = self {
                    require(*total_bytes <= options.max_bytes)?;
                }
            }
            _ => {}
        }
        Ok(())
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum ClientMessage {
    TerminalControl {
        epoch: String,
        id: u64,
        sequence: u64,
        control: crate::TerminalAction,
    },
    Approve {
        hello: Hello,
    },
    Request {
        epoch: String,
        id: u64,
        budget_ms: u64,
        initial_credit: u64,
        initial_event_credit: u64,
        operation: Operation,
    },
    Cancel {
        epoch: String,
        id: u64,
    },
    Credit {
        epoch: String,
        id: u64,
        decoded_bytes: u64,
        events: u64,
    },
    Upload {
        epoch: String,
        id: u64,
        offset: u64,
        data_base64: String,
    },
    Shutdown {
        epoch: String,
    },
}
impl ClientMessage {
    pub fn decode(mut value: Value) -> Result<Self> {
        crate::validate_json(&value, 0).map_err(|_| InvalidMessage)?;
        crate::command_payload::expand(&mut value)?;
        let compact = crate::creation_payload::expand(&mut value)?;
        let mut message: Self = serde_json::from_value(value).map_err(|_| InvalidMessage)?;
        if compact {
            let Self::Request { operation, .. } = &mut message else {
                return Err(InvalidMessage);
            };
            match operation {
                Operation::CreateOci { create } | Operation::InspectOciCreation { create } => {
                    create.features.as_mut().ok_or(InvalidMessage)?.compact = true
                }
                Operation::CreateRegistryPrepared { create, .. }
                | Operation::InspectRegistryCreation { create } => {
                    create.features.as_mut().ok_or(InvalidMessage)?.compact = true
                }
                Operation::QualifyOciCreation { features, .. } => {
                    features.as_mut().ok_or(InvalidMessage)?.compact = true
                }
                Operation::QualifyRegistryCreation { features, .. } => {
                    features.as_mut().ok_or(InvalidMessage)?.compact = true
                }
                Operation::Create { create } | Operation::InspectCreation { create } => {
                    create.features.as_mut().ok_or(InvalidMessage)?.compact = true
                }
                Operation::QualifyCreation { features, .. } => {
                    features.as_mut().ok_or(InvalidMessage)?.compact = true
                }
                _ => return Err(InvalidMessage),
            }
        }
        message.validate()?;
        Ok(message)
    }
    pub fn validate(&self) -> Result<()> {
        match self {
            Self::TerminalControl {
                epoch,
                id,
                sequence,
                control,
            } => {
                correlation(epoch, *id)?;
                require(*sequence > 0 && *sequence <= MAX_SAFE_INTEGER)?;
                control.validate()
            }
            Self::Approve { hello } => hello.validate(),
            Self::Request {
                epoch,
                id,
                budget_ms,
                initial_credit,
                initial_event_credit,
                operation,
            } => {
                correlation(epoch, *id)?;
                require(*initial_credit <= INITIAL_CREDIT_BYTES)?;
                require(*initial_event_credit <= INITIAL_CREDIT_EVENTS)?;
                operation.validate(*budget_ms)
            }
            Self::Cancel { epoch, id } => correlation(epoch, *id),
            Self::Credit {
                epoch,
                id,
                decoded_bytes,
                events,
            } => {
                correlation(epoch, *id)?;
                require(*decoded_bytes > 0 && *decoded_bytes <= INITIAL_CREDIT_BYTES)?;
                require(*events <= INITIAL_CREDIT_EVENTS)
            }
            Self::Upload {
                epoch,
                id,
                offset,
                data_base64,
            } => {
                correlation(epoch, *id)?;
                require(*offset <= MAX_TRANSFER_BYTES)?;
                require(!decode_chunk(data_base64)?.is_empty())
            }
            Self::Shutdown { epoch } => hex(epoch, 32),
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Dispatch {
    NotDispatched,
    MayHaveDispatched,
}
#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Completion {
    Exited,
    Completed,
    Cancelled,
    Deadline,
    OutputLimit,
    ConsumerLost,
    NativeError,
    Unknown,
}
#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ObservedState {
    Missing,
    Stopped,
    Running,
    Paused,
    Pausing,
    Frozen,
    Failed,
    Unreachable,
    IdentityUnknown,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Observation {
    pub state: ObservedState,
    pub resources: Option<Resources>,
    pub pid_identity: Option<(i32, u64)>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "present_optional"
    )]
    pub configuration: Option<Box<MachineConfiguration>>,
}
#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CreationPresence {
    Absent,
    Unverified,
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HealthSnapshot {
    pub total: u64,
    pub running: u64,
    pub uptime_seconds: u64,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CapacitySnapshot {
    pub allocated_cpus: u64,
    pub allocated_memory_mb: u64,
    pub used_cpu_millis: u64,
    pub used_memory_mb: u64,
    pub used_memory_pss_mb: Option<u64>,
    pub used_memory_private_mb: Option<u64>,
    pub used_memory_shared_mapped_mb: Option<u64>,
    pub host_memory_total_mb: Option<u64>,
    pub host_memory_available_mb: Option<u64>,
    pub used_disk_gb: u64,
    pub boot_id: Option<String>,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MachineCounters {
    pub cpu_seconds: Option<u64>,
    pub cpu_millis: Option<u64>,
    pub rss_mb: Option<u64>,
    pub pss_mb: Option<u64>,
    pub private_memory_mb: Option<u64>,
    pub shared_memory_mapped_mb: Option<u64>,
    pub disk_used_mb: Option<u64>,
    pub egress_bytes: Option<u64>,
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "result", rename_all = "snake_case", deny_unknown_fields)]
pub enum Outcome {
    CollectedBranchMaterialPublished {
        publication: Box<crate::BranchPublication>,
    },
    UnbootedBranchDisposalCandidate {
        candidate: Box<crate::UnbootedBranchDisposalCandidate>,
    },
    UnbootedBranchDisposed {
        proof: Box<crate::UnbootedBranchDisposal>,
    },
    PreparedBranchRetired {
        proof: Box<crate::PreparedBranchRetirement>,
    },
    HeldBranchDeletionContinued {
        proof: Box<crate::BranchDeletionContinuation>,
    },
    HeldBranchDeletionCleaned {
        proof: Box<crate::BranchDeletionResolution>,
    },
    ReleasedBranchDeletionContinued {
        proof: Box<crate::ReleasedBranchDeletionContinuation>,
    },
    PartialBranchDisposed {
        proof: Box<crate::PartialBranchDisposal>,
    },
    PartialBranchCleanupCandidate {
        candidate: Box<crate::PartialBranchCleanupCandidate>,
    },
    PartialBranchDisposalCleaned {
        proof: Box<crate::PartialBranchDisposalCleanup>,
    },
    PartialBranchCleanupUnneeded {
        proof: Box<crate::PartialBranchDisposalCleanupUnneeded>,
    },
    PartialBranchCollectionCandidate {
        candidate: Box<crate::PartialBranchCollectionCandidate>,
    },
    PartialBranchCollected {
        proof: Box<crate::PartialBranchCollection>,
        platform: String,
    },
    BranchDeletionCollected {
        proof: Box<crate::BranchDeletionCollection>,
    },
    ReleasedBranchDeletionCleaned {
        proof: Box<crate::ReleasedBranchDeletionResolution>,
    },
    ReleasedBranchDeletionResolved {
        proof: Box<crate::ReleasedBranchDeletionResolution>,
    },
    HeldBranchDeletionResolved {
        proof: Box<crate::BranchDeletionResolution>,
    },
    BranchBackingReleased {
        proof: Box<crate::BranchBackingRelease>,
    },
    UnbootedBranchChildAbsent {
        proof: Box<crate::UnbootedBranchChildAbsence>,
    },
    PartialBranchChildAbsent {
        proof: Box<crate::PartialBranchChildAbsence>,
    },
    BranchChildAbsent {
        proof: Box<crate::BranchChildAbsence>,
    },
    HeldBranchReleased {
        transition: Box<crate::BranchReleaseTransition>,
    },
    HeldBranchReleasePresence {
        #[serde(deserialize_with = "required_nullable")]
        transition: Option<Box<crate::BranchReleaseTransition>>,
    },
    BranchCreated {
        completion: Box<crate::BranchCompletion>,
    },
    BranchCompletionPresence {
        #[serde(deserialize_with = "required_nullable")]
        completion: Option<Box<crate::BranchCompletion>>,
    },
    Exported {
        publication: Box<crate::ExportPublication>,
    },
    ExportPresence {
        #[serde(deserialize_with = "required_nullable")]
        publication: Option<Box<crate::ExportPublication>>,
    },
    ExportStagingCleaned {
        cleanup: Box<crate::ExportStageCleanup>,
    },
    AbortedCaptureSourceQualified {
        qualification: Box<crate::CaptureAbortSourceQualification>,
    },
    CaptureStagingAborted {
        cleanup: Box<crate::CaptureStagingCleanupReceipt>,
    },
    CaptureStagingCleaned {
        cleanup: Box<crate::CaptureStagingCleanupReceipt>,
    },
    CaptureResolved {
        transition: Box<crate::CaptureResolutionTransition>,
    },
    CaptureResolutionPresence {
        #[serde(deserialize_with = "required_nullable")]
        transition: Option<Box<crate::CaptureResolutionTransition>>,
    },
    Captured {
        transition: Box<crate::CaptureTransition>,
    },
    CapturePresence {
        #[serde(deserialize_with = "required_nullable")]
        transition: Option<Box<crate::CaptureTransition>>,
    },
    Volume {
        volume: crate::VolumeResult,
    },
    PreparedArtifact {
        source: RegistrySource,
        size_bytes: u64,
        already_cached: bool,
    },
    Pulled {
        image: ImageObservation,
    },
    Images {
        count: u64,
        bytes: u64,
    },
    Grown {
        transition: Box<crate::GrowthTransition>,
        observation: Observation,
    },
    GrowthQualified {
        transition: Box<crate::GrowthTransition>,
        observation: Observation,
    },
    GrowthPresence {
        #[serde(deserialize_with = "required_nullable")]
        transition: Option<Box<crate::GrowthTransition>>,
    },
    Terminal {
        completion: Completion,
        dispatch: Dispatch,
        observed_exit: Option<i32>,
        worker_collected: bool,
        output_bytes: u64,
    },
    Logs {
        completion: Completion,
        lines: u64,
        bytes: u64,
        wire_bytes: u64,
    },
    Launched {
        pid: u32,
    },
    Health {
        snapshot: HealthSnapshot,
    },
    Capacity {
        snapshot: Box<CapacitySnapshot>,
    },
    Metrics {
        text: String,
    },
    Ready,
    Inventory {
        count: u64,
        bytes: u64,
    },
    Measurements {
        observation: Observation,
        counters: Box<MachineCounters>,
    },
    Qualified,
    CreationPresence {
        presence: CreationPresence,
    },
    Created {
        receipt: Receipt,
    },
    Observed {
        observation: Observation,
    },
    Command {
        completion: Completion,
        dispatch: Dispatch,
        observed_exit: Option<i32>,
        running_observed: bool,
        output_bytes: u64,
    },
    File {
        completion: Completion,
        dispatch: Dispatch,
        observed_bytes: u64,
        native_acknowledged: bool,
    },
    Error {
        code: SafeCode,
        dispatch: Dispatch,
    },
}
impl Outcome {
    pub fn validate(&self) -> Result<()> {
        match self {
            Self::CollectedBranchMaterialPublished { publication } => {
                publication.validate()?;
                require(
                    serde_json::to_vec(publication)
                        .map_err(|_| InvalidMessage)?
                        .len()
                        <= 64 * 1024,
                )
            }
            Self::UnbootedBranchDisposalCandidate { candidate } => candidate.validate(),
            Self::UnbootedBranchDisposed { proof } => proof.validate(),
            Self::PreparedBranchRetired { proof } => proof.validate(),
            Self::UnbootedBranchChildAbsent { proof } => proof.validate(),
            Self::PartialBranchChildAbsent { proof } => proof.validate(),
            Self::BranchChildAbsent { proof } => proof.validate(),
            Self::BranchBackingReleased { proof } => proof.validate(),
            Self::ReleasedBranchDeletionContinued { proof } => proof.validate(),
            Self::PartialBranchDisposed { proof } => proof.validate(),
            Self::PartialBranchCleanupCandidate { candidate } => candidate.validate(),
            Self::PartialBranchDisposalCleaned { proof } => proof.validate(),
            Self::PartialBranchCleanupUnneeded { proof } => proof.validate(),
            Self::PartialBranchCollectionCandidate { candidate } => candidate.validate(),
            Self::PartialBranchCollected { proof, platform } => {
                require(matches!(platform.as_str(), "linux" | "macos"))?;
                proof.validate()
            }
            Self::BranchDeletionCollected { proof } => proof.validate(),
            Self::ReleasedBranchDeletionCleaned { proof } => proof.validate(),
            Self::ReleasedBranchDeletionResolved { proof } => proof.validate(),
            Self::HeldBranchDeletionResolved { proof }
            | Self::HeldBranchDeletionCleaned { proof } => proof.validate(),
            Self::HeldBranchDeletionContinued { proof } => proof.validate(),
            Self::HeldBranchReleased { transition } => {
                transition.validate()?;
                require(transition.change.mode == crate::BranchReleaseMode::Explicit)
            }
            Self::HeldBranchReleasePresence { transition } => {
                if let Some(proof) = transition {
                    proof.validate()?;
                    require(proof.change.mode == crate::BranchReleaseMode::Explicit)?;
                }
                Ok(())
            }
            Self::BranchCreated { completion } => completion.validate(),
            Self::BranchCompletionPresence { completion } => {
                if let Some(completion) = completion {
                    completion.validate()?;
                }
                Ok(())
            }
            Self::Exported { publication } => publication.validate(),
            Self::ExportPresence { publication } => {
                if let Some(publication) = publication {
                    publication.validate()?;
                }
                Ok(())
            }
            Self::ExportStagingCleaned { cleanup } => cleanup.validate(),
            Self::Volume { volume } => volume.validate(),
            Self::PreparedArtifact {
                source, size_bytes, ..
            } => {
                source.validate()?;
                require(*size_bytes > 0 && *size_bytes <= 32 * 1024 * 1024 * 1024)
            }
            Self::Pulled { image } => {
                image.validate()?;
                require(image.digest != "packed")
            }
            Self::Images { count, bytes } => {
                require(*count <= 1024 && (2..=8388608).contains(bytes))
            }
            Self::Grown {
                transition,
                observation,
            }
            | Self::GrowthQualified {
                transition,
                observation,
            } => {
                transition.validate()?;
                Self::Observed {
                    observation: observation.clone(),
                }
                .validate()?;
                require(
                    observation.state == ObservedState::Stopped
                        && observation.pid_identity.is_none(),
                )?;
                let resources = observation.resources.as_ref().ok_or(InvalidMessage)?;
                require(
                    resources.storage_gib == transition.change.storage_gib
                        && resources.overlay_gib == transition.change.overlay_gib,
                )
            }
            Self::GrowthPresence { transition } => {
                if let Some(transition) = transition {
                    transition.validate()?;
                }
                Ok(())
            }
            Self::CapturePresence { transition } => {
                if let Some(transition) = transition {
                    transition.validate()?;
                }
                Ok(())
            }
            Self::AbortedCaptureSourceQualified { qualification } => qualification.validate(),
            Self::Captured { transition } => transition.validate(),
            Self::CaptureResolved { transition } => transition.validate(),
            Self::CaptureStagingCleaned { cleanup } | Self::CaptureStagingAborted { cleanup } => {
                cleanup.validate()
            }
            Self::CaptureResolutionPresence { transition } => {
                if let Some(transition) = transition {
                    transition.validate()?;
                }
                Ok(())
            }
            Self::Terminal {
                completion,
                dispatch,
                observed_exit,
                worker_collected,
                output_bytes,
            } => {
                require(*completion != Completion::Completed && *output_bytes <= MAX_SAFE_INTEGER)?;
                require(
                    *completion != Completion::Exited
                        || (*worker_collected
                            && matches!(observed_exit, Some(0..=123 | 125..=129 | 131..=255))),
                )?;
                require(
                    *dispatch != Dispatch::NotDispatched
                        || (observed_exit.is_none() && *output_bytes == 0),
                )
            }
            Self::Logs {
                completion,
                lines,
                bytes,
                wire_bytes,
            } => {
                require(*lines <= 10000 && *bytes <= 8388608 && *wire_bytes <= 8418608)?;
                require(*bytes >= *lines && *wire_bytes >= *bytes + 3 * *lines)?;
                require(!matches!(
                    completion,
                    Completion::Exited | Completion::Unknown
                ))?;
                require(*completion != Completion::Completed || *wire_bytes == *bytes + 3 * *lines)
            }
            Self::Launched { pid } => require(*pid > 0),
            Self::Health { snapshot } => {
                require(snapshot.total <= 1_000_000 && snapshot.running <= snapshot.total)
            }
            Self::Capacity { snapshot } => {
                require(snapshot.used_cpu_millis <= 1_048_576_000)?;
                if let Some(boot) = &snapshot.boot_id {
                    text(boot, 256, false)?;
                }
                Ok(())
            }
            Self::Metrics { text: value } => text(value, 65536, true),
            Self::Ready => Ok(()),
            Self::Inventory { count, bytes } => {
                require(*count <= 1024 && *bytes <= 4 * 1024 * 1024)
            }
            Self::Measurements { observation, .. } => Self::Observed {
                observation: observation.clone(),
            }
            .validate(),
            Self::Qualified | Self::CreationPresence { .. } => Ok(()),
            Self::Created { receipt } => receipt.validate(),
            Self::Observed { observation } => {
                if let Some(config) = &observation.configuration {
                    config.validate()?;
                }
                if let Some(resources) = &observation.resources {
                    resources.validate()?;
                }
                if let Some((pid, start)) = observation.pid_identity {
                    require(pid > 0 && start > 0)?;
                }
                require(
                    observation.state != ObservedState::Missing
                        || (observation.resources.is_none()
                            && observation.pid_identity.is_none()
                            && observation.configuration.is_none()),
                )
            }
            Self::Command {
                completion,
                dispatch,
                observed_exit,
                running_observed,
                output_bytes,
            } => {
                require(
                    *completion != Completion::Completed && *output_bytes <= MAX_TRANSFER_BYTES,
                )?;
                require(*completion != Completion::Exited || observed_exit.is_some())?;
                require(observed_exit.is_none() || *running_observed)?;
                require(*output_bytes == 0 || *running_observed)?;
                require(
                    *dispatch != Dispatch::NotDispatched
                        || (observed_exit.is_none() && !*running_observed && *output_bytes == 0),
                )
            }
            Self::File {
                completion,
                dispatch,
                observed_bytes,
                native_acknowledged,
            } => {
                require(matches!(
                    completion,
                    Completion::Completed
                        | Completion::Cancelled
                        | Completion::Deadline
                        | Completion::NativeError
                        | Completion::ConsumerLost
                ))?;
                require(
                    *observed_bytes <= MAX_TRANSFER_BYTES
                        && (*completion != Completion::Completed || *native_acknowledged),
                )?;
                require(
                    *dispatch != Dispatch::NotDispatched
                        || (!*native_acknowledged && *observed_bytes == 0),
                )
            }
            Self::Error { .. } => Ok(()),
        }
    }

    pub fn validate_for(&self, major: u16) -> Result<()> {
        self.validate()?;
        if matches!(self, Self::Observed { observation } | Self::Measurements { observation, .. } if observation.configuration.is_some())
        {
            require(major == 2)?;
        }
        if matches!(
            self,
            Self::BranchCreated { .. }
                | Self::CollectedBranchMaterialPublished { .. }
                | Self::UnbootedBranchChildAbsent { .. }
                | Self::PartialBranchChildAbsent { .. }
                | Self::BranchChildAbsent { .. }
                | Self::BranchBackingReleased { .. }
                | Self::UnbootedBranchDisposalCandidate { .. }
                | Self::UnbootedBranchDisposed { .. }
                | Self::PreparedBranchRetired { .. }
                | Self::ReleasedBranchDeletionContinued { .. }
                | Self::PartialBranchDisposed { .. }
                | Self::PartialBranchCleanupCandidate { .. }
                | Self::PartialBranchDisposalCleaned { .. }
                | Self::PartialBranchCleanupUnneeded { .. }
                | Self::PartialBranchCollected { .. }
                | Self::PartialBranchCollectionCandidate { .. }
                | Self::BranchDeletionCollected { .. }
                | Self::ReleasedBranchDeletionCleaned { .. }
                | Self::ReleasedBranchDeletionResolved { .. }
                | Self::HeldBranchDeletionResolved { .. }
                | Self::HeldBranchDeletionContinued { .. }
                | Self::HeldBranchDeletionCleaned { .. }
                | Self::HeldBranchReleased { .. }
                | Self::HeldBranchReleasePresence { .. }
                | Self::BranchCompletionPresence { .. }
                | Self::Exported { .. }
                | Self::ExportPresence { .. }
                | Self::ExportStagingCleaned { .. }
                | Self::Volume { .. }
                | Self::PreparedArtifact { .. }
                | Self::Pulled { .. }
                | Self::Images { .. }
                | Self::Grown { .. }
                | Self::GrowthQualified { .. }
                | Self::GrowthPresence { .. }
                | Self::CapturePresence { .. }
                | Self::Captured { .. }
                | Self::CaptureResolved { .. }
                | Self::CaptureStagingCleaned { .. }
                | Self::AbortedCaptureSourceQualified { .. }
                | Self::CaptureStagingAborted { .. }
                | Self::CaptureResolutionPresence { .. }
                | Self::Health { .. }
                | Self::Terminal { .. }
                | Self::Logs { .. }
                | Self::Launched { .. }
                | Self::Capacity { .. }
                | Self::Metrics { .. }
                | Self::Ready
                | Self::Inventory { .. }
                | Self::Measurements { .. }
                | Self::Error {
                    code: SafeCode::OutputLimit,
                    ..
                }
                | Self::Error {
                    code: SafeCode::PortConflict,
                    ..
                }
                | Self::Error {
                    code: SafeCode::NotFound,
                    ..
                }
        ) {
            require(major == 2)?;
        }
        Ok(())
    }
}
#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Stream {
    Checkpoint,
    Terminal,
    Log,
    Stdout,
    Stderr,
    File,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Event {
    pub stream: Stream,
    pub data_base64: String,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum ServerMessage {
    TerminalOpened {
        epoch: String,
        id: u64,
        sequence: u64,
    },
    Unavailable {
        epoch: String,
    },
    Hello {
        hello: Box<Hello>,
    },
    Accepted {
        epoch: String,
        id: u64,
        sequence: u64,
    },
    Event {
        epoch: String,
        id: u64,
        sequence: u64,
        event: Event,
    },
    Terminal {
        epoch: String,
        id: u64,
        sequence: u64,
        outcome: Outcome,
    },
}
impl ServerMessage {
    pub fn decode(value: Value) -> Result<Self> {
        crate::validate_json(&value, 0).map_err(|_| InvalidMessage)?;
        let message: Self = serde_json::from_value(value).map_err(|_| InvalidMessage)?;
        message.validate()?;
        Ok(message)
    }
    pub fn validate(&self) -> Result<()> {
        match self {
            Self::TerminalOpened {
                epoch,
                id,
                sequence,
            } => {
                correlation(epoch, *id)?;
                require(*sequence > 0 && *sequence <= MAX_SAFE_INTEGER)
            }
            Self::Unavailable { epoch } => hex(epoch, 32),
            Self::Hello { hello } => hello.validate(),
            Self::Accepted {
                epoch,
                id,
                sequence,
            } => {
                correlation(epoch, *id)?;
                require(*sequence == 0)
            }
            Self::Event {
                epoch,
                id,
                sequence,
                event,
            } => {
                correlation(epoch, *id)?;
                require(
                    *sequence > 0
                        && *sequence
                            <= if event.stream == Stream::Checkpoint {
                                MAX_CAPTURE_EVENTS
                            } else if event.stream == Stream::Terminal {
                                MAX_SAFE_INTEGER - 1
                            } else {
                                MAX_EVENTS_PER_REQUEST
                            },
                )?;
                require(!decode_chunk(&event.data_base64)?.is_empty())
            }
            Self::Terminal {
                epoch,
                id,
                sequence,
                outcome,
            } => {
                correlation(epoch, *id)?;
                require(
                    *sequence
                        <= if matches!(
                            outcome,
                            Outcome::Captured { .. }
                                | Outcome::Error {
                                    dispatch: Dispatch::MayHaveDispatched,
                                    ..
                                }
                        ) {
                            MAX_CAPTURE_EVENTS + 1
                        } else if matches!(outcome, Outcome::Terminal { .. }) {
                            MAX_SAFE_INTEGER
                        } else {
                            MAX_EVENTS_PER_REQUEST + 1
                        },
                )?;
                if *sequence == 0 {
                    require(matches!(
                        outcome,
                        Outcome::Error {
                            dispatch: Dispatch::NotDispatched,
                            ..
                        }
                    ))?;
                }
                outcome.validate()
            }
        }
    }
}

pub fn encode_chunk(bytes: &[u8]) -> Result<String> {
    require(!bytes.is_empty() && bytes.len() <= MAX_CHUNK_BYTES)?;
    Ok(STANDARD.encode(bytes))
}
pub fn decode_chunk(encoded: &str) -> Result<Vec<u8>> {
    // Check the encoded bound before allocating the decoded body. STANDARD also
    // rejects missing padding, whitespace, noncanonical trailing bits and URL alphabet.
    require(encoded.len() <= MAX_CHUNK_BYTES.div_ceil(3) * 4)?;
    let bytes = STANDARD.decode(encoded).map_err(|_| InvalidMessage)?;
    require(bytes.len() <= MAX_CHUNK_BYTES)?;
    Ok(bytes)
}
fn require(condition: bool) -> Result<()> {
    if condition {
        Ok(())
    } else {
        Err(InvalidMessage)
    }
}
fn text(value: &str, max: usize, empty: bool) -> Result<()> {
    require((empty || !value.is_empty()) && value.len() <= max && !value.contains('\0'))
}
pub(crate) fn hex(value: &str, length: usize) -> Result<()> {
    require(
        value.len() == length
            && value
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)),
    )
}
fn checkpointable_mode(
    flag: Option<bool>,
    features: Option<&CreationFeatures>,
    mounts: Option<&[crate::VolumeMount]>,
) -> Result<()> {
    require(flag.is_none_or(|value| value))?;
    if flag == Some(true) {
        require(
            mounts.is_none()
                && features.is_none_or(|value| {
                    !value.network.enabled && value.ports.is_empty() && value.workload.is_none()
                }),
        )?;
    }
    Ok(())
}

pub(crate) fn id(value: &str) -> Result<()> {
    require(
        !value.is_empty()
            && value != "."
            && value != ".."
            && value.len() <= 128
            && value
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b)),
    )
}
fn absolute_path(value: &str) -> Result<()> {
    text(value, 4096, false)?;
    require(value.starts_with('/') && !value.split('/').any(|part| part == ".."))
}
fn correlation(epoch: &str, request: u64) -> Result<()> {
    hex(epoch, 32)?;
    require(request > 0 && request <= MAX_SAFE_INTEGER)
}

// Omitted extension fields preserve the old wire shape. An explicitly present
// null is not a valid feature/configuration object and must not bypass gating.
pub(crate) fn present_optional<'de, T: Deserialize<'de>, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> std::result::Result<Option<T>, D::Error> {
    T::deserialize(deserializer).map(Some)
}

pub(crate) fn required_nullable<'de, D, T>(
    deserializer: D,
) -> std::result::Result<Option<T>, D::Error>
where
    D: serde::Deserializer<'de>,
    T: serde::Deserialize<'de>,
{
    Option::deserialize(deserializer)
}
