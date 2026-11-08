//! Shared native control engine. No Erlang terms, protocol frames or NIFs.
//!
//! The first release uses the pinned runtime's default account paths. The
//! account-wide lock does not authorize foreign records, and an inventory label
//! is never a substitute for a creation receipt returned to the durable caller.

mod agent_io;
mod buffered;
pub use buffered::{BufferedCommand, LaunchOutcome, COMMAND_METADATA_BYTES};
mod archive;
mod artifact;
mod assets;
mod creation_features;
mod domain;
mod epoch;
mod exec;
mod files;
mod gate;
mod host;
mod identity;
mod jobs;
mod logs;
mod streaming;
mod terminal;
mod terminal_io;
pub mod terminal_ipc;
mod terminal_supervisor;
mod terminal_worker;
pub use agent_io::{AGENT_REPLY_OVERHEAD, AGENT_REQUEST_BYTES};
pub use logs::{
    LogOptions, LogOutcome, LOG_LINES, LOG_LINE_BYTES, LOG_MEMORY_BYTES, LOG_OUTPUT_BYTES,
    LOG_POLL_MS, LOG_RAW_LINE_BYTES,
};
pub use terminal::{
    TerminalControl, TerminalFailure, TerminalIdentity, TerminalOptions, TerminalOutcome,
    TerminalSession, TERMINAL_BUFFER_EVENTS, TERMINAL_CHUNK_BYTES, TERMINAL_INPUT_BYTES,
};
pub use terminal_io::{run_terminal_agent, TerminalIoProof, TerminalIoRequest};
pub use terminal_supervisor::{
    TerminalEvent, TerminalMessage, TerminalOutput, TerminalRequest, TerminalRunResult,
};
pub use terminal_worker::run_terminal_worker;
mod machine;
mod material;
mod observations;
mod sdk_compat;
pub use jobs::{
    JOB_CHILDREN, JOB_CONTROL_HEADROOM, JOB_CONTROL_SLOTS, JOB_DESCRIPTORS, JOB_METADATA_BYTES,
    JOB_STAGING_BYTES, JOB_WORK_SLOTS,
};
mod transfer_supervisor;
mod transfer_worker;

pub use artifact::ApprovedArtifact;
pub use assets::{ApprovedTemplate, ApprovedTemplates, TemplateFile};
pub use creation_features::{
    CreationFeatures, MachineConfiguration, NetworkPolicy, PortMapping, StartupWorkload,
};
pub use domain::DomainBinding;
pub use exec::{Cancellation, Command, CommandOutcome, Completion, Output, Stream};
pub use files::{FileCompletion, FileOptions, FileOutcome};
pub use host::{BootLauncher, Executable, ExecutableLocator, HostContext, OwnerIdentity};
pub use identity::{CreationReceipt, Observation, ObservedState, Resources};
pub use machine::{CreateRequest, CreationPresence, Engine};
pub use material::{GrowDisks, MaterialProof};
pub use observations::{
    CapacitySnapshot, HealthSnapshot, InventorySnapshot, MachineCounters, ReadBudget,
};
pub use sdk_compat::OBSERVATION_SCHEMA;
pub use transfer_worker::run_file_worker;

pub const SMOLVM_REVISION: &str = "9f446ae00219148ca4a703914f44a8e2fab11655";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ErrorCode {
    NotFound,
    Validation,
    Unsupported,
    Conflict,
    Ownership,
    Database,
    State,
    Native,
    Io,
    OutputLimit,
    PortConflict,
    Admission,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Dispatch {
    NotDispatched,
    MayHaveDispatched,
}

/// Safe categories only. Upstream diagnostics can contain paths, credentials,
/// guest commands and file contents and must never become public messages.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Error {
    pub code: ErrorCode,
    pub dispatch: Dispatch,
}

impl Error {
    pub(crate) fn before(code: ErrorCode) -> Self {
        Self {
            code,
            dispatch: Dispatch::NotDispatched,
        }
    }

    pub(crate) fn uncertain(code: ErrorCode) -> Self {
        Self {
            code,
            dispatch: Dispatch::MayHaveDispatched,
        }
    }
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "native {:?} ({:?})", self.code, self.dispatch)
    }
}

impl std::error::Error for Error {}

pub type Result<T> = std::result::Result<T, Error>;
