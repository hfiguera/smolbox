//! Receipt-bound container conversion inputs and owned auxiliary launch.
//! Cached metadata supplies no source, child or publication authority.
use crate::disk_geometry::ExportDisk;
use crate::{Engine, Error, ErrorCode, ExportSourceMode, QualifiedExportSource, Result};
use serde::Deserialize;
use smolvm_protocol::AgentRequest;
use std::fs::File;

const METADATA_BYTES: usize = crate::bootstrap::METADATA_BYTES as usize;
const STRINGS: usize = 65536;

pub(crate) fn package_manager_rootfs(library: &std::path::Path) -> Result<std::path::PathBuf> {
    let package = library
        .parent()
        .ok_or(Error::before(ErrorCode::Ownership))?;
    if library.file_name() != Some(std::ffi::OsStr::new("lib")) {
        return Err(Error::before(ErrorCode::Ownership));
    }
    let path = package.join("agent-rootfs");
    crate::host::unredirected(&path)?;
    let root = crate::export_source::Root::open(&path)?;
    let resolved =
        smolvm::agent::AgentManager::resolve_rootfs_path(Some(path.clone()), "owned export helper")
            .map_err(|_| Error::before(ErrorCode::Ownership))?;
    root.verify()?;
    if resolved != path {
        return Err(Error::before(ErrorCode::Ownership));
    }
    Ok(path)
}

/// Frozen transport-neutral request identity. It does not enroll a source.
pub struct ContainerExportIntent {
    pub operation_id: String,
    pub request_sha256: String,
    pub request_identity_sha256: String,
    pub max_artifact_bytes: u64,
    pub max_staging_bytes: u64,
}
impl std::fmt::Debug for ContainerExportIntent {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ContainerExportIntent")
            .finish_non_exhaustive()
    }
}
/// Owned pre-launch scratch. No SDK initialization or VM has been dispatched.
/// Retains source/job/descriptors until explicit close or caller disposal.
pub struct ContainerExportScratch {
    helper_root: File,
    stage: crate::export_staging::Stage,
    source: PreparedContainerExport,
}
/// Initially collected storage-only SDK initialization. The retained registry
/// can subsequently launch a manager with a separate protected lifecycle.
/// Disk handles and original source/accounting remain owned by this value.
pub struct InitializedContainerStorage {
    storage: smolvm::storage::StorageDisk,
    overlay: smolvm::storage::OverlayDisk,
    scratch: ContainerExportScratch,
}
pub(crate) struct PreparedConversionManager {
    manager: smolvm::agent::AgentManager,
    rootfs: crate::export_source::Root,
    rootfs_path: std::path::PathBuf,
    launch: ConversionLaunchInputs,
    enrollment: Option<crate::epoch::BootEnrollment>,
    collection: Option<crate::epoch::BootCollection>,
}
/// Frozen configuration derived exclusively from protected scratch and the
/// retained source. This is configuration, never enrollment or launch evidence.
struct ConversionLaunchInputs {
    source_view: ExportDisk,
    plan: crate::ExportConversionBudget,
    source_directory: std::path::PathBuf,
}
impl ConversionLaunchInputs {
    fn capture(storage: &InitializedContainerStorage) -> Result<Self> {
        let scratch = &storage.scratch;
        let (_, path) = scratch
            .stage
            .prepared_helper_identity(&scratch.helper_root)?;
        let plan = scratch
            .stage
            .formatted_helper_budget(&scratch.helper_root)?;
        if scratch.source.conversion.as_ref() != Some(&plan) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let source_view = ExportDisk::capture_source_view(
            &path,
            &scratch.source.storage,
            scratch.source.source.budget(),
        )?;
        let inputs = Self {
            source_view,
            plan,
            source_directory: scratch.source.source.directory().into(),
        };
        inputs.sdk_config(storage)?;
        Ok(inputs)
    }
    fn sdk_config(
        &self,
        storage: &InitializedContainerStorage,
    ) -> Result<(smolvm::agent::VmResources, smolvm::agent::LaunchFeatures)> {
        let scratch = &storage.scratch;
        if self.plan
            != scratch
                .stage
                .formatted_helper_budget(&scratch.helper_root)?
            || scratch.source.conversion.as_ref() != Some(&self.plan)
            || self.source_directory != scratch.source.source.directory()
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let budget = scratch.source.source.budget();
        scratch.source.storage.verify(budget)?;
        self.source_view.verify(budget)?;
        let resources = self.plan.vm_resources();
        resources
            .validate()
            .map_err(|_| Error::before(ErrorCode::Validation))?;
        let (path, format) = self.source_view.sdk_source();
        let features = smolvm::agent::LaunchFeatures {
            // Journal replay is confined to the private COW. Never attach the
            // held source writable or expose an arbitrary extra disk/mount.
            extra_disks: vec![(path, false, format)],
            uid_share_dir: Some(self.source_directory.clone()),
            ..Default::default()
        };
        budget.check()?;
        Ok((resources, features))
    }
}
impl PreparedConversionManager {
    pub(crate) fn start_owned(
        &mut self,
        storage: &mut InitializedContainerStorage,
        epoch: &crate::epoch::ActorEpoch,
        budget: &crate::ReadBudget,
    ) -> Result<()> {
        budget.check()?;
        self.recheck(storage)?;
        let (name, path) = storage
            .scratch
            .stage
            .prepared_helper_identity(&storage.scratch.helper_root)?;
        if smolvm::agent::vm_data_dir(&name) != path || !epoch.launcher_selected() {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let (resources, features) = self.launch.sdk_config(storage)?;
        budget.check()?;
        let dispatch = epoch.begin_boot(&name)?;
        storage.scratch.stage.begin_helper_launch(
            &storage.scratch.helper_root,
            &dispatch,
            epoch,
        )?;
        if !epoch.launcher_selected() {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        let started =
            self.manager
                .start_with_full_config(Vec::new(), Vec::new(), resources, features);
        let pid = self.manager.child_pid();
        let enrolled = dispatch
            .finish_enrollment(pid)
            .map_err(|e| Error::uncertain(e.code))?;
        self.enrollment = Some(enrolled);
        // Preserve dispatch evidence even after cancellation or an SDK error.
        // It never substitutes for normal child collection or launch success.
        storage
            .scratch
            .stage
            .helper_launch_returned(
                &storage.scratch.helper_root,
                self.enrollment.as_ref().unwrap(),
            )
            .map_err(|e| Error::uncertain(e.code))?;
        started.map_err(|e| Error::uncertain(crate::sdk_compat::launch_error(&e)))?;
        self.recheck_started(storage, epoch)?;
        budget.check().map_err(|e| Error::uncertain(e.code))
    }
    pub(crate) fn collect_owned(
        &mut self,
        storage: &mut InitializedContainerStorage,
        epoch: &crate::epoch::ActorEpoch,
        budget: &crate::ReadBudget,
    ) -> Result<()> {
        budget.check()?;
        self.rootfs.verify()?;
        let enrolled = self
            .enrollment
            .as_ref()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        if storage.scratch.stage.runtime_prepared()? {
            let collected = self
                .collection
                .as_ref()
                .ok_or(Error::before(ErrorCode::Ownership))?;
            return storage.scratch.stage.verify_helper_runtime(
                &storage.scratch.helper_root,
                epoch,
                collected,
                &self.rootfs,
                budget,
            );
        }
        if storage.scratch.stage.helper_launch_pending()? {
            // Reconcile a retained, actually returned SDK enrollment whose
            // original publication failed. This does not replay SDK launch.
            storage
                .scratch
                .stage
                .helper_launch_returned(&storage.scratch.helper_root, enrolled)?;
        }
        let (name, path, child) = storage
            .scratch
            .stage
            .enrolled_helper_identity(&storage.scratch.helper_root, epoch)?;
        if enrolled.child() != child
            || !enrolled.intent().matches_epoch(&name, epoch)
            || self.manager.name() != Some(name.as_str())
            || smolvm::agent::vm_data_dir(&name) != path
            || self.manager.storage_path() != path.join(smolvm::storage::STORAGE_DISK_FILENAME)
            || self.manager.overlay_path() != path.join(smolvm::storage::OVERLAY_DISK_FILENAME)
            || self.manager.child_pid().is_some_and(|pid| pid != child.pid)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        if self.collection.is_none() {
            let already_gone = match epoch.collect_enrolled(&name, enrolled) {
                Ok(collected) => Some(collected),
                Err(error) if error.code == ErrorCode::Conflict => None,
                Err(error) => return Err(error),
            };
            if !storage.scratch.stage.helper_collection_entered()? {
                storage.scratch.stage.begin_helper_collection(
                    &storage.scratch.helper_root,
                    epoch,
                    enrolled,
                )?;
            } else if already_gone.is_none() {
                // An entered stop remains unknown/failed. Never replay it
                // implicitly or reconstruct manager ownership from a PID file.
                return Err(Error::before(ErrorCode::Conflict));
            }
            if let Some(collected) = already_gone {
                self.manager.mark_stopped();
                self.collection = Some(collected);
            } else {
                budget.check().map_err(|e| Error::uncertain(e.code))?;
                if self.manager.child_pid() != Some(child.pid)
                    || smolvm::process::process_start_time(child.pid) != Some(child.birth)
                {
                    return Err(Error::uncertain(ErrorCode::Ownership));
                }
                // Keep the existing actor pending while SDK owns shutdown/reap.
                // A sibling actor sweep cannot consume its child status and
                // permit PID reuse before the SDK stop call finishes.
                let dispatch = epoch.begin_collection(&name, enrolled)?;
                let stopped = self.manager.stop();
                dispatch
                    .sdk_returned()
                    .map_err(|e| Error::uncertain(e.code))?;
                stopped.map_err(|_| Error::uncertain(ErrorCode::Native))?;
                if self.manager.child_pid().is_some() {
                    return Err(Error::uncertain(ErrorCode::Ownership));
                }
                self.collection = Some(
                    epoch
                        .collect_enrolled(&name, enrolled)
                        .map_err(|e| Error::uncertain(e.code))?,
                );
            }
        }
        storage
            .scratch
            .stage
            .helper_child_collected(
                &storage.scratch.helper_root,
                epoch,
                self.collection.as_ref().unwrap(),
            )
            .map_err(|e| Error::uncertain(e.code))?;
        storage
            .scratch
            .stage
            .prepare_helper_runtime(
                &storage.scratch.helper_root,
                epoch,
                self.collection.as_ref().unwrap(),
                &self.rootfs,
                budget,
            )
            .map_err(|e| Error::uncertain(e.code))?;
        // Keep actual late collection evidence without returning late success.
        budget.check().map_err(|e| Error::uncertain(e.code))
    }
    pub(crate) fn recheck_started(
        &self,
        storage: &InitializedContainerStorage,
        epoch: &crate::epoch::ActorEpoch,
    ) -> Result<()> {
        self.rootfs.verify().map_err(|e| Error::uncertain(e.code))?;
        let (name, path, child) = storage
            .scratch
            .stage
            .returned_helper_identity(&storage.scratch.helper_root, epoch)?;
        if self.manager.name() != Some(name.as_str())
            || self.manager.child_pid() != Some(child.pid)
            || self.manager.storage_path() != path.join(smolvm::storage::STORAGE_DISK_FILENAME)
            || self.manager.overlay_path() != path.join(smolvm::storage::OVERLAY_DISK_FILENAME)
        {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        Ok(())
    }
    pub(crate) fn unstarted(&self) -> bool {
        self.enrollment.is_none() && self.collection.is_none() && self.manager.child_pid().is_none()
    }
    pub(crate) fn has_collection(&self) -> bool {
        self.collection.is_some()
    }
    pub(crate) fn verify_collected(
        &self,
        storage: &InitializedContainerStorage,
        epoch: &crate::epoch::ActorEpoch,
        budget: &crate::ReadBudget,
    ) -> Result<()> {
        let collection = self
            .collection
            .as_ref()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        if self.manager.child_pid().is_some() {
            return Err(Error::before(ErrorCode::Ownership));
        }
        storage.scratch.stage.verify_helper_runtime(
            &storage.scratch.helper_root,
            epoch,
            collection,
            &self.rootfs,
            budget,
        )
    }
    pub(crate) fn recheck(&self, storage: &InitializedContainerStorage) -> Result<()> {
        self.rootfs.verify()?;
        let (name, path) = storage
            .scratch
            .stage
            .prepared_helper_identity(&storage.scratch.helper_root)?;
        if self.manager.name() != Some(name.as_str())
            || self.manager.child_pid().is_some()
            || self.manager.storage_path() != path.join(smolvm::storage::STORAGE_DISK_FILENAME)
            || self.manager.overlay_path() != path.join(smolvm::storage::OVERLAY_DISK_FILENAME)
            || !self.rootfs_path.is_absolute()
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        self.launch.sdk_config(storage).map(|_| ())
    }
}
impl InitializedContainerStorage {
    pub(crate) fn conversion_input(
        &self,
        engine: &Engine,
    ) -> Result<crate::ContainerConversionInput> {
        self.scratch.source.conversion_input(engine)
    }
    pub(crate) fn conversion_socket(
        &self,
        epoch: &crate::epoch::ActorEpoch,
    ) -> Result<std::path::PathBuf> {
        let (_, path, _) = self
            .scratch
            .stage
            .returned_helper_identity(&self.scratch.helper_root, epoch)?;
        Ok(path.join("agent.sock"))
    }
    pub(crate) fn verify_conversion_plan(
        &self,
        engine: &Engine,
        plan: &ContainerExportPlan,
    ) -> Result<()> {
        self.recheck_source(engine)?;
        self.scratch.source.verify_plan(engine, plan)
    }
    pub(crate) fn register_conversion(
        &mut self,
        conversion: &mut crate::CollectedContainerConversion,
    ) -> Result<crate::ExportStagedFile> {
        self.scratch.stage.register_layer(conversion)
    }
    pub(crate) fn retire_layer_helper(&mut self) -> Result<()> {
        self.scratch
            .stage
            .retire_layer_helper(self.scratch.source.source.budget())
    }
    pub(crate) fn pack_container(
        &mut self,
        engine: &Engine,
        plan: &ContainerExportPlan,
    ) -> Result<crate::ExportStagedFile> {
        self.verify_conversion_plan(engine, plan)?;
        let layer = self.scratch.stage.container_layer()?;
        let assets = engine
            .export_asset_approval()?
            .qualify(self.scratch.source.source.budget())?;
        let record = self.scratch.source.source.checked_record(engine)?;
        let manifest = crate::export_pack::container_manifest(&record, plan, &layer, &assets)?;
        let maximum = self
            .scratch
            .source
            .conversion
            .as_ref()
            .ok_or(Error::before(ErrorCode::Ownership))?
            .artifact_limit(layer.size_bytes)?;
        let artifact = crate::export_pack::pack(
            &mut self.scratch.stage,
            &[layer],
            &assets,
            &manifest,
            maximum,
            self.scratch.source.source.budget(),
        )?;
        self.recheck_source(engine)?;
        Ok(artifact)
    }
    pub(crate) fn recheck_packed(&self, engine: &Engine) -> Result<()> {
        self.recheck_source(engine)?;
        self.scratch.stage.container_layer()?;
        self.scratch.stage.verify()
    }
    pub(crate) fn read_artifact(&self, offset: u64, output: &mut [u8]) -> Result<()> {
        self.scratch.stage.read_at(
            "artifact.smolmachine",
            offset,
            output,
            self.scratch.source.source.budget(),
        )
    }
    pub(crate) fn publish_container(
        &mut self,
        engine: &Engine,
        artifact: &crate::ExportStagedFile,
        destination: &crate::ApprovedExportDestination,
        tag: &str,
        credential: &crate::RegistryPublishCredential,
    ) -> Result<crate::ExportPublication> {
        self.recheck_packed(engine)?;
        let source = &self.scratch.source;
        let budget = source.source.budget();
        let plan = crate::export_publication::Plan::from_artifact(
            &self.scratch.stage,
            artifact,
            destination,
            tag,
            budget,
        )?;
        crate::export_publication::publish(
            &mut self.scratch.stage,
            artifact,
            &plan,
            destination,
            credential,
            budget,
            || source.recheck(engine),
        )
    }
    pub(crate) fn unlaunched_helper_recorded(&self) -> Result<bool> {
        self.scratch.stage.unlaunched_helper_recorded()
    }
    pub(crate) fn runtime_custody_recorded(&self) -> Result<bool> {
        self.scratch.stage.runtime_custody_recorded()
    }
    pub(crate) fn original_budget(&self) -> crate::ReadBudget {
        self.scratch.source.source.budget().clone()
    }
    pub(crate) fn recheck_source(&self, engine: &Engine) -> Result<()> {
        self.scratch.source.recheck(engine)
    }
    pub(crate) fn prepare_manager(&self, engine: &Engine) -> Result<PreparedConversionManager> {
        self.recheck(engine)?;
        let (name, path) = self
            .scratch
            .stage
            .prepared_helper_identity(&self.scratch.helper_root)?;
        if smolvm::agent::vm_data_dir(&name) != path {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let launch = ConversionLaunchInputs::capture(self)?;
        let rootfs_path = engine.export_manager_rootfs()?;
        let rootfs = crate::export_source::Root::open(&rootfs_path)?;
        // Reopen only the exact collected files. This constructor creates no
        // disks, resolves no default/cache rootfs and starts no child process.
        let storage = smolvm::storage::StorageDisk::open_existing_with_format(
            self.storage.path(),
            smolvm::data::disk::DiskFormat::Raw,
        )
        .map_err(|_| Error::before(ErrorCode::Ownership))?;
        let overlay = smolvm::storage::OverlayDisk::open_existing_with_format(
            self.overlay.path(),
            smolvm::data::disk::DiskFormat::Raw,
        )
        .map_err(|_| Error::before(ErrorCode::Ownership))?;
        self.recheck(engine)?;
        let manager =
            smolvm::agent::AgentManager::new_named(name, rootfs_path.clone(), storage, overlay)
                .map_err(|_| Error::before(ErrorCode::Native))?;
        let prepared = PreparedConversionManager {
            manager,
            rootfs,
            rootfs_path,
            launch,
            enrollment: None,
            collection: None,
        };
        prepared.recheck(self)?;
        self.recheck(engine)?;
        Ok(prepared)
    }
    pub(crate) fn retained_domain_matches(
        &self,
        domain: &std::sync::Arc<crate::domain::DomainGuard>,
    ) -> bool {
        self.scratch.source.source.same_domain(domain)
    }
    pub(crate) fn retained_identity(&self) -> Result<(crate::CreationReceipt, String, String)> {
        self.scratch
            .stage
            .prepared_helper_identity(&self.scratch.helper_root)?;
        self.scratch.stage.retained_identity()
    }
    pub(crate) fn cleanup_retained(
        &self,
        budget: &crate::ReadBudget,
    ) -> Result<crate::ExportStageCleanup> {
        self.scratch.stage.cleanup_retained(budget)
    }
}
impl std::fmt::Debug for InitializedContainerStorage {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("InitializedContainerStorage")
            .finish_non_exhaustive()
    }
}
impl InitializedContainerStorage {
    pub fn recheck(&self, engine: &Engine) -> Result<()> {
        self.scratch.source.recheck(engine)?;
        let (_, path) = self
            .scratch
            .stage
            .prepared_helper_identity(&self.scratch.helper_root)?;
        if self.storage.path() != path.join(smolvm::storage::STORAGE_DISK_FILENAME)
            || self.overlay.path() != path.join(smolvm::storage::OVERLAY_DISK_FILENAME)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
    pub fn close(self, budget: &crate::ReadBudget) -> Result<crate::ExportStageCleanup> {
        self.scratch.stage.close(budget)
    }
}
impl std::fmt::Debug for ContainerExportScratch {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ContainerExportScratch")
            .finish_non_exhaustive()
    }
}
impl ContainerExportScratch {
    pub fn initialize_sdk_storage(
        mut self,
        engine: &Engine,
    ) -> Result<crate::RetainedConversionStorage> {
        self.verify_sdk_namespace(engine)?;
        let library = engine.export_sdk_library()?;
        let budget = self.source.source.budget().clone();
        let pool = engine.jobs.clone();
        let retention = engine.export_retention.clone();
        let plan = self
            .source
            .conversion
            .as_ref()
            .ok_or(Error::before(ErrorCode::Ownership))?
            .clone();
        let (base, format) = self.source.storage.sdk_source();
        self.source.storage.verify(&budget)?;
        crate::oci_start::observe_owned(
            pool.clone(),
            budget.deadline,
            budget.cancel.clone(),
            move || {
                budget.check()?;
                let (name, path) = self.stage.begin_helper_sdk(&self.helper_root)?;
                let result = (|| -> Result<_> {
                    budget.check()?;
                    if smolvm::agent::vm_data_dir(&name) != path {
                        return Err(Error::uncertain(ErrorCode::Ownership));
                    }
                    let actual = smolvm::agent::ensure_vm_dir(&name)
                        .map_err(|_| Error::uncertain(ErrorCode::Io))?;
                    if actual != path {
                        return Err(Error::uncertain(ErrorCode::Ownership));
                    }
                    // The SDK copies template permissions before growing a
                    // formatted disk. Format at the approved one-GiB baseline,
                    // make only these owned copies writable, then grow through
                    // the public SDK. Immutable account templates stay unchanged.
                    let storage = smolvm::storage::StorageDisk::open_or_create_at(
                        &path.join(smolvm::storage::STORAGE_DISK_FILENAME),
                        1,
                    )
                    .map_err(|_| Error::uncertain(ErrorCode::Io))?;
                    let overlay = smolvm::storage::OverlayDisk::open_or_create_at(
                        &path.join(smolvm::storage::OVERLAY_DISK_FILENAME),
                        plan.overlay_gib,
                    )
                    .map_err(|_| Error::uncertain(ErrorCode::Io))?;
                    storage
                        .ensure_formatted()
                        .map_err(|_| Error::uncertain(ErrorCode::Io))?;
                    overlay
                        .ensure_formatted()
                        .map_err(|_| Error::uncertain(ErrorCode::Io))?;
                    crate::assets::prepare_created_disk(storage.path())?;
                    crate::assets::prepare_created_disk(overlay.path())?;
                    let storage = smolvm::storage::StorageDisk::open_or_create_at(
                        storage.path(),
                        plan.storage_gib,
                    )
                    .map_err(|_| Error::uncertain(ErrorCode::Io))?;
                    budget.check()?;
                    self.source.storage.verify(&budget)?;
                    if smolvm::agent::find_lib_dir().as_ref() != Some(&library) {
                        return Err(Error::uncertain(ErrorCode::Ownership));
                    }
                    smolvm::agent::create_disk_overlays(&[(
                        path.join("export-source.qcow2"),
                        base,
                        format,
                    )])
                    .map_err(|_| Error::uncertain(ErrorCode::Io))?;
                    Ok((storage, overlay))
                })();
                // The storage-only SDK batch has returned, even if caller observation
                // retired or a partial allocation failed. Record its exact private
                // file identities for cleanup without promoting a late success.
                if let Err(error) = self.stage.collect_helper_sdk(&self.helper_root) {
                    pool.quarantine();
                    return Err(Error::uncertain(error.code));
                }
                let (storage, overlay) = result?;
                let retained = retention.insert(InitializedContainerStorage {
                    storage,
                    overlay,
                    scratch: self,
                })?;
                budget.check().map_err(|e| Error::uncertain(e.code))?;
                Ok(retained)
            },
        )
    }
    pub fn recheck(&self, engine: &Engine) -> Result<()> {
        self.source.recheck(engine)?;
        self.stage.verify()?;
        self.stage.helper_identity(&self.helper_root)?;
        Ok(())
    }
    /// Mandatory namespace check before any future SDK lifecycle entry. A
    /// database-only fixture never supplies the SDK's process cache authority.
    pub fn verify_sdk_namespace(&self, engine: &Engine) -> Result<()> {
        self.recheck(engine)?;
        let (name, path) = self.stage.helper_identity(&self.helper_root)?;
        if smolvm::agent::vm_data_dir(&name) != path {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
    pub fn close(self, budget: &crate::ReadBudget) -> Result<crate::ExportStageCleanup> {
        self.stage.close(budget)
    }
}

/// Holds the stopped source gate, logical storage descriptors and original
/// deadline through conversion. Only receipt qualification can construct it.
pub struct PreparedContainerExport {
    storage: ExportDisk,
    // Close imported descriptors before releasing the source gate/job/domain.
    imported: Option<crate::export_import::Pack>,
    conversion: Option<crate::ExportConversionBudget>,
    source: QualifiedExportSource,
}
impl std::fmt::Debug for PreparedContainerExport {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PreparedContainerExport")
            .finish_non_exhaustive()
    }
}
impl QualifiedExportSource {
    pub fn prepare_container_export(mut self, engine: &Engine) -> Result<PreparedContainerExport> {
        let record = self.checked_record(engine)?;
        if self.mode() != ExportSourceMode::Container {
            return Err(Error::before(ErrorCode::Unsupported));
        }
        self.promote_disks()?;
        let imported = if record.source_smolmachine.is_some() {
            Some(crate::export_import::Pack::qualify(
                engine,
                &record,
                self.budget(),
            )?)
        } else {
            registry_source(&record)?;
            None
        };
        let storage = ExportDisk::capture(
            self.directory(),
            smolvm::storage::STORAGE_DISK_FILENAME,
            record
                .storage_gb
                .ok_or(Error::before(ErrorCode::Ownership))?,
            self.budget(),
        )?;
        let prepared = PreparedContainerExport {
            storage,
            source: self,
            conversion: None,
            imported,
        };
        prepared.recheck(engine)?;
        Ok(prepared)
    }
}
pub(crate) fn registry_source(record: &smolvm::config::VmRecord) -> Result<&str> {
    let image = record
        .image
        .as_deref()
        .ok_or(Error::before(ErrorCode::Unsupported))?;
    if record.source_smolmachine.is_some() || smolvm::data::image_source::is_local_ref(image) {
        return Err(Error::before(ErrorCode::Unsupported));
    }
    crate::ImagePullRequest {
        reference: image.into(),
        platform: crate::oci::native_oci_platform().into(),
    }
    .validate()?;
    Ok(image)
}
impl PreparedContainerExport {
    /// Frozen worker input only; the parent must retain this source's actual
    /// leases and authenticate/enroll its helper and worker separately.
    pub fn conversion_input(&self, engine: &Engine) -> Result<crate::ContainerConversionInput> {
        self.recheck(engine)?;
        let plan = self
            .conversion
            .as_ref()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        let record = self.source.checked_record(engine)?;
        let imported = self
            .imported
            .as_ref()
            .map(|pack| pack.snapshot(self.source.budget()))
            .transpose()?;
        if imported
            .as_ref()
            .map(|input| input.allowance())
            .transpose()?
            != plan.imported
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        match imported {
            Some(imported) => crate::export_bootstrap::ContainerConversionInput::from_source(
                record,
                plan.max_flattened_bytes,
                self.source.budget(),
                Some(imported),
            ),
            None => crate::export_bootstrap::ContainerConversionInput::from_record(
                record,
                plan.max_flattened_bytes,
                self.source.budget(),
            ),
        }
    }
    /// Enroll protected helper scratch before SDK entry. The existing export
    /// admission must match the full frozen request. This performs no SDK call.
    pub fn prepare_conversion_scratch(
        self,
        engine: &Engine,
        resources: &crate::ExportConversionResources,
        intent: &ContainerExportIntent,
    ) -> Result<ContainerExportScratch> {
        self.prepare_scratch(engine, resources, intent, false)
    }
    pub(crate) fn prepare_shared_conversion_scratch(
        self,
        engine: &Engine,
        resources: &crate::ExportConversionResources,
        intent: &ContainerExportIntent,
    ) -> Result<ContainerExportScratch> {
        self.prepare_scratch(engine, resources, intent, true)
    }
    fn prepare_scratch(
        mut self,
        engine: &Engine,
        resources: &crate::ExportConversionResources,
        intent: &ContainerExportIntent,
        shared: bool,
    ) -> Result<ContainerExportScratch> {
        self.recheck(engine)?;
        engine.check_export_intent(
            self.source.receipt(),
            &intent.operation_id,
            &intent.request_sha256,
            intent.max_staging_bytes,
            &intent.request_identity_sha256,
            self.source.budget(),
        )?;
        let plan = if shared {
            let plan = self.resource_plan(
                resources,
                intent.max_artifact_bytes,
                intent.max_staging_bytes,
                true,
            )?;
            self.reserve_plan(engine, plan)?
        } else {
            self.reserve_conversion(
                engine,
                resources,
                intent.max_artifact_bytes,
                intent.max_staging_bytes,
            )?
        };
        let mut stage = engine.export_staging.create(
            self.source.receipt(),
            &intent.operation_id,
            &intent.request_sha256,
            intent.max_staging_bytes,
            self.source.budget(),
        )?;
        let prepared = stage.prepare_helper(resources, &plan, self.source.budget());
        match prepared {
            Ok(helper_root) => {
                let scratch = ContainerExportScratch {
                    helper_root,
                    stage,
                    source: self,
                };
                if let Err(error) = scratch.recheck(engine) {
                    engine.jobs.quarantine();
                    return Err(Error::uncertain(error.code));
                }
                Ok(scratch)
            }
            Err(error) => {
                engine.jobs.quarantine();
                Err(Error::uncertain(error.code))
            }
        }
    }
    /// Atomically reserve the VMM and agent worker within this source job.
    /// No child is spawned and no scratch grant or collection proof is minted.
    /// The caller must retain this handle through actual execution/collection.
    pub fn reserve_conversion(
        &mut self,
        engine: &Engine,
        resources: &crate::ExportConversionResources,
        max_artifact_bytes: u64,
        max_staging_bytes: u64,
    ) -> Result<crate::ExportConversionBudget> {
        self.recheck(engine)?;
        let plan = self.resource_plan(resources, max_artifact_bytes, max_staging_bytes, false)?;
        self.reserve_plan(engine, plan)
    }
    pub(crate) fn resource_plan(
        &self,
        resources: &crate::ExportConversionResources,
        artifact: u64,
        staging: u64,
        shared: bool,
    ) -> Result<crate::ExportConversionBudget> {
        if let Some(pack) = &self.imported {
            let input = pack.snapshot(self.source.budget())?;
            resources.imported_plan(
                self.storage.len(),
                artifact,
                staging,
                &input.allowance()?,
                shared,
            )
        } else if shared {
            resources.shared_plan(self.storage.len(), artifact, staging)
        } else {
            resources.plan(self.storage.len(), artifact, staging)
        }
    }
    fn reserve_plan(
        &mut self,
        engine: &Engine,
        plan: crate::ExportConversionBudget,
    ) -> Result<crate::ExportConversionBudget> {
        self.recheck(engine)?;
        if self
            .conversion
            .as_ref()
            .is_some_and(|previous| previous != &plan)
        {
            return Err(Error::before(ErrorCode::Conflict));
        }
        self.source.promote_conversion()?;
        self.conversion = Some(plan.clone());
        self.recheck(engine)?;
        Ok(plan)
    }
    pub fn storage_bytes(&self) -> u64 {
        self.storage.len()
    }
    pub fn read_storage_at(&self, offset: u64, bytes: &mut [u8]) -> Result<()> {
        self.storage.read_at(offset, bytes, self.source.budget())
    }
    pub fn recheck(&self, engine: &Engine) -> Result<()> {
        self.source.recheck(engine)?;
        if let Some(pack) = &self.imported {
            pack.verify(self.source.budget())?;
        }
        self.storage.verify(self.source.budget())
    }
    // These requests are intended for an enrolled conversion helper with the
    // source's private read-only/COW storage view, not the stopped source agent.
    pub fn cached_query(&self, engine: &Engine) -> Result<AgentRequest> {
        self.recheck(engine)?;
        let record = self.source.checked_record(engine)?;
        Ok(AgentRequest::Query {
            image: registry_source(&record)?.into(),
        })
    }
    pub fn conversion_plan(
        &self,
        engine: &Engine,
        bytes: &[u8],
        verified: &crate::VerifiedOci,
    ) -> Result<ContainerExportPlan> {
        self.recheck(engine)?;
        let record = self.source.checked_record(engine)?;
        let plan = ContainerExportPlan::from_cached(&record, bytes, verified)?;
        self.recheck(engine)?;
        Ok(plan)
    }
    fn verify_plan(&self, engine: &Engine, plan: &ContainerExportPlan) -> Result<()> {
        self.recheck(engine)?;
        let record = self.source.checked_record(engine)?;
        plan.validate(&record)?;
        if let Some(pack) = &self.imported {
            let expected =
                ContainerExportPlan::from_imported(&record, &pack.snapshot(self.source.budget())?)?;
            if crate::material::hash(plan)? != crate::material::hash(&expected)? {
                return Err(Error::before(ErrorCode::Ownership));
            }
        }
        Ok(())
    }

    /// Seed metadata only after rechecking this source and its exact conversion
    /// plan. This supplies no flattened-layer, helper or publication proof.
    pub fn container_manifest(
        &self,
        engine: &Engine,
        plan: &ContainerExportPlan,
        layer_bytes: u64,
    ) -> Result<smolvm_pack::format::PackManifest> {
        self.recheck(engine)?;
        let record = self.source.checked_record(engine)?;
        self.verify_plan(engine, plan)?;
        let manifest = plan.seed_manifest(&record, layer_bytes)?;
        self.recheck(engine)?;
        Ok(manifest)
    }
}

// Bound each sequence during decoding, before constructing SDK ImageInfo. The
// overall byte cap applies before JSON deserialization; unknown fields reject.
fn strings<'de, D: serde::Deserializer<'de>>(
    decoder: D,
) -> std::result::Result<Vec<String>, D::Error> {
    bounded_strings(decoder, STRINGS)
}
fn bounded_strings<'de, D: serde::Deserializer<'de>>(
    decoder: D,
    maximum: usize,
) -> std::result::Result<Vec<String>, D::Error> {
    struct Visitor(usize);
    impl<'de> serde::de::Visitor<'de> for Visitor {
        type Value = Vec<String>;
        fn expecting(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            f.write_str("bounded container metadata strings")
        }
        fn visit_seq<A: serde::de::SeqAccess<'de>>(
            self,
            mut seq: A,
        ) -> std::result::Result<Self::Value, A::Error> {
            let mut values = Vec::new();
            while let Some(value) = seq.next_element::<String>()? {
                if values.len() == self.0 || value.contains('\0') {
                    return Err(serde::de::Error::custom("container metadata limit"));
                }
                values.push(value);
            }
            Ok(values)
        }
    }
    decoder.deserialize_seq(Visitor(maximum))
}
fn flatten_request<'de, D: serde::Deserializer<'de>>(
    decoder: D,
) -> std::result::Result<AgentRequest, D::Error> {
    fn lowerdirs<'de, D: serde::Deserializer<'de>>(
        decoder: D,
    ) -> std::result::Result<Vec<String>, D::Error> {
        bounded_strings(decoder, STRINGS + 1)
    }
    #[derive(Deserialize)]
    enum Method {
        #[serde(rename = "flatten_layers")]
        FlattenLayers,
    }
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Flatten {
        method: Method,
        #[serde(deserialize_with = "lowerdirs")]
        lowerdirs: Vec<String>,
        output: Option<String>,
    }
    let Flatten {
        method: Method::FlattenLayers,
        lowerdirs,
        output,
    } = Flatten::deserialize(decoder)?;
    if output.is_some() {
        return Err(serde::de::Error::custom(
            "conversion requires streaming output",
        ));
    }
    Ok(AgentRequest::FlattenLayers { lowerdirs, output })
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct CachedImage {
    reference: String,
    digest: String,
    size: u64,
    created: Option<String>,
    architecture: String,
    os: String,
    layer_count: usize,
    #[serde(deserialize_with = "strings")]
    layers: Vec<String>,
    #[serde(default, deserialize_with = "strings")]
    entrypoint: Vec<String>,
    #[serde(default, deserialize_with = "strings")]
    cmd: Vec<String>,
    #[serde(default, deserialize_with = "strings")]
    env: Vec<String>,
    workdir: Option<String>,
    user: Option<String>,
}
/// An inert, bounded cached-image conversion request. Construction does not
/// authenticate a helper or attest that the image has actually been flattened.
#[derive(serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ContainerExportPlan {
    record_sha256: String,
    #[serde(deserialize_with = "flatten_request")]
    request: AgentRequest,
    #[serde(deserialize_with = "strings")]
    image_env: Vec<String>,
    image_user: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    imported_sha256: Option<String>,
}
impl std::fmt::Debug for ContainerExportPlan {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ContainerExportPlan")
            .finish_non_exhaustive()
    }
}
impl ContainerExportPlan {
    fn from_cached(
        record: &smolvm::config::VmRecord,
        bytes: &[u8],
        verified: &crate::VerifiedOci,
    ) -> Result<Self> {
        if bytes.is_empty() || bytes.len() > METADATA_BYTES {
            return Err(Error::before(ErrorCode::OutputLimit));
        }
        let cached: CachedImage =
            serde_json::from_slice(bytes).map_err(|_| Error::before(ErrorCode::Validation))?;
        Self::from_image(record, cached, verified)
    }
    pub(crate) fn from_image(
        record: &smolvm::config::VmRecord,
        cached: CachedImage,
        verified: &crate::VerifiedOci,
    ) -> Result<Self> {
        let image = registry_source(record)?;
        let metadata = verified.metadata();
        let text = |v: &str, max| v.len() <= max && !v.contains('\0');
        if verified.source().reference != image
            || verified.source().platform != crate::oci::native_oci_platform()
            || cached.reference != smolvm_protocol::normalize_image_ref(image)
            || cached.digest != metadata.digest
            || cached.os != "linux"
            || format!("{}/{}", cached.os, cached.architecture) != crate::oci::native_oci_platform()
            || cached.size > i64::MAX as u64
            || cached.layer_count == 0
            || cached.layer_count != cached.layers.len()
            || cached.layers != verified.layers()
            || cached.entrypoint != metadata.entrypoint
            || cached.cmd != metadata.cmd
            || cached.env != metadata.env
            || cached.workdir != metadata.workdir
            || cached.user != metadata.user
            || cached.created.as_ref().is_some_and(|v| !text(v, 128))
            || cached.env.iter().any(|v| {
                !text(v, 1024 * 1024)
                    || v.split_once('=')
                        .is_none_or(|(k, _)| k.is_empty() || k.len() > 16384)
            })
            || cached
                .entrypoint
                .iter()
                .chain(&cached.cmd)
                .any(|v| !text(v, 1024 * 1024))
            || cached
                .workdir
                .as_ref()
                .is_some_and(|v| !v.starts_with('/') || !text(v, 4096))
            || cached
                .user
                .as_ref()
                .is_some_and(|v| v.is_empty() || !text(v, 16384))
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let owner = smolvm::pack_export::export_overlay_owner(&record.name, record);
        if !crate::domain::valid_id(&owner) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        // Match the SDK collector and actual agent overlay implementation:
        // topmost first, despite the protocol field's older bottom-up comment.
        let mut lowerdirs = vec![format!(
            "/mnt/source-storage/overlays/persistent-{owner}/upper"
        )];
        lowerdirs.extend(
            cached
                .layers
                .iter()
                .rev()
                .map(|digest| format!("/storage/layers/{}", &digest[7..])),
        );
        let request = AgentRequest::FlattenLayers {
            lowerdirs,
            output: None,
        };
        if serde_json::to_vec(&request)
            .map_err(|_| Error::before(ErrorCode::Validation))?
            .len()
            > crate::AGENT_REQUEST_BYTES
        {
            return Err(Error::before(ErrorCode::OutputLimit));
        }
        Ok(Self {
            record_sha256: crate::material::hash(record)?,
            request,
            image_env: cached.env,
            image_user: cached.user,
            imported_sha256: None,
        })
    }
    pub(crate) fn validate(&self, record: &smolvm::config::VmRecord) -> Result<()> {
        if record.source_smolmachine.is_some() {
            if self
                .imported_sha256
                .as_ref()
                .is_none_or(|s| !crate::domain::valid_hex(s, 64))
                || !self.image_env.is_empty()
                || self.image_user.is_some()
            {
                return Err(Error::before(ErrorCode::Ownership));
            }
        } else {
            registry_source(record)?;
            if self.imported_sha256.is_some() {
                return Err(Error::before(ErrorCode::Ownership));
            }
        }
        crate::export_stream::validate(&self.request, crate::JOB_EXPORT_STAGING_BYTES)?;
        let AgentRequest::FlattenLayers { lowerdirs, .. } = &self.request else {
            return Err(Error::before(ErrorCode::Validation));
        };
        let expected_upper = format!(
            "/mnt/source-storage/overlays/persistent-{}/upper",
            smolvm::pack_export::export_overlay_owner(&record.name, record)
        );
        if self.record_sha256 != crate::material::hash(record)?
            || lowerdirs.first() != Some(&expected_upper)
            || lowerdirs.len() < 2
            || lowerdirs.iter().skip(1).any(|path| {
                !path.starts_with(if self.imported_sha256.is_some() {
                    "/storage/imported/layers/"
                } else {
                    "/storage/layers/"
                })
            })
            || serde_json::to_vec(&self.request)
                .map_err(|_| Error::before(ErrorCode::Validation))?
                .len()
                > crate::AGENT_REQUEST_BYTES
            || self.image_env.len() > STRINGS
            || self.image_env.iter().any(|v| {
                v.len() > 1024 * 1024
                    || v.contains('\0')
                    || v.split_once('=')
                        .is_none_or(|(k, _)| k.is_empty() || k.len() > 16384)
            })
            || self
                .image_user
                .as_ref()
                .is_some_and(|v| v.is_empty() || v.len() > 16384 || v.contains('\0'))
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
    pub(crate) fn from_imported(
        record: &smolvm::config::VmRecord,
        imported: &crate::export_import::Snapshot,
    ) -> Result<Self> {
        imported.validate(record)?;
        let owner = smolvm::pack_export::export_overlay_owner(&record.name, record);
        if !crate::domain::valid_id(&owner) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let mut lowerdirs = vec![format!(
            "/mnt/source-storage/overlays/persistent-{owner}/upper"
        )];
        lowerdirs.extend(
            imported
                .layers
                .iter()
                .rev()
                .map(|layer| format!("/storage/imported/layers/{}", &layer.digest[7..])),
        );
        let plan = Self {
            record_sha256: crate::material::hash(record)?,
            request: AgentRequest::FlattenLayers {
                lowerdirs,
                output: None,
            },
            image_env: Vec::new(),
            image_user: None,
            imported_sha256: Some(crate::material::hash(imported)?),
        };
        plan.validate(record)?;
        Ok(plan)
    }
    pub fn request(&self) -> &AgentRequest {
        &self.request
    }
    pub(crate) fn seed_manifest(
        &self,
        record: &smolvm::config::VmRecord,
        layer_bytes: u64,
    ) -> Result<smolvm_pack::format::PackManifest> {
        if layer_bytes == 0 || layer_bytes > crate::JOB_EXPORT_STAGING_BYTES {
            return Err(Error::before(ErrorCode::Validation));
        }
        self.validate(record)?;
        let mut manifest = smolvm_pack::format::PackManifest::new(
            record
                .image
                .clone()
                .ok_or(Error::before(ErrorCode::Unsupported))?,
            "none".into(),
            crate::oci::native_oci_platform().into(),
            smolvm::platform::Platform::current()
                .host_oci_platform()
                .into(),
        );
        smolvm::pack_export::seed_manifest_from_vm(
            &mut manifest,
            record,
            &smolvm::pack_export::FromVmAssets {
                mode: smolvm_pack::format::PackMode::Container,
                image: record.image.clone(),
                image_env: self.image_env.clone(),
                image_user: self.image_user.clone(),
                layer_bytes,
            },
        );
        manifest.cpus = record.cpus;
        manifest.mem = record.mem;
        if manifest
            .to_json()
            .map_err(|_| Error::before(ErrorCode::Validation))?
            .len()
            > crate::EXPORT_METADATA_BYTES as usize
        {
            return Err(Error::before(ErrorCode::OutputLimit));
        }
        Ok(manifest)
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::{Cancellation, ReadBudget};
    use std::os::unix::fs::FileExt;
    use std::time::Duration;

    fn budget() -> ReadBudget {
        ReadBudget::for_export_work(Duration::from_secs(30), Cancellation::default()).unwrap()
    }
    #[test]
    fn imported_source_prepares_funded_exact_plan_and_protected_scratch_without_sdk_cache_or_lifecycle(
    ) {
        let temp = tempfile::tempdir().unwrap();
        let (manifest, files) = crate::export_import::tests::payload();
        let bytes = crate::export_import::tests::sidecar(&manifest, &files);
        let (engine, receipt, _) = crate::export_import::tests::fixture(
            temp.path(),
            "registry-blobs",
            &bytes,
            &manifest.image,
        );
        let root = engine.vm_directory(&receipt.name);
        let disk = crate::disk_geometry::tests::raw(&root);
        std::fs::rename(disk, root.join(smolvm::storage::STORAGE_DISK_FILENAME)).unwrap();
        let intent = ContainerExportIntent {
            operation_id: "imported-export".into(),
            request_sha256: "e".repeat(64),
            request_identity_sha256: "f".repeat(64),
            max_artifact_bytes: 1 << 30,
            max_staging_bytes: 128 << 30,
        };
        engine
            .admit_export_intent(
                &receipt,
                &intent.operation_id,
                &intent.request_sha256,
                intent.max_staging_bytes,
                &intent.request_identity_sha256,
                &budget(),
            )
            .unwrap();
        let mut source = engine
            .qualify_export_source(&receipt, &budget())
            .unwrap()
            .prepare_container_export(&engine)
            .unwrap();
        let resources = crate::ExportConversionResources {
            slots: 1,
            cpus: 4,
            memory_mb: 4608,
            disk_gb: 128,
        };
        let funded = source
            .reserve_conversion(
                &engine,
                &resources,
                intent.max_artifact_bytes,
                intent.max_staging_bytes,
            )
            .unwrap();
        assert!(funded.imported.is_some() && funded.storage_gib > 1);
        let input = source.conversion_input(&engine).unwrap();
        let encoded = serde_json::to_value(&input).unwrap();
        assert!(encoded["imported"].is_object());
        let record = engine.db.get_vm(&receipt.name).unwrap().unwrap();
        let snapshot = source
            .imported
            .as_ref()
            .unwrap()
            .snapshot(source.source.budget())
            .unwrap();
        let plan = ContainerExportPlan::from_imported(&record, &snapshot).unwrap();
        source.verify_plan(&engine, &plan).unwrap();
        let output = source.container_manifest(&engine, &plan, 4096).unwrap();
        assert!(output
            .env
            .iter()
            .all(|entry| !entry.starts_with("BAKED_SECRET=")));
        assert!(output.env.contains(&"SECRET=private-env-value".into()));
        let mut changed = serde_json::to_value(&plan).unwrap();
        changed["imported_sha256"] = "a".repeat(64).into();
        let changed: ContainerExportPlan = serde_json::from_value(changed).unwrap();
        assert!(source.verify_plan(&engine, &changed).is_err());
        assert!(source.cached_query(&engine).is_err());
        let scratch = source
            .prepare_conversion_scratch(&engine, &resources, &intent)
            .unwrap();
        scratch.recheck(&engine).unwrap();
        assert_eq!(scratch.source.conversion.as_ref(), Some(&funded));
        // An enrolled empty root is not SDK-prepared storage or launch input.
        assert!(scratch
            .stage
            .prepared_helper_budget(&scratch.helper_root)
            .is_err());
        assert_eq!(
            scratch.verify_sdk_namespace(&engine).unwrap_err().code,
            ErrorCode::Ownership
        );
        scratch.close(&budget()).unwrap();
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
    }
    #[test]
    fn manager_rootfs_uses_only_explicit_package_directory_without_following_guest_init_link() {
        use std::os::unix::fs::{symlink, PermissionsExt};
        let temp = tempfile::tempdir().unwrap();
        let package = temp.path().canonicalize().unwrap();
        let library = package.join("lib");
        std::fs::create_dir(&library).unwrap();
        assert!(package_manager_rootfs(&library).is_err());
        let rootfs = package.join("agent-rootfs");
        std::fs::create_dir_all(rootfs.join("sbin")).unwrap();
        std::fs::set_permissions(&rootfs, std::fs::Permissions::from_mode(0o755)).unwrap();
        symlink("/guest-only/init", rootfs.join("sbin/init")).unwrap();
        assert_eq!(package_manager_rootfs(&library).unwrap(), rootfs);
        assert!(package_manager_rootfs(&package.join("other")).is_err());
        std::fs::rename(&rootfs, package.join("original-rootfs")).unwrap();
        symlink(package.join("original-rootfs"), &rootfs).unwrap();
        assert!(package_manager_rootfs(&library).is_err());
    }
    fn scratch_fixture() -> (
        tempfile::TempDir,
        Engine,
        crate::CreationReceipt,
        ContainerExportIntent,
        ContainerExportScratch,
    ) {
        let temp = tempfile::tempdir().unwrap();
        let (engine, receipt) = crate::export_source::tests::fixture(temp.path(), true);
        let root = engine.vm_directory(&receipt.name);
        let disk = crate::disk_geometry::tests::raw(&root);
        std::fs::rename(disk, root.join(smolvm::storage::STORAGE_DISK_FILENAME)).unwrap();
        let intent = ContainerExportIntent {
            operation_id: "container-export".into(),
            request_sha256: "e".repeat(64),
            request_identity_sha256: "f".repeat(64),
            max_artifact_bytes: 1 << 30,
            max_staging_bytes: 128 << 30,
        };
        engine
            .admit_export_intent(
                &receipt,
                &intent.operation_id,
                &intent.request_sha256,
                intent.max_staging_bytes,
                &intent.request_identity_sha256,
                &budget(),
            )
            .unwrap();
        let prepared = engine
            .qualify_export_source(&receipt, &budget())
            .unwrap()
            .prepare_container_export(&engine)
            .unwrap();
        let resources = crate::ExportConversionResources {
            slots: 1,
            cpus: 4,
            memory_mb: 4608,
            disk_gb: 128,
        };
        let scratch = prepared
            .prepare_conversion_scratch(&engine, &resources, &intent)
            .unwrap();
        (temp, engine, receipt, intent, scratch)
    }
    pub(crate) fn initialized_fixture() -> (
        tempfile::TempDir,
        Engine,
        crate::CreationReceipt,
        ContainerExportIntent,
        InitializedContainerStorage,
    ) {
        initialized_fixture_with_cow(false, true)
    }
    fn initialized_fixture_with_cow(
        cow: bool,
        complete_name: bool,
    ) -> (
        tempfile::TempDir,
        Engine,
        crate::CreationReceipt,
        ContainerExportIntent,
        InitializedContainerStorage,
    ) {
        initialized_fixture_with_markers(cow, complete_name, true)
    }
    fn initialized_fixture_with_markers(
        cow: bool,
        complete_name: bool,
        formatted: bool,
    ) -> (
        tempfile::TempDir,
        Engine,
        crate::CreationReceipt,
        ContainerExportIntent,
        InitializedContainerStorage,
    ) {
        let (temp, engine, receipt, intent, mut scratch) = scratch_fixture();
        let (name, path) = scratch
            .stage
            .begin_helper_sdk(&scratch.helper_root)
            .unwrap();
        // Storage-only private model. SDK global namespace/library/COW entry is
        // intentionally not invoked through a database-only fixture.
        std::fs::write(
            path.join("name"),
            if complete_name {
                name.as_bytes()
            } else {
                &name.as_bytes()[..name.len() - 1]
            },
        )
        .unwrap();
        let storage =
            smolvm::storage::StorageDisk::open_or_create_at(&path.join("storage.raw"), 1).unwrap();
        let overlay =
            smolvm::storage::OverlayDisk::open_or_create_at(&path.join("overlay.raw"), 1).unwrap();
        // Inert model of completed SDK formatting, never used to enter SDK
        // lifecycle through this database-only fixture.
        if formatted {
            for marker in ["storage.formatted", "overlay.formatted"] {
                std::fs::write(path.join(marker), b"1").unwrap();
            }
        }
        if cow {
            let view = crate::disk_geometry::tests::qcow(&path, 3);
            let (source, format) = scratch.source.storage.sdk_source();
            crate::disk_geometry::tests::link_backing(
                &view,
                source.to_str().unwrap(),
                Some(format),
                true,
            );
            std::fs::rename(view, path.join("export-source.qcow2")).unwrap();
        }
        scratch
            .stage
            .collect_helper_sdk(&scratch.helper_root)
            .unwrap();
        (
            temp,
            engine,
            receipt,
            intent,
            InitializedContainerStorage {
                storage,
                overlay,
                scratch,
            },
        )
    }
    #[test]
    fn legacy_unformatted_storage_is_cleanable_but_cannot_supply_conversion_launch_inputs() {
        let (_temp, engine, _source, _intent, storage) =
            initialized_fixture_with_markers(true, true, false);
        storage.recheck(&engine).unwrap();
        assert!(storage
            .scratch
            .stage
            .prepared_helper_budget(&storage.scratch.helper_root)
            .is_ok());
        assert_eq!(
            ConversionLaunchInputs::capture(&storage)
                .err()
                .unwrap()
                .code,
            ErrorCode::Ownership
        );
        storage.close(&budget()).unwrap();
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
    }
    #[test]
    fn conversion_launch_inputs_bind_protected_budget_and_private_cow_without_launch() {
        let (_temp, engine, _source, _intent, storage) = initialized_fixture_with_cow(true, true);
        let mut launch = ConversionLaunchInputs::capture(&storage).unwrap();
        let (resources, features) = launch.sdk_config(&storage).unwrap();
        assert_eq!(resources, launch.plan.vm_resources());
        assert_eq!(resources.storage_gib, Some(1));
        assert_eq!(resources.overlay_gib, Some(1));
        assert!(!resources.network && !resources.gpu && !resources.cuda);
        let (_, path) = storage
            .scratch
            .stage
            .prepared_helper_identity(&storage.scratch.helper_root)
            .unwrap();
        assert_eq!(
            features.extra_disks,
            vec![(
                path.join("export-source.qcow2"),
                false,
                smolvm::data::disk::DiskFormat::Qcow2
            )]
        );
        assert_eq!(
            features.uid_share_dir.as_deref(),
            Some(storage.scratch.source.source.directory())
        );
        assert!(features.packed_layers_dir.is_none() && features.pack_idmap_source.is_none());
        assert!(features.credentials.is_none() && features.external_interceptor.is_none());
        assert!(features.pod_netns.is_none() && features.snapshot_dir.is_none());
        assert!(!features.cuda && !features.forkable && !features.expose_docker);
        assert!(!path.join("agent.pid").exists());
        let charged = engine.jobs.counts();
        launch.plan.memory_mib += 1;
        assert!(launch.sdk_config(&storage).is_err());
        assert_eq!(charged, engine.jobs.counts());
        storage.recheck(&engine).unwrap();
    }
    #[test]
    fn partial_collected_sdk_storage_is_cleanable_but_cannot_prepare_launch_inputs() {
        for (cow, complete_name) in [(false, true), (true, false)] {
            let (_temp, engine, source, intent, storage) =
                initialized_fixture_with_cow(cow, complete_name);
            assert!(ConversionLaunchInputs::capture(&storage).is_err());
            let retained = engine.export_retention.insert(storage).unwrap();
            retained.recheck(&engine, &budget()).unwrap();
            drop(retained);
            engine
                .cleanup_export_staging(
                    &source,
                    &intent.operation_id,
                    &intent.request_sha256,
                    true,
                    &budget(),
                )
                .unwrap();
            assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
        }
    }
    #[test]
    fn engine_retention_survives_caller_retirement_and_releases_only_explicit_exact_cleanup() {
        let (_temp, engine, source, intent, storage) = initialized_fixture();
        let (_, path) = storage
            .scratch
            .stage
            .prepared_helper_identity(&storage.scratch.helper_root)
            .unwrap();
        let retained = engine.export_retention.insert(storage).unwrap();
        retained.recheck(&engine, &budget()).unwrap();
        let charged = engine.jobs.counts();
        assert_eq!(
            (charged.work, charged.children, charged.work_descriptors),
            (1, 2, 24)
        );
        assert!(engine
            .cleanup_export_staging(
                &source,
                &intent.operation_id,
                &intent.request_sha256,
                true,
                &budget()
            )
            .is_err());
        drop(retained);
        assert_eq!(charged, engine.jobs.counts());
        assert!(engine.qualify_export_source(&source, &budget()).is_err());
        assert!(engine
            .cleanup_export_staging(
                &source,
                &intent.operation_id,
                &"0".repeat(64),
                true,
                &budget()
            )
            .is_err());
        assert!(engine
            .cleanup_export_staging(
                &source,
                &intent.operation_id,
                &intent.request_sha256,
                false,
                &budget()
            )
            .is_err());
        assert_eq!(charged, engine.jobs.counts());
        let proof = engine
            .cleanup_export_staging(
                &source,
                &intent.operation_id,
                &intent.request_sha256,
                true,
                &budget(),
            )
            .unwrap();
        assert!(!path.exists());
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
        assert_eq!(
            proof,
            engine
                .cleanup_export_staging(
                    &source,
                    &intent.operation_id,
                    &intent.request_sha256,
                    true,
                    &budget()
                )
                .unwrap()
        );
    }
    #[test]
    fn failed_or_cancelled_retained_cleanup_keeps_source_capacity_under_quarantine() {
        let (_temp, engine, source, intent, storage) = initialized_fixture();
        let (_, path) = storage
            .scratch
            .stage
            .prepared_helper_identity(&storage.scratch.helper_root)
            .unwrap();
        let retained = engine.export_retention.insert(storage).unwrap();
        drop(retained);
        let charged = engine.jobs.counts();
        let cancel = Cancellation::default();
        cancel.cancel();
        let cancelled = ReadBudget::new(Duration::from_secs(1), cancel).unwrap();
        assert!(engine
            .cleanup_export_staging(
                &source,
                &intent.operation_id,
                &intent.request_sha256,
                true,
                &cancelled
            )
            .is_err());
        engine.jobs.quarantine();
        std::fs::write(path.join("foreign"), b"keep").unwrap();
        assert!(engine
            .cleanup_export_staging(
                &source,
                &intent.operation_id,
                &intent.request_sha256,
                true,
                &budget()
            )
            .is_err());
        assert_eq!(charged, engine.jobs.counts());
        assert_eq!(std::fs::read(path.join("foreign")).unwrap(), b"keep");
        assert!(!engine.available());
    }
    #[test]
    fn retained_observation_token_is_bound_to_the_original_registry_instance() {
        let (_temp, engine, _source, _intent, storage) = initialized_fixture();
        let retained = engine.export_retention.insert(storage).unwrap();
        let other = tempfile::tempdir().unwrap();
        let (foreign, _) = crate::export_source::tests::fixture(other.path(), true);
        assert!(retained.recheck(&foreign, &budget()).is_err());
        retained.recheck(&engine, &budget()).unwrap();
        assert!(!format!("{retained:?}").contains("owner_token"));
    }
    #[test]
    fn initialized_storage_cannot_be_retained_in_another_owner_domain() {
        let (_temp, engine, _source, _intent, storage) = initialized_fixture();
        let other = tempfile::tempdir().unwrap();
        let (foreign, _) = crate::export_source::tests::fixture(other.path(), true);
        assert!(foreign.export_retention.insert(storage).is_err());
        assert_eq!(foreign.jobs.counts(), crate::jobs::Counts::default());
        assert_eq!(engine.jobs.counts().export_staging, 128 << 30);
    }
    #[test]
    fn manager_preparation_rejects_unbound_sdk_namespace_without_releasing_retained_storage() {
        let (_temp, engine, source, intent, storage) = initialized_fixture();
        let (_, path) = storage
            .scratch
            .stage
            .prepared_helper_identity(&storage.scratch.helper_root)
            .unwrap();
        let retained = engine.export_retention.insert(storage).unwrap();
        let charged = engine.jobs.counts();
        assert_eq!(
            retained
                .prepare_manager(&engine, &budget())
                .unwrap_err()
                .code,
            ErrorCode::Ownership
        );
        retained.recheck(&engine, &budget()).unwrap();
        assert_eq!(charged, engine.jobs.counts());
        assert!(!path.join("agent.pid").exists());
        assert_eq!(
            retained.start_manager(&engine).unwrap_err().code,
            ErrorCode::Ownership
        );
        assert_eq!(charged, engine.jobs.counts());
        assert!(!path.join("agent.pid").exists());
        drop(retained);
        engine
            .cleanup_export_staging(
                &source,
                &intent.operation_id,
                &intent.request_sha256,
                true,
                &budget(),
            )
            .unwrap();
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
    }
    #[test]
    fn normal_engine_replacement_never_adopts_a_retired_registry_token() {
        let (temp, engine, source, intent, storage) = initialized_fixture();
        let retained = engine.export_retention.insert(storage).unwrap();
        drop(engine);
        let reopened = crate::machine::tests::test_engine(temp.path());
        assert!(retained.recheck(&reopened, &budget()).is_err());
        assert!(!reopened.available());
        assert_eq!(reopened.jobs.counts().export_staging, 128 << 30);
        reopened
            .cleanup_export_staging(
                &source,
                &intent.operation_id,
                &intent.request_sha256,
                true,
                &budget(),
            )
            .unwrap();
        assert_eq!(reopened.jobs.counts().export_staging, 0);
        assert!(!reopened.available());
    }
    #[test]
    fn prelaunch_scratch_is_private_retained_exact_and_never_sdk_cache_authority() {
        let (_temp, engine, receipt, intent, scratch) = scratch_fixture();
        scratch.recheck(&engine).unwrap();
        assert!(scratch.verify_sdk_namespace(&engine).is_err());
        let (_name, path) = scratch.stage.helper_identity(&scratch.helper_root).unwrap();
        assert!(path.starts_with(&engine.binding().vm_root));
        assert!(std::fs::read_dir(&path).unwrap().next().is_none());
        assert_eq!(engine.jobs.counts().export_staging, 128 << 30);
        assert_eq!(engine.jobs.counts().children, 2);
        assert!(engine
            .cleanup_export_staging(
                &receipt,
                &intent.operation_id,
                &intent.request_sha256,
                true,
                &budget()
            )
            .is_err());
        let proof = scratch.close(&budget()).unwrap();
        assert!(!path.exists());
        assert_eq!(engine.jobs.counts().export_staging, 0);
        assert_eq!(engine.jobs.counts().children, 0);
        assert_eq!(
            proof,
            engine
                .cleanup_export_staging(
                    &receipt,
                    &intent.operation_id,
                    &intent.request_sha256,
                    true,
                    &budget()
                )
                .unwrap()
        );
        assert!(engine.vm_directory(&receipt.name).exists());
        assert!(engine
            .inspect_export_publication(
                &receipt,
                &intent.operation_id,
                &intent.request_sha256,
                &budget()
            )
            .unwrap()
            .is_none());
    }
    #[test]
    fn database_only_fixture_cannot_enter_sdk_storage_initialization() {
        let (_temp, engine, receipt, intent, scratch) = scratch_fixture();
        let (_, path) = scratch.stage.helper_identity(&scratch.helper_root).unwrap();
        let error = scratch.initialize_sdk_storage(&engine).unwrap_err();
        assert_eq!(error.code, ErrorCode::Ownership);
        assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
        assert!(std::fs::read_dir(&path).unwrap().next().is_none());
        engine
            .cleanup_export_staging(
                &receipt,
                &intent.operation_id,
                &intent.request_sha256,
                true,
                &budget(),
            )
            .unwrap();
        assert!(!path.exists());
    }
    #[test]
    fn private_source_removal_and_normal_replacement_retire_prelaunch_scratch_without_replay() {
        let (temp, engine, receipt, intent, scratch) = scratch_fixture();
        let (_, path) = scratch.stage.helper_identity(&scratch.helper_root).unwrap();
        drop(scratch);
        engine.db.remove_vm(&receipt.name).unwrap();
        std::fs::remove_dir_all(engine.vm_directory(&receipt.name)).unwrap();
        drop(engine);
        let reopened = crate::machine::tests::test_engine(temp.path());
        assert!(!reopened.available());
        assert_eq!(reopened.jobs.counts().export_staging, 128 << 30);
        let proof = reopened
            .cleanup_export_staging(
                &receipt,
                &intent.operation_id,
                &intent.request_sha256,
                true,
                &budget(),
            )
            .unwrap();
        assert!(!path.exists());
        assert_eq!(reopened.jobs.counts().export_staging, 0);
        assert!(!reopened.available());
        assert_eq!(
            proof,
            reopened
                .cleanup_export_staging(
                    &receipt,
                    &intent.operation_id,
                    &intent.request_sha256,
                    true,
                    &budget()
                )
                .unwrap()
        );
        assert!(reopened
            .check_export_intent(
                &receipt,
                &intent.operation_id,
                &intent.request_sha256,
                intent.max_staging_bytes,
                &intent.request_identity_sha256,
                &budget()
            )
            .is_err());
    }
    #[test]
    fn foreign_prelaunch_payload_or_substituted_root_is_preserved_with_capacity() {
        for replace in [false, true] {
            let (_temp, engine, _receipt, _intent, scratch) = scratch_fixture();
            let (_, path) = scratch.stage.helper_identity(&scratch.helper_root).unwrap();
            if replace {
                let original = path.with_extension("original");
                std::fs::rename(&path, original).unwrap();
                std::fs::create_dir(&path).unwrap();
                std::fs::set_permissions(
                    &path,
                    std::os::unix::fs::PermissionsExt::from_mode(0o700),
                )
                .unwrap();
            }
            std::fs::write(path.join("foreign"), b"keep").unwrap();
            assert!(scratch.recheck(&engine).is_err());
            assert!(scratch.close(&budget()).is_err());
            assert_eq!(std::fs::read(path.join("foreign")).unwrap(), b"keep");
            assert_eq!(engine.jobs.counts().export_staging, 128 << 30);
        }
    }
    #[test]
    fn conversion_grant_is_frozen_and_reserved_inside_the_original_source_job() {
        let temp = tempfile::tempdir().unwrap();
        let (engine, receipt) = crate::export_source::tests::fixture(temp.path(), true);
        let root = engine.vm_directory(&receipt.name);
        let disk = crate::disk_geometry::tests::raw(&root);
        std::fs::rename(disk, root.join(smolvm::storage::STORAGE_DISK_FILENAME)).unwrap();
        let mut prepared = engine
            .qualify_export_source(&receipt, &budget())
            .unwrap()
            .prepare_container_export(&engine)
            .unwrap();
        let grant = crate::ExportConversionResources {
            slots: 1,
            cpus: 4,
            memory_mb: 4608,
            disk_gb: 128,
        };
        let before = engine.jobs.counts();
        assert!(prepared.conversion_input(&engine).is_err());
        assert!(prepared
            .reserve_conversion(&engine, &grant, 123 << 30, 128 << 30)
            .is_err());
        assert_eq!(before, engine.jobs.counts());
        let plan = prepared
            .reserve_conversion(&engine, &grant, 30 << 30, 128 << 30)
            .unwrap();
        assert_eq!(plan.max_flattened_bytes, 93 << 30);
        let input = prepared.conversion_input(&engine).unwrap();
        assert_eq!(
            serde_json::to_value(input).unwrap()["maximum"],
            plan.max_flattened_bytes
        );
        let retained = engine.jobs.counts();
        assert_eq!(
            (retained.work, retained.children, retained.work_descriptors),
            (1, 2, 24)
        );
        assert_eq!(retained.export_staging, 0);
        assert_eq!(
            plan,
            prepared
                .reserve_conversion(&engine, &grant, 30 << 30, 128 << 30)
                .unwrap()
        );
        let mut changed = grant;
        changed.memory_mb = 2048;
        assert!(prepared
            .reserve_conversion(&engine, &changed, 30 << 30, 128 << 30)
            .is_err());
        assert_eq!(retained, engine.jobs.counts());
        drop(prepared);
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
    }
    pub(crate) fn record() -> smolvm::config::VmRecord {
        let mut record =
            smolvm::config::VmRecord::new("source".into(), 2, 512, vec![], vec![], false);
        record.image = Some(oci_fixture().0.source().reference.clone());
        record.env = vec![("PATH".into(), "/custom".into())];
        record.workdir = Some("/work".into());
        record
    }
    fn cached(record: &smolvm::config::VmRecord) -> serde_json::Value {
        let mut cached = serde_json::to_value(oci_fixture().3).unwrap();
        cached["reference"] = serde_json::json!(record.image);
        cached
    }
    pub(crate) fn oci_fixture() -> (
        crate::VerifiedOci,
        Vec<u8>,
        Vec<u8>,
        smolvm_protocol::ImageInfo,
    ) {
        use sha2::{Digest, Sha256};
        let platform = crate::oci::native_oci_platform();
        let architecture = platform.trim_start_matches("linux/");
        let config = serde_json::to_vec(&serde_json::json!({
            "architecture": architecture, "os": "linux", "config": {
                "Entrypoint": ["/image-entry"], "Cmd": ["image-command"],
                "Env": ["PATH=/image", "IMAGE_ONLY=private-env-value"],
                "WorkingDir": "/image-work", "User": "1000"
            }
        }))
        .unwrap();
        let digest = format!("sha256:{}", hex::encode(Sha256::digest(&config)));
        let layers = ['a', 'b'].map(|c| format!("sha256:{}", c.to_string().repeat(64)));
        let manifest = serde_json::to_vec(&serde_json::json!({
            "schemaVersion": 2,
            "config": {"mediaType": "application/vnd.oci.image.config.v1+json", "digest": digest, "size": config.len()},
            "layers": layers.iter().map(|digest| serde_json::json!({
                "mediaType": "application/vnd.oci.image.layer.v1.tar+gzip", "digest": digest, "size": 1
            })).collect::<Vec<_>>()
        })).unwrap();
        let source = crate::ImagePullRequest {
            reference: format!(
                "registry.example/team/app@sha256:{}",
                hex::encode(Sha256::digest(&manifest))
            ),
            platform: platform.into(),
        };
        let cached = smolvm_protocol::ImageInfo {
            reference: source.reference.clone(),
            digest,
            size: 10,
            created: None,
            architecture: architecture.into(),
            os: "linux".into(),
            layer_count: layers.len(),
            layers: layers.to_vec(),
            entrypoint: vec!["/image-entry".into()],
            cmd: vec!["image-command".into()],
            env: vec!["PATH=/image".into(), "IMAGE_ONLY=private-env-value".into()],
            workdir: Some("/image-work".into()),
            user: Some("1000".into()),
        };
        let verified = crate::VerifiedOci::verify(source, &manifest, &config).unwrap();
        (verified, manifest, config, cached)
    }
    #[test]
    fn decoded_plan_rejects_other_requests_extra_fields_and_sequence_growth_before_sdk_decode() {
        let record = record();
        let original = plan(&record);
        let value = serde_json::to_value(&original).unwrap();
        let decoded: ContainerExportPlan = serde_json::from_value(value.clone()).unwrap();
        decoded.validate(&record).unwrap();
        let mut changed = value.clone();
        changed["request"] = serde_json::json!({"method":"vm_exec","command":["sh"]});
        assert!(serde_json::from_value::<ContainerExportPlan>(changed).is_err());
        let mut changed = value.clone();
        changed["request"]["output"] = "/tmp/guest.tar".into();
        assert!(serde_json::from_value::<ContainerExportPlan>(changed).is_err());
        let mut changed = value.clone();
        changed["request"]["foreign"] = true.into();
        assert!(serde_json::from_value::<ContainerExportPlan>(changed).is_err());
        let mut changed = value.clone();
        changed["request"]["lowerdirs"] = serde_json::json!(vec![""; STRINGS + 2]);
        assert!(serde_json::from_value::<ContainerExportPlan>(changed).is_err());
        let mut changed = value;
        changed["image_env"] = serde_json::json!(vec![""; STRINGS + 1]);
        assert!(serde_json::from_value::<ContainerExportPlan>(changed).is_err());
    }
    pub(crate) fn plan(record: &smolvm::config::VmRecord) -> ContainerExportPlan {
        ContainerExportPlan::from_cached(
            record,
            &serde_json::to_vec(&cached(record)).unwrap(),
            &oci_fixture().0,
        )
        .unwrap()
    }

    #[test]
    fn conversion_preserves_actual_agent_precedence_and_sdk_runtime_metadata_without_rebase() {
        let mut record = record();
        record.fork_overlay_owner = Some("ancestor".into());
        let plan = plan(&record);
        let AgentRequest::FlattenLayers { lowerdirs, output } = plan.request() else {
            panic!("wrong conversion operation")
        };
        assert_eq!(
            lowerdirs,
            &vec![
                "/mnt/source-storage/overlays/persistent-ancestor/upper".to_string(),
                format!("/storage/layers/{}", "b".repeat(64)),
                format!("/storage/layers/{}", "a".repeat(64)),
            ]
        );
        assert!(output.is_none());
        let manifest = plan.seed_manifest(&record, 4096).unwrap();
        assert!(matches!(
            manifest.mode,
            smolvm_pack::format::PackMode::Container
        ));
        assert_eq!(manifest.image, record.image.clone().unwrap());
        assert_eq!(manifest.image_size, 4096);
        assert_eq!(
            manifest.env,
            vec!["IMAGE_ONLY=private-env-value", "PATH=/custom"]
        );
        assert_eq!(manifest.user.as_deref(), Some("1000"));
        assert_eq!(manifest.workdir, record.workdir);
        assert!(manifest.entrypoint.is_empty() && manifest.cmd.is_empty());
        assert_eq!(manifest.cpus, 2);
        record.user = Some("2000".into());
        assert!(plan.seed_manifest(&record, 4096).is_err());
        let updated = self::plan(&record);
        assert_eq!(
            updated
                .seed_manifest(&record, 4096)
                .unwrap()
                .user
                .as_deref(),
            Some("2000")
        );
        assert!(!format!("{plan:?}").contains("private-env-value"));
        assert!(plan.seed_manifest(&record, 0).is_err());
        assert!(plan
            .seed_manifest(&record, crate::JOB_EXPORT_STAGING_BYTES + 1)
            .is_err());
    }

    #[test]
    fn cached_metadata_cannot_substitute_image_platform_layers_paths_or_unbounded_arrays() {
        let record = record();
        let verified = oci_fixture().0;
        for (key, value) in [
            ("reference", serde_json::json!("registry.example/foreign")),
            (
                "digest",
                serde_json::json!(format!("sha256:{}", "e".repeat(64))),
            ),
            ("os", serde_json::json!("foreign")),
            ("architecture", serde_json::json!("foreign")),
            ("layer_count", serde_json::json!(0)),
            ("layers", serde_json::json!(["../../foreign", "sha256:bad"])),
            ("env", serde_json::json!(["=bad"])),
            ("user", serde_json::json!("")),
            ("path", serde_json::json!("/host/not-a-grant")),
        ] {
            let mut bad = cached(&record);
            bad[key] = value;
            assert!(
                ContainerExportPlan::from_cached(
                    &record,
                    &serde_json::to_vec(&bad).unwrap(),
                    &verified
                )
                .is_err(),
                "{key}"
            );
        }
        let mut bad = cached(&record);
        bad["cmd"] = serde_json::json!(vec![""; STRINGS + 1]);
        assert!(ContainerExportPlan::from_cached(
            &record,
            &serde_json::to_vec(&bad).unwrap(),
            &verified
        )
        .is_err());
        assert!(ContainerExportPlan::from_cached(
            &record,
            &vec![b' '; METADATA_BYTES + 1],
            &verified
        )
        .is_err());
        let mut imported = record.clone();
        imported.source_smolmachine = Some("/unproved.smolmachine".into());
        assert!(registry_source(&imported).is_err());
        let mut local = record;
        local.image = Some(format!("local:{}", "a".repeat(64)));
        assert!(registry_source(&local).is_err());
    }

    #[test]
    fn container_storage_is_receipt_bound_readonly_and_keeps_gate_budget_and_source_identity() {
        let temp = tempfile::tempdir().unwrap();
        let verified = oci_fixture().0;
        let (engine, receipt) =
            crate::export_source::tests::fixture_record(temp.path(), true, |row| {
                row.image = Some(verified.source().reference.clone());
            });
        let root = engine.vm_directory(&receipt.name);
        let disk = crate::disk_geometry::tests::raw(&root);
        std::fs::rename(disk, root.join(smolvm::storage::STORAGE_DISK_FILENAME)).unwrap();
        let before = serde_json::to_vec(&engine.db.get_vm(&receipt.name).unwrap()).unwrap();
        let prepared = engine
            .qualify_export_source(&receipt, &budget())
            .unwrap()
            .prepare_container_export(&engine)
            .unwrap();
        assert_eq!(prepared.storage_bytes(), 1 << 30);
        assert_eq!(engine.jobs.counts().work, 1);
        assert_eq!(engine.jobs.counts().export_staging, 0);
        assert!(engine.qualify_export_source(&receipt, &budget()).is_err());
        let mut bytes = [0; 2];
        prepared.read_storage_at(1080, &mut bytes).unwrap();
        assert_eq!(bytes, 0xef53u16.to_le_bytes());
        let record = engine.db.get_vm(&receipt.name).unwrap().unwrap();
        assert!(
            matches!(prepared.cached_query(&engine).unwrap(), AgentRequest::Query { image } if Some(image.as_str()) == record.image.as_deref())
        );
        let mut plan = prepared
            .conversion_plan(
                &engine,
                &serde_json::to_vec(&cached(&record)).unwrap(),
                &verified,
            )
            .unwrap();
        prepared.container_manifest(&engine, &plan, 4096).unwrap();
        plan.record_sha256 = "0".repeat(64);
        assert!(prepared.container_manifest(&engine, &plan, 4096).is_err());
        assert_eq!(
            before,
            serde_json::to_vec(&engine.db.get_vm(&receipt.name).unwrap()).unwrap()
        );
        let file = std::fs::OpenOptions::new()
            .write(true)
            .open(root.join(smolvm::storage::STORAGE_DISK_FILENAME))
            .unwrap();
        file.write_all_at(b"changed", 0).unwrap();
        assert!(prepared.recheck(&engine).is_err());
        drop(prepared);
        assert_eq!(engine.jobs.counts().work, 0);
    }

    #[test]
    fn prepared_container_source_never_survives_cancellation_or_owner_substitution() {
        let temp = tempfile::tempdir().unwrap();
        let (engine, receipt) = crate::export_source::tests::fixture(temp.path(), true);
        let root = engine.vm_directory(&receipt.name);
        let disk = crate::disk_geometry::tests::raw(&root);
        std::fs::rename(disk, root.join(smolvm::storage::STORAGE_DISK_FILENAME)).unwrap();
        let cancel = Cancellation::default();
        let budget = ReadBudget::for_export_work(Duration::from_secs(30), cancel.clone()).unwrap();
        let prepared = engine
            .qualify_export_source(&receipt, &budget)
            .unwrap()
            .prepare_container_export(&engine)
            .unwrap();
        let other = tempfile::tempdir().unwrap();
        let (foreign, _) = crate::export_source::tests::fixture(other.path(), true);
        assert!(prepared.recheck(&foreign).is_err());
        cancel.cancel();
        assert!(prepared.cached_query(&engine).is_err());
        assert!(prepared.read_storage_at(0, &mut [0]).is_err());
        assert_eq!(engine.jobs.counts().work, 1);
        drop(prepared);
        assert_eq!(engine.jobs.counts().work, 0);
    }
}
