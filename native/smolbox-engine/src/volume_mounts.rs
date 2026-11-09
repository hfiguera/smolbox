//! Proof-bound mount qualification. Paths alone never select an SDK mount.
//! Opaque handles retain descriptors, domain ownership and ordered volume gates.
use super::super::{cstring, existing_ledger, open_directory, require_absent};
use super::{inspect, VolumeProvisionPresence, VolumeProvisionReceipt};
use crate::{
    DomainBinding, Engine, Error, ErrorCode, LocalVolumePolicy, QualifiedVolumeRoot, ReadBudget,
    Result,
};
use serde::{Deserialize, Serialize};
use std::fs::File;
use std::path::PathBuf;
use std::sync::Arc;

pub const VOLUME_MOUNTS: usize = 8;

/// Operator-selected policy and requested immutable proofs, before qualification.
/// This is intent only; an opaque handle is still required before SDK entry.
pub struct VolumeMountSelection {
    pub policy: LocalVolumePolicy,
    pub requests: Vec<VolumeMountRequest>,
}
impl VolumeMountSelection {
    pub(crate) fn validate(&self, binding: &DomainBinding) -> Result<()> {
        validate(&self.policy, binding, &self.requests)
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct VolumeMountRequest {
    pub proof: VolumeProvisionReceipt,
    pub target: String,
    pub readonly: bool,
}
impl std::fmt::Debug for VolumeMountRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("VolumeMountRequest")
            .field("readonly", &self.readonly)
            .finish_non_exhaustive()
    }
}
impl VolumeMountRequest {
    pub fn validate(&self) -> Result<()> {
        self.proof.validate()?;
        if self.target.len() > 4096
            || !self.target.starts_with("/mnt/volumes/")
            || self.target.ends_with('/')
            || self.target.contains('\0')
            || self.target.contains('\\')
            || self.target.contains("//")
            || self
                .target
                .split('/')
                .any(|part| matches!(part, "." | ".."))
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(())
    }
}

struct Backing {
    request: VolumeMountRequest,
    directory: File,
}

/// Not constructible from serialized proof or inventory. Keep alive through
/// native record publication; retained SDK mounts then exclude volume deletion.
pub struct QualifiedVolumeMounts {
    root: QualifiedVolumeRoot,
    binding: DomainBinding,
    domain: PathBuf,
    backings: Vec<Backing>,
    _guards: Vec<crate::gate::MachineLease>,
    domain_guard: Option<Arc<crate::domain::DomainGuard>>,
}

/// A confirmed running VMM holds its guest mount state. Retain cooperating-
/// writer exclusion and full proof through worker collection, while closing
/// parent root/backing descriptors before worker FD admission.
pub(crate) struct MountedWorkerAuthority {
    _requests: Vec<VolumeMountRequest>,
    _guards: Vec<crate::gate::MachineLease>,
    _domain_guard: Option<Arc<crate::domain::DomainGuard>>,
}
impl std::fmt::Debug for QualifiedVolumeMounts {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("QualifiedVolumeMounts")
            .field("count", &self.backings.len())
            .finish_non_exhaustive()
    }
}

impl Engine {
    /// Qualify before the machine gate, preserving the global volume/machine
    /// order. Running work later rechecks the same handle under its machine gate.
    pub(crate) fn worker_mounts(
        &self,
        receipt: &crate::CreationReceipt,
        record: &smolvm::config::VmRecord,
        policy: Option<&LocalVolumePolicy>,
        budget: &ReadBudget,
    ) -> Result<Option<QualifiedVolumeMounts>> {
        self.verify_record(receipt, record)?;
        let journal = crate::material::MaterialJournal::at(&self.vm_directory(&receipt.name));
        match journal.mount_material(receipt, record)? {
            Some(material) => {
                let policy = policy.ok_or(Error::before(ErrorCode::Ownership))?;
                let mounts = self.qualify_volume_mounts(policy, &material.mounts, budget)?;
                self.verify_machine_mounts(receipt, record, &mounts, budget)?;
                Ok(Some(mounts))
            }
            None => Ok(None),
        }
    }

    /// A confirmed running guest already holds its mount state. Close parent
    /// descriptors before worker preparation; retain gates/proof with the job.
    pub(crate) fn reserve_mounted_worker(
        &self,
        receipt: &crate::CreationReceipt,
        mounts: Option<QualifiedVolumeMounts>,
        demand: crate::jobs::Demand,
        budget: &ReadBudget,
    ) -> Result<(crate::jobs::JobLease, Option<MountedWorkerAuthority>)> {
        match mounts {
            Some(mut mounts) => {
                let record = self.record(receipt)?;
                self.verify_machine_mounts(receipt, &record, &mounts, budget)?;
                if self.inspect(receipt)?.state != crate::ObservedState::Running {
                    return Err(Error::before(ErrorCode::State));
                }
                let permit = mounts.take_worker_lease(demand)?;
                Ok((permit, Some(mounts.into_worker_authority()?)))
            }
            None => Ok((self.jobs.acquire(demand)?, None)),
        }
    }
    /// Bind freshly prepared SDK configuration to this engine's qualified
    /// volume handle. This changes only an in-memory record; it cannot publish
    /// ownership, initialize an existing machine journal or bypass admission.
    pub fn bind_volume_mount_material(
        &self,
        mounts: &QualifiedVolumeMounts,
        record: &mut smolvm::config::VmRecord,
        budget: &ReadBudget,
    ) -> Result<crate::MountMaterial> {
        if !record.mounts.is_empty()
            || !record.staged_mounts.is_empty()
            || record
                .labels
                .contains_key(crate::mount_material::MOUNT_LABEL)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let records = self.volume_record_mounts(mounts, budget)?;
        let material = crate::MountMaterial {
            schema: 1,
            mounts: mounts
                .backings
                .iter()
                .map(|backing| backing.request.clone())
                .collect(),
        };
        let digest = material.digest()?;
        record.mounts = records;
        record
            .labels
            .insert(crate::mount_material::MOUNT_LABEL.into(), digest);
        Ok(material)
    }
    /// Linux, exact operator policy, completed private provisioning proof and
    /// one retained descriptor per exclusive volume. No SDK/database mutation.
    pub fn qualify_volume_mounts(
        &self,
        policy: &LocalVolumePolicy,
        requests: &[VolumeMountRequest],
        budget: &ReadBudget,
    ) -> Result<QualifiedVolumeMounts> {
        validate(policy, self.binding(), requests)?;
        self.binding().validate()?;
        budget.check()?;
        if !cfg!(target_os = "linux") {
            return Err(Error::before(ErrorCode::Unsupported));
        }
        let lease = self
            .jobs
            .acquire(crate::jobs::Demand::volume_mounts(requests.len())?)?;
        self.domain.verify()?;
        let mut root =
            QualifiedVolumeRoot::open(policy, &LocalVolumePolicy::canonical_sdk_root()?, budget)?;
        root._lease = Some(lease);
        // Public target order differs from gate order. All callers lock generated
        // volume IDs in the same order; partial acquisition releases on rejection.
        let mut ids: Vec<&str> = requests
            .iter()
            .map(|request| request.proof.backing.intent.worker_volume_id.as_str())
            .collect();
        ids.sort_unstable();
        let mut guards = Vec::with_capacity(ids.len());
        for id in ids {
            budget.check()?;
            guards.push(
                self.gate(&format!("volume:{id}"))?
                    .try_lock()
                    .map_err(|_| Error::before(ErrorCode::Conflict))?,
            );
        }
        let mut mounts = qualify(
            root,
            self.binding(),
            &self.domain.directory,
            requests,
            budget,
        )?;
        mounts._guards = guards;
        mounts.domain_guard = Some(self.domain.clone());
        self.domain.verify()?;
        Ok(mounts)
    }

    /// Recheck exact private/current authority, then project the public SDK's
    /// VmRecord.mounts tuple shape. Staged mounts and arbitrary host paths never
    /// enter this projection. It grants no machine/creation authority on its own.
    pub fn volume_record_mounts(
        &self,
        mounts: &QualifiedVolumeMounts,
        budget: &ReadBudget,
    ) -> Result<Vec<(String, String, bool)>> {
        if !mounts
            .domain_guard
            .as_ref()
            .is_some_and(|guard| Arc::ptr_eq(guard, &self.domain))
            || mounts.binding != *self.binding()
            || !self.jobs.available()
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        self.domain.verify()?;
        let records = mounts.records(budget)?;
        self.domain.verify()?;
        Ok(records)
    }

    /// Match a freshly qualified handle to immutable saved machine authority.
    /// Current paths or a matching SDK label cannot replace the saved full proof.
    pub(crate) fn verify_machine_mounts(
        &self,
        receipt: &crate::CreationReceipt,
        record: &smolvm::config::VmRecord,
        mounts: &QualifiedVolumeMounts,
        budget: &ReadBudget,
    ) -> Result<()> {
        self.verify_record(receipt, record)?;
        if self.volume_record_mounts(mounts, budget)? != record.mounts {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let material = crate::material::MaterialJournal::at(&self.vm_directory(&receipt.name))
            .mount_material(receipt, record)?
            .ok_or(Error::before(ErrorCode::Ownership))?;
        if material.mounts
            != mounts
                .backings
                .iter()
                .map(|b| b.request.clone())
                .collect::<Vec<_>>()
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        budget.check()
    }
}

fn validate(
    policy: &LocalVolumePolicy,
    binding: &DomainBinding,
    requests: &[VolumeMountRequest],
) -> Result<()> {
    policy.validate()?;
    if !crate::domain::valid_id(&binding.target_id)
        || !crate::domain::valid_hex(&binding.generation, 32)
    {
        return Err(Error::before(ErrorCode::Validation));
    }
    if requests.is_empty() || requests.len() > VOLUME_MOUNTS {
        return Err(Error::before(ErrorCode::Validation));
    }
    for (index, request) in requests.iter().enumerate() {
        request.validate()?;
        let proof = &request.proof.backing;
        if proof.policy != *policy
            || proof.target_id != binding.target_id
            || proof.domain_generation != binding.generation
            || request.proof.account != requests[0].proof.account
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        for previous in &requests[..index] {
            if previous.target >= request.target
                || request.target.starts_with(&format!("{}/", previous.target))
                || previous.proof.backing.intent.worker_volume_id == proof.intent.worker_volume_id
            {
                return Err(Error::before(ErrorCode::Validation));
            }
        }
    }
    Ok(())
}

fn qualify(
    root: QualifiedVolumeRoot,
    binding: &DomainBinding,
    domain: &std::path::Path,
    requests: &[VolumeMountRequest],
    budget: &ReadBudget,
) -> Result<QualifiedVolumeMounts> {
    validate(&root.policy, binding, requests)?;
    let mut backings = Vec::with_capacity(requests.len());
    for request in requests {
        cleanup_absent(domain, request, budget)?;
        match inspect(
            &root,
            binding,
            domain,
            &request.proof.backing.intent,
            budget,
        )? {
            VolumeProvisionPresence::Provisioned(proof) if *proof == request.proof => {}
            _ => return Err(Error::before(ErrorCode::Ownership)),
        }
        let directory = open_directory(
            &root.directory,
            &cstring(&request.proof.backing.intent.worker_volume_id)?,
        )?;
        verify(&directory, &request.proof)?;
        backings.push(Backing {
            request: request.clone(),
            directory,
        });
    }
    let qualified = QualifiedVolumeMounts {
        root,
        binding: binding.clone(),
        domain: domain.into(),
        backings,
        _guards: vec![],
        domain_guard: None,
    };
    qualified.records(budget)?;
    Ok(qualified)
}

impl QualifiedVolumeMounts {
    pub(crate) fn take_worker_lease(
        &mut self,
        demand: crate::jobs::Demand,
    ) -> Result<crate::jobs::JobLease> {
        let lease = self
            .root
            ._lease
            .as_mut()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        lease.promote_mount_worker(demand)?;
        self.root
            ._lease
            .take()
            .ok_or(Error::before(ErrorCode::Ownership))
    }
    pub(crate) fn recheck_before_launch(&self, budget: &ReadBudget) -> Result<()> {
        self.domain_guard
            .as_ref()
            .ok_or(Error::before(ErrorCode::Ownership))?
            .verify()?;
        self.records(budget)?;
        budget.check()
    }
    pub(crate) fn take_oci_lease(&mut self) -> Result<crate::jobs::JobLease> {
        let lease = self
            .root
            ._lease
            .as_mut()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        lease.promote_mount_oci_start()?;
        self.root
            ._lease
            .take()
            .ok_or(Error::before(ErrorCode::Ownership))
    }

    pub(crate) fn into_worker_authority(self) -> Result<MountedWorkerAuthority> {
        if self.root._lease.is_some() {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(MountedWorkerAuthority {
            _requests: self
                .backings
                .into_iter()
                .map(|backing| backing.request)
                .collect(),
            _guards: self._guards,
            _domain_guard: self.domain_guard,
        })
    }
    pub(crate) fn promote_start(&mut self) -> Result<()> {
        self.root
            ._lease
            .as_mut()
            .ok_or(Error::before(ErrorCode::Ownership))?
            .promote_mount_start()
    }
    pub(crate) fn promote_creation(&mut self) -> Result<()> {
        self.root
            ._lease
            .as_mut()
            .ok_or(Error::before(ErrorCode::Ownership))?
            .promote_mount_creation()
    }
    fn records(&self, budget: &ReadBudget) -> Result<Vec<(String, String, bool)>> {
        self.root.verify(budget)?;
        let mut mounts = Vec::with_capacity(self.backings.len());
        for backing in &self.backings {
            let proof = &backing.request.proof;
            cleanup_absent(&self.domain, &backing.request, budget)?;
            verify(&backing.directory, proof)?;
            match inspect(
                &self.root,
                &self.binding,
                &self.domain,
                &proof.backing.intent,
                budget,
            )? {
                VolumeProvisionPresence::Provisioned(current) if *current == *proof => {}
                _ => return Err(Error::before(ErrorCode::Ownership)),
            }
            mounts.push((
                proof
                    .node_path()
                    .to_str()
                    .ok_or(Error::before(ErrorCode::Ownership))?
                    .into(),
                backing.request.target.clone(),
                backing.request.readonly,
            ));
            cleanup_absent(&self.domain, &backing.request, budget)?;
        }
        self.root.verify(budget)?;
        Ok(mounts)
    }
}

fn cleanup_absent(
    domain: &std::path::Path,
    request: &VolumeMountRequest,
    budget: &ReadBudget,
) -> Result<()> {
    let ledger = existing_ledger(domain)?.ok_or(Error::before(ErrorCode::Ownership))?;
    for suffix in [
        "delete-intent",
        "delete-resolution",
        "deleted",
        "abort-intent",
        "aborted",
    ] {
        budget.check()?;
        require_absent(
            &ledger.directory,
            &cstring(&format!(
                "{}.{suffix}.json",
                request.proof.backing.intent.worker_volume_id
            ))?,
        )?;
    }
    ledger.verify()
}

fn verify(directory: &File, proof: &VolumeProvisionReceipt) -> Result<()> {
    super::verify_completed_backing(directory, proof)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::{Cancellation, LocalVolumeIntent};
    use std::os::unix::fs::{symlink, PermissionsExt};
    use std::time::Duration;

    struct Fixture {
        _directory: tempfile::TempDir,
        policy: LocalVolumePolicy,
        binding: DomainBinding,
        domain: PathBuf,
        request: VolumeMountRequest,
    }
    fn budget() -> ReadBudget {
        ReadBudget::new(Duration::from_secs(2), Cancellation::default()).unwrap()
    }
    fn root(f: &Fixture) -> QualifiedVolumeRoot {
        QualifiedVolumeRoot::open(&f.policy, &f.policy.root, &budget()).unwrap()
    }
    fn fixture() -> Fixture {
        let (directory, policy) = crate::volumes::tests::fixture();
        let domain = std::fs::canonicalize(directory.path())
            .unwrap()
            .join("private");
        std::fs::create_dir(&domain).unwrap();
        std::fs::set_permissions(&domain, std::fs::Permissions::from_mode(0o700)).unwrap();
        let binding = DomainBinding {
            target_id: "worker".into(),
            generation: "a".repeat(32),
            database: domain.join("db"),
            vm_root: domain.join("vms"),
        };
        let root = QualifiedVolumeRoot::open(&policy, &policy.root, &budget()).unwrap();
        let intent = LocalVolumeIntent {
            worker_volume_id: format!("sbv-{}", "b".repeat(32)),
            size_gb: 4,
        };
        let proof = super::super::provision(
            &root,
            &binding,
            &domain,
            &intent,
            super::super::VolumeAccount::current().unwrap(),
            &budget(),
        )
        .unwrap();
        Fixture {
            _directory: directory,
            policy,
            binding,
            domain,
            request: VolumeMountRequest {
                proof,
                target: "/mnt/volumes/data".into(),
                readonly: false,
            },
        }
    }
    fn qualified(f: &Fixture) -> QualifiedVolumeMounts {
        qualify(
            root(f),
            &f.binding,
            &f.domain,
            std::slice::from_ref(&f.request),
            &budget(),
        )
        .unwrap()
    }

    pub(crate) fn foreign_handle() -> (tempfile::TempDir, QualifiedVolumeMounts) {
        let fixture = fixture();
        let handle = qualified(&fixture);
        (fixture._directory, handle)
    }

    pub(crate) fn owned_handle(engine: &Engine) -> (tempfile::TempDir, QualifiedVolumeMounts) {
        let (directory, policy) = crate::volumes::tests::fixture();
        let mut root = QualifiedVolumeRoot::open(&policy, &policy.root, &budget()).unwrap();
        root._lease = Some(
            engine
                .jobs
                .acquire(crate::jobs::Demand::volume_mounts(1).unwrap())
                .unwrap(),
        );
        let intent = LocalVolumeIntent {
            worker_volume_id: format!("sbv-{}", "c".repeat(32)),
            size_gb: 1,
        };
        let proof = super::super::provision(
            &root,
            engine.binding(),
            &engine.domain.directory,
            &intent,
            super::super::VolumeAccount::current().unwrap(),
            &budget(),
        )
        .unwrap();
        let request = VolumeMountRequest {
            proof,
            target: "/mnt/volumes/data".into(),
            readonly: false,
        };
        let mut mounts = qualify(
            root,
            engine.binding(),
            &engine.domain.directory,
            &[request],
            &budget(),
        )
        .unwrap();
        mounts.domain_guard = Some(engine.domain.clone());
        mounts._guards.push(
            engine
                .gate(&format!("volume:{}", intent.worker_volume_id))
                .unwrap()
                .try_lock()
                .unwrap(),
        );
        (directory, mounts)
    }

    #[test]
    fn completed_proof_projects_exact_public_sdk_mount_without_mutating_private_records() {
        let f = fixture();
        let before: Vec<_> = std::fs::read_dir(f.domain.join("volume-staging"))
            .unwrap()
            .map(|entry| {
                let path = entry.unwrap().path();
                (path.clone(), std::fs::read(path).unwrap())
            })
            .collect();
        let qualified = qualified(&f);
        let mounts = qualified.records(&budget()).unwrap();
        let record = smolvm::config::VmRecord::new("mounted".into(), 1, 512, mounts, vec![], false);
        assert_eq!(
            record.mounts,
            vec![(
                f.request.proof.node_path().to_str().unwrap().into(),
                f.request.target.clone(),
                false
            )]
        );
        assert!(record.staged_mounts.is_empty());
        for (path, bytes) in before {
            assert_eq!(std::fs::read(path).unwrap(), bytes);
        }
        let shown = format!("{qualified:?} {:?}", f.request);
        assert!(!shown.contains(&f.request.proof.backing.owner_token));
        assert!(!shown.contains(f.policy.root.to_str().unwrap()));
        let readonly = VolumeMountRequest {
            readonly: true,
            ..f.request.clone()
        };
        let qualified = qualify(root(&f), &f.binding, &f.domain, &[readonly], &budget()).unwrap();
        assert!(qualified.records(&budget()).unwrap()[0].2);
    }

    #[test]
    fn mount_intent_rejects_arbitrary_paths_unknown_fields_and_invalid_guest_targets() {
        let f = fixture();
        for target in [
            "/etc",
            "/mnt/volumes",
            "/mnt/volumes/",
            "/mnt/volumes/a/../b",
            "/mnt/volumes/a/./b",
            "/mnt/volumes//a",
            "/mnt/volumes/a\\b",
            "/mnt/volumes/a\0b",
        ] {
            let request = VolumeMountRequest {
                target: target.into(),
                ..f.request.clone()
            };
            assert!(request.validate().is_err());
        }
        let request = VolumeMountRequest {
            target: format!("/mnt/volumes/{}", "a".repeat(4096)),
            ..f.request.clone()
        };
        assert!(request.validate().is_err());
        let mut value = serde_json::to_value(&f.request).unwrap();
        value["source"] = serde_json::json!("/caller/path");
        assert!(serde_json::from_value::<VolumeMountRequest>(value).is_err());
    }

    #[test]
    fn mount_sets_are_finite_sorted_exclusive_and_nonoverlapping() {
        let f = fixture();
        assert!(validate(&f.policy, &f.binding, &[]).is_err());
        assert!(validate(&f.policy, &f.binding, &vec![f.request.clone(); 9]).is_err());
        let duplicate = VolumeMountRequest {
            target: "/mnt/volumes/other".into(),
            readonly: true,
            ..f.request.clone()
        };
        assert!(validate(
            &f.policy,
            &f.binding,
            &[f.request.clone(), duplicate.clone()]
        )
        .is_err());
        let mut second = duplicate;
        second.proof.backing.intent.worker_volume_id = format!("sbv-{}", "c".repeat(32));
        assert!(validate(&f.policy, &f.binding, &[f.request.clone(), second.clone()]).is_ok());
        assert!(validate(&f.policy, &f.binding, &[second.clone(), f.request.clone()]).is_err());
        second.target = format!("{}/child", f.request.target);
        assert!(validate(&f.policy, &f.binding, &[f.request.clone(), second]).is_err());
    }

    #[test]
    fn supplied_authority_cannot_replace_private_origin_account_or_physical_identity() {
        let f = fixture();
        let mut wrong = f.request.clone();
        wrong.proof.backing.owner_token = "f".repeat(64);
        assert!(qualify(root(&f), &f.binding, &f.domain, &[wrong], &budget()).is_err());
        let mut wrong = f.request.clone();
        wrong.proof.backing.inode += 1;
        assert!(qualify(root(&f), &f.binding, &f.domain, &[wrong], &budget()).is_err());
        let mut wrong = f.request.clone();
        wrong.proof.account.gid = wrong.proof.account.gid.wrapping_add(1);
        assert!(qualify(root(&f), &f.binding, &f.domain, &[wrong], &budget()).is_err());
        let mut wrong = f.request.clone();
        wrong.proof.backing.domain_generation = "f".repeat(32);
        assert!(qualify(root(&f), &f.binding, &f.domain, &[wrong], &budget()).is_err());
        std::fs::remove_file(f.domain.join("volume-staging").join(format!(
            "{}.provisioned.json",
            f.request.proof.backing.intent.worker_volume_id
        )))
        .unwrap();
        assert!(qualify(
            root(&f),
            &f.binding,
            &f.domain,
            std::slice::from_ref(&f.request),
            &budget()
        )
        .is_err());
        assert!(f.request.proof.node_path().is_dir());
    }

    #[test]
    fn descriptor_rechecks_reject_substituted_backing_and_never_chmod_or_adopt_it() {
        let f = fixture();
        let qualified = qualified(&f);
        let path = f.request.proof.node_path();
        std::fs::rename(&path, f.policy.root.join("saved")).unwrap();
        std::fs::create_dir(&path).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        std::fs::write(path.join("foreign"), b"keep").unwrap();
        assert!(qualified.records(&budget()).is_err());
        assert_eq!(std::fs::read(path.join("foreign")).unwrap(), b"keep");
        std::fs::remove_dir_all(&path).unwrap();
        symlink(f.policy.root.join("saved"), &path).unwrap();
        assert!(qualified.records(&budget()).is_err());
    }

    #[test]
    fn safe_completed_mode_changes_preserve_mount_authority_without_rewriting_it() {
        use std::os::unix::fs::MetadataExt;
        let f = fixture();
        let qualified = qualified(&f);
        let path = f.request.proof.node_path();
        let completed = f.domain.join("volume-staging").join(format!(
            "{}.provisioned.json",
            f.request.proof.backing.intent.worker_volume_id
        ));
        let before = std::fs::read(&completed).unwrap();
        for mode in [0o750, 0o755] {
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(mode)).unwrap();
            assert_eq!(
                qualified.records(&budget()).unwrap(),
                vec![(
                    path.to_str().unwrap().into(),
                    f.request.target.clone(),
                    f.request.readonly
                )]
            );
            assert_eq!(std::fs::metadata(&path).unwrap().mode() & 0o7777, mode);
        }
        for change in 0..3 {
            let mut crossed = f.request.proof.clone();
            match change {
                0 => crossed.account.uid += 1,
                1 => crossed.account.gid += 1,
                _ => crossed.backing.inode += 1,
            }
            assert!(verify(&qualified.backings[0].directory, &crossed).is_err());
        }
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o770)).unwrap();
        assert!(qualified.records(&budget()).is_err());
        assert_eq!(std::fs::metadata(&path).unwrap().mode() & 0o7777, 0o770);
        assert_eq!(std::fs::read(completed).unwrap(), before);
    }

    #[test]
    fn unfinished_or_completed_cleanup_blocks_mount_selection_without_mutation() {
        for suffix in [
            "delete-intent",
            "delete-resolution",
            "deleted",
            "abort-intent",
            "aborted",
        ] {
            let f = fixture();
            let qualified = qualified(&f);
            let path = f.domain.join("volume-staging").join(format!(
                "{}.{suffix}.json",
                f.request.proof.backing.intent.worker_volume_id
            ));
            std::fs::write(&path, b"static cleanup boundary").unwrap();
            assert!(qualified.records(&budget()).is_err());
            assert_eq!(std::fs::read(path).unwrap(), b"static cleanup boundary");
            assert!(f.request.proof.node_path().is_dir());
        }
    }

    #[test]
    fn retained_mount_gate_blocks_other_users_until_handle_drop_and_cancellation_is_read_only() {
        let f = fixture();
        let mut qualified = qualified(&f);
        let gate = Arc::new(crate::gate::MachineGate::default());
        qualified._guards.push(gate.try_lock().unwrap());
        assert!(gate.try_lock().is_err());
        let cancel = Cancellation::default();
        cancel.cancel();
        let budget = ReadBudget::new(Duration::from_secs(1), cancel).unwrap();
        assert!(qualified.records(&budget).is_err());
        assert!(f.request.proof.node_path().is_dir());
        drop(qualified);
        assert!(gate.try_lock().is_ok());
    }
}
