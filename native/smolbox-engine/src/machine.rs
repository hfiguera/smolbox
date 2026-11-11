use crate::domain::{valid_hex, valid_id, DomainGuard};
use crate::exec::{validate_guest_user, Collector, Deadline};
use crate::gate::MachineGate;
use crate::identity::{material_hash, record_state};
use crate::transfer_supervisor::TransferSupervisor;
use crate::{
    ApprovedArtifact, Cancellation, Command, CommandOutcome, CreationReceipt, DomainBinding, Error,
    ErrorCode, Observation, ObservedState, Output, Resources, Result,
};
use smolvm::agent::{AgentClient, AgentManager, VmResources};
use smolvm::config::VmRecord;
use smolvm::db::SmolvmDb;
use smolvm::embedded::{EmbeddedRuntime, MachineSpec};
use smolvm_pack::format::PackMode;
use std::collections::{BTreeMap, HashMap};
use std::fs::OpenOptions;
use std::io::{Read, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, Weak};

fn creation_read_budget(
    deadline: std::time::Instant,
    cancel: &Cancellation,
) -> Result<crate::ReadBudget> {
    crate::ReadBudget::new(
        deadline
            .saturating_duration_since(std::time::Instant::now())
            .min(std::time::Duration::from_secs(30)),
        cancel.clone(),
    )
}

// Acquisition/preflight failures stay NotDispatched. Only actual SDK entry
// changes error evidence; late return keeps uncertainty and retained ownership.
fn lifecycle_sdk_call(
    budget: &crate::ReadBudget,
    call: impl FnOnce() -> smolvm::Result<()>,
) -> Result<()> {
    budget.check()?;
    call().map_err(|_| Error::uncertain(ErrorCode::Native))?;
    budget.check().map_err(|e| Error::uncertain(e.code))
}

#[derive(Clone)]
pub struct CreateRequest {
    pub name: String,
    pub owner_token: String,
    /// Fresh random generation selected before dispatch and stored in intent.
    pub incarnation: String,
    pub artifact: ApprovedArtifact,
    pub resources: Resources,
    pub labels: BTreeMap<String, String>,
}

#[derive(Clone, Copy, Default)]
struct PackRecordPolicy<'a> {
    features: Option<&'a crate::CreationFeatures>,
    checkpointable: bool,
}
impl<'a> From<Option<&'a crate::CreationFeatures>> for PackRecordPolicy<'a> {
    fn from(features: Option<&'a crate::CreationFeatures>) -> Self {
        Self {
            features,
            checkpointable: false,
        }
    }
}
impl PackRecordPolicy<'_> {
    fn qualify(&self, manifest: &smolvm_pack::format::PackManifest) -> Result<()> {
        if let Some(features) = self.features {
            features.qualify(manifest)?;
        }
        if self.checkpointable {
            crate::checkpoint_capture::validate_pack(manifest)?;
            if self.features.is_some_and(|features| {
                !features.ports.is_empty()
                    || features.workload.is_some()
                    || (!cfg!(target_os = "linux") && features.network.enabled)
            }) {
                return Err(Error::before(ErrorCode::Unsupported));
            }
        }
        Ok(())
    }
}

/// Fresh registry creation consumes a qualified pack; it cannot select a host
/// path or promote cache/inventory into existing-machine ownership.
pub struct CreateRegistryRequest {
    pub name: String,
    pub owner_token: String,
    pub incarnation: String,
    pub artifact: crate::QualifiedRegistryArtifact,
    pub labels: BTreeMap<String, String>,
    pub features: crate::CreationFeatures,
}

/// Fresh direct OCI creation intent; metadata was verified against this source
/// before entry. The bridge must select it from its operator approval catalog.
#[derive(Clone)]
pub struct CreateOciRequest {
    pub name: String,
    pub owner_token: String,
    pub incarnation: String,
    pub resources: Resources,
    pub labels: BTreeMap<String, String>,
    pub source: crate::VerifiedOci,
    pub features: crate::CreationFeatures,
}

/// Receipt-free immutable source intent. Only fresh creation may return
/// ownership; qualification/absence never fetch or adopt current authority.
#[derive(Clone)]
pub struct OciCreationIntent {
    pub name: String,
    pub owner_token: String,
    pub incarnation: String,
    pub source: crate::ImagePullRequest,
    pub resources: Resources,
    pub labels: BTreeMap<String, String>,
    pub features: crate::CreationFeatures,
}

/// Immutable registry source intent, without cache/receipt or credential bytes.
#[derive(Clone)]
pub struct RegistryCreationIntent {
    pub name: String,
    pub owner_token: String,
    pub incarnation: String,
    pub source: crate::RegistryArtifactSource,
    pub resources: Resources,
    pub labels: BTreeMap<String, String>,
    pub features: crate::CreationFeatures,
}

/// An intent can prove absence, never recover a lost creation receipt.
#[derive(Clone)]
pub struct CheckpointCreationIntent {
    pub name: String,
    pub owner_token: String,
    pub incarnation: String,
    pub source_sha256: String,
    pub resources: Resources,
    pub labels: BTreeMap<String, String>,
}

/// An intent can prove absence, never recover a lost creation receipt.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CreationPresence {
    Absent,
    Unverified,
}

pub struct Engine {
    opened_at: std::time::Instant,
    pub(crate) runtime: Arc<EmbeddedRuntime>,
    pub(crate) db: SmolvmDb,
    pub(crate) database_identity: (u64, u64),
    binding: DomainBinding,
    gates: Mutex<HashMap<String, Weak<MachineGate>>>,
    owned_handles: Mutex<BTreeMap<String, CreationReceipt>>,
    // Public SDK pid() can fall back to inventory. Only a successful owned
    // forkable start may enroll this independent original-live-source witness.
    capture_sources: Mutex<BTreeMap<String, (i32, u64)>>,
    // Keep the actual SDK manager alive; dropping it would stop its VMM.
    pub(crate) owned_managers: Mutex<BTreeMap<String, Arc<Mutex<AgentManager>>>>,
    branch_owners: Mutex<BTreeMap<String, Arc<crate::branch_owned::Context>>>,
    pub(crate) runtime_boots: Arc<crate::runtime_boot::Registry>,
    pub(crate) domain: Arc<DomainGuard>,
    pub(crate) transfers: Option<TransferSupervisor>,
    pub(crate) jobs: crate::jobs::JobPool,
    pub(crate) capture_staging: Arc<crate::capture_staging::Staging>,
    pub(crate) export_staging: Arc<crate::export_staging::Staging>,
    pub(crate) export_retention: Arc<crate::export_retention::Registry>,
    pub(crate) branch_retention: Arc<crate::branch::retention::Registry>,
    templates: Option<crate::assets::PreparedTemplates>,
    export_assets: Option<crate::ApprovedExportAssets>,
    host: Option<crate::HostContext>,
    boot: Option<(crate::BootLauncher, crate::epoch::ActorEpoch)>,
}

impl Engine {
    /// Install package-manifest-approved runtime inputs once, before serving.
    /// Paths are operator setup, never request fields. Old packages can omit this
    /// optional catalog and retain their existing behavior without export.
    pub fn prepare_export_assets(
        &mut self,
        assets: crate::ApprovedExportAssets,
        package_sha256: &str,
        budget: &crate::ReadBudget,
    ) -> Result<()> {
        budget.check()?;
        if !self.available() {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let host = self
            .host
            .as_ref()
            .ok_or(Error::before(ErrorCode::Unsupported))?;
        if host.domain != self.binding || host.package_sha256 != package_sha256 {
            return Err(Error::before(ErrorCode::Ownership));
        }
        assets.validate()?;
        let libraries = &host.executables.library_directory;
        let root = libraries
            .parent()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        if libraries.file_name() != Some(std::ffi::OsStr::new("lib"))
            || assets
                .files
                .iter()
                .any(|asset| asset.path != root.join(&asset.name))
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        if let Some(previous) = &self.export_assets {
            return if previous == &assets {
                Ok(())
            } else {
                Err(Error::before(ErrorCode::Conflict))
            };
        }
        let _job = self.jobs.acquire(crate::jobs::Demand::export_source())?;
        host.validate()?;
        let qualified = assets.qualify(budget)?;
        qualified.verify()?;
        budget.check()?;
        self.export_assets = Some(assets);
        Ok(())
    }
    pub(crate) fn export_asset_approval(&self) -> Result<&crate::ApprovedExportAssets> {
        if !self.available() {
            return Err(Error::before(ErrorCode::Ownership));
        }
        self.export_assets
            .as_ref()
            .ok_or(Error::before(ErrorCode::Unsupported))
    }
    pub(crate) fn capture_assets(&self) -> Result<(PathBuf, PathBuf)> {
        let host = self
            .host
            .as_ref()
            .ok_or(Error::before(ErrorCode::Unsupported))?;
        Ok((
            host.executables.library_directory.clone(),
            smolvm::agent::AgentManager::resolve_rootfs_path(None, "capture source assets")
                .map_err(|_| Error::before(ErrorCode::Unsupported))?,
        ))
    }
    /// Cache-independent pre-reservation feasibility. Downloaded pack contents
    /// are qualified separately during create_prepared, never inferred here.
    pub fn qualify_registry_intent(
        &self,
        source: &crate::RegistryArtifactSource,
        resources: Resources,
        user: Option<&str>,
        features: &crate::CreationFeatures,
        budget: &crate::ReadBudget,
    ) -> Result<()> {
        budget.check()?;
        source.validate()?;
        resources.validate()?;
        features.validate()?;
        validate_guest_user(user, true)?;
        if source.platform != crate::oci::native_oci_platform() {
            return Err(Error::before(ErrorCode::Unsupported));
        }
        let _lease = self.jobs.acquire(crate::jobs::Demand::observation())?;
        self.domain.verify()?;
        self.verify_templates()?;
        budget.check()
    }
    /// Fresh creation from previously prepared content. Qualification and SDK
    /// materialization share the original absolute deadline; no registry refetch.
    pub fn create_registry_cached(
        &self,
        intent: RegistryCreationIntent,
        size: u64,
        policy: crate::RegistryCachePolicy,
        deadline: std::time::Instant,
        cancel: &Cancellation,
    ) -> Result<CreationReceipt> {
        self.create_registry_cached_mode(intent, (size, policy, false), None, deadline, cancel)
    }

    pub fn create_registry_cached_with_mount_selection(
        &self,
        intent: RegistryCreationIntent,
        cache: (u64, crate::RegistryCachePolicy),
        mounts: crate::VolumeMountSelection,
        deadline: std::time::Instant,
        cancel: &Cancellation,
    ) -> Result<CreationReceipt> {
        self.create_registry_cached_mode(
            intent,
            (cache.0, cache.1, false),
            Some(mounts),
            deadline,
            cancel,
        )
    }

    pub fn create_registry_checkpointable_cached(
        &self,
        intent: RegistryCreationIntent,
        size: u64,
        policy: crate::RegistryCachePolicy,
        deadline: std::time::Instant,
        cancel: &Cancellation,
    ) -> Result<CreationReceipt> {
        self.create_registry_cached_mode(intent, (size, policy, true), None, deadline, cancel)
    }

    fn create_registry_cached_mode(
        &self,
        intent: RegistryCreationIntent,
        cache: (u64, crate::RegistryCachePolicy, bool),
        mounts: Option<crate::VolumeMountSelection>,
        deadline: std::time::Instant,
        cancel: &Cancellation,
    ) -> Result<CreationReceipt> {
        if cancel.is_cancelled() || std::time::Instant::now() >= deadline {
            return Err(Error::before(ErrorCode::State));
        }
        let (size, policy, checkpointable) = cache;
        if let Some(mounts) = &mounts {
            mounts.validate(self.binding())?;
        }
        validate_creation_identity(
            &intent.name,
            &intent.owner_token,
            &intent.incarnation,
            intent.resources,
            &intent.labels,
        )?;
        intent.source.validate()?;
        intent.features.validate()?;
        self.verify_templates()?;
        let artifact = self.qualify_registry_cached(
            intent.source,
            size,
            policy,
            intent.resources,
            deadline,
            cancel.clone(),
        )?;
        let request = CreateRegistryRequest {
            name: intent.name,
            owner_token: intent.owner_token,
            incarnation: intent.incarnation,
            artifact,
            labels: intent.labels,
            features: intent.features,
        };
        match mounts {
            Some(mounts) => {
                let mounts = self.qualify_volume_mounts(
                    &mounts.policy,
                    &mounts.requests,
                    &creation_read_budget(deadline, cancel)?,
                )?;
                self.create_registry_with_volume_mounts(request, mounts, deadline, cancel)
            }
            None if checkpointable => {
                self.create_registry_checkpointable_prepared(request, deadline, cancel)
            }
            None => self.create_registry_prepared(request, deadline, cancel),
        }
    }

    /// Read-only absence; never contacts registry/cache, adopts a row or issues
    /// ownership. Quiescence remains a caller prerequisite for capacity release.
    pub fn inspect_registry_creation(
        &self,
        intent: &RegistryCreationIntent,
        budget: &crate::ReadBudget,
    ) -> Result<CreationPresence> {
        budget.check()?;
        validate_creation_identity(
            &intent.name,
            &intent.owner_token,
            &intent.incarnation,
            intent.resources,
            &intent.labels,
        )?;
        intent.source.validate()?;
        intent.features.validate()?;
        if intent.source.platform != crate::oci::native_oci_platform() {
            return Err(Error::before(ErrorCode::Unsupported));
        }
        let _lease = self.jobs.acquire(crate::jobs::Demand::observation())?;
        let gate = self.observation_gate(&intent.name)?;
        let _guard = gate
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        self.verify_database_identity()?;
        let absent = crate::sdk_compat::observe_absence(
            &self.binding.database,
            self.database_identity,
            &intent.name,
            || self.creation_material_absent(&intent.name),
        )?;
        self.verify_database_identity()?;
        budget.check()?;
        Ok(if absent {
            CreationPresence::Absent
        } else {
            CreationPresence::Unverified
        })
    }
    /// Read-only checkpoint absence. No source read, installation, receipt
    /// recovery or adoption; release still requires caller-proven quiescence.
    pub fn inspect_checkpoint_creation(
        &self,
        intent: &CheckpointCreationIntent,
        budget: &crate::ReadBudget,
    ) -> Result<CreationPresence> {
        budget.check()?;
        validate_creation_identity(
            &intent.name,
            &intent.owner_token,
            &intent.incarnation,
            intent.resources,
            &intent.labels,
        )?;
        if !valid_hex(&intent.source_sha256, 64) {
            return Err(Error::before(ErrorCode::Validation));
        }
        let _lease = self.jobs.acquire(crate::jobs::Demand::observation())?;
        let gate = self.observation_gate(&intent.name)?;
        let _guard = gate
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        self.verify_database_identity()?;
        let absent = crate::sdk_compat::observe_absence(
            &self.binding.database,
            self.database_identity,
            &intent.name,
            || self.creation_material_absent(&intent.name),
        )?;
        self.verify_database_identity()?;
        budget.check()?;
        Ok(if absent {
            CreationPresence::Absent
        } else {
            CreationPresence::Unverified
        })
    }
    fn validate_oci_intent(&self, intent: &OciCreationIntent) -> Result<()> {
        validate_creation_identity(
            &intent.name,
            &intent.owner_token,
            &intent.incarnation,
            intent.resources,
            &intent.labels,
        )?;
        intent.source.validate()?;
        intent.features.validate()?;
        if intent.source.platform != crate::oci::native_oci_platform() {
            return Err(Error::before(ErrorCode::Unsupported));
        }
        Ok(())
    }

    /// Exact approved source preparation and fresh creation share one deadline.
    /// The bridge must independently select the source from its approval catalog.
    pub fn create_oci_intent(
        &self,
        intent: OciCreationIntent,
        deadline: std::time::Instant,
        cancel: &Cancellation,
    ) -> Result<CreationReceipt> {
        self.create_oci_intent_mode(intent, None, deadline, cancel)
    }

    pub fn create_oci_intent_with_mount_selection(
        &self,
        intent: OciCreationIntent,
        mounts: crate::VolumeMountSelection,
        deadline: std::time::Instant,
        cancel: &Cancellation,
    ) -> Result<CreationReceipt> {
        self.create_oci_intent_mode(intent, Some(mounts), deadline, cancel)
    }

    fn create_oci_intent_mode(
        &self,
        intent: OciCreationIntent,
        mounts: Option<crate::VolumeMountSelection>,
        deadline: std::time::Instant,
        cancel: &Cancellation,
    ) -> Result<CreationReceipt> {
        if cancel.is_cancelled() || std::time::Instant::now() >= deadline {
            return Err(Error::before(ErrorCode::State));
        }
        if let Some(mounts) = &mounts {
            mounts.validate(self.binding())?;
        }
        self.validate_oci_intent(&intent)?;
        self.verify_templates()?;
        let source = self.prepare_oci_metadata(intent.source, deadline, cancel.clone())?;
        let request = CreateOciRequest {
            name: intent.name,
            owner_token: intent.owner_token,
            incarnation: intent.incarnation,
            resources: intent.resources,
            labels: intent.labels,
            features: intent.features,
            source,
        };
        match mounts {
            Some(mounts) => {
                let mounts = self.qualify_volume_mounts(
                    &mounts.policy,
                    &mounts.requests,
                    &creation_read_budget(deadline, cancel)?,
                )?;
                self.create_oci_with_volume_mounts(request, mounts, deadline, cancel)
            }
            None => self.create_oci(request, deadline, cancel),
        }
    }

    /// Qualification is bounded source observation, never machine creation.
    pub fn qualify_oci_creation(
        &self,
        source: crate::ImagePullRequest,
        resources: Resources,
        user: Option<&str>,
        features: crate::CreationFeatures,
        deadline: std::time::Instant,
        cancel: &Cancellation,
    ) -> Result<()> {
        if cancel.is_cancelled() || std::time::Instant::now() >= deadline {
            return Err(Error::before(ErrorCode::State));
        }
        resources.validate()?;
        source.validate()?;
        features.validate()?;
        validate_guest_user(user, true)?;
        if source.platform != crate::oci::native_oci_platform() {
            return Err(Error::before(ErrorCode::Unsupported));
        }
        self.verify_templates()?;
        self.prepare_oci_metadata(source, deadline, cancel.clone())?
            .qualify(&features)
    }

    /// Read-only absence for original source intent. It never contacts a
    /// registry, prepares a manager or adopts an existing row/receipt.
    pub fn inspect_oci_creation(
        &self,
        intent: &OciCreationIntent,
        budget: &crate::ReadBudget,
    ) -> Result<CreationPresence> {
        budget.check()?;
        self.validate_oci_intent(intent)?;
        let _job = self.jobs.acquire(crate::jobs::Demand::observation())?;
        let gate = self.observation_gate(&intent.name)?;
        let _guard = gate
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        self.verify_database_identity()?;
        let absent = crate::sdk_compat::observe_absence(
            &self.binding.database,
            self.database_identity,
            &intent.name,
            || self.creation_material_absent(&intent.name),
        )?;
        self.verify_database_identity()?;
        budget.check()?;
        Ok(if absent {
            CreationPresence::Absent
        } else {
            CreationPresence::Unverified
        })
    }
    pub fn open(binding: DomainBinding, allow_initialize: bool) -> Result<Self> {
        // The future bridge configures these once, before creating native worker
        // threads. Without this guard seed preparation could invoke ordinary CLI
        // subcommands, and a debug child could corrupt protocol stdout.
        if std::env::var_os("SMOLVM_IMAGE_SEEDS") != Some("0".into())
            || std::env::var_os("SMOLVM_BOOT_DEBUG").is_some()
            || std::env::var_os("SMOLVM_TEMPLATE_DIR").is_some()
            || !std::env::var_os("SMOLVM_BOOT_BINARY")
                .is_some_and(|p| PathBuf::from(p).is_absolute())
            || std::env::var_os("SMOLVM_DATA_DIR").is_some()
        {
            return Err(Error::before(ErrorCode::Unsupported));
        }
        let domain = DomainGuard::acquire(&binding, allow_initialize)?;
        crate::epoch::fence_previous(&domain.directory, &binding)?;
        let (db, database_identity) = open_database(&binding.database, allow_initialize)?;
        let domain = Arc::new(domain);
        let jobs = crate::jobs::JobPool::default();
        let capture_staging =
            crate::capture_staging::Staging::open(&binding, domain.clone(), jobs.clone())?;
        let export_staging =
            crate::export_staging::Staging::open(&binding, domain.clone(), jobs.clone())?;
        let export_retention = crate::export_retention::Registry::new(domain.clone());
        let branch_retention = crate::branch::retention::Registry::new(domain.clone());
        Ok(Self {
            opened_at: std::time::Instant::now(),
            runtime: Arc::new(EmbeddedRuntime::with_db(db.clone())),
            db,
            database_identity,
            binding,
            gates: Mutex::new(HashMap::new()),
            owned_handles: Mutex::new(BTreeMap::new()),
            capture_sources: Mutex::new(BTreeMap::new()),
            owned_managers: Mutex::new(BTreeMap::new()),
            branch_owners: Mutex::new(BTreeMap::new()),
            runtime_boots: Arc::default(),
            domain,
            transfers: None,
            jobs,
            capture_staging,
            export_staging,
            export_retention,
            branch_retention,
            templates: None,
            export_assets: None,
            host: None,
            boot: None,
        })
    }

    pub fn binding(&self) -> &DomainBinding {
        &self.binding
    }

    pub(crate) fn observation_records(&self, budget: &crate::ReadBudget) -> Result<Vec<VmRecord>> {
        budget.check()?;
        self.domain.verify()?;
        let records = crate::sdk_compat::observe_records(
            &self.binding.database,
            self.database_identity,
            budget,
        )?;
        self.domain.verify()?;
        budget.check()?;
        Ok(records)
    }

    pub(crate) fn observation_record(
        &self,
        name: &str,
        budget: &crate::ReadBudget,
    ) -> Result<Option<VmRecord>> {
        budget.check()?;
        self.domain.verify()?;
        let record = crate::sdk_compat::observe_record(
            &self.binding.database,
            self.database_identity,
            name,
            budget,
        )?;
        self.domain.verify()?;
        budget.check()?;
        Ok(record)
    }

    pub(crate) fn observation_uptime(&self) -> u64 {
        self.opened_at.elapsed().as_secs()
    }
    pub(crate) fn observation_epoch(&self) -> Option<String> {
        self.host.as_ref().map(|host| host.epoch.clone())
    }

    pub(crate) fn observation_missing(&self, receipt: &CreationReceipt) -> Result<Observation> {
        receipt.validate(&self.binding)?;
        let material = match std::fs::symlink_metadata(self.vm_directory(&receipt.name)) {
            Ok(_) => true,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => false,
            Err(_) => return Err(Error::before(ErrorCode::Io)),
        };
        let child = self
            .runtime
            .pid(&receipt.name)
            .is_some_and(smolvm::process::is_alive);
        Ok(Observation {
            state: if material || child {
                ObservedState::IdentityUnknown
            } else {
                ObservedState::Missing
            },
            resources: None,
            pid_identity: None,
            configuration: None,
        })
    }

    /// Prepare under domain ownership. Only the Port child may configure its
    /// environment with this path, before spawning any executor threads. A NIF
    /// needs a public SDK configuration API instead of mutating BEAM environment.
    pub fn prepare_boot_launcher(&mut self) -> Result<PathBuf> {
        if self.boot.is_some() {
            return Err(Error::before(ErrorCode::Conflict));
        }
        let host = self
            .host
            .as_ref()
            .ok_or(Error::before(ErrorCode::Unsupported))?;
        let launcher = host.prepare_boot_launcher(&self.domain.directory)?;
        let actors = crate::epoch::ActorEpoch::new(&launcher, host)?;
        if let Some(transfers) = &mut self.transfers {
            transfers.set_epoch(actors.clone());
        }
        let path = launcher.executable().to_path_buf();
        self.boot = Some((launcher, actors));
        Ok(path)
    }

    pub(crate) fn boot_epoch(&self) -> Result<&crate::epoch::ActorEpoch> {
        let (launcher, actors) = self
            .boot
            .as_ref()
            .ok_or(Error::before(ErrorCode::Unsupported))?;
        if std::env::var_os("SMOLVM_BOOT_BINARY").as_deref()
            != Some(launcher.executable().as_os_str())
            || !actors.available()
        {
            return Err(Error::before(ErrorCode::State));
        }
        Ok(actors)
    }
    /// Cleanup uses the original actor ledger, including after launch admission
    /// was fenced. It grants no new boot or PID-file-derived manager authority.
    pub(crate) fn collection_epoch(&self) -> Result<&crate::epoch::ActorEpoch> {
        self.boot
            .as_ref()
            .map(|(_, actors)| actors)
            .ok_or(Error::before(ErrorCode::Unsupported))
    }

    /// Prepare approved account assets while this engine holds domain ownership,
    /// before a bridge publishes readiness or starts its native executors.
    pub fn prepare_templates(
        &mut self,
        templates: crate::ApprovedTemplates,
        package_sha256: &str,
    ) -> Result<()> {
        if self.templates.is_some() {
            return Err(Error::before(ErrorCode::Conflict));
        }
        self.templates =
            Some(templates.prepare(&self.binding, &self.domain.directory, package_sha256)?);
        Ok(())
    }

    pub(crate) fn verify_templates(&self) -> Result<()> {
        self.templates
            .as_ref()
            .ok_or(Error::before(ErrorCode::Unsupported))?
            .verify()
    }
    pub(crate) fn export_sdk_library(&self) -> Result<PathBuf> {
        self.verify_templates()?;
        let host = self
            .host
            .as_ref()
            .ok_or(Error::before(ErrorCode::Unsupported))?;
        host.validate()?;
        let expected = host
            .executables
            .library_directory
            .canonicalize()
            .map_err(|_| Error::before(ErrorCode::Ownership))?;
        if smolvm::agent::find_lib_dir().as_ref() != Some(&expected) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(expected)
    }
    pub(crate) fn export_manager_rootfs(&self) -> Result<PathBuf> {
        let library = self.export_sdk_library()?;
        self.export_asset_approval()?;
        crate::export_container::package_manager_rootfs(&library)
    }

    /// A bridge verifies its package before supplying generic host context.
    /// Future Rustler uses this same constructor on its bounded native executor.
    pub fn open_with_host(
        binding: DomainBinding,
        allow_initialize: bool,
        host: crate::HostContext,
    ) -> Result<Self> {
        if host.domain != binding {
            return Err(Error::before(ErrorCode::Ownership));
        }
        host.validate()?;
        let mut engine = Self::open(binding, allow_initialize)?;
        let transfers = TransferSupervisor::new(&host, engine.jobs.clone())?;
        engine.transfers = Some(transfers);
        engine.host = Some(host);
        Ok(engine)
    }

    /// Verify the approved pack, resources and qualified user without touching
    /// a VM record, VM directory, handle or lifecycle lock. Cache material is
    /// immutable by digest; create still independently verifies it at dispatch.
    pub fn qualify_creation(
        &self,
        artifact: &ApprovedArtifact,
        resources: Resources,
        user: Option<&str>,
    ) -> Result<()> {
        self.qualify_creation_with_features(artifact, resources, user, None)
    }

    pub fn qualify_creation_with_features(
        &self,
        artifact: &ApprovedArtifact,
        resources: Resources,
        user: Option<&str>,
        features: Option<&crate::CreationFeatures>,
    ) -> Result<()> {
        self.qualify_creation_policy(artifact, resources, user, features.into())
    }

    pub fn qualify_checkpointable_creation(
        &self,
        artifact: &ApprovedArtifact,
        resources: Resources,
        user: Option<&str>,
    ) -> Result<()> {
        self.qualify_branchable_creation(artifact, resources, user, None)
    }

    pub fn qualify_branchable_creation(
        &self,
        artifact: &ApprovedArtifact,
        resources: Resources,
        user: Option<&str>,
        features: Option<&crate::CreationFeatures>,
    ) -> Result<()> {
        self.qualify_creation_policy(
            artifact,
            resources,
            user,
            PackRecordPolicy {
                features,
                checkpointable: true,
            },
        )
    }

    fn qualify_creation_policy(
        &self,
        artifact: &ApprovedArtifact,
        resources: Resources,
        user: Option<&str>,
        policy: PackRecordPolicy<'_>,
    ) -> Result<()> {
        if let Some(features) = policy.features {
            features.validate()?;
        }
        self.verify_templates()?;
        let prepared = artifact.prepare(&self.domain.directory.join("artifacts"), resources)?;
        validate_guest_user(user, prepared.manifest.mode == PackMode::Container)?;
        policy.qualify(&prepared.manifest)?;
        Ok(())
    }

    pub fn create(&self, request: CreateRequest) -> Result<CreationReceipt> {
        self.create_mode(request, false, PackRecordPolicy::default(), None, None)
    }

    /// Fresh protocol-2 authority. An existing v1 receipt is never promoted.
    pub fn create_versioned(&self, request: CreateRequest) -> Result<CreationReceipt> {
        self.create_mode(request, true, PackRecordPolicy::default(), None, None)
    }

    /// Opt-in is part of fresh material before receipt publication. Never
    /// promote an existing non-forkable record from inventory or start output.
    pub fn create_checkpointable(
        &self,
        request: CreateRequest,
        deadline: std::time::Instant,
        cancel: &Cancellation,
    ) -> Result<CreationReceipt> {
        self.create_branchable(request, None, deadline, cancel)
    }

    pub fn create_branchable(
        &self,
        request: CreateRequest,
        features: Option<&crate::CreationFeatures>,
        deadline: std::time::Instant,
        cancel: &Cancellation,
    ) -> Result<CreationReceipt> {
        self.create_mode(
            request,
            true,
            PackRecordPolicy {
                features,
                checkpointable: true,
            },
            None,
            Some((deadline, cancel)),
        )
    }

    pub fn create_with_features(
        &self,
        request: CreateRequest,
        features: crate::CreationFeatures,
    ) -> Result<CreationReceipt> {
        self.create_mode(request, true, Some(&features).into(), None, None)
    }

    /// Mounted fresh local-pack creation. Retains qualified volume gates and
    /// descriptors, binds full proof into material and keeps one absolute budget.
    pub fn create_with_volume_mounts(
        &self,
        request: CreateRequest,
        features: crate::CreationFeatures,
        mounts: crate::QualifiedVolumeMounts,
        deadline: std::time::Instant,
        cancel: &Cancellation,
    ) -> Result<CreationReceipt> {
        self.create_mode(
            request,
            true,
            Some(&features).into(),
            Some(mounts),
            Some((deadline, cancel)),
        )
    }

    fn create_mode(
        &self,
        request: CreateRequest,
        versioned: bool,
        policy: PackRecordPolicy<'_>,
        mut mounts: Option<crate::QualifiedVolumeMounts>,
        budget: Option<(std::time::Instant, &Cancellation)>,
    ) -> Result<CreationReceipt> {
        let check = || {
            if budget.is_some_and(|(deadline, cancel)| {
                cancel.is_cancelled() || std::time::Instant::now() >= deadline
            }) {
                Err(Error::before(ErrorCode::State))
            } else {
                Ok(())
            }
        };
        check()?;
        if budget.is_some_and(|(deadline, _)| {
            deadline.saturating_duration_since(std::time::Instant::now())
                > std::time::Duration::from_secs(86400)
        }) {
            return Err(Error::before(ErrorCode::Validation));
        }
        validate_request(&request)?;
        if let Some(mounts) = &mut mounts {
            let (deadline, cancel) = budget.ok_or(Error::before(ErrorCode::Ownership))?;
            self.promote_creation_mounts(mounts, deadline, cancel)?;
        }
        if let Some(features) = policy.features {
            features.validate()?;
        }
        let gate = self.gate(&request.name)?;
        let _guard = gate
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        self.verify_templates()?;
        let prepared = request
            .artifact
            .prepare(&self.domain.directory.join("artifacts"), request.resources)?;
        policy.qualify(&prepared.manifest)?;
        check()?;
        if self
            .db
            .get_vm(&request.name)
            .map_err(|_| Error::before(ErrorCode::Database))?
            .is_some()
            || match std::fs::symlink_metadata(self.vm_directory(&request.name)) {
                Ok(_) => true,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => false,
                Err(_) => return Err(Error::before(ErrorCode::Io)),
            }
        {
            return Err(Error::before(ErrorCode::Conflict));
        }
        if !self
            .db
            .reserve_vm_create(&request.name, &request.owner_token)
            .map_err(|_| Error::before(ErrorCode::Database))?
        {
            return Err(Error::before(ErrorCode::Conflict));
        }
        // From here on partial storage may exist. Errors are uncertain and
        // cannot authorize reservation release or a replayed create.
        let result = self
            .create_reserved(&request, prepared, policy, None, budget, mounts.as_ref())
            .and_then(|receipt| {
                if versioned && receipt.material.is_none() {
                    crate::material::MaterialJournal::at(&self.vm_directory(&receipt.name))
                        .initialize(&receipt)
                        .map_err(|error| Error::uncertain(error.code))
                } else {
                    Ok(receipt)
                }
            })
            .and_then(|receipt| {
                check().map_err(|error| Error::uncertain(error.code))?;
                Ok(receipt)
            });
        // Releasing the upstream preparation lock is distinct from releasing
        // SmolBox's durable capacity reservation. Never remove partial storage.
        let _ = self
            .db
            .release_vm_create_reservation(&request.name, &request.owner_token);
        result
    }

    fn promote_creation_mounts(
        &self,
        mounts: &mut crate::QualifiedVolumeMounts,
        deadline: std::time::Instant,
        cancel: &Cancellation,
    ) -> Result<()> {
        let budget = creation_read_budget(deadline, cancel)?;
        self.volume_record_mounts(mounts, &budget)?;
        mounts.promote_creation()
    }

    /// Materialize a qualified registry pack under fresh versioned authority.
    /// SDK extraction/disk I/O is owned work and may outlive caller observation;
    /// no expired operation returns success or authorizes replay/absence.
    pub fn create_registry_prepared(
        &self,
        request: CreateRegistryRequest,
        deadline: std::time::Instant,
        cancel: &Cancellation,
    ) -> Result<CreationReceipt> {
        self.create_registry_mode(request, None, deadline, cancel, false)
    }

    pub fn create_registry_checkpointable_prepared(
        &self,
        request: CreateRegistryRequest,
        deadline: std::time::Instant,
        cancel: &Cancellation,
    ) -> Result<CreationReceipt> {
        self.create_registry_mode(request, None, deadline, cancel, true)
    }

    /// Prepared registry creation retains the same qualified mount authority and
    /// composite job lease as local creation; it does not reacquire work capacity.
    pub fn create_registry_with_volume_mounts(
        &self,
        request: CreateRegistryRequest,
        mounts: crate::QualifiedVolumeMounts,
        deadline: std::time::Instant,
        cancel: &Cancellation,
    ) -> Result<CreationReceipt> {
        self.create_registry_mode(request, Some(mounts), deadline, cancel, false)
    }

    fn create_registry_mode(
        &self,
        request: CreateRegistryRequest,
        mut mounts: Option<crate::QualifiedVolumeMounts>,
        deadline: std::time::Instant,
        cancel: &Cancellation,
        checkpointable: bool,
    ) -> Result<CreationReceipt> {
        let check = || {
            if cancel.is_cancelled() || std::time::Instant::now() >= deadline || !self.available() {
                Err(Error::before(ErrorCode::State))
            } else {
                Ok(())
            }
        };
        check()?;
        if deadline.saturating_duration_since(std::time::Instant::now())
            > std::time::Duration::from_secs(86400)
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        let CreateRegistryRequest {
            name,
            owner_token,
            incarnation,
            artifact,
            labels,
            features,
        } = request;
        validate_creation_identity(
            &name,
            &owner_token,
            &incarnation,
            artifact.resources,
            &labels,
        )?;
        artifact.source.validate()?;
        features.validate()?;
        if checkpointable && features.network.enabled {
            return Err(Error::before(ErrorCode::Unsupported));
        }
        let policy = PackRecordPolicy {
            features: Some(&features),
            checkpointable,
        };
        policy.qualify(&artifact.prepared.manifest)?;
        if artifact.prepared.manifest.platform != artifact.source.platform {
            return Err(Error::before(ErrorCode::Validation));
        }
        let _job = if let Some(mounts) = &mut mounts {
            self.promote_creation_mounts(mounts, deadline, cancel)?;
            None
        } else {
            Some(self.jobs.acquire(crate::jobs::Demand::oci_create())?)
        };
        self.domain.verify()?;
        let cache = crate::registry_artifact::RegistryCache::open(&self.domain.directory)?;
        if artifact.prepared.path != cache.path(&artifact.source)
            || !artifact.prepared.verified.covers(&artifact.prepared.path)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let gate = self.gate(&name)?;
        let _guard = gate
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        self.verify_templates()?;
        check()?;
        if self
            .db
            .get_vm(&name)
            .map_err(|_| Error::before(ErrorCode::Database))?
            .is_some()
            || match std::fs::symlink_metadata(self.vm_directory(&name)) {
                Ok(_) => true,
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => false,
                Err(_) => return Err(Error::before(ErrorCode::Io)),
            }
        {
            return Err(Error::before(ErrorCode::Conflict));
        }
        let local = CreateRequest {
            name,
            owner_token,
            incarnation,
            resources: artifact.resources,
            labels,
            artifact: ApprovedArtifact {
                path: artifact.prepared.path.clone(),
                sha256: artifact.source.content_sha256.clone(),
                max_bytes: std::fs::metadata(&artifact.prepared.path)
                    .map_err(|_| Error::before(ErrorCode::Io))?
                    .len(),
                guest_platform: artifact.source.platform.clone(),
            },
        };
        self.domain.verify()?;
        cache.verify()?;
        if !artifact.prepared.verified.covers(&artifact.prepared.path) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        if !self
            .db
            .reserve_vm_create(&local.name, &local.owner_token)
            .map_err(|_| Error::before(ErrorCode::Database))?
        {
            return Err(Error::before(ErrorCode::Conflict));
        }
        let result = (|| {
            check().map_err(|e| Error::uncertain(e.code))?;
            let receipt = self.create_reserved(
                &local,
                artifact.prepared,
                policy,
                Some(&artifact.source.reference),
                Some((deadline, cancel)),
                mounts.as_ref(),
            )?;
            self.domain.verify().map_err(|e| Error::uncertain(e.code))?;
            let receipt = if receipt.material.is_none() {
                crate::material::MaterialJournal::at(&self.vm_directory(&receipt.name))
                    .initialize(&receipt)
                    .map_err(|e| Error::uncertain(e.code))?
            } else {
                receipt
            };
            check().map_err(|e| Error::uncertain(e.code))?;
            Ok(receipt)
        })();
        let _ = self
            .db
            .release_vm_create_reservation(&local.name, &local.owner_token);
        result
    }

    /// Create direct OCI storage/record authority without a pack or seed builder.
    /// This never starts a guest; qualified bounded first-start remains separate.
    pub fn create_oci(
        &self,
        request: CreateOciRequest,
        deadline: std::time::Instant,
        cancel: &Cancellation,
    ) -> Result<CreationReceipt> {
        self.create_oci_mode(request, None, deadline, cancel)
    }

    /// Fresh direct OCI storage creation with retained, proof-bound mounts.
    pub fn create_oci_with_volume_mounts(
        &self,
        request: CreateOciRequest,
        mounts: crate::QualifiedVolumeMounts,
        deadline: std::time::Instant,
        cancel: &Cancellation,
    ) -> Result<CreationReceipt> {
        self.create_oci_mode(request, Some(mounts), deadline, cancel)
    }

    fn create_oci_mode(
        &self,
        request: CreateOciRequest,
        mut mounts: Option<crate::QualifiedVolumeMounts>,
        deadline: std::time::Instant,
        cancel: &Cancellation,
    ) -> Result<CreationReceipt> {
        let check = || {
            if cancel.is_cancelled() || std::time::Instant::now() >= deadline || !self.available() {
                Err(Error::before(ErrorCode::State))
            } else {
                Ok(())
            }
        };
        check()?;
        if deadline.saturating_duration_since(std::time::Instant::now())
            > std::time::Duration::from_secs(86400)
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        validate_creation_identity(
            &request.name,
            &request.owner_token,
            &request.incarnation,
            request.resources,
            &request.labels,
        )?;
        request.source.qualify(&request.features)?;
        let _job = if let Some(mounts) = &mut mounts {
            self.promote_creation_mounts(mounts, deadline, cancel)?;
            None
        } else {
            Some(self.jobs.acquire(crate::jobs::Demand::oci_create())?)
        };
        let gate = self.gate(&request.name)?;
        let _machine = gate
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        self.verify_templates()?;
        check()?;
        if self
            .db
            .get_vm(&request.name)
            .map_err(|_| Error::before(ErrorCode::Database))?
            .is_some()
            || match std::fs::symlink_metadata(self.vm_directory(&request.name)) {
                Ok(_) => true,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => false,
                Err(_) => return Err(Error::before(ErrorCode::Io)),
            }
        {
            return Err(Error::before(ErrorCode::Conflict));
        }
        if !self
            .db
            .reserve_vm_create(&request.name, &request.owner_token)
            .map_err(|_| Error::before(ErrorCode::Database))?
        {
            return Err(Error::before(ErrorCode::Conflict));
        }
        let result = (|| {
            check().map_err(|e| Error::uncertain(e.code))?;
            // Format fresh raw disks before growing them: copying an immutable
            // template onto an already larger disk inherits read-only mode and
            // makes the SDK's format-time expansion fail.
            let manager = AgentManager::for_vm_with_sizes(&request.name, Some(1), Some(1))
                .map_err(|_| Error::uncertain(ErrorCode::Native))?;
            prepare_manager_disks(&manager, || self.verify_templates())?;
            grow_fresh_formatted_disks(
                manager.storage_path(),
                manager.overlay_path(),
                request.resources,
            )?;
            self.verify_templates()
                .map_err(|e| Error::uncertain(e.code))?;
            check().map_err(|e| Error::uncertain(e.code))?;
            let mut labels = request.labels.clone();
            labels.insert("smolbox.owner".into(), request.owner_token.clone());
            labels.insert("smolbox.incarnation".into(), request.incarnation.clone());
            let mut record = request
                .source
                .record(&request.name, request.resources, labels, &request.features)
                .map_err(|e| Error::uncertain(e.code))?;
            let material = if let Some(mounts) = &mounts {
                let budget =
                    creation_read_budget(deadline, cancel).map_err(|e| Error::uncertain(e.code))?;
                Some(
                    self.bind_volume_mount_material(mounts, &mut record, &budget)
                        .map_err(|e| Error::uncertain(e.code))?,
                )
            } else {
                None
            };
            check().map_err(|e| Error::uncertain(e.code))?;
            let receipt = self.commit_created_record(
                &request.name,
                &request.owner_token,
                &request.incarnation,
                &record,
            )?;
            let journal = crate::material::MaterialJournal::at(&self.vm_directory(&receipt.name));
            let receipt = match material {
                Some(material) => journal.initialize_mounted(&receipt, &record, material),
                None => journal.initialize(&receipt),
            }
            .map_err(|e| Error::uncertain(e.code))?;
            check().map_err(|e| Error::uncertain(e.code))?;
            Ok(receipt)
        })();
        // Release only SDK preparation serialization. Uncertain partial creation
        // still retains the caller's durable capacity and cannot authorize replay.
        let _ = self
            .db
            .release_vm_create_reservation(&request.name, &request.owner_token);
        result
    }

    /// Observe a validated original creation intent without preparing its pack,
    /// adopting inventory, reaping reservations or touching VM material. The
    /// controller must quiesce old actors before using absence to release its
    /// durable reservation. A row, stale reservation, storage or local handle
    /// always remains unverified; this cannot return creation authority.
    pub fn inspect_creation(&self, request: &CreateRequest) -> Result<CreationPresence> {
        validate_request(request)?;
        request.artifact.validate()?;
        let gate = self.gate(&request.name)?;
        let _guard = gate
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        self.verify_database_identity()?;
        let absent = crate::sdk_compat::observe_absence(
            &self.binding.database,
            self.database_identity,
            &request.name,
            || self.creation_material_absent(&request.name),
        )?;
        self.verify_database_identity()?;
        Ok(if absent {
            CreationPresence::Absent
        } else {
            CreationPresence::Unverified
        })
    }

    pub(crate) fn verify_database_identity(&self) -> Result<()> {
        self.domain.verify()?;
        if database_identity(&self.binding.database)? != self.database_identity {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }

    pub(crate) fn capture_source_authority(
        &self,
        receipt: &CreationReceipt,
        pid: (i32, u64),
        record: &VmRecord,
    ) -> Result<crate::capture_resolution::SourceAuthority> {
        if !self
            .db
            .dependent_clones(&receipt.name)
            .map_err(|_| Error::before(ErrorCode::Database))?
            .is_empty()
        {
            return Err(Error::before(ErrorCode::State));
        }
        self.source_authority(receipt, pid, record)
    }
    pub(crate) fn branch_source_authority(
        &self,
        receipt: &CreationReceipt,
        pid: (i32, u64),
        record: &VmRecord,
        child: &VmRecord,
        budget: &crate::ReadBudget,
    ) -> Result<crate::capture_resolution::SourceAuthority> {
        if child.golden.as_deref() != Some(receipt.name.as_str()) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let dependents = crate::sdk_compat::source_dependents(
            &self.binding.database,
            self.database_identity,
            &receipt.name,
            budget,
        )?;
        if !dependents.contains(&child.name)
            || !crate::material::MaterialJournal::at(&self.vm_directory(&receipt.name))
                .branch_dependencies(
                    receipt,
                    Some(&child.name),
                    &dependents,
                    &self.binding.database,
                    self.database_identity,
                    budget,
                )?
        {
            return Err(Error::before(ErrorCode::State));
        }
        self.source_authority(receipt, pid, record)
    }
    pub(crate) fn branch_admission_source_authority(
        &self,
        receipt: &CreationReceipt,
        pid: (i32, u64),
        record: &VmRecord,
        joining: Option<&str>,
        budget: &crate::ReadBudget,
    ) -> Result<crate::capture_resolution::SourceAuthority> {
        let dependents = crate::sdk_compat::source_dependents(
            &self.binding.database,
            self.database_identity,
            &receipt.name,
            budget,
        )?;
        if !crate::material::MaterialJournal::at(&self.vm_directory(&receipt.name))
            .branch_dependencies(
                receipt,
                joining,
                &dependents,
                &self.binding.database,
                self.database_identity,
                budget,
            )?
        {
            return Err(Error::before(ErrorCode::State));
        }
        self.source_authority(receipt, pid, record)
    }
    /// The cleanup caller separately owns and qualifies this exact target child.
    /// Other retained siblings still require the ordinary published-head checks.
    /// This dependency filter alone grants no source or child ownership.
    pub(crate) fn branch_disposal_dependencies(
        &self,
        source: &CreationReceipt,
        child: &str,
        budget: &crate::ReadBudget,
    ) -> Result<bool> {
        let others = crate::sdk_compat::source_dependents(
            &self.binding.database,
            self.database_identity,
            &source.name,
            budget,
        )?
        .into_iter()
        .filter(|name| name != child)
        .collect::<Vec<_>>();
        crate::material::MaterialJournal::at(&self.vm_directory(&source.name)).branch_dependencies(
            source,
            None,
            &others,
            &self.binding.database,
            self.database_identity,
            budget,
        )
    }
    pub(crate) fn branch_disposal_source_authority(
        &self,
        source: &CreationReceipt,
        child: &str,
        pid: (i32, u64),
        record: &VmRecord,
        budget: &crate::ReadBudget,
    ) -> Result<crate::capture_resolution::SourceAuthority> {
        if !self.branch_disposal_dependencies(source, child, budget)? {
            return Err(Error::before(ErrorCode::State));
        }
        self.source_authority(source, pid, record)
    }
    fn source_authority(
        &self,
        receipt: &CreationReceipt,
        pid: (i32, u64),
        record: &VmRecord,
    ) -> Result<crate::capture_resolution::SourceAuthority> {
        let name = &receipt.name;
        let owner = self
            .owned_handles
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?
            .get(name)
            .map(|owned| owned == receipt);
        let enrolled = self
            .capture_sources
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?
            .get(name)
            .copied();
        let owner = if record.state == smolvm::config::RecordState::Running {
            owner.map(|owned| owned && enrolled == Some(pid))
        } else if enrolled.is_some() {
            Some(false)
        } else {
            owner
        };
        let excluded = self
            .owned_managers
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?
            .contains_key(name);
        if let Some((_, actors)) = &self.boot {
            let quiescent = if record.state == smolvm::config::RecordState::Running {
                self.runtime_boots
                    .get(receipt)?
                    .ok_or(Error::before(ErrorCode::Ownership))?
                    .source_quiescent(receipt, pid, actors)?
            } else {
                actors.quiescent_for(name)?
            };
            if !quiescent {
                return Err(Error::before(ErrorCode::State));
            }
        }
        crate::capture_resolution::SourceAuthority::verify(
            record,
            pid,
            crate::capture_resolution::SourceFacts {
                owner,
                runtime_pid: self.runtime.pid(name),
                original_alive: smolvm::process::is_alive(pid.0),
                observed_birth: smolvm::process::process_start_time(pid.0),
                excluded,
            },
        )
    }

    pub(crate) fn promote_capture_handle(
        &self,
        previous: &CreationReceipt,
        receipt: &CreationReceipt,
    ) -> Result<()> {
        let mut origin = previous.clone();
        origin.material = None;
        crate::material::check_origin(&origin, receipt)?;
        receipt.validate(self.binding())?;
        let mut handles = self
            .owned_handles
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        if handles.get(&previous.name) != Some(previous) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        handles.insert(receipt.name.clone(), receipt.clone());
        Ok(())
    }
    pub(crate) fn promote_branch_handle(
        &self,
        previous: &CreationReceipt,
        receipt: &CreationReceipt,
    ) -> Result<()> {
        let mut origin = previous.clone();
        origin.material = None;
        crate::material::check_origin(&origin, receipt)?;
        receipt.validate(self.binding())?;
        let mut handles = self
            .owned_handles
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        if handles.get(&previous.name) != Some(previous)
            && handles.get(&previous.name) != Some(receipt)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        handles.insert(receipt.name.clone(), receipt.clone());
        Ok(())
    }
    pub(crate) fn install_original_branch_manager(
        &self,
        receipt: &CreationReceipt,
        context: Arc<crate::branch_owned::Context>,
    ) -> Result<()> {
        let handles = self
            .owned_handles
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        let mut owners = self
            .branch_owners
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        let mut managers = self
            .owned_managers
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        if handles.get(&receipt.name) != Some(receipt)
            || managers
                .get(&receipt.name)
                .is_some_and(|manager| !Arc::ptr_eq(manager, &context.manager))
            || owners.get(&receipt.name).is_some_and(|owner| {
                !Arc::ptr_eq(&owner.enrollment, &context.enrollment)
                    || owner.plan != context.plan
                    || owner.identity_sha256 != context.identity_sha256
            })
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        managers.insert(receipt.name.clone(), context.manager.clone());
        owners.insert(receipt.name.clone(), context);
        Ok(())
    }
    /// Map/cache exclusion only, never original boot or collection authority.
    /// SDK runtime.pid falls back to the persisted row, so its PID cannot
    /// distinguish an original pre-handoff manager from a runtime-owned handle.
    pub(crate) fn require_unhanded_branch_child(&self, name: &str) -> Result<()> {
        self.unhanded_branch_handles(name, None).map(drop)
    }
    /// Original boot registers its receipt for graceful shutdown before SDK
    /// entry. That tracking is not lifecycle handoff. Only the retained boot's
    /// exact publication may tolerate it; all runtime handoff maps still refuse.
    pub(crate) fn require_original_branch_handle(&self, receipt: &CreationReceipt) -> Result<()> {
        self.unhanded_branch_handles(&receipt.name, Some(receipt))
            .map(drop)
    }
    /// Called only after original enrolled collection and its protected proof.
    /// Forget shutdown tracking, never a manager, actor, SDK row or disk.
    pub(crate) fn retire_collected_branch_handle(&self, receipt: &CreationReceipt) -> Result<()> {
        self.unhanded_branch_handles(&receipt.name, Some(receipt))?
            .remove(&receipt.name);
        Ok(())
    }
    fn unhanded_branch_handles(
        &self,
        name: &str,
        original: Option<&CreationReceipt>,
    ) -> Result<std::sync::MutexGuard<'_, BTreeMap<String, CreationReceipt>>> {
        let handles = self
            .owned_handles
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let owners = self
            .branch_owners
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let managers = self
            .owned_managers
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        if handles
            .get(name)
            .is_some_and(|actual| Some(actual) != original)
            || owners.contains_key(name)
            || managers.contains_key(name)
            || self.runtime_boots.try_contains(name)?
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(handles)
    }
    pub(crate) fn branch_child_unstarted(&self, name: &str) -> Result<()> {
        if self.runtime.pid(name).is_some()
            || self
                .owned_handles
                .lock()
                .map_err(|_| Error::before(ErrorCode::Native))?
                .contains_key(name)
            || self
                .owned_managers
                .lock()
                .map_err(|_| Error::before(ErrorCode::Native))?
                .contains_key(name)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        if let Some((_, actors)) = &self.boot {
            if !actors.quiescent_for(name)? {
                return Err(Error::before(ErrorCode::State));
            }
        }
        Ok(())
    }

    pub(crate) fn recover_capture_handle(
        &self,
        transition: &crate::CaptureResolutionTransition,
    ) -> Result<()> {
        let original = self
            .owned_handles
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?
            .get(&transition.previous.name)
            .is_some_and(|owned| owned == &transition.previous);
        if original {
            let record = self.record(&transition.receipt)?;
            let authority = self.capture_source_authority(
                &transition.previous,
                transition.change.intent.source_pid,
                &record,
            )?;
            if !authority.running() {
                return Err(Error::before(ErrorCode::Ownership));
            }
            self.promote_capture_handle(&transition.previous, &transition.receipt)?;
        }
        Ok(())
    }

    pub(crate) fn creation_material_absent(&self, name: &str) -> Result<bool> {
        if let Some((_, actors)) = &self.boot {
            if !actors.quiescent_for(name)? {
                return Ok(false);
            }
        }
        if self
            .owned_handles
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?
            .contains_key(name)
            || self.runtime.pid(name).is_some()
        {
            return Ok(false);
        }
        // A redirected/non-directory ancestor cannot establish absence in the
        // enrolled data domain. Do not create a missing cache root to inspect it.
        for path in self
            .binding
            .vm_root
            .ancestors()
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
        {
            match std::fs::symlink_metadata(path) {
                Ok(metadata) if metadata.is_dir() => {}
                Ok(_) => return Err(Error::before(ErrorCode::Ownership)),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(true),
                Err(_) => return Err(Error::before(ErrorCode::Io)),
            }
        }
        match std::fs::symlink_metadata(self.vm_directory(name)) {
            Ok(_) => Ok(false),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(true),
            Err(_) => Err(Error::before(ErrorCode::Io)),
        }
    }

    fn create_reserved(
        &self,
        request: &CreateRequest,
        prepared: crate::artifact::PreparedArtifact,
        policy: PackRecordPolicy<'_>,
        registry_reference: Option<&str>,
        budget: Option<(std::time::Instant, &Cancellation)>,
        mounts: Option<&crate::QualifiedVolumeMounts>,
    ) -> Result<CreationReceipt> {
        let check = || {
            if budget.is_some_and(|(deadline, cancel)| {
                cancel.is_cancelled() || std::time::Instant::now() >= deadline
            }) {
                Err(Error::uncertain(ErrorCode::State))
            } else {
                Ok(())
            }
        };
        check()?;
        if !prepared.verified.covers(&prepared.path) {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        // Container packs use the immutable account templates; format at the
        // baseline before growth. VM packs retain their original seeded geometry
        // and existing public SDK seeding path.
        let (initial_storage, initial_overlay) = match prepared.manifest.mode {
            PackMode::Container => (1, 1),
            PackMode::Vm => (request.resources.storage_gib, request.resources.overlay_gib),
        };
        let manager = AgentManager::for_vm_with_sizes(
            &request.name,
            Some(initial_storage),
            Some(initial_overlay),
        )
        .map_err(|_| Error::uncertain(ErrorCode::Native))?;
        smolvm::portable_checkpoint::materialize_pack_layers(&request.name, &prepared.path)
            .map_err(|_| Error::uncertain(ErrorCode::Native))?;
        check()?;
        let layers = smolvm::agent::machine_layers_cache_dir(&request.name);
        smolvm_pack::extract::force_detach_layers_volume(&layers);
        if prepared.manifest.mode == PackMode::Vm {
            let contents = smolvm::agent::read_shared_pack_pointer(&layers).unwrap_or(layers);
            let assets = &prepared.manifest.assets;
            smolvm::storage::seed_vm_mode_disks(
                manager
                    .storage_path()
                    .parent()
                    .ok_or(Error::uncertain(ErrorCode::Native))?,
                &contents,
                smolvm::storage::VmModeDiskSeedSpec {
                    artifact_sha256: Some(&request.artifact.sha256),
                    overlay_template: assets.overlay_template.as_ref().map(|a| a.path.as_str()),
                    storage_template: assets.storage_template.as_ref().map(|a| a.path.as_str()),
                    overlay_logical_size: assets.overlay_logical_size,
                    storage_logical_size: assets.storage_logical_size,
                    overlay_gb: Some(request.resources.overlay_gib),
                    storage_gb: Some(request.resources.storage_gib),
                },
            )
            .map_err(|_| Error::uncertain(ErrorCode::Native))?;
        }
        // VM pack seeding can replace the manager's initial raw disks with
        // qcow2 overlays. Resolve existing paths again without creation.
        let seeded =
            AgentManager::for_vm(&request.name).map_err(|_| Error::uncertain(ErrorCode::Native))?;
        prepare_manager_disks(&seeded, || self.verify_templates())?;
        if prepared.manifest.mode == PackMode::Container {
            grow_fresh_formatted_disks(
                seeded.storage_path(),
                seeded.overlay_path(),
                request.resources,
            )?;
        }
        check()?;
        if !prepared.verified.covers(&prepared.path) {
            return Err(Error::uncertain(ErrorCode::Validation));
        }
        let mut record = prepared_pack_record(request, &prepared, policy, registry_reference)?;
        let material = if let Some(mounts) = mounts {
            let (deadline, cancel) = budget.ok_or(Error::uncertain(ErrorCode::Ownership))?;
            let read_budget = crate::ReadBudget::new(
                deadline
                    .saturating_duration_since(std::time::Instant::now())
                    .min(std::time::Duration::from_secs(30)),
                cancel.clone(),
            )
            .map_err(|error| Error::uncertain(error.code))?;
            Some(
                self.bind_volume_mount_material(mounts, &mut record, &read_budget)
                    .map_err(|error| Error::uncertain(error.code))?,
            )
        } else {
            None
        };
        check()?;
        let receipt = self.commit_created_record(
            &request.name,
            &request.owner_token,
            &request.incarnation,
            &record,
        )?;
        if let Some(material) = material {
            crate::material::MaterialJournal::at(&self.vm_directory(&receipt.name))
                .initialize_mounted(&receipt, &record, material)
                .map_err(|error| Error::uncertain(error.code))
        } else {
            Ok(receipt)
        }
    }

    pub(crate) fn commit_created_record(
        &self,
        name: &str,
        owner_token: &str,
        incarnation: &str,
        record: &VmRecord,
    ) -> Result<CreationReceipt> {
        if record.name != name
            || record.labels.get("smolbox.owner").map(String::as_str) != Some(owner_token)
            || record.labels.get("smolbox.incarnation").map(String::as_str) != Some(incarnation)
        {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        let receipt = CreationReceipt {
            target_id: self.binding.target_id.clone(),
            domain_generation: self.binding.generation.clone(),
            name: name.into(),
            owner_token: owner_token.into(),
            incarnation: incarnation.into(),
            material_sha256: material_hash(record)
                .map_err(|_| Error::uncertain(ErrorCode::Native))?,
            material: None,
        };
        write_marker(&receipt, &self.vm_directory(name))?;
        if !self
            .db
            .commit_reserved_vm(name, owner_token, record)
            .map_err(|_| Error::uncertain(ErrorCode::Database))?
        {
            return Err(Error::uncertain(ErrorCode::Conflict));
        }
        Ok(receipt)
    }

    /// Receipt-bound direct OCI origin preflight. Never infer authority from
    /// current image inventory, a packed image string, labels or a request alone.
    pub fn qualify_image_pull(
        &self,
        receipt: &CreationReceipt,
        request: &crate::ImagePullRequest,
    ) -> Result<()> {
        let budget =
            crate::ReadBudget::new(std::time::Duration::from_secs(30), Cancellation::new())?;
        self.qualified_pull_record(receipt, request, &budget)
            .map(|_| ())
    }

    pub(crate) fn qualified_pull_record(
        &self,
        receipt: &CreationReceipt,
        request: &crate::ImagePullRequest,
        budget: &crate::ReadBudget,
    ) -> Result<VmRecord> {
        receipt.validate(&self.binding)?;
        request.validate()?;
        if request.platform != crate::oci::native_oci_platform() || receipt.material.is_none() {
            return Err(Error::before(ErrorCode::Unsupported));
        }
        let record = self
            .observation_record(&receipt.name, budget)?
            .ok_or(Error::before(ErrorCode::State))?;
        self.verify_record(receipt, &record)?;
        if record.source_smolmachine.is_some() || !record.network {
            return Err(Error::before(ErrorCode::Unsupported));
        }
        let origin = crate::ImagePullRequest {
            reference: record
                .image
                .clone()
                .ok_or(Error::before(ErrorCode::Unsupported))?,
            platform: request.platform.clone(),
        };
        origin
            .validate()
            .map_err(|_| Error::before(ErrorCode::Unsupported))?;
        let features = crate::CreationFeatures {
            network: crate::NetworkPolicy {
                enabled: true,
                hosts: record
                    .dns_filter_hosts
                    .clone()
                    .ok_or(Error::before(ErrorCode::Unsupported))?,
                cidrs: record
                    .allowed_cidrs
                    .clone()
                    .ok_or(Error::before(ErrorCode::Unsupported))?,
            },
            ports: record
                .ports
                .iter()
                .map(|&(host, guest)| crate::PortMapping { host, guest })
                .collect(),
            workload: None,
        };
        features.validate()?;
        budget.check()?;
        Ok(record)
    }

    /// Read-only: no connect-or-start, materializing manager or inventory adoption.
    pub fn inspect(&self, receipt: &CreationReceipt) -> Result<Observation> {
        self.inspect_under(
            receipt,
            &crate::ReadBudget::new(std::time::Duration::from_secs(30), Cancellation::default())?,
        )
    }
    pub(crate) fn inspect_under(
        &self,
        receipt: &CreationReceipt,
        budget: &crate::ReadBudget,
    ) -> Result<Observation> {
        self.inspect_mode(receipt, budget, true)
    }

    fn inspect_mode(
        &self,
        receipt: &CreationReceipt,
        budget: &crate::ReadBudget,
        probe_agent: bool,
    ) -> Result<Observation> {
        budget.check()?;
        self.verify_database_identity()?;
        receipt.validate(&self.binding)?;
        let Some(record) = self
            .db
            .get_vm(&receipt.name)
            .map_err(|_| Error::before(ErrorCode::Database))?
        else {
            // A missing DB row does not establish disposal if partial storage or
            // a locally owned handle survives. Never turn that into capacity
            // release evidence or recreate the retained machine.
            let storage_present = match std::fs::symlink_metadata(self.vm_directory(&receipt.name))
            {
                Ok(_) => true,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => false,
                Err(_) => return Err(Error::before(ErrorCode::Io)),
            };
            let child_present = self
                .runtime_pid(&receipt.name)
                .is_some_and(smolvm::process::is_alive)
                || self.owned_manager_busy(&receipt.name)?;
            budget.check()?;
            return Ok(Observation {
                state: if storage_present || child_present {
                    ObservedState::IdentityUnknown
                } else {
                    ObservedState::Missing
                },
                resources: None,
                pid_identity: None,
                configuration: None,
            });
        };
        self.verify_record(receipt, &record)?;
        let dependents = self
            .db
            .dependent_clones(&receipt.name)
            .map_err(|_| Error::before(ErrorCode::Database))?;
        budget.check()?;
        let checkpoint_budget = budget;
        let directory = self.vm_directory(&receipt.name);
        let continuing = !dependents.is_empty()
            && self.original_continuing_source(receipt, &record)?
            && crate::material::MaterialJournal::at(&directory).continuing_branch_children(
                receipt,
                &dependents,
                &self.binding.database,
                self.database_identity,
                checkpoint_budget,
            )?;
        let mut state = record_state(&record, !dependents.is_empty() && !continuing);
        let uncertain =
            if crate::material::MaterialJournal::at(&directory).branch_child(receipt, &record)? {
                crate::branch_boot::Lifecycle::at(&directory).uncertain(receipt)?
            } else {
                crate::checkpoint_lifecycle::Lifecycle::at(&directory).uncertain(
                    receipt,
                    &record,
                    checkpoint_budget,
                )?
            };
        if uncertain {
            state = ObservedState::IdentityUnknown;
        }
        if self.owned_manager_busy(&receipt.name)?
            || self.runtime_pid(&receipt.name).is_some_and(|pid| {
                smolvm::process::is_alive(pid)
                    && (record.pid != Some(pid) || state != ObservedState::Running)
            })
        {
            state = ObservedState::IdentityUnknown;
        }
        if !probe_agent
            && state == ObservedState::Running
            && record.state != smolvm::config::RecordState::Running
        {
            state = ObservedState::IdentityUnknown;
        }
        if state == ObservedState::Running && probe_agent {
            budget.check()?;
            let socket = self.vm_directory(&receipt.name).join("agent.sock");
            if AgentClient::connect_for_state_probe(socket)
                .and_then(|mut client| client.ping())
                .is_err()
            {
                state = ObservedState::Unreachable;
            }
            // The PID may disappear/change while the bounded agent probe runs.
            if record_state(&record, false) != ObservedState::Running {
                state = ObservedState::IdentityUnknown;
            }
        }
        budget.check()?;
        Ok(Observation {
            state,
            configuration: crate::MachineConfiguration::observe(&record),
            resources: Some(Resources {
                cpus: record.cpus,
                memory_mib: record.mem,
                storage_gib: record
                    .storage_gb
                    .ok_or(Error::before(ErrorCode::Ownership))?,
                overlay_gib: record
                    .overlay_gb
                    .ok_or(Error::before(ErrorCode::Ownership))?,
            }),
            pid_identity: if state == ObservedState::Running {
                record.pid.zip(record.pid_start_time)
            } else {
                None
            },
        })
    }

    pub(crate) fn verify_record(&self, receipt: &CreationReceipt, record: &VmRecord) -> Result<()> {
        if !receipt.matches(record)? || !marker_matches(receipt, &self.vm_directory(&receipt.name))?
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let journal = crate::material::MaterialJournal::at(&self.vm_directory(&receipt.name));
        journal.verify(receipt)?;
        journal.verify_mount_record(receipt, record)?;
        journal.verify_branch_child(receipt, record)?;
        Ok(())
    }

    /// Bounded compatibility entry; growth is still unavailable on the public
    /// helper protocol until reservation/history and qualification gates pass.
    pub fn expand_disks(
        &self,
        receipt: &CreationReceipt,
        operation_id: &str,
        request: crate::GrowDisks,
    ) -> Result<CreationReceipt> {
        self.expand_disks_owned(
            receipt,
            operation_id,
            request,
            std::time::Instant::now() + std::time::Duration::from_secs(30),
            &Cancellation::new(),
        )
    }

    /// Parent-only journal/database authority. An unresolved exact child retains
    /// machine, source, domain, geometry and job leases without mutation replay.
    pub fn expand_disks_owned(
        &self,
        receipt: &CreationReceipt,
        operation_id: &str,
        request: crate::GrowDisks,
        deadline: std::time::Instant,
        cancel: &Cancellation,
    ) -> Result<CreationReceipt> {
        if std::time::Instant::now() >= deadline || cancel.is_cancelled() {
            return Err(Error::before(ErrorCode::State));
        }
        if receipt.material.is_none() {
            return Err(Error::before(ErrorCode::Unsupported));
        }
        let gate = self.gate(&receipt.name)?;
        let machine = gate
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let observation = self.inspect(receipt)?;
        if observation.state != ObservedState::Stopped {
            return Err(Error::before(ErrorCode::State));
        }
        self.verify_lifecycle_preconditions(receipt, &observation)?;
        // expand_disk does not acquire the machine lifecycle/source flock.
        let source = self.source_lease(receipt)?;
        let before = self.record(receipt)?;
        let (storage_gib, overlay_gib) = request.targets(&before)?;
        let supervisor = self
            .transfers
            .as_ref()
            .ok_or(Error::before(ErrorCode::Unsupported))?;
        // Geometry/table reads are part of the owned growth job, not free
        // preparation outside admission. Move this same lease into Prepared.
        let geometry_job = supervisor.reserve_growth()?;
        let geometry_budget = crate::ReadBudget::new(
            deadline
                .saturating_duration_since(std::time::Instant::now())
                .min(std::time::Duration::from_secs(30)),
            cancel.clone(),
        )?;
        let directory = self.vm_directory(&receipt.name);
        let storage = Arc::new(crate::disk_geometry::DiskGeometry::capture_with_budget(
            &directory,
            smolvm::storage::STORAGE_DISK_FILENAME,
            before
                .storage_gb
                .ok_or(Error::before(ErrorCode::Ownership))?,
            &geometry_budget,
        )?);
        let overlay = Arc::new(crate::disk_geometry::DiskGeometry::capture_with_budget(
            &directory,
            smolvm::storage::OVERLAY_DISK_FILENAME,
            before
                .overlay_gb
                .ok_or(Error::before(ErrorCode::Ownership))?,
            &geometry_budget,
        )?);
        let metadata = crate::growth::Metadata::new(&storage, &overlay, request);
        let bytes =
            serde_json::to_vec(&metadata).map_err(|_| Error::before(ErrorCode::Validation))?;
        let expected = crate::growth::GrowthProof {
            storage_gib,
            overlay_gib,
        };
        let prepared = supervisor.prepare_growth_reserved(
            geometry_job,
            &self.transfer_directory()?,
            directory.join("agent.sock"),
            &bytes,
            expected,
        )?;
        if std::time::Instant::now() >= deadline || cancel.is_cancelled() {
            return Err(Error::before(ErrorCode::State));
        }
        let journal = crate::material::MaterialJournal::at(&self.vm_directory(&receipt.name));
        let permit =
            journal.prepare_geometry(receipt, operation_id, request, &before, &metadata)?;
        journal.enter(&permit)?;
        // Failures leave the entered journal and reservations unresolved. No
        // SDK mutation is retried, and a partial geometry is never authorized.
        (|| {
            let result = supervisor
                .run(
                    prepared,
                    Box::new((
                        machine,
                        source,
                        self.domain.clone(),
                        storage.clone(),
                        overlay.clone(),
                    )),
                    deadline,
                    cancel,
                )
                .map_err(|error| Error::uncertain(error.code))?;
            let crate::transfer_supervisor::RunResult::Collected(collected) = result else {
                return Err(Error::uncertain(ErrorCode::Native));
            };
            if collected.outcome.completion != crate::FileCompletion::Completed
                || !collected.outcome.native_acknowledged
                || collected.grown != Some(expected)
            {
                return Err(Error::uncertain(ErrorCode::Native));
            }
            collected.prepared.spool.verify()?;
            if collected
                .prepared
                .spool
                .file
                .metadata()
                .map_err(|_| Error::uncertain(ErrorCode::Io))?
                .len()
                != 0
            {
                return Err(Error::uncertain(ErrorCode::Ownership));
            }
            let remaining = crate::ReadBudget::new(
                deadline
                    .saturating_duration_since(std::time::Instant::now())
                    .min(std::time::Duration::from_secs(30)),
                cancel.clone(),
            )
            .map_err(|error| Error::uncertain(error.code))?;
            storage.verify_after_with_budget(storage_gib, &remaining)?;
            overlay.verify_after_with_budget(overlay_gib, &remaining)?;
            self.verify_database_identity()
                .map_err(|error| Error::uncertain(error.code))?;
            self.db
                .update_vm(&receipt.name, |record| {
                    if let Some(size) = request.storage_gib {
                        record.storage_gb = Some(size);
                    }
                    if let Some(size) = request.overlay_gib {
                        record.overlay_gb = Some(size);
                    }
                })
                .map_err(|_| Error::uncertain(ErrorCode::Database))?;
            let after = self
                .db
                .get_vm(&receipt.name)
                .map_err(|_| Error::uncertain(ErrorCode::Database))?
                .ok_or(Error::uncertain(ErrorCode::Ownership))?;
            if !marker_matches(receipt, &directory).map_err(|error| Error::uncertain(error.code))? {
                return Err(Error::uncertain(ErrorCode::Ownership));
            }
            let receipt = journal.complete(receipt, &permit, &after)?;
            drop(collected);
            Ok(receipt)
        })()
    }

    /// Pure local observation of already recorded correlated success. Missing
    /// or entered-only evidence cannot supply a replacement receipt.
    pub fn inspect_disk_transition(
        &self,
        receipt: &CreationReceipt,
        operation_id: &str,
        request: crate::GrowDisks,
    ) -> Result<Option<CreationReceipt>> {
        receipt.validate(&self.binding)?;
        let gate = self.gate(&receipt.name)?;
        let _guard = gate
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        self.verify_database_identity()?;
        if !marker_matches(receipt, &self.vm_directory(&receipt.name))? {
            return Err(Error::before(ErrorCode::Ownership));
        }
        crate::material::MaterialJournal::at(&self.vm_directory(&receipt.name)).completed(
            receipt,
            operation_id,
            request,
        )
    }

    /// Completed proof for the bridge/store to persist with its expansion ID.
    /// A missing proof after SDK entry remains uncertainty, never inventory
    /// adoption or another attempt to perform the growth.
    pub fn expand_disks_transition_owned(
        &self,
        receipt: &CreationReceipt,
        operation_id: &str,
        request: crate::GrowDisks,
        deadline: std::time::Instant,
        cancel: &Cancellation,
    ) -> Result<crate::GrowthTransition> {
        let completed =
            self.expand_disks_owned(receipt, operation_id, request, deadline, cancel)?;
        let budget = crate::ReadBudget::new(
            deadline
                .saturating_duration_since(std::time::Instant::now())
                .min(std::time::Duration::from_secs(30)),
            cancel.clone(),
        )
        .map_err(|error| Error::uncertain(error.code))?;
        let transition = self
            .inspect_growth_transition_with_budget(receipt, operation_id, request, &budget)
            .map_err(|error| Error::uncertain(error.code))?
            .ok_or(Error::uncertain(ErrorCode::Ownership))?;
        if completed != transition.receipt {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        Ok(transition)
    }

    /// Explicit operator qualification after external quiescence and repair.
    /// Does not resize disks, update SDK rows, boot, stop, signal or replay work.
    /// Only the already entered journal's original geometry can authorize its
    /// engine proof. Retained gates/quarantine still fence this operation.
    pub fn qualify_growth(
        &self,
        receipt: &CreationReceipt,
        operation_id: &str,
        request: crate::GrowDisks,
        previous: (u64, u64),
        quiesced: bool,
        budget: &crate::ReadBudget,
    ) -> Result<crate::GrowthTransition> {
        budget.check()?;
        if !quiesced {
            return Err(Error::before(ErrorCode::Validation));
        }
        receipt.validate(&self.binding)?;
        let gate = self.gate(&receipt.name)?;
        let _machine = gate
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let _job = self.jobs.acquire(crate::jobs::Demand::growth_repair())?;
        let _source = self.source_lease(receipt)?;
        self.verify_database_identity()?;
        let directory = self.vm_directory(&receipt.name);
        if !marker_matches(receipt, &directory)? {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let journal = crate::material::MaterialJournal::at(&directory);
        if let Some(transition) = journal.completed_transition(receipt, operation_id, request)? {
            if previous
                != (
                    transition.change.previous_storage_gib,
                    transition.change.previous_overlay_gib,
                )
            {
                return Err(Error::before(ErrorCode::Ownership));
            }
            if self.inspect(&transition.receipt)?.state != ObservedState::Stopped {
                return Err(Error::before(ErrorCode::State));
            }
            budget.check()?;
            return Ok(transition);
        }
        let permit = journal.recovery_permit(receipt, operation_id, request)?;
        if crate::material::MaterialJournal::previous_sizes(&permit) != previous {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let record = self
            .db
            .get_vm(&receipt.name)
            .map_err(|_| Error::before(ErrorCode::Database))?
            .ok_or(Error::before(ErrorCode::Ownership))?;
        let dependents = self
            .db
            .dependent_clones(&receipt.name)
            .map_err(|_| Error::before(ErrorCode::Database))?;
        if !dependents.is_empty()
            || record.pid.is_some()
            || record.pid_start_time.is_some()
            || !matches!(
                record.state,
                smolvm::config::RecordState::Created | smolvm::config::RecordState::Stopped
            )
            || record.paused_checkpoint.is_some()
            || self.runtime.pid(&receipt.name).is_some()
        {
            return Err(Error::before(ErrorCode::State));
        }
        let _geometry = journal.verify_recovery(&permit, &record, budget)?;
        budget.check()?;
        self.verify_database_identity()?;
        let current = self
            .db
            .get_vm(&receipt.name)
            .map_err(|_| Error::before(ErrorCode::Database))?
            .ok_or(Error::before(ErrorCode::Ownership))?;
        if serde_json::to_value(&current).map_err(|_| Error::before(ErrorCode::Native))?
            != serde_json::to_value(&record).map_err(|_| Error::before(ErrorCode::Native))?
            || !marker_matches(receipt, &directory)?
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let updated = journal.complete_repaired(receipt, &permit, &current)?;
        budget
            .check()
            .map_err(|error| Error::uncertain(error.code))?;
        let transition = journal
            .completed_transition(receipt, operation_id, request)
            .map_err(|error| Error::uncertain(error.code))?
            .ok_or(Error::uncertain(ErrorCode::Ownership))?;
        if transition.receipt != updated {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        budget
            .check()
            .map_err(|error| Error::uncertain(error.code))?;
        Ok(transition)
    }

    pub fn inspect_growth_transition(
        &self,
        receipt: &CreationReceipt,
        operation_id: &str,
        request: crate::GrowDisks,
    ) -> Result<Option<crate::GrowthTransition>> {
        let budget =
            crate::ReadBudget::new(std::time::Duration::from_secs(30), Cancellation::new())?;
        self.inspect_growth_transition_with_budget(receipt, operation_id, request, &budget)
    }

    pub fn inspect_growth_transition_with_budget(
        &self,
        receipt: &CreationReceipt,
        operation_id: &str,
        request: crate::GrowDisks,
        budget: &crate::ReadBudget,
    ) -> Result<Option<crate::GrowthTransition>> {
        budget.check()?;
        let _job = self.jobs.acquire(crate::jobs::Demand::observation())?;
        receipt.validate(&self.binding)?;
        // Journal observation is read-only and can remain available while work
        // is quarantined, but it shares the exact retained machine gate.
        let gate = self.observation_gate(&receipt.name)?;
        let _guard = gate
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        self.verify_database_identity()?;
        if !marker_matches(receipt, &self.vm_directory(&receipt.name))? {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let result = crate::material::MaterialJournal::at(&self.vm_directory(&receipt.name))
            .completed_transition(receipt, operation_id, request)?;
        budget.check()?;
        Ok(result)
    }

    pub fn start(&self, receipt: &CreationReceipt) -> Result<Observation> {
        self.start_mode(receipt, None, None)
    }

    /// Only originally authenticated forkable material is eligible. The SDK's
    /// ordinary start already honors it without rewriting the record's policy.
    pub fn start_checkpointable(
        &self,
        receipt: &CreationReceipt,
        deadline: std::time::Instant,
        cancel: &Cancellation,
    ) -> Result<Observation> {
        let budget = crate::ReadBudget::for_checkpoint_work(
            deadline.saturating_duration_since(std::time::Instant::now()),
            cancel.clone(),
        )?;
        budget.check()?;
        let record = self.record(receipt)?;
        crate::checkpoint_capture::validate_record(&record)?;
        if !record.forkable {
            return Err(Error::before(ErrorCode::Unsupported));
        }
        self.start_mode(receipt, None, Some((deadline, cancel)))
    }

    /// Read-only source qualification, not an assertion that guest work is idle.
    /// No caller can obtain capture authority from an inventory row or agent ping.
    pub fn checkpoint_preflight(
        &self,
        receipt: &CreationReceipt,
        budget: &crate::ReadBudget,
    ) -> Result<Observation> {
        budget.check()?;
        let _permit = self.jobs.acquire(crate::jobs::Demand::observation())?;
        let gate = self.observation_gate(&receipt.name)?;
        let _guard = gate
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let observed = self.inspect(receipt)?;
        if observed.state != ObservedState::Running {
            return Err(Error::before(ErrorCode::State));
        }
        let record = self.record(receipt)?;
        crate::checkpoint_capture::validate_portable_record(&record)?;
        if !record.forkable {
            return Err(Error::before(ErrorCode::Unsupported));
        }
        self.verify_templates()?;
        self.verify_lifecycle_preconditions(receipt, &observed)?;
        let (pid, birth) = observed
            .pid_identity
            .ok_or(Error::before(ErrorCode::Ownership))?;
        self.capture_source_authority(receipt, (pid, birth), &record)?;
        if self.runtime.pid(&receipt.name) != Some(pid)
            || !smolvm::process::is_alive(pid)
            || smolvm::process::process_start_time(pid) != Some(birth)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        budget.check()?;
        Ok(observed)
    }

    /// Select saved mount proof only after receipt verification and against the
    /// bridge's current operator policy; a record path cannot grant admission.
    pub fn start_with_volume_policy(
        &self,
        receipt: &CreationReceipt,
        policy: &crate::LocalVolumePolicy,
        deadline: std::time::Instant,
        cancel: &Cancellation,
    ) -> Result<Observation> {
        let budget = creation_read_budget(deadline, cancel)?;
        budget.check()?;
        let record = self.record(receipt)?;
        let journal = crate::material::MaterialJournal::at(&self.vm_directory(&receipt.name));
        match journal.mount_material(receipt, &record)? {
            Some(material) => {
                let mounts = self.qualify_volume_mounts(policy, &material.mounts, &budget)?;
                self.start_with_volume_mounts(receipt, mounts, deadline, cancel)
            }
            None => self.start_mode(receipt, None, Some((deadline, cancel))),
        }
    }

    /// Start an authenticated mounted pack while retaining qualified backing
    /// descriptors and volume gates through SDK launch and final observation.
    pub fn start_with_volume_mounts(
        &self,
        receipt: &CreationReceipt,
        mounts: crate::QualifiedVolumeMounts,
        deadline: std::time::Instant,
        cancel: &Cancellation,
    ) -> Result<Observation> {
        self.start_mode(receipt, Some(mounts), Some((deadline, cancel)))
    }

    fn start_mode(
        &self,
        receipt: &CreationReceipt,
        mut mounts: Option<crate::QualifiedVolumeMounts>,
        budget: Option<(std::time::Instant, &Cancellation)>,
    ) -> Result<Observation> {
        // Capture the fallback before any preflight/SDK work. Readiness never
        // grants another budget after the original one-shot boot returns.
        let fallback = Cancellation::default();
        let (deadline, cancel) = budget.unwrap_or((
            std::time::Instant::now() + std::time::Duration::from_secs(30),
            &fallback,
        ));
        let check = || {
            if cancel.is_cancelled() || std::time::Instant::now() >= deadline {
                Err(Error::before(ErrorCode::State))
            } else {
                Ok(())
            }
        };
        check()?;
        if deadline.saturating_duration_since(std::time::Instant::now())
            > std::time::Duration::from_secs(86400)
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        // The SDK convenience start couples application rejection to VM stop.
        // Packed image boot uses our enrolled manager and a bounded one-shot
        // launch worker instead; bare/checkpoint starts retain their own path.
        let record = self.record(receipt)?;
        if record.source_smolmachine.is_some() && record.image.is_some() {
            return self.start_packed_owned(receipt, mounts, deadline, cancel.clone());
        }
        if let Some(mounts) = &mut mounts {
            self.volume_record_mounts(mounts, &creation_read_budget(deadline, cancel)?)?;
            mounts.promote_start()?;
        }
        let gate = self.gate(&receipt.name)?;
        let _guard = gate
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let expected = self.inspect(receipt)?;
        match expected.state {
            ObservedState::Stopped => {}
            _ => return Err(Error::before(ErrorCode::State)),
        }
        let record = self.record(receipt)?;
        reject_unqualified_oci_boot(&record)?;
        match &mounts {
            Some(mounts) => {
                self.verify_machine_mounts(
                    receipt,
                    &record,
                    mounts,
                    &creation_read_budget(deadline, cancel)?,
                )?;
            }
            None if record.mounts.is_empty() && record.staged_mounts.is_empty() => {}
            None => return Err(Error::before(ErrorCode::Ownership)),
        }
        self.verify_templates()?;
        let boot = self.boot_epoch()?;
        self.verify_lifecycle_preconditions(receipt, &expected)?;
        if let Some(mounts) = &mounts {
            self.verify_machine_mounts(
                receipt,
                &self.record(receipt)?,
                mounts,
                &creation_read_budget(deadline, cancel)?,
            )?;
        }
        if let Some(owned) = self.runtime_boots.get(receipt)? {
            let cleanup = creation_read_budget(deadline, cancel)?;
            self.stop_runtime_boot(receipt, &expected, &owned, &cleanup)?;
            self.finish_stop_result(receipt, &cleanup, self.inspect_under(receipt, &cleanup))?;
        }
        let record = self.record(receipt)?;
        let lifecycle =
            crate::checkpoint_lifecycle::Lifecycle::at(&self.vm_directory(&receipt.name));
        let checkpoint_budget = crate::ReadBudget::for_checkpoint_work(
            deadline.saturating_duration_since(std::time::Instant::now()),
            cancel.clone(),
        )?;
        let checkpoint_start =
            if crate::material::MaterialJournal::at(&self.vm_directory(&receipt.name))
                .branch_child(receipt, &record)?
            {
                crate::branch_boot::Lifecycle::at(&self.vm_directory(&receipt.name))
                    .require_regular_restart(receipt)?;
                None
            } else {
                lifecycle.prepare(receipt, &record, &checkpoint_budget)?
            };
        check()?;
        // Mounted startup already holds the promoted work budget through
        // readiness. Unmounted startup reserves its relay here.
        let _readiness = if mounts.is_none() {
            Some(self.jobs.acquire(crate::jobs::Demand::branch_probe())?)
        } else {
            None
        };
        let owned_boot = self.runtime_boots.reserve(receipt, &self.jobs)?;
        self.track_handle(receipt)?;
        if let Err(error) = check() {
            self.runtime_boots.retire(&owned_boot)?;
            return Err(error);
        }
        let dispatch = match boot.begin_boot(&receipt.name) {
            Ok(dispatch) => dispatch,
            Err(error) => {
                self.runtime_boots.retire(&owned_boot)?;
                return Err(error);
            }
        };
        let checkpoint_start = match checkpoint_start {
            Some(permit) => {
                let mut nonce = [0; 16];
                getrandom::fill(&mut nonce).map_err(|_| Error::before(ErrorCode::Native))?;
                Some(lifecycle.enter(permit, &hex::encode(nonce), &checkpoint_budget)?)
            }
            None => None,
        };
        let result = self.runtime.start_machine(&receipt.name);
        let enrollment = dispatch
            .finish_enrollment(self.runtime.pid(&receipt.name))
            .map_err(|error| Error::uncertain(error.code))?;
        owned_boot.enroll(enrollment, boot)?;
        result.map_err(|error| Error::uncertain(crate::sdk_compat::launch_error(&error)))?;
        if record.forkable {
            let running = self
                .record(receipt)
                .map_err(|error| Error::uncertain(error.code))?;
            let pid = running
                .pid
                .zip(running.pid_start_time)
                .ok_or(Error::uncertain(ErrorCode::Ownership))?;
            if running.state != smolvm::config::RecordState::Running
                || self.runtime.pid(&receipt.name) != Some(pid.0)
                || !smolvm::process::is_alive(pid.0)
                || smolvm::process::process_start_time(pid.0) != Some(pid.1)
            {
                return Err(Error::uncertain(ErrorCode::Ownership));
            }
            self.capture_sources
                .lock()
                .map_err(|_| Error::uncertain(ErrorCode::Native))?
                .insert(receipt.name.clone(), pid);
        }
        check().map_err(|error| Error::uncertain(error.code))?;
        let directory = self.vm_directory(&receipt.name);
        if let Some(permit) = checkpoint_start {
            let restored_record = || {
                check().map_err(|error| Error::uncertain(error.code))?;
                let record = self
                    .record(receipt)
                    .map_err(|error| Error::uncertain(error.code))?;
                owned_boot
                    .verify_before(receipt, &record)
                    .map_err(|error| Error::uncertain(error.code))?;
                let pid = record
                    .pid
                    .zip(record.pid_start_time)
                    .ok_or(Error::uncertain(ErrorCode::Ownership))?;
                if record.state != smolvm::config::RecordState::Running
                    || self.runtime.pid(&receipt.name) != Some(pid.0)
                    || smolvm::process::process_start_time(pid.0) != Some(pid.1)
                    || !smolvm::process::is_alive(pid.0)
                {
                    return Err(Error::uncertain(ErrorCode::Ownership));
                }
                Ok((record, pid))
            };
            restored_record()?;
            // Keep the restore Entered until the enrolled guest proves timer
            // progress. An expired probe cannot enable cold fallback or replay.
            crate::branch_agent::checkpoint_timer_probe(
                &directory.join("agent.sock"),
                &directory,
                &checkpoint_budget,
            )?;
            let (record, pid) = restored_record()?;
            lifecycle.complete(permit, receipt, &record, pid, &checkpoint_budget)?;
        }
        let readiness = crate::ReadBudget {
            deadline,
            cancel: cancel.clone(),
        };
        crate::runtime_boot::wait_until_ready(
            &readiness,
            || {
                let observation = self.inspect_mode(receipt, &readiness, false)?;
                owned_boot.verify_running(
                    receipt,
                    &observation,
                    self.runtime.pid(&receipt.name),
                )?;
                Ok(observation)
            },
            |attempt| {
                crate::branch_agent::boot_probe(&directory.join("agent.sock"), &directory, attempt)
            },
        )
    }

    pub fn stop(&self, receipt: &CreationReceipt) -> Result<Observation> {
        self.stop_with_budget(
            receipt,
            &crate::ReadBudget::new(std::time::Duration::from_secs(30), Cancellation::default())?,
        )
    }
    /// One caller deadline/cancellation token covers preflight, SDK collection
    /// and final observation. Late SDK return never grants a stopped result.
    pub fn stop_with_budget(
        &self,
        receipt: &CreationReceipt,
        budget: &crate::ReadBudget,
    ) -> Result<Observation> {
        budget.check()?;
        if budget
            .deadline
            .saturating_duration_since(std::time::Instant::now())
            > std::time::Duration::from_secs(30)
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        let gate = self.gate(&receipt.name)?;
        let _guard = gate
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        if self.record(receipt)?.forkpoint_held {
            return Err(Error::before(ErrorCode::State));
        }
        let mut expected = self.inspect_under(receipt, budget)?;
        if expected.state == ObservedState::IdentityUnknown {
            if self.stop_entered_capture(receipt, budget)? {
                return self
                    .inspect_under(receipt, budget)
                    .map_err(|e| Error::uncertain(e.code));
            }
            let record = self.record(receipt)?;
            let entered = record.labels.contains_key("smolbox.checkpoint-sha256")
                && crate::checkpoint_lifecycle::Lifecycle::at(&self.vm_directory(&receipt.name))
                    .uncertain(receipt, &record, budget)?;
            let tracked = self
                .owned_handles
                .lock()
                .map_err(|_| Error::before(ErrorCode::Native))?
                .get(&receipt.name)
                .is_some_and(|owned| owned == receipt);
            let pid = record.pid.zip(record.pid_start_time);
            if entered
                && tracked
                && record_state(&record, false) == ObservedState::Running
                && pid.is_some_and(|(pid, birth)| {
                    self.runtime.pid(&receipt.name) == Some(pid)
                        && smolvm::process::process_start_time(pid) == Some(birth)
                        && smolvm::process::is_alive(pid)
                })
            {
                // Normal stop of this engine's already enrolled VMM is allowed.
                // It does not resolve/replay the entered restore or free storage.
                expected.state = ObservedState::Running;
                expected.pid_identity = pid;
            }
        }
        match expected.state {
            ObservedState::Stopped => {
                // An owned SDK manager may retain an ordinarily exited child
                // and its launch flock. Explicit stop performs normal cleanup;
                // an absent manager needs no SDK mutation.
                if !self
                    .owned_managers
                    .lock()
                    .map_err(|_| Error::before(ErrorCode::Native))?
                    .contains_key(&receipt.name)
                    && !self.runtime_boots.contains(&receipt.name)?
                {
                    return self.inspect_under(receipt, budget);
                }
            }
            ObservedState::Running => {}
            _ => return Err(Error::before(ErrorCode::State)),
        }
        let original = self
            .branch_owners
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?
            .get(&receipt.name)
            .cloned();
        budget.check()?;
        if let Some(context) = original {
            self.stop_original_branch(receipt, &expected, &context, budget)?;
        } else if let Some(owned) = self.runtime_boots.get(receipt)? {
            self.stop_runtime_boot(receipt, &expected, &owned, budget)?;
        } else {
            self.verify_lifecycle_preconditions(receipt, &expected)?;
            let manager = self
                .owned_managers
                .lock()
                .map_err(|_| Error::before(ErrorCode::Native))?
                .get(&receipt.name)
                .cloned();
            if let Some(manager) = manager {
                // Direct manager stop does not take the SDK source flock.
                let _source = self.source_lease(receipt)?;
                let manager = manager
                    .try_lock()
                    .map_err(|_| Error::before(ErrorCode::Conflict))?;
                self.coordinated_lifecycle(receipt, &expected, budget, || {
                    manager.stop()?;
                    self.db
                        .update_vm(&receipt.name, |row| {
                            row.state = smolvm::config::RecordState::Stopped;
                            row.pid = None;
                            row.pid_start_time = None;
                        })?
                        .ok_or_else(|| smolvm::Error::vm_not_found(&receipt.name))?;
                    Ok(())
                })?;
            } else {
                self.coordinated_lifecycle(receipt, &expected, budget, || {
                    self.runtime.stop_machine(&receipt.name)
                })?;
            }
        }
        self.finish_stop_result(receipt, budget, self.inspect_under(receipt, budget))
    }
    fn finish_stop_result(
        &self,
        receipt: &CreationReceipt,
        budget: &crate::ReadBudget,
        result: Result<Observation>,
    ) -> Result<Observation> {
        let observation = result.map_err(|e| Error::uncertain(e.code))?;
        budget.check().map_err(|e| Error::uncertain(e.code))?;
        if observation.state == ObservedState::Stopped {
            let owned = self
                .runtime_boots
                .get(receipt)
                .map_err(|e| Error::uncertain(e.code))?;
            if let Some(owned) = &owned {
                owned
                    .collected(
                        receipt,
                        self.collection_epoch()
                            .map_err(|e| Error::uncertain(e.code))?,
                        budget,
                    )
                    .map_err(|e| Error::uncertain(e.code))?;
            }
            budget.check().map_err(|e| Error::uncertain(e.code))?;
            self.owned_managers
                .lock()
                .map_err(|_| Error::uncertain(ErrorCode::Native))?
                .remove(&receipt.name);
            self.branch_owners
                .lock()
                .map_err(|_| Error::uncertain(ErrorCode::Native))?
                .remove(&receipt.name);
            self.owned_handles
                .lock()
                .map_err(|_| Error::uncertain(ErrorCode::Native))?
                .remove(&receipt.name);
            self.capture_sources
                .lock()
                .map_err(|_| Error::uncertain(ErrorCode::Native))?
                .remove(&receipt.name);
            if let Some(owned) = owned {
                self.runtime_boots
                    .retire(&owned)
                    .map_err(|e| Error::uncertain(e.code))?;
            }
        }
        budget.check().map_err(|e| Error::uncertain(e.code))?;
        Ok(observation)
    }

    pub fn delete(&self, receipt: &CreationReceipt) -> Result<Observation> {
        self.delete_with_budget(
            receipt,
            &crate::ReadBudget::new(std::time::Duration::from_secs(30), Cancellation::default())?,
        )
    }

    pub fn delete_with_budget(
        &self,
        receipt: &CreationReceipt,
        budget: &crate::ReadBudget,
    ) -> Result<Observation> {
        budget.check()?;
        receipt.validate(self.binding())?;
        let original = self
            .branch_owners
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?
            .get(&receipt.name)
            .cloned();
        if let Some(original) = original {
            if original.plan.publication.child() == receipt
                && original
                    .plan
                    .publication
                    .change
                    .child_origin
                    .intent
                    .child
                    .hold
            {
                return self.delete_held_branch(receipt, budget);
            }
            return self.delete_released_branch(receipt, budget);
        }
        if self.retained_released_deletion_head(receipt, budget)? {
            return self.delete_released_branch(receipt, budget);
        }
        let gate = self.gate(&receipt.name)?;
        let _guard = gate
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        // Delete only an observed stopped incarnation, never kill an unreachable
        // or unknown PID through the upstream recovery convenience path.
        let expected = self.inspect(receipt)?;
        match expected.state {
            ObservedState::Missing => {
                if let Some(owned) = self.runtime_boots.get(receipt)? {
                    owned.collected(receipt, self.collection_epoch()?, budget)?;
                    self.runtime_boots.retire(&owned)?;
                    self.owned_handles
                        .lock()
                        .map_err(|_| Error::before(ErrorCode::Native))?
                        .remove(&receipt.name);
                }
                return self.inspect(receipt);
            }
            ObservedState::Stopped => {}
            _ => return Err(Error::before(ErrorCode::State)),
        }
        // SDK deletion derives its storage path from the process cache root,
        // independently of the supplied DB. Never enter it for another root,
        // including synthetic DB-only fixtures or a changed process environment.
        if smolvm::agent::vm_data_dir(&receipt.name) != self.vm_directory(&receipt.name) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        self.authorize_capture_staging_deletion(receipt, budget)?;
        self.verify_lifecycle_preconditions(receipt, &expected)?;
        budget.check()?;
        if let Some(owned) = self.runtime_boots.get(receipt)? {
            owned.verify_before(receipt, &self.record(receipt)?)?;
            owned.call(
                receipt,
                self.collection_epoch()?,
                self.runtime.pid(&receipt.name),
                budget,
                || {
                    self.runtime
                        .delete_machine(&receipt.name)
                        .map_err(|_| Error::uncertain(ErrorCode::Native))
                },
            )?;
        } else {
            self.runtime
                .delete_machine(&receipt.name)
                .map_err(|_| Error::uncertain(ErrorCode::Native))?;
        }
        let observation = self
            .inspect(receipt)
            .map_err(|error| Error::uncertain(error.code))?;
        if observation.state == ObservedState::Missing {
            if let Some(owned) = self.runtime_boots.get(receipt)? {
                self.runtime_boots.retire(&owned)?;
            }
            self.owned_managers
                .lock()
                .map_err(|_| Error::uncertain(ErrorCode::Native))?
                .remove(&receipt.name);
            self.owned_handles
                .lock()
                .map_err(|_| Error::uncertain(ErrorCode::Native))?
                .remove(&receipt.name);
            self.capture_sources
                .lock()
                .map_err(|_| Error::uncertain(ErrorCode::Native))?
                .remove(&receipt.name);
        }
        Ok(observation)
    }

    fn stop_entered_capture(
        &self,
        receipt: &CreationReceipt,
        budget: &crate::ReadBudget,
    ) -> Result<bool> {
        budget.check()?;
        if receipt.material.is_none() {
            return Ok(false);
        }
        let journal = crate::material::MaterialJournal::at(&self.vm_directory(&receipt.name));
        let record = self
            .db
            .get_vm(&receipt.name)
            .map_err(|_| Error::before(ErrorCode::Database))?
            .ok_or(Error::before(ErrorCode::NotFound))?;
        if !journal.entered_capture_source(receipt, &record)? {
            return Ok(false);
        }
        let tracked = self
            .owned_handles
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?
            .get(&receipt.name)
            .is_some_and(|owned| owned == receipt);
        let pid = record
            .pid
            .zip(record.pid_start_time)
            .ok_or(Error::before(ErrorCode::Ownership))?;
        self.capture_source_authority(receipt, pid, &record)?;
        if !tracked
            || self.runtime.pid(&receipt.name) != Some(pid.0)
            || !smolvm::process::is_alive(pid.0)
            || smolvm::process::process_start_time(pid.0) != Some(pid.1)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        self.verify_database_identity()?;
        let current = self
            .db
            .get_vm(&receipt.name)
            .map_err(|_| Error::before(ErrorCode::Database))?
            .ok_or(Error::before(ErrorCode::NotFound))?;
        if !journal.entered_capture_source(receipt, &current)?
            || current.pid.zip(current.pid_start_time) != Some(pid)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        if let Some(owned) = self.runtime_boots.get(receipt)? {
            owned.call(
                receipt,
                self.collection_epoch()?,
                self.runtime.pid(&receipt.name),
                budget,
                || {
                    self.runtime
                        .stop_machine(&receipt.name)
                        .map_err(|_| Error::uncertain(ErrorCode::Native))
                },
            )?;
        } else {
            lifecycle_sdk_call(budget, || self.runtime.stop_machine(&receipt.name))?;
        }
        let after = self
            .db
            .get_vm(&receipt.name)
            .map_err(|_| Error::uncertain(ErrorCode::Database))?
            .ok_or(Error::uncertain(ErrorCode::NotFound))?;
        if after.state != smolvm::config::RecordState::Stopped
            || after.pid.is_some()
            || self.runtime.pid(&receipt.name).is_some()
        {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        budget.check().map_err(|e| Error::uncertain(e.code))?;
        if let Some(owned) = self.runtime_boots.get(receipt)? {
            self.runtime_boots.retire(&owned)?;
        }
        self.owned_handles
            .lock()
            .map_err(|_| Error::uncertain(ErrorCode::Native))?
            .remove(&receipt.name);
        self.capture_sources
            .lock()
            .map_err(|_| Error::uncertain(ErrorCode::Native))?
            .remove(&receipt.name);
        // The entered capture and unknown material remain fenced after collection.
        Ok(true)
    }

    fn coordinated_lifecycle(
        &self,
        receipt: &CreationReceipt,
        expected: &Observation,
        budget: &crate::ReadBudget,
        action: impl FnOnce() -> smolvm::Result<()>,
    ) -> Result<()> {
        budget.check()?;
        self.verify_lifecycle_preconditions(receipt, expected)?;
        lifecycle_sdk_call(budget, action)
    }

    pub(crate) fn verify_lifecycle_preconditions(
        &self,
        receipt: &CreationReceipt,
        expected: &Observation,
    ) -> Result<()> {
        // Caller holds the SmolBox gate. The ordinary SDK takes its own source
        // lock; never hold an outer source flock here (it would self-contend).
        // This contract covers cooperating callers, not independent SDK writers.
        self.verify_database_identity()?;
        let record = self.record(receipt)?;
        if record.forkpoint_held {
            return Err(Error::before(ErrorCode::State));
        }
        let dependents = self
            .db
            .dependent_clones(&receipt.name)
            .map_err(|_| Error::before(ErrorCode::Database))?;
        if record_state(&record, !dependents.is_empty()) != expected.state
            || (expected.state == ObservedState::Running
                && record.pid.zip(record.pid_start_time) != expected.pid_identity)
            || self
                .runtime_pid(&receipt.name)
                .is_some_and(|pid| smolvm::process::is_alive(pid) && record.pid != Some(pid))
        {
            return Err(Error::before(ErrorCode::State));
        }
        Ok(())
    }

    pub fn exec_with_volume_policy(
        &self,
        receipt: &CreationReceipt,
        command: Command,
        cancel: Cancellation,
        consumer: impl FnMut(Output) -> std::result::Result<(), ()>,
        policy: &crate::LocalVolumePolicy,
    ) -> Result<CommandOutcome> {
        let record = self.record(receipt)?;
        if record.mounts.is_empty() {
            self.exec(receipt, command, cancel, consumer)
        } else {
            self.exec_stream_owned_with_volume_policy(
                receipt,
                crate::BufferedCommand {
                    argv: command.argv,
                    env: command.env.into_iter().collect(),
                    workdir: command.workdir,
                    user: command.user,
                    stdin: None,
                    timeout: command.timeout,
                    max_output_bytes: command.max_output_bytes,
                },
                cancel,
                consumer,
                policy,
            )
        }
    }

    pub fn exec(
        &self,
        receipt: &CreationReceipt,
        command: Command,
        cancel: Cancellation,
        mut consumer: impl FnMut(Output) -> std::result::Result<(), ()>,
    ) -> Result<CommandOutcome> {
        receipt.validate(&self.binding)?;
        let record = self
            .db
            .get_vm(&receipt.name)
            .map_err(|_| Error::before(ErrorCode::Database))?
            .ok_or(Error::before(ErrorCode::State))?;
        self.verify_record(receipt, &record)?;
        if !record.mounts.is_empty() || !record.staged_mounts.is_empty() {
            return Err(Error::before(ErrorCode::Ownership));
        }
        command.validate(record.image.is_some())?;
        if record.forkpoint_held {
            return Err(Error::before(ErrorCode::State));
        }
        let direct_manager = self
            .owned_managers
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?
            .contains_key(&receipt.name);
        if direct_manager {
            return self.exec_stream_owned(
                receipt,
                crate::BufferedCommand {
                    argv: command.argv,
                    env: command.env.into_iter().collect(),
                    workdir: command.workdir,
                    user: command.user,
                    stdin: None,
                    timeout: command.timeout,
                    max_output_bytes: command.max_output_bytes,
                },
                cancel,
                consumer,
            );
        }
        let _job = self.jobs.acquire(crate::jobs::Demand::streaming())?;
        let gate = self.gate(&receipt.name)?;
        let _guard = gate
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let _source_lease = self.source_lease(receipt)?;
        if self.inspect(receipt)?.state != ObservedState::Running {
            return Err(Error::before(ErrorCode::State));
        }
        if cancel.is_cancelled() {
            return Ok(Collector::new(command.max_output_bytes).finish(true, true, false));
        }
        self.verify_templates()?;
        // Reconnect is explicit execution preparation, never observational
        // inspection; this API cannot start a stopped machine.
        self.track_handle(receipt)?;
        self.runtime
            .connect_machine(&receipt.name)
            .map_err(|_| Error::before(ErrorCode::Native))?;
        let deadline = Deadline::start(command.timeout, cancel.clone());
        let mut collector = Collector::new(command.max_output_bytes);
        collector.mark_dispatch();
        let result = self.runtime.exec_streaming_with_options(
            &receipt.name,
            command.argv.clone(),
            command.options(),
            &cancel.exec,
            |event| collector.event(event, &cancel, &mut consumer),
        );
        let expired = deadline.finish();
        Ok(collector.finish(result.is_ok(), cancel.is_cancelled(), expired))
    }

    /// Graceful owner-bound shutdown never enumerates shared inventory or
    /// deletes storage. Failure is explicit; it does not confirm termination.
    pub fn shutdown(&self) -> Vec<(String, Result<Observation>)> {
        let receipts = self
            .owned_handles
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .values()
            .cloned()
            .collect::<Vec<_>>();
        let mut outcomes: Vec<_> = receipts
            .iter()
            .map(|receipt| (receipt.name.clone(), self.stop(receipt)))
            .collect();
        smolvm::process::reap_vm_children();
        if let Some((_, actors)) = &self.boot {
            if let Err(error) = actors.close() {
                outcomes.push(("epoch".into(), Err(error)));
            }
        }
        outcomes
    }

    pub(crate) fn track_handle(&self, receipt: &CreationReceipt) -> Result<()> {
        self.owned_handles
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?
            .insert(receipt.name.clone(), receipt.clone());
        Ok(())
    }

    pub(crate) fn gate(&self, name: &str) -> Result<Arc<MachineGate>> {
        if !self.available() {
            return Err(Error::before(ErrorCode::State));
        }
        self.observation_gate(name)
    }

    /// Read-only callers share the same machine lock even when work admission
    /// is quarantined. A retained mutation still conflicts on that exact lock.
    pub(crate) fn observation_gate(&self, name: &str) -> Result<Arc<MachineGate>> {
        self.domain.verify()?;
        let mut gates = self
            .gates
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        gates.retain(|_, gate| gate.strong_count() > 0);
        if let Some(gate) = gates.get(name).and_then(Weak::upgrade) {
            return Ok(gate);
        }
        let gate = Arc::new(MachineGate::default());
        gates.insert(name.into(), Arc::downgrade(&gate));
        Ok(gate)
    }

    /// Admission state only; never process termination or guest result evidence.
    /// A future bridge observes the same state while owned collectors stay alive.
    pub fn available(&self) -> bool {
        self.jobs.available()
            && self
                .boot
                .as_ref()
                .is_none_or(|(_, actors)| actors.available())
            && self
                .transfers
                .as_ref()
                .is_none_or(|transfers| transfers.available())
    }

    pub(crate) fn registry_account_enabled(&self) -> bool {
        // Verified host contexts opt into the actual account's operator setup.
        // Receipt-free model engines never inspect the caller's credentials.
        self.host.is_some()
    }

    pub(crate) fn source_lease(
        &self,
        receipt: &CreationReceipt,
    ) -> Result<crate::sdk_compat::SourceLease> {
        receipt.validate(&self.binding)?;
        crate::sdk_compat::source_lease(&self.binding.vm_root, &receipt.name)
    }

    pub(crate) fn vm_directory(&self, name: &str) -> PathBuf {
        self.binding.vm_root.join(smolvm::agent::vm_dir_hash(name))
    }

    pub(crate) fn owned_manager_busy(&self, name: &str) -> Result<bool> {
        let handles = self
            .owned_managers
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        Ok(handles
            .get(name)
            .is_some_and(|manager| manager.try_lock().is_err()))
    }

    pub(crate) fn register_image_boot(
        &self,
        receipt: &CreationReceipt,
        manager: Arc<Mutex<AgentManager>>,
    ) -> Result<Arc<crate::runtime_boot::Owned>> {
        let mut handles = self
            .owned_handles
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        let mut managers = self
            .owned_managers
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        if handles.contains_key(&receipt.name) || managers.contains_key(&receipt.name) {
            return Err(Error::before(ErrorCode::Conflict));
        }
        let owned = self.runtime_boots.reserve(receipt, &self.jobs)?;
        handles.insert(receipt.name.clone(), receipt.clone());
        managers.insert(receipt.name.clone(), manager);
        Ok(owned)
    }

    // Caller must first close BootEntry while still unentered. That shared
    // fence prevents the detached worker from entering after retirement.
    pub(crate) fn retire_unentered_image_boot(
        &self,
        receipt: &CreationReceipt,
        manager: &Arc<Mutex<AgentManager>>,
        owned: &Arc<crate::runtime_boot::Owned>,
    ) -> Result<()> {
        let mut handles = self
            .owned_handles
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        let mut managers = self
            .owned_managers
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        if handles.get(&receipt.name) != Some(receipt)
            || !managers
                .get(&receipt.name)
                .is_some_and(|current| Arc::ptr_eq(current, manager))
            || manager
                .try_lock()
                .map_err(|_| Error::before(ErrorCode::Conflict))?
                .child_pid()
                .is_some()
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        self.runtime_boots.retire(owned)?;
        handles.remove(&receipt.name);
        managers.remove(&receipt.name);
        Ok(())
    }

    pub(crate) fn runtime_pid(&self, name: &str) -> Option<i32> {
        self.owned_managers
            .lock()
            .ok()
            .and_then(|handles| handles.get(name)?.try_lock().ok()?.child_pid())
            .or_else(|| self.runtime.pid(name))
    }

    pub(crate) fn record(&self, receipt: &CreationReceipt) -> Result<VmRecord> {
        self.verify_database_identity()?;
        receipt.validate(&self.binding)?;
        let record = self
            .db
            .get_vm(&receipt.name)
            .map_err(|_| Error::before(ErrorCode::Database))?
            .ok_or(Error::before(ErrorCode::State))?;
        self.verify_record(receipt, &record)?;
        Ok(record)
    }
    pub(crate) fn guest_work_record(&self, receipt: &CreationReceipt) -> Result<VmRecord> {
        let record = self.record(receipt)?;
        if record.forkpoint_held {
            return Err(Error::before(ErrorCode::State));
        }
        Ok(record)
    }
    pub(crate) fn original_continuing_source(
        &self,
        receipt: &CreationReceipt,
        record: &VmRecord,
    ) -> Result<bool> {
        let owned = self
            .owned_handles
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?
            .get(&receipt.name)
            == Some(receipt);
        let pid = self
            .capture_sources
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?
            .get(&receipt.name)
            .copied();
        Ok(owned
            && pid.is_some_and(|identity| {
                record.pid.zip(record.pid_start_time) == Some(identity)
                    && self.runtime.pid(&receipt.name) == Some(identity.0)
                    && smolvm::process::process_start_time(identity.0) == Some(identity.1)
                    && record_state(record, false) == ObservedState::Running
            }))
    }
    pub(crate) fn retained_branch_context(
        &self,
        receipt: &CreationReceipt,
    ) -> Result<Arc<crate::branch_owned::Context>> {
        receipt.validate(self.binding())?;
        self.domain.verify()?;
        let cached = self
            .branch_owners
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?
            .get(&receipt.name)
            .cloned();
        let context = match cached {
            Some(context) => Some(context),
            None => self.branch_retention.completed_context(receipt)?,
        }
        .ok_or(Error::before(ErrorCode::Ownership))?;
        let mut origin = context.plan.publication.child().clone();
        origin.material = None;
        crate::material::check_origin(&origin, receipt)?;
        if !Arc::ptr_eq(&context._domain, &self.domain)
            || !Arc::ptr_eq(&context._runtime, &self.runtime)
            || !Arc::ptr_eq(&context.runtime_boots, &self.runtime_boots)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(context)
    }
    pub(crate) fn original_branch_manager(
        &self,
        receipt: &CreationReceipt,
        context: &Arc<crate::branch_owned::Context>,
    ) -> Result<()> {
        context.require_no_runtime_boot()?;
        if self
            .owned_handles
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?
            .get(&receipt.name)
            != Some(receipt)
            || !self
                .branch_owners
                .lock()
                .map_err(|_| Error::before(ErrorCode::Native))?
                .get(&receipt.name)
                .is_some_and(|owner| Arc::ptr_eq(owner, context))
            || !self
                .owned_managers
                .lock()
                .map_err(|_| Error::before(ErrorCode::Native))?
                .get(&receipt.name)
                .is_some_and(|manager| Arc::ptr_eq(manager, &context.manager))
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
    /// A retired original manager cannot borrow a current runtime/handle owner.
    /// Keep this map order consistent with branch installation/retirement.
    pub(crate) fn require_no_active_branch_handles(&self, receipt: &CreationReceipt) -> Result<()> {
        let handles = self
            .owned_handles
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        let owners = self
            .branch_owners
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        let managers = self
            .owned_managers
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        if handles.contains_key(&receipt.name)
            || self.runtime_boots.contains(&receipt.name)?
            || owners.contains_key(&receipt.name)
            || managers.contains_key(&receipt.name)
            || self.runtime.pid(&receipt.name).is_some()
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
    pub(crate) fn retire_deleted_branch_handle(
        &self,
        receipt: &CreationReceipt,
        context: &Arc<crate::branch_owned::Context>,
    ) -> Result<()> {
        let mut handles = self
            .owned_handles
            .lock()
            .map_err(|_| Error::uncertain(ErrorCode::Native))?;
        let mut owners = self
            .branch_owners
            .lock()
            .map_err(|_| Error::uncertain(ErrorCode::Native))?;
        let mut managers = self
            .owned_managers
            .lock()
            .map_err(|_| Error::uncertain(ErrorCode::Native))?;
        if handles
            .get(&receipt.name)
            .is_some_and(|actual| actual != receipt)
            || owners
                .get(&receipt.name)
                .is_some_and(|actual| !Arc::ptr_eq(actual, context))
            || managers
                .get(&receipt.name)
                .is_some_and(|actual| !Arc::ptr_eq(actual, &context.manager))
        {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        handles.remove(&receipt.name);
        owners.remove(&receipt.name);
        managers.remove(&receipt.name);
        Ok(())
    }
    pub(crate) fn recover_branch_release_handle(
        &self,
        release: &crate::BranchReleaseTransition,
    ) -> Result<()> {
        release.validate()?;
        let mut handles = self
            .owned_handles
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        match handles.get(&release.previous.name) {
            Some(current) if current == &release.previous => {
                handles.insert(release.receipt.name.clone(), release.receipt.clone());
            }
            Some(current) if current == &release.receipt => {}
            None => {} // Historical result never re-enrolls a stopped/deleted handle.
            Some(_) => return Err(Error::before(ErrorCode::Ownership)),
        }
        Ok(())
    }

    pub(crate) fn transfer_directory(&self) -> Result<PathBuf> {
        let path = self.domain.directory.join("transfers");
        crate::transfer_supervisor::prepare_directory(&path)?;
        Ok(path)
    }
}

fn prepared_pack_record(
    request: &CreateRequest,
    prepared: &crate::artifact::PreparedArtifact,
    policy: PackRecordPolicy<'_>,
    registry_reference: Option<&str>,
) -> Result<VmRecord> {
    let mut labels = request.labels.clone();
    labels.insert("smolbox.owner".into(), request.owner_token.clone());
    labels.insert("smolbox.incarnation".into(), request.incarnation.clone());
    let mut record = MachineSpec {
        name: request.name.clone(),
        persistent: true,
        labels,
        resources: VmResources {
            cpus: request.resources.cpus,
            memory_mib: request.resources.memory_mib,
            storage_gib: Some(request.resources.storage_gib),
            overlay_gib: Some(request.resources.overlay_gib),
            network: false,
            ..VmResources::default()
        },
        image: (prepared.manifest.mode == PackMode::Container)
            .then(|| prepared.manifest.image.clone()),
        ..MachineSpec::default()
    }
    .to_record()
    .map_err(|_| Error::uncertain(ErrorCode::Validation))?;
    record.source_smolmachine = Some(
        prepared
            .path
            .to_str()
            .ok_or(Error::uncertain(ErrorCode::Validation))?
            .into(),
    );
    record.source_registry_ref = registry_reference.map(str::to_owned);
    // Always neutral; baked ENTRYPOINT/CMD cannot become an implicit workload.
    record.entrypoint = vec!["/bin/true".into()];
    record.cmd = vec![];
    // Per-operation env/workdir/user are explicit. No baked secrets or
    // environment values enter this durable neutral-start record.
    record.workdir = Some("/".into());
    record.user = (prepared.manifest.mode == PackMode::Container).then(|| "0".into());
    if let Some(features) = policy.features {
        features
            .apply(&mut record, &prepared.manifest)
            .map_err(|error| Error::uncertain(error.code))?;
    }
    if policy.checkpointable {
        policy.qualify(&prepared.manifest)?;
        crate::checkpoint_capture::validate_branch_record(&record)?;
        record.forkable = true;
    }
    Ok(record)
}

fn validate_request(request: &CreateRequest) -> Result<()> {
    validate_creation_identity(
        &request.name,
        &request.owner_token,
        &request.incarnation,
        request.resources,
        &request.labels,
    )
}
fn reject_unqualified_oci_boot(record: &VmRecord) -> Result<()> {
    if record.image.is_some() && record.source_smolmachine.is_none() {
        return Err(Error::before(ErrorCode::Unsupported));
    }
    Ok(())
}
pub(crate) fn validate_creation_identity(
    name: &str,
    owner_token: &str,
    incarnation: &str,
    resources: Resources,
    labels: &BTreeMap<String, String>,
) -> Result<()> {
    if !valid_id(name)
        || !valid_hex(owner_token, 64)
        || !valid_hex(incarnation, 32)
        || labels.len() > 32
        || labels.iter().any(|(k, v)| {
            !valid_id(k) || k.starts_with("smolbox.") || v.len() > 1024 || v.contains('\0')
        })
    {
        return Err(Error::before(ErrorCode::Validation));
    }
    smolvm::data::validate_vm_name(name, "name")
        .map_err(|_| Error::before(ErrorCode::Validation))?;
    resources.validate()
}

fn prepare_manager_disks(
    manager: &AgentManager,
    verify_templates: impl FnOnce() -> Result<()>,
) -> Result<()> {
    for path in [manager.storage_path(), manager.overlay_path()] {
        crate::assets::prepare_created_disk(path).map_err(|e| Error::uncertain(e.code))?;
    }
    verify_templates().map_err(|e| Error::uncertain(e.code))?;
    let directory = manager
        .storage_path()
        .parent()
        .ok_or(Error::uncertain(ErrorCode::Native))?;
    let (storage, storage_format) =
        smolvm::agent::resolve_disk_image(directory, smolvm::storage::STORAGE_DISK_FILENAME);
    let (overlay, overlay_format) =
        smolvm::agent::resolve_disk_image(directory, smolvm::storage::OVERLAY_DISK_FILENAME);
    // Complete clean SDK formatting before receipt minting; never forge markers
    // or format/resize disk bytes outside the SDK. Preserve seeded VM disks.
    smolvm::storage::StorageDisk::open_existing_with_format(&storage, storage_format)
        .and_then(|disk| disk.ensure_formatted())
        .map_err(|_| Error::uncertain(ErrorCode::Native))?;
    smolvm::storage::OverlayDisk::open_existing_with_format(&overlay, overlay_format)
        .and_then(|disk| disk.ensure_formatted())
        .map_err(|_| Error::uncertain(ErrorCode::Native))?;
    for path in [&storage, &overlay] {
        crate::assets::prepare_created_disk(path).map_err(|e| Error::uncertain(e.code))?;
    }
    Ok(())
}

/// Only fresh, reserved, pre-receipt container/OCI disks enter this helper.
/// Existing machines use the separate authorized material-transition path.
fn grow_fresh_formatted_disks(storage: &Path, overlay: &Path, resources: Resources) -> Result<()> {
    resources.validate().map_err(|e| Error::uncertain(e.code))?;
    fn grow<K: smolvm::storage::DiskType>(path: &Path, gib: u64) -> Result<()> {
        crate::assets::prepare_created_disk(path).map_err(|e| Error::uncertain(e.code))?;
        let disk = smolvm::storage::VmDisk::<K>::open_existing_with_format(
            path,
            smolvm::storage::DiskFormat::Raw,
        )
        .map_err(|_| Error::uncertain(ErrorCode::Native))?;
        // Formatting completed through the public SDK before this step. Do not
        // synthesize a marker, shrink a seeded disk or format again after growth.
        if disk.needs_format() || disk.size_bytes() > gib * (1 << 30) {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        let grown = smolvm::storage::VmDisk::<K>::open_or_create_at(path, gib)
            .map_err(|_| Error::uncertain(ErrorCode::Native))?;
        if grown.size_bytes() != gib * (1 << 30) {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        Ok(())
    }
    grow::<smolvm::storage::Storage>(storage, resources.storage_gib)?;
    grow::<smolvm::storage::Overlay>(overlay, resources.overlay_gib)
}

fn database_identity(path: &Path) -> Result<(u64, u64)> {
    let metadata =
        std::fs::symlink_metadata(path).map_err(|_| Error::before(ErrorCode::Database))?;
    if !metadata.is_file() {
        return Err(Error::before(ErrorCode::Ownership));
    }
    Ok((metadata.dev(), metadata.ino()))
}

fn open_database(path: &Path, allow_initialize: bool) -> Result<(SmolvmDb, (u64, u64))> {
    // Binding validation has already selected the SDK's exact default path.
    // Reopening an enrolled domain must not silently recreate a lost database.
    match std::fs::symlink_metadata(path) {
        Ok(_) => crate::sdk_compat::validate_database(path, database_identity(path)?)?,
        Err(error) if allow_initialize && error.kind() == std::io::ErrorKind::NotFound => {}
        Err(_) => return Err(Error::before(ErrorCode::Database)),
    }
    let db = SmolvmDb::open_at(path).map_err(|_| Error::before(ErrorCode::Database))?;
    Ok((db, database_identity(path)?))
}

fn marker_bytes(receipt: &CreationReceipt) -> String {
    format!(
        "smolbox-incarnation-v1\n{}\n{}\n{}\n{}\n",
        receipt.domain_generation,
        receipt.owner_token,
        receipt.incarnation,
        receipt.material_sha256
    )
}

fn write_marker(receipt: &CreationReceipt, directory: &Path) -> Result<()> {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(directory.join("smolbox.incarnation"))
        .map_err(|_| Error::uncertain(ErrorCode::Io))?;
    file.write_all(marker_bytes(receipt).as_bytes())
        .and_then(|_| file.sync_all())
        .and_then(|_| std::fs::File::open(directory)?.sync_all())
        .map_err(|_| Error::uncertain(ErrorCode::Io))
}

/// Only a protected branch publication may retry this exact independent marker.
/// Atomic publication prevents a partial write becoming a reusable incarnation.
pub(crate) fn publish_branch_marker(receipt: &CreationReceipt, directory: &Path) -> Result<()> {
    let path = directory.join("smolbox.incarnation");
    match std::fs::symlink_metadata(&path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            let mut file = tempfile::NamedTempFile::new_in(directory)
                .map_err(|_| Error::uncertain(ErrorCode::Io))?;
            file.write_all(marker_bytes(receipt).as_bytes())
                .and_then(|()| file.as_file().sync_all())
                .map_err(|_| Error::uncertain(ErrorCode::Io))?;
            file.persist_noclobber(&path)
                .map_err(|_| Error::uncertain(ErrorCode::Ownership))?;
            std::fs::File::open(directory)
                .and_then(|file| file.sync_all())
                .map_err(|_| Error::uncertain(ErrorCode::Io))?;
        }
        Err(_) => return Err(Error::uncertain(ErrorCode::Ownership)),
        Ok(_) => {}
    }
    verify_branch_marker(receipt, directory)
}
pub(crate) fn verify_branch_marker(receipt: &CreationReceipt, directory: &Path) -> Result<()> {
    use std::os::unix::fs::MetadataExt;
    let file = crate::artifact::open_regular(&directory.join("smolbox.incarnation"))?;
    let info = file
        .metadata()
        .map_err(|_| Error::uncertain(ErrorCode::Io))?;
    if info.uid() != unsafe { libc::geteuid() }
        || info.mode() & 0o777 != 0o600
        || info.nlink() != 1
        || !marker_matches(receipt, directory)?
    {
        return Err(Error::uncertain(ErrorCode::Ownership));
    }
    Ok(())
}

pub(crate) fn marker_matches(receipt: &CreationReceipt, directory: &Path) -> Result<bool> {
    let path = directory.join("smolbox.incarnation");
    let mut file = match OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(path)
    {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(_) => return Err(Error::before(ErrorCode::Ownership)),
    };
    if !file
        .metadata()
        .map_err(|_| Error::before(ErrorCode::Io))?
        .is_file()
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    let mut bytes = String::new();
    Read::by_ref(&mut file)
        .take(512)
        .read_to_string(&mut bytes)
        .map_err(|_| Error::before(ErrorCode::Ownership))?;
    Ok(bytes == marker_bytes(receipt))
}

#[cfg(test)]
pub(crate) mod tests {
    #[test]
    fn unhanded_branch_guards_refuse_busy_ownership_maps_without_waiting_or_minting_authority() {
        let root = tempfile::tempdir().unwrap();
        let engine = test_engine(root.path());
        let held = engine.owned_handles.lock().unwrap();
        assert_eq!(
            engine
                .require_unhanded_branch_child("inert-child")
                .unwrap_err()
                .code,
            ErrorCode::Conflict
        );
        drop(held);
        let held = engine.branch_owners.lock().unwrap();
        assert_eq!(
            engine
                .require_unhanded_branch_child("inert-child")
                .unwrap_err()
                .code,
            ErrorCode::Conflict
        );
        drop(held);
        let held = engine.owned_managers.lock().unwrap();
        assert_eq!(
            engine
                .require_unhanded_branch_child("inert-child")
                .unwrap_err()
                .code,
            ErrorCode::Conflict
        );
        drop(held);
        engine.require_unhanded_branch_child("inert-child").unwrap();
    }

    use super::*;
    #[test]
    fn original_branch_shutdown_tracking_is_not_handoff_and_retires_only_the_exact_handle() {
        let root = tempfile::tempdir().unwrap();
        let engine = test_engine(root.path());
        let receipt = install_record(&engine);
        let mut sibling = receipt.clone();
        sibling.name = "untouched-sibling".into();
        engine.track_handle(&sibling).unwrap();
        // Production boot records this exact receipt before entering the SDK.
        engine.track_handle(&receipt).unwrap();
        assert_eq!(
            engine
                .require_unhanded_branch_child(&receipt.name)
                .unwrap_err()
                .code,
            ErrorCode::Ownership
        );
        engine.require_original_branch_handle(&receipt).unwrap();
        assert_eq!(engine.owned_handles.lock().unwrap().len(), 2);
        for case in 0..4 {
            let mut crossed = receipt.clone();
            match case {
                0 => crossed.owner_token = "f".repeat(64),
                1 => crossed.incarnation = "f".repeat(32),
                2 => crossed.domain_generation = "f".repeat(32),
                _ => crossed.material = None,
            }
            if crossed == receipt {
                crossed.material_sha256 = "f".repeat(64);
            }
            assert_eq!(
                engine
                    .require_original_branch_handle(&crossed)
                    .unwrap_err()
                    .code,
                ErrorCode::Ownership
            );
            assert!(engine.retire_collected_branch_handle(&crossed).is_err());
            assert_eq!(engine.owned_handles.lock().unwrap().len(), 2);
        }
        // Neither an exact receipt nor an empty tracking map overrides runtime
        // boot ownership. No manager is constructed in this model.
        let runtime = engine
            .runtime_boots
            .reserve(&receipt, &engine.jobs)
            .unwrap();
        assert!(engine.require_original_branch_handle(&receipt).is_err());
        assert!(engine.retire_collected_branch_handle(&receipt).is_err());
        engine.runtime_boots.retire(&runtime).unwrap();
        let held = engine.owned_handles.lock().unwrap();
        assert_eq!(
            engine
                .require_original_branch_handle(&receipt)
                .unwrap_err()
                .code,
            ErrorCode::Conflict
        );
        assert!(engine.retire_collected_branch_handle(&receipt).is_err());
        drop(held);
        engine.retire_collected_branch_handle(&receipt).unwrap();
        // A retry after positive collection may observe already-retired
        // tracking. This supplies no actor or collection authority by itself.
        engine.retire_collected_branch_handle(&receipt).unwrap();
        engine.require_unhanded_branch_child(&receipt.name).unwrap();
        assert_eq!(
            engine.owned_handles.lock().unwrap().get(&sibling.name),
            Some(&sibling)
        );
        assert!(engine.db.get_vm(&receipt.name).unwrap().is_some());
    }

    #[test]
    fn release_cache_recovery_never_reenrolls_a_missing_or_different_handle() {
        let model = crate::branch_boot::tests::identity_model(true);
        let request = crate::BranchReleaseRequest {
            operation_id: "recover-release-model".into(),
            request_sha256: "e".repeat(64),
            env: Vec::new(),
        };
        let release = crate::branch_release::Intent::issue(
            &model.plan.publication,
            &model.record,
            &model.enrollment,
            &model.identity_sha256,
            &request,
        )
        .unwrap()
        .transition;
        model.engine.track_handle(&release.previous).unwrap();
        model
            .engine
            .recover_branch_release_handle(&release)
            .unwrap();
        assert_eq!(
            model
                .engine
                .owned_handles
                .lock()
                .unwrap()
                .get(&release.receipt.name),
            Some(&release.receipt)
        );
        model
            .engine
            .owned_handles
            .lock()
            .unwrap()
            .remove(&release.receipt.name);
        model
            .engine
            .recover_branch_release_handle(&release)
            .unwrap();
        assert!(model.engine.owned_handles.lock().unwrap().is_empty());
        let mut foreign = release.previous.clone();
        foreign.incarnation = "f".repeat(32);
        model
            .engine
            .owned_handles
            .lock()
            .unwrap()
            .insert(foreign.name.clone(), foreign.clone());
        assert!(model
            .engine
            .recover_branch_release_handle(&release)
            .is_err());
        assert_eq!(
            model
                .engine
                .owned_handles
                .lock()
                .unwrap()
                .get(&foreign.name),
            Some(&foreign)
        );
    }

    pub(crate) fn fixture_marker(receipt: &CreationReceipt, directory: &Path) {
        write_marker(receipt, directory).unwrap();
    }

    #[test]
    #[ignore = "explicit approved account-template disk qualification; no manager, domain owner or VM"]
    fn ordinary_approved_template_format_and_growth_without_vm() {
        use sha2::{Digest, Sha256};
        use std::fs::File;
        use std::io::Read;
        use std::os::unix::fs::DirBuilderExt;
        let approval = std::env::var_os("SMOLBOX_TEMPLATE_GROWTH_APPROVAL")
            .expect("explicit preapproved template identities");
        let approved: BTreeMap<String, crate::TemplateFile> =
            serde_json::from_slice(&std::fs::read(approval).unwrap()).unwrap();
        assert_eq!(approved.len(), 2);
        let output = PathBuf::from(
            std::env::var_os("SMOLBOX_TEMPLATE_GROWTH_OUTPUT").expect("fresh private output"),
        );
        crate::host::unredirected(output.parent().unwrap()).unwrap();
        std::fs::DirBuilder::new()
            .mode(0o700)
            .create(&output)
            .unwrap();
        fn digest(path: &Path, bytes: u64) -> String {
            let mut input = File::open(path).unwrap().take(bytes);
            let mut hash = Sha256::new();
            let mut count = 0;
            let mut buffer = [0; 65536];
            loop {
                let n = input.read(&mut buffer).unwrap();
                if n == 0 {
                    break;
                }
                count += n as u64;
                hash.update(&buffer[..n]);
            }
            assert_eq!(count, bytes);
            hex::encode(hash.finalize())
        }
        let account = dirs::home_dir().unwrap().join(".smolvm");
        let mut originals = Vec::new();
        for name in ["storage-template.ext4", "overlay-template.ext4"] {
            let expected = approved.get(name).unwrap();
            let path = account.join(name);
            assert_eq!(path, expected.path);
            assert_eq!(expected.bytes, 1 << 30);
            crate::host::unredirected(&path).unwrap();
            let metadata = std::fs::symlink_metadata(&path).unwrap();
            assert!(metadata.is_file());
            assert_eq!(metadata.uid(), unsafe { libc::geteuid() });
            assert_eq!(metadata.nlink(), 1);
            assert_eq!(metadata.mode() & 0o777, 0o400);
            assert_eq!(metadata.len(), expected.bytes);
            assert_eq!(digest(&path, expected.bytes), expected.sha256);
            // Plain approved files already exist in the resolver's first root;
            // it cannot decompress/install templates during this fixture.
            assert_eq!(
                smolvm_pack::assets::find_existing_template(name),
                Some(path.clone())
            );
            originals.push((path, metadata));
        }
        let storage = output.join("storage.raw");
        let overlay = output.join("overlay.raw");
        smolvm::storage::StorageDisk::open_or_create_at(&storage, 1)
            .unwrap()
            .ensure_formatted()
            .unwrap();
        smolvm::storage::OverlayDisk::open_or_create_at(&overlay, 1)
            .unwrap()
            .ensure_formatted()
            .unwrap();
        grow_fresh_formatted_disks(
            &storage,
            &overlay,
            Resources {
                cpus: 1,
                memory_mib: 512,
                storage_gib: 3,
                overlay_gib: 2,
            },
        )
        .unwrap();
        for (disk, name, gib) in [
            (&storage, "storage-template.ext4", 3),
            (&overlay, "overlay-template.ext4", 2),
        ] {
            assert_eq!(std::fs::metadata(disk).unwrap().len(), gib << 30);
            assert_eq!(digest(disk, 1 << 30), approved[name].sha256);
            assert_eq!(
                std::fs::read(disk.with_extension("formatted")).unwrap(),
                b"1"
            );
        }
        for (path, before) in originals {
            let after = std::fs::symlink_metadata(&path).unwrap();
            assert_eq!(
                (
                    before.dev(),
                    before.ino(),
                    before.mode(),
                    before.len(),
                    before.mtime(),
                    before.mtime_nsec(),
                    before.ctime(),
                    before.ctime_nsec()
                ),
                (
                    after.dev(),
                    after.ino(),
                    after.mode(),
                    after.len(),
                    after.mtime(),
                    after.mtime_nsec(),
                    after.ctime(),
                    after.ctime_nsec()
                )
            );
            assert_eq!(
                digest(&path, 1 << 30),
                approved[path.file_name().unwrap().to_str().unwrap()].sha256
            );
        }
        // Remove only the four exact files created above, after all reads close.
        for path in [&storage, &overlay] {
            std::fs::remove_file(path).unwrap();
            std::fs::remove_file(path.with_extension("formatted")).unwrap();
        }
        let executable = std::env::current_exe().unwrap();
        let evidence = serde_json::json!({
            "status":"passed", "scope":"approved-template-format-and-growth-only",
            "templates":approved, "test_binary_sha256":digest(&executable, std::fs::metadata(&executable).unwrap().len()),
            "storage_gib":3, "overlay_gib":2, "templates_unchanged":true,
            "sdk_domain_opened":false, "manager_created":false, "vm_started":false,
            "helper_launch_qualified":false, "crash_handling_qualified":false,
            "distribution_approved":false,
        });
        std::fs::write(
            output.join("evidence.json"),
            serde_json::to_vec_pretty(&evidence).unwrap(),
        )
        .unwrap();
    }

    #[test]
    fn fresh_formatted_growth_preserves_bytes_and_markers_and_rejects_unformatted_disks() {
        use std::fs::File;
        use std::io::{Read, Seek, SeekFrom, Write};
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap();
        let storage = root.join("storage.raw");
        let overlay = root.join("overlay.raw");
        for path in [&storage, &overlay] {
            let mut file = File::create(path).unwrap();
            file.set_len(1 << 30).unwrap();
            file.write_all(b"inert formatted-disk model").unwrap();
            file.seek(SeekFrom::End(-4)).unwrap();
            file.write_all(b"tail").unwrap();
        }
        let resources = Resources {
            cpus: 1,
            memory_mib: 512,
            storage_gib: 3,
            overlay_gib: 2,
        };
        assert_eq!(
            grow_fresh_formatted_disks(&storage, &overlay, resources)
                .unwrap_err()
                .code,
            ErrorCode::Ownership
        );
        assert_eq!(std::fs::metadata(&storage).unwrap().len(), 1 << 30);
        // Private model only: no templates, SDK namespace or lifecycle entry.
        for path in [&storage, &overlay] {
            std::fs::write(path.with_extension("formatted"), b"1").unwrap();
        }
        grow_fresh_formatted_disks(&storage, &overlay, resources).unwrap();
        for (path, gib) in [(&storage, 3), (&overlay, 2)] {
            let mut file = File::open(path).unwrap();
            assert_eq!(file.metadata().unwrap().len(), gib << 30);
            let mut prefix = [0; 26];
            file.read_exact(&mut prefix).unwrap();
            assert_eq!(&prefix, b"inert formatted-disk model");
            file.seek(SeekFrom::Start((1 << 30) - 4)).unwrap();
            let mut tail = [0; 4];
            file.read_exact(&mut tail).unwrap();
            assert_eq!(&tail, b"tail");
            assert_eq!(
                std::fs::read(path.with_extension("formatted")).unwrap(),
                b"1"
            );
        }
        // Repeating the bounded growth is harmless; a lower target cannot shrink.
        grow_fresh_formatted_disks(&storage, &overlay, resources).unwrap();
        assert!(grow_fresh_formatted_disks(
            &storage,
            &overlay,
            Resources {
                storage_gib: 1,
                ..resources
            }
        )
        .is_err());
        assert_eq!(std::fs::metadata(&storage).unwrap().len(), 3 << 30);
    }

    #[test]
    fn collection_keeps_original_ledger_under_quarantine_without_granting_boot() {
        let temporary = tempfile::tempdir().unwrap();
        let mut engine = test_engine(temporary.path());
        let root = temporary.path().canonicalize().unwrap().join("model-epoch");
        std::fs::create_dir(&root).unwrap();
        let (_, launcher, actors) =
            crate::epoch::tests::fixture_for_binding(&root, None, engine.binding().clone());
        engine.boot = Some((launcher, actors.clone()));
        drop(actors.begin_boot("unresolved-model").unwrap()); // No process or SDK entry.
        engine.jobs.quarantine();
        assert!(engine.boot_epoch().is_err());
        assert!(!engine.available());
        let original = engine.collection_epoch().unwrap();
        assert_eq!(original.identity(), actors.identity());
        assert!(original.bound_to(engine.binding()));
        assert!(!original.available());
    }

    #[test]
    fn cancelled_growth_proof_observation_cannot_enter_io_or_reserve_control_capacity() {
        let temporary = tempfile::tempdir().unwrap();
        let engine = test_engine(temporary.path());
        let receipt = install_record(&engine);
        let cancel = Cancellation::new();
        cancel.cancel();
        let budget = crate::ReadBudget::new(std::time::Duration::from_secs(1), cancel).unwrap();
        let error = engine
            .inspect_growth_transition_with_budget(
                &receipt,
                "growth",
                crate::GrowDisks {
                    storage_gib: Some(2),
                    overlay_gib: None,
                },
                &budget,
            )
            .unwrap_err();
        assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
        assert_eq!(error.code, ErrorCode::State);
        assert_eq!(engine.jobs.counts().control, 0);
        assert!(engine.owned_handles.lock().unwrap().is_empty());
    }

    #[test]
    fn quarantined_work_keeps_bounded_observations_and_machine_conflicts_without_adopting_inventory(
    ) {
        let temporary = tempfile::tempdir().unwrap();
        let engine = test_engine(temporary.path());
        let receipt = install_record(&engine);
        let gate = engine.gate(&receipt.name).unwrap();
        let held = gate.try_lock().unwrap();
        let work = engine
            .jobs
            .acquire(crate::jobs::Demand::growth(1).unwrap())
            .unwrap();
        engine.jobs.quarantine();
        assert!(!engine.available());
        assert_eq!(engine.node_health(&read_budget()).unwrap().total, 1);
        assert_eq!(engine.inventory(&read_budget()).unwrap().count, 1);
        assert_eq!(
            engine.node_capacity(&read_budget()).unwrap().allocated_cpus,
            0
        );
        assert_eq!(
            engine
                .machine_counters(&receipt, &read_budget())
                .err()
                .unwrap()
                .code,
            ErrorCode::Conflict
        );
        assert_eq!(
            engine.gate(&receipt.name).err().unwrap().code,
            ErrorCode::State
        );
        assert_eq!(engine.jobs.counts().work, 1);
        drop(held);
        assert_eq!(
            engine
                .machine_counters(&receipt, &read_budget())
                .unwrap()
                .0
                .state,
            ObservedState::Stopped
        );
        drop(work);
        assert!(!engine.available());
        assert_eq!(engine.jobs.counts().work, 0);
        assert_eq!(engine.node_health(&read_budget()).unwrap().total, 1);
        assert!(engine.owned_handles.lock().unwrap().is_empty());
    }

    fn read_budget() -> crate::ReadBudget {
        crate::ReadBudget::new(std::time::Duration::from_secs(10), Cancellation::new()).unwrap()
    }

    #[test]
    fn shared_work_admission_precedes_guest_dispatch_and_does_not_starve_observation() {
        let temp = tempfile::tempdir().unwrap();
        let engine = test_engine(temp.path());
        let receipt = install_record(&engine);
        let leases = (0..crate::JOB_WORK_SLOTS)
            .map(|_| {
                engine
                    .jobs
                    .acquire(crate::jobs::Demand::streaming())
                    .unwrap()
            })
            .collect::<Vec<_>>();
        let command = Command {
            argv: vec!["/bin/true".into()],
            env: vec![],
            workdir: None,
            user: None,
            timeout: std::time::Duration::from_secs(1),
            max_output_bytes: 1024,
        };
        assert_eq!(
            engine
                .exec(&receipt, command, Cancellation::new(), |_| Ok(()))
                .err()
                .unwrap()
                .code,
            ErrorCode::Admission
        );
        assert_eq!(engine.node_health(&read_budget()).unwrap().total, 1);
        assert_eq!(engine.jobs.counts().work, crate::JOB_WORK_SLOTS);
        assert_eq!(engine.jobs.counts().control, 0);
        drop(leases);
        assert_eq!(engine.jobs.counts().work, 0);
    }

    #[test]
    fn observations_read_inventory_without_minting_authority_or_changing_records() {
        let temp = tempfile::tempdir().unwrap();
        let engine = test_engine(temp.path());
        assert_eq!(engine.node_health(&read_budget()).unwrap().total, 0);
        let receipt = install_record(&engine);
        let original = engine.db.get_vm(&receipt.name).unwrap().unwrap();
        let health = engine.node_health(&read_budget()).unwrap();
        assert_eq!((health.total, health.running), (1, 0));
        let inventory = engine.inventory(&read_budget()).unwrap();
        assert_eq!(inventory.count, 1);
        let body: serde_json::Value = serde_json::from_slice(&inventory.bytes).unwrap();
        assert_eq!(body[0]["name"], "owned");
        for key in [
            "receipt",
            "owner_token",
            "incarnation",
            "labels",
            "env",
            "source_smolmachine",
        ] {
            assert!(body[0].get(key).is_none());
        }
        let capacity = engine.node_capacity(&read_budget()).unwrap();
        assert_eq!(
            (
                capacity.allocated_cpus,
                capacity.used_memory_mb,
                capacity.used_cpu_millis
            ),
            (0, 0, 0)
        );
        let (observation, measurements) =
            engine.machine_counters(&receipt, &read_budget()).unwrap();
        assert_eq!(observation.state, ObservedState::Stopped);
        assert_eq!(measurements.cpu_millis, None);
        assert_eq!(measurements.rss_mb, None);
        assert_eq!(
            crate::identity::material_hash(&original).unwrap(),
            crate::identity::material_hash(&engine.db.get_vm(&receipt.name).unwrap().unwrap())
                .unwrap()
        );
        assert!(engine.owned_handles.lock().unwrap().is_empty());
    }

    #[test]
    fn observations_bound_records_bytes_cancel_and_foreign_running_pids() {
        let temp = tempfile::tempdir().unwrap();
        let engine = test_engine(temp.path());
        let receipt = install_record(&engine);
        let cancel = Cancellation::new();
        cancel.cancel();
        let stopped = crate::ReadBudget::new(std::time::Duration::from_secs(1), cancel).unwrap();
        assert!(engine.node_health(&stopped).is_err());
        engine
            .db
            .update_vm(&receipt.name, |r| {
                r.pid = Some(std::process::id() as i32);
                r.pid_start_time = None;
            })
            .unwrap();
        assert!(engine.node_health(&read_budget()).is_err());
        assert!(engine.node_capacity(&read_budget()).is_err());
        engine
            .db
            .update_vm(&receipt.name, |r| {
                r.pid = None;
                r.labels.insert(
                    "large".into(),
                    "x".repeat(crate::observations::MAX_RECORD_BYTES + 1),
                );
            })
            .unwrap();
        assert_eq!(
            engine.node_health(&read_budget()).err().unwrap().code,
            ErrorCode::OutputLimit
        );
    }

    #[test]
    fn inventory_limit_is_an_error_not_a_partial_success() {
        let temp = tempfile::tempdir().unwrap();
        let engine = test_engine(temp.path());
        for n in 0..1025 {
            let record = VmRecord::new(format!("item-{n:04}"), 1, 512, vec![], vec![], false);
            engine
                .db
                .insert_vm_if_not_exists(&record.name, &record)
                .unwrap();
        }
        assert_eq!(
            engine.inventory(&read_budget()).err().unwrap().code,
            ErrorCode::OutputLimit
        );
        assert_eq!(
            engine.node_health(&read_budget()).err().unwrap().code,
            ErrorCode::OutputLimit
        );
        assert!(engine.owned_handles.lock().unwrap().is_empty());
    }

    #[test]
    fn raw_snapshot_budget_rejects_an_aggregate_of_individually_valid_records() {
        let temp = tempfile::tempdir().unwrap();
        let engine = test_engine(temp.path());
        for n in 0..9 {
            let mut record = VmRecord::new(format!("large-{n}"), 1, 512, vec![], vec![], false);
            record.env = vec![("IMAGE_METADATA".into(), "x".repeat(4 * 1024 * 1024))];
            assert!(
                serde_json::to_vec(&record).unwrap().len() < crate::observations::MAX_RECORD_BYTES
            );
            engine
                .db
                .insert_vm_if_not_exists(&record.name, &record)
                .unwrap();
        }
        assert_eq!(
            engine.node_health(&read_budget()).err().unwrap().code,
            ErrorCode::OutputLimit
        );
        assert!(engine.owned_handles.lock().unwrap().is_empty());
    }

    #[test]
    fn large_merged_workload_records_remain_observable_without_disclosing_their_env() {
        let temp = tempfile::tempdir().unwrap();
        let engine = test_engine(temp.path());
        let receipt = install_record(&engine);
        engine
            .db
            .update_vm(&receipt.name, |record| {
                record.env = (0..64)
                    .map(|n| (format!("K{n}"), "\u{1}".repeat(8192)))
                    .collect();
            })
            .unwrap();
        assert_eq!(engine.node_health(&read_budget()).unwrap().total, 1);
        let inventory = engine.inventory(&read_budget()).unwrap();
        let rows: serde_json::Value = serde_json::from_slice(&inventory.bytes).unwrap();
        assert_eq!(inventory.count, 1);
        assert!(rows[0].get("env").is_none());
        assert!(rows[0].get("labels").is_none());
        assert!(inventory.bytes.len() < crate::observations::MAX_INVENTORY_BYTES);
    }

    #[test]
    fn capacity_samples_a_birth_bound_normal_process_without_creating_a_vm() {
        let temp = tempfile::tempdir().unwrap();
        let engine = test_engine(temp.path());
        let receipt = install_record(&engine);
        let pid = std::process::id() as i32;
        let birth = smolvm::process::process_start_time(pid).unwrap();
        engine
            .db
            .update_vm(&receipt.name, |r| {
                r.pid = Some(pid);
                r.pid_start_time = Some(birth);
            })
            .unwrap();
        for name in [
            smolvm::storage::STORAGE_DISK_FILENAME,
            smolvm::storage::OVERLAY_DISK_FILENAME,
        ] {
            std::fs::File::create(engine.vm_directory(&receipt.name).join(name))
                .unwrap()
                .set_len(1024 * 1024 * 1024)
                .unwrap();
        }
        let measured = engine.node_capacity(&read_budget()).unwrap();
        assert_eq!(
            (
                measured.allocated_cpus,
                measured.allocated_memory_mb,
                measured.used_disk_gb
            ),
            (1, 512, 2)
        );
        assert!(measured.used_memory_mb > 0);
        assert_eq!(engine.node_health(&read_budget()).unwrap().running, 1);
        // Physical liveness is insufficient for a usable machine inventory
        // result. This ordinary process deliberately has no agent socket.
        assert_eq!(
            engine.inventory(&read_budget()).err().unwrap().code,
            ErrorCode::State
        );
        engine
            .db
            .update_vm(&receipt.name, |r| r.pid_start_time = Some(birth + 1))
            .unwrap();
        assert!(engine.node_capacity(&read_budget()).is_err());
        assert!(engine.owned_handles.lock().unwrap().is_empty());
    }

    #[test]
    fn machine_measurements_require_saved_authority_and_cannot_resolve_partial_storage() {
        let temp = tempfile::tempdir().unwrap();
        let engine = test_engine(temp.path());
        let receipt = install_record(&engine);
        let mut foreign = receipt.clone();
        foreign.owner_token = "d".repeat(64);
        assert_eq!(
            engine
                .machine_counters(&foreign, &read_budget())
                .err()
                .unwrap()
                .code,
            ErrorCode::Ownership
        );
        engine.db.remove_vm(&receipt.name).unwrap();
        assert_eq!(
            engine
                .machine_counters(&receipt, &read_budget())
                .unwrap()
                .0
                .state,
            ObservedState::IdentityUnknown
        );
        assert!(engine.vm_directory(&receipt.name).exists());
    }

    pub(crate) fn test_install_templates(
        engine: &mut Engine,
        templates: crate::assets::PreparedTemplates,
    ) {
        engine.templates = Some(templates);
    }

    pub(crate) fn test_engine(root: &Path) -> Engine {
        let root = root.canonicalize().unwrap();
        test_engine_with_vm_root(&root, root.join("vms"))
    }

    pub(crate) fn test_engine_with_vm_root(root: &Path, vm_root: PathBuf) -> Engine {
        let root = root.canonicalize().unwrap();
        let binding = DomainBinding {
            target_id: "local".into(),
            generation: "a".repeat(32),
            database: root.join("db"),
            vm_root,
        };
        let db = SmolvmDb::open_at(&binding.database).unwrap();
        let domain = DomainGuard::acquire_at(&binding, root.join("private"), true).unwrap();
        let domain = Arc::new(domain);
        let jobs = crate::jobs::JobPool::default();
        let capture_staging =
            crate::capture_staging::Staging::open(&binding, domain.clone(), jobs.clone()).unwrap();
        let export_staging =
            crate::export_staging::Staging::open(&binding, domain.clone(), jobs.clone()).unwrap();
        let export_retention = crate::export_retention::Registry::new(domain.clone());
        let branch_retention = crate::branch::retention::Registry::new(domain.clone());
        Engine {
            opened_at: std::time::Instant::now(),
            runtime: Arc::new(EmbeddedRuntime::with_db(db.clone())),
            database_identity: database_identity(&binding.database).unwrap(),
            db,
            binding,
            gates: Mutex::new(HashMap::new()),
            owned_handles: Mutex::new(BTreeMap::new()),
            capture_sources: Mutex::new(BTreeMap::new()),
            owned_managers: Mutex::new(BTreeMap::new()),
            branch_owners: Mutex::new(BTreeMap::new()),
            runtime_boots: Arc::default(),
            domain,
            transfers: None,
            jobs,
            capture_staging,
            export_staging,
            export_retention,
            branch_retention,
            templates: None,
            export_assets: None,
            host: None,
            boot: None,
        }
    }

    pub(crate) fn test_export_host(engine: &mut Engine, root: &Path) {
        use sha2::{Digest, Sha256};
        use std::os::unix::fs::PermissionsExt;
        let executable = root.join("approved-export-host");
        std::fs::write(&executable, b"test host identity, never executed").unwrap();
        std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o500)).unwrap();
        let executable = crate::Executable {
            path: executable,
            sha256: format!(
                "{:x}",
                Sha256::digest(b"test host identity, never executed")
            ),
        };
        engine.host = Some(
            crate::HostContext::capture(
                engine.binding().clone(),
                "b".repeat(32),
                "c".repeat(64),
                crate::ExecutableLocator {
                    boot: executable.clone(),
                    file_worker: executable,
                    library_directory: root.join("lib"),
                },
            )
            .unwrap(),
        );
    }
    pub(crate) fn test_model_host_epoch(engine: &mut Engine, root: &Path, epoch: &str) {
        if engine.host.is_none() {
            test_export_host(engine, root);
        }
        engine.host.as_mut().unwrap().epoch = epoch.into();
    }
    #[test]
    fn metadata_preparation_observes_exact_source_without_changing_machine_storage_or_records() {
        use sha2::{Digest, Sha256};
        use std::net::TcpListener;
        let temp = tempfile::tempdir().unwrap();
        let engine = test_engine(temp.path());
        let receipt = install_record(&engine);
        let before = serde_json::to_vec(&engine.db.get_vm(&receipt.name).unwrap()).unwrap();
        let (mut source, manifest, config) = crate::oci::tests::bytes();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        source.reference = format!(
            "127.0.0.1:{}/team/app@sha256:{}",
            listener.local_addr().unwrap().port(),
            hex::encode(Sha256::digest(&manifest))
        );
        let cancel = Cancellation::new();
        cancel.cancel();
        assert_eq!(
            engine
                .prepare_oci_metadata(
                    source.clone(),
                    std::time::Instant::now() + std::time::Duration::from_secs(5),
                    cancel
                )
                .err()
                .unwrap()
                .dispatch,
            crate::Dispatch::NotDispatched
        );
        assert!(engine
            .prepare_oci_metadata(
                source.clone(),
                std::time::Instant::now(),
                Cancellation::new()
            )
            .is_err());
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
        std::thread::scope(|scope| {
            let peer = scope.spawn(|| {
                for body in [&manifest, &config] {
                    let (mut stream, _) = listener.accept().unwrap();
                    stream
                        .set_read_timeout(Some(std::time::Duration::from_secs(2)))
                        .unwrap();
                    let mut request = Vec::new();
                    while !request.ends_with(b"\r\n\r\n") {
                        assert!(request.len() < 16384);
                        let mut byte = [0];
                        stream.read_exact(&mut byte).unwrap();
                        request.push(byte[0]);
                    }
                    write!(
                        stream,
                        "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: {}\r\n\r\n",
                        body.len()
                    )
                    .unwrap();
                    stream.write_all(body).unwrap();
                }
            });
            let verified = engine
                .prepare_oci_metadata(
                    source.clone(),
                    std::time::Instant::now() + std::time::Duration::from_secs(5),
                    Cancellation::new(),
                )
                .unwrap();
            assert!(verified.source() == &source);
            peer.join().unwrap();
        });
        assert_eq!(
            serde_json::to_vec(&engine.db.get_vm(&receipt.name).unwrap()).unwrap(),
            before
        );
        assert!(engine.owned_handles.lock().unwrap().is_empty());
        assert!(engine.owned_managers.lock().unwrap().is_empty());
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
        assert!(engine.jobs.available());
        assert!(!engine.domain.directory.join("transfers").exists());
        engine.jobs.quarantine();
        let error = engine
            .prepare_oci_metadata(
                source,
                std::time::Instant::now() + std::time::Duration::from_secs(5),
                Cancellation::new(),
            )
            .err()
            .unwrap();
        assert_eq!(error.code, ErrorCode::State);
        assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
    }

    #[test]
    fn registry_descriptor_preparation_is_bounded_and_does_not_prepare_a_machine_or_cache() {
        use sha2::{Digest, Sha256};
        use std::net::TcpListener;
        use std::time::{Duration, Instant};
        let temp = tempfile::tempdir().unwrap();
        let engine = test_engine(temp.path());
        let receipt = install_record(&engine);
        let before = serde_json::to_vec(&engine.db.get_vm(&receipt.name).unwrap()).unwrap();
        let manifest = serde_json::to_vec(&serde_json::json!({
            "schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json",
            "config":{"mediaType":"application/vnd.smolmachines.machine.config.v1+json","digest":format!("sha256:{}","b".repeat(64)),"size":2},
            "layers":[{"mediaType":"application/vnd.smolmachines.smolmachine.v1","digest":format!("sha256:{}","a".repeat(64)),"size":123}]
        })).unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let hash = hex::encode(Sha256::digest(&manifest));
        let source = crate::RegistryArtifactSource {
            reference: format!(
                "127.0.0.1:{}/team/app@sha256:{hash}",
                listener.local_addr().unwrap().port()
            ),
            platform: crate::oci::native_oci_platform().into(),
            content_sha256: "a".repeat(64),
        };
        for (cap, deadline, cancel) in [
            (
                0,
                Instant::now() + Duration::from_secs(5),
                Cancellation::new(),
            ),
            (123, Instant::now(), Cancellation::new()),
            (123, Instant::now() + Duration::from_secs(5), {
                let cancel = Cancellation::new();
                cancel.cancel();
                cancel
            }),
        ] {
            assert_eq!(
                engine
                    .prepare_registry_descriptor(source.clone(), cap, deadline, cancel)
                    .err()
                    .unwrap()
                    .dispatch,
                crate::Dispatch::NotDispatched
            );
        }
        std::thread::scope(|scope| {
            let peer = scope.spawn(|| {
                let (mut stream, _) = listener.accept().unwrap();
                stream
                    .set_read_timeout(Some(Duration::from_secs(2)))
                    .unwrap();
                let mut request = Vec::new();
                while !request.ends_with(b"\r\n\r\n") {
                    assert!(request.len() < 16384);
                    let mut byte = [0];
                    stream.read_exact(&mut byte).unwrap();
                    request.push(byte[0]);
                }
                let request = String::from_utf8(request).unwrap();
                assert!(request.starts_with(&format!(
                    "GET /v2/team/app/manifests/sha256:{hash} HTTP/1.1\r\n"
                )));
                assert!(!request.to_ascii_lowercase().contains("authorization:"));
                write!(
                    stream,
                    "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: {}\r\n\r\n",
                    manifest.len()
                )
                .unwrap();
                stream.write_all(&manifest).unwrap();
            });
            let descriptor = engine
                .prepare_registry_descriptor(
                    source.clone(),
                    123,
                    Instant::now() + Duration::from_secs(5),
                    Cancellation::new(),
                )
                .unwrap();
            assert_eq!(descriptor.size(), 123);
            assert_eq!(
                descriptor.digest(),
                format!("sha256:{}", source.content_sha256)
            );
            peer.join().unwrap();
        });
        listener.set_nonblocking(true).unwrap();
        assert_eq!(
            listener.accept().unwrap_err().kind(),
            std::io::ErrorKind::WouldBlock
        );
        assert_eq!(
            serde_json::to_vec(&engine.db.get_vm(&receipt.name).unwrap()).unwrap(),
            before
        );
        assert!(engine.owned_handles.lock().unwrap().is_empty());
        assert!(engine.owned_managers.lock().unwrap().is_empty());
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
        assert!(!engine.domain.directory.join("transfers").exists());
        engine.jobs.quarantine();
        assert_eq!(
            engine
                .prepare_registry_descriptor(
                    source,
                    123,
                    Instant::now() + Duration::from_secs(5),
                    Cancellation::new()
                )
                .err()
                .unwrap()
                .dispatch,
            crate::Dispatch::NotDispatched
        );
    }

    #[test]
    fn registry_blob_preparation_downloads_once_rehashes_warm_cache_and_rejects_corruption() {
        use sha2::{Digest, Sha256};
        use std::net::TcpListener;
        use std::os::unix::fs::PermissionsExt;
        use std::time::{Duration, Instant};
        let temp = tempfile::tempdir().unwrap();
        let engine = test_engine(temp.path());
        let receipt = install_record(&engine);
        let before = serde_json::to_vec(&engine.db.get_vm(&receipt.name).unwrap()).unwrap();
        let blob = b"bounded-registry-content";
        let content = hex::encode(Sha256::digest(blob));
        let manifest=serde_json::to_vec(&serde_json::json!({
            "schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json",
            "config":{"mediaType":"application/vnd.smolmachines.machine.config.v1+json","digest":format!("sha256:{}","b".repeat(64)),"size":2},
            "layers":[{"mediaType":"application/vnd.smolmachines.smolmachine.v1","digest":format!("sha256:{content}"),"size":blob.len()}]
        })).unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let hash = hex::encode(Sha256::digest(&manifest));
        let source = crate::RegistryArtifactSource {
            reference: format!(
                "127.0.0.1:{}/team/app@sha256:{hash}",
                listener.local_addr().unwrap().port()
            ),
            platform: crate::oci::native_oci_platform().into(),
            content_sha256: content.clone(),
        };
        let cached_path = engine
            .domain
            .directory
            .join("registry-blobs")
            .join(format!("{content}.smolmachine"));
        assert_eq!(
            engine
                .prepare_registry_blob(
                    source.clone(),
                    blob.len() as u64,
                    crate::RegistryCachePolicy {
                        max_bytes: 0,
                        max_files: 1
                    },
                    Instant::now() + Duration::from_secs(5),
                    Cancellation::new()
                )
                .err()
                .unwrap()
                .dispatch,
            crate::Dispatch::NotDispatched
        );
        let credential = crate::RegistryIdentityCredential::new(
            "private-identity".into(),
            "https://auth.example/exchange",
        )
        .unwrap();
        assert_eq!(
            engine
                .prepare_registry_blob_with_credential(
                    source.clone(),
                    blob.len() as u64,
                    crate::RegistryCachePolicy {
                        max_bytes: blob.len() as u64,
                        max_files: 1
                    },
                    Instant::now() + Duration::from_secs(5),
                    Cancellation::new(),
                    Some(credential)
                )
                .err()
                .unwrap()
                .dispatch,
            crate::Dispatch::NotDispatched
        );
        for stage in 0..4 {
            if stage == 3 {
                std::fs::remove_file(&cached_path).unwrap();
            }
            if stage == 2 {
                std::fs::set_permissions(&cached_path, std::fs::Permissions::from_mode(0o600))
                    .unwrap();
                std::fs::write(&cached_path, vec![b'x'; blob.len()]).unwrap();
                std::fs::set_permissions(&cached_path, std::fs::Permissions::from_mode(0o400))
                    .unwrap();
            }
            std::thread::scope(|scope| {
                let peer = scope.spawn(|| {
                    for index in 0..if stage == 0 { 2 } else { 1 } {
                        let (mut stream, _) = listener.accept().unwrap();
                        stream
                            .set_read_timeout(Some(Duration::from_secs(2)))
                            .unwrap();
                        let mut request = Vec::new();
                        while !request.ends_with(b"\r\n\r\n") {
                            assert!(request.len() < 16384);
                            let mut byte = [0];
                            stream.read_exact(&mut byte).unwrap();
                            request.push(byte[0]);
                        }
                        let request = String::from_utf8(request).unwrap();
                        let (path, body): (_, &[u8]) = if index == 0 {
                            (format!("manifests/sha256:{hash}"), &manifest)
                        } else {
                            (format!("blobs/sha256:{content}"), blob)
                        };
                        assert!(
                            request.starts_with(&format!("GET /v2/team/app/{path} HTTP/1.1\r\n"))
                        );
                        write!(
                            stream,
                            "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: {}\r\n\r\n",
                            body.len()
                        )
                        .unwrap();
                        stream.write_all(body).unwrap();
                    }
                });
                let policy = crate::RegistryCachePolicy {
                    max_bytes: if stage == 3 { 1 } else { blob.len() as u64 },
                    max_files: 1,
                };
                let result = engine.prepare_registry_blob(
                    source.clone(),
                    blob.len() as u64,
                    policy,
                    Instant::now() + Duration::from_secs(5),
                    Cancellation::new(),
                );
                if stage >= 2 {
                    assert!(result.is_err());
                } else {
                    let result = result.unwrap();
                    assert_eq!(result.size(), blob.len() as u64);
                    assert_eq!(result.already_cached(), stage == 1);
                    assert_eq!(result.path(), cached_path);
                    assert!(result.source() == &source);
                    assert_eq!(std::fs::read(result.path()).unwrap(), blob);
                }
                peer.join().unwrap();
            });
            assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
            assert!(engine.owned_handles.lock().unwrap().is_empty());
            assert!(engine.owned_managers.lock().unwrap().is_empty());
            assert_eq!(
                serde_json::to_vec(&engine.db.get_vm(&receipt.name).unwrap()).unwrap(),
                before
            );
            assert_eq!(
                std::fs::read_dir(cached_path.parent().unwrap())
                    .unwrap()
                    .count(),
                if stage == 3 { 0 } else { 1 }
            );
        }
        listener.set_nonblocking(true).unwrap();
        assert_eq!(
            listener.accept().unwrap_err().kind(),
            std::io::ErrorKind::WouldBlock
        );
    }

    #[test]
    fn registry_pack_qualification_keeps_engine_storage_and_owned_handles_unchanged() {
        use std::time::{Duration, Instant};
        let temp = tempfile::tempdir().unwrap();
        let engine = test_engine(temp.path());
        let receipt = install_record(&engine);
        let before = serde_json::to_vec(&engine.db.get_vm(&receipt.name).unwrap()).unwrap();
        let blob = crate::registry_artifact::tests::sidecar_fixture(
            &engine.domain.directory,
            crate::oci::native_oci_platform(),
        );
        let path = blob.path().to_owned();
        let resources = Resources {
            cpus: 1,
            memory_mib: 512,
            storage_gib: 1,
            overlay_gib: 1,
        };
        let qualified = engine
            .qualify_registry_blob(
                blob,
                resources,
                Instant::now() + Duration::from_secs(3),
                Cancellation::new(),
            )
            .unwrap();
        assert_eq!(qualified.platform(), crate::oci::native_oci_platform());
        assert!(qualified.prepared.verified.covers(&path));
        assert_eq!(
            serde_json::to_vec(&engine.db.get_vm(&receipt.name).unwrap()).unwrap(),
            before
        );
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
        assert!(engine.owned_handles.lock().unwrap().is_empty());
        assert!(engine.owned_managers.lock().unwrap().is_empty());
        assert!(!engine.domain.directory.join("artifacts").exists());
    }

    #[test]
    fn registry_creation_rejects_cancel_unqualified_templates_and_crossed_cache_before_dispatch() {
        use std::time::{Duration, Instant};
        let temp = tempfile::tempdir().unwrap();
        let engine = test_engine(temp.path());
        let resources = Resources {
            cpus: 1,
            memory_mib: 512,
            storage_gib: 1,
            overlay_gib: 1,
        };
        for scenario in [
            "cancel",
            "templates",
            "crossed",
            "foreign_mounts",
            "mounted_cancel",
        ] {
            let blob = crate::registry_artifact::tests::sidecar_fixture(
                &engine.domain.directory,
                crate::oci::native_oci_platform(),
            );
            let mut artifact = engine
                .qualify_registry_blob(
                    blob,
                    resources,
                    Instant::now() + Duration::from_secs(3),
                    Cancellation::new(),
                )
                .unwrap();
            if scenario == "crossed" {
                artifact.source.content_sha256 = "c".repeat(64);
            }
            let cancel = Cancellation::new();
            if matches!(scenario, "cancel" | "mounted_cancel") {
                cancel.cancel();
            }
            let request = CreateRegistryRequest {
                name: "fresh-registry".into(),
                owner_token: "a".repeat(64),
                incarnation: "b".repeat(32),
                artifact,
                labels: BTreeMap::new(),
                features: crate::CreationFeatures {
                    network: crate::NetworkPolicy {
                        enabled: false,
                        hosts: vec![],
                        cidrs: vec![],
                    },
                    ports: vec![],
                    workload: None,
                },
            };
            let result = if matches!(scenario, "foreign_mounts" | "mounted_cancel") {
                let (_directory, mounts) = crate::volumes::foreign_handle();
                engine.create_registry_with_volume_mounts(
                    request,
                    mounts,
                    Instant::now() + Duration::from_secs(3),
                    &cancel,
                )
            } else {
                engine.create_registry_prepared(
                    request,
                    Instant::now() + Duration::from_secs(3),
                    &cancel,
                )
            };
            let error = result.err().unwrap();
            assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
            assert_eq!(
                error.code,
                match scenario {
                    "cancel" | "mounted_cancel" => ErrorCode::State,
                    "templates" => ErrorCode::Unsupported,
                    _ => ErrorCode::Ownership,
                }
            );
            assert!(engine.db.get_vm("fresh-registry").unwrap().is_none());
            assert!(!engine.vm_directory("fresh-registry").exists());
            assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
            assert_eq!(
                rusqlite::Connection::open(&engine.binding.database)
                    .unwrap()
                    .prepare("SELECT count(*) FROM vm_create_reservations")
                    .unwrap()
                    .query_row([], |row| row.get::<_, i64>(0))
                    .unwrap(),
                0
            );
        }
    }

    #[test]
    fn forkable_pack_opt_in_binds_network_policy_and_keeps_capture_offline() {
        use std::time::{Duration, Instant};
        let temp = tempfile::tempdir().unwrap();
        let engine = test_engine(temp.path());
        let resources = Resources {
            cpus: 1,
            memory_mib: 512,
            storage_gib: 1,
            overlay_gib: 1,
        };
        for mode in [PackMode::Vm, PackMode::Container] {
            let blob = crate::registry_artifact::tests::sidecar_fixture_mode(
                &engine.domain.directory,
                crate::oci::native_oci_platform(),
                mode.clone(),
            );
            let artifact = engine
                .qualify_registry_blob(
                    blob,
                    resources,
                    Instant::now() + Duration::from_secs(3),
                    Cancellation::new(),
                )
                .unwrap();
            let request = CreateRequest {
                name: "checkpointable-source".into(),
                owner_token: "a".repeat(64),
                incarnation: "b".repeat(32),
                resources,
                labels: BTreeMap::new(),
                artifact: ApprovedArtifact {
                    path: artifact.prepared.path.clone(),
                    sha256: artifact.source.content_sha256.clone(),
                    max_bytes: 1024 * 1024,
                    guest_platform: artifact.source.platform.clone(),
                },
            };
            let ordinary = prepared_pack_record(
                &request,
                &artifact.prepared,
                PackRecordPolicy::default(),
                None,
            )
            .unwrap();
            assert!(!ordinary.forkable);
            let policy = PackRecordPolicy {
                features: None,
                checkpointable: true,
            };
            let opted = prepared_pack_record(&request, &artifact.prepared, policy, None);
            if mode == PackMode::Vm {
                let mut opted = opted.unwrap();
                assert!(opted.forkable);
                assert_eq!(
                    crate::checkpoint_capture::validate_record(&opted).unwrap(),
                    resources
                );
                opted.created_at = ordinary.created_at;
                assert_ne!(
                    material_hash(&opted).unwrap(),
                    material_hash(&ordinary).unwrap()
                );
                opted.forkable = false;
                assert_eq!(
                    material_hash(&opted).unwrap(),
                    material_hash(&ordinary).unwrap()
                );
                let networked = crate::CreationFeatures {
                    network: crate::NetworkPolicy {
                        enabled: true,
                        hosts: vec!["example.com".into()],
                        cidrs: vec![],
                    },
                    ports: vec![],
                    workload: None,
                };
                let networked = prepared_pack_record(
                    &request,
                    &artifact.prepared,
                    PackRecordPolicy {
                        features: Some(&networked),
                        checkpointable: true,
                    },
                    None,
                );
                if cfg!(target_os = "linux") {
                    let networked = networked.unwrap();
                    assert!(networked.forkable);
                    assert_eq!(networked.dns_filter_hosts, Some(vec!["example.com".into()]));
                    assert!(crate::checkpoint_capture::validate_record(&networked).is_err());
                    assert_ne!(
                        material_hash(&networked).unwrap(),
                        material_hash(&ordinary).unwrap()
                    );
                } else {
                    assert_eq!(networked.unwrap_err().code, ErrorCode::Unsupported);
                }
            } else {
                assert_eq!(opted.unwrap_err().code, ErrorCode::Unsupported);
            }
            assert!(engine.db.get_vm(&request.name).unwrap().is_none());
            assert!(!engine.vm_directory(&request.name).exists());
            assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
        }
    }

    #[test]
    fn checkpointable_start_and_preflight_cannot_promote_a_stopped_record_or_cross_ownership() {
        use std::time::{Duration, Instant};
        let temp = tempfile::tempdir().unwrap();
        let engine = test_engine(temp.path());
        let name = "ordinary-source";
        let owner = "a".repeat(64);
        let incarnation = "b".repeat(32);
        let mut record = VmRecord::new(name.into(), 1, 512, vec![], vec![], false);
        record.storage_gb = Some(1);
        record.overlay_gb = Some(1);
        record.entrypoint = vec!["/bin/true".into()];
        record.cmd.clear();
        record.env.clear();
        record.workdir = Some("/".into());
        record.user = None;
        record.labels.insert("smolbox.owner".into(), owner.clone());
        record
            .labels
            .insert("smolbox.incarnation".into(), incarnation.clone());
        crate::checkpoint_capture::validate_record(&record).unwrap();
        std::fs::create_dir_all(engine.vm_directory(name)).unwrap();
        assert!(engine.db.reserve_vm_create(name, &owner).unwrap());
        let receipt = engine
            .commit_created_record(name, &owner, &incarnation, &record)
            .unwrap();
        let receipt = crate::material::MaterialJournal::at(&engine.vm_directory(name))
            .initialize(&receipt)
            .unwrap();
        let before = serde_json::to_vec(&engine.db.get_vm(name).unwrap()).unwrap();
        let failure = engine
            .start_checkpointable(
                &receipt,
                Instant::now() + Duration::from_secs(3),
                &Cancellation::new(),
            )
            .unwrap_err();
        assert_eq!(failure.code, ErrorCode::Unsupported);
        assert_eq!(failure.dispatch, crate::Dispatch::NotDispatched);
        assert_eq!(
            engine
                .checkpoint_preflight(&receipt, &read_budget())
                .unwrap_err()
                .code,
            ErrorCode::State
        );
        let mut crossed = receipt.clone();
        crossed.owner_token = "f".repeat(64);
        assert_eq!(
            engine
                .start_checkpointable(
                    &crossed,
                    Instant::now() + Duration::from_secs(3),
                    &Cancellation::new()
                )
                .unwrap_err()
                .code,
            ErrorCode::Ownership
        );
        assert_eq!(
            serde_json::to_vec(&engine.db.get_vm(name).unwrap()).unwrap(),
            before
        );
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
        assert!(engine.owned_handles.lock().unwrap().is_empty());
    }

    #[test]
    fn registry_pack_record_binds_origin_without_inheriting_baked_workload() {
        use std::time::{Duration, Instant};
        let temp = tempfile::tempdir().unwrap();
        let engine = test_engine(temp.path());
        let resources = Resources {
            cpus: 1,
            memory_mib: 512,
            storage_gib: 1,
            overlay_gib: 1,
        };
        let blob = crate::registry_artifact::tests::sidecar_fixture(
            &engine.domain.directory,
            crate::oci::native_oci_platform(),
        );
        let mut artifact = engine
            .qualify_registry_blob(
                blob,
                resources,
                Instant::now() + Duration::from_secs(3),
                Cancellation::new(),
            )
            .unwrap();
        artifact.prepared.manifest.entrypoint = vec!["private-start".into()];
        artifact.prepared.manifest.cmd = vec!["private-argument".into()];
        artifact.prepared.manifest.env.push("PRIVATE=baked".into());
        let request = CreateRequest {
            name: "prepared".into(),
            owner_token: "a".repeat(64),
            incarnation: "b".repeat(32),
            resources,
            labels: BTreeMap::new(),
            artifact: ApprovedArtifact {
                path: artifact.prepared.path.clone(),
                sha256: artifact.source.content_sha256.clone(),
                max_bytes: 1024 * 1024,
                guest_platform: artifact.source.platform.clone(),
            },
        };
        let record = prepared_pack_record(
            &request,
            &artifact.prepared,
            PackRecordPolicy::default(),
            Some(&artifact.source.reference),
        )
        .unwrap();
        assert_eq!(
            record.source_registry_ref.as_deref(),
            Some(artifact.source.reference.as_str())
        );
        assert_eq!(
            record.source_smolmachine.as_deref(),
            artifact.prepared.path.to_str()
        );
        assert_eq!(record.entrypoint, vec!["/bin/true"]);
        assert!(record.cmd.is_empty());
        assert!(record.env.is_empty());
        assert_eq!(record.user.as_deref(), Some("0"));
        assert_eq!(record.workdir.as_deref(), Some("/"));
        assert!(!record.network);
        let local = prepared_pack_record(
            &request,
            &artifact.prepared,
            PackRecordPolicy::default(),
            None,
        )
        .unwrap();
        assert_ne!(
            material_hash(&record).unwrap(),
            material_hash(&local).unwrap()
        );
        assert!(local.source_registry_ref.is_none());
        assert!(reject_unqualified_oci_boot(&record).is_ok());
    }

    #[test]
    fn registry_cached_qualification_rechecks_size_policy_and_pack_without_host_fetch() {
        use std::time::{Duration, Instant};
        let temp = tempfile::tempdir().unwrap();
        let engine = test_engine(temp.path());
        let blob = crate::registry_artifact::tests::sidecar_fixture(
            &engine.domain.directory,
            crate::oci::native_oci_platform(),
        );
        let source = blob.source().clone();
        let size = blob.size();
        let path = blob.path().to_owned();
        let resources = Resources {
            cpus: 1,
            memory_mib: 512,
            storage_gib: 1,
            overlay_gib: 1,
        };
        let policy = crate::RegistryCachePolicy {
            max_bytes: size,
            max_files: 1,
        };
        for (source, size, policy, allowed) in [
            (source.clone(), size, policy, true),
            (source.clone(), size + 1, policy, false),
            (
                source.clone(),
                size,
                crate::RegistryCachePolicy {
                    max_bytes: size - 1,
                    max_files: 1,
                },
                false,
            ),
            (
                crate::RegistryArtifactSource {
                    content_sha256: "c".repeat(64),
                    ..source
                },
                size,
                policy,
                false,
            ),
        ] {
            let result = engine.qualify_registry_cached(
                source,
                size,
                policy,
                resources,
                Instant::now() + Duration::from_secs(3),
                Cancellation::new(),
            );
            if allowed {
                assert!(result.unwrap().prepared.verified.covers(&path));
            } else {
                assert!(result.is_err());
            }
            assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
            assert!(engine.owned_handles.lock().unwrap().is_empty());
            assert!(engine.owned_managers.lock().unwrap().is_empty());
        }
        assert_eq!(
            std::fs::read_dir(engine.domain.directory.join("registry-blobs"))
                .unwrap()
                .count(),
            1
        );
        assert!(!engine.domain.directory.join("artifacts").exists());
    }

    #[test]
    fn checkpoint_intent_absence_never_restores_or_recovers_authority() {
        let temp = tempfile::tempdir().unwrap();
        let engine = test_engine(temp.path());
        let receipt = install_record(&engine);
        let before = serde_json::to_vec(&engine.db.get_vm(&receipt.name).unwrap()).unwrap();
        let mut intent = CheckpointCreationIntent {
            name: "missing-checkpoint".into(),
            owner_token: "a".repeat(64),
            incarnation: "b".repeat(32),
            source_sha256: "c".repeat(64),
            resources: Resources {
                cpus: 1,
                memory_mib: 256,
                storage_gib: 1,
                overlay_gib: 1,
            },
            labels: BTreeMap::new(),
        };
        assert_eq!(
            engine
                .inspect_checkpoint_creation(&intent, &read_budget())
                .unwrap(),
            CreationPresence::Absent
        );
        assert!(engine.db.get_vm(&intent.name).unwrap().is_none());
        intent.name = receipt.name.clone();
        assert_eq!(
            engine
                .inspect_checkpoint_creation(&intent, &read_budget())
                .unwrap(),
            CreationPresence::Unverified
        );
        intent.name = "partial-checkpoint".into();
        std::fs::create_dir_all(engine.vm_directory(&intent.name)).unwrap();
        assert_eq!(
            engine
                .inspect_checkpoint_creation(&intent, &read_budget())
                .unwrap(),
            CreationPresence::Unverified
        );
        engine.jobs.quarantine();
        intent.name = "missing-checkpoint".into();
        assert_eq!(
            engine
                .inspect_checkpoint_creation(&intent, &read_budget())
                .unwrap(),
            CreationPresence::Absent
        );
        intent.source_sha256 = "invalid".into();
        assert_eq!(
            engine
                .inspect_checkpoint_creation(&intent, &read_budget())
                .unwrap_err()
                .code,
            ErrorCode::Validation
        );
        assert_eq!(
            serde_json::to_vec(&engine.db.get_vm(&receipt.name).unwrap()).unwrap(),
            before
        );
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
        assert!(engine.owned_handles.lock().unwrap().is_empty());
        assert!(!std::fs::read_dir(&engine.domain.directory)
            .unwrap()
            .any(|entry| {
                entry
                    .unwrap()
                    .file_name()
                    .to_string_lossy()
                    .starts_with(".checkpoint-source-")
            }));
    }

    #[test]
    fn registry_intent_absence_is_read_only_in_quarantine_and_never_prepares_cache() {
        let temp = tempfile::tempdir().unwrap();
        let engine = test_engine(temp.path());
        let receipt = install_record(&engine);
        let before = serde_json::to_vec(&engine.db.get_vm(&receipt.name).unwrap()).unwrap();
        let mut intent = RegistryCreationIntent {
            name: "missing-registry".into(),
            owner_token: "a".repeat(64),
            incarnation: "b".repeat(32),
            source: crate::RegistryArtifactSource {
                reference: format!("registry.example/team/app@sha256:{}", "a".repeat(64)),
                platform: crate::oci::native_oci_platform().into(),
                content_sha256: "b".repeat(64),
            },
            resources: Resources {
                cpus: 1,
                memory_mib: 512,
                storage_gib: 1,
                overlay_gib: 1,
            },
            labels: BTreeMap::new(),
            features: crate::CreationFeatures {
                network: crate::NetworkPolicy {
                    enabled: false,
                    hosts: vec![],
                    cidrs: vec![],
                },
                ports: vec![],
                workload: None,
            },
        };
        assert_eq!(
            engine
                .inspect_registry_creation(&intent, &read_budget())
                .unwrap(),
            CreationPresence::Absent
        );
        let error = engine
            .create_registry_cached(
                intent.clone(),
                123,
                crate::RegistryCachePolicy {
                    max_bytes: 123,
                    max_files: 1,
                },
                std::time::Instant::now() + std::time::Duration::from_secs(3),
                &Cancellation::new(),
            )
            .err()
            .unwrap();
        assert_eq!(error.code, ErrorCode::Unsupported);
        assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
        let error = engine
            .qualify_registry_intent(
                &intent.source,
                intent.resources,
                None,
                &intent.features,
                &read_budget(),
            )
            .err()
            .unwrap();
        assert_eq!(error.code, ErrorCode::Unsupported);
        assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
        intent.name = receipt.name.clone();
        assert_eq!(
            engine
                .inspect_registry_creation(&intent, &read_budget())
                .unwrap(),
            CreationPresence::Unverified
        );
        intent.name = "partial-registry".into();
        std::fs::create_dir_all(engine.vm_directory(&intent.name)).unwrap();
        assert_eq!(
            engine
                .inspect_registry_creation(&intent, &read_budget())
                .unwrap(),
            CreationPresence::Unverified
        );
        engine.jobs.quarantine();
        intent.name = "missing-registry".into();
        assert_eq!(
            engine
                .inspect_registry_creation(&intent, &read_budget())
                .unwrap(),
            CreationPresence::Absent
        );
        assert!(!engine.domain.directory.join("registry-blobs").exists());
        assert!(!engine.domain.directory.join("artifacts").exists());
        assert_eq!(
            serde_json::to_vec(&engine.db.get_vm(&receipt.name).unwrap()).unwrap(),
            before
        );
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
        assert!(engine.owned_handles.lock().unwrap().is_empty());
    }

    #[test]
    fn registry_cached_qualification_does_not_create_missing_cache() {
        use std::time::{Duration, Instant};
        let temp = tempfile::tempdir().unwrap();
        let engine = test_engine(temp.path());
        let source = crate::RegistryArtifactSource {
            reference: format!("registry.example/team/app@sha256:{}", "a".repeat(64)),
            platform: crate::oci::native_oci_platform().into(),
            content_sha256: "b".repeat(64),
        };
        let result = engine.qualify_registry_cached(
            source,
            123,
            crate::RegistryCachePolicy {
                max_bytes: 123,
                max_files: 1,
            },
            Resources {
                cpus: 1,
                memory_mib: 512,
                storage_gib: 1,
                overlay_gib: 1,
            },
            Instant::now() + Duration::from_secs(3),
            Cancellation::new(),
        );
        assert!(result.is_err());
        assert!(!engine.domain.directory.join("registry-blobs").exists());
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
    }

    pub(crate) fn install_record(engine: &Engine) -> CreationReceipt {
        install_named_record(engine, "owned")
    }

    #[test]
    fn mounted_guest_work_requires_policy_and_running_backing_before_worker_or_sdk_entry() {
        let temp = tempfile::tempdir().unwrap();
        let engine = test_engine(temp.path());
        let (_volume_directory, mounts) = crate::volumes::owned_handle(&engine);
        let name = "mounted-command";
        let owner = "b".repeat(64);
        let incarnation = "c".repeat(32);
        let directory = engine.vm_directory(name);
        std::fs::create_dir_all(&directory).unwrap();
        let mut record = VmRecord::new(name.into(), 1, 256, vec![], vec![], false);
        record.storage_gb = Some(1);
        record.overlay_gb = Some(1);
        record.image = Some(format!("registry.example/app@sha256:{}", "d".repeat(64)));
        record.labels.insert("smolbox.owner".into(), owner.clone());
        record
            .labels
            .insert("smolbox.incarnation".into(), incarnation.clone());
        let material = engine
            .bind_volume_mount_material(&mounts, &mut record, &read_budget())
            .unwrap();
        let policy = material.mounts[0].proof.backing.policy.clone();
        assert!(engine.db.reserve_vm_create(name, &owner).unwrap());
        let origin = engine
            .commit_created_record(name, &owner, &incarnation, &record)
            .unwrap();
        let receipt = crate::material::MaterialJournal::at(&directory)
            .initialize_mounted(&origin, &record, material)
            .unwrap();
        assert!(engine
            .worker_mounts(&receipt, &record, None, &read_budget())
            .is_err());
        let error = engine
            .reserve_mounted_worker(
                &receipt,
                Some(mounts),
                crate::jobs::Demand::command(1024, 1024).unwrap(),
                &read_budget(),
            )
            .err()
            .unwrap();
        assert_eq!(error.code, ErrorCode::State);
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
        let before = serde_json::to_vec(&engine.db.get_vm(name).unwrap()).unwrap();
        let command = crate::BufferedCommand {
            argv: vec!["true".into()],
            env: vec![],
            workdir: None,
            user: None,
            stdin: None,
            timeout: std::time::Duration::from_secs(1),
            max_output_bytes: 1024,
        };
        for error in [
            engine
                .exec_buffered(&receipt, command.clone(), Cancellation::new(), |_| Ok(()))
                .err()
                .unwrap(),
            engine
                .exec_stream_owned(&receipt, command.clone(), Cancellation::new(), |_| Ok(()))
                .err()
                .unwrap(),
            engine
                .exec_background(&receipt, command.clone(), Cancellation::new())
                .err()
                .unwrap(),
            engine
                .exec(
                    &receipt,
                    Command {
                        argv: vec!["true".into()],
                        env: vec![],
                        workdir: None,
                        user: None,
                        timeout: std::time::Duration::from_secs(1),
                        max_output_bytes: 1024,
                    },
                    Cancellation::new(),
                    |_| Ok(()),
                )
                .err()
                .unwrap(),
        ] {
            assert_eq!(error.code, ErrorCode::Ownership);
            assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
        }
        for error in [
            engine
                .exec_buffered_with_volume_policy(
                    &receipt,
                    command.clone(),
                    Cancellation::new(),
                    |_| Ok(()),
                    &policy,
                )
                .err()
                .unwrap(),
            engine
                .exec_stream_owned_with_volume_policy(
                    &receipt,
                    command.clone(),
                    Cancellation::new(),
                    |_| Ok(()),
                    &policy,
                )
                .err()
                .unwrap(),
            engine
                .exec_background_with_volume_policy(&receipt, command, Cancellation::new(), &policy)
                .err()
                .unwrap(),
        ] {
            assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
        }
        let file_options = || crate::FileOptions {
            guest_path: "/mnt/volumes/data/value".into(),
            max_bytes: 1024,
            timeout: std::time::Duration::from_secs(1),
            mode: None,
        };
        struct Unread;
        impl std::io::Read for Unread {
            fn read(&mut self, _: &mut [u8]) -> std::io::Result<usize> {
                panic!("unqualified file input must not be read");
            }
        }
        let file_output = std::cell::Cell::new(0);
        for error in [
            engine
                .read_file(&receipt, file_options(), Cancellation::new(), |_| {
                    file_output.set(file_output.get() + 1);
                    Ok(())
                })
                .err()
                .unwrap(),
            engine
                .write_file(&receipt, file_options(), b"data", Cancellation::new())
                .err()
                .unwrap(),
            engine
                .write_file_from_reader(&receipt, file_options(), Unread, 4, Cancellation::new())
                .err()
                .unwrap(),
        ] {
            assert_eq!(error.code, ErrorCode::Ownership);
            assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
        }
        for error in [
            engine
                .read_file_with_volume_policy(
                    &receipt,
                    file_options(),
                    Cancellation::new(),
                    |_| {
                        file_output.set(file_output.get() + 1);
                        Ok(())
                    },
                    &policy,
                )
                .err()
                .unwrap(),
            engine
                .write_file_with_volume_policy(
                    &receipt,
                    file_options(),
                    b"data",
                    Cancellation::new(),
                    &policy,
                )
                .err()
                .unwrap(),
            engine
                .write_file_from_reader_with_volume_policy(
                    &receipt,
                    file_options(),
                    Unread,
                    4,
                    Cancellation::new(),
                    &policy,
                )
                .err()
                .unwrap(),
        ] {
            assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
        }
        let mut crossed_policy = policy.clone();
        crossed_policy.id.push_str("-other");
        assert!(engine
            .write_file_from_reader_with_volume_policy(
                &receipt,
                file_options(),
                Unread,
                4,
                Cancellation::new(),
                &crossed_policy
            )
            .is_err());
        assert_eq!(file_output.get(), 0);
        let request = || crate::TerminalRequest {
            options: crate::TerminalOptions {
                program: "/bin/sh".into(),
                cols: 80,
                rows: 24,
                session: std::time::Duration::from_secs(1),
                idle: std::time::Duration::from_secs(1),
                attach: std::time::Duration::from_millis(100),
                close: std::time::Duration::from_millis(1),
                max_buffer_bytes: 1024,
                max_input_bytes: 65536,
                total_input_bytes: 1048576,
            },
            deadline: std::time::Instant::now() + std::time::Duration::from_secs(1),
            cancel: Cancellation::new(),
        };
        let controls = std::cell::Cell::new(0);
        let output = std::cell::Cell::new(0);
        let error = engine
            .terminal_owned(
                &receipt,
                request(),
                || {
                    controls.set(controls.get() + 1);
                    Ok(None)
                },
                |_| {
                    output.set(output.get() + 1);
                    Ok(())
                },
            )
            .err()
            .unwrap();
        assert_eq!(error.code, ErrorCode::Ownership);
        assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
        let error = engine
            .terminal_owned_with_volume_policy(
                &receipt,
                request(),
                || {
                    controls.set(controls.get() + 1);
                    Ok(None)
                },
                |_| {
                    output.set(output.get() + 1);
                    Ok(())
                },
                &policy,
            )
            .err()
            .unwrap();
        assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
        assert_eq!(controls.get(), 0);
        assert_eq!(output.get(), 0);
        assert_eq!(
            serde_json::to_vec(&engine.db.get_vm(name).unwrap()).unwrap(),
            before
        );
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
        assert!(engine.owned_handles.lock().unwrap().is_empty());
        assert!(!engine.domain.directory.join("transfers").exists());
    }

    #[test]
    fn mounted_oci_handoff_keeps_volume_gate_and_job_until_explicit_drop() {
        let temp = tempfile::tempdir().unwrap();
        let engine = test_engine(temp.path());
        let (_volume_directory, mut mounts) = crate::volumes::owned_handle(&engine);
        let gate = engine
            .gate(&format!("volume:sbv-{}", "c".repeat(32)))
            .unwrap();
        assert!(gate.try_lock().is_err());
        let permit = mounts.take_oci_lease().unwrap();
        mounts.recheck_before_launch(&read_budget()).unwrap();
        let before = engine.jobs.counts();
        assert_eq!(before.work, 1);
        assert_eq!(before.children, 2);
        let authority = mounts.into_worker_authority().unwrap();
        assert_eq!(engine.jobs.counts(), before);
        assert!(gate.try_lock().is_err());
        drop(authority);
        assert!(gate.try_lock().is_ok());
        assert_eq!(engine.jobs.counts(), before);
        drop(permit);
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
        // A second fixture uses a fresh private ledger rather than replaying
        // the already completed provision under the same generated intent.
        let temp = tempfile::tempdir().unwrap();
        let engine = test_engine(temp.path());
        let (_volume_directory, mounts) = crate::volumes::owned_handle(&engine);
        assert!(mounts.into_worker_authority().is_err());
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
    }

    #[test]
    fn mounted_start_requires_full_saved_proof_and_retains_admission_before_sdk_entry() {
        use std::time::{Duration, Instant};
        for changed_proof in [false, true] {
            let temp = tempfile::tempdir().unwrap();
            let engine = test_engine(temp.path());
            let (_volume_directory, mounts) = crate::volumes::owned_handle(&engine);
            let name = "mounted-owned";
            let owner = "b".repeat(64);
            let incarnation = "c".repeat(32);
            let directory = engine.vm_directory(name);
            std::fs::create_dir_all(&directory).unwrap();
            let mut record = VmRecord::new(name.into(), 1, 256, vec![], vec![], false);
            record.storage_gb = Some(1);
            record.overlay_gb = Some(1);
            record.labels.insert("smolbox.owner".into(), owner.clone());
            record
                .labels
                .insert("smolbox.incarnation".into(), incarnation.clone());
            let mut material = engine
                .bind_volume_mount_material(&mounts, &mut record, &read_budget())
                .unwrap();
            if changed_proof {
                material.mounts[0].proof.backing.inode += 1;
                record.labels.insert(
                    crate::mount_material::MOUNT_LABEL.into(),
                    material.digest().unwrap(),
                );
            }
            assert!(engine.db.reserve_vm_create(name, &owner).unwrap());
            let origin = engine
                .commit_created_record(name, &owner, &incarnation, &record)
                .unwrap();
            let receipt = crate::material::MaterialJournal::at(&directory)
                .initialize_mounted(&origin, &record, material)
                .unwrap();
            let before = serde_json::to_vec(&engine.db.get_vm(name).unwrap()).unwrap();
            assert_eq!(
                engine.start(&receipt).err().unwrap().code,
                ErrorCode::Ownership
            );
            let verified = engine.verify_machine_mounts(&receipt, &record, &mounts, &read_budget());
            assert_eq!(verified.is_ok(), !changed_proof);
            let error = engine
                .start_with_volume_mounts(
                    &receipt,
                    mounts,
                    Instant::now() + Duration::from_secs(1),
                    &Cancellation::new(),
                )
                .err()
                .unwrap();
            assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
            assert_eq!(
                error.code,
                if changed_proof {
                    ErrorCode::Ownership
                } else {
                    ErrorCode::Unsupported
                }
            );
            assert_eq!(
                serde_json::to_vec(&engine.db.get_vm(name).unwrap()).unwrap(),
                before
            );
            assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
            assert!(engine.owned_handles.lock().unwrap().is_empty());
            assert!(engine.owned_managers.lock().unwrap().is_empty());
        }
    }

    #[test]
    fn mounted_start_cancel_and_foreign_handle_reject_before_record_or_sdk_entry() {
        use std::time::{Duration, Instant};
        let temp = tempfile::tempdir().unwrap();
        let engine = test_engine(temp.path());
        let receipt = install_record(&engine);
        let before = serde_json::to_vec(&engine.db.get_vm(&receipt.name).unwrap()).unwrap();
        for cancelled in [true, false] {
            let (_directory, mounts) = crate::volumes::foreign_handle();
            let cancel = Cancellation::new();
            if cancelled {
                cancel.cancel();
            }
            let error = engine
                .start_with_volume_mounts(
                    &receipt,
                    mounts,
                    Instant::now() + Duration::from_secs(1),
                    &cancel,
                )
                .err()
                .unwrap();
            assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
            assert_eq!(
                error.code,
                if cancelled {
                    ErrorCode::State
                } else {
                    ErrorCode::Ownership
                }
            );
            assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
        }
        assert_eq!(
            serde_json::to_vec(&engine.db.get_vm(&receipt.name).unwrap()).unwrap(),
            before
        );
        assert!(engine.owned_handles.lock().unwrap().is_empty());
    }

    #[test]
    fn mounted_source_preparation_rejects_crossed_authority_and_cancel_without_cache_or_jobs() {
        use std::time::{Duration, Instant};
        let temp = tempfile::tempdir().unwrap();
        let engine = test_engine(temp.path());
        let receipt = install_record(&engine);
        let before = serde_json::to_vec(&engine.db.get_vm(&receipt.name).unwrap()).unwrap();
        let value: serde_json::Value = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/mounted-creation-request.json"
        ))
        .unwrap();
        let selection = || {
            let requests: Vec<crate::VolumeMountRequest> =
                serde_json::from_value(value["operation"]["create"]["volume_mounts"].clone())
                    .unwrap();
            crate::VolumeMountSelection {
                policy: requests[0].proof.backing.policy.clone(),
                requests,
            }
        };
        for cancelled in [false, true] {
            let cancel = Cancellation::new();
            if cancelled {
                cancel.cancel();
            }
            let resources = Resources {
                cpus: 1,
                memory_mib: 256,
                storage_gib: 1,
                overlay_gib: 1,
            };
            let oci = OciCreationIntent {
                name: "mounted-fresh".into(),
                owner_token: "b".repeat(64),
                incarnation: "c".repeat(32),
                resources,
                labels: BTreeMap::new(),
                source: crate::oci::tests::verified().source().clone(),
                features: crate::oci::tests::features(),
            };
            let registry = RegistryCreationIntent {
                name: oci.name.clone(),
                owner_token: oci.owner_token.clone(),
                incarnation: oci.incarnation.clone(),
                resources,
                labels: BTreeMap::new(),
                features: oci.features.clone(),
                source: crate::RegistryArtifactSource {
                    reference: oci.source.reference.clone(),
                    platform: oci.source.platform.clone(),
                    content_sha256: "d".repeat(64),
                },
            };
            let expected = if cancelled {
                ErrorCode::State
            } else {
                ErrorCode::Ownership
            };
            for error in [
                engine
                    .create_oci_intent_with_mount_selection(
                        oci,
                        selection(),
                        Instant::now() + Duration::from_secs(1),
                        &cancel,
                    )
                    .err()
                    .unwrap(),
                engine
                    .create_registry_cached_with_mount_selection(
                        registry,
                        (
                            1024,
                            crate::RegistryCachePolicy {
                                max_bytes: 1024,
                                max_files: 1,
                            },
                        ),
                        selection(),
                        Instant::now() + Duration::from_secs(1),
                        &cancel,
                    )
                    .err()
                    .unwrap(),
            ] {
                assert_eq!(error.code, expected);
                assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
            }
            assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
            assert!(!engine.vm_directory("mounted-fresh").exists());
            assert!(!engine.domain.directory.join("registry-blobs").exists());
            assert!(!engine.domain.directory.join("artifacts").exists());
        }
        assert_eq!(
            serde_json::to_vec(&engine.db.get_vm(&receipt.name).unwrap()).unwrap(),
            before
        );
        assert!(engine.owned_handles.lock().unwrap().is_empty());
    }

    #[test]
    fn source_intent_absence_is_read_only_and_cannot_adopt_existing_inventory_or_partial_storage() {
        let temp = tempfile::tempdir().unwrap();
        let engine = test_engine(temp.path());
        let receipt = install_record(&engine);
        let before = serde_json::to_vec(&engine.db.get_vm(&receipt.name).unwrap()).unwrap();
        let mut intent = OciCreationIntent {
            name: "source-fresh".into(),
            owner_token: "b".repeat(64),
            incarnation: "c".repeat(32),
            source: crate::oci::tests::verified().source().clone(),
            resources: Resources {
                cpus: 1,
                memory_mib: 256,
                storage_gib: 1,
                overlay_gib: 1,
            },
            labels: Default::default(),
            features: crate::oci::tests::features(),
        };
        assert!(matches!(
            engine
                .inspect_oci_creation(&intent, &read_budget())
                .unwrap(),
            CreationPresence::Absent
        ));
        intent.name = receipt.name.clone();
        assert!(matches!(
            engine
                .inspect_oci_creation(&intent, &read_budget())
                .unwrap(),
            CreationPresence::Unverified
        ));
        intent.name = "source-partial".into();
        std::fs::create_dir_all(engine.vm_directory(&intent.name)).unwrap();
        assert!(matches!(
            engine
                .inspect_oci_creation(&intent, &read_budget())
                .unwrap(),
            CreationPresence::Unverified
        ));
        assert_eq!(
            serde_json::to_vec(&engine.db.get_vm(&receipt.name).unwrap()).unwrap(),
            before
        );
        assert!(engine.owned_handles.lock().unwrap().is_empty());
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
        assert!(!engine.domain.directory.join("transfers").exists());
    }

    #[test]
    fn oci_creation_authority_requires_fresh_reservation_and_retains_original_source_identity() {
        let temp = tempfile::tempdir().unwrap();
        let engine = test_engine(temp.path());
        let source = crate::oci::tests::verified();
        let features = crate::oci::tests::features();
        let resources = Resources {
            cpus: 1,
            memory_mib: 256,
            storage_gib: 1,
            overlay_gib: 1,
        };
        let name = "oci-owned";
        let token = "b".repeat(64);
        let incarnation = "c".repeat(32);
        let directory = engine.vm_directory(name);
        std::fs::create_dir_all(&directory).unwrap();
        let labels = BTreeMap::from([
            ("smolbox.owner".into(), token.clone()),
            ("smolbox.incarnation".into(), incarnation.clone()),
        ]);
        let record = source.record(name, resources, labels, &features).unwrap();
        assert!(engine.db.reserve_vm_create(name, &token).unwrap());
        let origin = engine
            .commit_created_record(name, &token, &incarnation, &record)
            .unwrap();
        let receipt = crate::material::MaterialJournal::at(&directory)
            .initialize(&origin)
            .unwrap();
        let different = crate::ImagePullRequest {
            reference: format!("registry.example/another@sha256:{}", "d".repeat(64)),
            platform: source.source().platform.clone(),
        };
        engine.qualify_image_pull(&receipt, &different).unwrap();
        assert_eq!(
            engine.start(&receipt).err().unwrap().code,
            ErrorCode::Unsupported
        );
        assert!(engine.runtime_pid(name).is_none());
        assert!(engine.qualify_image_pull(&origin, &different).is_err());
        let mut packed = record.clone();
        packed.name = "packed-origin".into();
        packed.source_smolmachine = Some("/approved/import.smolmachine".into());
        let pack_directory = engine.vm_directory(&packed.name);
        std::fs::create_dir_all(&pack_directory).unwrap();
        assert!(engine.db.reserve_vm_create(&packed.name, &token).unwrap());
        let pack_origin = engine
            .commit_created_record(&packed.name, &token, &incarnation, &packed)
            .unwrap();
        let pack_receipt = crate::material::MaterialJournal::at(&pack_directory)
            .initialize(&pack_origin)
            .unwrap();
        assert_eq!(
            engine
                .qualify_image_pull(&pack_receipt, &different)
                .err()
                .unwrap()
                .code,
            ErrorCode::Unsupported
        );

        assert_eq!(
            receipt.material_sha256,
            crate::identity::material_hash(&record).unwrap()
        );
        assert!(engine
            .commit_created_record(name, &token, &incarnation, &record)
            .is_err());
        let mut changed = record.clone();
        changed.source_smolmachine = Some("/approved/import.smolmachine".into());
        engine.db.update_vm(name, |r| *r = changed.clone()).unwrap();
        assert!(engine.qualify_image_pull(&receipt, &different).is_err());
        assert_ne!(
            crate::identity::material_hash(&changed).unwrap(),
            receipt.material_sha256
        );
    }
    #[test]
    fn owned_pull_rejects_stopped_origin_and_cancelled_budget_without_worker_staging_or_replay() {
        use sha2::{Digest, Sha256};
        use std::os::unix::fs::PermissionsExt;
        let temp = tempfile::tempdir().unwrap();
        let mut engine = test_engine(temp.path());
        let source = crate::oci::tests::verified();
        let token = "b".repeat(64);
        let incarnation = "c".repeat(32);
        let name = "oci-owned";
        let directory = engine.vm_directory(name);
        std::fs::create_dir_all(&directory).unwrap();
        let record = source
            .record(
                name,
                Resources {
                    cpus: 1,
                    memory_mib: 256,
                    storage_gib: 1,
                    overlay_gib: 1,
                },
                BTreeMap::from([
                    ("smolbox.owner".into(), token.clone()),
                    ("smolbox.incarnation".into(), incarnation.clone()),
                ]),
                &crate::oci::tests::features(),
            )
            .unwrap();
        assert!(engine.db.reserve_vm_create(name, &token).unwrap());
        let origin = engine
            .commit_created_record(name, &token, &incarnation, &record)
            .unwrap();
        let receipt = crate::material::MaterialJournal::at(&directory)
            .initialize(&origin)
            .unwrap();
        let executable = temp.path().canonicalize().unwrap().join("inert-worker");
        std::fs::write(&executable, b"not a runnable helper").unwrap();
        std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o700)).unwrap();
        let identity = crate::Executable {
            path: executable,
            sha256: hex::encode(Sha256::digest(b"not a runnable helper")),
        };
        let host = crate::HostContext::capture(
            engine.binding.clone(),
            "d".repeat(32),
            "e".repeat(64),
            crate::ExecutableLocator {
                boot: identity.clone(),
                file_worker: identity,
                library_directory: engine.domain.directory.clone(),
            },
        )
        .unwrap();
        engine.transfers = Some(TransferSupervisor::new(&host, engine.jobs.clone()).unwrap());
        let mut crossed_source = source.source().clone();
        crossed_source.reference = format!("registry.example/other@sha256:{}", "a".repeat(64));
        let error = engine
            .start_oci_source_owned(
                &receipt,
                &crossed_source,
                std::time::Instant::now() + std::time::Duration::from_secs(5),
                Cancellation::new(),
            )
            .err()
            .unwrap();
        assert_eq!(error.code, ErrorCode::Ownership);
        assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
        assert!(engine.owned_managers.lock().unwrap().is_empty());
        let before = serde_json::to_value(engine.db.get_vm(name).unwrap().unwrap()).unwrap();
        let cancel = Cancellation::new();
        cancel.cancel();
        for cancellation in [cancel, Cancellation::new()] {
            let error = engine
                .pull_image_owned(
                    &receipt,
                    source.source().clone(),
                    std::time::Instant::now() + std::time::Duration::from_secs(5),
                    cancellation,
                )
                .err()
                .unwrap();
            assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
            assert_eq!(error.code, ErrorCode::State);
            assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
            assert!(!directory.join("agent.sock").exists());
            assert_eq!(
                serde_json::to_value(engine.db.get_vm(name).unwrap().unwrap()).unwrap(),
                before
            );
        }
        let cancel = Cancellation::new();
        cancel.cancel();
        let error = engine
            .start_oci_owned(
                &receipt,
                std::time::Instant::now() + std::time::Duration::from_secs(5),
                cancel,
            )
            .unwrap_err();
        assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
        assert_eq!(error.code, ErrorCode::State);
        let error = engine
            .start_oci_owned(
                &receipt,
                std::time::Instant::now() + std::time::Duration::from_secs(5),
                Cancellation::new(),
            )
            .unwrap_err();
        assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
        assert_eq!(error.code, ErrorCode::Unsupported);
        assert!(engine.owned_managers.lock().unwrap().is_empty());
        assert!(engine.owned_handles.lock().unwrap().is_empty());
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
        assert!(!engine.domain.directory.join("transfers").exists());
        assert_eq!(
            serde_json::to_value(engine.db.get_vm(name).unwrap().unwrap()).unwrap(),
            before
        );
    }

    #[test]
    fn bounded_owned_record_reads_ignore_unrelated_json_but_reject_overlimit_identity_and_cancel() {
        let temp = tempfile::tempdir().unwrap();
        let engine = test_engine(temp.path());
        let receipt = install_record(&engine);
        let db = rusqlite::Connection::open(&engine.binding.database).unwrap();
        db.execute(
            "INSERT INTO vms(name,data) VALUES (?1,?2)",
            rusqlite::params!["unrelated", "not JSON"],
        )
        .unwrap();
        let record = engine
            .observation_record(&receipt.name, &read_budget())
            .unwrap()
            .unwrap();
        assert!(receipt.matches(&record).unwrap());
        assert!(engine
            .observation_record("missing", &read_budget())
            .unwrap()
            .is_none());
        let original: Vec<u8> = db
            .query_row("SELECT data FROM vms WHERE name=?1", [&receipt.name], |r| {
                r.get(0)
            })
            .unwrap();
        db.execute(
            "UPDATE vms SET data=?2 WHERE name=?1",
            rusqlite::params![
                &receipt.name,
                " ".repeat(crate::observations::MAX_RECORD_BYTES + 1)
            ],
        )
        .unwrap();
        assert_eq!(
            engine
                .observation_record(&receipt.name, &read_budget())
                .err()
                .unwrap()
                .code,
            ErrorCode::OutputLimit
        );
        let mut changed: serde_json::Value = serde_json::from_slice(&original).unwrap();
        changed["name"] = serde_json::json!("different");
        db.execute(
            "UPDATE vms SET data=?2 WHERE name=?1",
            rusqlite::params![&receipt.name, serde_json::to_string(&changed).unwrap()],
        )
        .unwrap();
        assert_eq!(
            engine
                .observation_record(&receipt.name, &read_budget())
                .err()
                .unwrap()
                .code,
            ErrorCode::Database
        );
        db.execute(
            "UPDATE vms SET data=?2 WHERE name=?1",
            rusqlite::params![&receipt.name, &original],
        )
        .unwrap();
        let cancel = Cancellation::new();
        cancel.cancel();
        let budget = crate::ReadBudget::new(std::time::Duration::from_secs(1), cancel).unwrap();
        assert!(engine.observation_record(&receipt.name, &budget).is_err());
        assert_eq!(
            db.query_row::<Vec<u8>, _, _>(
                "SELECT data FROM vms WHERE name=?1",
                [&receipt.name],
                |r| r.get(0)
            )
            .unwrap(),
            original
        );
    }

    #[test]
    fn oci_create_cancellation_and_invalid_identity_reject_before_any_sdk_or_disk_mutation() {
        let temp = tempfile::tempdir().unwrap();
        let engine = test_engine(temp.path());
        let request = CreateOciRequest {
            name: "oci-owned".into(),
            owner_token: "b".repeat(64),
            incarnation: "c".repeat(32),
            resources: Resources {
                cpus: 1,
                memory_mib: 256,
                storage_gib: 1,
                overlay_gib: 1,
            },
            labels: BTreeMap::new(),
            source: crate::oci::tests::verified(),
            features: crate::oci::tests::features(),
        };
        let cancel = Cancellation::new();
        cancel.cancel();
        assert_eq!(
            engine
                .create_oci(
                    request.clone(),
                    std::time::Instant::now() + std::time::Duration::from_secs(1),
                    &cancel
                )
                .err()
                .unwrap()
                .dispatch,
            crate::Dispatch::NotDispatched
        );
        for cancelled in [true, false] {
            let (_directory, mounts) = crate::volumes::foreign_handle();
            let cancel = Cancellation::new();
            if cancelled {
                cancel.cancel();
            }
            let error = engine
                .create_oci_with_volume_mounts(
                    request.clone(),
                    mounts,
                    std::time::Instant::now() + std::time::Duration::from_secs(1),
                    &cancel,
                )
                .err()
                .unwrap();
            assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
            assert_eq!(
                error.code,
                if cancelled {
                    ErrorCode::State
                } else {
                    ErrorCode::Ownership
                }
            );
            assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
        }
        let mut invalid = request.clone();
        invalid.owner_token = "wrong".into();
        assert_eq!(
            engine
                .create_oci(
                    invalid,
                    std::time::Instant::now() + std::time::Duration::from_secs(1),
                    &Cancellation::new()
                )
                .err()
                .unwrap()
                .code,
            ErrorCode::Validation
        );
        assert!(!engine.vm_directory(&request.name).exists());
        assert!(engine.db.get_vm(&request.name).unwrap().is_none());
    }

    #[test]
    fn stopped_image_listing_is_empty_read_only_and_rejects_foreign_receipts() {
        let temp = tempfile::tempdir().unwrap();
        let engine = test_engine(temp.path());
        let receipt = install_record(&engine);
        let before = engine.db.get_vm(&receipt.name).unwrap().unwrap();
        assert!(engine
            .list_images(&receipt, &read_budget())
            .unwrap()
            .is_empty());
        let mut chunks = Vec::new();
        assert_eq!(
            engine
                .list_images_stream(&receipt, &read_budget(), |bytes| {
                    chunks.extend_from_slice(bytes);
                    Ok(())
                })
                .unwrap(),
            (0, 2)
        );
        assert_eq!(chunks, b"[]");
        assert!(engine
            .list_images_stream(&receipt, &read_budget(), |_| Err(()))
            .is_err());
        let after = engine.db.get_vm(&receipt.name).unwrap().unwrap();
        assert_eq!(
            serde_json::to_value(before).unwrap(),
            serde_json::to_value(after).unwrap()
        );
        assert!(!engine
            .vm_directory(&receipt.name)
            .join("agent.sock")
            .exists());
        assert!(engine.transfers.is_none());
        let mut foreign = receipt.clone();
        foreign.incarnation = "f".repeat(32);
        assert!(engine.list_images(&foreign, &read_budget()).is_err());
        let cancel = Cancellation::default();
        cancel.cancel();
        let budget = crate::ReadBudget::new(std::time::Duration::from_secs(1), cancel).unwrap();
        assert!(engine.list_images(&receipt, &budget).is_err());
    }

    fn entered_growth_model(
        engine: &Engine,
        entered: bool,
        witnessed: bool,
    ) -> (CreationReceipt, crate::GrowDisks, PathBuf) {
        let origin = install_record(engine);
        let directory = engine.vm_directory(&origin.name);
        let path = crate::disk_geometry::tests::raw(&directory);
        std::fs::rename(path, directory.join("overlay.raw")).unwrap();
        crate::disk_geometry::tests::raw(&directory);
        let journal = crate::material::MaterialJournal::at(&directory);
        let receipt = journal.initialize(&origin).unwrap();
        let storage =
            crate::disk_geometry::DiskGeometry::capture(&directory, "storage.raw", 1).unwrap();
        let overlay =
            crate::disk_geometry::DiskGeometry::capture(&directory, "overlay.raw", 1).unwrap();
        let request = crate::GrowDisks {
            storage_gib: Some(2),
            overlay_gib: None,
        };
        let record = engine.record(&receipt).unwrap();
        let permit = if witnessed {
            journal
                .prepare_geometry(
                    &receipt,
                    "repair",
                    request,
                    &record,
                    &crate::growth::Metadata::new(&storage, &overlay, request),
                )
                .unwrap()
        } else {
            journal
                .prepare(&receipt, "repair", request, &record)
                .unwrap()
        };
        if entered {
            journal.enter(&permit).unwrap();
        }
        (receipt, request, directory)
    }

    #[test]
    fn explicit_growth_qualification_requires_quiescence_entered_witness_and_complete_repair() {
        let temp = tempfile::tempdir().unwrap();
        let engine = test_engine(temp.path());
        let (receipt, request, directory) = entered_growth_model(&engine, true, true);
        let journal_path = directory.join("smolbox.material-v2.json");
        let before = std::fs::read(&journal_path).unwrap();
        assert_eq!(
            engine
                .qualify_growth(&receipt, "repair", request, (1, 1), false, &read_budget())
                .err()
                .unwrap()
                .code,
            ErrorCode::Validation
        );
        assert!(engine
            .qualify_growth(&receipt, "foreign", request, (1, 1), true, &read_budget())
            .is_err());
        assert!(engine
            .qualify_growth(&receipt, "repair", request, (1, 1), true, &read_budget())
            .is_err());
        assert_eq!(std::fs::read(&journal_path).unwrap(), before);

        // Deterministic operator-repair model. No helper/VM was ever dispatched,
        // interrupted or raced; only owned fixture files and its private DB.
        OpenOptions::new()
            .write(true)
            .open(directory.join("storage.raw"))
            .unwrap()
            .set_len(2u64 << 30)
            .unwrap();
        assert!(engine
            .qualify_growth(&receipt, "repair", request, (1, 1), true, &read_budget())
            .is_err());
        engine
            .db
            .update_vm(&receipt.name, |record| record.storage_gb = Some(2))
            .unwrap();
        let sdk_record =
            serde_json::to_value(engine.db.get_vm(&receipt.name).unwrap().unwrap()).unwrap();
        let pending = std::fs::read(&journal_path).unwrap();
        assert!(engine
            .qualify_growth(&receipt, "repair", request, (1, 2), true, &read_budget())
            .is_err());
        assert_eq!(std::fs::read(&journal_path).unwrap(), pending);
        let proof = engine
            .qualify_growth(&receipt, "repair", request, (1, 1), true, &read_budget())
            .unwrap();
        proof.validate().unwrap();
        assert_eq!(proof.previous, receipt);
        assert_eq!(proof.receipt.material.as_ref().unwrap().revision, 1);
        assert_eq!(proof.receipt.material_sha256, receipt.material_sha256);
        assert_eq!(
            serde_json::to_value(engine.db.get_vm(&receipt.name).unwrap().unwrap()).unwrap(),
            sdk_record
        );
        let journal: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&journal_path).unwrap()).unwrap();
        assert!(journal["pending"].is_null());
        assert_eq!(
            journal["history"][0]["qualified_geometry_sha256"]
                .as_str()
                .unwrap()
                .len(),
            64
        );
        assert_eq!(
            engine
                .qualify_growth(&receipt, "repair", request, (1, 1), true, &read_budget())
                .unwrap(),
            proof
        );
        assert_eq!(
            engine.inspect(&proof.receipt).unwrap().state,
            ObservedState::Stopped
        );
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
        assert!(engine.owned_handles.lock().unwrap().is_empty());
    }

    #[test]
    fn growth_qualification_cannot_adopt_prepared_legacy_or_substituted_geometry() {
        for (entered, witnessed) in [(false, true), (true, false), (true, true)] {
            let temp = tempfile::tempdir().unwrap();
            let engine = test_engine(temp.path());
            let (receipt, request, directory) = entered_growth_model(&engine, entered, witnessed);
            OpenOptions::new()
                .write(true)
                .open(directory.join("storage.raw"))
                .unwrap()
                .set_len(2u64 << 30)
                .unwrap();
            engine
                .db
                .update_vm(&receipt.name, |record| record.storage_gb = Some(2))
                .unwrap();
            if witnessed && entered {
                std::fs::rename(
                    directory.join("storage.raw"),
                    directory.join("retained.raw"),
                )
                .unwrap();
                let replacement = crate::disk_geometry::tests::raw(&directory);
                OpenOptions::new()
                    .write(true)
                    .open(replacement)
                    .unwrap()
                    .set_len(2u64 << 30)
                    .unwrap();
            }
            let before = std::fs::read(directory.join("smolbox.material-v2.json")).unwrap();
            assert!(engine
                .qualify_growth(&receipt, "repair", request, (1, 1), true, &read_budget())
                .is_err());
            assert_eq!(
                std::fs::read(directory.join("smolbox.material-v2.json")).unwrap(),
                before
            );
            assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
        }
    }

    #[test]
    fn explicit_growth_qualification_keeps_source_machine_and_quarantine_fences() {
        let temp = tempfile::tempdir().unwrap();
        let engine = test_engine(temp.path());
        let (receipt, request, directory) = entered_growth_model(&engine, true, true);
        let before = std::fs::read(directory.join("smolbox.material-v2.json")).unwrap();
        let gate = engine.gate(&receipt.name).unwrap();
        let held = gate.try_lock().unwrap();
        assert_eq!(
            engine
                .qualify_growth(&receipt, "repair", request, (1, 1), true, &read_budget())
                .err()
                .unwrap()
                .code,
            ErrorCode::Conflict
        );
        drop(held);
        let source = engine.source_lease(&receipt).unwrap();
        assert_eq!(
            engine
                .qualify_growth(&receipt, "repair", request, (1, 1), true, &read_budget())
                .err()
                .unwrap()
                .code,
            ErrorCode::Conflict
        );
        drop(source);
        engine.jobs.quarantine();
        assert_eq!(
            engine
                .qualify_growth(&receipt, "repair", request, (1, 1), true, &read_budget())
                .err()
                .unwrap()
                .code,
            ErrorCode::State
        );
        assert_eq!(
            std::fs::read(directory.join("smolbox.material-v2.json")).unwrap(),
            before
        );
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
    }

    #[test]
    #[ignore = "requires built helper; ordinary stopped sparse-file engine growth with private fixture database, no VM"]
    fn ordinary_engine_growth_commits_only_collected_geometry_and_preserves_creation_authority() {
        use sha2::Digest;
        use std::os::unix::fs::PermissionsExt;
        use std::time::{Duration, Instant};
        let temporary = tempfile::tempdir().unwrap();
        let mut engine = test_engine(temporary.path());
        let origin = install_record(&engine);
        let directory = engine.vm_directory(&origin.name);
        std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700)).unwrap();
        let path = crate::disk_geometry::tests::raw(&directory);
        std::fs::rename(&path, directory.join("overlay.raw")).unwrap();
        crate::disk_geometry::tests::raw(&directory);
        let receipt = crate::material::MaterialJournal::at(&directory)
            .initialize(&origin)
            .unwrap();
        let executable = PathBuf::from(
            std::env::var_os("SMOLBOX_TEST_FILE_WORKER").expect("set rebuilt helper path"),
        );
        let executable = crate::Executable {
            sha256: hex::encode(sha2::Sha256::digest(std::fs::read(&executable).unwrap())),
            path: executable,
        };
        let host = crate::HostContext::capture(
            engine.binding.clone(),
            "d".repeat(32),
            "e".repeat(64),
            crate::ExecutableLocator {
                boot: executable.clone(),
                file_worker: executable,
                library_directory: std::env::var_os("LIBKRUN_BUNDLE")
                    .expect("set private copied libraries")
                    .into(),
            },
        )
        .unwrap();
        engine.transfers = Some(TransferSupervisor::new(&host, engine.jobs.clone()).unwrap());
        let request = crate::GrowDisks {
            storage_gib: Some(2),
            overlay_gib: None,
        };
        let cancel = Cancellation::new();
        cancel.cancel();
        assert_eq!(
            engine
                .expand_disks_owned(
                    &receipt,
                    "grow",
                    request,
                    Instant::now() + Duration::from_secs(10),
                    &cancel
                )
                .unwrap_err()
                .dispatch,
            crate::Dispatch::NotDispatched
        );
        engine.record(&receipt).unwrap(); // No pending journal entry from pre-dispatch cancellation.
        let transition = engine
            .expand_disks_transition_owned(
                &receipt,
                "grow",
                request,
                Instant::now() + Duration::from_secs(10),
                &Cancellation::new(),
            )
            .unwrap();
        transition.validate().unwrap();
        assert_eq!(transition.previous, receipt);
        let updated = transition.receipt.clone();
        assert_eq!(
            engine
                .inspect_growth_transition(&receipt, "grow", request)
                .unwrap(),
            Some(transition)
        );
        assert_eq!(updated.material_sha256, origin.material_sha256);
        assert_eq!(updated.owner_token, origin.owner_token);
        assert_eq!(updated.incarnation, origin.incarnation);
        assert_eq!(updated.material.as_ref().unwrap().revision, 1);
        let record = engine.record(&updated).unwrap();
        assert_eq!(record.storage_gb, Some(2));
        assert_eq!(record.overlay_gb, Some(1));
        assert_eq!(
            engine.inspect(&updated).unwrap().state,
            ObservedState::Stopped
        );
        assert_eq!(
            engine
                .inspect_disk_transition(&receipt, "grow", request)
                .unwrap(),
            Some(updated.clone())
        );
        let error = engine
            .expand_disks_owned(
                &updated,
                "grow",
                crate::GrowDisks {
                    storage_gib: Some(3),
                    overlay_gib: None,
                },
                Instant::now() + Duration::from_secs(10),
                &Cancellation::new(),
            )
            .unwrap_err();
        assert_eq!(error.code, ErrorCode::Conflict);
        assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
        assert_eq!(engine.record(&updated).unwrap().storage_gb, Some(2));
        assert_eq!(engine.jobs.counts().work, 0);
        assert!(!directory.join("agent.sock").exists());
        assert!(engine.owned_handles.lock().unwrap().is_empty());
    }

    fn creation_intent(name: &str) -> CreateRequest {
        CreateRequest {
            name: name.into(),
            owner_token: "b".repeat(64),
            incarnation: "c".repeat(32),
            artifact: ApprovedArtifact {
                path: PathBuf::from("/approved/missing.smolmachine"),
                sha256: "d".repeat(64),
                max_bytes: 1024,
                guest_platform: "linux/arm64".into(),
            },
            resources: Resources {
                cpus: 1,
                memory_mib: 512,
                storage_gib: 1,
                overlay_gib: 1,
            },
            labels: BTreeMap::new(),
        }
    }

    #[test]
    fn intent_absence_does_not_prepare_missing_artifact_or_materialize_storage() {
        let temp = tempfile::tempdir().unwrap();
        let engine = test_engine(temp.path());
        assert_eq!(
            engine.inspect_creation(&creation_intent("absent")).unwrap(),
            CreationPresence::Absent
        );
        assert!(!engine.binding.vm_root.exists());
        assert!(!engine.domain.directory.join("artifacts").exists());
        assert!(engine.db.list_vms().unwrap().is_empty());
        assert!(engine.owned_handles.lock().unwrap().is_empty());
    }

    #[test]
    fn intent_cannot_adopt_matching_labels_or_corrupted_row() {
        let temp = tempfile::tempdir().unwrap();
        let engine = test_engine(temp.path());
        let receipt = install_record(&engine);
        let request = creation_intent(&receipt.name);
        assert_eq!(
            engine.inspect_creation(&request).unwrap(),
            CreationPresence::Unverified
        );
        let raw = rusqlite::Connection::open(&engine.binding.database).unwrap();
        raw.execute("UPDATE vms SET data = X'00'", []).unwrap();
        assert_eq!(
            engine.inspect_creation(&request).unwrap(),
            CreationPresence::Unverified
        );
        assert_eq!(
            raw.query_row("SELECT data FROM vms", [], |row| row.get::<_, Vec<u8>>(0))
                .unwrap(),
            vec![0]
        );
        assert!(engine.owned_handles.lock().unwrap().is_empty());
    }

    #[test]
    fn active_and_stale_create_reservations_remain_unverified_and_unchanged() {
        let temp = tempfile::tempdir().unwrap();
        let engine = test_engine(temp.path());
        let request = creation_intent("reserved");
        engine
            .db
            .reserve_vm_create(&request.name, "foreign")
            .unwrap();
        let raw = rusqlite::Connection::open(&engine.binding.database).unwrap();
        for stale in [false, true] {
            if stale {
                raw.execute(
                    "UPDATE vm_create_reservations SET owner_pid = -1, created_at = 0",
                    [],
                )
                .unwrap();
            }
            assert_eq!(
                engine.inspect_creation(&request).unwrap(),
                CreationPresence::Unverified
            );
            assert_eq!(
                raw.query_row(
                    "SELECT owner_token FROM vm_create_reservations",
                    [],
                    |row| { row.get::<_, String>(0) }
                )
                .unwrap(),
                "foreign"
            );
        }
        assert!(!engine.binding.vm_root.exists());
    }

    #[test]
    fn partial_material_and_dangling_symlinks_are_never_intent_absence() {
        let temp = tempfile::tempdir().unwrap();
        let engine = test_engine(temp.path());
        std::fs::create_dir_all(&engine.binding.vm_root).unwrap();
        let request = creation_intent("partial");
        let directory = engine.vm_directory(&request.name);
        std::fs::write(&directory, b"partial").unwrap();
        assert_eq!(
            engine.inspect_creation(&request).unwrap(),
            CreationPresence::Unverified
        );
        assert_eq!(std::fs::read(&directory).unwrap(), b"partial");
        std::fs::remove_file(&directory).unwrap();
        std::os::unix::fs::symlink("missing-material", &directory).unwrap();
        assert_eq!(
            engine.inspect_creation(&request).unwrap(),
            CreationPresence::Unverified
        );
        assert!(std::fs::symlink_metadata(&directory)
            .unwrap()
            .file_type()
            .is_symlink());
    }

    #[test]
    fn redirected_domain_ancestors_cannot_establish_intent_absence() {
        let temp = tempfile::tempdir().unwrap();
        let engine = test_engine(temp.path());
        let redirected = temp.path().join("redirected");
        std::fs::create_dir(&redirected).unwrap();
        std::os::unix::fs::symlink(&redirected, &engine.binding.vm_root).unwrap();
        let error = engine
            .inspect_creation(&creation_intent("absent"))
            .unwrap_err();
        assert_eq!(error.code, ErrorCode::Ownership);
        assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
        assert!(std::fs::read_dir(&redirected).unwrap().next().is_none());
    }

    #[test]
    fn local_handles_and_busy_lifecycle_gate_prevent_intent_absence() {
        let temp = tempfile::tempdir().unwrap();
        let engine = test_engine(temp.path());
        let request = creation_intent("busy");
        let gate = engine.gate(&request.name).unwrap();
        let guard = gate.try_lock().unwrap();
        assert_eq!(
            engine.inspect_creation(&request).unwrap_err().code,
            ErrorCode::Conflict
        );
        drop(guard);
        let receipt = CreationReceipt {
            target_id: engine.binding.target_id.clone(),
            domain_generation: engine.binding.generation.clone(),
            name: request.name.clone(),
            owner_token: request.owner_token.clone(),
            incarnation: request.incarnation.clone(),
            material_sha256: "e".repeat(64),
            material: None,
        };
        engine.track_handle(&receipt).unwrap();
        assert_eq!(
            engine.inspect_creation(&request).unwrap(),
            CreationPresence::Unverified
        );
    }

    #[test]
    fn broken_database_or_invalid_intent_never_becomes_absence() {
        let temp = tempfile::tempdir().unwrap();
        let engine = test_engine(temp.path());
        let mut request = creation_intent("absent");
        request.owner_token.clear();
        assert_eq!(
            engine.inspect_creation(&request).unwrap_err().code,
            ErrorCode::Validation
        );
        request.owner_token = "b".repeat(64);
        let raw = rusqlite::Connection::open(&engine.binding.database).unwrap();
        raw.execute("DROP TABLE vm_create_reservations", [])
            .unwrap();
        let error = engine.inspect_creation(&request).unwrap_err();
        assert_eq!(error.code, ErrorCode::Unsupported);
        assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
    }

    #[test]
    fn cached_database_replacement_or_redirection_never_becomes_intent_absence() {
        let temp = tempfile::tempdir().unwrap();
        let engine = test_engine(temp.path());
        let moved = engine.binding.database.with_extension("saved");
        std::fs::rename(&engine.binding.database, &moved).unwrap();
        // The writer connection still refers to the old inode, where the
        // candidate is absent. A different file at its path cannot use that
        // stale cached observation to authorize managed capacity release.
        std::fs::write(&engine.binding.database, b"replacement").unwrap();
        let request = creation_intent("absent");
        let error = engine.inspect_creation(&request).unwrap_err();
        assert_eq!(error.code, ErrorCode::Ownership);
        assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
        assert_eq!(
            std::fs::read(&engine.binding.database).unwrap(),
            b"replacement"
        );
        std::fs::remove_file(&engine.binding.database).unwrap();
        std::os::unix::fs::symlink(&moved, &engine.binding.database).unwrap();
        assert_eq!(
            engine.inspect_creation(&request).unwrap_err().code,
            ErrorCode::Ownership
        );
        std::fs::remove_file(&engine.binding.database).unwrap();
        let error = engine.inspect_creation(&request).unwrap_err();
        assert_eq!(error.code, ErrorCode::Database);
        assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
    }

    #[test]
    fn enrolled_database_reopen_does_not_recreate_a_missing_file() {
        let temp = tempfile::tempdir().unwrap();
        let database = temp.path().canonicalize().unwrap().join("missing.db");
        let error = match open_database(&database, false) {
            Err(error) => error,
            Ok(_) => panic!("missing enrolled database was recreated"),
        };
        assert_eq!(error.code, ErrorCode::Database);
        assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
        assert!(!database.exists());
        let (db, identity) = open_database(&database, true).unwrap();
        assert!(db.list_vms().unwrap().is_empty());
        assert_eq!(identity, database_identity(&database).unwrap());
        drop(db);
        let (_, reopened) = open_database(&database, false).unwrap();
        assert_eq!(reopened, identity);
    }

    #[test]
    fn sdk_initialization_never_repairs_an_existing_unsupported_schema() {
        for initialize in [false, true] {
            let temp = tempfile::tempdir().unwrap();
            let database = temp.path().canonicalize().unwrap().join("db");
            let (db, _) = open_database(&database, true).unwrap();
            drop(db);
            let writer = rusqlite::Connection::open(&database).unwrap();
            writer
                .execute("DROP TABLE vm_create_reservations", [])
                .unwrap();
            let error = open_database(&database, initialize).err().unwrap();
            assert_eq!(error.code, ErrorCode::Unsupported);
            assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
            assert!(writer
                .prepare("SELECT * FROM vm_create_reservations")
                .is_err());
        }
    }

    fn install_named_record(engine: &Engine, name: &str) -> CreationReceipt {
        let mut record = VmRecord::new(name.into(), 1, 512, vec![], vec![], false);
        record.storage_gb = Some(1);
        record.overlay_gb = Some(1);
        record.labels.insert("smolbox.owner".into(), "b".repeat(64));
        let receipt = CreationReceipt {
            target_id: engine.binding.target_id.clone(),
            domain_generation: engine.binding.generation.clone(),
            name: record.name.clone(),
            owner_token: "b".repeat(64),
            incarnation: "c".repeat(32),
            material_sha256: material_hash(&record).unwrap(),
            material: None,
        };
        engine
            .db
            .insert_vm_if_not_exists(&record.name, &record)
            .unwrap();
        let directory = engine.vm_directory(&receipt.name);
        std::fs::create_dir_all(&directory).unwrap();
        write_marker(&receipt, &directory).unwrap();
        receipt
    }

    #[test]
    fn cooperating_lifecycle_rechecks_receipt_before_sdk_entry() {
        let temp = tempfile::tempdir().unwrap();
        let engine = test_engine(temp.path());
        let receipt = install_record(&engine);
        let expected = engine.inspect(&receipt).unwrap();
        engine
            .db
            .update_vm(&receipt.name, |record| record.cpus = 2)
            .unwrap();
        let gate = engine.gate(&receipt.name).unwrap();
        let _lease = gate.try_lock().unwrap();
        let error = engine
            .coordinated_lifecycle(&receipt, &expected, &read_budget(), || {
                panic!("failed receipt reached SDK mutation")
            })
            .unwrap_err();
        assert_eq!(error.code, ErrorCode::Ownership);
        assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
        assert_eq!(engine.db.get_vm(&receipt.name).unwrap().unwrap().cpus, 2);
        assert!(engine
            .vm_directory(&receipt.name)
            .join("smolbox.incarnation")
            .exists());
    }

    #[test]
    fn lifecycle_does_not_hold_outer_source_flock_and_sdk_errors_are_uncertain() {
        let temp = tempfile::tempdir().unwrap();
        let engine = test_engine(temp.path());
        let receipt = install_record(&engine);
        let expected = engine.inspect(&receipt).unwrap();
        let gate = engine.gate(&receipt.name).unwrap();
        let _lease = gate.try_lock().unwrap();
        let error = engine
            .coordinated_lifecycle(&receipt, &expected, &read_budget(), || {
                // Model the SDK taking its own source lock; no VM or SDK mutation.
                let _source =
                    crate::sdk_compat::source_lease(&engine.binding.vm_root, &receipt.name)
                        .unwrap();
                assert!(gate.try_lock().is_err());
                Err(smolvm::Error::config("modeled SDK entry", "failure"))
            })
            .unwrap_err();
        assert_eq!(error.code, ErrorCode::Native);
        assert_eq!(error.dispatch, crate::Dispatch::MayHaveDispatched);
        assert!(engine.vm_directory(&receipt.name).exists());
    }

    #[test]
    fn cooperating_delete_rejects_changed_state_without_changing_material_identity() {
        let temp = tempfile::tempdir().unwrap();
        let engine = test_engine(temp.path());
        let receipt = install_record(&engine);
        let expected = engine.inspect(&receipt).unwrap();
        engine
            .db
            .update_vm(&receipt.name, |record| {
                record.state = smolvm::config::RecordState::Paused;
            })
            .unwrap();
        let record = engine.db.get_vm(&receipt.name).unwrap().unwrap();
        assert!(receipt.matches(&record).unwrap());
        let error = engine
            .coordinated_lifecycle(&receipt, &expected, &read_budget(), || {
                panic!("changed state reached SDK deletion")
            })
            .unwrap_err();
        assert_eq!(error.code, ErrorCode::State);
        assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
        assert_eq!(
            engine.db.get_vm(&receipt.name).unwrap().unwrap().state,
            smolvm::config::RecordState::Paused
        );
        assert!(engine.vm_directory(&receipt.name).exists());
    }

    #[test]
    fn corrupted_database_record_is_error_never_missing_or_stopped() {
        let temp = tempfile::tempdir().unwrap();
        let engine = test_engine(temp.path());
        let receipt = install_record(&engine);
        let raw = rusqlite::Connection::open(&engine.binding.database).unwrap();
        raw.execute(
            "UPDATE vms SET data = ?1 WHERE name = ?2",
            rusqlite::params![b"invalid JSON", receipt.name],
        )
        .unwrap();
        let error = engine.inspect(&receipt).unwrap_err();
        assert_eq!(error.code, ErrorCode::Database);
        assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
        assert!(engine.shutdown().is_empty()); // Inventory is never adopted.
    }

    #[test]
    fn matching_labels_cannot_authorize_changed_record_or_recreated_directory() {
        let temp = tempfile::tempdir().unwrap();
        let engine = test_engine(temp.path());
        let receipt = install_record(&engine);
        assert_eq!(
            engine.inspect(&receipt).unwrap().state,
            ObservedState::Stopped
        );
        engine.db.update_vm(&receipt.name, |r| r.cpus = 2).unwrap();
        assert_eq!(
            engine.delete(&receipt).unwrap_err().code,
            ErrorCode::Ownership
        );
        engine.db.update_vm(&receipt.name, |r| r.cpus = 1).unwrap();
        std::fs::remove_file(
            engine
                .vm_directory(&receipt.name)
                .join("smolbox.incarnation"),
        )
        .unwrap();
        assert_eq!(
            engine.inspect(&receipt).unwrap_err().code,
            ErrorCode::Ownership
        );
        assert!(engine.db.get_vm(&receipt.name).unwrap().is_some());
    }

    #[test]
    fn missing_inspection_does_not_recreate_data_or_acquire_a_handle() {
        let temp = tempfile::tempdir().unwrap();
        let engine = test_engine(temp.path());
        let receipt = CreationReceipt {
            target_id: "local".into(),
            domain_generation: "a".repeat(32),
            name: "absent".into(),
            owner_token: "b".repeat(64),
            incarnation: "c".repeat(32),
            material_sha256: "d".repeat(64),
            material: None,
        };
        assert_eq!(
            engine.inspect(&receipt).unwrap().state,
            ObservedState::Missing
        );
        assert!(!engine.binding.vm_root.exists());
        assert!(engine.shutdown().is_empty());
    }

    #[test]
    fn partial_storage_without_database_record_is_not_verified_absence() {
        let temp = tempfile::tempdir().unwrap();
        let engine = test_engine(temp.path());
        let receipt = CreationReceipt {
            target_id: "local".into(),
            domain_generation: "a".repeat(32),
            name: "partial".into(),
            owner_token: "b".repeat(64),
            incarnation: "c".repeat(32),
            material_sha256: "d".repeat(64),
            material: None,
        };
        std::fs::create_dir_all(engine.vm_directory(&receipt.name)).unwrap();
        assert_eq!(
            engine.inspect(&receipt).unwrap().state,
            ObservedState::IdentityUnknown
        );
        assert_eq!(engine.delete(&receipt).unwrap_err().code, ErrorCode::State);
        assert!(engine.vm_directory(&receipt.name).exists());
    }

    #[test]
    fn lifecycle_gate_is_per_machine_and_inactive_names_are_not_accumulated() {
        let temp = tempfile::tempdir().unwrap();
        let engine = test_engine(temp.path());
        let first = engine.gate("a").unwrap();
        let _guard = first.try_lock().unwrap();
        assert!(engine.gate("a").unwrap().try_lock().is_err());
        assert!(engine.gate("b").unwrap().try_lock().is_ok());
        for n in 0..1000 {
            drop(engine.gate(&format!("finished-{n}")).unwrap());
        }
        assert!(engine.gates.lock().unwrap().len() <= 2);
    }
}

#[cfg(test)]
mod export_asset_catalog_tests {
    use super::*;
    use crate::export_assets::tests::{budget, fixture};
    use std::os::unix::fs::PermissionsExt;
    #[test]
    fn package_catalog_requires_host_domain_package_and_exact_library_root() {
        let temp = tempfile::tempdir().unwrap();
        let mut engine = tests::test_engine(temp.path());
        let assets = fixture(&temp.path().join("assets"));
        assert!(engine
            .prepare_export_assets(assets.clone(), &"c".repeat(64), &budget())
            .is_err());
        tests::test_export_host(
            &mut engine,
            &std::fs::canonicalize(temp.path().join("assets")).unwrap(),
        );
        assert_eq!(
            engine
                .prepare_export_assets(assets.clone(), &"d".repeat(64), &budget())
                .unwrap_err()
                .code,
            ErrorCode::Ownership
        );
        let elsewhere = fixture(&temp.path().join("elsewhere"));
        assert_eq!(
            engine
                .prepare_export_assets(elsewhere, &"c".repeat(64), &budget())
                .unwrap_err()
                .code,
            ErrorCode::Ownership
        );
        let domain = engine.host.as_ref().unwrap().domain.clone();
        engine.host.as_mut().unwrap().domain.generation = "e".repeat(32);
        assert!(engine
            .prepare_export_assets(assets.clone(), &"c".repeat(64), &budget())
            .is_err());
        engine.host.as_mut().unwrap().domain = domain;
        assert!(engine.export_asset_approval().is_err());
        engine
            .prepare_export_assets(assets.clone(), &"c".repeat(64), &budget())
            .unwrap();
        assert!(engine.export_asset_approval().unwrap() == &assets);
        engine
            .prepare_export_assets(assets.clone(), &"c".repeat(64), &budget())
            .unwrap();
        let mut changed = assets;
        changed.files[0].sha256 = "f".repeat(64);
        assert_eq!(
            engine
                .prepare_export_assets(changed, &"c".repeat(64), &budget())
                .unwrap_err()
                .code,
            ErrorCode::Conflict
        );
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
    }
    #[test]
    fn asset_setup_preserves_budget_admission_and_rejects_changed_bytes_without_installation() {
        let temp = tempfile::tempdir().unwrap();
        let mut engine = tests::test_engine(temp.path());
        let assets = fixture(&temp.path().join("assets"));
        tests::test_export_host(
            &mut engine,
            &std::fs::canonicalize(temp.path().join("assets")).unwrap(),
        );
        let work = engine
            .jobs
            .acquire(crate::jobs::Demand::export_source())
            .unwrap();
        assert_eq!(
            engine
                .prepare_export_assets(assets.clone(), &"c".repeat(64), &budget())
                .unwrap_err()
                .code,
            ErrorCode::Admission
        );
        assert!(engine.export_asset_approval().is_err());
        drop(work);
        let canceled = budget();
        canceled.cancel.cancel();
        assert_eq!(
            engine
                .prepare_export_assets(assets.clone(), &"c".repeat(64), &canceled)
                .unwrap_err()
                .code,
            ErrorCode::State
        );
        let mut wrong = assets.clone();
        wrong.files[0].sha256 = "f".repeat(64);
        assert!(engine
            .prepare_export_assets(wrong, &"c".repeat(64), &budget())
            .is_err());
        assert!(engine.export_asset_approval().is_err());
        engine
            .prepare_export_assets(assets.clone(), &"c".repeat(64), &budget())
            .unwrap();
        // The catalog stores grants, not persistent file descriptors; packing
        // independently rehashes and rejects changed bytes under its own job.
        std::fs::set_permissions(
            &assets.files[0].path,
            std::fs::Permissions::from_mode(0o600),
        )
        .unwrap();
        std::fs::write(&assets.files[0].path, b"changed").unwrap();
        assert!(engine
            .export_asset_approval()
            .unwrap()
            .qualify(&budget())
            .is_err());
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
    }
}

#[cfg(test)]
mod stop_budget_tests;
