//! Typed branch creation authority. Hashes bind evidence; admission and original
//! manager ownership remain in the engine, never in these wire values.
use crate::{InvalidMessage, MaterialProof, Receipt};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

fn check(value: bool) -> Result<(), InvalidMessage> {
    if value {
        Ok(())
    } else {
        Err(InvalidMessage)
    }
}
fn hash(value: &impl Serialize) -> Result<String, InvalidMessage> {
    Ok(format!(
        "{:x}",
        Sha256::digest(serde_json::to_vec(value).map_err(|_| InvalidMessage)?)
    ))
}
fn origin(receipt: &Receipt) -> Receipt {
    let mut value = receipt.clone();
    value.material = None;
    value
}
fn root(receipt: &Receipt) -> Result<MaterialProof, InvalidMessage> {
    Ok(MaterialProof {
        schema: 2,
        revision: 0,
        record_sha256: receipt.material_sha256.clone(),
        chain_sha256: hash(&("smolbox-material-origin-v2", origin(receipt)))?,
        operation_id: None,
        request_sha256: None,
    })
}
#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BranchResources {
    pub slots: u64,
    pub cpus: u64,
    pub memory_mb: u64,
    pub disk_gb: u64,
}
impl BranchResources {
    fn validate(&self) -> Result<(), InvalidMessage> {
        check(
            [self.slots, self.cpus, self.memory_mb, self.disk_gb]
                .iter()
                .all(|n| (1..=1_048_576).contains(n)),
        )
    }
    fn add(self, other: Self) -> Result<Self, InvalidMessage> {
        let sum = |a: u64, b: u64| a.checked_add(b).ok_or(InvalidMessage);
        Ok(Self {
            slots: sum(self.slots, other.slots)?,
            cpus: sum(self.cpus, other.cpus)?,
            memory_mb: sum(self.memory_mb, other.memory_mb)?,
            disk_gb: sum(self.disk_gb, other.disk_gb)?,
        })
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BranchApproval {
    pub id: String,
    pub host_overhead_mb: u64,
    pub resources: BranchResources,
}
impl BranchApproval {
    pub fn validate(&self) -> Result<(), InvalidMessage> {
        crate::wire::id(&self.id)?;
        self.resources.validate()?;
        check((128..=16_384).contains(&self.host_overhead_mb))
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BranchChildIntent {
    pub operation_id: String,
    pub name: String,
    pub owner_token: String,
    pub incarnation: String,
    pub idle: bool,
    pub hold: bool,
}
impl BranchChildIntent {
    fn validate(&self, source: &Receipt) -> Result<(), InvalidMessage> {
        crate::wire::id(&self.operation_id)?;
        crate::wire::id(&self.name)?;
        crate::wire::hex(&self.owner_token, 64)?;
        crate::wire::hex(&self.incarnation, 32)?;
        check(
            self.name != source.name
                && self.incarnation != source.incarnation
                && self.owner_token != source.owner_token
                && self.idle,
        )
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BranchReleaseRequest {
    pub operation_id: String,
    pub request_sha256: String,
}
impl BranchReleaseRequest {
    fn validate(&self) -> Result<(), InvalidMessage> {
        crate::wire::id(&self.operation_id)?;
        crate::wire::hex(&self.request_sha256, 64)
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BranchCreateRequest {
    pub source: Receipt,
    pub child: BranchChildIntent,
    pub approval: BranchApproval,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "crate::wire::present_optional"
    )]
    pub initial_release: Option<BranchReleaseRequest>,
}
impl BranchCreateRequest {
    pub fn validate(&self) -> Result<(), InvalidMessage> {
        self.source.validate_for(2)?;
        self.child.validate(&self.source)?;
        self.approval.validate()?;
        check(self.source.material.is_some())?;
        match (self.child.hold, &self.initial_release) {
            (true, None) => Ok(()),
            (false, Some(release)) => {
                release.validate()?;
                check(release.operation_id != self.child.operation_id)
            }
            _ => Err(InvalidMessage),
        }
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BranchResourcePlan {
    pub ordinary_child: BranchResources,
    pub total_additional: BranchResources,
    pub minimum_extra_memory_mb: u64,
    pub minimum_extra_disk_gb: u64,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BranchIntent {
    pub source: Receipt,
    pub child: BranchChildIntent,
    pub approval: BranchApproval,
    pub plan: BranchResourcePlan,
    pub request_sha256: String,
    pub source_pid: (i32, u64),
    pub epoch: String,
}
impl BranchIntent {
    pub(crate) fn validate(&self) -> Result<(), InvalidMessage> {
        self.source.validate_for(2)?;
        self.child.validate(&self.source)?;
        self.approval.validate()?;
        crate::wire::hex(&self.epoch, 32)?;
        let before = self.source.material.as_ref().ok_or(InvalidMessage)?;
        let child = self.plan.ordinary_child;
        let memory = child
            .memory_mb
            .checked_sub(self.approval.host_overhead_mb)
            .ok_or(InvalidMessage)?;
        let disks = child
            .disk_gb
            .checked_mul(2)
            .and_then(|n| n.checked_add(memory.div_ceil(1024)))
            .ok_or(InvalidMessage)?;
        check(
            before.revision < 1024
                && self.source_pid.0 > 0
                && self.source_pid.1 > 0
                && child.slots == 1
                && (1..=16).contains(&child.cpus)
                && (64..=65_536).contains(&memory)
                && (2..=2048).contains(&child.disk_gb)
                && self.plan.minimum_extra_memory_mb == child.memory_mb
                && self.plan.minimum_extra_disk_gb == disks
                && self.approval.resources.memory_mb >= child.memory_mb
                && self.approval.resources.disk_gb >= disks
                && self.plan.total_additional == child.add(self.approval.resources)?,
        )?;
        check(
            self.request_sha256
                == hash(&(
                    "smolbox-initial-branch-admission-v1",
                    "9f446ae00219148ca4a703914f44a8e2fab11655",
                    "shared-materialized-ram",
                    &self.source,
                    &self.child,
                    &self.approval,
                    &self.plan,
                    self.source_pid,
                    &self.epoch,
                ))?,
        )
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BranchChildOrigin {
    pub intent: BranchIntent,
    pub generation: String,
    pub raw_child_sha256: String,
}
impl BranchChildOrigin {
    fn validate(&self, child: &Receipt) -> Result<(), InvalidMessage> {
        self.intent.validate()?;
        crate::wire::hex(&self.generation, 8)?;
        crate::wire::hex(&self.raw_child_sha256, 64)?;
        check(
            child.target_id == self.intent.source.target_id
                && child.domain_generation == self.intent.source.domain_generation
                && child.name == self.intent.child.name
                && child.owner_token == self.intent.child.owner_token
                && child.incarnation == self.intent.child.incarnation,
        )
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BranchSourceChange {
    pub child_origin: BranchChildOrigin,
    pub child: Receipt,
    pub platform: String,
    #[serde(deserialize_with = "crate::wire::required_nullable")]
    pub previous_lineage: Option<u64>,
    #[serde(deserialize_with = "crate::wire::required_nullable")]
    pub lineage: Option<u64>,
    pub previous_growth_sha256: String,
    pub growth_sha256: String,
    pub previous_capture_sha256: String,
    pub capture_sha256: String,
    #[serde(deserialize_with = "crate::wire::required_nullable")]
    pub checkpoint_head: Option<String>,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BranchPublication {
    pub schema: u8,
    pub previous: Receipt,
    pub receipt: Receipt,
    pub change: BranchSourceChange,
}
impl BranchPublication {
    pub fn validate(&self) -> Result<(), InvalidMessage> {
        self.previous.validate_for(2)?;
        self.receipt.validate_for(2)?;
        let change = &self.change;
        change.child.validate_for(2)?;
        change.child_origin.validate(&change.child)?;
        for sha in [
            &change.previous_growth_sha256,
            &change.growth_sha256,
            &change.previous_capture_sha256,
            &change.capture_sha256,
        ] {
            crate::wire::hex(sha, 64)?;
        }
        if let Some(head) = &change.checkpoint_head {
            crate::wire::hex(head, 32)?;
        }
        let lineage = match change.platform.as_str() {
            "linux" => Some(change.child_origin.intent.source_pid.1),
            "macos" => change.previous_lineage,
            _ => return Err(InvalidMessage),
        };
        let before = self.previous.material.as_ref().ok_or(InvalidMessage)?;
        let after = self.receipt.material.as_ref().ok_or(InvalidMessage)?;
        check(
            self.schema == 1
                && self.previous == change.child_origin.intent.source
                && origin(&self.previous) == origin(&self.receipt)
                && change.child.material.as_deref() == Some(&root(&change.child)?)
                && change.lineage == lineage
                && change.previous_lineage != Some(0)
                && (before.revision != 0 || **before == root(&self.previous)?)
                && (change.lineage != change.previous_lineage
                    || (change.growth_sha256 == change.previous_growth_sha256
                        && change.capture_sha256 == change.previous_capture_sha256
                        && after.record_sha256 == before.record_sha256)),
        )?;
        check(
            after.revision == before.revision + 1
                && after.operation_id.as_deref()
                    == Some(&change.child_origin.intent.child.operation_id)
                && after.request_sha256.as_deref()
                    == Some(&change.child_origin.intent.request_sha256)
                && after.chain_sha256
                    == hash(&(
                        "smolbox-branch-source-transition-v1",
                        change,
                        &after.record_sha256,
                    ))?,
        )
    }
}
#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BranchReleaseMode {
    Initial,
    Explicit,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BranchReleaseChange {
    pub request: BranchReleaseRequest,
    pub binding: BranchChildOrigin,
    pub identity_sha256: String,
    pub boot_sha256: String,
    pub mode: BranchReleaseMode,
    pub activation_token: String,
    pub invariant_sha256: String,
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BranchReleaseTransition {
    pub schema: u8,
    pub previous: Receipt,
    pub receipt: Receipt,
    pub change: BranchReleaseChange,
}
impl BranchReleaseTransition {
    pub fn validate(&self) -> Result<(), InvalidMessage> {
        self.previous.validate_for(2)?;
        self.receipt.validate_for(2)?;
        self.change.request.validate()?;
        self.change.binding.validate(&self.previous)?;
        for sha in [
            &self.change.identity_sha256,
            &self.change.boot_sha256,
            &self.change.activation_token,
            &self.change.invariant_sha256,
        ] {
            crate::wire::hex(sha, 64)?;
        }
        let before = self.previous.material.as_ref().ok_or(InvalidMessage)?;
        let after = self.receipt.material.as_ref().ok_or(InvalidMessage)?;
        check(
            self.schema == 1
                && origin(&self.previous) == origin(&self.receipt)
                && **before == root(&self.previous)?
                && self.change.request.operation_id
                    != self.change.binding.intent.child.operation_id
                && (self.change.mode == BranchReleaseMode::Explicit)
                    == self.change.binding.intent.child.hold
                && before.record_sha256 != after.record_sha256
                && after.revision == 1
                && after.operation_id.as_deref() == Some(&self.change.request.operation_id)
                && after.request_sha256.as_deref() == Some(&self.change.request.request_sha256)
                && after.chain_sha256
                    == hash(&(
                        "smolbox-branch-child-release-v1",
                        &self.previous,
                        &self.change,
                        &after.record_sha256,
                    ))?,
        )
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BranchHeldReleaseRequest {
    pub completion: BranchCompletion,
    pub source: Receipt,
    pub request: BranchReleaseRequest,
}
impl BranchHeldReleaseRequest {
    pub fn validate(&self) -> Result<(), InvalidMessage> {
        self.completion.validate()?;
        self.source.validate_for(2)?;
        self.request.validate()?;
        check(
            self.completion.held
                && self.source.material.is_some()
                && origin(&self.source) == origin(&self.completion.publication.previous)
                && self.request.operation_id
                    != self
                        .completion
                        .publication
                        .change
                        .child_origin
                        .intent
                        .child
                        .operation_id
                && serde_json::to_vec(self).map_err(|_| InvalidMessage)?.len() <= 68 * 1024,
        )
    }
    pub fn matches(&self, proof: &BranchReleaseTransition) -> Result<(), InvalidMessage> {
        self.validate()?;
        proof.validate()?;
        check(
            proof.change.mode == BranchReleaseMode::Explicit
                && proof.previous == self.completion.child
                && proof.change.request == self.request
                && proof.change.binding == self.completion.publication.change.child_origin
                && proof.change.identity_sha256 == self.completion.identity_sha256,
        )
    }
    pub fn approval(&self) -> &BranchApproval {
        &self
            .completion
            .publication
            .change
            .child_origin
            .intent
            .approval
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BranchCompletion {
    pub schema: u8,
    pub publication: BranchPublication,
    pub child: Receipt,
    pub identity_sha256: String,
    pub held: bool,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "crate::wire::present_optional"
    )]
    pub release: Option<BranchReleaseTransition>,
}
impl BranchCompletion {
    pub fn validate(&self) -> Result<(), InvalidMessage> {
        self.publication.validate()?;
        crate::wire::hex(&self.identity_sha256, 64)?;
        check(
            self.schema == 1
                && serde_json::to_vec(self).map_err(|_| InvalidMessage)?.len() <= 64 * 1024,
        )?;
        match &self.release {
            None => check(
                self.held
                    && self.publication.change.child_origin.intent.child.hold
                    && self.child == self.publication.change.child,
            ),
            Some(release) => {
                release.validate()?;
                check(
                    !self.held
                        && release.previous == self.publication.change.child
                        && release.receipt == self.child
                        && release.change.identity_sha256 == self.identity_sha256
                        && release.change.binding == self.publication.change.child_origin,
                )
            }
        }
    }
    pub fn matches(&self, request: &BranchCreateRequest) -> Result<(), InvalidMessage> {
        self.validate()?;
        request.validate()?;
        let intent = &self.publication.change.child_origin.intent;
        check(
            self.publication.previous == request.source
                && intent.child == request.child
                && intent.approval == request.approval
                && self.held == request.child.hold,
        )?;
        match (&self.release, &request.initial_release) {
            (None, None) => Ok(()),
            (Some(release), Some(wanted)) => check(
                release.change.mode == BranchReleaseMode::Initial
                    && release.change.request == *wanted,
            ),
            _ => Err(InvalidMessage),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::*;
    fn rows() -> Vec<serde_json::Value> {
        serde_json::from_str(include_str!("../fixtures/branch-creation-v1.json")).unwrap()
    }
    fn ready_session(
        row: &serde_json::Value,
        epoch: Option<String>,
        platform: Option<String>,
    ) -> Session {
        let value: serde_json::Value =
            serde_json::from_str(include_str!("../fixtures/hello-v2.json")).unwrap();
        let ServerMessage::Hello { hello } = ServerMessage::decode(value).unwrap() else {
            panic!()
        };
        let mut h = *hello;
        h.epoch = epoch.unwrap_or_else(|| {
            row["completion"]["publication"]["change"]["child_origin"]["intent"]["epoch"]
                .as_str()
                .unwrap()
                .into()
        });
        if let Some(platform) = platform {
            h.package.platform = platform;
        }
        let sdk = h.sdk.as_mut().unwrap();
        sdk.feature_versions.insert("branches".into(), 1);
        h.limits = Limits::for_sdk(sdk);
        let mut session = Session::new(h.clone()).unwrap();
        session.approve(&h).unwrap();
        let operation = Operation::ResolveReadyBranchCompletion {
            request: Box::new(serde_json::from_value(row["request"].clone()).unwrap()),
            quiesced: true,
        };
        let response = session
            .admit(ClientMessage::Request {
                epoch: h.epoch,
                id: 1,
                budget_ms: 30000,
                initial_credit: INITIAL_CREDIT_BYTES,
                initial_event_credit: INITIAL_CREDIT_EVENTS,
                operation,
            })
            .unwrap();
        assert!(matches!(response, ServerMessage::Accepted { .. }));
        session
    }
    #[test]
    fn explicit_ready_handoff_has_exact_finite_fenced_protocol_two_authority() {
        for row in rows() {
            let request: BranchCreateRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            let operation = Operation::ResolveReadyBranchCompletion {
                request: Box::new(request.clone()),
                quiesced: true,
            };
            operation.validate(30000).unwrap();
            // Conservative bridge accounting reserves 1024 bytes per request
            // and per accepted/terminal envelope pair, independent of payload.
            let epoch = "f".repeat(32);
            let request_message = ClientMessage::Request {
                epoch: epoch.clone(),
                id: u64::MAX,
                budget_ms: 30000,
                initial_credit: u64::MAX,
                initial_event_credit: u64::MAX,
                operation: operation.clone(),
            };
            assert!(
                serde_json::to_vec(&request_message).unwrap().len()
                    - serde_json::to_vec(&operation).unwrap().len()
                    <= 1024
            );
            let outcome = Outcome::BranchCompletionPresence {
                completion: Some(Box::new(
                    serde_json::from_value(row["completion"].clone()).unwrap(),
                )),
            };
            let accepted = ServerMessage::Accepted {
                epoch: epoch.clone(),
                id: u64::MAX,
                sequence: u64::MAX,
            };
            let terminal = ServerMessage::Terminal {
                epoch,
                id: u64::MAX,
                sequence: u64::MAX,
                outcome: outcome.clone(),
            };
            assert!(
                serde_json::to_vec(&accepted).unwrap().len()
                    + serde_json::to_vec(&terminal).unwrap().len()
                    - serde_json::to_vec(&outcome).unwrap().len()
                    <= 1024
            );

            assert!(operation.validate(30001).is_err());
            assert!(operation.requires_branches());
            assert!(operation.capability() == Capability::Inspect);
            assert!(operation.receipt() == Some(&request.source));
            assert!(operation.branch_request() == Some(&request));
            let unfenced = Operation::ResolveReadyBranchCompletion {
                request: Box::new(request),
                quiesced: false,
            };
            assert!(unfenced.validate(1).is_err());
            let mut value = serde_json::to_value(&operation).unwrap();
            value["path"] = serde_json::json!("/foreign");
            assert!(serde_json::from_value::<Operation>(value).is_err());
        }
    }
    #[test]
    fn explicit_ready_result_correlates_original_creation_and_allows_no_output() {
        for row in rows() {
            let completion: BranchCompletion =
                serde_json::from_value(row["completion"].clone()).unwrap();
            let mut session = ready_session(&row, None, None);
            assert!(session.event(1, Stream::Stdout, b"extra").is_err());
            session
                .terminal(
                    1,
                    Outcome::BranchCompletionPresence {
                        completion: Some(Box::new(completion)),
                    },
                )
                .unwrap();
            ready_session(&row, None, None)
                .terminal(1, Outcome::BranchCompletionPresence { completion: None })
                .unwrap();
        }
    }
    #[test]
    fn explicit_ready_result_rejects_crossed_creation_platform_and_original_epoch() {
        for row in rows() {
            let completion: BranchCompletion =
                serde_json::from_value(row["completion"].clone()).unwrap();
            for (epoch, platform) in [(Some("e".repeat(32)), None), (None, Some("linux".into()))] {
                assert!(ready_session(&row, epoch, platform)
                    .terminal(
                        1,
                        Outcome::BranchCompletionPresence {
                            completion: Some(Box::new(completion.clone()))
                        }
                    )
                    .is_err());
            }
            let mut changed = row.clone();
            changed["request"]["approval"]["resources"]["disk_gb"] = serde_json::json!(9999);
            assert!(ready_session(&changed, None, None)
                .terminal(
                    1,
                    Outcome::BranchCompletionPresence {
                        completion: Some(Box::new(completion))
                    }
                )
                .is_err());
        }
    }
    #[test]
    fn creation_contract_binds_both_modes_and_rejects_changed_plan_or_activation() {
        for row in rows() {
            let request: BranchCreateRequest =
                serde_json::from_value(row["request"].clone()).unwrap();
            let completion: BranchCompletion =
                serde_json::from_value(row["completion"].clone()).unwrap();
            completion.matches(&request).unwrap();
            let create = Operation::CreateBranch {
                request: Box::new(request.clone()),
            };
            let lookup = Operation::InspectBranchCompletion {
                request: Box::new(request.clone()),
            };
            create.validate(900000).unwrap();
            assert!(create.validate(900001).is_err());
            lookup.validate(30000).unwrap();
            assert!(lookup.validate(30001).is_err());
            let mut wrong = request.clone();
            wrong.approval.resources.disk_gb += 1;
            assert!(completion.matches(&wrong).is_err());
            wrong = request.clone();
            wrong.child.incarnation = "a".repeat(32);
            assert!(completion.matches(&wrong).is_err());
            wrong = request.clone();
            wrong.initial_release = None;
            if !wrong.child.hold {
                assert!(wrong.validate().is_err());
            }
            for path in [
                vec![
                    "publication",
                    "change",
                    "child_origin",
                    "intent",
                    "plan",
                    "minimum_extra_disk_gb",
                ],
                vec!["publication", "change", "child_origin", "raw_child_sha256"],
                vec!["identity_sha256"],
            ] {
                let mut corrupted = row["completion"].clone();
                let mut selected = &mut corrupted;
                for part in path {
                    selected = &mut selected[part];
                }
                *selected = serde_json::json!(0);
                assert!(serde_json::from_value::<BranchCompletion>(corrupted)
                    .map_or(true, |value| value.validate().is_err()));
            }
            let mut extra = row["request"].clone();
            extra["path"] = serde_json::json!("/foreign");
            assert!(serde_json::from_value::<BranchCreateRequest>(extra).is_err());
            if request.child.hold {
                let mut null = row["request"].clone();
                null["initial_release"] = serde_json::Value::Null;
                assert!(serde_json::from_value::<BranchCreateRequest>(null).is_err());
            }
        }
    }
    #[test]
    fn valid_shape_digest_substitutions_cannot_change_source_child_or_activation_evidence() {
        for row in rows() {
            let paths = vec![
                vec!["publication", "receipt", "material", "chain_sha256"],
                vec!["publication", "change", "child", "material", "chain_sha256"],
                vec![
                    "publication",
                    "change",
                    "child_origin",
                    "intent",
                    "request_sha256",
                ],
            ];
            for path in paths {
                let mut value = row["completion"].clone();
                let mut leaf = &mut value;
                for part in path {
                    leaf = &mut leaf[part];
                }
                *leaf = serde_json::json!("0".repeat(64));
                assert!(serde_json::from_value::<BranchCompletion>(value)
                    .unwrap()
                    .validate()
                    .is_err());
            }
            if row["request"].get("initial_release").is_some() {
                let mut value = row["completion"].clone();
                value["release"]["change"]["activation_token"] = serde_json::json!("0".repeat(64));
                assert!(serde_json::from_value::<BranchCompletion>(value)
                    .unwrap()
                    .validate()
                    .is_err());
            }
        }
    }
    #[test]
    fn creation_and_lookup_sessions_require_branch_feature_and_exact_distinct_zero_output_proofs() {
        let ServerMessage::Hello { hello } = ServerMessage::decode(
            serde_json::from_str(include_str!("../fixtures/hello-v2.json")).unwrap(),
        )
        .unwrap() else {
            unreachable!()
        };
        for row in rows() {
            for lookup in [false, true] {
                for enabled in [false, true] {
                    let request: BranchCreateRequest =
                        serde_json::from_value(row["request"].clone()).unwrap();
                    let completion: BranchCompletion =
                        serde_json::from_value(row["completion"].clone()).unwrap();
                    let mut hello = (*hello).clone();
                    if enabled {
                        hello
                            .sdk
                            .as_mut()
                            .unwrap()
                            .feature_versions
                            .insert("branches".into(), 1);
                    }
                    let mut session = Session::new(hello.clone()).unwrap();
                    session.approve(&hello).unwrap();
                    let operation = if lookup {
                        Operation::InspectBranchCompletion {
                            request: Box::new(request.clone()),
                        }
                    } else {
                        Operation::CreateBranch {
                            request: Box::new(request.clone()),
                        }
                    };
                    let accepted = session
                        .admit(ClientMessage::Request {
                            epoch: hello.epoch.clone(),
                            id: 1,
                            budget_ms: 1000,
                            initial_credit: 1024,
                            initial_event_credit: 1,
                            operation,
                        })
                        .unwrap();
                    if !enabled {
                        assert!(matches!(
                            accepted,
                            ServerMessage::Terminal {
                                outcome: Outcome::Error {
                                    code: SafeCode::Unsupported,
                                    ..
                                },
                                ..
                            }
                        ));
                        continue;
                    }
                    assert!(matches!(accepted, ServerMessage::Accepted { .. }));
                    assert!(session.event(1, Stream::Stdout, b"unexpected").is_err());
                    let reply = |proof| {
                        if lookup {
                            Outcome::BranchCompletionPresence {
                                completion: Some(Box::new(proof)),
                            }
                        } else {
                            Outcome::BranchCreated {
                                completion: Box::new(proof),
                            }
                        }
                    };
                    let wrong_kind = if lookup {
                        Outcome::BranchCreated {
                            completion: Box::new(completion.clone()),
                        }
                    } else {
                        Outcome::BranchCompletionPresence { completion: None }
                    };
                    assert!(session.terminal(1, wrong_kind).is_err());
                    let mut crossed = completion.clone();
                    crossed.child.owner_token = "9".repeat(64);
                    assert!(session.terminal(1, reply(crossed)).is_err());
                    assert!(reply(completion.clone()).validate_for(1).is_err());
                    session.terminal(1, reply(completion)).unwrap();
                }
            }
        }
    }
}
