//! Same-account local volume provision evidence. The pinned SDK does not drop
//! VMM UIDs when the launcher is unprivileged. Guest/replacement qualification
//! remains a separate activation gate; no permission widening is inferred.
#[path = "volume_mounts.rs"]
mod mounts;
#[cfg(test)]
pub(crate) use mounts::tests::{foreign_handle, owned_handle};
pub use mounts::{QualifiedVolumeMounts, VolumeMountRequest, VolumeMountSelection, VOLUME_MOUNTS};

use super::{
    cstring, existing_ledger, observe, publish, read_record, require_absent, stage,
    VolumeStagingPresence, VolumeStagingReceipt,
};
use crate::{
    DomainBinding, Engine, Error, ErrorCode, LocalVolumeIntent, LocalVolumePolicy,
    QualifiedVolumeRoot, ReadBudget, Result,
};
use serde::{Deserialize, Serialize};

#[path = "volume_deletion.rs"]
mod deletion;
pub(crate) use deletion::remove_tree;
pub use deletion::{
    VolumeDeletionPresence, VolumeDeletionReceipt, VolumeStagingAbortPresence,
    VolumeStagingAbortReceipt,
};

/// Exact account inherited by an unprivileged pinned-SDK VMM. It is not a
/// permission to change the helper's credentials or turn off SDK UID isolation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct VolumeAccount {
    pub uid: u32,
    pub gid: u32,
}
impl VolumeAccount {
    fn select(uid: u32, gid: u32, real_uid: u32, real_gid: u32, uid_drop: bool) -> Result<Self> {
        if uid == 0 || uid != real_uid || gid != real_gid || uid_drop {
            return Err(Error::before(ErrorCode::Unsupported));
        }
        Ok(Self { uid, gid })
    }
    pub(super) fn current() -> Result<Self> {
        Self::select(
            unsafe { libc::geteuid() },
            unsafe { libc::getegid() },
            unsafe { libc::getuid() },
            unsafe { libc::getgid() },
            smolvm::process::vm_uid_drop_active(),
        )
    }
    pub fn validate(&self) -> Result<()> {
        if self.uid == 0 {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
}

/// Completed host provisioning, with immutable backing and exact inherited
/// account identity. Supplied receipt fields require matching protected records.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct VolumeProvisionReceipt {
    pub schema: u8,
    pub backing: VolumeStagingReceipt,
    pub account: VolumeAccount,
}
impl std::fmt::Debug for VolumeProvisionReceipt {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("VolumeProvisionReceipt")
            .field("schema", &self.schema)
            .finish_non_exhaustive()
    }
}
impl VolumeProvisionReceipt {
    pub fn validate(&self) -> Result<()> {
        self.backing.validate()?;
        self.account.validate()?;
        if self.schema != 1 {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
    /// Owned path selected by the operator root and generated ID. Mount use
    /// requires current proof/attachment verification, not this accessor alone.
    pub fn node_path(&self) -> std::path::PathBuf {
        self.backing
            .policy
            .root
            .join(&self.backing.intent.worker_volume_id)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VolumeProvisionPresence {
    Absent,
    Unverified,
    Provisioned(Box<VolumeProvisionReceipt>),
}

/// Pre-dispatch ownership/mount exclusion, retaining root admission and the
/// volume gate. Prepared deletion consumes this handle and rechecks all proof;
/// callers cannot construct it from a path or an inventory record.
pub struct VolumeDeletionPermit {
    root: QualifiedVolumeRoot,
    receipt: VolumeProvisionReceipt,
    _guard: crate::gate::MachineLease,
}
impl std::fmt::Debug for VolumeDeletionPermit {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("VolumeDeletionPermit")
            .finish_non_exhaustive()
    }
}
impl VolumeDeletionPermit {
    /// Revalidate retained root identity before using this completed preflight.
    /// Does not initialize SDK state, delete data or establish quiescence.
    pub fn verify_root(&self, budget: &ReadBudget) -> Result<()> {
        self.root.verify(budget)
    }
    pub fn receipt(&self) -> &VolumeProvisionReceipt {
        &self.receipt
    }
}

impl Engine {
    /// Qualify exact protected ownership and exclude every retained SDK mount,
    /// including stopped/read-only records. Durable exclusive attachment and
    /// fresh creation integration remain additional requirements for deletion.
    pub fn qualify_volume_deletion(
        &self,
        policy: &LocalVolumePolicy,
        intent: &LocalVolumeIntent,
        budget: &ReadBudget,
    ) -> Result<VolumeDeletionPermit> {
        budget.check()?;
        policy.validate()?;
        intent.validate()?;
        if !cfg!(target_os = "linux") {
            return Err(Error::before(ErrorCode::Unsupported));
        }
        let job = self.jobs.acquire(crate::jobs::Demand::volume_delete())?;
        self.domain.verify()?;
        let mut root =
            QualifiedVolumeRoot::open(policy, &LocalVolumePolicy::canonical_sdk_root()?, budget)?;
        root._lease = Some(job);
        let gate = self.gate(&format!("volume:{}", intent.worker_volume_id))?;
        let guard = gate
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let receipt = match inspect(
            &root,
            self.binding(),
            &self.domain.directory,
            intent,
            budget,
        )? {
            VolumeProvisionPresence::Provisioned(receipt) => *receipt,
            _ => return Err(Error::before(ErrorCode::Ownership)),
        };
        if !crate::sdk_compat::volume_unattached(
            &self.binding().database,
            self.database_identity,
            &receipt.node_path(),
            budget,
        )? {
            return Err(Error::before(ErrorCode::Conflict));
        }
        root.verify(budget)?;
        self.domain.verify()?;
        Ok(VolumeDeletionPermit {
            root,
            receipt,
            _guard: guard,
        })
    }

    /// Fresh Linux host provisioning under the dedicated unprivileged account.
    /// No arbitrary permission policy, root UID opt-out or existing-dir adoption.
    /// Public capability activation still requires ordinary guest qualification.
    pub fn provision_volume(
        &self,
        policy: &LocalVolumePolicy,
        intent: &LocalVolumeIntent,
        budget: &ReadBudget,
    ) -> Result<VolumeProvisionReceipt> {
        budget.check()?;
        intent.validate()?;
        let account = VolumeAccount::current()?;
        let root = self.qualify_volume_root(policy, budget)?;
        let gate = self.gate(&format!("volume:{}", intent.worker_volume_id))?;
        let _guard = gate
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        self.domain.verify()?;
        let receipt = provision(
            &root,
            self.binding(),
            &self.domain.directory,
            intent,
            account,
            budget,
        )?;
        self.domain
            .verify()
            .map_err(|error| Error::uncertain(error.code))?;
        Ok(receipt)
    }

    /// Read-only completed provisioning proof. Staging alone is unverified and
    /// cannot be promoted by inspection. Available through reserved control jobs.
    pub fn inspect_volume_provision(
        &self,
        policy: &LocalVolumePolicy,
        intent: &LocalVolumeIntent,
        budget: &ReadBudget,
    ) -> Result<VolumeProvisionPresence> {
        budget.check()?;
        policy.validate()?;
        intent.validate()?;
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
        let result = inspect(
            &root,
            self.binding(),
            &self.domain.directory,
            intent,
            budget,
        )?;
        self.domain.verify()?;
        root.verify(budget)?;
        Ok(result)
    }
}

pub(super) fn provision(
    root: &QualifiedVolumeRoot,
    binding: &DomainBinding,
    domain: &std::path::Path,
    intent: &LocalVolumeIntent,
    account: VolumeAccount,
    budget: &ReadBudget,
) -> Result<VolumeProvisionReceipt> {
    budget.check()?;
    account.validate()?;
    if account != VolumeAccount::current()? {
        return Err(Error::before(ErrorCode::Ownership));
    }
    intent.validate()?;
    let name = cstring(&format!("{}.provisioned.json", intent.worker_volume_id))?;
    if let Some(ledger) = existing_ledger(domain)? {
        require_absent(&ledger.directory, &name)?;
    }
    let backing = stage(root, binding, domain, intent, budget)?;
    let complete = || -> Result<VolumeProvisionReceipt> {
        let ledger = existing_ledger(domain)?.ok_or(Error::before(ErrorCode::Ownership))?;
        match observe(root, binding, domain, intent, budget)? {
            VolumeStagingPresence::Staged(current) if *current == backing => {}
            _ => return Err(Error::before(ErrorCode::Ownership)),
        }
        if account != VolumeAccount::current()? {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let receipt = VolumeProvisionReceipt {
            schema: 1,
            backing: backing.clone(),
            account,
        };
        receipt.validate()?;
        publish(&ledger, &name, &receipt)?;
        match inspect(root, binding, domain, intent, budget)? {
            VolumeProvisionPresence::Provisioned(current) if *current == receipt => Ok(receipt),
            _ => Err(Error::before(ErrorCode::Ownership)),
        }
    };
    complete().map_err(|error| Error::uncertain(error.code))
}

pub(super) fn inspect(
    root: &QualifiedVolumeRoot,
    binding: &DomainBinding,
    domain: &std::path::Path,
    intent: &LocalVolumeIntent,
    budget: &ReadBudget,
) -> Result<VolumeProvisionPresence> {
    budget.check()?;
    intent.validate()?;
    root.verify(budget)?;
    let Some(ledger) = existing_ledger(domain)? else {
        return Ok(match observe(root, binding, domain, intent, budget)? {
            VolumeStagingPresence::Absent => VolumeProvisionPresence::Absent,
            _ => VolumeProvisionPresence::Unverified,
        });
    };
    let receipt: Option<VolumeProvisionReceipt> = read_record(
        &ledger,
        &cstring(&format!("{}.provisioned.json", intent.worker_volume_id))?,
        budget,
    )?;
    let staging = match &receipt {
        Some(provision) => {
            super::observe_provisioned(root, binding, domain, intent, provision, budget)?
        }
        None => observe(root, binding, domain, intent, budget)?,
    };
    let result = match (staging, receipt) {
        (VolumeStagingPresence::Absent, None) => VolumeProvisionPresence::Absent,
        (VolumeStagingPresence::Staged(backing), Some(receipt)) => {
            receipt.validate()?;
            if receipt.backing != *backing || receipt.account != VolumeAccount::current()? {
                return Err(Error::before(ErrorCode::Ownership));
            }
            VolumeProvisionPresence::Provisioned(Box::new(receipt))
        }
        _ => VolumeProvisionPresence::Unverified,
    };
    ledger.verify()?;
    root.verify(budget)?;
    Ok(result)
}

/// Recheck the immutable completed identity, permitting only owner-rwx,
/// non-group/world-writable, non-special permission evolution. No chmod/chown or
/// record update occurs. Incomplete staging uses its separate exact-mode check.
pub(super) fn verify_completed_backing(
    directory: &std::fs::File,
    proof: &VolumeProvisionReceipt,
) -> Result<()> {
    use std::os::unix::fs::MetadataExt;
    proof.validate()?;
    let metadata = directory
        .metadata()
        .map_err(|_| Error::before(ErrorCode::Ownership))?;
    if !metadata.is_dir()
        || (metadata.dev(), metadata.ino()) != (proof.backing.device, proof.backing.inode)
        || metadata.uid() != proof.account.uid
        || metadata.gid() != proof.account.gid
        || metadata.mode() & 0o7022 != 0
        || metadata.mode() & 0o700 != 0o700
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn account_selection_preserves_sdk_unprivileged_mode_without_permission_optouts() {
        assert_eq!(
            VolumeAccount::select(1000, 1000, 1000, 1000, false).unwrap(),
            VolumeAccount {
                uid: 1000,
                gid: 1000
            }
        );
        for args in [
            (0, 0, 0, 0, true),
            (0, 0, 0, 0, false),
            (1000, 1000, 1000, 1000, true),
            (1000, 1000, 2000, 1000, false),
            (1000, 1000, 1000, 2000, false),
        ] {
            assert_eq!(
                VolumeAccount::select(args.0, args.1, args.2, args.3, args.4)
                    .unwrap_err()
                    .code,
                ErrorCode::Unsupported
            );
        }
    }
}
