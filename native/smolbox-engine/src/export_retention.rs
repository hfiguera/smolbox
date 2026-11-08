//! Engine-owned conversion storage and managers. Retiring a caller never
//! releases executing source/job leases or turns launch return into collection.
use crate::{
    CreationReceipt, Engine, Error, ErrorCode, ExportStageCleanup, InitializedContainerStorage,
    ReadBudget, Result,
};
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex, Weak};

type Identity = (CreationReceipt, String, String);
struct Entry {
    identity: Identity,
    borrower: Weak<()>,
    work: Mutex<Work>,
}
struct Work {
    storage: InitializedContainerStorage,
    manager: Option<crate::export_container::PreparedConversionManager>,
    conversion_entered: bool,
    conversion_worker: Weak<()>,
    converted_plan: Option<crate::ContainerExportPlan>,
}
pub(crate) struct Registry {
    entries: Mutex<BTreeMap<String, Arc<Entry>>>,
    domain: Arc<crate::domain::DomainGuard>,
}
/// Opaque token for the original retained conversion. It exposes no raw manager,
/// PID or caller-selected paths. Drop retires only this caller; conversion state
/// and leases stay in the engine-owned registry.
pub struct RetainedConversionStorage {
    registry: Weak<Registry>,
    key: String,
    borrower: Arc<()>,
}
/// Independently verified spools from a collected original worker. Retains the
/// source and helper leases; supplies no staging registration/publication proof.
pub struct CollectedContainerConversion {
    collected: Box<crate::transfer_supervisor::Collected>,
    plan: crate::ContainerExportPlan,
    layer: crate::ContainerLayerIo,
    version: crate::checkpoint_materialize::FileVersion,
    budget: ReadBudget,
    entry: Weak<Entry>,
}
impl CollectedContainerConversion {
    pub(crate) fn staging_source(
        &mut self,
    ) -> Result<(
        &mut crate::transfer_supervisor::Spool,
        crate::export_bootstrap::Proof,
        ReadBudget,
    )> {
        self.budget.check()?;
        let (_, _, version) = self.collected.verify_conversion(&self.budget)?;
        if version != self.version {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let proof = self
            .collected
            .converted
            .as_ref()
            .ok_or(Error::before(ErrorCode::Ownership))?
            .clone();
        Ok((
            &mut self.collected.prepared.spool,
            proof,
            self.budget.clone(),
        ))
    }
    pub fn plan(&self) -> &crate::ContainerExportPlan {
        &self.plan
    }
    pub fn layer(&self) -> &crate::ContainerLayerIo {
        &self.layer
    }
    /// Bounded positional access; no caller-selected file or guest path.
    pub fn read_layer_at(
        &self,
        offset: u64,
        output: &mut [u8],
        budget: &ReadBudget,
    ) -> Result<usize> {
        use std::os::unix::fs::{FileExt, MetadataExt};
        self.budget.check()?;
        budget.check()?;
        if output.len() as u64 > crate::transfer_worker::CHUNK || offset > self.layer.bytes {
            return Err(Error::before(ErrorCode::Validation));
        }
        self.collected.prepared.spool.verify()?;
        let file = &self.collected.prepared.spool.file;
        let info = file
            .metadata()
            .map_err(|_| Error::uncertain(ErrorCode::Io))?;
        if crate::checkpoint_materialize::FileVersion::of(&info) != self.version
            || info.len() != self.layer.bytes
            || info.nlink() != 1
            || info.mode() & 0o777 != 0o600
        {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        let limit = output
            .len()
            .min((self.layer.bytes - offset).min(crate::transfer_worker::CHUNK) as usize);
        let count = file
            .read_at(&mut output[..limit], offset)
            .map_err(|_| Error::uncertain(ErrorCode::Io))?;
        let after = file
            .metadata()
            .map_err(|_| Error::uncertain(ErrorCode::Io))?;
        self.collected.prepared.spool.verify()?;
        if crate::checkpoint_materialize::FileVersion::of(&after) != self.version {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        self.budget.check().map_err(|e| Error::uncertain(e.code))?;
        budget.check().map_err(|e| Error::uncertain(e.code))?;
        Ok(count)
    }
}
/// Retains original source, domain and stage through forwarding even when the
/// Engine value is dropped. A fresh engine cannot adopt this entry.
pub(crate) struct PackedConversion {
    token: RetainedConversionStorage,
    entry: Arc<Entry>,
}
impl PackedConversion {
    pub(crate) fn recheck(&self, engine: &Engine) -> Result<()> {
        if !Arc::ptr_eq(&self.token.entry(engine)?, &self.entry) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        self.entry
            .work
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?
            .storage
            .recheck_packed(engine)
    }
    pub(crate) fn read_at(&self, offset: u64, output: &mut [u8]) -> Result<()> {
        self.entry
            .work
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?
            .storage
            .read_artifact(offset, output)
    }
    pub(crate) fn publish(
        &mut self,
        engine: &Engine,
        artifact: &crate::ExportStagedFile,
        destination: &crate::ApprovedExportDestination,
        tag: &str,
        credential: &crate::RegistryPublishCredential,
    ) -> Result<crate::ExportPublication> {
        self.recheck(engine)?;
        self.entry
            .work
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?
            .storage
            .publish_container(engine, artifact, destination, tag, credential)
    }
    pub(crate) fn close(self, budget: &ReadBudget) -> Result<ExportStageCleanup> {
        let Self { token, entry } = self;
        let registry = token.registry.upgrade();
        drop(token);
        if let Some(registry) = registry {
            let (source, operation, request) = &entry.identity;
            registry
                .cleanup(source, operation, request, budget)
                .ok_or(Error::before(ErrorCode::Ownership))?
        } else {
            entry
                .work
                .try_lock()
                .map_err(|_| Error::before(ErrorCode::Conflict))?
                .storage
                .cleanup_retained(budget)
        }
    }
}
impl std::fmt::Debug for RetainedConversionStorage {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("RetainedConversionStorage")
            .finish_non_exhaustive()
    }
}
impl Registry {
    /// Explicit quiesced cleanup can collect only this registry's original
    /// manager. An active caller/worker or lost manager never grants adoption.
    pub(crate) fn collect_for_cleanup(
        &self,
        engine: &Engine,
        source: &CreationReceipt,
        operation: &str,
        request: &str,
        budget: &ReadBudget,
    ) -> Option<Result<()>> {
        let entries = match self.entries.try_lock() {
            Ok(entries) => entries,
            Err(_) => return Some(Err(Error::before(ErrorCode::Conflict))),
        };
        let entry = entries
            .values()
            .find(|entry| &entry.identity.0 == source && entry.identity.1 == operation)?
            .clone();
        drop(entries);
        Some((|| {
            budget.check()?;
            self.domain.verify()?;
            if !std::ptr::eq(self, engine.export_retention.as_ref()) || entry.identity.2 != request
            {
                return Err(Error::before(ErrorCode::Ownership));
            }
            if entry.borrower.upgrade().is_some() {
                return Err(Error::before(ErrorCode::Conflict));
            }
            {
                let work = entry
                    .work
                    .try_lock()
                    .map_err(|_| Error::before(ErrorCode::Conflict))?;
                if work.conversion_worker.upgrade().is_some() {
                    return Err(Error::before(ErrorCode::Conflict));
                }
                match &work.manager {
                    None => return Ok(()),
                    Some(manager)
                        if manager.unstarted() && work.storage.unlaunched_helper_recorded()? =>
                    {
                        return Ok(())
                    }
                    Some(manager)
                        if manager.has_collection()
                            && work.storage.runtime_custody_recorded()? =>
                    {
                        return Ok(())
                    }
                    _ => {}
                }
            }
            collect_entry(entry, engine, budget)
        })())
    }
    pub(crate) fn collect_retired(
        &self,
        engine: &Engine,
        source: &CreationReceipt,
        operation: &str,
        request: &str,
        budget: &ReadBudget,
    ) -> Result<()> {
        budget.check()?;
        self.domain.verify()?;
        if !std::ptr::eq(self, engine.export_retention.as_ref()) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let entry = {
            let entries = self
                .entries
                .try_lock()
                .map_err(|_| Error::before(ErrorCode::Conflict))?;
            entries
                .values()
                .find(|entry| {
                    &entry.identity.0 == source
                        && entry.identity.1 == operation
                        && entry.identity.2 == request
                })
                .cloned()
                .ok_or(Error::before(ErrorCode::Ownership))?
        };
        if entry.borrower.upgrade().is_some() {
            return Err(Error::before(ErrorCode::Conflict));
        }
        collect_entry(entry, engine, budget)
    }
    pub(crate) fn new(domain: Arc<crate::domain::DomainGuard>) -> Arc<Self> {
        Arc::new(Self {
            entries: Mutex::new(BTreeMap::new()),
            domain,
        })
    }
    pub(crate) fn insert(
        self: &Arc<Self>,
        storage: InitializedContainerStorage,
    ) -> Result<RetainedConversionStorage> {
        self.domain.verify()?;
        if !storage.retained_domain_matches(&self.domain) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let identity = storage.retained_identity()?;
        let key = crate::material::hash(&("smolbox-retained-conversion-storage-v1", &identity))?;
        let mut entries = self
            .entries
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        if entries.len() >= crate::EXPORT_RECORDS
            || entries.contains_key(&key)
            || entries
                .values()
                .any(|entry| entry.identity.0 == identity.0 && entry.identity.1 == identity.1)
        {
            return Err(Error::before(ErrorCode::Conflict));
        }
        let borrower = Arc::new(());
        entries.insert(
            key.clone(),
            Arc::new(Entry {
                identity,
                borrower: Arc::downgrade(&borrower),
                work: Mutex::new(Work {
                    storage,
                    manager: None,
                    conversion_entered: false,
                    conversion_worker: Weak::new(),
                    converted_plan: None,
                }),
            }),
        );
        Ok(RetainedConversionStorage {
            registry: Arc::downgrade(self),
            key,
            borrower,
        })
    }
    pub(crate) fn cleanup(
        &self,
        source: &CreationReceipt,
        operation: &str,
        request: &str,
        budget: &ReadBudget,
    ) -> Option<Result<ExportStageCleanup>> {
        let entries = match self.entries.try_lock() {
            Ok(entries) => entries,
            Err(_) => return Some(Err(Error::before(ErrorCode::Conflict))),
        };
        let key = entries
            .iter()
            .find(|(_, entry)| &entry.identity.0 == source && entry.identity.1 == operation)
            .map(|(key, _)| key.clone())?;
        let entry = entries.get(&key)?.clone();
        drop(entries);
        let result = (|| -> Result<_> {
            budget.check()?;
            self.domain.verify()?;
            if entry.identity.2 != request {
                return Err(Error::before(ErrorCode::Ownership));
            }
            if entry.borrower.upgrade().is_some() {
                return Err(Error::before(ErrorCode::Conflict));
            }
            let work = entry
                .work
                .try_lock()
                .map_err(|_| Error::before(ErrorCode::Conflict))?;
            if work.conversion_worker.upgrade().is_some() {
                return Err(Error::before(ErrorCode::Conflict));
            }
            work.storage.cleanup_retained(budget)
        })();
        if result.is_ok() {
            let mut entries = match self.entries.try_lock() {
                Ok(entries) => entries,
                Err(_) => return Some(Err(Error::uncertain(ErrorCode::Conflict))),
            };
            if entries
                .get(&key)
                .is_none_or(|current| !Arc::ptr_eq(current, &entry))
            {
                return Some(Err(Error::uncertain(ErrorCode::Ownership)));
            }
            entries.remove(&key);
        }
        Some(result)
    }
}
impl RetainedConversionStorage {
    /// Single owned conversion dispatch through the original source deadline.
    /// An uncertain attempt is retained and cannot be replayed by this token.
    pub fn run_conversion(&self, engine: &Engine) -> Result<CollectedContainerConversion> {
        let entry = self.entry(engine)?;
        let mut work = entry
            .work
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let budget = work.storage.original_budget();
        budget.check()?;
        work.storage.recheck_source(engine)?;
        let epoch = engine.boot_epoch()?;
        work.manager
            .as_ref()
            .ok_or(Error::before(ErrorCode::Ownership))?
            .recheck_started(&work.storage, epoch)?;
        if work.conversion_entered {
            return Err(Error::before(ErrorCode::Conflict));
        }
        let input = work.storage.conversion_input(engine)?;
        let expected = input.expected()?;
        let bytes = serde_json::to_vec(&input).map_err(|_| Error::before(ErrorCode::Validation))?;
        let supervisor = engine
            .transfers
            .as_ref()
            .ok_or(Error::before(ErrorCode::Unsupported))?;
        let prepared = supervisor.prepare_conversion_owned(
            &engine.transfer_directory()?,
            work.storage.conversion_socket(epoch)?,
            &bytes,
            expected,
        )?;
        budget.check()?;
        let worker = Arc::new(());
        work.conversion_worker = Arc::downgrade(&worker);
        work.conversion_entered = true;
        let result = supervisor.run(
            prepared,
            Box::new((entry.clone(), worker)),
            budget.deadline,
            &budget.cancel,
        )?;
        let mut collected = match result {
            crate::transfer_supervisor::RunResult::Collected(collected) => collected,
            crate::transfer_supervisor::RunResult::Retained(_) => {
                return Err(Error::uncertain(ErrorCode::Native))
            }
        };
        let (plan, layer, version) = collected.verify_conversion(&budget)?;
        work.storage
            .verify_conversion_plan(engine, &plan)
            .map_err(|e| Error::uncertain(e.code))?;
        budget.check().map_err(|e| Error::uncertain(e.code))?;
        Ok(CollectedContainerConversion {
            collected,
            plan,
            layer,
            version,
            budget,
            entry: Arc::downgrade(&entry),
        })
    }
    /// Move this exact collected output into protected staging without copying
    /// the tar or extending the original deadline. No packing/publication occurs.
    pub fn register_conversion(
        &self,
        engine: &Engine,
        mut conversion: CollectedContainerConversion,
    ) -> Result<crate::ExportStagedFile> {
        let entry = self.entry(engine)?;
        if conversion
            .entry
            .upgrade()
            .is_none_or(|owner| !Arc::ptr_eq(&owner, &entry))
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let mut work = entry
            .work
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let budget = work.storage.original_budget();
        budget.check()?;
        work.storage
            .verify_conversion_plan(engine, &conversion.plan)?;
        work.manager
            .as_ref()
            .ok_or(Error::before(ErrorCode::Ownership))?
            .recheck_started(&work.storage, engine.boot_epoch()?)?;
        if work.converted_plan.is_some() {
            return Err(Error::before(ErrorCode::Conflict));
        }
        let staged = work.storage.register_conversion(&mut conversion)?;
        work.converted_plan = Some(conversion.plan);
        work.storage
            .recheck_source(engine)
            .map_err(|e| Error::uncertain(e.code))?;
        budget.check().map_err(|e| Error::uncertain(e.code))?;
        Ok(staged)
    }
    /// Pack only an original collected conversion. Retire its private helper
    /// first; no SDK launch/stop, new job admission or implicit source mutation.
    pub fn pack(self, engine: &Engine) -> Result<crate::PackedExport> {
        let entry = self.entry(engine)?;
        let mut work = entry
            .work
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let budget = work.storage.original_budget();
        budget.check()?;
        if work.conversion_worker.upgrade().is_some() {
            return Err(Error::before(ErrorCode::Conflict));
        }
        let Work {
            storage,
            manager,
            converted_plan,
            ..
        } = &mut *work;
        let plan = converted_plan
            .as_ref()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        storage.verify_conversion_plan(engine, plan)?;
        manager
            .as_ref()
            .ok_or(Error::before(ErrorCode::Ownership))?
            .verify_collected(storage, engine.collection_epoch()?, &budget)?;
        storage.retire_layer_helper()?;
        let artifact = storage.pack_container(engine, plan)?;
        budget.check().map_err(|e| Error::uncertain(e.code))?;
        drop(work);
        Ok(crate::PackedExport::new_container(
            PackedConversion { token: self, entry },
            artifact,
        ))
    }
    /// Collect this conversion's originally enrolled child, retaining files and
    /// source accounting. This never adopts a process or grants cleanup proof.
    pub fn collect_manager(&self, engine: &Engine, budget: &ReadBudget) -> Result<()> {
        collect_entry(self.entry(engine)?, engine, budget)
    }
    fn entry(&self, engine: &Engine) -> Result<Arc<Entry>> {
        let registry = self
            .registry
            .upgrade()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        if !Arc::ptr_eq(&registry, &engine.export_retention) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        registry.domain.verify()?;
        let entries = registry
            .entries
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let entry = entries
            .get(&self.key)
            .cloned()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        let borrowed = entry
            .borrower
            .upgrade()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        if !Arc::ptr_eq(&borrowed, &self.borrower) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(entry)
    }
    /// One SDK launch through the original source budget. Observer retirement
    /// does not drop the retained manager, source authority or executing work.
    /// Entered/returned attempts cannot be replayed or cleaned as storage-only.
    pub fn start_manager(&self, engine: &Engine) -> Result<()> {
        let entry = self.entry(engine)?;
        let budget = {
            let work = entry
                .work
                .try_lock()
                .map_err(|_| Error::before(ErrorCode::Conflict))?;
            work.storage.original_budget()
        };
        self.prepare_manager(engine, &budget)?;
        engine.export_manager_rootfs()?;
        let epoch = engine.boot_epoch()?.clone();
        {
            let work = entry
                .work
                .try_lock()
                .map_err(|_| Error::before(ErrorCode::Conflict))?;
            work.storage.recheck(engine)?;
        }
        let worker_budget = budget.clone();
        let worker_epoch = epoch.clone();
        let worker_entry = entry.clone();
        // The source job already reserves both VMM and worker slots. No new
        // work admission or map-wide lock spans the blocking SDK entry.
        crate::oci_start::observe_owned(
            engine.jobs.clone(),
            budget.deadline,
            budget.cancel.clone(),
            move || {
                let mut work = worker_entry
                    .work
                    .try_lock()
                    .map_err(|_| Error::before(ErrorCode::Conflict))?;
                if work.conversion_worker.upgrade().is_some() {
                    return Err(Error::before(ErrorCode::Conflict));
                }
                let Work {
                    storage, manager, ..
                } = &mut *work;
                let manager = manager
                    .as_mut()
                    .ok_or(Error::before(ErrorCode::Ownership))?;
                manager.start_owned(storage, &worker_epoch, &worker_budget)
            },
        )?;
        let work = entry
            .work
            .try_lock()
            .map_err(|_| Error::uncertain(ErrorCode::Conflict))?;
        work.storage
            .recheck_source(engine)
            .map_err(|e| Error::uncertain(e.code))?;
        work.manager
            .as_ref()
            .ok_or(Error::uncertain(ErrorCode::Ownership))?
            .recheck_started(&work.storage, &epoch)?;
        budget.check().map_err(|e| Error::uncertain(e.code))
    }
    /// Construct and retain an unstarted SDK manager from collected storage and
    /// the package's explicit rootfs. No caller-supplied paths or launch occur.
    pub fn prepare_manager(&self, engine: &Engine, budget: &ReadBudget) -> Result<()> {
        self.recheck(engine, budget)?;
        let entry = self.entry(engine)?;
        let mut work = entry
            .work
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        budget.check()?;
        if let Some(manager) = &work.manager {
            return manager.recheck(&work.storage);
        }
        let manager = work.storage.prepare_manager(engine)?;
        work.manager = Some(manager);
        budget.check()
    }
    pub fn recheck(&self, engine: &Engine, budget: &ReadBudget) -> Result<()> {
        budget.check()?;
        let entry = self.entry(engine)?;
        let work = entry
            .work
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        work.storage.recheck(engine)?;
        if let Some(manager) = &work.manager {
            manager.recheck(&work.storage)?;
        }
        Ok(())
    }
}

fn collect_entry(entry: Arc<Entry>, engine: &Engine, budget: &ReadBudget) -> Result<()> {
    budget.check()?;
    {
        let work = entry
            .work
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        if work.conversion_worker.upgrade().is_some() {
            return Err(Error::before(ErrorCode::Conflict));
        }
        if work.manager.is_none() {
            return Err(Error::before(ErrorCode::Ownership));
        }
    }
    let epoch = engine.collection_epoch()?.clone();
    let budget = ReadBudget {
        deadline: budget
            .deadline
            .min(std::time::Instant::now() + std::time::Duration::from_secs(30)),
        cancel: budget.cancel.clone(),
    };
    let worker_budget = budget.clone();
    crate::oci_start::observe_owned(
        engine.jobs.clone(),
        budget.deadline,
        budget.cancel.clone(),
        move || {
            let mut work = entry
                .work
                .try_lock()
                .map_err(|_| Error::before(ErrorCode::Conflict))?;
            if work.conversion_worker.upgrade().is_some() {
                return Err(Error::before(ErrorCode::Conflict));
            }
            let Work {
                storage, manager, ..
            } = &mut *work;
            manager
                .as_mut()
                .ok_or(Error::before(ErrorCode::Ownership))?
                .collect_owned(storage, &epoch, &worker_budget)
        },
    )
}

impl Engine {
    /// Explicit quiesced control for an original retained entry after its caller
    /// retired. A persisted receipt alone cannot reconstruct a manager/child.
    pub fn collect_export_helper(
        &self,
        source: &CreationReceipt,
        operation: &str,
        request: &str,
        quiesced: bool,
        budget: &ReadBudget,
    ) -> Result<()> {
        budget.check()?;
        source.validate(self.binding())?;
        if !quiesced
            || !crate::domain::valid_id(operation)
            || !crate::domain::valid_hex(request, 64)
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        self.export_retention
            .collect_retired(self, source, operation, request, budget)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn quiesced_cleanup_rejects_live_borrowers_workers_and_foreign_requests_before_storage_retirement(
    ) {
        let (_temp, engine, source, intent, storage) =
            crate::export_container::tests::initialized_fixture();
        let retained = engine.export_retention.insert(storage).unwrap();
        let entry = retained.entry(&engine).unwrap();
        let budget = ReadBudget::new(
            std::time::Duration::from_secs(30),
            crate::Cancellation::default(),
        )
        .unwrap();
        assert_eq!(
            engine
                .cleanup_export_staging(
                    &source,
                    &intent.operation_id,
                    &intent.request_sha256,
                    true,
                    &budget
                )
                .unwrap_err()
                .code,
            ErrorCode::Conflict
        );
        let worker = Arc::new(());
        entry.work.lock().unwrap().conversion_worker = Arc::downgrade(&worker);
        drop(retained);
        assert_eq!(
            engine
                .cleanup_export_staging(
                    &source,
                    &intent.operation_id,
                    &intent.request_sha256,
                    true,
                    &budget
                )
                .unwrap_err()
                .code,
            ErrorCode::Conflict
        );
        assert_eq!(
            engine
                .cleanup_export_staging(
                    &source,
                    &intent.operation_id,
                    &"f".repeat(64),
                    true,
                    &budget
                )
                .unwrap_err()
                .code,
            ErrorCode::Ownership
        );
        assert_eq!(engine.jobs.counts().export_staging, 128 << 30);
        drop((worker, entry));
        engine
            .cleanup_export_staging(
                &source,
                &intent.operation_id,
                &intent.request_sha256,
                true,
                &budget,
            )
            .unwrap();
        assert_eq!(engine.jobs.counts().export_staging, 0);
        assert_eq!(engine.jobs.counts().work, 0);
    }
    #[test]
    fn packed_entry_retains_original_domain_after_engine_drop_without_reconstructing_ownership() {
        // Retention/cleanup model using collected storage only: no manager, VM,
        // packed artifact or publication authority is manufactured by this test.
        let (_temp, engine, _, _, storage) = crate::export_container::tests::initialized_fixture();
        let binding = engine.binding().clone();
        let directory = engine.domain.directory.clone();
        let jobs = engine.jobs.clone();
        let token = engine.export_retention.insert(storage).unwrap();
        let packed = PackedConversion {
            entry: token.entry(&engine).unwrap(),
            token,
        };
        let charged = jobs.counts();
        drop(engine);
        assert_eq!(jobs.counts(), charged);
        assert_eq!(
            crate::domain::DomainGuard::acquire_at(&binding, directory, false)
                .err()
                .unwrap()
                .code,
            ErrorCode::Conflict
        );
        let budget = ReadBudget::new(
            std::time::Duration::from_secs(30),
            crate::Cancellation::default(),
        )
        .unwrap();
        packed.close(&budget).unwrap();
        assert_eq!(jobs.counts().work, 0);
        assert_eq!(jobs.counts().export_staging, 0);
    }
    #[test]
    fn active_conversion_lease_fences_collection_and_retired_cleanup_without_sdk_entry() {
        let (_temp, engine, source, intent, storage) =
            crate::export_container::tests::initialized_fixture();
        let retained = engine.export_retention.insert(storage).unwrap();
        let entry = retained.entry(&engine).unwrap();
        let worker = Arc::new(());
        entry.work.lock().unwrap().conversion_worker = Arc::downgrade(&worker);
        let budget = ReadBudget::new(
            std::time::Duration::from_secs(30),
            crate::Cancellation::default(),
        )
        .unwrap();
        assert_eq!(
            retained.collect_manager(&engine, &budget).unwrap_err().code,
            ErrorCode::Conflict
        );
        let charged = engine.jobs.counts();
        assert!(retained.run_conversion(&engine).is_err()); // No original launched manager.
        assert!(!entry.work.lock().unwrap().conversion_entered);
        drop(retained);
        assert_eq!(
            engine
                .export_retention
                .cleanup(
                    &source,
                    &intent.operation_id,
                    &intent.request_sha256,
                    &budget
                )
                .unwrap()
                .unwrap_err()
                .code,
            ErrorCode::Conflict
        );
        assert_eq!(engine.jobs.counts(), charged);
        drop(worker);
        assert_eq!(
            collect_entry(entry, &engine, &budget).unwrap_err().code,
            ErrorCode::Ownership
        );
        engine
            .export_retention
            .cleanup(
                &source,
                &intent.operation_id,
                &intent.request_sha256,
                &budget,
            )
            .unwrap()
            .unwrap();
        assert_eq!(engine.jobs.counts().work, 0);
    }

    #[test]
    fn collection_controls_require_original_manager_and_exact_retired_authority() {
        let (_temp, engine, source, intent, storage) =
            crate::export_container::tests::initialized_fixture();
        let retained = engine.export_retention.insert(storage).unwrap();
        let budget = ReadBudget::new(
            std::time::Duration::from_secs(30),
            crate::Cancellation::default(),
        )
        .unwrap();
        let charged = engine.jobs.counts();
        assert_eq!(
            retained.collect_manager(&engine, &budget).unwrap_err().code,
            ErrorCode::Ownership
        );
        assert_eq!(
            engine
                .collect_export_helper(
                    &source,
                    &intent.operation_id,
                    &intent.request_sha256,
                    true,
                    &budget
                )
                .unwrap_err()
                .code,
            ErrorCode::Conflict
        );
        drop(retained);
        assert_eq!(
            engine
                .collect_export_helper(
                    &source,
                    &intent.operation_id,
                    &intent.request_sha256,
                    false,
                    &budget
                )
                .unwrap_err()
                .code,
            ErrorCode::Validation
        );
        assert_eq!(
            engine
                .collect_export_helper(
                    &source,
                    &intent.operation_id,
                    &"0".repeat(64),
                    true,
                    &budget
                )
                .unwrap_err()
                .code,
            ErrorCode::Ownership
        );
        assert_eq!(
            engine
                .collect_export_helper(
                    &source,
                    &intent.operation_id,
                    &intent.request_sha256,
                    true,
                    &budget
                )
                .unwrap_err()
                .code,
            ErrorCode::Ownership
        );
        assert_eq!(charged, engine.jobs.counts());
        budget.cancel.cancel();
        assert!(engine
            .collect_export_helper(
                &source,
                &intent.operation_id,
                &intent.request_sha256,
                true,
                &budget
            )
            .is_err());
        assert_eq!(charged, engine.jobs.counts());
        let cleanup = ReadBudget::new(
            std::time::Duration::from_secs(30),
            crate::Cancellation::default(),
        )
        .unwrap();
        engine
            .cleanup_export_staging(
                &source,
                &intent.operation_id,
                &intent.request_sha256,
                true,
                &cleanup,
            )
            .unwrap();
        assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
    }
    #[test]
    fn entry_work_contention_never_holds_registry_control_or_releases_worker_authority() {
        let (_temp, engine, source, intent, storage) =
            crate::export_container::tests::initialized_fixture();
        let retained = engine.export_retention.insert(storage).unwrap();
        let budget = ReadBudget::for_export_work(
            std::time::Duration::from_secs(30),
            crate::Cancellation::default(),
        )
        .unwrap();
        let worker_entry = retained.entry(&engine).unwrap();
        let worker = worker_entry.work.try_lock().unwrap();
        assert!(engine.export_retention.entries.try_lock().is_ok());
        assert_eq!(
            retained.recheck(&engine, &budget).unwrap_err().code,
            ErrorCode::Conflict
        );
        assert!(engine
            .export_retention
            .cleanup(
                &source,
                "unrelated-control",
                &intent.request_sha256,
                &budget
            )
            .is_none());
        let control = engine
            .jobs
            .acquire(crate::jobs::Demand::export_observation())
            .unwrap();
        let second_control = engine
            .jobs
            .acquire(crate::jobs::Demand::export_observation())
            .unwrap();
        let charged = engine.jobs.counts();
        drop(retained);
        assert_eq!(
            engine
                .cleanup_export_staging(
                    &source,
                    &intent.operation_id,
                    &intent.request_sha256,
                    true,
                    &budget
                )
                .unwrap_err()
                .code,
            ErrorCode::Conflict
        );
        assert_eq!(charged, engine.jobs.counts());
        drop((control, second_control));
        drop(worker);
        engine
            .cleanup_export_staging(
                &source,
                &intent.operation_id,
                &intent.request_sha256,
                true,
                &budget,
            )
            .unwrap();
        assert_eq!(engine.jobs.counts().export_staging, 0);
        assert_eq!(engine.jobs.counts().work, 1);
        drop(worker_entry);
        assert_eq!(engine.jobs.counts().work, 0);
    }
}
