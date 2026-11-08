//! Request-private checkpoint input and documented store-policy validation.
//! No SDK reservation, VM record, material receipt or global cache is created.
use crate::checkpoint::{Budgeted, HISTORY_INDEX_BYTES, HISTORY_OBJECT_BYTES};
use crate::domain::DomainGuard;
use crate::{ApprovedCheckpoint, Engine, Error, ErrorCode, ReadBudget, Resources, Result};
use sha2::{Digest, Sha256};
use smolvm_pack::format::{CheckpointLayout, PackManifest};
use std::collections::BTreeMap;
use std::fs::{File, Metadata};
use std::io::Read;
use std::os::unix::fs::DirBuilderExt;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;

/// SDK-materialized private input. This still grants no existing-machine
/// authority and cannot be obtained from inventory or an inspection response.
pub struct MaterializedCheckpoint {
    source: PreparedCheckpoint,
    manifest: PackManifest,
    proof: crate::checkpoint_materialize::Proof,
}

pub struct CreateCheckpointRequest {
    pub name: String,
    pub owner_token: String,
    pub incarnation: String,
    pub checkpoint: MaterializedCheckpoint,
    pub labels: BTreeMap<String, String>,
}

struct CreationReservation {
    db: smolvm::db::SmolvmDb,
    name: String,
    token: String,
}
impl Drop for CreationReservation {
    fn drop(&mut self) {
        let _ = self
            .db
            .release_vm_create_reservation(&self.name, &self.token);
    }
}
struct InstallationLeases {
    _checkpoint: Option<MaterializedCheckpoint>,
    _machine: crate::gate::MachineLease,
    _reservation: CreationReservation,
}
impl std::fmt::Debug for MaterializedCheckpoint {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("MaterializedCheckpoint")
            .field("sha256", &self.source.artifact_sha256())
            .finish_non_exhaustive()
    }
}
impl MaterializedCheckpoint {
    pub fn resources(&self) -> Resources {
        self.source.resources()
    }
    pub fn artifact_sha256(&self) -> &str {
        self.source.artifact_sha256()
    }
    pub fn manifest(&self) -> &PackManifest {
        &self.manifest
    }
    pub fn verify(&self, engine: &Engine, budget: &ReadBudget) -> Result<()> {
        self.source.verify(engine, budget)?;
        let actual = crate::checkpoint_materialize::material_proof(
            &self.source.stage.path().join("materialized"),
            &self.manifest,
            self.resources(),
            self.proof.expected.clone(),
            budget,
        )?;
        if actual != self.proof {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
}

/// Opaque fresh-creation input, not authority over any existing machine. The
/// staging allowance and owner domain remain held until consumption or cleanup.
pub struct PreparedCheckpoint {
    manifest: PackManifest,
    approval: ApprovedCheckpoint,
    versions: BTreeMap<PathBuf, Metadata>,
    stage: Stage,
}
impl std::fmt::Debug for PreparedCheckpoint {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PreparedCheckpoint")
            .field("sha256", &self.approval.artifact.sha256)
            .finish_non_exhaustive()
    }
}
impl PreparedCheckpoint {
    pub fn resources(&self) -> Resources {
        self.approval.resources
    }
    pub fn artifact_sha256(&self) -> &str {
        &self.approval.artifact.sha256
    }
    pub fn manifest(&self) -> &PackManifest {
        &self.manifest
    }

    /// Recheck retained private input versions. Inspection cannot construct this
    /// value, and its domain binding cannot cross independently opened engines.
    pub fn verify(&self, engine: &Engine, budget: &ReadBudget) -> Result<()> {
        self.verify_domain(&engine.domain, budget)
    }
    fn verify_domain(&self, domain: &Arc<DomainGuard>, budget: &ReadBudget) -> Result<()> {
        if !Arc::ptr_eq(&self.stage.domain, domain) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        self.verify_stage(budget)
    }

    fn verify_stage(&self, budget: &ReadBudget) -> Result<()> {
        budget.check()?;
        self.stage.verify()?;
        for (path, original) in &self.versions {
            budget.check()?;
            let named =
                std::fs::symlink_metadata(path).map_err(|_| Error::before(ErrorCode::Ownership))?;
            if !named.is_file() || version(&named) != version(original) {
                return Err(Error::before(ErrorCode::Ownership));
            }
        }
        budget.check()
    }
}

impl Engine {
    /// Approved source to fresh creation under a single absolute deadline.
    /// Bridges select the operator catalog; the engine rechecks immutable intent
    /// before preparing files or entering the SDK creation reservation.
    pub fn create_checkpoint_approved(
        &self,
        approval: ApprovedCheckpoint,
        intent: crate::CheckpointCreationIntent,
        budget: ReadBudget,
    ) -> Result<crate::CreationReceipt> {
        budget.check()?;
        approval.validate()?;
        crate::machine::validate_creation_identity(
            &intent.name,
            &intent.owner_token,
            &intent.incarnation,
            intent.resources,
            &intent.labels,
        )?;
        if intent.source_sha256 != approval.artifact.sha256
            || intent.resources != approval.resources
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        self.verify_templates()?;
        let source = self.prepare_checkpoint_artifact(approval, budget.clone())?;
        let checkpoint = self.materialize_checkpoint_artifact(source, budget.clone())?;
        self.create_checkpoint(
            CreateCheckpointRequest {
                name: intent.name,
                owner_token: intent.owner_token,
                incarnation: intent.incarnation,
                checkpoint,
                labels: intent.labels,
            },
            budget,
        )
    }

    /// Fresh checkpoint creation only. Existing SDK rows/directories never
    /// become restore authority; installation errors retain partial storage.
    pub fn create_checkpoint(
        &self,
        request: CreateCheckpointRequest,
        budget: ReadBudget,
    ) -> Result<crate::CreationReceipt> {
        budget.check()?;
        crate::machine::validate_creation_identity(
            &request.name,
            &request.owner_token,
            &request.incarnation,
            request.checkpoint.resources(),
            &request.labels,
        )?;
        request.checkpoint.verify(self, &budget)?;
        crate::checkpoint_install::verify_input_capacities(
            &request.checkpoint.source.stage.path().join("materialized"),
            &request.checkpoint.manifest,
            request.checkpoint.resources(),
        )?;
        let gate = self.gate(&request.name)?;
        let machine = gate
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        self.verify_templates()?;
        self.domain.verify()?;
        let supervisor = self
            .transfers
            .as_ref()
            .ok_or(Error::before(ErrorCode::Unsupported))?;
        let target = self.vm_directory(&request.name);
        if self
            .db
            .get_vm(&request.name)
            .map_err(|_| Error::before(ErrorCode::Database))?
            .is_some()
        {
            return Err(Error::before(ErrorCode::Conflict));
        }
        match std::fs::symlink_metadata(&target) {
            Ok(_) => return Err(Error::before(ErrorCode::Conflict)),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => return Err(Error::before(ErrorCode::Io)),
        }
        budget.check()?;
        let mut record = checkpoint_record(&request)?;
        if !self
            .db
            .reserve_vm_create(&request.name, &request.owner_token)
            .map_err(|_| Error::before(ErrorCode::Database))?
        {
            return Err(Error::before(ErrorCode::Conflict));
        }
        let reservation = CreationReservation {
            db: self.db.clone(),
            name: request.name.clone(),
            token: request.owner_token.clone(),
        };
        let mut checkpoint = request.checkpoint;
        let resources = checkpoint.resources();
        let result = (|| {
            budget
                .check()
                .map_err(|error| Error::uncertain(error.code))?;
            let parent = target
                .parent()
                .ok_or(Error::uncertain(ErrorCode::Ownership))?;
            crate::host::unredirected(
                parent
                    .parent()
                    .ok_or(Error::uncertain(ErrorCode::Ownership))?,
            )
            .map_err(|error| Error::uncertain(error.code))?;
            match std::fs::DirBuilder::new().mode(0o700).create(parent) {
                Ok(()) => {}
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
                Err(_) => return Err(Error::uncertain(ErrorCode::Io)),
            }
            let parent_metadata = std::fs::symlink_metadata(parent)
                .map_err(|_| Error::uncertain(ErrorCode::Ownership))?;
            crate::host::unredirected(parent).map_err(|error| Error::uncertain(error.code))?;
            if !parent_metadata.is_dir()
                || parent_metadata.uid() != unsafe { libc::geteuid() }
                || parent_metadata.mode() & 0o022 != 0
            {
                return Err(Error::uncertain(ErrorCode::Ownership));
            }
            std::fs::DirBuilder::new()
                .mode(0o700)
                .create(&target)
                .map_err(|_| Error::uncertain(ErrorCode::Conflict))?;
            let ticket = crate::checkpoint_install::Ticket {
                schema: 1,
                name: request.name.clone(),
                owner_token: request.owner_token.clone(),
                incarnation: request.incarnation.clone(),
                source_sha256: checkpoint.artifact_sha256().into(),
                material_sha256: checkpoint.proof.material_sha256.clone(),
            };
            let ticket_sha256 = ticket.publish(&target)?;
            let (metadata, expected) = crate::checkpoint_install::Metadata::new(
                checkpoint.source.stage.path(),
                &target,
                &checkpoint.proof,
                &checkpoint.manifest,
                ticket_sha256,
                budget.deadline,
            )
            .map_err(|error| Error::uncertain(error.code))?;
            checkpoint
                .source
                .stage
                .permit
                .as_mut()
                .ok_or(Error::uncertain(ErrorCode::Ownership))?
                .promote_checkpoint_install(checkpoint.proof.logical_bytes)
                .map_err(|error| Error::uncertain(error.code))?;
            let prepared = supervisor
                .prepare_checkpoint_install_owned(
                    checkpoint.source.stage.path(),
                    &target,
                    &metadata
                        .encode()
                        .map_err(|error| Error::uncertain(error.code))?,
                    expected.clone(),
                )
                .map_err(|error| Error::uncertain(error.code))?;
            Ok((prepared, expected))
        })();
        let (prepared, expected) = result?;
        let holder = Arc::new(std::sync::Mutex::new(Some(InstallationLeases {
            _checkpoint: Some(checkpoint),
            _machine: machine,
            _reservation: reservation,
        })));
        let result = supervisor
            .run(
                prepared,
                Box::new(holder.clone()),
                budget.deadline,
                &budget.cancel,
            )
            .map_err(|error| Error::uncertain(error.code))?;
        let crate::transfer_supervisor::RunResult::Collected(collected) = result else {
            return Err(Error::uncertain(ErrorCode::Native));
        };
        let proof = collected
            .installed
            .as_ref()
            .filter(|proof| proof.matches(&expected))
            .ok_or(Error::uncertain(ErrorCode::Native))?;
        if !collected.outcome.success() {
            return Err(Error::uncertain(ErrorCode::Native));
        }
        budget
            .check()
            .map_err(|error| Error::uncertain(error.code))?;
        self.domain
            .verify()
            .map_err(|error| Error::uncertain(error.code))?;
        let actual =
            crate::checkpoint_install::installed_proof(&target, resources, expected, &budget)
                .map_err(|error| Error::uncertain(error.code))?;
        if actual != *proof {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        // SDK may hard-link readonly state/backings on macOS. Authorized source
        // unlink changes target ctime; anchor first-start evidence afterward while
        // retaining native capacity, the SDK reservation and the machine gate.
        let mut authority = holder
            .lock()
            .map_err(|_| Error::uncertain(ErrorCode::Native))?
            .take()
            .ok_or(Error::uncertain(ErrorCode::Ownership))?;
        let mut checkpoint = authority
            ._checkpoint
            .take()
            .ok_or(Error::uncertain(ErrorCode::Ownership))?;
        let native = checkpoint
            .source
            .stage
            .permit
            .take()
            .ok_or(Error::uncertain(ErrorCode::Ownership))?;
        drop(checkpoint);
        if !self.jobs.available() {
            std::mem::forget(native);
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        let actual = crate::checkpoint_install::installed_proof(
            &target,
            resources,
            actual.expected,
            &budget,
        )
        .map_err(|error| Error::uncertain(error.code))?;
        let lifecycle_root = crate::checkpoint_lifecycle::Root::new(
            self.binding(),
            &request.name,
            &request.owner_token,
            &request.incarnation,
            record
                .labels
                .get("smolbox.checkpoint-sha256")
                .ok_or(Error::uncertain(ErrorCode::Ownership))?,
            resources,
            actual,
        )
        .map_err(|error| Error::uncertain(error.code))?;
        record.labels.insert(
            crate::checkpoint_lifecycle::LABEL.into(),
            lifecycle_root
                .sha256()
                .map_err(|error| Error::uncertain(error.code))?,
        );
        crate::checkpoint_lifecycle::Lifecycle::at(&target)
            .initialize(lifecycle_root)
            .map_err(|error| Error::uncertain(error.code))?;
        let receipt = self.commit_created_record(
            &request.name,
            &request.owner_token,
            &request.incarnation,
            &record,
        )?;
        let receipt = crate::material::MaterialJournal::at(&target)
            .initialize(&receipt)
            .map_err(|error| Error::uncertain(error.code))?;
        budget
            .check()
            .map_err(|error| Error::uncertain(error.code))?;
        drop(collected);
        // Source destruction follows complete installation/record proof. Its
        // original material versions may change through SDK-authorized links.
        drop(
            holder
                .lock()
                .map_err(|_| Error::uncertain(ErrorCode::Native))?
                .take(),
        );
        Ok(receipt)
    }

    /// Execute SDK extraction/store materialization in one owned worker. It has
    /// four chunk threads, no SDK row/VM dispatch and no global restore cache.
    pub fn materialize_checkpoint_artifact(
        &self,
        mut source: PreparedCheckpoint,
        budget: ReadBudget,
    ) -> Result<MaterializedCheckpoint> {
        source.verify(self, &budget)?;
        let supervisor = self
            .transfers
            .as_ref()
            .ok_or(Error::before(ErrorCode::Unsupported))?;
        let bytes =
            crate::checkpoint_materialize::material_bytes(&source.manifest, source.resources())?;
        let (metadata, expected) = crate::checkpoint_materialize::Metadata::new(
            source.stage.path(),
            &source.stage.root,
            &source.approval,
            &source.manifest,
            &source.versions,
            budget.deadline,
        )?;
        let encoded = metadata.encode()?;
        source
            .stage
            .permit
            .as_mut()
            .ok_or(Error::before(ErrorCode::Ownership))?
            .promote_checkpoint_material(bytes)?;
        let prepared =
            supervisor.prepare_checkpoint_owned(source.stage.path(), &encoded, expected.clone())?;
        let holder = Arc::new(std::sync::Mutex::new(Some(source)));
        let result = supervisor.run(
            prepared,
            Box::new(holder.clone()),
            budget.deadline,
            &budget.cancel,
        )?;
        let crate::transfer_supervisor::RunResult::Collected(collected) = result else {
            return Err(Error::uncertain(ErrorCode::Native));
        };
        let proof = collected
            .materialized
            .clone()
            .filter(|proof| proof.matches(&expected))
            .ok_or(Error::before(ErrorCode::Native))?;
        if !collected.outcome.success() {
            return Err(Error::before(ErrorCode::Native));
        }
        drop(collected); // exact child exit and removal of worker spools precede demotion
        let mut source = holder
            .lock()
            .map_err(|_| Error::before(ErrorCode::Native))?
            .take()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        source
            .stage
            .permit
            .as_mut()
            .ok_or(Error::before(ErrorCode::Ownership))?
            .collected_checkpoint_material()?;
        source.verify(self, &budget)?;
        let mut manifest = source.manifest.clone();
        let checkpoint = manifest.checkpoint.as_mut().unwrap();
        checkpoint.payload = CheckpointLayout::Assets;
        checkpoint.version = smolvm::portable_checkpoint::FORMAT_VERSION;
        checkpoint.history.clear();
        let material = MaterializedCheckpoint {
            source,
            manifest,
            proof,
        };
        material.verify(self, &budget)?;
        Ok(material)
    }

    /// Prepare operator-selected bytes privately before any fresh restore intent
    /// enters the SDK. Never select paths from inventory or a caller payload.
    pub fn prepare_checkpoint_artifact(
        &self,
        approval: ApprovedCheckpoint,
        budget: ReadBudget,
    ) -> Result<PreparedCheckpoint> {
        approval.validate()?;
        budget.check()?;
        let permit = self.jobs.acquire(crate::jobs::Demand::checkpoint_prepare(
            approval.artifact.max_bytes,
        )?)?;
        self.domain.verify()?;
        let domain = self.domain.clone();
        let pool = self.jobs.clone();
        crate::oci_start::observe_readonly(
            pool.clone(),
            budget.deadline,
            budget.cancel.clone(),
            move || prepare(approval, budget, domain, pool, permit),
        )
    }
}

fn checkpoint_record(request: &CreateCheckpointRequest) -> Result<smolvm::config::VmRecord> {
    let resources = request.checkpoint.resources();
    let mut labels = request.labels.clone();
    labels.insert("smolbox.owner".into(), request.owner_token.clone());
    labels.insert("smolbox.incarnation".into(), request.incarnation.clone());
    labels.insert(
        "smolbox.checkpoint-sha256".into(),
        request.checkpoint.artifact_sha256().into(),
    );
    let mut record = smolvm::embedded::MachineSpec {
        name: request.name.clone(),
        persistent: true,
        labels,
        resources: smolvm::agent::VmResources {
            cpus: resources.cpus,
            memory_mib: resources.memory_mib,
            storage_gib: Some(resources.storage_gib),
            overlay_gib: Some(resources.overlay_gib),
            network: false,
            allowed_cidrs: Some(vec![]),
            ..smolvm::agent::VmResources::default()
        },
        ..smolvm::embedded::MachineSpec::default()
    }
    .to_record();
    record.entrypoint = vec!["/bin/true".into()];
    record.cmd.clear();
    record.env.clear();
    record.workdir = Some("/".into());
    record.init_completed = true;
    record.forkable = true;
    record.host_uid_owner = Some(request.name.clone());
    record.checkpoint_head = request
        .checkpoint
        .manifest
        .checkpoint
        .as_ref()
        .and_then(|checkpoint| checkpoint.lineage.as_ref())
        .map(|lineage| lineage.id.clone());
    Ok(record)
}

struct Stage {
    file: Option<File>,
    directory: Option<tempfile::TempDir>,
    root: Metadata,
    permit: Option<crate::jobs::JobLease>,
    pool: crate::jobs::JobPool,
    domain: Arc<DomainGuard>,
}
impl Stage {
    fn path(&self) -> &Path {
        self.directory
            .as_ref()
            .expect("live checkpoint stage")
            .path()
    }
    fn verify(&self) -> Result<()> {
        self.domain.verify()?;
        let current = std::fs::symlink_metadata(self.path())
            .map_err(|_| Error::before(ErrorCode::Ownership))?;
        if !current.is_dir() || root_identity(&current) != root_identity(&self.root) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
}
impl Drop for Stage {
    fn drop(&mut self) {
        let owned = self.verify().is_ok();
        drop(self.file.take());
        let Some(directory) = self.directory.take() else {
            return;
        };
        // Disable tempfile's unconditional path cleanup. An unknown replacement
        // is retained, and its allowance is fenced rather than silently freed.
        let path = directory.keep();
        if !owned || std::fs::remove_dir_all(path).is_err() {
            self.pool.quarantine();
            if let Some(permit) = self.permit.take() {
                std::mem::forget(permit);
            }
        }
    }
}
fn root_identity(metadata: &Metadata) -> (u64, u64, u32, u32) {
    (
        metadata.dev(),
        metadata.ino(),
        metadata.mode(),
        metadata.uid(),
    )
}
fn version(metadata: &Metadata) -> (u64, u64, u64, u32, u32, u32, i64, i64, i64, i64) {
    (
        metadata.dev(),
        metadata.ino(),
        metadata.len(),
        metadata.mode(),
        metadata.uid(),
        metadata.gid(),
        metadata.mtime(),
        metadata.mtime_nsec(),
        metadata.ctime(),
        metadata.ctime_nsec(),
    )
}

fn prepare(
    approval: ApprovedCheckpoint,
    budget: ReadBudget,
    domain: Arc<DomainGuard>,
    pool: crate::jobs::JobPool,
    permit: crate::jobs::JobLease,
) -> Result<PreparedCheckpoint> {
    approval.validate()?;
    budget.check()?;
    domain.verify()?;
    let directory = tempfile::Builder::new()
        .prefix(".checkpoint-source-")
        .tempdir_in(&domain.directory)
        .map_err(|_| Error::before(ErrorCode::Io))?;
    std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700))
        .map_err(|_| Error::before(ErrorCode::Io))?;
    let root =
        std::fs::symlink_metadata(directory.path()).map_err(|_| Error::before(ErrorCode::Io))?;
    let mut stage = Stage {
        file: None,
        directory: Some(directory),
        root,
        permit: Some(permit),
        pool,
        domain,
    };
    stage.verify()?;
    let mut source = crate::artifact::open_regular(&approval.artifact.path)?;
    let original = source
        .metadata()
        .map_err(|_| Error::before(ErrorCode::Io))?;
    if original.len() == 0 || original.len() > approval.artifact.max_bytes {
        return Err(Error::before(ErrorCode::Validation));
    }
    let mut output =
        tempfile::NamedTempFile::new_in(stage.path()).map_err(|_| Error::before(ErrorCode::Io))?;
    let copied = crate::artifact::copy_hash(
        &mut Budgeted {
            input: &mut source,
            budget: &budget,
        },
        &mut output,
        approval.artifact.max_bytes,
    );
    budget.check()?;
    if copied? != approval.artifact.sha256 {
        return Err(Error::before(ErrorCode::Validation));
    }
    crate::checkpoint::verify_input(&source, &approval.artifact.path, &original)?;
    output
        .as_file()
        .set_permissions(std::fs::Permissions::from_mode(0o400))
        .map_err(|_| Error::before(ErrorCode::Io))?;
    output
        .as_file()
        .sync_all()
        .map_err(|_| Error::before(ErrorCode::Io))?;
    let input = stage.path().join("input.smolcheckpoint");
    stage.file = Some(
        output
            .persist_noclobber(&input)
            .map_err(|_| Error::before(ErrorCode::Io))?,
    );
    File::open(stage.path())
        .and_then(|file| file.sync_all())
        .map_err(|_| Error::before(ErrorCode::Io))?;
    let mut private_approval = approval.clone();
    private_approval.artifact.path = input.clone();
    let manifest = crate::checkpoint::inspect_artifact(&private_approval, &budget)?;
    let mut versions = BTreeMap::new();
    versions.insert(
        input.clone(),
        stage
            .file
            .as_ref()
            .unwrap()
            .metadata()
            .map_err(|_| Error::before(ErrorCode::Io))?,
    );
    if manifest.checkpoint.as_ref().unwrap().payload == CheckpointLayout::Chunked {
        let mut file = crate::artifact::open_regular(&input)?;
        let footer = smolvm_pack::packer::read_footer_from_file(&mut file)
            .map_err(|_| Error::before(ErrorCode::Validation))?;
        let store = stage.path().join("history");
        budget.check()?;
        smolvm_pack::extract::unpack_checkpoint_history(&input, &footer, &store)
            .map_err(|_| Error::before(ErrorCode::Validation))?;
        budget.check()?;
        validate_history(&store, &manifest, &approval, &budget, &mut versions)?;
    }
    let prepared = PreparedCheckpoint {
        manifest,
        approval,
        versions,
        stage,
    };
    prepared.verify_stage(&budget)?;
    Ok(prepared)
}

fn validate_history(
    store: &Path,
    outer: &PackManifest,
    approval: &ApprovedCheckpoint,
    budget: &ReadBudget,
    versions: &mut BTreeMap<PathBuf, Metadata>,
) -> Result<()> {
    let checkpoint = outer
        .checkpoint
        .as_ref()
        .ok_or(Error::before(ErrorCode::Validation))?;
    let mut objects = BTreeMap::<String, u64>::new();
    for (index, generation) in checkpoint.history.iter().enumerate() {
        budget.check()?;
        let (path, manifest) = if index == 0 {
            (
                store.join("checkpoint.json"),
                smolvm::checkpoint_store::read_manifest(store),
            )
        } else {
            (
                store
                    .join("generations")
                    .join(&generation.lineage.id)
                    .join("checkpoint.json"),
                smolvm::checkpoint_store::read_manifest_at(store, Some(&generation.lineage.id)),
            )
        };
        let manifest = manifest.map_err(|_| Error::before(ErrorCode::Validation))?;
        budget.check()?;
        let captured = manifest
            .checkpoint
            .as_ref()
            .ok_or(Error::before(ErrorCode::Validation))?;
        let mut generation_approval = approval.clone();
        if index > 0 {
            // Retained ancestors may precede stopped disk growth.
            generation_approval.resources = Resources {
                cpus: captured.cpus,
                memory_mib: captured.memory_mib,
                storage_gib: captured
                    .storage_gib
                    .ok_or(Error::before(ErrorCode::Validation))?,
                overlay_gib: captured
                    .overlay_gib
                    .ok_or(Error::before(ErrorCode::Validation))?,
            };
        }
        generation_approval.validate_compatibility(&manifest)?;
        if manifest
            .checkpoint
            .as_ref()
            .and_then(|checkpoint| checkpoint.lineage.as_ref())
            != Some(&generation.lineage)
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        if index == 0 {
            let mut expected = outer.clone();
            let header = expected.checkpoint.as_mut().unwrap();
            header.payload = CheckpointLayout::Assets;
            header.version = smolvm::portable_checkpoint::FORMAT_VERSION;
            header.history.clear();
            if expected
                .to_json()
                .map_err(|_| Error::before(ErrorCode::Validation))?
                != manifest
                    .to_json()
                    .map_err(|_| Error::before(ErrorCode::Validation))?
            {
                return Err(Error::before(ErrorCode::Validation));
            }
        }
        let data_bytes = validate_index_policy(
            &path,
            store,
            &manifest,
            generation_approval.resources,
            budget,
            &mut objects,
            versions,
        )?;
        if data_bytes != generation.data_bytes {
            return Err(Error::before(ErrorCode::Validation));
        }
        let file = crate::artifact::open_regular(&path)?;
        file.set_permissions(std::fs::Permissions::from_mode(0o400))
            .map_err(|_| Error::before(ErrorCode::Io))?;
        versions.insert(
            path,
            file.metadata().map_err(|_| Error::before(ErrorCode::Io))?,
        );
    }
    Ok(())
}

// The SDK parses/validates its index contract first. This independent reader uses
// the public StoredFile serialization and FORMAT.md for stricter managed policy:
// exact declared files, bounded logical profiles and self-contained references.
#[derive(serde::Deserialize)]
struct PolicyIndex {
    files: Vec<smolvm::checkpoint_store::StoredFile>,
}
fn validate_index_policy(
    path: &Path,
    store: &Path,
    manifest: &PackManifest,
    resources: Resources,
    budget: &ReadBudget,
    objects: &mut BTreeMap<String, u64>,
    versions: &mut BTreeMap<PathBuf, Metadata>,
) -> Result<u64> {
    let mut file = crate::artifact::open_regular(path)?;
    let length = file
        .metadata()
        .map_err(|_| Error::before(ErrorCode::Io))?
        .len();
    if length == 0 || length > HISTORY_INDEX_BYTES {
        return Err(Error::before(ErrorCode::Validation));
    }
    let mut bytes = Vec::with_capacity(length as usize);
    Budgeted {
        input: (&mut file).take(HISTORY_INDEX_BYTES + 1),
        budget,
    }
    .read_to_end(&mut bytes)
    .map_err(|_| Error::before(ErrorCode::Validation))?;
    budget.check()?;
    if bytes.len() as u64 != length {
        return Err(Error::before(ErrorCode::Validation));
    }
    let index: PolicyIndex =
        serde_json::from_slice(&bytes).map_err(|_| Error::before(ErrorCode::Validation))?;
    drop(bytes);
    let mut expected = crate::archive::checkpoint_expected_files(manifest, resources)?;
    if index.files.len() != expected.len() {
        return Err(Error::before(ErrorCode::Validation));
    }
    let mut data_bytes = 0u64;
    for file in index.files {
        budget.check()?;
        let value = serde_json::to_value(file).map_err(|_| Error::before(ErrorCode::Validation))?;
        let path = value
            .get("path")
            .and_then(|value| value.as_str())
            .ok_or(Error::before(ErrorCode::Validation))?;
        let size = value
            .get("size")
            .and_then(|value| value.as_u64())
            .ok_or(Error::before(ErrorCode::Validation))?;
        let (declared_size, digest) = expected
            .remove(path)
            .ok_or(Error::before(ErrorCode::Validation))?;
        if declared_size != size {
            return Err(Error::before(ErrorCode::Validation));
        }
        let chunks = value
            .get("chunks")
            .and_then(|value| value.as_array())
            .ok_or(Error::before(ErrorCode::Validation))?;
        let mut file_hash = digest.as_ref().map(|_| Sha256::new());
        for (index, chunk) in chunks.iter().enumerate() {
            budget.check()?;
            let offset = (index as u64)
                .checked_mul(HISTORY_OBJECT_BYTES)
                .ok_or(Error::before(ErrorCode::Validation))?;
            let length = size
                .checked_sub(offset)
                .ok_or(Error::before(ErrorCode::Validation))?
                .min(HISTORY_OBJECT_BYTES);
            if chunk.is_null() {
                if let Some(hash) = file_hash.as_mut() {
                    let zeros = [0; 64 * 1024];
                    let mut remaining = length;
                    while remaining > 0 {
                        budget.check()?;
                        let count = remaining.min(zeros.len() as u64) as usize;
                        hash.update(&zeros[..count]);
                        remaining -= count as u64;
                    }
                }
                continue;
            }
            let hash = chunk.as_str().ok_or(Error::before(ErrorCode::Validation))?;
            data_bytes = data_bytes
                .checked_add(length)
                .ok_or(Error::before(ErrorCode::Validation))?;
            if let Some(verified) = objects.get(hash) {
                if *verified != length {
                    return Err(Error::before(ErrorCode::Validation));
                }
            }
            if !objects.contains_key(hash) || file_hash.is_some() {
                let path = store.join("objects").join(hash);
                let (actual, metadata) = verify_object(&path, hash, budget, &mut file_hash)?;
                if actual != length {
                    return Err(Error::before(ErrorCode::Validation));
                }
                objects.insert(hash.into(), actual);
                versions.insert(path, metadata);
            }
        }
        if let Some(hash) = file_hash {
            if Some(hex::encode(hash.finalize())) != digest {
                return Err(Error::before(ErrorCode::Validation));
            }
        }
    }
    if !expected.is_empty() {
        return Err(Error::before(ErrorCode::Validation));
    }
    Ok(data_bytes)
}

fn verify_object(
    path: &Path,
    expected: &str,
    budget: &ReadBudget,
    file_hash: &mut Option<Sha256>,
) -> Result<(u64, Metadata)> {
    let file = crate::artifact::open_regular(path)?;
    let original = file.metadata().map_err(|_| Error::before(ErrorCode::Io))?;
    if original.len() == 0 || original.len() > crate::checkpoint::HISTORY_OBJECT_PACKED_BYTES {
        return Err(Error::before(ErrorCode::Validation));
    }
    let mut decoder = zstd::stream::read::Decoder::new(Budgeted {
        input: &file,
        budget,
    })
    .map_err(|_| Error::before(ErrorCode::Validation))?;
    decoder
        .window_log_max(23)
        .map_err(|_| Error::before(ErrorCode::Validation))?;
    let mut bounded = decoder.take(HISTORY_OBJECT_BYTES + 1);
    let mut hash = Sha256::new();
    let mut size = 0u64;
    let mut buffer = [0; 64 * 1024];
    loop {
        budget.check()?;
        let count = bounded
            .read(&mut buffer)
            .map_err(|_| Error::before(ErrorCode::Validation))?;
        if count == 0 {
            break;
        }
        size += count as u64;
        hash.update(&buffer[..count]);
        if let Some(hash) = file_hash.as_mut() {
            hash.update(&buffer[..count]);
        }
    }
    if size == 0 || size > HISTORY_OBJECT_BYTES || hex::encode(hash.finalize()) != expected {
        return Err(Error::before(ErrorCode::Validation));
    }
    crate::checkpoint::verify_input(&file, path, &original)?;
    file.set_permissions(std::fs::Permissions::from_mode(0o400))
        .map_err(|_| Error::before(ErrorCode::Io))?;
    Ok((
        size,
        file.metadata().map_err(|_| Error::before(ErrorCode::Io))?,
    ))
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::checkpoint::tests::payload_fixture;
    use serde_json::json;

    fn budget() -> ReadBudget {
        ReadBudget::for_checkpoint_work(
            std::time::Duration::from_secs(30),
            crate::Cancellation::default(),
        )
        .unwrap()
    }
    fn domain(root: &Path) -> Arc<DomainGuard> {
        std::fs::create_dir_all(root).unwrap();
        let root = root.canonicalize().unwrap();
        let binding = crate::DomainBinding {
            target_id: "local".into(),
            generation: "a".repeat(32),
            database: root.join("db"),
            vm_root: root.join("vms"),
        };
        Arc::new(DomainGuard::acquire_at(&binding, root.join("private"), true).unwrap())
    }
    fn names(path: &Path) -> Vec<std::ffi::OsString> {
        let mut result: Vec<_> = std::fs::read_dir(path)
            .unwrap()
            .map(|entry| entry.unwrap().file_name())
            .collect();
        result.sort();
        result
    }
    pub(crate) fn approve(path: PathBuf, mut approval: ApprovedCheckpoint) -> ApprovedCheckpoint {
        let bytes = std::fs::read(&path).unwrap();
        approval.artifact.path = path;
        approval.artifact.sha256 = hex::encode(Sha256::digest(&bytes));
        approval.artifact.max_bytes = bytes.len() as u64;
        approval
    }
    pub(crate) fn current_fixture() -> (ApprovedCheckpoint, PackManifest, Vec<(String, Vec<u8>)>) {
        let (approval, mut manifest, files) = payload_fixture();
        manifest.checkpoint.as_mut().unwrap().cpu_contract =
            smolvm_pack::format::CheckpointCpuContract::ExactV1 {
                fingerprint: smolvm::portable_checkpoint::cpu_fingerprint().unwrap(),
            };
        (approval, manifest, files)
    }
    pub(crate) fn pack(
        root: &Path,
        manifest: PackManifest,
        files: Vec<(String, Vec<u8>)>,
    ) -> PathBuf {
        let assets = root.join("assets");
        std::fs::create_dir_all(&assets).unwrap();
        for (path, bytes) in files {
            let path = assets.join(path);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, bytes).unwrap();
        }
        pack_directory(root.join("source.smolcheckpoint"), manifest, assets)
    }
    fn pack_directory(output: PathBuf, manifest: PackManifest, assets: PathBuf) -> PathBuf {
        smolvm_pack::packer::Packer::new(manifest)
            .with_asset_collector(smolvm_pack::assets::AssetCollector::new(assets).unwrap())
            .pack_artifact(&output)
            .unwrap();
        output
    }
    pub(crate) fn enter(
        approval: ApprovedCheckpoint,
        owner: Arc<DomainGuard>,
        pool: &crate::jobs::JobPool,
    ) -> Result<PreparedCheckpoint> {
        let permit = pool
            .acquire(crate::jobs::Demand::checkpoint_prepare(
                approval.artifact.max_bytes,
            )?)
            .unwrap();
        prepare(approval, budget(), owner, pool.clone(), permit)
    }

    #[test]
    fn approved_creation_rejects_crossed_intent_before_preparation() {
        let temp = tempfile::tempdir().unwrap();
        let engine = crate::machine::tests::test_engine(temp.path());
        let (approval, _, _) = current_fixture();
        let intent = crate::CheckpointCreationIntent {
            name: "fresh-checkpoint".into(),
            owner_token: "d".repeat(64),
            incarnation: "e".repeat(32),
            source_sha256: approval.artifact.sha256.clone(),
            resources: approval.resources,
            labels: BTreeMap::new(),
        };
        for case in 0..3 {
            let mut crossed = intent.clone();
            match case {
                0 => crossed.source_sha256 = "f".repeat(64),
                1 => crossed.resources.memory_mib += 128,
                _ => crossed.owner_token = "invalid".into(),
            }
            let failure = engine
                .create_checkpoint_approved(approval.clone(), crossed, budget())
                .unwrap_err();
            assert_eq!(failure.code, ErrorCode::Validation);
            assert_eq!(failure.dispatch, crate::Dispatch::NotDispatched);
        }
        assert!(engine.db.get_vm(&intent.name).unwrap().is_none());
        assert!(!engine.vm_directory(&intent.name).exists());
        assert!(!std::fs::read_dir(&engine.domain.directory)
            .unwrap()
            .any(|entry| {
                entry
                    .unwrap()
                    .file_name()
                    .to_string_lossy()
                    .starts_with(".checkpoint-source-")
            }));
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
    }

    fn ordinary_worker_libraries(root: &Path) -> PathBuf {
        std::env::var_os("LIBKRUN_BUNDLE").map_or_else(|| root.to_path_buf(), PathBuf::from)
    }

    #[test]
    #[ignore = "requires a built helper; explicit ordinary non-VM checkpoint installation"]
    fn ordinary_worker_checkpoint_installation_commits_only_fresh_owned_material() {
        let executable =
            PathBuf::from(std::env::var_os("SMOLBOX_TEST_FILE_WORKER").expect("built helper path"))
                .canonicalize()
                .unwrap();
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap();
        let mut engine = crate::machine::tests::test_engine(&root);
        let templates = crate::assets::tests::Fixture::new();
        crate::machine::tests::test_install_templates(&mut engine, templates.prepare().unwrap());
        let worker = crate::Executable {
            path: executable.clone(),
            sha256: hex::encode(Sha256::digest(std::fs::read(&executable).unwrap())),
        };
        let host = crate::HostContext::capture(
            engine.binding().clone(),
            "b".repeat(32),
            "c".repeat(64),
            crate::ExecutableLocator {
                boot: worker.clone(),
                file_worker: worker,
                library_directory: ordinary_worker_libraries(&root),
            },
        )
        .unwrap();
        engine.transfers = Some(
            crate::transfer_supervisor::TransferSupervisor::new(&host, engine.jobs.clone())
                .unwrap(),
        );
        let (approval, mut manifest, mut files) = current_fixture();
        let assets = root.join("operator/assets");
        std::fs::create_dir_all(&assets).unwrap();
        for disk in &mut manifest.checkpoint.as_mut().unwrap().disks {
            disk.files[0].asset.size = 1 << 30;
            disk.files[0].asset.sha256.clear();
            files.retain(|(path, _)| path != &disk.files[0].asset.path);
            let path = assets.join(&disk.files[0].asset.path);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::File::create(path)
                .unwrap()
                .set_len(1 << 30)
                .unwrap();
        }
        for (path, bytes) in files {
            let path = assets.join(path);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, bytes).unwrap();
        }
        let path = pack_directory(
            root.join("operator/source.smolcheckpoint"),
            manifest,
            assets,
        );
        let approval = approve(path, approval);
        let request = crate::CheckpointCreationIntent {
            name: "ordinary-checkpoint".into(),
            owner_token: "d".repeat(64),
            incarnation: "e".repeat(32),
            source_sha256: approval.artifact.sha256.clone(),
            resources: approval.resources,
            labels: BTreeMap::new(),
        };
        let receipt = engine
            .create_checkpoint_approved(approval.clone(), request, budget())
            .unwrap();
        assert_eq!(receipt.owner_token, "d".repeat(64));
        assert!(receipt.material.is_some());
        let record = engine.db.get_vm(&receipt.name).unwrap().unwrap();
        assert!(receipt.matches(&record).unwrap());
        assert!(record.pid.is_none());
        assert!(record.image.is_none());
        assert!(record.forkable);
        assert!(record.init_completed);
        assert_eq!(
            record.host_uid_owner.as_deref(),
            Some(receipt.name.as_str())
        );
        assert_eq!(
            record.labels.get("smolbox.checkpoint-sha256"),
            Some(&approval.artifact.sha256)
        );
        assert_eq!(record.entrypoint, vec!["/bin/true"]);
        assert!(record.env.is_empty());
        assert!(record.cmd.is_empty());
        assert!(
            smolvm::portable_checkpoint::pending_dir(&engine.vm_directory(&receipt.name)).is_some()
        );
        assert_eq!(
            std::fs::metadata(engine.vm_directory(&receipt.name).join("storage.raw"))
                .unwrap()
                .len(),
            1 << 30
        );
        assert_eq!(
            std::fs::metadata(engine.vm_directory(&receipt.name).join("overlay.raw"))
                .unwrap()
                .len(),
            1 << 30
        );
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
        assert!(!engine
            .db
            .reserve_vm_create(&receipt.name, &"f".repeat(64))
            .unwrap());
        assert_eq!(
            engine.inspect(&receipt).unwrap().state,
            crate::ObservedState::Stopped
        );
        let lifecycle =
            crate::checkpoint_lifecycle::Lifecycle::at(&engine.vm_directory(&receipt.name));
        let permit = lifecycle
            .prepare(&receipt, &record, &budget())
            .unwrap()
            .unwrap();
        lifecycle.enter(permit, &"1".repeat(32), &budget()).unwrap();
        // Persisted dispatch-state model only: no SDK boot call or VM loss.
        assert_eq!(
            engine.inspect(&receipt).unwrap().state,
            crate::ObservedState::IdentityUnknown
        );
        assert!(engine.start(&receipt).is_err());
        assert!(record.pid.is_none());
        // No VMM has started. This owned disposable fixture remains ordinary
        // filesystem/database evidence, not a captured-state restore witness.
    }

    #[test]
    #[ignore = "requires a built helper; explicit ordinary non-VM checkpoint materialization"]
    fn ordinary_worker_checkpoint_materializes_sdk_files_and_collects_without_vm_dispatch() {
        let executable = std::path::PathBuf::from(
            std::env::var_os("SMOLBOX_TEST_FILE_WORKER").expect("built helper path"),
        )
        .canonicalize()
        .unwrap();
        for chunked in [false, true] {
            let temp = tempfile::tempdir().unwrap();
            let root = temp.path().canonicalize().unwrap();
            let mut engine = crate::machine::tests::test_engine(&root);
            let worker = crate::Executable {
                path: executable.clone(),
                sha256: hex::encode(Sha256::digest(std::fs::read(&executable).unwrap())),
            };
            let host = crate::HostContext::capture(
                crate::DomainBinding {
                    target_id: "local".into(),
                    generation: "a".repeat(32),
                    database: root.join("db"),
                    vm_root: root.join("vms"),
                },
                "b".repeat(32),
                "c".repeat(64),
                crate::ExecutableLocator {
                    boot: worker.clone(),
                    file_worker: worker,
                    library_directory: ordinary_worker_libraries(&root),
                },
            )
            .unwrap();
            engine.transfers = Some(
                crate::transfer_supervisor::TransferSupervisor::new(&host, engine.jobs.clone())
                    .unwrap(),
            );
            let approval = if chunked {
                history(&root.join("operator")).0
            } else {
                let (approval, manifest, files) = current_fixture();
                approve(pack(&root.join("operator"), manifest, files), approval)
            };
            let source = enter(approval, engine.domain.clone(), &engine.jobs).unwrap();
            let material = engine
                .materialize_checkpoint_artifact(source, budget())
                .unwrap();
            assert_eq!(
                std::fs::read(
                    material
                        .source
                        .stage
                        .path()
                        .join("materialized/checkpoint/checkpoint.bin")
                )
                .unwrap(),
                b"state"
            );
            assert_eq!(
                std::fs::read(
                    material
                        .source
                        .stage
                        .path()
                        .join("materialized/checkpoint/memory.bin")
                )
                .unwrap(),
                b"memory"
            );
            material.verify(&engine, &budget()).unwrap();
            assert_eq!(engine.jobs.counts().children, 1);
            assert!(engine.jobs.counts().checkpoint_material > 0);
            assert!(engine.db.list_vms().unwrap().is_empty());
            let path = material.source.stage.path().to_path_buf();
            drop(material);
            assert!(!path.exists());
            assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
        }
    }

    #[test]
    fn private_classic_input_retains_allowance_domain_and_exact_bytes_until_owned_cleanup() {
        let temp = tempfile::tempdir().unwrap();
        let owner = domain(&temp.path().join("owner"));
        let before = names(&owner.directory);
        let (approval, manifest, files) = current_fixture();
        let approval = approve(
            pack(&temp.path().join("operator"), manifest, files),
            approval,
        );
        let source = approval.artifact.path.clone();
        let original = std::fs::read(&source).unwrap();
        let pool = crate::jobs::JobPool::default();
        let prepared = enter(approval, owner.clone(), &pool).unwrap();
        let stage = prepared.stage.path().to_path_buf();
        assert_eq!(
            std::fs::read(stage.join("input.smolcheckpoint")).unwrap(),
            original
        );
        assert_eq!(
            std::fs::metadata(stage.join("input.smolcheckpoint"))
                .unwrap()
                .mode()
                & 0o777,
            0o400
        );
        assert_eq!(std::fs::metadata(&stage).unwrap().mode() & 0o777, 0o700);
        assert!(pool.counts().checkpoint_staging > original.len() as u64);
        assert_eq!(
            pool.counts().checkpoint_metadata,
            crate::JOB_CHECKPOINT_METADATA_BYTES
        );
        let control = pool.acquire(crate::jobs::Demand::observation()).unwrap();
        let sibling = pool.acquire(crate::jobs::Demand::observation()).unwrap();
        std::fs::write(&source, b"operator replaced its source").unwrap();
        prepared.verify_domain(&owner, &budget()).unwrap();
        let other = domain(&temp.path().join("other"));
        assert_eq!(
            prepared.verify_domain(&other, &budget()).unwrap_err().code,
            ErrorCode::Ownership
        );
        assert!(!format!("{prepared:?}").contains(stage.to_str().unwrap()));
        drop(prepared);
        assert!(!stage.exists());
        assert_eq!(names(&owner.directory), before);
        assert_eq!(pool.counts().checkpoint_staging, 0);
        assert_eq!(pool.counts().checkpoint_metadata, 0);
        drop((control, sibling));
        assert_eq!(pool.counts(), crate::jobs::Counts::default());
        assert!(!temp.path().join("owner/vms").exists());
        assert!(!temp.path().join("owner/db").exists());
    }

    fn generation(
        root: &Path,
        id: &str,
        parent: Option<(&Path, &str)>,
        storage: u64,
    ) -> (ApprovedCheckpoint, PackManifest) {
        std::fs::create_dir_all(root).unwrap();
        let (mut approval, mut manifest, files) = current_fixture();
        approval.resources.storage_gib = storage;
        let checkpoint = manifest.checkpoint.as_mut().unwrap();
        checkpoint.storage_gib = Some(storage);
        checkpoint.lineage = Some(smolvm_pack::format::CheckpointLineage {
            id: id.into(),
            parent: parent.map(|(_, id)| id.into()),
            machine: "idle".into(),
            created_at: "2026-10-14T00:00:00Z".into(),
        });
        let mut writer =
            smolvm::checkpoint_store::Writer::new(&root.parent().unwrap().join("cache"), root)
                .unwrap();
        let mut stored = Vec::new();
        for (path, bytes) in files {
            stored.push(
                writer
                    .ingest(&path, bytes.len() as u64, 0o600, &mut bytes.as_slice())
                    .unwrap(),
            );
        }
        if let Some((parent, _)) = parent {
            writer.retain_generations(root, parent, 2).unwrap();
        }
        writer.finish(root, manifest.clone(), stored).unwrap();
        (approval, manifest)
    }
    pub(crate) fn history(root: &Path) -> (ApprovedCheckpoint, PackManifest, PathBuf) {
        let ancestor = root.join("ancestor");
        generation(&ancestor, &"2".repeat(32), None, 1);
        let head = root.join("head");
        let (approval, _) = generation(
            &head,
            &"1".repeat(32),
            Some((&ancestor, &"2".repeat(32))),
            2,
        );
        let path = root.join("history.smolcheckpoint");
        smolvm::checkpoint_store::export_with_history(&head, 2, &path, |manifest| {
            manifest.checkpoint.as_mut().unwrap().version =
                smolvm::portable_checkpoint::HISTORY_FORMAT_VERSION;
        })
        .unwrap();
        let manifest = smolvm_pack::packer::read_manifest_from_sidecar(&path).unwrap();
        let unpacked = root.join("unpacked");
        let footer = smolvm_pack::packer::read_footer_from_sidecar(&path).unwrap();
        smolvm_pack::extract::unpack_checkpoint_history(&path, &footer, &unpacked).unwrap();
        (approve(path, approval), manifest, unpacked)
    }

    #[test]
    fn sdk_written_history_binds_head_ancestor_profiles_references_and_input_versions() {
        let temp = tempfile::tempdir().unwrap();
        let owner = domain(&temp.path().join("owner"));
        let before = names(&owner.directory);
        let (approval, manifest, _) = history(&temp.path().join("operator"));
        let pool = crate::jobs::JobPool::default();
        let prepared = enter(approval, owner.clone(), &pool).unwrap();
        assert_eq!(prepared.resources().storage_gib, 2);
        assert_eq!(prepared.manifest().checkpoint, manifest.checkpoint);
        let store = prepared.stage.path().join("history");
        assert_eq!(
            smolvm::checkpoint_store::read_manifest_at(&store, Some(&"2".repeat(32)))
                .unwrap()
                .checkpoint
                .unwrap()
                .storage_gib,
            Some(1)
        );
        prepared.verify_domain(&owner, &budget()).unwrap();
        let object = prepared
            .versions
            .keys()
            .find(|path| path.parent() == Some(store.join("objects").as_path()))
            .unwrap()
            .clone();
        assert_eq!(std::fs::metadata(&object).unwrap().mode() & 0o777, 0o400);
        std::fs::set_permissions(&object, std::fs::Permissions::from_mode(0o600)).unwrap();
        std::fs::write(&object, b"changed object").unwrap();
        assert_eq!(
            prepared.verify_domain(&owner, &budget()).unwrap_err().code,
            ErrorCode::Ownership
        );
        drop(prepared);
        assert_eq!(names(&owner.directory), before);
        assert_eq!(pool.counts(), crate::jobs::Counts::default());
    }

    #[test]
    fn invalid_index_graphs_reject_before_any_sdk_machine_or_reusable_input_is_created() {
        let temp = tempfile::tempdir().unwrap();
        let owner = domain(&temp.path().join("owner"));
        let before = names(&owner.directory);
        let (approval, manifest, unpacked) = history(&temp.path().join("operator"));
        let index_path = unpacked.join("checkpoint.json");
        let original: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&index_path).unwrap()).unwrap();
        for case in [
            "unknown_field",
            "missing_object",
            "wrong_chunk_length",
            "hidden_file",
            "crossed_head",
            "state_digest",
        ] {
            let mut index = original.clone();
            let state_position = index["files"]
                .as_array()
                .unwrap()
                .iter()
                .position(|file| file["path"] == "checkpoint/checkpoint.bin")
                .unwrap();
            match case {
                "unknown_field" => index["unknown"] = json!(true),
                "missing_object" => {
                    index["files"][state_position]["chunks"][0] = json!("0".repeat(64))
                }
                "wrong_chunk_length" => {
                    let other = index["files"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .find(|file| file["path"] == "checkpoint/manifest.bin")
                        .unwrap()["chunks"][0]
                        .clone();
                    index["files"][state_position]["chunks"][0] = other;
                }
                "hidden_file" => {
                    index["files"][state_position]["path"] = json!("checkpoint/hidden")
                }
                "crossed_head" => index["manifest"]["checkpoint"]["memory_mib"] = json!(1024),
                "state_digest" => {
                    index["files"][state_position]["chunks"][0] = serde_json::Value::Null
                }
                _ => unreachable!(),
            }
            std::fs::write(&index_path, serde_json::to_vec(&index).unwrap()).unwrap();
            let path = pack_directory(
                temp.path().join(format!("{case}.smolcheckpoint")),
                manifest.clone(),
                unpacked.clone(),
            );
            let candidate = approve(path, approval.clone());
            let pool = crate::jobs::JobPool::default();
            let error = enter(candidate, owner.clone(), &pool).unwrap_err();
            assert_eq!(error.dispatch, crate::Dispatch::NotDispatched, "{case}");
            assert!(pool.available(), "{case}");
            assert_eq!(pool.counts(), crate::jobs::Counts::default(), "{case}");
            assert_eq!(names(&owner.directory), before, "{case}");
        }
        assert!(!temp.path().join("owner/vms").exists());
        assert!(!temp.path().join("owner/db").exists());
    }

    #[test]
    fn cancellation_and_wrong_digest_leave_no_private_stage_or_machine_state() {
        let temp = tempfile::tempdir().unwrap();
        let owner = domain(&temp.path().join("owner"));
        let before = names(&owner.directory);
        let (approval, manifest, files) = current_fixture();
        let mut approval = approve(
            pack(&temp.path().join("operator"), manifest, files),
            approval,
        );
        let pool = crate::jobs::JobPool::default();
        let cancel = crate::Cancellation::new();
        let budget =
            ReadBudget::for_checkpoint_work(std::time::Duration::from_secs(30), cancel.clone())
                .unwrap();
        cancel.cancel();
        let permit = pool
            .acquire(crate::jobs::Demand::checkpoint_prepare(approval.artifact.max_bytes).unwrap())
            .unwrap();
        assert_eq!(
            prepare(
                approval.clone(),
                budget,
                owner.clone(),
                pool.clone(),
                permit
            )
            .unwrap_err()
            .code,
            ErrorCode::State
        );
        approval.artifact.sha256 = "0".repeat(64);
        assert_eq!(
            enter(approval, owner.clone(), &pool).unwrap_err().code,
            ErrorCode::Validation
        );
        assert_eq!(names(&owner.directory), before);
        assert_eq!(pool.counts(), crate::jobs::Counts::default());
    }

    #[test]
    fn unknown_private_root_model_preserves_substitute_and_fences_staging_allowance() {
        let temp = tempfile::tempdir().unwrap();
        let owner = domain(&temp.path().join("owner"));
        let (approval, manifest, files) = current_fixture();
        let approval = approve(
            pack(&temp.path().join("operator"), manifest, files),
            approval,
        );
        let pool = crate::jobs::JobPool::default();
        let prepared = enter(approval, owner, &pool).unwrap();
        let path = prepared.stage.path().to_path_buf();
        let retained = path.with_extension("retained");
        std::fs::rename(&path, &retained).unwrap();
        std::fs::create_dir(&path).unwrap();
        std::fs::write(path.join("unknown"), b"untouched").unwrap();
        drop(prepared);
        assert_eq!(std::fs::read(path.join("unknown")).unwrap(), b"untouched");
        assert!(retained.join("input.smolcheckpoint").exists());
        assert!(!pool.available());
        assert!(pool.counts().checkpoint_staging > 0);
        assert!(pool.acquire(crate::jobs::Demand::observation()).is_ok());
    }
}
