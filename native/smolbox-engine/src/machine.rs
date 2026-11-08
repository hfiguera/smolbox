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
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CreationPresence {
    Absent,
    Unverified,
}

pub struct Engine {
    opened_at: std::time::Instant,
    runtime: EmbeddedRuntime,
    pub(crate) db: SmolvmDb,
    pub(crate) database_identity: (u64, u64),
    binding: DomainBinding,
    gates: Mutex<HashMap<String, Weak<MachineGate>>>,
    owned_handles: Mutex<BTreeMap<String, CreationReceipt>>,
    // Keep the actual SDK manager alive; dropping it would stop its VMM.
    pub(crate) owned_oci: Mutex<BTreeMap<String, Arc<Mutex<AgentManager>>>>,
    pub(crate) domain: Arc<DomainGuard>,
    pub(crate) transfers: Option<TransferSupervisor>,
    pub(crate) jobs: crate::jobs::JobPool,
    templates: Option<crate::assets::PreparedTemplates>,
    host: Option<crate::HostContext>,
    boot: Option<(crate::BootLauncher, crate::epoch::ActorEpoch)>,
}

impl Engine {
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
        if cancel.is_cancelled() || std::time::Instant::now() >= deadline {
            return Err(Error::before(ErrorCode::State));
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
        self.create_registry_prepared(
            CreateRegistryRequest {
                name: intent.name,
                owner_token: intent.owner_token,
                incarnation: intent.incarnation,
                artifact,
                labels: intent.labels,
                features: intent.features,
            },
            deadline,
            cancel,
        )
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
        if cancel.is_cancelled() || std::time::Instant::now() >= deadline {
            return Err(Error::before(ErrorCode::State));
        }
        self.validate_oci_intent(&intent)?;
        self.verify_templates()?;
        let source = self.prepare_oci_metadata(intent.source, deadline, cancel.clone())?;
        self.create_oci(
            CreateOciRequest {
                name: intent.name,
                owner_token: intent.owner_token,
                incarnation: intent.incarnation,
                resources: intent.resources,
                labels: intent.labels,
                features: intent.features,
                source,
            },
            deadline,
            cancel,
        )
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
        Ok(Self {
            opened_at: std::time::Instant::now(),
            runtime: EmbeddedRuntime::with_db(db.clone()),
            db,
            database_identity,
            binding,
            gates: Mutex::new(HashMap::new()),
            owned_handles: Mutex::new(BTreeMap::new()),
            owned_oci: Mutex::new(BTreeMap::new()),
            domain: Arc::new(domain),
            transfers: None,
            jobs: crate::jobs::JobPool::default(),
            templates: None,
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
        if let Some(features) = features {
            features.validate()?;
        }
        self.verify_templates()?;
        let prepared = artifact.prepare(&self.domain.directory.join("artifacts"), resources)?;
        validate_guest_user(user, prepared.manifest.mode == PackMode::Container)?;
        if let Some(features) = features {
            features.qualify(&prepared.manifest)?;
        }
        Ok(())
    }

    pub fn create(&self, request: CreateRequest) -> Result<CreationReceipt> {
        self.create_mode(request, false, None)
    }

    /// Fresh protocol-2 authority. An existing v1 receipt is never promoted.
    pub fn create_versioned(&self, request: CreateRequest) -> Result<CreationReceipt> {
        self.create_mode(request, true, None)
    }

    pub fn create_with_features(
        &self,
        request: CreateRequest,
        features: crate::CreationFeatures,
    ) -> Result<CreationReceipt> {
        self.create_mode(request, true, Some(&features))
    }

    fn create_mode(
        &self,
        request: CreateRequest,
        versioned: bool,
        features: Option<&crate::CreationFeatures>,
    ) -> Result<CreationReceipt> {
        validate_request(&request)?;
        if let Some(features) = features {
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
        if let Some(features) = features {
            features.qualify(&prepared.manifest)?;
        }
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
            .create_reserved(&request, prepared, features, None, None)
            .and_then(|receipt| {
                if versioned {
                    crate::material::MaterialJournal::at(&self.vm_directory(&receipt.name))
                        .initialize(&receipt)
                        .map_err(|error| Error::uncertain(error.code))
                } else {
                    Ok(receipt)
                }
            });
        // Releasing the upstream preparation lock is distinct from releasing
        // SmolBox's durable capacity reservation. Never remove partial storage.
        let _ = self
            .db
            .release_vm_create_reservation(&request.name, &request.owner_token);
        result
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
        features.qualify(&artifact.prepared.manifest)?;
        if artifact.prepared.manifest.platform != artifact.source.platform {
            return Err(Error::before(ErrorCode::Validation));
        }
        let _job = self.jobs.acquire(crate::jobs::Demand::oci_create())?;
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
                Some(&features),
                Some(&artifact.source.reference),
                Some((deadline, cancel)),
            )?;
            self.domain.verify().map_err(|e| Error::uncertain(e.code))?;
            let receipt = crate::material::MaterialJournal::at(&self.vm_directory(&receipt.name))
                .initialize(&receipt)
                .map_err(|e| Error::uncertain(e.code))?;
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
        let check = || {
            if cancel.is_cancelled() || std::time::Instant::now() >= deadline {
                Err(Error::before(ErrorCode::State))
            } else {
                Ok(())
            }
        };
        check()?;
        validate_creation_identity(
            &request.name,
            &request.owner_token,
            &request.incarnation,
            request.resources,
            &request.labels,
        )?;
        request.source.qualify(&request.features)?;
        let _job = self.jobs.acquire(crate::jobs::Demand::oci_create())?;
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
            let manager = AgentManager::for_vm_with_sizes(
                &request.name,
                Some(request.resources.storage_gib),
                Some(request.resources.overlay_gib),
            )
            .map_err(|_| Error::uncertain(ErrorCode::Native))?;
            prepare_manager_disks(&manager, || self.verify_templates())?;
            self.verify_templates()
                .map_err(|e| Error::uncertain(e.code))?;
            check().map_err(|e| Error::uncertain(e.code))?;
            let mut labels = request.labels.clone();
            labels.insert("smolbox.owner".into(), request.owner_token.clone());
            labels.insert("smolbox.incarnation".into(), request.incarnation.clone());
            let record = request
                .source
                .record(&request.name, request.resources, labels, &request.features)
                .map_err(|e| Error::uncertain(e.code))?;
            let receipt = self.commit_created_record(
                &request.name,
                &request.owner_token,
                &request.incarnation,
                &record,
            )?;
            let receipt = crate::material::MaterialJournal::at(&self.vm_directory(&receipt.name))
                .initialize(&receipt)
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

    fn verify_database_identity(&self) -> Result<()> {
        self.domain.verify()?;
        if database_identity(&self.binding.database)? != self.database_identity {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }

    fn creation_material_absent(&self, name: &str) -> Result<bool> {
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
        features: Option<&crate::CreationFeatures>,
        registry_reference: Option<&str>,
        budget: Option<(std::time::Instant, &Cancellation)>,
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
        let manager = AgentManager::for_vm_with_sizes(
            &request.name,
            Some(request.resources.storage_gib),
            Some(request.resources.overlay_gib),
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
        check()?;
        if !prepared.verified.covers(&prepared.path) {
            return Err(Error::uncertain(ErrorCode::Validation));
        }
        let record = prepared_pack_record(request, &prepared, features, registry_reference)?;
        check()?;
        self.commit_created_record(
            &request.name,
            &request.owner_token,
            &request.incarnation,
            &record,
        )
    }

    fn commit_created_record(
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
                || self.oci_manager_busy(&receipt.name)?;
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
        let mut state = record_state(&record, !dependents.is_empty());
        if self.oci_manager_busy(&receipt.name)?
            || self.runtime_pid(&receipt.name).is_some_and(|pid| {
                smolvm::process::is_alive(pid)
                    && (record.pid != Some(pid) || state != ObservedState::Running)
            })
        {
            state = ObservedState::IdentityUnknown;
        }
        if state == ObservedState::Running {
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
        crate::material::MaterialJournal::at(&self.vm_directory(&receipt.name)).verify(receipt)?;
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
        let result = (|| {
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
        })();
        // Failures leave the entered journal and reservations unresolved. No
        // SDK mutation is retried, and a partial geometry is never authorized.
        result
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
        let gate = self.gate(&receipt.name)?;
        let _guard = gate
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let expected = self.inspect(receipt)?;
        match expected.state {
            ObservedState::Stopped => {}
            _ => return Err(Error::before(ErrorCode::State)),
        }
        reject_unqualified_oci_boot(&self.record(receipt)?)?;
        self.verify_templates()?;
        let boot = self.boot_epoch()?;
        self.verify_lifecycle_preconditions(receipt, &expected)?;
        self.track_handle(receipt)?;
        let dispatch = boot.begin_boot(&receipt.name)?;
        let result = self.runtime.start_machine(&receipt.name);
        dispatch
            .finish(self.runtime.pid(&receipt.name))
            .map_err(|error| Error::uncertain(error.code))?;
        result.map_err(|error| Error::uncertain(crate::sdk_compat::launch_error(&error)))?;
        self.inspect(receipt)
            .map_err(|error| Error::uncertain(error.code))
    }

    pub fn stop(&self, receipt: &CreationReceipt) -> Result<Observation> {
        let gate = self.gate(&receipt.name)?;
        let _guard = gate
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let expected = self.inspect(receipt)?;
        match expected.state {
            ObservedState::Stopped => {
                // An owned SDK manager may retain an ordinarily exited child
                // and its launch flock. Explicit stop performs normal cleanup;
                // an absent manager needs no SDK mutation.
                if !self
                    .owned_oci
                    .lock()
                    .map_err(|_| Error::before(ErrorCode::Native))?
                    .contains_key(&receipt.name)
                {
                    return self.inspect(receipt);
                }
            }
            ObservedState::Running => {}
            _ => return Err(Error::before(ErrorCode::State)),
        }
        self.coordinated_lifecycle(receipt, &expected, || {
            let manager = self
                .owned_oci
                .lock()
                .map_err(|_| smolvm::Error::config("stop", "native manager unavailable"))?
                .get(&receipt.name)
                .cloned();
            if let Some(manager) = manager {
                // The direct manager path does not take the SDK runtime's
                // source flock. Keep source/dependency serialization here.
                let _source = self
                    .source_lease(receipt)
                    .map_err(|_| smolvm::Error::config("stop", "native source unavailable"))?;
                let manager = manager
                    .try_lock()
                    .map_err(|_| smolvm::Error::config("stop", "native startup still active"))?;
                manager.stop()?;
                self.db
                    .update_vm(&receipt.name, |record| {
                        record.state = smolvm::config::RecordState::Stopped;
                        record.pid = None;
                        record.pid_start_time = None;
                    })?
                    .ok_or_else(|| smolvm::Error::vm_not_found(&receipt.name))?;
                Ok(())
            } else {
                self.runtime.stop_machine(&receipt.name)
            }
        })?;
        let observation = self
            .inspect(receipt)
            .map_err(|error| Error::uncertain(error.code))?;
        if observation.state == ObservedState::Stopped {
            self.owned_oci
                .lock()
                .map_err(|_| Error::uncertain(ErrorCode::Native))?
                .remove(&receipt.name);
            self.owned_handles
                .lock()
                .map_err(|_| Error::uncertain(ErrorCode::Native))?
                .remove(&receipt.name);
        }
        Ok(observation)
    }

    pub fn delete(&self, receipt: &CreationReceipt) -> Result<Observation> {
        let gate = self.gate(&receipt.name)?;
        let _guard = gate
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        // Delete only an observed stopped incarnation, never kill an unreachable
        // or unknown PID through the upstream recovery convenience path.
        let expected = self.inspect(receipt)?;
        match expected.state {
            ObservedState::Missing => return self.inspect(receipt),
            ObservedState::Stopped => {}
            _ => return Err(Error::before(ErrorCode::State)),
        }
        self.coordinated_lifecycle(receipt, &expected, || {
            self.runtime.delete_machine(&receipt.name)
        })?;
        let observation = self
            .inspect(receipt)
            .map_err(|error| Error::uncertain(error.code))?;
        if observation.state == ObservedState::Missing {
            self.owned_oci
                .lock()
                .map_err(|_| Error::uncertain(ErrorCode::Native))?
                .remove(&receipt.name);
            self.owned_handles
                .lock()
                .map_err(|_| Error::uncertain(ErrorCode::Native))?
                .remove(&receipt.name);
        }
        Ok(observation)
    }

    fn coordinated_lifecycle(
        &self,
        receipt: &CreationReceipt,
        expected: &Observation,
        action: impl FnOnce() -> smolvm::Result<()>,
    ) -> Result<()> {
        self.verify_lifecycle_preconditions(receipt, expected)?;
        action().map_err(|_| Error::uncertain(ErrorCode::Native))
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
        command.validate(record.image.is_some())?;
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

    fn oci_manager_busy(&self, name: &str) -> Result<bool> {
        let handles = self
            .owned_oci
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?;
        Ok(handles
            .get(name)
            .is_some_and(|manager| manager.try_lock().is_err()))
    }

    pub(crate) fn runtime_pid(&self, name: &str) -> Option<i32> {
        self.owned_oci
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

    pub(crate) fn activate_files(
        &self,
        receipt: &CreationReceipt,
        timeout: std::time::Duration,
        cancel: &Cancellation,
    ) -> Result<bool> {
        if self.inspect(receipt)?.state != ObservedState::Running {
            return Err(Error::before(ErrorCode::State));
        }
        let record = self.record(receipt)?;
        self.verify_templates()?;
        if record.image.is_none() {
            return Ok(true);
        }
        self.track_handle(receipt)?;
        self.runtime
            .connect_machine(&receipt.name)
            .map_err(|_| Error::before(ErrorCode::Native))?;
        let mut collector = Collector::new(8192);
        collector.mark_dispatch();
        let result = self.runtime.exec_streaming_with_options(
            &receipt.name,
            vec!["/bin/true".into()],
            smolvm::embedded::ExecOptions {
                timeout: Some(timeout),
                ..Default::default()
            },
            &cancel.exec,
            |event| collector.event(event, cancel, &mut |_| Ok(())),
        );
        Ok(collector
            .finish(result.is_ok(), cancel.is_cancelled(), false)
            .success())
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
    features: Option<&crate::CreationFeatures>,
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
            allowed_cidrs: Some(vec![]),
            ..VmResources::default()
        },
        image: (prepared.manifest.mode == PackMode::Container)
            .then(|| prepared.manifest.image.clone()),
        ..MachineSpec::default()
    }
    .to_record();
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
    if let Some(features) = features {
        features
            .apply(&mut record, &prepared.manifest)
            .map_err(|error| Error::uncertain(error.code))?;
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
fn validate_creation_identity(
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
mod tests {
    use super::*;

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

    fn test_engine(root: &Path) -> Engine {
        let root = root.canonicalize().unwrap();
        let binding = DomainBinding {
            target_id: "local".into(),
            generation: "a".repeat(32),
            database: root.join("db"),
            vm_root: root.join("vms"),
        };
        let db = SmolvmDb::open_at(&binding.database).unwrap();
        let domain = DomainGuard::acquire_at(&binding, root.join("private"), true).unwrap();
        Engine {
            opened_at: std::time::Instant::now(),
            runtime: EmbeddedRuntime::with_db(db.clone()),
            database_identity: database_identity(&binding.database).unwrap(),
            db,
            binding,
            gates: Mutex::new(HashMap::new()),
            owned_handles: Mutex::new(BTreeMap::new()),
            owned_oci: Mutex::new(BTreeMap::new()),
            domain: Arc::new(domain),
            transfers: None,
            jobs: crate::jobs::JobPool::default(),
            templates: None,
            host: None,
            boot: None,
        }
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
        assert!(engine.owned_oci.lock().unwrap().is_empty());
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
        assert!(engine.owned_oci.lock().unwrap().is_empty());
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
            assert!(engine.owned_oci.lock().unwrap().is_empty());
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
        assert!(engine.owned_oci.lock().unwrap().is_empty());
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
        for scenario in ["cancel", "templates", "crossed"] {
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
            if scenario == "cancel" {
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
            let error = engine
                .create_registry_prepared(request, Instant::now() + Duration::from_secs(3), &cancel)
                .err()
                .unwrap();
            assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
            assert_eq!(
                error.code,
                match scenario {
                    "cancel" => ErrorCode::State,
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
            None,
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
        let local = prepared_pack_record(&request, &artifact.prepared, None, None).unwrap();
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
            assert!(engine.owned_oci.lock().unwrap().is_empty());
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

    fn install_record(engine: &Engine) -> CreationReceipt {
        install_named_record(engine, "owned")
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
        assert!(engine.owned_oci.lock().unwrap().is_empty());
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
        assert!(engine.owned_oci.lock().unwrap().is_empty());
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
            .coordinated_lifecycle(&receipt, &expected, || {
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
            .coordinated_lifecycle(&receipt, &expected, || {
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
            .coordinated_lifecycle(&receipt, &expected, || {
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
