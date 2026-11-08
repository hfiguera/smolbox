//! Immutable proof of mount configuration, authenticated by the record hash and
//! private material journal. Labels or current directory inventory cannot mint it.
use crate::{CreationReceipt, Error, ErrorCode, Result, VolumeMountRequest};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use smolvm::config::VmRecord;

pub(crate) const MOUNT_LABEL: &str = "smolbox.volume-mounts-sha256";

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MountMaterial {
    pub schema: u8,
    pub mounts: Vec<VolumeMountRequest>,
}
impl std::fmt::Debug for MountMaterial {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("MountMaterial")
            .field("count", &self.mounts.len())
            .finish_non_exhaustive()
    }
}
impl MountMaterial {
    pub(crate) fn validate(&self, origin: &CreationReceipt) -> Result<()> {
        if self.schema != 1 || self.mounts.is_empty() || self.mounts.len() > crate::VOLUME_MOUNTS {
            return Err(Error::before(ErrorCode::Ownership));
        }
        for (index, mount) in self.mounts.iter().enumerate() {
            mount.validate()?;
            let backing = &mount.proof.backing;
            if backing.target_id != origin.target_id
                || backing.domain_generation != origin.domain_generation
                || backing.policy != self.mounts[0].proof.backing.policy
                || mount.proof.account != self.mounts[0].proof.account
            {
                return Err(Error::before(ErrorCode::Ownership));
            }
            for previous in &self.mounts[..index] {
                if previous.target >= mount.target
                    || mount.target.starts_with(&format!("{}/", previous.target))
                    || previous.proof.backing.intent.worker_volume_id
                        == backing.intent.worker_volume_id
                {
                    return Err(Error::before(ErrorCode::Ownership));
                }
            }
        }
        Ok(())
    }

    pub(crate) fn digest(&self) -> Result<String> {
        let value = serde_json::to_value(self).map_err(|_| Error::before(ErrorCode::Ownership))?;
        let bytes = serde_json::to_vec(&value).map_err(|_| Error::before(ErrorCode::Ownership))?;
        Ok(hex::encode(Sha256::digest(bytes)))
    }

    pub(crate) fn records(&self) -> Result<Vec<(String, String, bool)>> {
        self.mounts
            .iter()
            .map(|mount| {
                Ok((
                    mount
                        .proof
                        .node_path()
                        .to_str()
                        .ok_or(Error::before(ErrorCode::Ownership))?
                        .into(),
                    mount.target.clone(),
                    mount.readonly,
                ))
            })
            .collect()
    }

    pub(crate) fn verify_record(&self, origin: &CreationReceipt, record: &VmRecord) -> Result<()> {
        self.validate(origin)?;
        if record.mounts != self.records()?
            || !record.staged_mounts.is_empty()
            || record.labels.get(MOUNT_LABEL) != Some(&self.digest()?)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
}
