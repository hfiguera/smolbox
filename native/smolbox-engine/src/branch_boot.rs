//! One explicit first restore of an owned branch child. Persisted process fields
//! never reconstruct manager ownership, complete initialization or permit replay.
use crate::{BranchPublication, Error, ErrorCode, Result};
use serde::{Deserialize, Serialize};
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
mod collection;
mod partial_disposal;
use collection::CollectionRecord;

const FILE_NAME: &str = "smolbox.branch-start-v1.json";
const MAX_BYTES: u64 = 64 * 1024;
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Directory {
    pub path: PathBuf,
    pub device: u64,
    pub inode: u64,
}

impl Directory {
    pub(crate) fn capture(root: &crate::export_source::Root) -> Result<Self> {
        root.verify()?;
        let metadata = root
            .descriptor()
            .metadata()
            .map_err(|_| Error::before(ErrorCode::Io))?;
        Ok(Self {
            path: root.path().into(),
            device: metadata.dev(),
            inode: metadata.ino(),
        })
    }
    fn verify(&self) -> Result<()> {
        let root = crate::export_source::Root::open(&self.path)?;
        if Self::capture(&root)? != *self {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Plan {
    pub schema: u8,
    pub publication: BranchPublication,
    pub source: Directory,
    pub child: Directory,
    pub snapshot: Directory,
    pub rootfs: Directory,
}
impl Plan {
    pub(crate) fn validate(&self) -> Result<()> {
        self.publication.validate()?;
        let binding = &self.publication.change.child_origin;
        if self.schema != 1
            || self.source.path.file_name()
                != Some(smolvm::agent::vm_dir_hash(&self.publication.previous.name).as_ref())
            || self.child.path
                != self
                    .source
                    .path
                    .parent()
                    .ok_or(Error::before(ErrorCode::Ownership))?
                    .join(smolvm::agent::vm_dir_hash(&binding.intent.child.name))
            || self.snapshot.path != self.source.path.join("s").join(&binding.generation)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        for directory in [&self.source, &self.child, &self.snapshot, &self.rootfs] {
            if !directory.path.is_absolute()
                || directory.path.as_os_str().len() > 4096
                || directory.inode == 0
            {
                return Err(Error::before(ErrorCode::Ownership));
            }
        }
        Ok(())
    }
    pub(crate) fn verify(&self) -> Result<()> {
        self.validate()?;
        for directory in [&self.source, &self.child, &self.snapshot, &self.rootfs] {
            directory.verify()?;
        }
        Ok(())
    }
    pub(crate) fn sdk_config(
        &self,
        record: &smolvm::config::VmRecord,
    ) -> Result<(smolvm::agent::VmResources, smolvm::agent::LaunchFeatures)> {
        self.validate()?;
        self.publication.change.child_origin.verify_record(record)?;
        if !self.publication.child().matches(record)?
            || record.state != smolvm::config::RecordState::Created
            || record.pid.is_some()
            || record.pid_start_time.is_some()
            || !record.forkpoint_held
            || !record.fork_env.is_empty()
            || record.image.is_some()
            || !record.ports.is_empty()
            || !record.mounts.is_empty()
            || !record.staged_mounts.is_empty()
            || !record.disks.is_empty()
            || record.cuda
            || record.gpu.unwrap_or(false)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        crate::checkpoint_capture::validate_branch_record(record)?;
        let resources = record.vm_resources();
        resources
            .validate()
            .map_err(|_| Error::before(ErrorCode::Validation))?;
        let features = smolvm::agent::LaunchFeatures {
            snapshot_dir: Some(self.snapshot.path.clone()),
            dns_filter_hosts: record.dns_filter_hosts.clone(),
            credentials: smolvm::credentials::CredentialLaunch::for_record(&record.name, record),
            uid_share_dir: Some(self.source.path.clone()),
            watch_parent: Some(true),
            ..Default::default()
        };
        Ok((resources, features))
    }
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "snake_case", deny_unknown_fields)]
enum Phase {
    Prepared,
    Entered {
        boot: crate::epoch::BootIntent,
    },
    Returned {
        boot: crate::epoch::BootIntent,
        child: Option<crate::OwnerIdentity>,
        sdk_succeeded: bool,
    },
    Initializing {
        intent: crate::branch_identity::Intent,
    },
    IdentityReady {
        intent: crate::branch_identity::Intent,
        identity_sha256: String,
    },
    HeldReady {
        intent: crate::branch_identity::Intent,
        identity_sha256: String,
    },
    Releasing {
        intent: Box<crate::branch_release::Intent>,
    },
    Released {
        intent: Box<crate::branch_release::Intent>,
    },
    Initialized {
        boot: crate::epoch::BootIntent,
        child: crate::OwnerIdentity,
        identity_sha256: String,
    },
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Journal {
    plan: Plan,
    phase: Phase,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    collection: Option<CollectionRecord>,
}
impl Journal {
    fn validate(&self) -> Result<()> {
        self.plan.validate()?;
        if let Some(record) = &self.collection {
            record.validate(&self.plan, &self.phase)?;
        }
        match &self.phase {
            Phase::Prepared => {}
            Phase::Releasing { intent } | Phase::Released { intent } => {
                intent.validate()?;
                if intent.transition.previous != *self.plan.publication.child()
                    || intent.transition.change.binding != self.plan.publication.change.child_origin
                {
                    return Err(Error::before(ErrorCode::Ownership));
                }
            }
            Phase::Initializing { intent }
            | Phase::IdentityReady { intent, .. }
            | Phase::HeldReady { intent, .. } => {
                intent.validate()?;
                if !intent.boot.matches(
                    &self.plan.publication.child().name,
                    &self.plan.publication.change.child_origin.intent.epoch,
                ) {
                    return Err(Error::before(ErrorCode::Ownership));
                }
            }
            Phase::Entered { boot }
            | Phase::Returned { boot, .. }
            | Phase::Initialized { boot, .. } => {
                if !boot.matches(
                    &self.plan.publication.child().name,
                    &self.plan.publication.change.child_origin.intent.epoch,
                ) {
                    return Err(Error::before(ErrorCode::Ownership));
                }
            }
        }
        if let Phase::IdentityReady {
            intent,
            identity_sha256,
        }
        | Phase::HeldReady {
            intent,
            identity_sha256,
        } = &self.phase
        {
            if *identity_sha256 != intent.digest()? {
                return Err(Error::before(ErrorCode::Ownership));
            }
        }
        if let Phase::Returned {
            child: Some(child), ..
        } = &self.phase
        {
            if child.pid <= 0 || child.birth == 0 || child.uid != unsafe { libc::geteuid() } {
                return Err(Error::before(ErrorCode::Ownership));
            }
        }
        if let Phase::Initialized {
            child,
            identity_sha256,
            ..
        } = &self.phase
        {
            if child.pid <= 0
                || child.birth == 0
                || child.uid != unsafe { libc::geteuid() }
                || !crate::domain::valid_hex(identity_sha256, 64)
            {
                return Err(Error::before(ErrorCode::Ownership));
            }
        }
        Ok(())
    }
}
pub(crate) struct Lifecycle {
    directory: PathBuf,
}
impl Lifecycle {
    pub(crate) fn at(directory: &Path) -> Self {
        Self {
            directory: directory.into(),
        }
    }
    /// Missing boot intent or an exact prepared-only plan never authorizes
    /// collection. Disposal must additionally retain its original no-boot owner.
    pub(crate) fn unentered(
        &self,
        publication: &BranchPublication,
        child: &crate::export_source::Root,
    ) -> Result<()> {
        child.verify()?;
        if child.path() != self.directory {
            return Err(Error::before(ErrorCode::Ownership));
        }
        match self.read_active() {
            Err(error) if error.code == ErrorCode::NotFound => Ok(()),
            Ok((journal, _))
                if journal.plan.publication == *publication
                    && journal.plan.child == Directory::capture(child)?
                    && matches!(journal.phase, Phase::Prepared) =>
            {
                Ok(())
            }
            _ => Err(Error::before(ErrorCode::Ownership)),
        }
    }
    pub(crate) fn prepare(&self, plan: &Plan) -> Result<()> {
        plan.verify()?;
        if plan.child.path != self.directory {
            return Err(Error::before(ErrorCode::Ownership));
        }
        match self.read_active() {
            Ok((previous, _))
                if previous.plan == *plan && matches!(previous.phase, Phase::Prepared) =>
            {
                Ok(())
            }
            Ok(_) => Err(Error::before(ErrorCode::State)),
            Err(error) if error.code == ErrorCode::NotFound => self.write(
                &Journal {
                    plan: plan.clone(),
                    phase: Phase::Prepared,
                    collection: None,
                },
                None,
            ),
            Err(error) => Err(error),
        }
    }
    pub(crate) fn enter(
        &self,
        plan: &Plan,
        dispatch: &crate::epoch::BootDispatch,
        epoch: &crate::epoch::ActorEpoch,
    ) -> Result<()> {
        plan.verify()?;
        let (mut journal, version) = self.read_active()?;
        if journal.plan != *plan
            || !matches!(journal.phase, Phase::Prepared)
            || !dispatch.matches_epoch(&plan.publication.child().name, epoch)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        journal.phase = Phase::Entered {
            boot: dispatch.intent(),
        };
        self.write(&journal, Some(version))
            .map_err(|e| Error::uncertain(e.code))
    }
    pub(crate) fn returned(
        &self,
        plan: &Plan,
        boot: &crate::epoch::BootIntent,
        enrollment: Option<&crate::epoch::BootEnrollment>,
        succeeded: bool,
    ) -> Result<()> {
        let (mut journal, version) = self.read_active()?;
        let Phase::Entered { boot: previous } = &journal.phase else {
            return Err(Error::uncertain(ErrorCode::State));
        };
        if journal.plan != *plan
            || previous != boot
            || enrollment.is_some_and(|enrolled| enrolled.intent() != boot)
        {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        journal.phase = Phase::Returned {
            boot: boot.clone(),
            child: enrollment.map(|enrolled| enrolled.child()),
            sdk_succeeded: succeeded,
        };
        self.write(&journal, Some(version))
            .map_err(|e| Error::uncertain(e.code))
    }
    pub(crate) fn enter_identity(
        &self,
        plan: &Plan,
        intent: &crate::branch_identity::Intent,
        enrollment: &crate::epoch::BootEnrollment,
    ) -> Result<()> {
        plan.verify()?;
        let (mut journal, version) = self.read_active()?;
        let Phase::Returned {
            boot,
            child: Some(child),
            sdk_succeeded: true,
        } = &journal.phase
        else {
            return Err(Error::before(ErrorCode::State));
        };
        if journal.plan != *plan
            || boot != enrollment.intent()
            || *child != enrollment.child()
            || !intent.matches(&plan.publication.child().name, enrollment)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        journal.phase = Phase::Initializing {
            intent: intent.clone(),
        };
        self.write(&journal, Some(version))
            .map_err(|e| Error::uncertain(e.code))
    }
    pub(crate) fn identity_ready(
        &self,
        plan: &Plan,
        enrollment: &crate::epoch::BootEnrollment,
        proof: &crate::branch_identity::Verified,
    ) -> Result<()> {
        let (mut journal, version) = self.read_active()?;
        let Phase::Initializing { intent } = &journal.phase else {
            return Err(Error::uncertain(ErrorCode::State));
        };
        if journal.plan != *plan
            || !intent.matches(&plan.publication.child().name, enrollment)
            || !proof.matches(intent)
        {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        journal.phase = Phase::IdentityReady {
            intent: intent.clone(),
            identity_sha256: proof.digest().into(),
        };
        self.write(&journal, Some(version))
            .map_err(|e| Error::uncertain(e.code))
    }
    pub(crate) fn enter_release(
        &self,
        plan: &Plan,
        intent: &crate::branch_release::Intent,
        enrollment: &crate::epoch::BootEnrollment,
    ) -> Result<()> {
        intent.validate()?;
        let (mut journal, version) = self.read_active()?;
        let (Phase::IdentityReady {
            intent: identity,
            identity_sha256,
        }
        | Phase::HeldReady {
            intent: identity,
            identity_sha256,
        }) = &journal.phase
        else {
            return Err(Error::before(ErrorCode::State));
        };
        if journal.plan != *plan
            || !intent.matches(enrollment)
            || !identity.matches(&plan.publication.child().name, enrollment)
            || intent.transition.change.identity_sha256 != *identity_sha256
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        journal.phase = Phase::Releasing {
            intent: Box::new(intent.clone()),
        };
        self.write(&journal, Some(version))
            .map_err(|e| Error::uncertain(e.code))
    }
    pub(crate) fn authorize_release(
        &self,
        plan: &Plan,
        intent: &crate::branch_release::Intent,
        enrollment: &crate::epoch::BootEnrollment,
    ) -> Result<()> {
        let (journal, _) = self.read_active()?;
        if journal.plan != *plan
            || !intent.matches(enrollment)
            || !matches!(&journal.phase, Phase::Releasing { intent: actual } if actual.as_ref() == intent)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
    pub(crate) fn released(
        &self,
        plan: &Plan,
        intent: &crate::branch_release::Intent,
        enrollment: &crate::epoch::BootEnrollment,
    ) -> Result<()> {
        self.authorize_release(plan, intent, enrollment)?;
        let recorded = crate::material::MaterialJournal::at(&self.directory)
            .completed_branch_release(
                &intent.transition.previous,
                &intent.transition.change.request,
            )?;
        if recorded.as_ref() != Some(&intent.transition) {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        let (mut journal, version) = self.read_active()?;
        journal.phase = Phase::Released {
            intent: Box::new(intent.clone()),
        };
        self.write(&journal, Some(version))
            .map_err(|e| Error::uncertain(e.code))
    }
    pub(crate) fn completed_release(
        &self,
        plan: &Plan,
        request: &crate::BranchReleaseRequest,
        enrollment: &crate::epoch::BootEnrollment,
    ) -> Result<Option<crate::BranchReleaseTransition>> {
        request.validate()?;
        let (journal, _) = self.read_active()?;
        if journal.plan != *plan {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let Phase::Released { intent } = journal.phase else {
            return Ok(None);
        };
        if !intent.matches(enrollment) || intent.transition.change.request != *request {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let recorded = crate::material::MaterialJournal::at(&self.directory)
            .completed_branch_release(&intent.transition.previous, request)?;
        if recorded.as_ref() != Some(&intent.transition) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(recorded)
    }
    pub(crate) fn finish_record(
        &self,
        plan: &Plan,
        enrollment: &crate::epoch::BootEnrollment,
        identity_sha256: &str,
    ) -> Result<(
        crate::CreationReceipt,
        bool,
        Option<crate::BranchReleaseTransition>,
    )> {
        let (mut journal, version) = self.read_active()?;
        if journal.plan != *plan {
            return Err(Error::before(ErrorCode::Ownership));
        }
        match &journal.phase {
            Phase::IdentityReady {
                intent,
                identity_sha256: actual,
            }
            | Phase::HeldReady {
                intent,
                identity_sha256: actual,
            } => {
                if !plan.publication.change.child_origin.intent.child.hold
                    || !intent.matches(&plan.publication.child().name, enrollment)
                    || actual != identity_sha256
                {
                    return Err(Error::before(ErrorCode::Ownership));
                }
                if matches!(journal.phase, Phase::IdentityReady { .. }) {
                    journal.phase = Phase::HeldReady {
                        intent: intent.clone(),
                        identity_sha256: actual.clone(),
                    };
                    self.write(&journal, Some(version))
                        .map_err(|e| Error::uncertain(e.code))?;
                }
                Ok((plan.publication.child().clone(), true, None))
            }
            Phase::Released { intent } => {
                if !intent.matches(enrollment)
                    || intent.transition.change.identity_sha256 != identity_sha256
                {
                    return Err(Error::before(ErrorCode::Ownership));
                }
                let release = self
                    .completed_release(plan, &intent.transition.change.request, enrollment)?
                    .ok_or(Error::before(ErrorCode::Ownership))?;
                Ok((release.receipt.clone(), false, Some(release)))
            }
            _ => Err(Error::before(ErrorCode::State)),
        }
    }
    /// IdentityReady alone cannot permit cold restart. Explicit release and
    /// final initialized publication must precede ordinary lifecycle ownership.
    pub(crate) fn require_regular_restart(&self, receipt: &crate::CreationReceipt) -> Result<()> {
        let (journal, _) = self.read_active()?;
        let mut origin = journal.plan.publication.child().clone();
        origin.material = None;
        crate::material::check_origin(&origin, receipt)?;
        if !matches!(journal.phase, Phase::Released { .. }) {
            return Err(Error::before(ErrorCode::State));
        }
        Ok(())
    }
    pub(crate) fn uncertain(&self, receipt: &crate::CreationReceipt) -> Result<bool> {
        match self.read() {
            Ok((journal, _)) => {
                let mut origin = journal.plan.publication.child().clone();
                origin.material = None;
                crate::material::check_origin(&origin, receipt)?;
                Ok(journal.collection.is_some()
                    || !matches!(
                        journal.phase,
                        Phase::Released { .. } | Phase::HeldReady { .. }
                    ))
            }
            Err(error) if error.code == ErrorCode::NotFound => Ok(true),
            Err(error) => Err(error),
        }
    }
    fn read_active(&self) -> Result<(Journal, crate::checkpoint_materialize::FileVersion)> {
        let record = self.read()?;
        if record.0.collection.is_some() {
            return Err(Error::before(ErrorCode::State));
        }
        Ok(record)
    }
    fn read(&self) -> Result<(Journal, crate::checkpoint_materialize::FileVersion)> {
        let path = self.directory.join(FILE_NAME);
        crate::host::unredirected(&self.directory)?;
        let mut file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
            .open(path)
            .map_err(|e| {
                Error::before(if e.kind() == std::io::ErrorKind::NotFound {
                    ErrorCode::NotFound
                } else {
                    ErrorCode::Ownership
                })
            })?;
        let metadata = file.metadata().map_err(|_| Error::before(ErrorCode::Io))?;
        if !metadata.is_file()
            || metadata.nlink() != 1
            || metadata.uid() != unsafe { libc::geteuid() }
            || metadata.mode() & 0o777 != 0o600
            || metadata.len() > MAX_BYTES
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let version = crate::checkpoint_materialize::FileVersion::of(&metadata);
        let mut bytes = Vec::new();
        std::io::Read::by_ref(&mut file)
            .take(MAX_BYTES + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| Error::before(ErrorCode::Io))?;
        let journal: Journal =
            serde_json::from_slice(&bytes).map_err(|_| Error::before(ErrorCode::Ownership))?;
        journal.validate()?;
        if journal.plan.child.path != self.directory {
            return Err(Error::before(ErrorCode::Ownership));
        }
        if crate::checkpoint_materialize::FileVersion::of(
            &file.metadata().map_err(|_| Error::before(ErrorCode::Io))?,
        ) != version
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        if crate::checkpoint_materialize::FileVersion::of(
            &std::fs::symlink_metadata(self.directory.join(FILE_NAME))
                .map_err(|_| Error::before(ErrorCode::Ownership))?,
        ) != version
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok((journal, version))
    }
    fn write(
        &self,
        journal: &Journal,
        previous: Option<crate::checkpoint_materialize::FileVersion>,
    ) -> Result<()> {
        journal.validate()?;
        journal.plan.verify()?;
        let bytes = serde_json::to_vec(journal).map_err(|_| Error::before(ErrorCode::Io))?;
        if bytes.len() as u64 > MAX_BYTES {
            return Err(Error::before(ErrorCode::Admission));
        }
        let mut file = tempfile::NamedTempFile::new_in(&self.directory)
            .map_err(|_| Error::before(ErrorCode::Io))?;
        file.write_all(&bytes)
            .and_then(|()| file.as_file().sync_all())
            .map_err(|_| Error::before(ErrorCode::Io))?;
        let path = self.directory.join(FILE_NAME);
        if let Some(previous) = previous {
            if self.read()?.1 != previous {
                return Err(Error::before(ErrorCode::Ownership));
            }
            file.persist(&path)
                .map_err(|_| Error::before(ErrorCode::Io))?;
        } else {
            file.persist_noclobber(&path)
                .map_err(|_| Error::before(ErrorCode::Io))?;
        }
        File::open(&self.directory)
            .and_then(|file| file.sync_all())
            .map_err(|_| Error::before(ErrorCode::Io))
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    struct Model {
        _temp: tempfile::TempDir,
        engine: crate::Engine,
        record: smolvm::config::VmRecord,
        plan: Plan,
    }
    impl Model {
        fn new() -> Self {
            Self::with_hold(false)
        }
        fn with_hold(hold: bool) -> Self {
            let (temp, engine, publication, record) =
                crate::branch_material::tests::publication_model_with_hold(hold);
            let source = engine.vm_directory(&publication.previous.name);
            let child = engine.vm_directory(&publication.child().name);
            let snapshot = source
                .join("s")
                .join(&publication.change.child_origin.generation);
            let rootfs = temp
                .path()
                .canonicalize()
                .unwrap()
                .join("agent-rootfs-model");
            for path in [source.join("s"), snapshot.clone(), rootfs.clone()] {
                std::fs::create_dir(&path).unwrap();
                std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700)).unwrap();
            }
            let capture = |path: &Path| {
                Directory::capture(&crate::export_source::Root::open(path).unwrap()).unwrap()
            };
            let plan = Plan {
                schema: 1,
                publication,
                source: capture(&source),
                child: capture(&child),
                snapshot: capture(&snapshot),
                rootfs: capture(&rootfs),
            };
            Self {
                _temp: temp,
                engine,
                record,
                plan,
            }
        }
        fn lifecycle(&self) -> Lifecycle {
            Lifecycle::at(&self.plan.child.path)
        }
        fn epoch(&self, epoch: String) -> (tempfile::TempDir, crate::epoch::ActorEpoch) {
            let temp = tempfile::tempdir().unwrap();
            let (_, _, actor) = crate::epoch::tests::fixture_for_binding_and_epoch(
                &temp.path().canonicalize().unwrap(),
                None,
                self.engine.binding().clone(),
                epoch,
            );
            (temp, actor)
        }
    }

    pub(crate) struct IdentityModel {
        pub _temp: tempfile::TempDir,
        pub _epoch: tempfile::TempDir,
        pub actors: crate::epoch::ActorEpoch,
        pub engine: crate::Engine,
        pub plan: Plan,
        pub record: smolvm::config::VmRecord,
        pub enrollment: crate::epoch::BootEnrollment,
        pub identity_sha256: String,
    }
    /// Private file/row state only, with synthetic process and guest facts.
    pub(crate) fn identity_model(hold: bool) -> IdentityModel {
        let model = Model::with_hold(hold);
        let lifecycle = model.lifecycle();
        lifecycle.prepare(&model.plan).unwrap();
        let (epoch_root, epoch) = model.epoch(
            model
                .plan
                .publication
                .change
                .child_origin
                .intent
                .epoch
                .clone(),
        );
        let dispatch = epoch.begin_boot(&model.record.name).unwrap();
        lifecycle.enter(&model.plan, &dispatch, &epoch).unwrap();
        let boot = dispatch.intent();
        let enrollment = crate::epoch::tests::complete_model(dispatch);
        lifecycle
            .returned(&model.plan, &boot, Some(&enrollment), true)
            .unwrap();
        let identity =
            crate::branch_identity::Intent::new(&model.record.name, &enrollment).unwrap();
        lifecycle
            .enter_identity(&model.plan, &identity, &enrollment)
            .unwrap();
        lifecycle
            .identity_ready(
                &model.plan,
                &enrollment,
                &crate::branch_identity::tests::confirmed_model(&identity),
            )
            .unwrap();
        let mut record = model.record;
        record.state = smolvm::config::RecordState::Running;
        record.pid = Some(enrollment.child().pid);
        record.pid_start_time = Some(enrollment.child().birth);
        model
            .engine
            .db
            .update_vm(&record.name, |actual| *actual = record.clone())
            .unwrap();
        IdentityModel {
            _temp: model._temp,
            _epoch: epoch_root,
            actors: epoch,
            engine: model.engine,
            plan: model.plan,
            record,
            enrollment,
            identity_sha256: identity.digest().unwrap(),
        }
    }
    #[test]
    fn held_completion_is_idempotent_observation_but_never_restart_or_command_authority() {
        let model = identity_model(true);
        let lifecycle = Lifecycle::at(&model.plan.child.path);
        let (child, held, release) = lifecycle
            .finish_record(&model.plan, &model.enrollment, &model.identity_sha256)
            .unwrap();
        assert!(held && release.is_none());
        assert_eq!(child, *model.plan.publication.child());
        assert!(!lifecycle.uncertain(&child).unwrap());
        assert!(lifecycle.require_regular_restart(&child).is_err());
        assert!(model.engine.guest_work_record(&child).is_err());
        assert_eq!(
            model.engine.stop(&child).unwrap_err().dispatch,
            crate::Dispatch::NotDispatched
        );
        let path = model.plan.child.path.join(FILE_NAME);
        let bytes = std::fs::read(&path).unwrap();
        lifecycle
            .finish_record(&model.plan, &model.enrollment, &model.identity_sha256)
            .unwrap();
        assert_eq!(std::fs::read(path).unwrap(), bytes);
        let completion = crate::BranchCompletion {
            schema: 1,
            publication: model.plan.publication.clone(),
            child,
            identity_sha256: model.identity_sha256.clone(),
            held,
            release,
        };
        completion.validate().unwrap();
        let mut changed = completion;
        changed.held = false;
        assert!(changed.validate().is_err());
    }
    #[test]
    fn automatic_creation_cannot_complete_as_held_or_invent_release_from_a_flag() {
        let model = identity_model(false);
        let lifecycle = Lifecycle::at(&model.plan.child.path);
        assert!(lifecycle
            .finish_record(&model.plan, &model.enrollment, &model.identity_sha256)
            .is_err());
        let mut changed = model.record.clone();
        changed.forkpoint_held = false;
        model
            .engine
            .db
            .update_vm(&changed.name, |actual| *actual = changed.clone())
            .unwrap();
        assert!(lifecycle
            .finish_record(&model.plan, &model.enrollment, &model.identity_sha256)
            .is_err());
        assert!(lifecycle.uncertain(model.plan.publication.child()).unwrap());
    }

    #[test]
    fn first_restore_selects_original_snapshot_and_uid_share_without_cold_fallback() {
        let model = Model::new();
        model.plan.verify().unwrap();
        let (_, features) = model.plan.sdk_config(&model.record).unwrap();
        assert_eq!(
            features.snapshot_dir.as_ref(),
            Some(&model.plan.snapshot.path)
        );
        assert_eq!(
            features.uid_share_dir.as_ref(),
            Some(&model.plan.source.path)
        );
        assert_eq!(features.watch_parent, Some(true));
        assert!(!features.forkable);
        let mut changed = model.record.clone();
        changed.forkpoint_held = false;
        assert!(model.plan.sdk_config(&changed).is_err());
        let mut changed = model.plan.clone();
        changed.snapshot.path = model.plan.child.path.join("s/aabbccdd");
        assert!(changed.validate().is_err());
        let old = model.plan.rootfs.path.with_extension("old");
        std::fs::rename(&model.plan.rootfs.path, old).unwrap();
        std::fs::create_dir(&model.plan.rootfs.path).unwrap();
        std::fs::set_permissions(
            &model.plan.rootfs.path,
            std::fs::Permissions::from_mode(0o700),
        )
        .unwrap();
        assert!(model.plan.verify().is_err());
    }

    #[test]
    fn entered_and_returned_boots_cannot_replay_or_claim_initialized_readiness() {
        let model = Model::new();
        let lifecycle = model.lifecycle();
        assert!(lifecycle.uncertain(model.plan.publication.child()).unwrap());
        lifecycle.prepare(&model.plan).unwrap();
        lifecycle.prepare(&model.plan).unwrap();
        let (_epoch_root, epoch) = model.epoch(
            model
                .plan
                .publication
                .change
                .child_origin
                .intent
                .epoch
                .clone(),
        );
        let dispatch = epoch.begin_boot(&model.record.name).unwrap();
        lifecycle.enter(&model.plan, &dispatch, &epoch).unwrap();
        assert!(lifecycle.prepare(&model.plan).is_err());
        assert!(lifecycle.enter(&model.plan, &dispatch, &epoch).is_err());
        let intent = dispatch.intent();
        // Typed enrollment model only: no SDK call, real child or guest reset.
        let enrollment = crate::epoch::tests::complete_model(dispatch);
        lifecycle
            .returned(&model.plan, &intent, Some(&enrollment), true)
            .unwrap();
        assert!(lifecycle
            .returned(&model.plan, &intent, Some(&enrollment), true)
            .is_err());
        assert!(lifecycle.uncertain(model.plan.publication.child()).unwrap());
        assert!(lifecycle
            .require_regular_restart(model.plan.publication.child())
            .is_err());
        assert!(lifecycle.prepare(&model.plan).is_err());
    }

    #[test]
    fn foreign_epoch_and_original_sdk_failure_remain_unresolved() {
        let model = Model::new();
        let lifecycle = model.lifecycle();
        lifecycle.prepare(&model.plan).unwrap();
        let (_foreign_root, foreign) = model.epoch("f".repeat(32));
        let dispatch = foreign.begin_boot(&model.record.name).unwrap();
        assert!(lifecycle.enter(&model.plan, &dispatch, &foreign).is_err());
        assert!(matches!(lifecycle.read().unwrap().0.phase, Phase::Prepared));
        drop(dispatch);
        let (_epoch_root, epoch) = model.epoch(
            model
                .plan
                .publication
                .change
                .child_origin
                .intent
                .epoch
                .clone(),
        );
        let dispatch = epoch.begin_boot(&model.record.name).unwrap();
        lifecycle.enter(&model.plan, &dispatch, &epoch).unwrap();
        lifecycle
            .returned(&model.plan, &dispatch.intent(), None, false)
            .unwrap();
        assert!(lifecycle.uncertain(model.plan.publication.child()).unwrap());
        assert!(lifecycle.prepare(&model.plan).is_err());
        assert!(lifecycle
            .require_regular_restart(model.plan.publication.child())
            .is_err());
    }

    #[test]
    fn reserved_initialized_phase_never_grants_restart_without_release_material() {
        let model = Model::new();
        let lifecycle = model.lifecycle();
        lifecycle.prepare(&model.plan).unwrap();
        let (_epoch_root, epoch) = model.epoch(
            model
                .plan
                .publication
                .change
                .child_origin
                .intent
                .epoch
                .clone(),
        );
        let dispatch = epoch.begin_boot(&model.record.name).unwrap();
        lifecycle.enter(&model.plan, &dispatch, &epoch).unwrap();
        let enrollment = crate::epoch::tests::complete_model(dispatch);
        let (mut journal, version) = lifecycle.read().unwrap();
        // The earlier reserved reader shape carried no actual release proof.
        // Preserve parsing without treating it as initialization authority.
        journal.phase = Phase::Initialized {
            boot: enrollment.intent().clone(),
            child: enrollment.child(),
            identity_sha256: "a".repeat(64),
        };
        lifecycle.write(&journal, Some(version)).unwrap();
        assert!(lifecycle
            .require_regular_restart(model.plan.publication.child())
            .is_err());
        assert!(lifecycle.uncertain(model.plan.publication.child()).unwrap());
        let mut foreign = model.plan.publication.child().clone();
        foreign.owner_token = "f".repeat(32);
        assert!(lifecycle.require_regular_restart(&foreign).is_err());
        if let Phase::Initialized { child, .. } = &mut journal.phase {
            child.birth = 0;
        }
        assert!(journal.validate().is_err());
    }

    #[test]
    fn protected_journal_rejects_linked_writable_and_foreign_bytes_without_overwrite() {
        let model = Model::new();
        let lifecycle = model.lifecycle();
        lifecycle.prepare(&model.plan).unwrap();
        let path = model.plan.child.path.join(FILE_NAME);
        let bytes = std::fs::read(&path).unwrap();
        let alias = model.plan.child.path.join("linked-model");
        std::fs::hard_link(&path, &alias).unwrap();
        assert!(lifecycle.prepare(&model.plan).is_err());
        std::fs::remove_file(alias).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o620)).unwrap();
        assert!(lifecycle.prepare(&model.plan).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), bytes);
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        std::fs::write(&path, b"foreign-model").unwrap();
        assert!(lifecycle.prepare(&model.plan).is_err());
        assert_eq!(std::fs::read(path).unwrap(), b"foreign-model");
    }

    #[test]
    fn guest_initialization_requires_original_enrollment_and_cannot_enable_cold_restart_or_replay()
    {
        let model = Model::new();
        let lifecycle = model.lifecycle();
        lifecycle.prepare(&model.plan).unwrap();
        let (_epoch_root, epoch) = model.epoch(
            model
                .plan
                .publication
                .change
                .child_origin
                .intent
                .epoch
                .clone(),
        );
        let dispatch = epoch.begin_boot(&model.record.name).unwrap();
        lifecycle.enter(&model.plan, &dispatch, &epoch).unwrap();
        let boot = dispatch.intent();
        let enrolled = crate::epoch::tests::complete_model(dispatch);
        let intent = crate::branch_identity::Intent::new(&model.record.name, &enrolled).unwrap();
        assert!(lifecycle
            .enter_identity(&model.plan, &intent, &enrolled)
            .is_err());
        lifecycle
            .returned(&model.plan, &boot, Some(&enrolled), true)
            .unwrap();
        let (_foreign_root, foreign_epoch) = model.epoch("e".repeat(32));
        let foreign = crate::epoch::tests::complete_model(
            foreign_epoch.begin_boot(&model.record.name).unwrap(),
        );
        let crossed = crate::branch_identity::Intent::new(&model.record.name, &foreign).unwrap();
        assert!(lifecycle
            .enter_identity(&model.plan, &crossed, &foreign)
            .is_err());
        lifecycle
            .enter_identity(&model.plan, &intent, &enrolled)
            .unwrap();
        assert!(lifecycle
            .enter_identity(&model.plan, &intent, &enrolled)
            .is_err());
        let crossed_proof = crate::branch_identity::tests::confirmed_model(&crossed);
        assert!(lifecycle
            .identity_ready(&model.plan, &enrolled, &crossed_proof)
            .is_err());
        let proof = crate::branch_identity::tests::confirmed_model(&intent);
        lifecycle
            .identity_ready(&model.plan, &enrolled, &proof)
            .unwrap();
        assert!(lifecycle
            .identity_ready(&model.plan, &enrolled, &proof)
            .is_err());
        assert!(lifecycle
            .enter_identity(&model.plan, &intent, &enrolled)
            .is_err());
        assert!(lifecycle.uncertain(model.plan.publication.child()).unwrap());
        assert!(lifecycle
            .require_regular_restart(model.plan.publication.child())
            .is_err());
        let (mut journal, _) = lifecycle.read().unwrap();
        if let Phase::IdentityReady {
            identity_sha256, ..
        } = &mut journal.phase
        {
            *identity_sha256 = "f".repeat(64);
        }
        assert!(journal.validate().is_err());
    }
}
