//! Separate original SDK-entry fence. Legacy primary Entered is only intent
//! publication; neither it nor a missing sidecar can prove SDK deletion unentered.
use super::ledger::{ProtectedRecord, Version};
use super::*;
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum EntryStage {
    Prepared,
    Entered,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct EntryRecord {
    schema: u8,
    creation_key: String,
    disposal_sha256: String,
    stage: EntryStage,
}
impl EntryRecord {
    fn new(intent: &PartialDisposalIntent) -> Result<Self> {
        intent.validate()?;
        Ok(Self {
            schema: 1,
            creation_key: crate::material::hash(&(
                "smolbox-partial-branch-disposal-v1",
                &intent.request.collection_request.creation,
            ))?,
            disposal_sha256: crate::material::hash(intent)?,
            stage: EntryStage::Prepared,
        })
    }
}
impl ProtectedRecord for EntryRecord {
    const MAX_BYTES: u64 = 4096;
    fn validate_for(&self, ledger: &Ledger) -> Result<()> {
        if self.schema != 1
            || !crate::domain::valid_hex(&self.creation_key, 64)
            || !crate::domain::valid_hex(&self.disposal_sha256, 64)
            || ledger.path
                != ledger.domain.directory.join(format!(
                    "branch-partial-disposal-{}.sdk-entry.json",
                    self.creation_key
                ))
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
}
fn file(domain: Arc<crate::domain::DomainGuard>, intent: &PartialDisposalIntent) -> Result<Ledger> {
    let mut ledger = Ledger::new(domain, &intent.request.collection_request.creation)?;
    ledger.path = ledger.path.with_extension("sdk-entry.json");
    Ok(ledger)
}

pub(in crate::branch::retention) struct RetainedSdkEntry {
    record: EntryRecord,
    attempted: bool,
    published: bool,
}
impl RetainedSdkEntry {
    // Created only alongside the original in-memory disposal intent. Existing
    // primary/sidecar records never reconstruct a missing original cached grant.
    pub(in crate::branch::retention) fn new(intent: &PartialDisposalIntent) -> Result<Self> {
        Ok(Self {
            record: EntryRecord::new(intent)?,
            attempted: false,
            published: false,
        })
    }

    /// Recover only the original visible primary publication, before this
    /// original SDK-entry grant has even attempted publication. Legacy primary
    /// bytes, an existing sidecar or missing cache cannot establish this fact.
    pub(in crate::branch::retention) fn unpublished_primary(
        &self,
        domain: Arc<crate::domain::DomainGuard>,
        intent: &PartialDisposalIntent,
        budget: &ReadBudget,
    ) -> Result<()> {
        if self.record != EntryRecord::new(intent)? || self.attempted || self.published {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let ledger = self.context(domain, intent, budget)?;
        if ledger.read_record::<EntryRecord>()?.is_some() {
            return Err(Error::before(ErrorCode::Ownership));
        }
        budget.check()
    }

    fn context(
        &self,
        domain: Arc<crate::domain::DomainGuard>,
        intent: &PartialDisposalIntent,
        budget: &ReadBudget,
    ) -> Result<Ledger> {
        budget.check()?;
        let expected = EntryRecord::new(intent)?;
        if self.record.creation_key != expected.creation_key
            || self.record.disposal_sha256 != expected.disposal_sha256
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let main = Ledger::new(domain.clone(), &intent.request.collection_request.creation)?;
        let (record, version) = main.read()?.ok_or(Error::before(ErrorCode::Ownership))?;
        if record.intent != *intent || record.stage != Stage::Entered || record.proof.is_some() {
            return Err(Error::before(ErrorCode::Ownership));
        }
        // A residual-removal grant cannot be bypassed by SDK continuation.
        for extension in ["cleanup.json", "cleanup-unneeded.json"] {
            match std::fs::symlink_metadata(main.path.with_extension(extension)) {
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                _ => return Err(Error::before(ErrorCode::Ownership)),
            }
        }
        main.synchronize(&version)?;
        file(domain, intent)
    }

    pub(in crate::branch::retention) fn prepare(
        &mut self,
        domain: Arc<crate::domain::DomainGuard>,
        intent: &PartialDisposalIntent,
        budget: &ReadBudget,
    ) -> Result<()> {
        if self.record.stage != EntryStage::Prepared {
            return Err(Error::uncertain(ErrorCode::State));
        }
        let ledger = self.context(domain, intent, budget)?;
        match ledger.read_record::<EntryRecord>()? {
            Some((record, _)) if self.attempted && record == self.record => {}
            Some(_) => return Err(Error::before(ErrorCode::Ownership)),
            None if self.published => return Err(Error::before(ErrorCode::Ownership)),
            None => {
                // Retain publication attempts before fallible private IO. A
                // matching visible Prepared can be synchronized on retry.
                self.attempted = true;
                ledger.write_record(&self.record, None)?;
            }
        }
        let (record, version) = ledger
            .read_record::<EntryRecord>()?
            .ok_or(Error::before(ErrorCode::Ownership))?;
        if record != self.record {
            return Err(Error::before(ErrorCode::Ownership));
        }
        ledger.synchronize_record::<EntryRecord>(&version)?;
        self.published = true;
        budget.check()
    }

    fn prepared(
        &self,
        domain: Arc<crate::domain::DomainGuard>,
        intent: &PartialDisposalIntent,
        budget: &ReadBudget,
    ) -> Result<(Ledger, Version)> {
        if self.record.stage != EntryStage::Prepared || !self.attempted || !self.published {
            return Err(Error::uncertain(ErrorCode::State));
        }
        let ledger = self.context(domain, intent, budget)?;
        let (record, version) = ledger
            .read_record::<EntryRecord>()?
            .ok_or(Error::before(ErrorCode::Ownership))?;
        if record != self.record {
            return Err(Error::before(ErrorCode::Ownership));
        }
        ledger.synchronize_record::<EntryRecord>(&version)?;
        budget.check()?;
        Ok((ledger, version))
    }

    pub(in crate::branch::retention) fn enter(
        &mut self,
        domain: Arc<crate::domain::DomainGuard>,
        intent: &PartialDisposalIntent,
        budget: &ReadBudget,
    ) -> Result<()> {
        self.enter_with(domain, intent, budget, |ledger, record, version| {
            ledger.write_record(record, Some(version))
        })
    }

    fn enter_with(
        &mut self,
        domain: Arc<crate::domain::DomainGuard>,
        intent: &PartialDisposalIntent,
        budget: &ReadBudget,
        publish: impl FnOnce(&Ledger, &EntryRecord, Version) -> Result<()>,
    ) -> Result<()> {
        let (ledger, version) = self.prepared(domain, intent, budget)?;
        // Spend the original cached grant before publishing SDK entry. Any IO
        // uncertainty after this point forbids another SDK call, even if the
        // protected file remains Prepared. Neither cache nor file can roll back.
        self.record.stage = EntryStage::Entered;
        publish(&ledger, &self.record, version).map_err(|e| Error::uncertain(e.code))?;
        let (record, version) = ledger
            .read_record::<EntryRecord>()?
            .ok_or(Error::uncertain(ErrorCode::Ownership))?;
        if record != self.record {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        ledger
            .synchronize_record::<EntryRecord>(&version)
            .map_err(|e| Error::uncertain(e.code))?;
        budget.check().map_err(|e| Error::uncertain(e.code))
    }
}

#[cfg(test)]
#[path = "sdk_entry/tests.rs"]
mod tests;
