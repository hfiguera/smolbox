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

/// An intent can prove absence, never recover a lost creation receipt.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CreationPresence {
    Absent,
    Unverified,
}

pub struct Engine {
    runtime: EmbeddedRuntime,
    db: SmolvmDb,
    database_identity: (u64, u64),
    binding: DomainBinding,
    gates: Mutex<HashMap<String, Weak<MachineGate>>>,
    owned_handles: Mutex<BTreeMap<String, CreationReceipt>>,
    pub(crate) domain: Arc<DomainGuard>,
    pub(crate) transfers: Option<TransferSupervisor>,
    templates: Option<crate::assets::PreparedTemplates>,
    host: Option<crate::HostContext>,
    boot: Option<(crate::BootLauncher, crate::epoch::ActorEpoch)>,
}

impl Engine {
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
            runtime: EmbeddedRuntime::with_db(db.clone()),
            db,
            database_identity,
            binding,
            gates: Mutex::new(HashMap::new()),
            owned_handles: Mutex::new(BTreeMap::new()),
            domain: Arc::new(domain),
            transfers: None,
            templates: None,
            host: None,
            boot: None,
        })
    }

    pub fn binding(&self) -> &DomainBinding {
        &self.binding
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

    fn boot_epoch(&self) -> Result<&crate::epoch::ActorEpoch> {
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

    fn verify_templates(&self) -> Result<()> {
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
        let transfers = TransferSupervisor::new(&host)?;
        let mut engine = Self::open(binding, allow_initialize)?;
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
        self.verify_templates()?;
        let prepared = artifact.prepare(&self.domain.directory.join("artifacts"), resources)?;
        validate_guest_user(user, prepared.manifest.mode == PackMode::Container)
    }

    pub fn create(&self, request: CreateRequest) -> Result<CreationReceipt> {
        validate_request(&request)?;
        let gate = self.gate(&request.name)?;
        let _guard = gate
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        self.verify_templates()?;
        let prepared = request
            .artifact
            .prepare(&self.domain.directory.join("artifacts"), request.resources)?;
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
        let result = self.create_reserved(&request, prepared);
        // Releasing the upstream preparation lock is distinct from releasing
        // SmolBox's durable capacity reservation. Never remove partial storage.
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
    ) -> Result<CreationReceipt> {
        let manager = AgentManager::for_vm_with_sizes(
            &request.name,
            Some(request.resources.storage_gib),
            Some(request.resources.overlay_gib),
        )
        .map_err(|_| Error::uncertain(ErrorCode::Native))?;
        smolvm::portable_checkpoint::materialize_pack_layers(&request.name, &prepared.path)
            .map_err(|_| Error::uncertain(ErrorCode::Native))?;
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
        for path in [seeded.storage_path(), seeded.overlay_path()] {
            crate::assets::prepare_created_disk(path)
                .map_err(|error| Error::uncertain(error.code))?;
        }
        self.verify_templates()
            .map_err(|error| Error::uncertain(error.code))?;
        let directory = seeded
            .storage_path()
            .parent()
            .ok_or(Error::uncertain(ErrorCode::Native))?;
        let (storage, storage_format) =
            smolvm::agent::resolve_disk_image(directory, smolvm::storage::STORAGE_DISK_FILENAME);
        let (overlay, overlay_format) =
            smolvm::agent::resolve_disk_image(directory, smolvm::storage::OVERLAY_DISK_FILENAME);
        // Raw container disks are formatted lazily by SDK start. Its template
        // copy also copies mode 0400. Complete that public SDK preparation now,
        // before receipt minting, then restore writable private backing modes.
        // The SDK records its own formatted state; SmolBox never forges markers
        // or formats/resizes files itself. VM-mode seeded disks remain intact.
        smolvm::storage::StorageDisk::open_existing_with_format(&storage, storage_format)
            .and_then(|disk| disk.ensure_formatted())
            .map_err(|_| Error::uncertain(ErrorCode::Native))?;
        smolvm::storage::OverlayDisk::open_existing_with_format(&overlay, overlay_format)
            .and_then(|disk| disk.ensure_formatted())
            .map_err(|_| Error::uncertain(ErrorCode::Native))?;
        for path in [&storage, &overlay] {
            crate::assets::prepare_created_disk(path)
                .map_err(|error| Error::uncertain(error.code))?;
        }
        if !prepared.verified.covers(&prepared.path) {
            return Err(Error::uncertain(ErrorCode::Validation));
        }
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
        // Always neutral; baked ENTRYPOINT/CMD cannot become an implicit workload.
        record.entrypoint = vec!["/bin/true".into()];
        record.cmd = vec![];
        // Per-operation env/workdir/user are explicit. No baked secrets or
        // environment values enter this durable neutral-start record.
        record.workdir = Some("/".into());
        record.user = (prepared.manifest.mode == PackMode::Container).then(|| "0".into());
        let receipt = CreationReceipt {
            target_id: self.binding.target_id.clone(),
            domain_generation: self.binding.generation.clone(),
            name: request.name.clone(),
            owner_token: request.owner_token.clone(),
            incarnation: request.incarnation.clone(),
            material_sha256: material_hash(&record)
                .map_err(|_| Error::uncertain(ErrorCode::Native))?,
        };
        write_marker(&receipt, &self.vm_directory(&receipt.name))?;
        if !self
            .db
            .commit_reserved_vm(&request.name, &request.owner_token, &record)
            .map_err(|_| Error::uncertain(ErrorCode::Database))?
        {
            return Err(Error::uncertain(ErrorCode::Conflict));
        }
        Ok(receipt)
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
                .runtime
                .pid(&receipt.name)
                .is_some_and(smolvm::process::is_alive);
            return Ok(Observation {
                state: if storage_present || child_present {
                    ObservedState::IdentityUnknown
                } else {
                    ObservedState::Missing
                },
                resources: None,
                pid_identity: None,
            });
        };
        self.verify_record(receipt, &record)?;
        let dependents = self
            .db
            .dependent_clones(&receipt.name)
            .map_err(|_| Error::before(ErrorCode::Database))?;
        let mut state = record_state(&record, !dependents.is_empty());
        if self.runtime.pid(&receipt.name).is_some_and(|pid| {
            smolvm::process::is_alive(pid)
                && (record.pid != Some(pid) || state != ObservedState::Running)
        }) {
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
        Ok(())
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
        self.verify_templates()?;
        let boot = self.boot_epoch()?;
        self.verify_lifecycle_preconditions(receipt, &expected)?;
        self.track_handle(receipt)?;
        let dispatch = boot.begin_boot(&receipt.name)?;
        let result = self.runtime.start_machine(&receipt.name);
        dispatch
            .finish(self.runtime.pid(&receipt.name))
            .map_err(|error| Error::uncertain(error.code))?;
        result.map_err(|_| Error::uncertain(ErrorCode::Native))?;
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
            ObservedState::Stopped => return self.inspect(receipt),
            ObservedState::Running => {}
            _ => return Err(Error::before(ErrorCode::State)),
        }
        self.coordinated_lifecycle(receipt, &expected, || {
            self.runtime.stop_machine(&receipt.name)
        })?;
        let observation = self
            .inspect(receipt)
            .map_err(|error| Error::uncertain(error.code))?;
        if observation.state == ObservedState::Stopped {
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

    fn verify_lifecycle_preconditions(
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
                .runtime
                .pid(&receipt.name)
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

    fn track_handle(&self, receipt: &CreationReceipt) -> Result<()> {
        self.owned_handles
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?
            .insert(receipt.name.clone(), receipt.clone());
        Ok(())
    }

    pub(crate) fn gate(&self, name: &str) -> Result<Arc<MachineGate>> {
        self.domain.verify()?;
        if !self.available() {
            return Err(Error::before(ErrorCode::State));
        }
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
        self.boot
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

fn validate_request(request: &CreateRequest) -> Result<()> {
    if !valid_id(&request.name)
        || !valid_hex(&request.owner_token, 64)
        || !valid_hex(&request.incarnation, 32)
        || request.labels.len() > 32
        || request.labels.iter().any(|(k, v)| {
            !valid_id(k) || k.starts_with("smolbox.") || v.len() > 1024 || v.contains('\0')
        })
    {
        return Err(Error::before(ErrorCode::Validation));
    }
    smolvm::data::validate_vm_name(&request.name, "name")
        .map_err(|_| Error::before(ErrorCode::Validation))?;
    request.resources.validate()
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

fn marker_matches(receipt: &CreationReceipt, directory: &Path) -> Result<bool> {
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
            runtime: EmbeddedRuntime::with_db(db.clone()),
            database_identity: database_identity(&binding.database).unwrap(),
            db,
            binding,
            gates: Mutex::new(HashMap::new()),
            owned_handles: Mutex::new(BTreeMap::new()),
            domain: Arc::new(domain),
            transfers: None,
            templates: None,
            host: None,
            boot: None,
        }
    }

    fn install_record(engine: &Engine) -> CreationReceipt {
        install_named_record(engine, "owned")
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
