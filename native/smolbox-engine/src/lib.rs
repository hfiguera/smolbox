//! Shared native control engine. No Erlang terms, protocol frames or NIFs.
//!
//! The first release uses the pinned runtime's default account paths. The
//! account-wide lock does not authorize foreign records, and an inventory label
//! is never a substitute for a creation receipt returned to the durable caller.

mod agent_io;
mod branch;
mod branch_absence;
pub use branch_absence::{
    BranchChildAbsence, BranchChildAbsenceRequest, PartialBranchChildAbsence,
    PartialBranchChildAbsenceRequest, UnbootedBranchChildAbsence,
    UnbootedBranchChildAbsenceRequest, BRANCH_ABSENCE_BYTES, PARTIAL_BRANCH_ABSENCE_BYTES,
    UNBOOTED_BRANCH_ABSENCE_BYTES,
};
mod branch_backing;
pub use branch_backing::{
    BranchBackingReleaseRequest, PartialBranchBackingReleaseRequest,
    UnbootedBranchBackingReleaseRequest, BRANCH_BACKING_PROOF_BYTES, BRANCH_BACKING_REQUEST_BYTES,
};
mod branch_agent;
mod branch_boot;
mod branch_delete_action;
pub use branch_delete_action::{HeldBranchDeletionAction, HeldBranchDeletionActionRequest};
mod branch_delete_request;
pub use branch_delete_request::{
    HeldBranchDeletionRequest, HELD_BRANCH_DELETION_PROOF_BYTES, HELD_BRANCH_DELETION_REQUEST_BYTES,
};
mod branch_delete;
pub use branch_delete::{
    BranchDeletionCollection, BranchDeletionCollectionRequest, BranchDeletionContinuation,
    BranchDeletionResolution, ReleasedBranchDeletionCleanupRequest,
    ReleasedBranchDeletionContinuation, ReleasedBranchDeletionContinuationRequest,
    ReleasedBranchDeletionRequest, ReleasedBranchDeletionResolution,
    RELEASED_BRANCH_DELETION_PROOF_BYTES, RELEASED_BRANCH_DELETION_REQUEST_BYTES,
};
mod branch_held_release;
mod branch_identity;
mod branch_material;
mod branch_owned;
pub use branch_owned::BranchCompletion;
mod branch_partial_collection;
pub use branch_partial_collection::{
    PartialBranchCollection, PartialBranchCollectionCandidate, PartialBranchCollectionRequest,
};
mod branch_partial_cleanup_candidate;
pub use branch_partial_cleanup_candidate::{
    PartialBranchCleanupCandidate, PartialBranchCleanupState,
    PARTIAL_BRANCH_CLEANUP_CANDIDATE_BYTES,
};
mod branch_partial_cleanup;
pub use branch_partial_cleanup::{
    PartialBranchDisposalCleanup, PartialBranchDisposalCleanupRequest,
    PARTIAL_BRANCH_CLEANUP_PROOF_BYTES, PARTIAL_BRANCH_CLEANUP_REQUEST_BYTES,
};
mod branch_partial_cleanup_unneeded;
pub use branch_partial_cleanup_unneeded::{
    PartialBranchDisposalCleanupUnneeded, PARTIAL_BRANCH_UNNEEDED_CLEANUP_PROOF_BYTES,
};
mod branch_partial_disposal;
pub use branch_partial_disposal::{
    PartialBranchDisposal, PartialBranchDisposalCompletion, PartialBranchDisposalRequest,
    PARTIAL_BRANCH_DISPOSAL_PROOF_BYTES, PARTIAL_BRANCH_DISPOSAL_REQUEST_BYTES,
};
mod branch_release;
pub use branch_release::{BranchReleaseChange, BranchReleaseRequest, BranchReleaseTransition};
mod branch_worker;
pub use branch::{
    BranchApproval, BranchBackingRelease, BranchBootIdentity, BranchChildIntent,
    BranchCreateRequest, BranchGuestIdentity, BranchPreparationState, BranchResourcePlan,
    BranchResources, InitialBranchRetirement, PreparedBranchIntent, PreparedBranchRetirement,
    PreparedBranchRetirementRequest, PreparedBranchWorker, PreparedInitialBranch,
    RetainedBranchPreparation, RetainedBranchResolution, UnbootedBranchDisposal,
    UnbootedBranchDisposalCandidate, UnbootedBranchDisposalCompletion,
    UnbootedBranchDisposalRequest, PREPARED_BRANCH_RETIREMENT_BYTES,
};
pub use branch_material::{BranchPublication, BranchSourceChange};
mod bootstrap;
pub use bootstrap::Metadata as OciBootstrapPlan;
mod buffered;
mod capture;
mod capture_abort_source;
mod capture_material;
mod capture_resolution;
mod capture_staging;
pub use capture_abort_source::{CaptureAbortSourceQualification, CaptureAbortSourceState};
pub use capture_staging::CaptureStagingCleanupReceipt;
mod capture_worker;
pub use capture::CapturedCheckpoint;
mod checkpoint;
mod checkpoint_capture;
pub use capture_material::{CaptureArtifact, CaptureChange, CaptureRequest, CaptureTransition};
pub use capture_resolution::{CaptureResolutionChange, CaptureResolutionTransition};
mod checkpoint_install;
mod checkpoint_lifecycle;
mod checkpoint_materialize;
mod checkpoint_source;
pub use buffered::{BufferedCommand, LaunchOutcome, COMMAND_METADATA_BYTES};
pub use checkpoint::{
    ApprovedCheckpoint, ApprovedCheckpointArtifact, CHECKPOINT_ARTIFACT_BYTES,
    CHECKPOINT_DISK_FILES,
};
pub use checkpoint_source::{CreateCheckpointRequest, MaterializedCheckpoint, PreparedCheckpoint};
mod archive;
mod artifact;
mod assets;
mod creation_features;
mod disk_geometry;
mod domain;
mod epoch;
mod exec;
mod export_assets;
mod runtime_boot;
pub use export_assets::{
    ApprovedExportAsset, ApprovedExportAssets, EXPORT_ASSET_FILE_BYTES, EXPORT_ASSET_TOTAL_BYTES,
};
mod export_publication;
pub use export_publication::{
    ApprovedExportDestination, ExportPublication, ExportPublicationIdentity, PublishedExport,
    RegistryPublishCredential, EXPORT_METADATA_BYTES, EXPORT_REGISTRY_REQUESTS,
    EXPORT_UPLOAD_CHUNK_BYTES,
};
mod export_pack;
pub use export_pack::PackedExport;
mod export_bootstrap;
mod export_container;
pub use export_bootstrap::{
    run_container_conversion, ContainerConversionInput, ContainerConversionIo,
};
mod export_stream;
pub use export_stream::{stream_container_layer, ContainerLayerIo};
mod export_disks;
pub use export_container::{
    ContainerExportIntent, ContainerExportPlan, ContainerExportScratch,
    InitializedContainerStorage, PreparedContainerExport,
};
mod export_conversion;
mod export_import;
pub use export_import::{ImportedContainerLayer, QualifiedImportedContainerExport};
mod export_coordinator;
pub use export_conversion::{
    ExportConversionBudget, ExportConversionResources, ImportedConversionAllowance,
};
mod export_retention;
mod export_runtime;
pub use export_disks::{
    ExportDiskDigest, ExportDiskKind, MaterializedExportDisks, PreparedExportDisks,
};
pub use export_retention::{CollectedContainerConversion, RetainedConversionStorage};
mod export_source;
mod export_staging;
pub use export_source::{ExportSourceMode, QualifiedExportSource};
pub use export_staging::{
    ExportStageCleanup, ExportStagedFile, EXPORT_RECORDS, EXPORT_RECORD_BYTES,
};
mod files;
mod gate;
mod growth;
mod host;
mod identity;
mod image_pull;
pub use image_pull::ImagePullRequest;
mod images;
pub use images::{ImageObservation, IMAGE_COUNT, IMAGE_OUTPUT_BYTES, IMAGE_REPLY_BYTES};
mod jobs;
mod logs;
mod qcow_geometry;
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
mod guest_registry;
mod machine;
mod material;
mod observations;
mod oci;
mod oci_start;
mod registry_account;
mod registry_artifact;
mod registry_credentials;
mod registry_provider;
pub use registry_credentials::RegistryIdentityCredential;
mod mount_material;
mod registry_io;
mod volumes;
pub use mount_material::MountMaterial;
pub use oci::{OciConfigDescriptor, VerifiedOci, OCI_METADATA_BYTES};
pub use registry_artifact::{
    QualifiedRegistryArtifact, RegistryArtifactSource, RegistryBlobDescriptor, RegistryCachePolicy,
    RegistryCachedBlob, REGISTRY_CACHE_BYTES, REGISTRY_CACHE_FILES,
};
pub use volumes::{
    LocalVolumeIntent, LocalVolumePolicy, QualifiedVolumeMounts, QualifiedVolumeRoot,
    VolumeAccount, VolumeDeletionPermit, VolumeDeletionPresence, VolumeDeletionReceipt,
    VolumeMountRequest, VolumeMountSelection, VolumeProvisionPresence, VolumeProvisionReceipt,
    VolumeStagingAbortPresence, VolumeStagingAbortReceipt, VolumeStagingPresence,
    VolumeStagingReceipt, VOLUME_ANCESTOR_BYTES, VOLUME_DELETE_ENTRIES, VOLUME_MOUNTS,
    VOLUME_OBSERVATION_METADATA_BYTES, VOLUME_OBSERVATION_MS, VOLUME_RECORD_BYTES, VOLUME_WORK_MS,
};
mod sdk_compat;
pub use jobs::{
    JOB_CHECKPOINT_MATERIAL_BYTES, JOB_CHECKPOINT_METADATA_BYTES, JOB_CHECKPOINT_STAGING_BYTES,
    JOB_CHILDREN, JOB_CONTROL_HEADROOM, JOB_CONTROL_METADATA_BYTES, JOB_CONTROL_SLOTS,
    JOB_DESCRIPTORS, JOB_EXPORT_STAGING_BYTES, JOB_MATERIAL_CONTROL_METADATA_BYTES,
    JOB_METADATA_BYTES, JOB_REGISTRY_STAGING_BYTES, JOB_STAGING_BYTES, JOB_WORK_SLOTS,
};
mod transfer_supervisor;
mod transfer_worker;

pub use artifact::ApprovedArtifact;
pub use assets::{ApprovedTemplate, ApprovedTemplates, TemplateFile};
pub use creation_features::{
    CreationFeatures, MachineConfiguration, NetworkPolicy, ObservedMount, PortMapping,
    StartupWorkload,
};
pub use domain::DomainBinding;
pub use exec::{Cancellation, Command, CommandOutcome, Completion, Output, Stream};
pub use files::{FileCompletion, FileOptions, FileOutcome};
pub use host::{BootLauncher, Executable, ExecutableLocator, HostContext, OwnerIdentity};
pub use identity::{CreationReceipt, Observation, ObservedState, Resources};
pub use machine::{
    CheckpointCreationIntent, CreateOciRequest, CreateRegistryRequest, CreateRequest,
    CreationPresence, Engine, OciCreationIntent, RegistryCreationIntent,
};
pub use material::{GrowDisks, GrowthChange, GrowthTransition, MaterialProof};
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
