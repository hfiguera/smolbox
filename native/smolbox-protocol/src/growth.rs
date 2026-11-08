//! Bounded growth wire evidence. Native mutation authority remains in the engine.
use crate::{InvalidMessage, MaterialProof, Receipt};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DiskSizes {
    pub storage_gib: u64,
    pub overlay_gib: u64,
}
impl DiskSizes {
    pub fn validate(&self) -> Result<(), InvalidMessage> {
        check((1..=64).contains(&self.storage_gib) && (1..=64).contains(&self.overlay_gib))
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GrowDisks {
    #[serde(deserialize_with = "crate::wire::required_nullable")]
    pub storage_gib: Option<u64>,
    #[serde(deserialize_with = "crate::wire::required_nullable")]
    pub overlay_gib: Option<u64>,
}
impl GrowDisks {
    pub fn targets(&self, previous: DiskSizes) -> Result<DiskSizes, InvalidMessage> {
        previous.validate()?;
        check(self.storage_gib.is_some() || self.overlay_gib.is_some())?;
        let next = DiskSizes {
            storage_gib: self.storage_gib.unwrap_or(previous.storage_gib),
            overlay_gib: self.overlay_gib.unwrap_or(previous.overlay_gib),
        };
        next.validate()?;
        check(
            next != previous
                && next.storage_gib >= previous.storage_gib
                && next.overlay_gib >= previous.overlay_gib,
        )?;
        Ok(next)
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GrowthChange {
    pub operation_id: String,
    pub request: GrowDisks,
    pub previous: MaterialProof,
    pub immutable_sha256: String,
    pub previous_storage_gib: u64,
    pub previous_overlay_gib: u64,
    pub storage_gib: u64,
    pub overlay_gib: u64,
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GrowthTransition {
    pub schema: u8,
    pub previous: Receipt,
    pub receipt: Receipt,
    pub change: GrowthChange,
}
impl GrowthTransition {
    pub fn validate(&self) -> Result<(), InvalidMessage> {
        self.previous.validate_for(2)?;
        self.receipt.validate_for(2)?;
        self.change.previous.validate()?;
        crate::wire::id(&self.change.operation_id)?;
        crate::wire::hex(&self.change.immutable_sha256, 64)?;
        let before = self.previous.material.as_ref().ok_or(InvalidMessage)?;
        let after = self.receipt.material.as_ref().ok_or(InvalidMessage)?;
        let old_sizes = DiskSizes {
            storage_gib: self.change.previous_storage_gib,
            overlay_gib: self.change.previous_overlay_gib,
        };
        let wanted = self.change.request.targets(old_sizes)?;
        check(wanted == self.sizes())?;
        let mut origin = self.previous.clone();
        origin.material = None;
        let mut supplied = self.receipt.clone();
        supplied.material = None;
        check(self.schema == 1 && origin == supplied && **before == self.change.previous)?;
        if before.revision == 0 {
            check(before.chain_sha256 == hash(&("smolbox-material-origin-v2", &origin))?)?;
        }
        check(
            after.revision == before.revision + 1
                && after.operation_id.as_deref() == Some(&self.change.operation_id),
        )?;
        check(after.request_sha256.as_deref() == Some(&hash(&self.change.request)?))?;
        check(
            after.chain_sha256
                == hash(&(
                    "smolbox-material-transition-v2",
                    &self.change,
                    &after.record_sha256,
                ))?,
        )
    }

    pub fn sizes(&self) -> DiskSizes {
        DiskSizes {
            storage_gib: self.change.storage_gib,
            overlay_gib: self.change.overlay_gib,
        }
    }

    pub fn matches(
        &self,
        previous: &Receipt,
        id: &str,
        request: GrowDisks,
        sizes: DiskSizes,
    ) -> Result<(), InvalidMessage> {
        self.validate()?;
        check(
            self.previous == *previous
                && self.change.operation_id == id
                && self.change.request == request
                && self.change.previous_storage_gib == sizes.storage_gib
                && self.change.previous_overlay_gib == sizes.overlay_gib,
        )
    }
}

fn hash(value: &impl Serialize) -> Result<String, InvalidMessage> {
    let bytes = serde_json::to_vec(value).map_err(|_| InvalidMessage)?;
    Ok(format!("{:x}", Sha256::digest(bytes)))
}
fn check(value: bool) -> Result<(), InvalidMessage> {
    if value {
        Ok(())
    } else {
        Err(InvalidMessage)
    }
}
