//! Private stopped-growth job: no runtime, database writer or implicit boot.
use crate::disk_geometry::{DiskGeometry, GeometryWitness};
use crate::transfer_worker::{Blob, Request};
use crate::{Error, ErrorCode, GrowDisks, Result};
use serde::{Deserialize, Serialize};

pub(crate) const METADATA_BYTES: u64 = 16 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct GrowthProof {
    pub storage_gib: u64,
    pub overlay_gib: u64,
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Metadata {
    schema: u8,
    storage: GeometryWitness,
    overlay: GeometryWitness,
    request: GrowDisks,
}
impl Metadata {
    pub(crate) fn new(storage: &DiskGeometry, overlay: &DiskGeometry, request: GrowDisks) -> Self {
        Self {
            schema: 1,
            storage: storage.witness(),
            overlay: overlay.witness(),
            request,
        }
    }

    pub(crate) fn bound(&self, change: &crate::GrowthChange) -> bool {
        self.schema == 1
            && self.request == change.request
            && self.storage.bound(
                self.overlay.directory(),
                smolvm::storage::STORAGE_DISK_FILENAME,
                change.previous_storage_gib,
            )
            && self.overlay.bound(
                self.storage.directory(),
                smolvm::storage::OVERLAY_DISK_FILENAME,
                change.previous_overlay_gib,
            )
            && self.targets().is_ok_and(|sizes| {
                sizes.storage_gib == change.storage_gib && sizes.overlay_gib == change.overlay_gib
            })
            && serde_json::to_vec(self).is_ok_and(|bytes| bytes.len() as u64 <= METADATA_BYTES)
    }

    pub(crate) fn directory(&self) -> &std::path::Path {
        self.storage.directory()
    }

    pub(crate) fn verify_repaired(
        &self,
        change: &crate::GrowthChange,
        budget: &crate::ReadBudget,
    ) -> Result<(DiskGeometry, DiskGeometry)> {
        if !self.bound(change) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let storage = self.storage.reopen_after(change.storage_gib, budget)?;
        let overlay = self.overlay.reopen_after(change.overlay_gib, budget)?;
        Ok((storage, overlay))
    }

    fn targets(&self) -> Result<GrowthProof> {
        let storage_gib = self.request.storage_gib.unwrap_or(self.storage.gib());
        let overlay_gib = self.request.overlay_gib.unwrap_or(self.overlay.gib());
        if self.schema != 1
            || self.storage.directory() != self.overlay.directory()
            || !(1..=64).contains(&storage_gib)
            || !(1..=64).contains(&overlay_gib)
            || storage_gib < self.storage.gib()
            || overlay_gib < self.overlay.gib()
            || (storage_gib == self.storage.gib() && overlay_gib == self.overlay.gib())
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(GrowthProof {
            storage_gib,
            overlay_gib,
        })
    }
}

pub(crate) fn run(request: &Request, blob: &Blob, expected: GrowthProof) -> Result<GrowthProof> {
    let metadata: Metadata = blob.read(request.owner, METADATA_BYTES)?;
    if metadata.targets()? != expected
        || metadata.storage.directory()
            != request.socket.parent().unwrap_or(std::path::Path::new(""))
    {
        return Err(Error::before(ErrorCode::Ownership));
    }
    // Validate both original descriptors before the first mutation. A replaced
    // untouched companion disk is just as invalid as a replaced grow target.
    let storage = metadata
        .storage
        .reopen(smolvm::storage::STORAGE_DISK_FILENAME)?;
    let overlay = metadata
        .overlay
        .reopen(smolvm::storage::OVERLAY_DISK_FILENAME)?;
    if let Some(size) = metadata.request.storage_gib {
        smolvm::storage::expand_disk::<smolvm::storage::Storage>(storage.path(), size)
            .map_err(|_| Error::uncertain(ErrorCode::Native))?;
    }
    if let Some(size) = metadata.request.overlay_gib {
        smolvm::storage::expand_disk::<smolvm::storage::Overlay>(overlay.path(), size)
            .map_err(|_| Error::uncertain(ErrorCode::Native))?;
    }
    storage.verify_after(expected.storage_gib)?;
    overlay.verify_after(expected.overlay_gib)?;
    Ok(expected)
}
