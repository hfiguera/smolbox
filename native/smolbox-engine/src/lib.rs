//! Shared native control engine. No Erlang terms, protocol frames or NIFs.
//!
//! The first release uses the pinned runtime's default account paths. The
//! account-wide lock does not authorize foreign records, and an inventory label
//! is never a substitute for a creation receipt returned to the durable caller.

mod archive;
mod artifact;
mod assets;
mod domain;
mod epoch;
mod exec;
mod files;
mod gate;
mod host;
mod identity;
mod machine;
mod sdk_compat;
mod transfer_supervisor;
mod transfer_worker;

pub use artifact::ApprovedArtifact;
pub use assets::{ApprovedTemplate, ApprovedTemplates, TemplateFile};
pub use domain::DomainBinding;
pub use exec::{Cancellation, Command, CommandOutcome, Completion, Output, Stream};
pub use files::{FileCompletion, FileOptions, FileOutcome};
pub use host::{BootLauncher, Executable, ExecutableLocator, HostContext, OwnerIdentity};
pub use identity::{CreationReceipt, Observation, ObservedState, Resources};
pub use machine::{CreateRequest, CreationPresence, Engine};
pub use sdk_compat::OBSERVATION_SCHEMA;
pub use transfer_worker::run_file_worker;

pub const SMOLVM_REVISION: &str = "9f446ae00219148ca4a703914f44a8e2fab11655";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ErrorCode {
    Validation,
    Unsupported,
    Conflict,
    Ownership,
    Database,
    State,
    Native,
    Io,
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
