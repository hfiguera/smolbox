//! Entirely synthetic material histories. No SDK manager, VM or process entry.
use super::*;
use serde_json::{json, Value};

fn rows() -> Vec<Value> {
    serde_json::from_str(include_str!(
        "../../../smolbox-protocol/fixtures/branch-material-history-v1.json"
    ))
    .unwrap()
}

fn journals(row: &Value) -> Vec<Journal> {
    let mut origin: CreationReceipt = serde_json::from_value(row["origin"].clone()).unwrap();
    origin.material = None;
    let mut value = json!({
        "schema": 2, "origin": origin,
        "head": row["origin"]["material"], "history": [], "pending": null
    });
    let mut result = Vec::new();
    for event in row["events"].as_array().unwrap() {
        let wire = event["transition"].clone();
        let kind = event["kind"].as_str().unwrap();
        let field = match kind {
            "growth" => {
                let proof: GrowthTransition = serde_json::from_value(wire.clone()).unwrap();
                proof.validate().unwrap();
                assert_eq!(serde_json::to_value(proof).unwrap(), wire);
                "history"
            }
            "capture" => {
                let proof: crate::CaptureTransition = serde_json::from_value(wire.clone()).unwrap();
                proof.validate().unwrap();
                assert_eq!(serde_json::to_value(proof).unwrap(), wire);
                "capture_history"
            }
            "resolution" => {
                let proof: crate::CaptureResolutionTransition =
                    serde_json::from_value(wire.clone()).unwrap();
                proof.validate().unwrap();
                assert_eq!(serde_json::to_value(proof).unwrap(), wire);
                "capture_resolutions"
            }
            "branch" => {
                let proof: crate::BranchPublication = serde_json::from_value(wire.clone()).unwrap();
                proof.validate().unwrap();
                assert_eq!(serde_json::to_value(proof).unwrap(), wire);
                "branch_history"
            }
            _ => panic!("unknown synthetic history kind"),
        };
        value["head"] = wire["receipt"]["material"].clone();
        value
            .as_object_mut()
            .unwrap()
            .entry(field)
            .or_insert_with(|| json!([]))
            .as_array_mut()
            .unwrap()
            .push(json!({"change": wire["change"], "proof": wire["receipt"]["material"]}));
        let journal: Journal = serde_json::from_value(value.clone()).unwrap();
        validate_journal(&journal).unwrap();
        result.push(journal);
    }
    result
}

#[test]
fn synthetic_cross_reader_branch_histories_preserve_every_actual_engine_journal_prefix() {
    for row in rows() {
        let history = journals(&row);
        let last = history.last().unwrap();
        assert_eq!(
            serde_json::to_value(&last.head).unwrap(),
            row["receipt"]["material"]
        );
        assert_eq!(last.history_len(), 7);
        assert_eq!(last.branch_history.as_ref().unwrap().len(), 2);
    }
}

#[test]
fn individually_valid_branch_evidence_cannot_replace_known_growth_capture_or_checkpoint_heads() {
    for row in rows() {
        let history = journals(&row);
        let last = history.last().unwrap();
        for field in ["growth", "capture", "checkpoint"] {
            let mut changed = last.clone();
            let entry = changed.branch_history.as_mut().unwrap().last_mut().unwrap();
            match field {
                "growth" => {
                    entry.change.previous_growth_sha256 = "0".repeat(64);
                    entry.change.growth_sha256 = "0".repeat(64);
                }
                "capture" => {
                    entry.change.previous_capture_sha256 = "0".repeat(64);
                    entry.change.capture_sha256 = "0".repeat(64);
                }
                _ => entry.change.checkpoint_head = Some("0".repeat(32)),
            }
            entry.change.validate().unwrap();
            entry.proof = crate::branch_material::next_proof(
                &entry.change,
                entry.proof.record_sha256.clone(),
            )
            .unwrap();
            changed.head = entry.proof.clone();
            assert!(validate_journal(&changed).is_err());
        }
        let mut missing = last.clone();
        missing.branch_history.as_mut().unwrap().remove(0);
        assert!(validate_journal(&missing).is_err());
        let mut duplicate = last.clone();
        let entry = duplicate.branch_history.as_ref().unwrap()[0].clone();
        duplicate.branch_history.as_mut().unwrap().push(entry);
        assert!(validate_journal(&duplicate).is_err());
    }
}
