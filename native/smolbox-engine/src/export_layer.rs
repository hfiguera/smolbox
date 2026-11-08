//! Protected handoff of a collected worker's original inode. No second tar copy,
//! helper collection, tar validation or publication authority is minted here.
use super::*;
use crate::transfer_supervisor::Spool;
use std::ffi::CString;
use std::os::fd::FromRawFd;

const NAME: &str = "layer.tar";
#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum Phase {
    Entering,
    Ready,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Layer {
    input_sha256: String,
    plan_sha256: String,
    phase: Phase,
    file: ExportStagedFile,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pack: Option<PackIntent>,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct PackIntent {
    maximum: u64,
    entered: bool,
    file: Option<Version>,
}
impl Layer {
    pub(super) fn validate(&self, record: &Record) -> Result<()> {
        let helper = record.helper.as_ref().ok_or(before(ErrorCode::Ownership))?;
        if !crate::domain::valid_hex(&self.input_sha256, 64)
            || !crate::domain::valid_hex(&self.plan_sha256, 64)
            || self.file.name != NAME
            || self.file.size_bytes == 0
            || self.file.size_bytes > helper.budget.max_flattened_bytes
            || self.file.version.0 != record.device
            || self.file.version.1 == 0
            || self.file.version.2 != self.file.size_bytes
            || self.file.version.3 <= 0
            || self.file.version.5 <= 0
            || !(0..1_000_000_000).contains(&self.file.version.4)
            || !(0..1_000_000_000).contains(&self.file.version.6)
            || !matches!(
                helper.phase,
                HelperPhase::LaunchReturned
                    | HelperPhase::LaunchCollecting
                    | HelperPhase::LaunchCollected
                    | HelperPhase::RuntimePrepared
                    | HelperPhase::Removing
                    | HelperPhase::Removed
            )
            || !crate::domain::valid_hex(&self.file.sha256, 64)
            || (record.schema == 10
                && (self.pack.is_some()
                    || !matches!(
                        record.phase,
                        super::Phase::Preparing | super::Phase::Cleaning | super::Phase::Cleaned
                    )))
            || (record.schema == 11
                && (helper.phase != HelperPhase::Removed
                    || helper.runtime.is_none()
                    || self.phase != Phase::Ready
                    || !matches!(
                        record.phase,
                        super::Phase::Ready
                            | super::Phase::Packing
                            | super::Phase::Packed
                            | super::Phase::Cleaning
                            | super::Phase::Cleaned
                    )))
            || match self.phase {
                Phase::Entering => !record.files.is_empty(),
                Phase::Ready => {
                    record.files.first() != Some(&self.file)
                        || record.files.len() > if record.schema == 11 { 2 } else { 1 }
                }
            }
        {
            return Err(before(ErrorCode::Ownership));
        }
        if record.schema == 11 {
            let artifact = record
                .files
                .iter()
                .find(|f| f.name == "artifact.smolmachine");
            if (record.phase == super::Phase::Ready && self.pack.is_some())
                || (matches!(record.phase, super::Phase::Packing | super::Phase::Packed)
                    && self.pack.is_none())
                || (record.phase == super::Phase::Packed && artifact.is_none())
                || (record.files.len() == 2 && artifact.is_none())
            {
                return Err(before(ErrorCode::Ownership));
            }
            if let Some(pack) = &self.pack {
                if pack.maximum == 0
                    || pack.maximum > helper.budget.artifact_limit(self.file.size_bytes)?
                    || (pack.file.is_some() && !pack.entered)
                    || pack
                        .file
                        .is_some_and(|v| v.0 != record.device || v.1 == 0 || v.2 != 0)
                    || artifact.is_some_and(|f| {
                        f.size_bytes > pack.maximum
                            || pack
                                .file
                                .is_none_or(|v| (v.0, v.1) != (f.version.0, f.version.1))
                    })
                {
                    return Err(before(ErrorCode::Ownership));
                }
            } else if artifact.is_some() {
                return Err(before(ErrorCode::Ownership));
            }
        }
        Ok(())
    }
}
pub(super) fn forward(old: &Option<Layer>, next: &Option<Layer>) -> bool {
    match (old, next) {
        (None, Some(next)) => next.phase == Phase::Entering,
        (Some(old), Some(next)) if old.phase == Phase::Entering => {
            old.phase == Phase::Entering
                && next.phase == Phase::Ready
                && old.input_sha256 == next.input_sha256
                && old.plan_sha256 == next.plan_sha256
                && old.file.name == next.file.name
                && old.file.size_bytes == next.file.size_bytes
                && old.file.sha256 == next.file.sha256
                && same_payload(old.file.version, next.file.version)
                && old.pack.is_none()
                && next.pack.is_none()
        }
        (Some(old), Some(next)) if old.phase == Phase::Ready && next.phase == Phase::Ready => {
            let mut same = next.clone();
            same.pack = old.pack.clone();
            same == *old
                && match (&old.pack, &next.pack) {
                    (None, Some(next)) => next.file.is_none() && !next.entered,
                    (Some(old), Some(next)) => {
                        old.maximum == next.maximum
                            && old.file.is_none()
                            && ((!old.entered && next.entered && next.file.is_none())
                                || (old.entered && next.entered && next.file.is_some()))
                    }
                    _ => false,
                }
        }
        _ => false,
    }
}
fn same_payload(a: Version, b: Version) -> bool {
    (a.0, a.1, a.2, a.3, a.4) == (b.0, b.1, b.2, b.3, b.4)
}
pub(super) fn verify_cleanup(
    registry: &Staging,
    record: &Record,
    budget: &ReadBudget,
) -> Result<()> {
    budget.check()?;
    let layer = record.layer.as_ref().ok_or(before(ErrorCode::Ownership))?;
    let path = registry.root_path(record);
    if absent_path(&path) && matches!(record.phase, super::Phase::Cleaning | super::Phase::Cleaned)
    {
        return Ok(());
    }
    verify_root(&open_root(&path)?, record)?;
    let mut found = false;
    let mut artifact_found = false;
    for (count, entry) in std::fs::read_dir(&path)
        .map_err(|_| before(ErrorCode::Io))?
        .enumerate()
    {
        budget.check()?;
        if count >= 2 {
            return Err(before(ErrorCode::Ownership));
        }
        let entry = entry.map_err(|_| before(ErrorCode::Io))?;
        let name = entry.file_name();
        let file = plain(&entry.path())?;
        let version = Version::of(&file)?;
        let mode = file.metadata().map_err(|_| before(ErrorCode::Io))?.mode() & 0o777;
        if name == NAME {
            found = true;
            if match layer.phase {
                Phase::Entering => {
                    !same_payload(version, layer.file.version) || !matches!(mode, 0o600 | 0o400)
                }
                Phase::Ready => version != layer.file.version || mode != 0o400,
            } {
                return Err(before(ErrorCode::Ownership));
            }
        } else if name == "artifact.smolmachine" && record.schema == 11 {
            artifact_found = true;
            let pack = layer.pack.as_ref().ok_or(before(ErrorCode::Ownership))?;
            let anchor = pack.file.ok_or(before(ErrorCode::Ownership))?;
            if (version.0, version.1) != (anchor.0, anchor.1)
                || version.2 > pack.maximum
                || !matches!(mode, 0o600 | 0o400)
            {
                return Err(before(ErrorCode::Ownership));
            }
            if let Some(proof) = record
                .files
                .iter()
                .find(|f| f.name == "artifact.smolmachine")
            {
                if version != proof.version || mode != 0o400 {
                    return Err(before(ErrorCode::Ownership));
                }
            }
        } else {
            return Err(before(ErrorCode::Ownership));
        }
    }
    if record.phase != super::Phase::Cleaning
        && ((!found && layer.phase == Phase::Ready)
            || (!artifact_found && layer.pack.as_ref().is_some_and(|p| p.file.is_some())))
    {
        return Err(before(ErrorCode::Ownership));
    }
    Ok(())
}
impl Stage {
    pub(crate) fn retire_layer_helper(&mut self, budget: &ReadBudget) -> Result<()> {
        budget.check()?;
        let _control = self
            .registry
            .jobs
            .acquire(crate::jobs::Demand::export_cleanup())?;
        self.verify()?;
        let record = self.record()?;
        if record.schema != 10
            || record.phase != super::Phase::Preparing
            || record
                .layer
                .as_ref()
                .is_none_or(|l| l.phase != Phase::Ready)
            || record.helper.as_ref().is_none_or(|h| {
                !matches!(
                    h.phase,
                    HelperPhase::RuntimePrepared | HelperPhase::Removing | HelperPhase::Removed
                )
            })
        {
            return Err(before(ErrorCode::Ownership));
        }
        verify_cleanup(&self.registry, &record, budget)?;
        {
            let mut entries = self
                .registry
                .entries
                .lock()
                .map_err(|_| before(ErrorCode::Native))?;
            let entry = entries
                .get_mut(&self.key)
                .ok_or(before(ErrorCode::Ownership))?;
            if entry.record != record || !entry.live.ptr_eq(&Arc::downgrade(&self.live)) {
                return Err(before(ErrorCode::Ownership));
            }
            self.registry.retire_helper(&self.key, entry, budget)?;
        }
        let mut record = self.record()?;
        if record
            .helper
            .as_ref()
            .is_none_or(|h| h.phase != HelperPhase::Removed)
        {
            return Err(before(ErrorCode::Ownership));
        }
        record.schema = 11;
        record.phase = super::Phase::Ready;
        self.publish_record(record)
            .map_err(|e| Error::uncertain(e.code))?;
        self.verify()?;
        budget.check()
    }
    pub(crate) fn container_layer(&self) -> Result<ExportStagedFile> {
        self.verify()?;
        let record = self.record()?;
        if record.schema != 11 {
            return Err(before(ErrorCode::Ownership));
        }
        Ok(record.layer.ok_or(before(ErrorCode::Ownership))?.file)
    }
    pub(crate) fn begin_container_pack(&mut self, maximum: u64) -> Result<()> {
        self.verify()?;
        let mut record = self.record()?;
        if record.schema != 11
            || record.phase != super::Phase::Ready
            || maximum == 0
            || record.helper.as_ref().is_none_or(|h| {
                record.layer.as_ref().is_none_or(|l| {
                    h.budget
                        .artifact_limit(l.file.size_bytes)
                        .map_or(true, |cap| maximum > cap)
                })
            })
        {
            return Err(before(ErrorCode::Ownership));
        }
        let layer = record.layer.as_mut().ok_or(before(ErrorCode::Ownership))?;
        if layer.pack.is_some() {
            return Err(before(ErrorCode::Conflict));
        }
        layer.pack = Some(PackIntent {
            maximum,
            entered: false,
            file: None,
        });
        record.phase = super::Phase::Packing;
        self.publish_record(record)
    }
    pub(crate) fn enter_container_writer(&self, name: &str, maximum: u64) -> Result<()> {
        let old = self.record()?;
        if old.schema != 11
            || name != "artifact.smolmachine"
            || old.phase != super::Phase::Packing
            || old
                .layer
                .as_ref()
                .and_then(|l| l.pack.as_ref())
                .is_none_or(|p| p.maximum != maximum || p.entered || p.file.is_some())
        {
            return Err(before(ErrorCode::Ownership));
        }
        let mut next = old.clone();
        next.layer.as_mut().unwrap().pack.as_mut().unwrap().entered = true;
        self.publish_writer_record(old, next)
    }
    pub(crate) fn note_container_writer(&self, file: &File) -> Result<()> {
        let old = self.record()?;
        let mut next = old.clone();
        let pack = next
            .layer
            .as_mut()
            .and_then(|l| l.pack.as_mut())
            .ok_or(before(ErrorCode::Ownership))?;
        if old.schema != 11
            || old.phase != super::Phase::Packing
            || pack.file.is_some()
            || !pack.entered
        {
            return Err(before(ErrorCode::Ownership));
        }
        let version = Version::of(file)?;
        if version.0 != old.device
            || version.2 != 0
            || Version::of(&plain(
                &self.registry.root_path(&old).join("artifact.smolmachine"),
            )?)? != version
        {
            return Err(before(ErrorCode::Ownership));
        }
        pack.file = Some(version);
        self.publish_writer_record(old, next)
    }
    fn publish_writer_record(&self, old: Record, next: Record) -> Result<()> {
        let (_, version) = read(&self.registry.path(&self.key))?;
        self.registry.publish(&self.key, &next, Some(version))?;
        let mut entries = self
            .registry
            .entries
            .lock()
            .map_err(|_| before(ErrorCode::Native))?;
        let entry = entries
            .get_mut(&self.key)
            .ok_or(before(ErrorCode::Ownership))?;
        if entry.record != old {
            return Err(before(ErrorCode::Ownership));
        }
        entry.record = next;
        Ok(())
    }
    pub(crate) fn register_layer(
        &mut self,
        conversion: &mut crate::CollectedContainerConversion,
    ) -> Result<ExportStagedFile> {
        let (spool, proof, budget) = conversion.staging_source()?;
        self.register_layer_parts(spool, &proof, &budget)
    }
    fn register_layer_parts(
        &mut self,
        spool: &mut Spool,
        proof: &crate::export_bootstrap::Proof,
        budget: &ReadBudget,
    ) -> Result<ExportStagedFile> {
        budget.check()?;
        self.verify()?;
        let mut record = self.record()?;
        let helper = record.helper.as_ref().ok_or(before(ErrorCode::Ownership))?;
        if record.schema != 8
            || helper.phase != HelperPhase::LaunchReturned
            || record.layer.is_some()
            || !record.files.is_empty()
            || self.written.load(Ordering::SeqCst) != 0
            || self.reserved.load(Ordering::SeqCst) != 0
            || !proof.matches(&crate::export_bootstrap::Expected {
                input_sha256: proof.input_sha256.clone(),
                maximum: helper.budget.max_flattened_bytes,
            })
        {
            return Err(before(ErrorCode::Ownership));
        }
        spool.verify()?;
        let source = spool.path.parent().ok_or(before(ErrorCode::Ownership))?;
        crate::host::private_directory(source)?;
        let parent = open_root(source)?;
        let source_name = CString::new(
            spool
                .path
                .file_name()
                .ok_or(before(ErrorCode::Ownership))?
                .as_encoded_bytes(),
        )
        .map_err(|_| before(ErrorCode::Ownership))?;
        let source_file = at(&parent, &source_name)?;
        let version = Version::of(&spool.file)?;
        if version != Version::of(&source_file)?
            || version.0 != record.device
            || version.2 != proof.bytes
            || spool
                .file
                .metadata()
                .map_err(|_| before(ErrorCode::Io))?
                .mode()
                & 0o777
                != 0o600
            || !absent_path(&self.registry.root_path(&record).join(NAME))
        {
            return Err(before(ErrorCode::Ownership));
        }
        drop(source_file);
        let reserved = helper
            .budget
            .private_disk_bytes
            .checked_add(proof.bytes)
            .filter(|n| *n <= record.max_bytes)
            .ok_or(before(ErrorCode::Admission))?;
        let layer = Layer {
            input_sha256: proof.input_sha256.clone(),
            plan_sha256: proof.plan_sha256.clone(),
            phase: Phase::Entering,
            pack: None,
            file: ExportStagedFile {
                name: NAME.into(),
                size_bytes: proof.bytes,
                sha256: proof.sha256.clone(),
                version,
            },
        };
        record.schema = 10;
        record.layer = Some(layer);
        self.publish_record(record)
            .map_err(|e| Error::uncertain(e.code))?;
        self.reserved.store(reserved, Ordering::SeqCst);
        // From this point the protected record owns the attempt. Never retry a
        // rename or enroll an existing destination after any uncertain return.
        let target_name = CString::new(NAME).unwrap();
        let complete = (|| -> Result<ExportStagedFile> {
            budget.check()?;
            if Version::of(&spool.file)? != version
                || Version::of(&at(&parent, &source_name)?)? != version
            {
                return Err(before(ErrorCode::Ownership));
            }
            self.record()?;
            move_exclusive(&parent, &source_name, &self.root, &target_name)?;
            if !absent_path(&spool.path) {
                return Err(before(ErrorCode::Ownership));
            }
            let target = at(&self.root, &target_name)?;
            if !same_payload(Version::of(&target)?, version)
                || Version::of(&spool.file)? != Version::of(&target)?
            {
                return Err(before(ErrorCode::Ownership));
            }
            drop(target);
            spool
                .file
                .set_permissions(std::fs::Permissions::from_mode(0o400))
                .and_then(|()| spool.file.sync_all())
                .map_err(|_| before(ErrorCode::Io))?;
            parent
                .sync_all()
                .and_then(|()| self.root.sync_all())
                .map_err(|_| before(ErrorCode::Io))?;
            let final_version = Version::of(&spool.file)?;
            let mut reader = &spool.file;
            reader
                .seek(SeekFrom::Start(0))
                .map_err(|_| before(ErrorCode::Io))?;
            let mut hash = Sha256::new();
            let mut bytes = 0;
            let mut buffer = [0; 64 * 1024];
            loop {
                budget.check()?;
                let count = reader
                    .read(&mut buffer)
                    .map_err(|_| before(ErrorCode::Io))?;
                if count == 0 {
                    break;
                }
                bytes += count as u64;
                if bytes > proof.bytes {
                    return Err(before(ErrorCode::Ownership));
                }
                hash.update(&buffer[..count]);
            }
            if bytes != proof.bytes
                || hex::encode(hash.finalize()) != proof.sha256
                || Version::of(&spool.file)? != final_version
                || Version::of(&at(&self.root, &target_name)?)? != final_version
            {
                return Err(before(ErrorCode::Ownership));
            }
            let mut record = self.record()?;
            let layer = record.layer.as_mut().ok_or(before(ErrorCode::Ownership))?;
            layer.phase = Phase::Ready;
            layer.file.version = final_version;
            let file = layer.file.clone();
            record.files = vec![file.clone()];
            self.publish_record(record)?;
            self.written.store(bytes, Ordering::SeqCst);
            self.verify()?;
            budget.check()?;
            Ok(file)
        })();
        complete.map_err(|e| Error::uncertain(e.code))
    }
}
fn at(parent: &File, name: &CString) -> Result<File> {
    let raw = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            name.as_ptr(),
            libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK,
        )
    };
    if raw < 0 {
        return Err(before(ErrorCode::Io));
    }
    Ok(unsafe { File::from_raw_fd(raw) })
}
fn move_exclusive(
    source: &File,
    name: &CString,
    target: &File,
    destination: &CString,
) -> Result<()> {
    #[cfg(target_os = "linux")]
    let result = unsafe {
        libc::syscall(
            libc::SYS_renameat2,
            source.as_raw_fd(),
            name.as_ptr(),
            target.as_raw_fd(),
            destination.as_ptr(),
            libc::RENAME_NOREPLACE,
        )
    };
    #[cfg(target_os = "macos")]
    let result = unsafe {
        libc::renameatx_np(
            source.as_raw_fd(),
            name.as_ptr(),
            target.as_raw_fd(),
            destination.as_ptr(),
            libc::RENAME_EXCL,
        )
    };
    if result != 0 {
        let error = std::io::Error::last_os_error();
        let code = if error.kind() == std::io::ErrorKind::AlreadyExists {
            ErrorCode::Conflict
        } else if matches!(
            error.raw_os_error(),
            Some(libc::ENOSYS | libc::EINVAL | libc::ENOTSUP | libc::EXDEV)
        ) {
            ErrorCode::Unsupported
        } else {
            ErrorCode::Io
        };
        return Err(before(code));
    }
    Ok(())
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::export_staging::tests::{budget, launch_fixture};
    fn spool(path: &Path) -> (Spool, crate::export_bootstrap::Proof) {
        let path = path.canonicalize().unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        let mut spool = Spool::new(&path).unwrap();
        spool.file.write_all(b"private layer bytes").unwrap();
        spool.file.sync_all().unwrap();
        let proof = crate::export_bootstrap::Proof {
            input_sha256: "a".repeat(64),
            bytes: 19,
            sha256: hex::encode(Sha256::digest(b"private layer bytes")),
            plan_bytes: 128,
            plan_sha256: "b".repeat(64),
        };
        (spool, proof)
    }
    fn launched(
        stage: &mut Stage,
        root: &File,
        epoch: &crate::epoch::ActorEpoch,
    ) -> crate::epoch::BootEnrollment {
        let (name, _) = stage.prepared_helper_identity(root).unwrap();
        let dispatch = epoch.begin_boot(&name).unwrap();
        stage.begin_helper_launch(root, &dispatch, epoch).unwrap();
        let enrolled = crate::epoch::tests::complete_model(dispatch);
        stage.helper_launch_returned(root, &enrolled).unwrap();
        enrolled
    }
    fn collect(
        stage: &mut Stage,
        root: &File,
        epoch: &crate::epoch::ActorEpoch,
        enrolled: &crate::epoch::BootEnrollment,
        path: &Path,
    ) -> PathBuf {
        let (name, _) = stage
            .record()
            .unwrap()
            .helper
            .as_ref()
            .map(|h| (h.name.clone(), h.path(&stage.registry.binding)))
            .unwrap();
        stage
            .begin_helper_collection(root, epoch, enrolled)
            .unwrap();
        let collected = epoch.collect_enrolled(&name, enrolled).unwrap();
        stage
            .helper_child_collected(root, epoch, &collected)
            .unwrap();
        let rootfs = path.canonicalize().unwrap().join("layer-rootfs-model");
        std::fs::create_dir(&rootfs).unwrap();
        let rootfs_handle = crate::export_source::Root::open(&rootfs).unwrap();
        stage
            .prepare_helper_runtime(root, epoch, &collected, &rootfs_handle, &budget())
            .unwrap();
        stage
            .verify_helper_runtime(root, epoch, &collected, &rootfs_handle, &budget())
            .unwrap();
        rootfs
    }
    fn intent(stage: &mut Stage, spool: &Spool, proof: &crate::export_bootstrap::Proof) {
        let mut record = stage.record().unwrap();
        record.schema = 10;
        record.layer = Some(Layer {
            input_sha256: proof.input_sha256.clone(),
            plan_sha256: proof.plan_sha256.clone(),
            phase: Phase::Entering,
            pack: None,
            file: ExportStagedFile {
                name: NAME.into(),
                size_bytes: proof.bytes,
                sha256: proof.sha256.clone(),
                version: Version::of(&spool.file).unwrap(),
            },
        });
        stage.publish_record(record).unwrap();
    }
    pub(crate) fn ready_fixture() -> (
        tempfile::TempDir,
        crate::Engine,
        CreationReceipt,
        Stage,
        ExportStagedFile,
    ) {
        let (temp, engine, source, mut stage, root, epoch) = launch_fixture();
        let enrolled = launched(&mut stage, &root, &epoch);
        let (mut spool, proof) = spool(temp.path());
        let file = stage
            .register_layer_parts(&mut spool, &proof, &budget())
            .unwrap();
        assert!(stage.retire_layer_helper(&budget()).is_err());
        drop(spool);
        collect(&mut stage, &root, &epoch, &enrolled, temp.path());
        stage.retire_layer_helper(&budget()).unwrap();
        assert_eq!(stage.record().unwrap().schema, 11);
        (temp, engine, source, stage, file)
    }
    #[test]
    fn shared_stage_caps_packing_from_actual_layer_and_persists_cleanup_only_recovery() {
        let (temp, engine, source, mut stage, root, epoch) =
            crate::export_staging::tests::shared_launch_fixture();
        let enrolled = launched(&mut stage, &root, &epoch);
        let (mut spool, proof) = spool(temp.path());
        let file = stage
            .register_layer_parts(&mut spool, &proof, &budget())
            .unwrap();
        drop(spool);
        collect(&mut stage, &root, &epoch, &enrolled, temp.path());
        stage.retire_layer_helper(&budget()).unwrap();
        let record = stage.record().unwrap();
        let shared = &record.helper.as_ref().unwrap().budget;
        assert_eq!(shared.shared_output_bytes, Some(123 << 30));
        let cap = shared.artifact_limit(file.size_bytes).unwrap();
        assert!(cap < shared.max_artifact_bytes);
        assert!(stage.begin_container_pack(cap + 1).is_err());
        stage.begin_container_pack(cap).unwrap();
        let mut writer = stage.file("artifact.smolmachine", cap, &budget()).unwrap();
        writer.write_all(b"partial owned bytes").unwrap();
        drop(writer);
        assert_eq!(stage.reserved.load(Ordering::SeqCst), record.max_bytes);
        drop((stage, root, epoch, engine));
        let reopened = crate::machine::tests::test_engine(temp.path());
        assert_eq!(reopened.jobs.counts().export_staging, 128 << 30);
        reopened
            .cleanup_export_staging(&source, "launch-model", &"d".repeat(64), true, &budget())
            .unwrap();
        assert_eq!(reopened.jobs.counts().export_staging, 0);
        assert!(!reopened.available());
    }

    #[test]
    fn packing_readiness_retires_only_original_collected_helper_and_preserves_layer() {
        let (_temp, engine, source, stage, file) = ready_fixture();
        let record = stage.record().unwrap();
        let helper = record.helper.as_ref().unwrap();
        assert!(helper.phase == HelperPhase::Removed);
        assert!(!helper.path(engine.binding()).exists());
        assert!(record.phase == super::super::Phase::Ready);
        for schema in [9, 10, 12] {
            let mut unsupported = record.clone();
            unsupported.schema = schema;
            assert!(unsupported.valid(engine.binding()).is_err());
        }
        assert_eq!(stage.container_layer().unwrap(), file);
        assert!(engine.db.get_vm(&source.name).unwrap().is_some());
        let proof = cleanup_proof(&record).unwrap();
        assert_eq!(stage.close(&budget()).unwrap(), proof);
        assert_eq!(engine.jobs.counts().export_staging, 0);
    }

    #[test]
    fn partial_pack_writer_identity_survives_normal_reopen_for_cleanup_only() {
        let (temp, engine, source, mut stage, _) = ready_fixture();
        stage.begin_container_pack(1024).unwrap();
        assert!(stage.file("artifact.smolmachine", 1023, &budget()).is_err());
        let mut writer = stage.file("artifact.smolmachine", 1024, &budget()).unwrap();
        writer.write_all(b"partial owned output").unwrap();
        drop(writer);
        assert!(stage.file("artifact.smolmachine", 1024, &budget()).is_err());
        let expected = cleanup_proof(&stage.record().unwrap()).unwrap();
        drop((stage, engine));
        let reopened = crate::machine::tests::test_engine(temp.path());
        let result = reopened
            .cleanup_export_staging(&source, "launch-model", &"d".repeat(64), true, &budget())
            .unwrap();
        assert_eq!(result, expected);
        assert_eq!(reopened.jobs.counts().export_staging, 0);
        assert!(!reopened.available());
    }
    #[test]
    fn unregistered_replaced_or_linked_partial_pack_files_never_gain_cleanup_authority() {
        for variant in 0..3 {
            let (temp, engine, _, mut stage, _) = ready_fixture();
            stage.begin_container_pack(1024).unwrap();
            let path = stage
                .registry
                .root_path(&stage.record().unwrap())
                .join("artifact.smolmachine");
            let held = if variant == 0 {
                std::fs::write(&path, b"unregistered").unwrap();
                None
            } else {
                let mut writer = stage.file("artifact.smolmachine", 1024, &budget()).unwrap();
                writer.write_all(b"partial owned output").unwrap();
                drop(writer);
                let held = File::open(&path).unwrap();
                if variant == 1 {
                    std::fs::remove_file(&path).unwrap();
                    std::fs::write(&path, b"foreign").unwrap();
                } else {
                    std::fs::hard_link(&path, temp.path().join("foreign-alias")).unwrap();
                }
                Some(held)
            };
            assert!(stage.cleanup_retained(&budget()).is_err());
            assert!(path.exists());
            assert_eq!(engine.jobs.counts().export_staging, 128 << 30);
            drop(held);
        }
    }

    #[test]
    fn original_inode_moves_once_into_readonly_protected_custody_without_copying_or_packing() {
        let (temp, engine, source, mut stage, root, epoch) = launch_fixture();
        let enrolled = launched(&mut stage, &root, &epoch);
        let (mut spool, proof) = spool(temp.path());
        let original = Version::of(&spool.file).unwrap();
        let old_path = spool.path.clone();
        let file = stage
            .register_layer_parts(&mut spool, &proof, &budget())
            .unwrap();
        assert_eq!(file.name, NAME);
        assert_eq!(file.size_bytes, 19);
        assert!(!old_path.exists());
        assert!(same_payload(file.version, original));
        let record = stage.record().unwrap();
        assert_eq!(record.schema, 10);
        assert!(record.layer.as_ref().unwrap().phase == Phase::Ready);
        assert_eq!(
            stage.reserved.load(Ordering::SeqCst),
            record.helper.as_ref().unwrap().budget.private_disk_bytes + 19
        );
        assert_eq!(stage.written.load(Ordering::SeqCst), 19);
        let target = stage.registry.root_path(&record).join(NAME);
        assert_eq!(std::fs::metadata(&target).unwrap().mode() & 0o777, 0o400);
        drop(spool);
        assert_eq!(std::fs::read(&target).unwrap(), b"private layer bytes");
        assert!(stage.begin_pack().is_err());
        assert!(stage.file("artifact.smolmachine", 1024, &budget()).is_err());
        assert!(stage.cleanup_retained(&budget()).is_err());
        collect(&mut stage, &root, &epoch, &enrolled, temp.path());
        assert_eq!(stage.record().unwrap().schema, 10);
        let expected = cleanup_proof(&stage.record().unwrap()).unwrap();
        let actual = stage.close(&budget()).unwrap();
        assert_eq!(actual, expected);
        assert!(!target.exists());
        assert_eq!(engine.jobs.counts().export_staging, 0);
        assert!(engine.db.get_vm(&source.name).unwrap().is_some());
    }
    #[test]
    fn deterministic_entered_handoff_models_reopen_for_cleanup_without_resuming_a_writer() {
        for boundary in 0..3 {
            let (temp, engine, source, mut stage, root, epoch) = launch_fixture();
            let enrolled = launched(&mut stage, &root, &epoch);
            let (spool, proof) = spool(temp.path());
            intent(&mut stage, &spool, &proof);
            let target = stage
                .registry
                .root_path(&stage.record().unwrap())
                .join(NAME);
            if boundary > 0 {
                let parent = open_root(&temp.path().canonicalize().unwrap()).unwrap();
                let name =
                    CString::new(spool.path.file_name().unwrap().as_encoded_bytes()).unwrap();
                move_exclusive(&parent, &name, &stage.root, &CString::new(NAME).unwrap()).unwrap();
                parent.sync_all().unwrap();
                stage.root.sync_all().unwrap();
                if boundary == 2 {
                    spool
                        .file
                        .set_permissions(std::fs::Permissions::from_mode(0o400))
                        .unwrap();
                    spool.file.sync_all().unwrap();
                }
            }
            drop(spool);
            collect(&mut stage, &root, &epoch, &enrolled, temp.path());
            let expected = cleanup_proof(&stage.record().unwrap()).unwrap();
            drop((stage, root, epoch, engine));
            let reopened = crate::machine::tests::test_engine(temp.path());
            assert_eq!(reopened.jobs.counts().export_staging, 128 << 30);
            let cleanup = reopened
                .cleanup_export_staging(&source, "launch-model", &"d".repeat(64), true, &budget())
                .unwrap();
            assert_eq!(cleanup, expected);
            assert!(!target.exists());
            assert_eq!(reopened.jobs.counts().export_staging, 0);
            assert!(!reopened.available());
        }
    }
    #[test]
    fn invalid_or_foreign_spools_destinations_and_canceled_admission_never_move_or_replace() {
        for variant in 0..5 {
            let (temp, engine, _, mut stage, root, epoch) = launch_fixture();
            launched(&mut stage, &root, &epoch);
            let (mut spool, mut proof) = spool(temp.path());
            let target = stage
                .registry
                .root_path(&stage.record().unwrap())
                .join(NAME);
            let b = budget();
            match variant {
                0 => std::fs::write(&target, b"foreign").unwrap(),
                1 => {
                    proof.bytes = 0;
                }
                2 => {
                    std::fs::hard_link(&spool.path, temp.path().join("alias")).unwrap();
                }
                3 => b.cancel.cancel(),
                _ => {
                    proof.plan_sha256 = "bad".into();
                }
            }
            assert!(stage.register_layer_parts(&mut spool, &proof, &b).is_err());
            assert_eq!(stage.record().unwrap().schema, 8);
            assert!(spool.path.exists());
            if variant == 0 {
                assert_eq!(std::fs::read(&target).unwrap(), b"foreign");
            } else {
                assert!(!target.exists());
            }
            assert_eq!(engine.jobs.counts().export_staging, 128 << 30);
        }
    }
    #[test]
    fn changed_layer_or_unknown_stage_inventory_preserves_helper_and_staging_allowance() {
        for variant in 0..4 {
            let (temp, engine, _, mut stage, root, epoch) = launch_fixture();
            let enrolled = launched(&mut stage, &root, &epoch);
            let (mut spool, proof) = spool(temp.path());
            stage
                .register_layer_parts(&mut spool, &proof, &budget())
                .unwrap();
            collect(&mut stage, &root, &epoch, &enrolled, temp.path());
            let record = stage.record().unwrap();
            let target = stage.registry.root_path(&record).join(NAME);
            let helper = record.helper.as_ref().unwrap().path(engine.binding());
            match variant {
                0 => {
                    std::fs::remove_file(&target).unwrap();
                    std::fs::write(&target, b"foreign").unwrap();
                }
                1 => std::fs::set_permissions(&target, std::fs::Permissions::from_mode(0o600))
                    .unwrap(),
                2 => std::fs::hard_link(&target, temp.path().join("alias")).unwrap(),
                _ => std::fs::write(
                    stage.registry.root_path(&record).join("unknown"),
                    b"preserve",
                )
                .unwrap(),
            }
            assert!(stage.cleanup_retained(&budget()).is_err());
            assert!(helper.join("storage.raw").exists());
            assert!(target.exists());
            assert_eq!(engine.jobs.counts().export_staging, 128 << 30);
        }
    }
    #[test]
    fn layer_schema_cannot_be_downgraded_or_combined_with_bare_files() {
        let (temp, _, _, mut stage, root, epoch) = launch_fixture();
        launched(&mut stage, &root, &epoch);
        let (mut spool, proof) = spool(temp.path());
        let legacy = serde_json::to_value(stage.record().unwrap()).unwrap();
        assert!(legacy.get("layer").is_none());
        stage
            .register_layer_parts(&mut spool, &proof, &budget())
            .unwrap();
        let record = stage.record().unwrap();
        for schema in [1, 5, 8, 9, 11] {
            let mut changed = record.clone();
            changed.schema = schema;
            assert!(changed.valid(&stage.registry.binding).is_err());
        }
        let mut changed = record.clone();
        changed.layer = None;
        assert!(changed.valid(&stage.registry.binding).is_err());
        let mut changed = record;
        changed.files[0].name = "storage.raw".into();
        assert!(changed.valid(&stage.registry.binding).is_err());
    }
}
