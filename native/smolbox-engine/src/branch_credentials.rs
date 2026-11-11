use crate::{Error, ErrorCode, Result};
use smolvm::config::VmRecord;
use std::collections::BTreeMap;

const BINDING: &str = "smolbox-branch-https";

pub(crate) fn policy(host: &str) -> Result<smolvm::credentials::CredentialPolicy> {
    serde_json::from_value(serde_json::json!({
        "credentials": [{
            "name": BINDING,
            "environment_variable": "SMOLBOX_BRANCH_HTTPS_TOKEN",
            "allowed_hosts": [host],
            "set_header": "authorization"
        }]
    }))
    .map_err(|_| Error::before(ErrorCode::Validation))
}

pub(crate) fn validate_record(record: &VmRecord) -> Result<()> {
    let valid = match (&record.credential_policy, &record.dns_filter_hosts) {
        (Some(actual), Some(hosts)) if hosts.len() == 1 => {
            *actual == policy(&hosts[0])?
                && record.credentials_supplied_by_api
                && record.allowed_cidrs.as_ref().is_some_and(Vec::is_empty)
                && record.credential_placeholders.len() == 1
                && record.credential_placeholders.contains_key(BINDING)
        }
        (None, _) => {
            record.credential_placeholders.is_empty() && !record.credentials_supplied_by_api
        }
        _ => false,
    };
    if valid {
        Ok(())
    } else {
        Err(Error::before(ErrorCode::Unsupported))
    }
}

fn values(token: &str) -> Result<BTreeMap<String, zeroize::Zeroizing<String>>> {
    let body = token.trim_end_matches('=');
    if token.is_empty()
        || token.len() > 2048
        || body.is_empty()
        || !body
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"._~+/-".contains(&b))
    {
        return Err(Error::before(ErrorCode::Validation));
    }
    Ok(BTreeMap::from([(
        BINDING.into(),
        zeroize::Zeroizing::new(format!("Bearer {token}")),
    )]))
}

/// Remove the boot-only value even if startup fails. A source is always empty.
pub(crate) struct BootValues(String);
impl Drop for BootValues {
    fn drop(&mut self) {
        smolvm::credentials::forget_values(&self.0);
    }
}

pub(crate) fn prepare_boot(record: &VmRecord, token: Option<&str>) -> Result<BootValues> {
    validate_record(record)?;
    if let Some(source) = &record.golden {
        smolvm::credentials::forget_values(source);
    }
    let supplied = match (&record.credential_policy, &record.golden, token) {
        (Some(_), Some(_), Some(token)) => values(token)?,
        (Some(_), Some(_), None) => return Err(Error::before(ErrorCode::Unsupported)),
        (_, _, None) => BTreeMap::new(),
        _ => return Err(Error::before(ErrorCode::Unsupported)),
    };
    smolvm::credentials::supply_values(&record.name, supplied);
    Ok(BootValues(record.name.clone()))
}

pub(crate) fn prepare_held(record: &VmRecord) -> Result<()> {
    validate_record(record)?;
    if record.credential_policy.is_some() {
        let source = record
            .golden
            .as_ref()
            .ok_or(Error::before(ErrorCode::Ownership))?;
        smolvm::credentials::forget_values(source);
        smolvm::credentials::forget_values(&record.name);
    }
    Ok(())
}

pub(crate) fn install_held(record: &VmRecord, token: Option<&str>) -> Result<()> {
    validate_record(record)?;
    match (&record.credential_policy, token) {
        (Some(_), Some(token)) if record.golden.is_some() && record.forkpoint_held => {
            smolvm::agent::apply_live_credential_values(&record.name, &values(token)?)
                .map_err(|_| Error::before(ErrorCode::Native))
        }
        (None, None) => Ok(()),
        _ => Err(Error::before(ErrorCode::Unsupported)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn child() -> VmRecord {
        let mut record =
            VmRecord::new("credential-child-unit".into(), 1, 512, vec![], vec![], true);
        let policy = policy("api.example.test").unwrap();
        record.dns_filter_hosts = Some(vec!["api.example.test".into()]);
        record.allowed_cidrs = Some(vec![]);
        record.credential_placeholders =
            smolvm::credentials::prepare_policy(&policy, record.dns_filter_hosts.as_deref())
                .unwrap();
        record.credential_policy = Some(policy);
        record.credentials_supplied_by_api = true;
        record.golden = Some("credential-source-unit".into());
        record.forkpoint_held = true;
        record
    }

    #[test]
    fn held_restore_clears_parent_fallback_and_boot_values_are_child_scoped_and_transient() {
        let record = child();
        smolvm::credentials::supply_values(
            record.golden.as_ref().unwrap(),
            values("parent-key").unwrap(),
        );
        prepare_held(&record).unwrap();
        let mut launch =
            smolvm::credentials::CredentialLaunch::for_record(&record.name, &record).unwrap();
        assert!(launch.supplied_only);
        assert!(launch.child_env().iter().all(|(_, value)| value.is_none()));
        assert!(prepare_boot(&record, None).is_err());
        {
            let _values = prepare_boot(&record, Some("child-key")).unwrap();
            let environment = launch.child_env();
            assert_eq!(
                environment[0].1.as_deref().map(String::as_str),
                Some("Bearer child-key")
            );
            let mut sibling = record.clone();
            sibling.name = "credential-unbound-unit".into();
            let mut other =
                smolvm::credentials::CredentialLaunch::for_record(&sibling.name, &sibling).unwrap();
            assert!(other.child_env().iter().all(|(_, value)| value.is_none()));
            assert!(!serde_json::to_string(&launch)
                .unwrap()
                .contains("child-key"));
        }
        assert!(launch.child_env().iter().all(|(_, value)| value.is_none()));
    }

    #[test]
    fn policy_and_values_reject_host_widening_host_environment_fallback_and_invalid_tokens() {
        let record = child();
        validate_record(&record).unwrap();
        let mut altered = record.clone();
        altered.credentials_supplied_by_api = false;
        assert!(validate_record(&altered).is_err());
        altered = record.clone();
        altered.dns_filter_hosts = Some(vec!["other.example.test".into()]);
        assert!(validate_record(&altered).is_err());
        for token in ["", "line\nvalue", "two words"] {
            assert!(values(token).is_err());
        }
        assert!(values(&"a".repeat(2049)).is_err());
        assert!(install_held(&record, None).is_err());
        let mut source = record;
        source.golden = None;
        assert!(prepare_boot(&source, Some("parent-key")).is_err());
        prepare_boot(&source, None).unwrap();
    }
}
