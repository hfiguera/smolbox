//! Explicit caller-fenced cleanup of protected but unprovisioned backing. An
//! abort never publishes readiness or adopts an unproved temporary directory.
use super::super::super::{
    cstring, existing_ledger, open_directory, publish, read_record, require_absent, temporary_name,
    Entry, PrivateLedger, VolumeAccount, VolumeStagingReceipt,
};
use super::{node, remove_tree, unlink, MAX_ENTRIES};
use crate::{
    DomainBinding, Engine, Error, ErrorCode, LocalVolumeIntent, LocalVolumePolicy,
    QualifiedVolumeRoot, ReadBudget, Result,
};
use serde::{Deserialize, Serialize};
use std::ffi::CString;
use std::os::unix::fs::MetadataExt;

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct VolumeStagingAbortReceipt {
    pub schema: u8,
    pub operation_id: String,
    pub backing: VolumeStagingReceipt,
    pub account: VolumeAccount,
}
impl std::fmt::Debug for VolumeStagingAbortReceipt {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("VolumeStagingAbortReceipt")
            .field("schema", &self.schema)
            .finish_non_exhaustive()
    }
}
impl VolumeStagingAbortReceipt {
    pub fn validate(&self) -> Result<()> {
        self.backing.validate()?;
        self.account.validate()?;
        if self.schema != 1 || !crate::domain::valid_hex(&self.operation_id, 32) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VolumeStagingAbortPresence {
    Unverified,
    Aborted(Box<VolumeStagingAbortReceipt>),
}

impl Engine {
    /// Explicit cleanup before readiness, only with protected prepared/staged
    /// backing and fenced prior writers. Quarantine/gates/attachments still fence.
    pub fn abort_volume_staging(
        &self,
        policy: &LocalVolumePolicy,
        intent: &LocalVolumeIntent,
        quiesced: bool,
        budget: &ReadBudget,
    ) -> Result<VolumeStagingAbortReceipt> {
        if !quiesced {
            return Err(Error::before(ErrorCode::Validation));
        }
        policy.validate()?;
        intent.validate()?;
        budget.check()?;
        if !cfg!(target_os = "linux") {
            return Err(Error::before(ErrorCode::Unsupported));
        }
        let job = self.jobs.acquire(crate::jobs::Demand::volume_delete())?;
        self.domain.verify()?;
        let mut root =
            QualifiedVolumeRoot::open(policy, &LocalVolumePolicy::canonical_sdk_root()?, budget)?;
        root._lease = Some(job);
        let gate = self.gate(&format!("volume:{}", intent.worker_volume_id))?;
        let _guard = gate
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let receipt = cleanup(
            &root,
            self.binding(),
            &self.domain.directory,
            intent,
            budget,
            quiesced,
            || {
                self.domain.verify()?;
                for name in [
                    &cstring(&intent.worker_volume_id)?,
                    &temporary_name(intent)?,
                ] {
                    let path = policy.root.join(
                        name.to_str()
                            .map_err(|_| Error::before(ErrorCode::Validation))?,
                    );
                    if !crate::sdk_compat::volume_unattached(
                        &self.binding().database,
                        self.database_identity,
                        &path,
                        budget,
                    )? {
                        return Err(Error::before(ErrorCode::Conflict));
                    }
                }
                Ok(())
            },
        )?;
        self.domain
            .verify()
            .map_err(|error| Error::uncertain(error.code))?;
        Ok(receipt)
    }

    /// Read-only abort proof. Missing data or missing completion remains unknown.
    pub fn inspect_volume_staging_abort(
        &self,
        policy: &LocalVolumePolicy,
        intent: &LocalVolumeIntent,
        budget: &ReadBudget,
    ) -> Result<VolumeStagingAbortPresence> {
        policy.validate()?;
        intent.validate()?;
        budget.check()?;
        if !cfg!(target_os = "linux") {
            return Err(Error::before(ErrorCode::Unsupported));
        }
        let job = self
            .jobs
            .acquire(crate::jobs::Demand::volume_observation())?;
        self.domain.verify()?;
        let mut root =
            QualifiedVolumeRoot::open(policy, &LocalVolumePolicy::canonical_sdk_root()?, budget)?;
        root._lease = Some(job);
        let gate = self.observation_gate(&format!("volume:{}", intent.worker_volume_id))?;
        let _guard = gate
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let result = observe(
            &root,
            self.binding(),
            &self.domain.directory,
            intent,
            budget,
        )?;
        self.domain.verify()?;
        Ok(result)
    }
}

fn backing(
    root: &QualifiedVolumeRoot,
    binding: &DomainBinding,
    ledger: &PrivateLedger,
    intent: &LocalVolumeIntent,
    budget: &ReadBudget,
) -> Result<VolumeStagingReceipt> {
    let entry: Entry = read_record(
        ledger,
        &cstring(&format!("{}.intent.json", intent.worker_volume_id))?,
        budget,
    )?
    .ok_or(Error::before(ErrorCode::Ownership))?;
    let kind = match entry.schema {
        1 => "staged",
        2 => "backing",
        _ => return Err(Error::before(ErrorCode::Ownership)),
    };
    let receipt: VolumeStagingReceipt = read_record(
        ledger,
        &cstring(&format!("{}.{kind}.json", intent.worker_volume_id))?,
        budget,
    )?
    .ok_or(Error::before(ErrorCode::Ownership))?;
    receipt.validate()?;
    if entry.target_id != binding.target_id
        || entry.domain_generation != binding.generation
        || entry.policy != root.policy
        || entry.intent != *intent
        || (entry.root_device, entry.root_inode) != root.identity
        || receipt.target_id != entry.target_id
        || receipt.domain_generation != entry.domain_generation
        || receipt.policy != entry.policy
        || receipt.intent != entry.intent
        || receipt.owner_token != entry.owner_token
        || (receipt.root_device, receipt.root_inode) != root.identity
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    Ok(receipt)
}

fn unprovisioned(ledger: &PrivateLedger, intent: &LocalVolumeIntent) -> Result<()> {
    for kind in ["provisioned", "delete-intent", "deleted"] {
        require_absent(
            &ledger.directory,
            &cstring(&format!("{}.{kind}.json", intent.worker_volume_id))?,
        )?;
    }
    Ok(())
}

fn candidate(
    root: &QualifiedVolumeRoot,
    backing: &VolumeStagingReceipt,
) -> Result<Option<CString>> {
    let mut found = None;
    for name in [
        cstring(&backing.intent.worker_volume_id)?,
        temporary_name(&backing.intent)?,
    ] {
        match require_absent(&root.directory, &name) {
            Ok(()) => {}
            Err(error) if error.code == ErrorCode::Conflict => {
                let child = open_directory(&root.directory, &name)?;
                let metadata = child
                    .metadata()
                    .map_err(|_| Error::before(ErrorCode::Ownership))?;
                if found.is_some()
                    || (metadata.dev(), metadata.ino()) != (backing.device, backing.inode)
                    || metadata.uid() != unsafe { libc::geteuid() }
                    || metadata.mode() & 0o7777 != backing.mode
                {
                    return Err(Error::before(ErrorCode::Ownership));
                }
                found = Some(name);
            }
            Err(error) => return Err(error),
        }
    }
    Ok(found)
}

fn cleanup(
    root: &QualifiedVolumeRoot,
    binding: &DomainBinding,
    domain: &std::path::Path,
    intent: &LocalVolumeIntent,
    budget: &ReadBudget,
    quiesced: bool,
    attachment_guard: impl FnOnce() -> Result<()>,
) -> Result<VolumeStagingAbortReceipt> {
    if !quiesced {
        return Err(Error::before(ErrorCode::Validation));
    }
    intent.validate()?;
    root.verify(budget)?;
    let ledger = existing_ledger(domain)?.ok_or(Error::before(ErrorCode::Ownership))?;
    unprovisioned(&ledger, intent)?;
    let backing = backing(root, binding, &ledger, intent, budget)?;
    let account = VolumeAccount::current()?;
    candidate(root, &backing)?;
    attachment_guard()?;
    if let VolumeStagingAbortPresence::Aborted(receipt) =
        observe(root, binding, domain, intent, budget)?
    {
        return Ok(*receipt);
    }
    let entered = cstring(&format!("{}.abort-intent.json", intent.worker_volume_id))?;
    let completed = cstring(&format!("{}.aborted.json", intent.worker_volume_id))?;
    let existing: Option<VolumeStagingAbortReceipt> = read_record(&ledger, &entered, budget)?;
    let receipt = if let Some(receipt) = existing {
        receipt.validate()?;
        if receipt.backing != backing || receipt.account != account {
            return Err(Error::before(ErrorCode::Ownership));
        }
        receipt
    } else {
        let mut id = [0; 16];
        getrandom::fill(&mut id).map_err(|_| Error::before(ErrorCode::Native))?;
        let receipt = VolumeStagingAbortReceipt {
            schema: 1,
            operation_id: hex::encode(id),
            backing,
            account,
        };
        receipt.validate()?;
        publish(&ledger, &entered, &receipt)?;
        receipt
    };
    let mutate = || -> Result<()> {
        root.verify(budget)?;
        if let Some(name) = candidate(root, &receipt.backing)? {
            let child = open_directory(&root.directory, &name)?;
            remove_tree(&child, budget, MAX_ENTRIES)?;
            root.verify(budget)?;
            let current = node(&root.directory, &name)?;
            if current.identity != (receipt.backing.device, receipt.backing.inode)
                || !current.directory
            {
                return Err(Error::before(ErrorCode::Ownership));
            }
            unlink(&root.directory, &name, true)?;
        }
        root.directory
            .sync_all()
            .map_err(|_| Error::before(ErrorCode::Io))?;
        root.verify(budget)?;
        if candidate(root, &receipt.backing)?.is_some() {
            return Err(Error::before(ErrorCode::Ownership));
        }
        publish(&ledger, &completed, &receipt)?;
        root.verify(budget)?;
        if candidate(root, &receipt.backing)?.is_some() {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    };
    mutate().map_err(|error| Error::uncertain(error.code))?;
    Ok(receipt)
}

fn observe(
    root: &QualifiedVolumeRoot,
    binding: &DomainBinding,
    domain: &std::path::Path,
    intent: &LocalVolumeIntent,
    budget: &ReadBudget,
) -> Result<VolumeStagingAbortPresence> {
    intent.validate()?;
    root.verify(budget)?;
    let Some(ledger) = existing_ledger(domain)? else {
        return Ok(VolumeStagingAbortPresence::Unverified);
    };
    unprovisioned(&ledger, intent)?;
    let entered: Option<VolumeStagingAbortReceipt> = read_record(
        &ledger,
        &cstring(&format!("{}.abort-intent.json", intent.worker_volume_id))?,
        budget,
    )?;
    let complete: Option<VolumeStagingAbortReceipt> = read_record(
        &ledger,
        &cstring(&format!("{}.aborted.json", intent.worker_volume_id))?,
        budget,
    )?;
    let result = match (entered, complete) {
        (Some(entered), Some(complete)) => {
            complete.validate()?;
            if entered != complete
                || complete.backing != backing(root, binding, &ledger, intent, budget)?
                || complete.account != VolumeAccount::current()?
                || candidate(root, &complete.backing)?.is_some()
            {
                return Err(Error::before(ErrorCode::Ownership));
            }
            VolumeStagingAbortPresence::Aborted(Box::new(complete))
        }
        _ => VolumeStagingAbortPresence::Unverified,
    };
    ledger.verify()?;
    root.verify(budget)?;
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    struct Fixture {
        _directory: tempfile::TempDir,
        root: QualifiedVolumeRoot,
        domain: std::path::PathBuf,
        binding: DomainBinding,
        backing: VolumeStagingReceipt,
    }
    fn budget() -> ReadBudget {
        crate::volumes::tests::budget()
    }
    fn fixture(temporary: bool) -> Option<Fixture> {
        if let Err(error) = VolumeAccount::current() {
            assert_eq!(error.code, ErrorCode::Unsupported);
            return None;
        }
        let (directory, policy) = crate::volumes::tests::fixture();
        let root = QualifiedVolumeRoot::open(&policy, &policy.root, &budget()).unwrap();
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
        let intent = LocalVolumeIntent {
            worker_volume_id: format!("sbv-{}", "b".repeat(32)),
            size_gb: 2,
        };
        let backing =
            super::super::super::super::stage(&root, &binding, &domain, &intent, &budget())
                .unwrap();
        // Static non-VM pre/post-publication models; no live writer interrupted.
        std::fs::remove_file(
            domain
                .join("volume-staging")
                .join(format!("{}.staged.json", intent.worker_volume_id)),
        )
        .unwrap();
        if temporary {
            std::fs::rename(
                policy.root.join(&intent.worker_volume_id),
                policy
                    .root
                    .join(temporary_name(&intent).unwrap().to_str().unwrap()),
            )
            .unwrap();
        }
        Some(Fixture {
            _directory: directory,
            root,
            domain,
            binding,
            backing,
        })
    }
    fn path(f: &Fixture, temporary: bool) -> std::path::PathBuf {
        f.root.policy.root.join(if temporary {
            temporary_name(&f.backing.intent)
                .unwrap()
                .to_str()
                .unwrap()
                .to_owned()
        } else {
            f.backing.intent.worker_volume_id.clone()
        })
    }
    fn record(f: &Fixture, kind: &str) -> std::path::PathBuf {
        f.domain
            .join("volume-staging")
            .join(format!("{}.{kind}.json", f.backing.intent.worker_volume_id))
    }
    fn run(f: &Fixture, quiesced: bool) -> Result<VolumeStagingAbortReceipt> {
        cleanup(
            &f.root,
            &f.binding,
            &f.domain,
            &f.backing.intent,
            &budget(),
            quiesced,
            || Ok(()),
        )
    }
    fn inspect(f: &Fixture) -> Result<VolumeStagingAbortPresence> {
        observe(&f.root, &f.binding, &f.domain, &f.backing.intent, &budget())
    }

    #[test]
    fn fenced_abort_cleans_prepared_temporary_and_published_unready_backing_without_readiness() {
        for temporary in [false, true] {
            let Some(f) = fixture(temporary) else { return };
            std::fs::write(path(&f, temporary).join("data"), b"owned").unwrap();
            assert_eq!(inspect(&f).unwrap(), VolumeStagingAbortPresence::Unverified);
            let receipt = run(&f, true).unwrap();
            assert_eq!(receipt.backing, f.backing);
            assert!(!path(&f, true).exists());
            assert!(!path(&f, false).exists());
            assert!(!record(&f, "provisioned").exists());
            assert!(!record(&f, "staged").exists());
            assert_eq!(
                inspect(&f).unwrap(),
                VolumeStagingAbortPresence::Aborted(Box::new(receipt.clone()))
            );
            let bytes = std::fs::read(record(&f, "aborted")).unwrap();
            assert_eq!(run(&f, true).unwrap(), receipt);
            assert_eq!(std::fs::read(record(&f, "aborted")).unwrap(), bytes);
            assert!(!format!("{receipt:?}").contains(&receipt.backing.owner_token));
        }
    }

    #[test]
    fn abort_requires_quiescence_and_cannot_override_attachment_or_cancellation() {
        let Some(f) = fixture(true) else { return };
        assert_eq!(run(&f, false).unwrap_err().code, ErrorCode::Validation);
        let error = cleanup(
            &f.root,
            &f.binding,
            &f.domain,
            &f.backing.intent,
            &budget(),
            true,
            || Err(Error::before(ErrorCode::Conflict)),
        )
        .unwrap_err();
        assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
        assert!(!record(&f, "abort-intent").exists());
        let cancel = crate::Cancellation::default();
        cancel.cancel();
        let cancelled = ReadBudget::new(std::time::Duration::from_secs(2), cancel).unwrap();
        assert_eq!(
            cleanup(
                &f.root,
                &f.binding,
                &f.domain,
                &f.backing.intent,
                &cancelled,
                true,
                || Ok(())
            )
            .unwrap_err()
            .code,
            ErrorCode::State
        );
        assert!(path(&f, true).exists());
    }

    #[test]
    fn unproved_or_substituted_backing_is_preserved_without_abort_intent() {
        let Some(f) = fixture(true) else { return };
        let saved = std::fs::read(record(&f, "backing")).unwrap();
        std::fs::remove_file(record(&f, "backing")).unwrap();
        assert_eq!(run(&f, true).unwrap_err().code, ErrorCode::Ownership);
        assert!(path(&f, true).exists());
        std::fs::write(record(&f, "backing"), saved).unwrap();
        std::fs::set_permissions(
            record(&f, "backing"),
            std::fs::Permissions::from_mode(0o600),
        )
        .unwrap();
        let target = path(&f, true);
        std::fs::rename(&target, target.with_extension("original")).unwrap();
        std::fs::create_dir(&target).unwrap();
        std::fs::set_permissions(&target, std::fs::Permissions::from_mode(0o700)).unwrap();
        std::fs::write(target.join("keep"), b"foreign").unwrap();
        assert_eq!(run(&f, true).unwrap_err().code, ErrorCode::Ownership);
        assert!(!record(&f, "abort-intent").exists());
        assert_eq!(std::fs::read(target.join("keep")).unwrap(), b"foreign");
    }

    #[test]
    fn both_candidate_paths_or_completed_provisioning_prevent_abort() {
        let Some(f) = fixture(true) else { return };
        std::fs::create_dir(path(&f, false)).unwrap();
        assert_eq!(run(&f, true).unwrap_err().code, ErrorCode::Ownership);
        assert!(path(&f, true).exists());
        assert!(path(&f, false).exists());
        std::fs::remove_dir(path(&f, false)).unwrap();
        std::fs::write(record(&f, "provisioned"), b"retained").unwrap();
        assert_eq!(run(&f, true).unwrap_err().code, ErrorCode::Conflict);
        assert!(!record(&f, "abort-intent").exists());
    }

    #[test]
    fn missing_abort_completion_stays_unknown_until_an_explicit_fenced_call() {
        let Some(f) = fixture(false) else { return };
        let receipt = run(&f, true).unwrap();
        std::fs::remove_file(record(&f, "aborted")).unwrap();
        assert_eq!(inspect(&f).unwrap(), VolumeStagingAbortPresence::Unverified);
        assert!(!record(&f, "aborted").exists());
        assert_eq!(run(&f, true).unwrap(), receipt);
        assert_eq!(
            inspect(&f).unwrap(),
            VolumeStagingAbortPresence::Aborted(Box::new(receipt))
        );
    }

    #[test]
    fn crossed_abort_evidence_and_reappearing_inventory_cannot_release_ownership() {
        let Some(f) = fixture(true) else { return };
        let receipt = run(&f, true).unwrap();
        let changed = VolumeStagingAbortReceipt {
            operation_id: "f".repeat(32),
            ..receipt.clone()
        };
        std::fs::write(record(&f, "aborted"), serde_json::to_vec(&changed).unwrap()).unwrap();
        assert_eq!(inspect(&f).unwrap_err().code, ErrorCode::Ownership);
        std::fs::write(record(&f, "aborted"), serde_json::to_vec(&receipt).unwrap()).unwrap();
        std::fs::create_dir(path(&f, true)).unwrap();
        std::fs::write(path(&f, true).join("keep"), b"foreign").unwrap();
        assert_eq!(inspect(&f).unwrap_err().code, ErrorCode::Ownership);
        assert_eq!(
            std::fs::read(path(&f, true).join("keep")).unwrap(),
            b"foreign"
        );
    }
}
