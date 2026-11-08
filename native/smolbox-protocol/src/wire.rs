//! Versioned bridge DTOs. These are intentionally separate from engine types.
//! No DTO implements Debug: commands, receipts and file bytes are sensitive.
use base64::{engine::general_purpose::STANDARD, Engine as _};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

pub const PROTOCOL_MAJOR: u16 = 1;
pub const PROTOCOL_MINOR: u16 = 4;
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
pub struct Hello {
    pub major: u16,
    pub minor: u16,
    pub epoch: String,
    pub domain: DomainIdentity,
    pub package: PackageIdentity,
    pub capabilities: Vec<Capability>,
    pub limits: Limits,
    pub preflight: Preflight,
}
impl Hello {
    pub fn validate(&self) -> Result<()> {
        require(self.major == PROTOCOL_MAJOR && self.minor == PROTOCOL_MINOR)?;
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
        require(self.limits == Limits::default() && self.capabilities.len() <= 10)?;
        for (index, capability) in self.capabilities.iter().enumerate() {
            require(!self.capabilities[..index].contains(capability))?;
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
}
impl Receipt {
    pub fn validate(&self) -> Result<()> {
        id(&self.target_id)?;
        id(&self.name)?;
        hex(&self.domain_generation, 32)?;
        hex(&self.owner_token, 64)?;
        hex(&self.incarnation, 32)?;
        hex(&self.material_sha256, 64)
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
pub struct FileOptions {
    pub guest_path: String,
    pub max_bytes: u64,
    pub mode: Option<u32>,
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "operation", rename_all = "snake_case", deny_unknown_fields)]
pub enum Operation {
    QualifyCreation {
        artifact: Artifact,
        resources: Resources,
        user: Option<String>,
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
    pub fn capability(&self) -> Capability {
        match self {
            Self::QualifyCreation { .. } => Capability::QualifyCreation,
            Self::Create { .. } => Capability::Create,
            Self::InspectCreation { .. } => Capability::InspectCreation,
            Self::Inspect { .. } => Capability::Inspect,
            Self::Start { .. } => Capability::Start,
            Self::Stop { .. } => Capability::Stop,
            Self::Delete { .. } => Capability::Delete,
            Self::Exec { .. } => Capability::Exec,
            Self::ReadFile { .. } => Capability::ReadFile,
            Self::WriteFile { .. } => Capability::WriteFile,
        }
    }
    pub fn receipt(&self) -> Option<&Receipt> {
        match self {
            Self::Create { .. } | Self::InspectCreation { .. } | Self::QualifyCreation { .. } => {
                None
            }
            Self::Inspect { receipt }
            | Self::Start { receipt }
            | Self::Stop { receipt }
            | Self::Delete { receipt }
            | Self::Exec { receipt, .. }
            | Self::ReadFile { receipt, .. }
            | Self::WriteFile { receipt, .. } => Some(receipt),
        }
    }
    pub fn validate(&self, budget_ms: u64) -> Result<()> {
        require(budget_ms > 0 && budget_ms <= 86_400_000)?;
        if let Some(receipt) = self.receipt() {
            receipt.validate()?;
        }
        match self {
            Self::QualifyCreation {
                artifact,
                resources,
                user,
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
    pub fn decode(value: Value) -> Result<Self> {
        crate::validate_json(&value, 0).map_err(|_| InvalidMessage)?;
        let message: Self = serde_json::from_value(value).map_err(|_| InvalidMessage)?;
        message.validate()?;
        Ok(message)
    }
    pub fn validate(&self) -> Result<()> {
        match self {
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
}
#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CreationPresence {
    Absent,
    Unverified,
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "result", rename_all = "snake_case", deny_unknown_fields)]
pub enum Outcome {
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
            Self::Qualified | Self::CreationPresence { .. } => Ok(()),
            Self::Created { receipt } => receipt.validate(),
            Self::Observed { observation } => {
                if let Some(resources) = &observation.resources {
                    resources.validate()?;
                }
                if let Some((pid, start)) = observation.pid_identity {
                    require(pid > 0 && start > 0)?;
                }
                require(
                    observation.state != ObservedState::Missing
                        || (observation.resources.is_none() && observation.pid_identity.is_none()),
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
}
#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Stream {
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
                require(*sequence > 0 && *sequence <= MAX_EVENTS_PER_REQUEST)?;
                require(!decode_chunk(&event.data_base64)?.is_empty())
            }
            Self::Terminal {
                epoch,
                id,
                sequence,
                outcome,
            } => {
                correlation(epoch, *id)?;
                require(*sequence <= MAX_EVENTS_PER_REQUEST + 1)?;
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
