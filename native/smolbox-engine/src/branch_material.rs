//! Source transition and independent child origin for one collected held fork.
//! Neither proof establishes child boot, readiness or release.
use crate::branch::InitialBranchJournal;
use crate::domain::valid_hex;
use crate::material::{check_origin, hash, root_proof};
use crate::{CreationReceipt, Error, ErrorCode, MaterialProof, Result};
use serde::{Deserialize, Serialize};
use smolvm::config::VmRecord;

pub(crate) const PARENT_LABEL: &str = "smolbox.branch-parent";

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct ChildOrigin {
    pub intent: InitialBranchJournal,
    pub generation: String,
    pub raw_child_sha256: String,
}
impl ChildOrigin {
    pub(crate) fn validate(&self) -> Result<()> {
        self.intent.validate()?;
        if !valid_hex(&self.generation, 8)
            || !valid_hex(&self.raw_child_sha256, 64)
            || self.intent.child.owner_token == self.intent.source.owner_token
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
    pub(crate) fn label(&self) -> Result<String> {
        self.validate()?;
        hash(&("smolbox-branch-child-origin-v1", self))
    }
    pub(crate) fn verify_origin(&self, origin: &CreationReceipt) -> Result<()> {
        self.validate()?;
        if origin.target_id != self.intent.source.target_id
            || origin.domain_generation != self.intent.source.domain_generation
            || origin.name != self.intent.child.name
            || origin.owner_token != self.intent.child.owner_token
            || origin.incarnation != self.intent.child.incarnation
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
    pub(crate) fn verify_record(&self, record: &VmRecord) -> Result<()> {
        self.validate()?;
        if record.name != self.intent.child.name
            || record.labels.get("smolbox.owner") != Some(&self.intent.child.owner_token)
            || record.labels.get("smolbox.incarnation") != Some(&self.intent.child.incarnation)
            || record.labels.get(PARENT_LABEL) != Some(&self.label()?)
            || record.golden.as_deref() != Some(self.intent.source.name.as_str())
            || record.fork_generation.as_ref() != Some(&self.generation)
            || record.forkable
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
    pub(crate) fn owned_record(&self, raw: &VmRecord) -> Result<VmRecord> {
        self.validate()?;
        if crate::identity::material_hash(raw)? != self.raw_child_sha256
            || raw.state != smolvm::config::RecordState::Created
            || raw.pid.is_some()
            || raw.pid_start_time.is_some()
            || !raw.forkpoint_held
            || !raw.fork_env.is_empty()
            || raw.labels.contains_key(PARENT_LABEL)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        let mut owned = raw.clone();
        owned.labels.insert(
            "smolbox.owner".into(),
            self.intent.child.owner_token.clone(),
        );
        owned.labels.insert(
            "smolbox.incarnation".into(),
            self.intent.child.incarnation.clone(),
        );
        owned.labels.insert(PARENT_LABEL.into(), self.label()?);
        self.verify_record(&owned)?;
        Ok(owned)
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BranchSourceChange {
    pub(crate) child_origin: ChildOrigin,
    pub(crate) child: CreationReceipt,
    pub(crate) platform: String,
    pub(crate) previous_lineage: Option<u64>,
    pub(crate) lineage: Option<u64>,
    pub(crate) previous_growth_sha256: String,
    pub(crate) growth_sha256: String,
    pub(crate) previous_capture_sha256: String,
    pub(crate) capture_sha256: String,
    pub(crate) checkpoint_head: Option<String>,
}
impl BranchSourceChange {
    pub fn operation_id(&self) -> &str {
        &self.child_origin.intent.child.operation_id
    }
    pub fn request_sha256(&self) -> &str {
        &self.child_origin.intent.request_sha256
    }
    pub fn child(&self) -> &CreationReceipt {
        &self.child
    }
    pub(crate) fn validate(&self) -> Result<()> {
        self.child_origin.verify_origin(&self.child)?;
        let mut child_root = self.child.clone();
        child_root.material = None;
        let expected_lineage = match self.platform.as_str() {
            "linux" => Some(self.child_origin.intent.source_pid.1),
            "macos" => self.previous_lineage,
            _ => return Err(Error::before(ErrorCode::Ownership)),
        };
        if self.child.material.as_ref() != Some(&root_proof(&child_root)?)
            || !valid_hex(&self.child.material_sha256, 64)
            || self.lineage != expected_lineage
            || self.previous_lineage == Some(0)
            || [
                &self.previous_growth_sha256,
                &self.growth_sha256,
                &self.previous_capture_sha256,
                &self.capture_sha256,
            ]
            .iter()
            .any(|s| !valid_hex(s, 64))
            || self
                .checkpoint_head
                .as_ref()
                .is_some_and(|s| !valid_hex(s, 32))
            || (self.lineage == self.previous_lineage
                && (self.previous_growth_sha256 != self.growth_sha256
                    || self.previous_capture_sha256 != self.capture_sha256))
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BranchPublication {
    pub schema: u8,
    pub previous: CreationReceipt,
    pub receipt: CreationReceipt,
    pub change: BranchSourceChange,
}
impl std::fmt::Debug for BranchPublication {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("BranchPublication")
            .field("schema", &self.schema)
            .finish_non_exhaustive()
    }
}
impl BranchPublication {
    pub fn child(&self) -> &CreationReceipt {
        self.change.child()
    }
    pub fn validate(&self) -> Result<()> {
        self.change.validate()?;
        let mut origin = self.previous.clone();
        origin.material = None;
        check_origin(&origin, &self.receipt)?;
        let proof = self
            .receipt
            .material
            .as_ref()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        let previous = self
            .previous
            .material
            .as_ref()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        if self.schema != 1
            || self.previous != self.change.child_origin.intent.source
            || (previous.revision == 0 && *previous != root_proof(&origin)?)
            || *proof != next_proof(&self.change, proof.record_sha256.clone())?
            || (self.change.lineage == self.change.previous_lineage
                && proof.record_sha256 != previous.record_sha256)
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        proof.validate()
    }
    /// Derive ownership only from an original entered intent and the exact
    /// collected SDK projection, before publishing any child labels or files.
    pub(crate) fn issue(
        intent: &InitialBranchJournal,
        before: &VmRecord,
        source: &VmRecord,
        raw: &VmRecord,
        generation: &str,
    ) -> Result<(Self, VmRecord)> {
        crate::branch_worker::verify_sdk_result(
            intent,
            before,
            source,
            &smolvm::agent::fork::PreparedFork {
                snapshot_dir: smolvm::agent::vm_data_dir(&before.name)
                    .join("s")
                    .join(generation),
                clone_record: raw.clone(),
                port_remaps: vec![],
                source_continues: true,
            },
        )?;
        let binding = ChildOrigin {
            intent: intent.clone(),
            generation: generation.into(),
            raw_child_sha256: crate::identity::material_hash(raw)?,
        };
        let owned = binding.owned_record(raw)?;
        let child_root = CreationReceipt {
            target_id: intent.source.target_id.clone(),
            domain_generation: intent.source.domain_generation.clone(),
            name: intent.child.name.clone(),
            owner_token: intent.child.owner_token.clone(),
            incarnation: intent.child.incarnation.clone(),
            material_sha256: crate::identity::material_hash(&owned)?,
            material: None,
        };
        let mut child = child_root.clone();
        child.material = Some(root_proof(&child_root)?);
        let change = BranchSourceChange {
            child_origin: binding,
            child,
            platform: std::env::consts::OS.into(),
            previous_lineage: before.fork_lineage_pid_start_time,
            lineage: source.fork_lineage_pid_start_time,
            previous_growth_sha256: crate::material::immutable_hash(before)?,
            growth_sha256: crate::material::immutable_hash(source)?,
            previous_capture_sha256: crate::material::capture_immutable_hash(before)?,
            capture_sha256: crate::material::capture_immutable_hash(source)?,
            checkpoint_head: source.checkpoint_head.clone(),
        };
        let mut receipt = intent.source.clone();
        receipt.material = Some(next_proof(
            &change,
            crate::identity::material_hash(source)?,
        )?);
        let publication = Self {
            schema: 1,
            previous: intent.source.clone(),
            receipt,
            change,
        };
        publication.validate()?;
        Ok((publication, owned))
    }
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Completed {
    pub change: BranchSourceChange,
    pub proof: MaterialProof,
}
pub(crate) fn next_proof(
    change: &BranchSourceChange,
    record_sha256: String,
) -> Result<MaterialProof> {
    change.validate()?;
    let previous = change
        .child_origin
        .intent
        .source
        .material
        .as_ref()
        .ok_or(Error::before(ErrorCode::Ownership))?;
    let proof = MaterialProof {
        schema: 2,
        revision: previous.revision + 1,
        record_sha256: record_sha256.clone(),
        chain_sha256: hash(&(
            "smolbox-branch-source-transition-v1",
            change,
            &record_sha256,
        ))?,
        operation_id: Some(change.operation_id().into()),
        request_sha256: Some(change.request_sha256().into()),
    };
    proof.validate()?;
    Ok(proof)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::{branch_worker, material::MaterialJournal, Engine};
    use std::os::unix::fs::PermissionsExt;

    // Private SDK-row and protected-file model only. There is no VMM, native
    // source enrollment, live persistence interruption or default namespace use.
    struct Fixture {
        _temp: tempfile::TempDir,
        engine: Engine,
        metadata: branch_worker::Metadata,
        expected: branch_worker::Expected,
        before: VmRecord,
        source: VmRecord,
        raw: VmRecord,
        owned: VmRecord,
        publication: BranchPublication,
    }
    impl Fixture {
        fn new() -> Self {
            Self::with_hold(false)
        }
        fn with_hold(hold: bool) -> Self {
            let (temp, mut metadata, _) = branch_worker::tests::fixture();
            crate::branch::tests::set_initial_hold(&mut metadata.grant.intent, hold);
            let (_, expected) = metadata.encode().unwrap();
            let engine = crate::machine::tests::test_engine(temp.path());
            let before = engine
                .db
                .get_vm(&metadata.grant.intent.source.name)
                .unwrap()
                .unwrap();
            let journal = MaterialJournal::at(&metadata.source_directory);
            journal
                .prepare_initial_branch(&metadata.grant.intent, &before)
                .unwrap();
            journal
                .enter_branch_preparation(&metadata.grant, &expected, &before)
                .unwrap();
            let mut source = before.clone();
            if cfg!(target_os = "linux") {
                source.fork_lineage_pid_start_time = source.pid_start_time;
            }
            let mut raw = source.clone();
            raw.name = metadata.grant.intent.child.name.clone();
            raw.state = smolvm::config::RecordState::Created;
            raw.pid = None;
            raw.pid_start_time = None;
            raw.created_at += 1;
            raw.golden = Some(source.name.clone());
            raw.fork_overlay_owner = Some(source.name.clone());
            raw.fork_generation = Some("aabbccdd".into());
            raw.fork_lineage_pid_start_time = None;
            raw.forkable = false;
            raw.forkpoint_held = true;
            raw.fork_env.clear();
            let (publication, owned) = BranchPublication::issue(
                &metadata.grant.intent,
                &before,
                &source,
                &raw,
                "aabbccdd",
            )
            .unwrap();
            engine
                .db
                .update_vm(&source.name, |record| *record = source.clone())
                .unwrap();
            engine.db.insert_vm(&raw.name, &raw).unwrap();
            let child = engine.vm_directory(&raw.name);
            std::fs::create_dir_all(&child).unwrap();
            std::fs::set_permissions(&child, std::fs::Permissions::from_mode(0o700)).unwrap();
            Self {
                _temp: temp,
                engine,
                metadata,
                expected,
                before,
                source,
                raw,
                owned,
                publication,
            }
        }
        fn journal(&self) -> MaterialJournal {
            MaterialJournal::at(&self.metadata.source_directory)
        }
        // A second private row/file preparation on the same original source.
        // This models an SDK result; no VMM, live actor or source is enrolled.
        fn next(mut self) -> Self {
            self.before = self.source.clone();
            let mut intent = crate::branch::tests::initial_journal_named(
                &self.publication.receipt,
                &self.before,
                "second-branch",
            );
            intent.child.name = "second-child".into();
            intent.child.owner_token = "7".repeat(64);
            intent.child.incarnation = "8".repeat(32);
            crate::branch::tests::set_initial_hold(&mut intent, true);
            self.metadata.grant.intent = intent;
            self.metadata.grant.worker_operation = "b".repeat(32);
            self.expected = self.metadata.encode().unwrap().1;
            self.journal()
                .prepare_initial_branch(&self.metadata.grant.intent, &self.before)
                .unwrap();
            self.journal()
                .enter_branch_preparation(&self.metadata.grant, &self.expected, &self.before)
                .unwrap();
            self.raw = self.source.clone();
            self.raw.name = self.metadata.grant.intent.child.name.clone();
            self.raw.state = smolvm::config::RecordState::Created;
            self.raw.pid = None;
            self.raw.pid_start_time = None;
            self.raw.created_at += 2;
            self.raw.golden = Some(self.source.name.clone());
            self.raw.fork_overlay_owner = Some(self.source.name.clone());
            self.raw.fork_generation = Some("bbccddee".into());
            self.raw.fork_lineage_pid_start_time = None;
            self.raw.forkable = false;
            self.raw.forkpoint_held = true;
            self.raw.fork_env.clear();
            (self.publication, self.owned) = BranchPublication::issue(
                &self.metadata.grant.intent,
                &self.before,
                &self.source,
                &self.raw,
                "bbccddee",
            )
            .unwrap();
            self.engine.db.insert_vm(&self.raw.name, &self.raw).unwrap();
            let directory = self.child_directory();
            std::fs::create_dir_all(&directory).unwrap();
            std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700)).unwrap();
            self
        }
        fn child_directory(&self) -> std::path::PathBuf {
            self.engine.vm_directory(&self.raw.name)
        }
        fn begin(&self) {
            self.journal()
                .begin_branch_publication(
                    &self.metadata.grant,
                    &self.expected,
                    &self.publication,
                    &self.before,
                    &self.source,
                    &self.raw,
                )
                .unwrap();
        }
        fn publish_child(&self) {
            self.engine
                .db
                .update_vm(&self.raw.name, |record| *record = self.owned.clone())
                .unwrap();
            crate::machine::publish_branch_marker(
                self.publication.child(),
                &self.child_directory(),
            )
            .unwrap();
            MaterialJournal::at(&self.child_directory())
                .initialize_branch_child(&self.publication, &self.owned)
                .unwrap();
        }
        fn complete(&self) -> Result<BranchPublication> {
            // Hypothetical previously verified original source facts. This
            // typed value is not evidence that this test enrolled a real PID.
            let pid = self.metadata.grant.intent.source_pid;
            let authority = crate::capture_resolution::SourceAuthority::verify(
                &self.source,
                pid,
                crate::capture_resolution::SourceFacts {
                    owner: Some(true),
                    runtime_pid: Some(pid.0),
                    original_alive: true,
                    observed_birth: Some(pid.1),
                    excluded: false,
                },
            )?;
            self.journal().complete_branch_publication(
                &self.metadata.grant,
                &self.expected,
                &self.publication,
                (&self.source, &self.owned),
                &self.child_directory(),
                &authority,
            )
        }
    }

    /// Fully published private row/file model; no native process is enrolled.
    pub(crate) fn publication_model() -> (tempfile::TempDir, Engine, BranchPublication, VmRecord) {
        publication_model_with_hold(false)
    }
    pub(crate) fn publication_model_with_hold(
        hold: bool,
    ) -> (tempfile::TempDir, Engine, BranchPublication, VmRecord) {
        let f = Fixture::with_hold(hold);
        f.begin();
        f.publish_child();
        f.complete().unwrap();
        (f._temp, f.engine, f.publication, f.owned)
    }

    fn read_budget() -> crate::ReadBudget {
        crate::ReadBudget::new(
            std::time::Duration::from_secs(5),
            crate::Cancellation::default(),
        )
        .unwrap()
    }
    #[test]
    fn subsequent_branch_preserves_earlier_leaf_and_advances_only_current_source_head() {
        let first = Fixture::new();
        first.begin();
        first.publish_child();
        let original = first.complete().unwrap();
        let first_child = crate::material::hash(&first.owned).unwrap();
        let f = first.next();
        let budget = read_budget();
        let names = crate::sdk_compat::source_dependents(
            &f.metadata.database,
            f.engine.database_identity,
            &f.source.name,
            &budget,
        )
        .unwrap();
        assert_eq!(names.len(), 2);
        let verify = |joining: Option<&str>| {
            f.journal().branch_dependencies(
                &original.receipt,
                joining,
                &names,
                &f.metadata.database,
                f.engine.database_identity,
                &budget,
            )
        };
        assert!(verify(Some(&f.raw.name)).unwrap());
        assert!(!verify(None).unwrap());
        assert!(!verify(Some("another-child")).unwrap());
        f.engine
            .db
            .update_vm(&original.child().name, |child| child.forkpoint_held = false)
            .unwrap();
        assert!(!verify(Some(&f.raw.name)).unwrap());
        f.engine
            .db
            .update_vm(&original.child().name, |child| child.forkpoint_held = true)
            .unwrap();
        assert!(verify(Some(&f.raw.name)).unwrap());
        f.begin();
        f.publish_child();
        let result = f.complete().unwrap();
        assert_eq!(result.previous, original.receipt);
        assert_eq!(
            result.receipt.material_sha256,
            original.receipt.material_sha256
        );
        assert_eq!(
            result.receipt.material.as_ref().unwrap().revision,
            original.receipt.material.as_ref().unwrap().revision + 1
        );
        assert_ne!(result.child().owner_token, original.child().owner_token);
        assert!(f.journal().verify(&original.receipt).is_err());
        assert!(f
            .journal()
            .continuing_branch_children(
                &result.receipt,
                &names,
                &f.metadata.database,
                f.engine.database_identity,
                &budget,
            )
            .unwrap());
        assert_eq!(
            crate::material::hash(&f.engine.db.get_vm(&original.child().name).unwrap().unwrap())
                .unwrap(),
            first_child
        );
    }
    #[test]
    fn entered_branch_can_exempt_only_its_own_child_and_never_an_unknown_sibling() {
        let f = Fixture::new();
        f.begin();
        f.publish_child();
        f.complete().unwrap();
        let f = f.next();
        let mut foreign = f.raw.clone();
        foreign.name = "unknown-sibling".into();
        f.engine.db.insert_vm(&foreign.name, &foreign).unwrap();
        let budget = read_budget();
        let names = crate::sdk_compat::source_dependents(
            &f.metadata.database,
            f.engine.database_identity,
            &f.source.name,
            &budget,
        )
        .unwrap();
        assert!(!f
            .journal()
            .branch_dependencies(
                &f.metadata.grant.intent.source,
                Some(&f.raw.name),
                &names,
                &f.metadata.database,
                f.engine.database_identity,
                &budget,
            )
            .unwrap());
        assert!(!f
            .journal()
            .branch_dependencies(
                &f.metadata.grant.intent.source,
                Some(&f.raw.name),
                &[f.raw.name.clone(), f.raw.name.clone()],
                &f.metadata.database,
                f.engine.database_identity,
                &budget,
            )
            .unwrap());
    }
    #[test]
    fn prepared_next_branch_keeps_siblings_and_requires_exact_unentered_declaration() {
        let f = Fixture::new();
        f.begin();
        f.publish_child();
        let completed = f.complete().unwrap();
        let mut intent = crate::branch::tests::initial_journal_named(
            &completed.receipt,
            &f.source,
            "prepared-second-branch",
        );
        intent.child.name = "next-unentered-child".into();
        crate::branch::tests::set_initial_hold(&mut intent, true);
        f.journal()
            .prepare_initial_branch(&intent, &f.source)
            .unwrap();
        let bytes =
            std::fs::read(f.metadata.source_directory.join("smolbox.material-v2.json")).unwrap();
        let budget = read_budget();
        let verify = |joining: Option<&str>, names: &[String]| {
            f.journal().branch_dependencies(
                &completed.receipt,
                joining,
                names,
                &f.metadata.database,
                f.engine.database_identity,
                &budget,
            )
        };
        assert!(verify(
            Some(&intent.child.name),
            std::slice::from_ref(&f.owned.name)
        )
        .unwrap());
        assert!(!verify(None, std::slice::from_ref(&f.owned.name)).unwrap());
        assert!(!verify(
            Some(&intent.child.name),
            &[f.owned.name.clone(), intent.child.name.clone()]
        )
        .unwrap());
        budget.cancel.cancel();
        assert!(verify(
            Some(&intent.child.name),
            std::slice::from_ref(&f.owned.name)
        )
        .is_err());
        assert_eq!(
            std::fs::read(f.metadata.source_directory.join("smolbox.material-v2.json")).unwrap(),
            bytes
        );
    }
    #[test]
    fn published_siblings_cannot_substitute_original_branch_or_capture_enrollment() {
        let (_temp, engine, publication, _) = publication_model();
        let before = engine.jobs.counts();
        let error = engine
            .branch_preflight(&publication.receipt, &read_budget())
            .unwrap_err();
        assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
        assert_eq!(engine.jobs.counts(), before);
        let record = engine
            .db
            .get_vm(&publication.receipt.name)
            .unwrap()
            .unwrap();
        assert!(engine
            .capture_source_authority(
                &publication.receipt,
                record.pid.zip(record.pid_start_time).unwrap(),
                &record,
            )
            .is_err());
        engine.verify_record(&publication.receipt, &record).unwrap();
    }

    #[test]
    fn continuing_source_metadata_requires_exact_published_children_and_current_heads() {
        let (_temp, engine, publication, child) = publication_model();
        let journal = MaterialJournal::at(&engine.vm_directory(&publication.previous.name));
        let budget = crate::ReadBudget::new(
            std::time::Duration::from_secs(5),
            crate::Cancellation::default(),
        )
        .unwrap();
        let names = vec![child.name.clone()];
        let verify = || {
            journal.continuing_branch_children(
                &publication.receipt,
                &names,
                &engine.binding().database,
                engine.database_identity,
                &budget,
            )
        };
        assert!(verify().unwrap()); // File/row candidacy only, no original-live-source witness.
        engine
            .db
            .update_vm(&child.name, |actual| actual.forkpoint_held = false)
            .unwrap();
        assert!(!verify().unwrap());
        engine
            .db
            .update_vm(&child.name, |actual| *actual = child.clone())
            .unwrap();
        assert!(verify().unwrap());
        engine
            .db
            .update_vm(&child.name, |actual| {
                actual.labels.insert("smolbox.owner".into(), "f".repeat(64));
            })
            .unwrap();
        assert!(!verify().unwrap());
        engine
            .db
            .update_vm(&child.name, |actual| *actual = child.clone())
            .unwrap();
        let mut foreign = child.clone();
        foreign.name = "unpublished-child".into();
        engine.db.insert_vm(&foreign.name, &foreign).unwrap();
        assert!(!journal
            .continuing_branch_children(
                &publication.receipt,
                &[child.name, foreign.name],
                &engine.binding().database,
                engine.database_identity,
                &budget
            )
            .unwrap());
    }

    #[test]
    fn inventory_dependencies_without_protected_branch_history_cannot_be_continuing_authority() {
        let temp = tempfile::tempdir().unwrap();
        let (engine, receipt) = crate::export_source::tests::fixture(temp.path(), false);
        let budget = crate::ReadBudget::new(
            std::time::Duration::from_secs(5),
            crate::Cancellation::default(),
        )
        .unwrap();
        let journal = MaterialJournal::at(&engine.vm_directory(&receipt.name));
        assert!(!journal
            .continuing_branch_children(
                &receipt,
                &["inventory-only".into()],
                &engine.binding().database,
                engine.database_identity,
                &budget
            )
            .unwrap());
    }

    #[test]
    fn source_transition_and_child_origin_bind_independent_identities_and_exact_sdk_projection() {
        let f = Fixture::new();
        f.publication.validate().unwrap();
        assert_ne!(
            f.publication.child().owner_token,
            f.publication.previous.owner_token
        );
        assert_ne!(
            f.publication.child().incarnation,
            f.publication.previous.incarnation
        );
        assert!(!f.publication.child().matches(&f.raw).unwrap());
        assert!(f.publication.child().matches(&f.owned).unwrap());
        assert!(f
            .publication
            .change
            .child_origin
            .verify_record(&f.raw)
            .is_err());
        assert_eq!(
            f.publication.previous.material_sha256,
            f.publication.receipt.material_sha256
        );
        assert_eq!(f.publication.receipt.material.as_ref().unwrap().revision, 1);
        if cfg!(target_os = "macos") {
            assert_eq!(
                f.publication
                    .previous
                    .material
                    .as_ref()
                    .unwrap()
                    .record_sha256,
                f.publication
                    .receipt
                    .material
                    .as_ref()
                    .unwrap()
                    .record_sha256
            );
        }
        let debug = format!("{:?}", f.publication);
        assert!(!debug.contains(&f.publication.child().owner_token));
        for case in 0..8 {
            let mut changed = f.publication.clone();
            match case {
                0 => changed.change.child.owner_token = "f".repeat(64),
                1 => changed.change.child.incarnation = "f".repeat(32),
                2 => changed.change.child_origin.generation = "eeff0011".into(),
                3 => changed.change.platform = "windows".into(),
                4 => {
                    changed
                        .change
                        .child
                        .material
                        .as_mut()
                        .unwrap()
                        .record_sha256 = "f".repeat(64)
                }
                5 => changed.receipt.material.as_mut().unwrap().revision += 1,
                6 => changed.previous.material_sha256 = "f".repeat(64),
                _ => {
                    changed.change.child_origin.intent.child.owner_token =
                        f.publication.previous.owner_token.clone()
                }
            }
            assert!(changed.validate().is_err(), "{case}");
        }
        let mut foreign = f.raw.clone();
        foreign.storage_gb = Some(2);
        assert!(BranchPublication::issue(
            &f.metadata.grant.intent,
            &f.before,
            &f.source,
            &foreign,
            "aabbccdd"
        )
        .is_err());
    }

    #[test]
    fn durable_publication_requires_child_identity_and_preserves_exact_result_without_sdk_replay() {
        let f = Fixture::new();
        assert!(f.complete().is_err());
        f.begin();
        let source_file = f.metadata.source_directory.join("smolbox.material-v2.json");
        let pending = std::fs::read(&source_file).unwrap();
        f.begin();
        assert_eq!(std::fs::read(&source_file).unwrap(), pending);
        assert!(f
            .journal()
            .authorize_branch_preparation(&f.metadata.grant, &f.expected, &f.before)
            .is_err());
        assert!(f.complete().is_err());
        crate::machine::publish_branch_marker(f.publication.child(), &f.child_directory()).unwrap();
        assert!(f.complete().is_err()); // Marker alone is not a child root journal.
        f.publish_child();
        let completed = f.complete().unwrap();
        assert!(completed == f.publication);
        let reopened = f.journal();
        reopened.verify(&completed.receipt).unwrap();
        assert!(reopened.verify(&completed.previous).is_err());
        f.engine.verify_record(completed.child(), &f.owned).unwrap();
        let child_file = f.child_directory().join("smolbox.material-v2.json");
        let child_bytes = std::fs::read(&child_file).unwrap();
        let binding: serde_json::Value = serde_json::from_slice(&child_bytes).unwrap();
        assert!(binding.get("branch_child").is_some());
        let child_journal = MaterialJournal::at(&f.child_directory());
        child_journal
            .initialize_branch_child(&completed, &f.owned)
            .unwrap();
        assert_eq!(std::fs::read(child_file).unwrap(), child_bytes);
        let bytes = std::fs::read(&source_file).unwrap();
        assert!(f.complete().is_err()); // Completion is lookup-only after publication.
        let result = reopened
            .completed_branch_publication(
                &completed.previous,
                completed.change.operation_id(),
                completed.change.request_sha256(),
            )
            .unwrap()
            .unwrap();
        assert!(result == completed);
        assert_eq!(std::fs::read(source_file).unwrap(), bytes);
        let mut foreign = f.owned.clone();
        foreign.labels.insert(PARENT_LABEL.into(), "f".repeat(64));
        assert!(f.engine.verify_record(completed.child(), &foreign).is_err());
    }

    #[test]
    fn publication_history_rejects_reordering_cross_identity_and_operation_reuse() {
        let f = Fixture::new();
        f.begin();
        f.publish_child();
        f.complete().unwrap();
        let path = f.metadata.source_directory.join("smolbox.material-v2.json");
        let original: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        for case in 0..6 {
            let mut value = original.clone();
            match case {
                0 => {
                    let entry = value["branch_history"][0].clone();
                    value["branch_history"].as_array_mut().unwrap().push(entry);
                }
                1 => value["branch_history"] = serde_json::json!([]),
                2 => {
                    value["head"] = serde_json::to_value(&f.publication.previous.material).unwrap()
                }
                3 => {
                    value["branch_history"][0]["change"]["child"]["owner_token"] =
                        "f".repeat(64).into()
                }
                4 => {
                    value["branch_history"][0]["change"]["previous_growth_sha256"] =
                        "f".repeat(64).into()
                }
                _ => value["branch_history"][0]["proof"]["operation_id"] = "other-operation".into(),
            }
            std::fs::write(&path, serde_json::to_vec(&value).unwrap()).unwrap();
            assert!(
                f.journal().verify(&f.publication.receipt).is_err(),
                "{case}"
            );
        }
        std::fs::write(&path, serde_json::to_vec(&original).unwrap()).unwrap();
        let bytes = std::fs::read(&path).unwrap();
        assert!(f
            .journal()
            .prepare_capture(
                &f.publication.receipt,
                f.publication.change.operation_id(),
                crate::CaptureRequest {
                    max_bytes: 1024,
                    idle: true
                },
                &f.source
            )
            .is_err());
        assert_eq!(std::fs::read(&path).unwrap(), bytes);
        // Material-chain model only: actual capture eligibility must separately
        // exclude live child dependencies before SDK dispatch.
        let permit = f
            .journal()
            .prepare_capture(
                &f.publication.receipt,
                "later-capture",
                crate::CaptureRequest {
                    max_bytes: 1024,
                    idle: true,
                },
                &f.source,
            )
            .unwrap();
        f.journal().enter_capture(&permit).unwrap();
        let mut captured = f.source.clone();
        captured.checkpoint_head = Some("e".repeat(32));
        let next = f
            .journal()
            .complete_capture(
                &f.publication.receipt,
                &permit,
                crate::CaptureArtifact {
                    sha256: "d".repeat(64),
                    size_bytes: 1,
                    head: "e".repeat(32),
                    parent: f.source.checkpoint_head.clone(),
                },
                &captured,
            )
            .unwrap();
        f.journal().verify(&next.receipt).unwrap();
        assert!(
            f.journal()
                .completed_branch_publication(
                    &f.publication.previous,
                    f.publication.change.operation_id(),
                    f.publication.change.request_sha256()
                )
                .unwrap()
                .as_ref()
                == Some(&f.publication)
        );
    }

    #[test]
    fn child_marker_retry_never_overwrites_foreign_or_linked_identity_and_unbranched_fields_stay_omitted(
    ) {
        let f = Fixture::new();
        let source: serde_json::Value = serde_json::from_slice(
            &std::fs::read(f.metadata.source_directory.join("smolbox.material-v2.json")).unwrap(),
        )
        .unwrap();
        assert!(source.get("branch_history").is_none() && source.get("branch_child").is_none());
        f.begin();
        f.publish_child();
        let marker = f.child_directory().join("smolbox.incarnation");
        let original = std::fs::read(&marker).unwrap();
        let linked = f.child_directory().join("linked-marker");
        std::fs::hard_link(&marker, &linked).unwrap();
        assert!(
            crate::machine::publish_branch_marker(f.publication.child(), &f.child_directory())
                .is_err()
        );
        std::fs::remove_file(linked).unwrap();
        std::fs::write(&marker, b"foreign incarnation").unwrap();
        assert!(
            crate::machine::publish_branch_marker(f.publication.child(), &f.child_directory())
                .is_err()
        );
        assert_eq!(std::fs::read(&marker).unwrap(), b"foreign incarnation");
        assert!(f.complete().is_err());
        std::fs::write(marker, original).unwrap();
        f.complete().unwrap();
    }
}
