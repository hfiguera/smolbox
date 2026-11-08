//! Explicit held snapshot boot, retaining the original manager through SDK
//! return. No cold fallback, convenience fork/retry or implicit held release.
use super::*;
use crate::branch_boot::{Directory, Lifecycle, Plan};
use crate::branch_release::unchanged_records;
use crate::disk_geometry::ExportDisk;
use smolvm::agent::AgentManager;
use std::fs::File;

pub(super) struct OwnedBoot {
    manager: Arc<Mutex<AgentManager>>,
    plan: Plan,
    enrollment: Option<Arc<crate::epoch::BootEnrollment>>,
    returned: bool,
    succeeded: bool,
    identity_sha256: Option<String>,
}
/// Confirmed bare-guest initialization on the original boot. Held release,
/// public readiness and current process liveness remain separate.
#[derive(Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BranchGuestIdentity {
    pub schema: u8,
    pub boot: BranchBootIdentity,
    pub identity_sha256: String,
}
impl std::fmt::Debug for BranchGuestIdentity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("BranchGuestIdentity")
            .field("schema", &self.schema)
            .finish_non_exhaustive()
    }
}
/// Original boot enrollment only. This does not establish guest identity reset,
/// initialized branch readiness, release or current process liveness.
#[derive(Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BranchBootIdentity {
    pub schema: u8,
    pub child: CreationReceipt,
    pub publication_sha256: String,
    pub boot_sha256: String,
    pub pid: i32,
    pub birth: u64,
}
impl std::fmt::Debug for BranchBootIdentity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("BranchBootIdentity")
            .field("schema", &self.schema)
            .finish_non_exhaustive()
    }
}
impl OwnedBoot {
    fn guest_identity(&self) -> Result<BranchGuestIdentity> {
        Ok(BranchGuestIdentity {
            schema: 1,
            boot: self.identity()?,
            identity_sha256: self
                .identity_sha256
                .clone()
                .ok_or(Error::uncertain(ErrorCode::State))?,
        })
    }
    fn verify_live(&self, epoch: &crate::epoch::ActorEpoch) -> Result<()> {
        let enrolled = self
            .enrollment
            .as_ref()
            .ok_or(Error::uncertain(ErrorCode::Ownership))?;
        let child = enrolled.child();
        self.plan.verify()?;
        if !enrolled
            .intent()
            .matches_epoch(&self.plan.publication.child().name, epoch)
            || self
                .manager
                .try_lock()
                .map_err(|_| Error::uncertain(ErrorCode::Conflict))?
                .child_pid()
                != Some(child.pid)
            || smolvm::process::process_start_time(child.pid) != Some(child.birth)
            || !smolvm::process::is_alive(child.pid)
        {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        Ok(())
    }
    fn identity(&self) -> Result<BranchBootIdentity> {
        let enrollment = self
            .enrollment
            .as_ref()
            .ok_or(Error::uncertain(ErrorCode::Ownership))?;
        if !self.returned || !self.succeeded {
            return Err(Error::uncertain(ErrorCode::State));
        }
        Ok(BranchBootIdentity {
            schema: 1,
            child: self.plan.publication.child().clone(),
            publication_sha256: crate::material::hash(&self.plan.publication)?,
            boot_sha256: crate::material::hash(enrollment.intent())?,
            pid: enrollment.child().pid,
            birth: enrollment.child().birth,
        })
    }
}
// Completed worker facts are requalified from the original protected lifecycle
// below. An in-memory phase alone never attests readiness or permits handoff.
pub(super) fn handoff_ready(work: &Work, resolving: bool) -> bool {
    let phase = matches!(work.phase, Phase::IdentityReady | Phase::Released)
        || (resolving && matches!(work.phase, Phase::IdentityEntered | Phase::ReleaseEntered));
    phase && work.worker.upgrade().is_none() && work.prepared.is_none() && work.collected.is_none()
}
// Protected lifecycle completion is required even when an expired producer
// left its in-memory phase at the entered boundary. This calls no SDK/agent API.
pub(super) fn qualify_ready_result(
    plan: &Plan,
    enrollment: &crate::epoch::BootEnrollment,
    identity_sha256: &str,
    creation: Option<&BranchCreateRequest>,
) -> Result<crate::BranchCompletion> {
    let (child, held, release) =
        Lifecycle::at(&plan.child.path).finish_record(plan, enrollment, identity_sha256)?;
    let result = crate::BranchCompletion {
        schema: 1,
        publication: plan.publication.clone(),
        child,
        identity_sha256: identity_sha256.into(),
        held,
        release,
    };
    result.validate()?;
    if let Some(creation) = creation {
        creation.matches(&result)?;
    }
    Ok(result)
}
struct BarePack {
    root: crate::export_source::Root,
    file: File,
    path: std::path::PathBuf,
    version: crate::checkpoint_materialize::FileVersion,
}
impl BarePack {
    fn qualify(
        engine: &Engine,
        record: &smolvm::config::VmRecord,
        budget: &ReadBudget,
    ) -> Result<Option<Self>> {
        use sha2::{Digest, Sha256};
        let Some(path) = record
            .source_smolmachine
            .as_deref()
            .map(std::path::Path::new)
        else {
            return Ok(None);
        };
        let sha = path
            .file_name()
            .and_then(|name| name.to_str())
            .and_then(|name| name.strip_suffix(".smolmachine"))
            .filter(|sha| crate::domain::valid_hex(sha, 64))
            .ok_or(Error::before(ErrorCode::Ownership))?;
        // The path was authenticated by the original material receipt. Neither
        // a basename nor a mutable SDK cache pointer can supply this authority.
        let root = ["artifacts", "registry-blobs"]
            .into_iter()
            .map(|name| engine.domain.directory.join(name))
            .find(|root| path == root.join(format!("{sha}.smolmachine")))
            .ok_or(Error::before(ErrorCode::Ownership))?;
        let root = crate::export_source::Root::open(&root)?;
        let mut file = crate::artifact::open_regular(path)?;
        let info = file.metadata().map_err(|_| Error::before(ErrorCode::Io))?;
        if info.uid() != unsafe { libc::geteuid() }
            || info.mode() & 0o777 != 0o400
            || info.nlink() != 1
            || info.len() > 32 * 1024 * 1024 * 1024
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let version = crate::checkpoint_materialize::FileVersion::of(&info);
        let mut hash = Sha256::new();
        let mut buffer = [0; 65536];
        loop {
            budget.check()?;
            let count = file
                .read(&mut buffer)
                .map_err(|_| Error::before(ErrorCode::Io))?;
            if count == 0 {
                break;
            }
            hash.update(&buffer[..count]);
        }
        if hex::encode(hash.finalize()) != sha {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let footer = smolvm_pack::packer::read_footer_from_file(&mut file)
            .map_err(|_| Error::before(ErrorCode::Ownership))?;
        let manifest = crate::artifact::read_manifest(&mut file, &footer)?;
        crate::checkpoint_capture::validate_pack(&manifest)?;
        if manifest.platform != crate::oci::native_oci_platform() || manifest.gpu || manifest.cuda {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let this = Self {
            root,
            file,
            path: path.into(),
            version,
        };
        this.verify(budget)?;
        Ok(Some(this))
    }
    fn verify(&self, budget: &ReadBudget) -> Result<()> {
        budget.check()?;
        self.root.verify()?;
        let named = crate::artifact::open_regular(&self.path)?;
        for file in [&self.file, &named] {
            if crate::checkpoint_materialize::FileVersion::of(
                &file.metadata().map_err(|_| Error::before(ErrorCode::Io))?,
            ) != self.version
            {
                return Err(Error::before(ErrorCode::Ownership));
            }
        }
        Ok(())
    }
}
impl RetainedBranchPreparation {
    /// Transfer this exact completed manager into ordinary lifecycle ownership.
    /// Temporary gates/work retire; native backing remains separately charged.
    pub fn finish_child(&self, engine: &Engine) -> Result<crate::BranchCompletion> {
        if let Some(completed) = self.completed(engine)? {
            return Ok(completed);
        }
        let budget = self.entry(engine)?.ownership.intent.guard.budget.clone();
        self.finish_child_under(engine, &budget, false)
    }
    // Only the original explicit resolution token may supply a fresh deadline.
    // It can qualify an already completed worker result, never resume that work.
    pub(super) fn finish_child_under(
        &self,
        engine: &Engine,
        budget: &ReadBudget,
        resolving: bool,
    ) -> Result<crate::BranchCompletion> {
        budget.check()?;
        if let Some(completed) = self.completed(engine)? {
            return Ok(completed);
        }
        let registry = self
            .registry
            .upgrade()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        let mut entry = self.entry(engine)?;
        let mut entries = registry
            .entries
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let mut completed = registry
            .completed
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        if Arc::strong_count(&entry) != 2
            || Arc::strong_count(&entry.ownership) != 1
            || !entries
                .get(&self.key)
                .is_some_and(|actual| Arc::ptr_eq(actual, &entry))
            || completed.contains_key(&self.key)
        {
            return Err(Error::before(ErrorCode::Conflict));
        }
        let work = entry
            .work
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        if !handoff_ready(&work, resolving) {
            return Err(Error::before(ErrorCode::State));
        }
        let original = &entry.ownership.intent;
        budget.check()?;
        if resolving {
            original.guard._job.check_resolved_branch_handoff()?;
        } else {
            original.guard._job.check_branch_handoff()?;
        }
        let boot = work.boot.as_ref().ok_or(Error::before(ErrorCode::State))?;
        let epoch = engine.boot_epoch()?;
        boot.verify_live(epoch)?;
        boot.guest_identity()?;
        let identity_sha256 = boot
            .identity_sha256
            .as_ref()
            .ok_or(Error::before(ErrorCode::State))?;
        let enrollment = boot
            .enrollment
            .as_ref()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        let result = qualify_ready_result(
            &boot.plan,
            enrollment,
            identity_sha256,
            entry.ownership.creation.as_ref(),
        )?;
        let record = engine.record(&result.child)?;
        let source = engine.record(&boot.plan.publication.receipt)?;
        if !engine
            .branch_source_authority(
                &boot.plan.publication.receipt,
                original.intent.source_pid,
                &source,
                &record,
                budget,
            )?
            .running()
            || record.forkpoint_held != result.held
            || record.pid != Some(enrollment.child().pid)
            || record.pid_start_time != Some(enrollment.child().birth)
        {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        let context = Arc::new(crate::branch_owned::Context {
            manager: boot.manager.clone(),
            plan: boot.plan.clone(),
            enrollment: enrollment.clone(),
            identity_sha256: identity_sha256.clone(),
            release: Mutex::new(None),
            deletion: Mutex::new(None),
            _runtime: original.guard._runtime.clone(),
            _domain: original.guard.domain.clone(),
        });
        budget.check().map_err(|e| Error::uncertain(e.code))?;
        // A returned release may have synchronized both journals just before
        // the original observer expired, leaving its in-memory handle at root.
        // Promotion accepts only that already-owned root or this exact next head.
        if let Some(release) = &result.release {
            engine
                .promote_branch_handle(&release.previous, &release.receipt)
                .map_err(|error| Error::uncertain(error.code))?;
        }
        engine
            .install_branch_manager(&result, context.clone())
            .map_err(|e| Error::uncertain(e.code))?;
        drop(work);
        drop(entries.remove(&self.key));
        // The registry lock and prechecked unique counts exclude another reader
        // or collector. Unexpected ownership retains the original whole entry.
        let converted = Arc::get_mut(&mut entry)
            .and_then(|unique| Arc::get_mut(&mut unique.ownership))
            .ok_or(Error::uncertain(ErrorCode::Conflict))
            .and_then(|ownership| {
                if resolving {
                    ownership.intent.guard._job.handoff_resolved_branch()
                } else {
                    ownership.intent.guard._job.handoff_branch()
                }
            });
        let backing = match converted {
            Ok(backing) => backing,
            Err(error) => {
                entries.insert(self.key.clone(), entry);
                return Err(Error::uncertain(error.code));
            }
        };
        completed.insert(
            self.key.clone(),
            CompletedChild {
                borrower: Arc::downgrade(&self.borrower),
                result: result.clone(),
                _context: context,
                _backing: backing,
                jobs: entry.ownership.jobs.clone(),
            },
        );
        // Close preparation roots and release the two machine gates only after
        // the actual child manager and backing have their independent owners.
        drop(entry);
        Ok(result)
    }
    /// Restore the published held child once using its retained snapshot.
    /// Initialization, readiness, release and ordinary use remain separate.
    /// Repeated successful observation returns only the original enrollment.
    pub fn boot_child(&self, engine: &Engine) -> Result<BranchBootIdentity> {
        let entry = self.entry(engine)?;
        {
            let work = entry
                .work
                .try_lock()
                .map_err(|_| Error::before(ErrorCode::Conflict))?;
            if matches!(
                work.phase,
                Phase::Booted
                    | Phase::IdentityEntered
                    | Phase::IdentityReady
                    | Phase::ReleaseEntered
                    | Phase::Released
            ) {
                return work
                    .boot
                    .as_ref()
                    .ok_or(Error::uncertain(ErrorCode::State))?
                    .identity();
            }
        }
        let publication = self.publish_material(engine)?;
        let original = &entry.ownership.intent;
        let budget = &original.guard.budget;
        let mut work = entry
            .work
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        if work.phase != Phase::Published {
            return Err(Error::before(ErrorCode::State));
        }
        budget.check()?;
        engine.binding().validate()?;
        engine.verify_database_identity()?;
        engine.branch_child_unstarted(&publication.child().name)?;
        let epoch = engine.boot_epoch()?.clone();
        if epoch.identity() != original.intent.epoch {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let snapshot = work
            .snapshot
            .as_ref()
            .ok_or(Error::before(ErrorCode::State))?;
        snapshot._snapshot.verify()?;
        snapshot._child.verify()?;
        original.guard.source_root.verify()?;
        let record = engine.record(publication.child())?;
        let source = engine.record(&publication.receipt)?;
        if !engine
            .branch_source_authority(
                &publication.receipt,
                original.intent.source_pid,
                &source,
                &record,
                budget,
            )?
            .running()
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let library = engine.export_sdk_library()?;
        let rootfs_path = crate::export_container::package_manager_rootfs(&library)?;
        if std::env::var_os("SMOLVM_AGENT_ROOTFS").as_deref() != Some(rootfs_path.as_os_str()) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let rootfs = crate::export_source::Root::open(&rootfs_path)?;
        let plan = Plan {
            schema: 1,
            publication: publication.clone(),
            source: Directory::capture(&original.guard.source_root)?,
            child: Directory::capture(&snapshot._child)?,
            snapshot: Directory::capture(&snapshot._snapshot)?,
            rootfs: Directory::capture(&rootfs)?,
        };
        let (resources, features) = plan.sdk_config(&record)?;
        let lifecycle = Lifecycle::at(&plan.child.path);
        lifecycle.prepare(&plan)?;
        let pack = BarePack::qualify(engine, &record, budget)?;
        let features = features
            .with_packed_layers(
                &smolvm::agent::machine_layers_cache_dir(&record.name),
                record.source_smolmachine.as_deref(),
            )
            .map_err(|_| Error::uncertain(ErrorCode::Native))?;
        if let Some(pack) = &pack {
            pack.verify(budget)?;
        }
        let storage = ExportDisk::capture(
            &plan.child.path,
            smolvm::storage::STORAGE_DISK_FILENAME,
            record
                .storage_gb
                .ok_or(Error::before(ErrorCode::Ownership))?,
            budget,
        )?;
        let overlay = ExportDisk::capture(
            &plan.child.path,
            smolvm::storage::OVERLAY_DISK_FILENAME,
            record
                .overlay_gb
                .ok_or(Error::before(ErrorCode::Ownership))?,
            budget,
        )?;
        let (storage_path, storage_format) = storage.sdk_source();
        let (overlay_path, overlay_format) = overlay.sdk_source();
        let storage_disk =
            smolvm::storage::StorageDisk::open_existing_with_format(&storage_path, storage_format)
                .map_err(|_| Error::before(ErrorCode::Native))?;
        let overlay_disk =
            smolvm::storage::OverlayDisk::open_existing_with_format(&overlay_path, overlay_format)
                .map_err(|_| Error::before(ErrorCode::Native))?;
        plan.verify()?;
        storage.verify(budget)?;
        overlay.verify(budget)?;
        if smolvm::agent::vm_data_dir(&record.name) != plan.child.path {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let manager = Arc::new(Mutex::new(
            AgentManager::new_named(&record.name, &plan.rootfs.path, storage_disk, overlay_disk)
                .map_err(|_| Error::before(ErrorCode::Native))?,
        ));
        if manager
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?
            .child_pid()
            .is_some()
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        // Its protected publication now contains all required preparation
        // evidence. Only these collected IPC spools may retire before boot.
        work.collected.take();
        work.boot = Some(OwnedBoot {
            manager: manager.clone(),
            plan: plan.clone(),
            enrollment: None,
            returned: false,
            succeeded: false,
            identity_sha256: None,
        });
        work.phase = Phase::BootEntered;
        let active = Arc::new(());
        work.worker = Arc::downgrade(&active);
        let dispatch = epoch.begin_boot(&record.name)?;
        let boot_intent = dispatch.intent();
        lifecycle.enter(&plan, &dispatch, &epoch)?;
        engine.track_handle(publication.child())?;
        let db = engine.db.clone();
        let jobs = engine.jobs.clone();
        let retained = entry.clone();
        let check_budget = budget.clone();
        drop(work);
        let result = crate::oci_start::observe_owned(
            jobs,
            budget.deadline,
            budget.cancel.clone(),
            move || {
                let _active = active;
                let _rootfs = rootfs;
                storage.verify(&check_budget)?;
                overlay.verify(&check_budget)?;
                if let Some(pack) = &pack {
                    pack.verify(&check_budget)?;
                }
                plan.verify().map_err(|e| Error::uncertain(e.code))?;
                {
                    let work = retained
                        .work
                        .lock()
                        .map_err(|_| Error::uncertain(ErrorCode::Native))?;
                    let boot = work
                        .boot
                        .as_ref()
                        .ok_or(Error::uncertain(ErrorCode::Ownership))?;
                    if boot.plan != plan || !Arc::ptr_eq(&boot.manager, &manager) {
                        return Err(Error::uncertain(ErrorCode::Ownership));
                    }
                }
                if !epoch.launcher_selected() {
                    return Err(Error::uncertain(ErrorCode::Ownership));
                }
                let started = manager
                    .lock()
                    .map_err(|_| Error::uncertain(ErrorCode::Native))?
                    .start_with_full_config(Vec::new(), Vec::new(), resources, features);
                let pid = manager
                    .lock()
                    .map_err(|_| Error::uncertain(ErrorCode::Native))?
                    .child_pid();
                let enrollment = dispatch.finish_enrollment(pid);
                lifecycle.returned(
                    &plan,
                    &boot_intent,
                    enrollment.as_ref().ok(),
                    started.is_ok(),
                )?;
                let mut work = retained
                    .work
                    .lock()
                    .map_err(|_| Error::uncertain(ErrorCode::Native))?;
                let boot = work
                    .boot
                    .as_mut()
                    .ok_or(Error::uncertain(ErrorCode::Ownership))?;
                boot.returned = true;
                boot.succeeded = started.is_ok();
                boot.enrollment = enrollment.ok().map(Arc::new);
                let enrolled = boot
                    .enrollment
                    .as_ref()
                    .ok_or(Error::uncertain(ErrorCode::Ownership))?;
                let child = enrolled.child();
                if pid != Some(child.pid)
                    || !enrolled.intent().matches_epoch(&record.name, &epoch)
                    || smolvm::process::process_start_time(child.pid) != Some(child.birth)
                    || !smolvm::process::is_alive(child.pid)
                {
                    return Err(Error::uncertain(ErrorCode::Ownership));
                }
                started.map_err(|e| Error::uncertain(crate::sdk_compat::launch_error(&e)))?;
                let expected = crate::material::hash(&record)?;
                let mut changed = false;
                db.update_vm(&record.name, |actual| {
                    if crate::material::hash(actual).ok().as_ref() == Some(&expected) {
                        actual.state = smolvm::config::RecordState::Running;
                        actual.pid = Some(child.pid);
                        actual.pid_start_time = Some(child.birth);
                        changed = true;
                    }
                })
                .map_err(|_| Error::uncertain(ErrorCode::Database))?;
                if !changed {
                    return Err(Error::uncertain(ErrorCode::Ownership));
                }
                check_budget.check().map_err(|e| Error::uncertain(e.code))?;
                boot.identity()
            },
        );
        let identity = result.map_err(|e| Error::uncertain(e.code))?;
        budget.check().map_err(|e| Error::uncertain(e.code))?;
        let mut work = entry
            .work
            .lock()
            .map_err(|_| Error::uncertain(ErrorCode::Native))?;
        work.worker = Weak::new();
        work.phase = Phase::Booted;
        Ok(identity)
    }

    /// Initialize one original boot once, leaving the inherited helper held.
    /// Failed/unknown entry cannot be replayed, even when its process is alive.
    pub fn initialize_child(&self, engine: &Engine) -> Result<BranchGuestIdentity> {
        let entry = self.entry(engine)?;
        {
            let work = entry
                .work
                .try_lock()
                .map_err(|_| Error::before(ErrorCode::Conflict))?;
            if matches!(
                work.phase,
                Phase::IdentityReady | Phase::ReleaseEntered | Phase::Released
            ) {
                return work
                    .boot
                    .as_ref()
                    .ok_or(Error::uncertain(ErrorCode::State))?
                    .guest_identity();
            }
        }
        self.boot_child(engine)?;
        let original = &entry.ownership.intent;
        let budget = original.guard.budget.clone();
        budget.check()?;
        let epoch = engine.boot_epoch()?.clone();
        engine.binding().validate()?;
        engine.verify_database_identity()?;
        let staging = engine.transfer_directory()?;
        let mut work = entry
            .work
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        if work.phase != Phase::Booted {
            return Err(Error::before(ErrorCode::State));
        }
        let boot = work.boot.as_ref().ok_or(Error::before(ErrorCode::State))?;
        boot.verify_live(&epoch)?;
        let plan = boot.plan.clone();
        let record = engine.record(plan.publication.child())?;
        let source = engine.record(&plan.publication.receipt)?;
        if record.state != smolvm::config::RecordState::Running
            || !record.forkpoint_held
            || !record.fork_env.is_empty()
            || !engine
                .branch_source_authority(
                    &plan.publication.receipt,
                    original.intent.source_pid,
                    &source,
                    &record,
                    &budget,
                )?
                .running()
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let enrolled = boot
            .enrollment
            .as_ref()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        if record.pid != Some(enrolled.child().pid)
            || record.pid_start_time != Some(enrolled.child().birth)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let intent = crate::branch_identity::Intent::new(&record.name, enrolled)?;
        // Conservative in-memory entry retains original ownership even if the
        // protected writer returns uncertainty. No guest IO precedes the write.
        let active = Arc::new(());
        work.worker = Arc::downgrade(&active);
        work.phase = Phase::IdentityEntered;
        let boot = work.boot.as_ref().ok_or(Error::before(ErrorCode::State))?;
        Lifecycle::at(&plan.child.path).enter_identity(
            &plan,
            &intent,
            boot.enrollment
                .as_ref()
                .ok_or(Error::before(ErrorCode::Ownership))?,
        )?;
        let retained = entry.clone();
        let check_budget = budget.clone();
        let database = engine.binding().database.clone();
        let database_identity = engine.database_identity;
        let source_pid = original.intent.source_pid;
        let expected_records = [
            (source.name.clone(), crate::material::hash(&source)?),
            (record.name.clone(), crate::material::hash(&record)?),
        ];
        drop(work);
        let identity = crate::oci_start::observe_owned(
            engine.jobs.clone(),
            budget.deadline,
            budget.cancel.clone(),
            move || {
                let _active = active;
                let unchanged = || -> Result<()> {
                    unchanged_records(
                        &database,
                        database_identity,
                        &expected_records,
                        &check_budget,
                    )?;
                    if !smolvm::process::is_alive(source_pid.0)
                        || smolvm::process::process_start_time(source_pid.0) != Some(source_pid.1)
                    {
                        return Err(Error::uncertain(ErrorCode::Ownership));
                    }
                    Ok(())
                };
                unchanged()?;
                {
                    let work = retained
                        .work
                        .lock()
                        .map_err(|_| Error::uncertain(ErrorCode::Native))?;
                    let boot = work
                        .boot
                        .as_ref()
                        .ok_or(Error::uncertain(ErrorCode::State))?;
                    boot.verify_live(&epoch)?;
                    if boot.plan != plan || work.phase != Phase::IdentityEntered {
                        return Err(Error::uncertain(ErrorCode::Ownership));
                    }
                }
                let proof =
                    intent.execute(&plan.child.path.join("agent.sock"), &staging, &check_budget)?;
                unchanged()?;
                let mut work = retained
                    .work
                    .lock()
                    .map_err(|_| Error::uncertain(ErrorCode::Native))?;
                let boot = work
                    .boot
                    .as_mut()
                    .ok_or(Error::uncertain(ErrorCode::State))?;
                boot.verify_live(&epoch)?;
                check_budget.check().map_err(|e| Error::uncertain(e.code))?;
                Lifecycle::at(&plan.child.path).identity_ready(
                    &plan,
                    boot.enrollment
                        .as_ref()
                        .ok_or(Error::uncertain(ErrorCode::Ownership))?,
                    &proof,
                )?;
                boot.identity_sha256 = Some(proof.digest().into());
                boot.guest_identity()
            },
        )
        .map_err(|e| Error::uncertain(e.code))?;
        budget.check().map_err(|e| Error::uncertain(e.code))?;
        let mut work = entry
            .work
            .lock()
            .map_err(|_| Error::uncertain(ErrorCode::Native))?;
        work.worker = Weak::new();
        work.phase = Phase::IdentityReady;
        Ok(identity)
    }
    /// Release within this original admitted branch job. Later public held
    /// release needs its own store/version admission and lifecycle handoff.
    pub fn release_child(
        &self,
        engine: &Engine,
        request: &crate::BranchReleaseRequest,
    ) -> Result<crate::BranchReleaseTransition> {
        request.validate()?;
        let entry = self.entry(engine)?;
        {
            let mut work = entry
                .work
                .try_lock()
                .map_err(|_| Error::before(ErrorCode::Conflict))?;
            if matches!(work.phase, Phase::ReleaseEntered | Phase::Released) {
                if work.worker.upgrade().is_some() {
                    return Err(Error::before(ErrorCode::Conflict));
                }
                let boot = work
                    .boot
                    .as_ref()
                    .ok_or(Error::uncertain(ErrorCode::State))?;
                let completed = Lifecycle::at(&boot.plan.child.path).completed_release(
                    &boot.plan,
                    request,
                    boot.enrollment
                        .as_ref()
                        .ok_or(Error::uncertain(ErrorCode::Ownership))?,
                )?;
                if let Some(release) = completed {
                    engine.promote_branch_handle(&release.previous, &release.receipt)?;
                    work.phase = Phase::Released;
                    return Ok(release);
                }
                return Err(Error::uncertain(ErrorCode::State));
            }
        }
        self.initialize_child(engine)?;
        let original = &entry.ownership.intent;
        let budget = original.guard.budget.clone();
        budget.check()?;
        let epoch = engine.boot_epoch()?.clone();
        engine.binding().validate()?;
        engine.verify_database_identity()?;
        let staging = engine.transfer_directory()?;
        let mut work = entry
            .work
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        if work.phase != Phase::IdentityReady {
            return Err(Error::before(ErrorCode::State));
        }
        let boot = work.boot.as_ref().ok_or(Error::before(ErrorCode::State))?;
        boot.verify_live(&epoch)?;
        let plan = boot.plan.clone();
        let record = engine.record(plan.publication.child())?;
        let source = engine.record(&plan.publication.receipt)?;
        if !engine
            .branch_source_authority(
                &plan.publication.receipt,
                original.intent.source_pid,
                &source,
                &record,
                &budget,
            )?
            .running()
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let enrolled = boot
            .enrollment
            .as_ref()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        let intent = crate::branch_release::Intent::issue(
            &plan.publication,
            &record,
            enrolled,
            boot.identity_sha256
                .as_deref()
                .ok_or(Error::before(ErrorCode::State))?,
            request,
        )?;
        let active = Arc::new(());
        work.worker = Arc::downgrade(&active);
        work.phase = Phase::ReleaseEntered;
        let boot = work.boot.as_ref().ok_or(Error::before(ErrorCode::State))?;
        Lifecycle::at(&plan.child.path).enter_release(
            &plan,
            &intent,
            boot.enrollment
                .as_ref()
                .ok_or(Error::before(ErrorCode::Ownership))?,
        )?;
        crate::material::MaterialJournal::at(&plan.child.path)
            .begin_branch_release(&intent, &record)?;
        let retained = entry.clone();
        let application = crate::branch_release::Application {
            plan,
            intent,
            before: record,
            source,
            enrollment: boot
                .enrollment
                .as_ref()
                .ok_or(Error::before(ErrorCode::Ownership))?
                .clone(),
            database: engine.binding().database.clone(),
            database_identity: engine.database_identity,
            db: engine.db.clone(),
            staging,
            budget: budget.clone(),
        };
        drop(work);
        let release = crate::oci_start::observe_owned(
            engine.jobs.clone(),
            budget.deadline,
            budget.cancel.clone(),
            move || {
                let _active = active;
                application.run(|| {
                    let work = retained
                        .work
                        .lock()
                        .map_err(|_| Error::uncertain(ErrorCode::Native))?;
                    if work.phase != Phase::ReleaseEntered {
                        return Err(Error::uncertain(ErrorCode::State));
                    }
                    work.boot
                        .as_ref()
                        .ok_or(Error::uncertain(ErrorCode::State))?
                        .verify_live(&epoch)
                })
            },
        )
        .map_err(|e| Error::uncertain(e.code))?;
        budget.check().map_err(|e| Error::uncertain(e.code))?;
        engine
            .promote_branch_handle(&release.previous, &release.receipt)
            .map_err(|e| Error::uncertain(e.code))?;
        let mut work = entry
            .work
            .lock()
            .map_err(|_| Error::uncertain(ErrorCode::Native))?;
        work.worker = Weak::new();
        work.phase = Phase::Released;
        Ok(release)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sha2::{Digest, Sha256};
    use std::os::unix::fs::PermissionsExt;

    fn pack_model(
        change: impl FnOnce(&mut smolvm_pack::format::PackManifest),
    ) -> (tempfile::TempDir, Engine, smolvm::config::VmRecord) {
        let temp = tempfile::tempdir().unwrap();
        let engine = crate::machine::tests::test_engine(temp.path());
        let mut manifest = smolvm_pack::format::PackManifest::new(
            "vm://model".into(),
            "none".into(),
            crate::oci::native_oci_platform().into(),
            "model".into(),
        );
        manifest.mode = smolvm_pack::format::PackMode::Vm;
        change(&mut manifest);
        let bytes = crate::export_import::tests::sidecar(&manifest, &[]);
        let cache = engine.domain.directory.join("artifacts");
        std::fs::create_dir(&cache).unwrap();
        std::fs::set_permissions(&cache, std::fs::Permissions::from_mode(0o700)).unwrap();
        let path = cache.join(format!(
            "{}.smolmachine",
            hex::encode(Sha256::digest(&bytes))
        ));
        std::fs::write(&path, bytes).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o400)).unwrap();
        let mut record =
            smolvm::config::VmRecord::new("model".into(), 1, 512, vec![], vec![], false);
        record.source_smolmachine = Some(path.to_str().unwrap().into());
        (temp, engine, record)
    }
    fn budget() -> ReadBudget {
        ReadBudget::for_checkpoint_work(
            std::time::Duration::from_secs(30),
            crate::Cancellation::default(),
        )
        .unwrap()
    }

    #[test]
    fn initialization_observation_rejects_changed_original_source_or_child_rows() {
        let (_temp, engine, publication, child) =
            crate::branch_material::tests::publication_model();
        let source = engine
            .db
            .get_vm(&publication.receipt.name)
            .unwrap()
            .unwrap();
        let expected = [
            (source.name.clone(), crate::material::hash(&source).unwrap()),
            (child.name.clone(), crate::material::hash(&child).unwrap()),
        ];
        let verify = || {
            unchanged_records(
                &engine.binding().database,
                engine.database_identity,
                &expected,
                &budget(),
            )
        };
        verify().unwrap();
        for original in [&source, &child] {
            engine
                .db
                .update_vm(&original.name, |record| record.pid = Some(999))
                .unwrap();
            assert!(verify().is_err());
            engine
                .db
                .update_vm(&original.name, |record| *record = original.clone())
                .unwrap();
            verify().unwrap();
            engine
                .db
                .update_vm(&original.name, |record| {
                    record
                        .labels
                        .insert("foreign-owner-model".into(), "changed".into());
                })
                .unwrap();
            assert!(verify().is_err());
            engine
                .db
                .update_vm(&original.name, |record| *record = original.clone())
                .unwrap();
        }
        verify().unwrap();
    }

    #[test]
    fn original_bare_pack_is_pinned_without_comparing_grown_disk_geometry() {
        let (_temp, engine, mut record) = pack_model(|_| {});
        record.storage_gb = Some(8);
        record.overlay_gb = Some(4);
        let pack = BarePack::qualify(&engine, &record, &budget())
            .unwrap()
            .unwrap();
        pack.verify(&budget()).unwrap();
        let alias = pack.path.with_extension("linked-model");
        std::fs::hard_link(&pack.path, &alias).unwrap();
        assert!(pack.verify(&budget()).is_err());
        std::fs::remove_file(alias).unwrap();
        // Replacing equal bytes still cannot replace the originally pinned inode.
        let replacement = pack.path.with_extension("replacement-model");
        std::fs::copy(&pack.path, &replacement).unwrap();
        std::fs::rename(replacement, &pack.path).unwrap();
        assert!(pack.verify(&budget()).is_err());
    }

    #[test]
    fn branch_pack_rejects_container_gpu_foreign_platform_and_unowned_cache_paths() {
        for change in [
            (|m: &mut smolvm_pack::format::PackManifest| {
                m.mode = smolvm_pack::format::PackMode::Container
            }) as fn(&mut smolvm_pack::format::PackManifest),
            |m| m.gpu = true,
            |m| m.cuda = true,
            |m| m.platform = "foreign/platform".into(),
        ] {
            let (_temp, engine, record) = pack_model(change);
            assert!(BarePack::qualify(&engine, &record, &budget()).is_err());
        }
        let (temp, engine, mut record) = pack_model(|_| {});
        let original = std::path::Path::new(record.source_smolmachine.as_ref().unwrap());
        let outside = temp
            .path()
            .canonicalize()
            .unwrap()
            .join(original.file_name().unwrap());
        std::fs::copy(original, &outside).unwrap();
        record.source_smolmachine = Some(outside.to_str().unwrap().into());
        assert!(BarePack::qualify(&engine, &record, &budget()).is_err());
    }
}
