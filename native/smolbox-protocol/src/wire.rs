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
    TerminalOpen,
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
            ("logs", Capability::Logs),
            ("background_exec", Capability::ExecBackground),
            ("buffered_exec", Capability::ExecBuffered),
            ("streaming_exec", Capability::ExecStream),
            ("terminals", Capability::TerminalOpen),
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
                    | "volumes"
                    | "disk_growth"
                    | "checkpoints"
                    | "exports"
                    | "branches"
            ))?;
            require(*version == if feature == "material_proofs" { 2 } else { 1 })?;
        }
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
            self.feature_versions.get("terminals") != Some(&1)
                || self.feature_versions.get("buffered_exec") == Some(&1),
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
                && self.capabilities.len() <= if self.major == 1 { 10 } else { 21 },
        )?;
        for (index, capability) in self.capabilities.iter().enumerate() {
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
    pub operation_id: Option<String>,
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
    pub features: Option<Box<CreationFeatures>>,
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
}
impl MachineConfiguration {
    fn validate(&self) -> Result<()> {
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

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "operation", rename_all = "snake_case", deny_unknown_fields)]
pub enum Operation {
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
    pub fn command_limit(&self) -> Option<u64> {
        match self {
            Self::Exec { command, .. } => Some(command.max_output_bytes),
            Self::ExecBuffered { command, .. } => Some(command.max_output_bytes),
            Self::ExecStream { command, .. } => Some(command.max_output_bytes),
            _ => None,
        }
    }
    pub fn creation_features(&self) -> Option<&CreationFeatures> {
        match self {
            Self::Create { create } | Self::InspectCreation { create } => {
                create.features.as_deref()
            }
            Self::QualifyCreation { features, .. } => features.as_deref(),
            _ => None,
        }
    }
    pub fn capability(&self) -> Capability {
        match self {
            Self::TerminalOpen { .. } => Capability::TerminalOpen,
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
            Self::Health | Self::Capacity | Self::Metrics | Self::Readiness | Self::List => None,
            Self::Create { .. } | Self::InspectCreation { .. } | Self::QualifyCreation { .. } => {
                None
            }
            Self::Inspect { receipt }
            | Self::Logs { receipt, .. }
            | Self::Measurements { receipt }
            | Self::Start { receipt }
            | Self::Stop { receipt }
            | Self::Delete { receipt }
            | Self::Exec { receipt, .. }
            | Self::ExecBuffered { receipt, .. }
            | Self::ExecStream { receipt, .. }
            | Self::TerminalOpen { receipt, .. }
            | Self::ExecBackground { receipt, .. }
            | Self::ReadFile { receipt, .. }
            | Self::WriteFile { receipt, .. } => Some(receipt),
        }
    }
    pub fn validate(&self, budget_ms: u64) -> Result<()> {
        require(budget_ms > 0 && budget_ms <= 86_400_000)?;
        if let Some(receipt) = self.receipt() {
            receipt.validate()?;
        }
        if let Some(features) = self.creation_features() {
            features.validate()?;
        }
        match self {
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
            Self::Health { .. }
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
                            <= if event.stream == Stream::Terminal {
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
                        <= if matches!(outcome, Outcome::Terminal { .. }) {
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
fn hex(value: &str, length: usize) -> Result<()> {
    require(
        value.len() == length
            && value
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)),
    )
}
fn id(value: &str) -> Result<()> {
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
fn present_optional<'de, T: Deserialize<'de>, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> std::result::Result<Option<T>, D::Error> {
    T::deserialize(deserializer).map(Some)
}
