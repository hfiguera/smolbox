use super::*;

#[test]
fn shared_cleanup_request_and_positive_absence_fixture_algebra_are_exact_and_separate_from_observation(
) {
    let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
        "../../../../../smolbox-protocol/fixtures/released-branch-deletion-cleanup-v1.json"
    ))
    .unwrap();
    for row in rows {
        let request: ReleasedBranchDeletionCleanupRequest =
            serde_json::from_value(row["request"].clone()).unwrap();
        let proof: ReleasedBranchDeletionResolution =
            serde_json::from_value(row["proof"].clone()).unwrap();
        request.matches(&proof).unwrap();
        assert!(!format!("{request:?}").contains(&request.child.owner_token));
        let old: ReleasedBranchDeletionRequest =
            serde_json::from_value(row["request"].clone()).unwrap();
        assert!(old.validate().is_err());
    }
}
