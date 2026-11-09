//! Immutable creation features, shared by every native bridge. The SDK owns
//! network and workload execution; this module validates intent and constructs
//! its public configuration without a second runtime or a CLI/server fallback.
use crate::{Error, ErrorCode, Result};
use smolvm::config::VmRecord;
use smolvm_pack::format::{PackManifest, PackMode};
use std::collections::BTreeMap;
use std::net::IpAddr;

#[derive(Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CreationFeatures {
    pub network: NetworkPolicy,
    pub ports: Vec<PortMapping>,
    pub workload: Option<StartupWorkload>,
}
#[derive(Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NetworkPolicy {
    pub enabled: bool,
    pub hosts: Vec<String>,
    pub cidrs: Vec<String>,
}
#[derive(Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PortMapping {
    pub host: u16,
    pub guest: u16,
}
#[derive(Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StartupWorkload {
    pub entrypoint: Vec<String>,
    pub cmd: Vec<String>,
    pub env: BTreeMap<String, String>,
    pub workdir: Option<String>,
}

#[derive(Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MachineConfiguration {
    pub network: NetworkPolicy,
    pub ports: Vec<PortMapping>,
    pub backend: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub mounts: Vec<ObservedMount>,
}
#[derive(Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ObservedMount {
    pub source: String,
    pub target: String,
    pub readonly: bool,
    pub staged: bool,
}
impl MachineConfiguration {
    pub(crate) fn observe(record: &VmRecord) -> Option<Box<Self>> {
        (record.network
            || !record.ports.is_empty()
            || !record.mounts.is_empty()
            || !record.staged_mounts.is_empty())
        .then(|| Self::observe_explicit(record))
    }

    // Qualification must report verified defaults explicitly. Ordinary legacy
    // observations keep omitting an all-default offline configuration above.
    pub(crate) fn observe_explicit(record: &VmRecord) -> Box<Self> {
        Box::new(Self {
            network: NetworkPolicy {
                enabled: record.network,
                hosts: record.dns_filter_hosts.clone().unwrap_or_default(),
                cidrs: record.allowed_cidrs.clone().unwrap_or_default(),
            },
            ports: record
                .ports
                .iter()
                .map(|&(host, guest)| PortMapping { host, guest })
                .collect(),
            backend: record.network_backend.map(|value| value.as_str().into()),
            mounts: record
                .mounts
                .iter()
                .map(|(source, target, readonly)| ObservedMount {
                    source: source.clone(),
                    target: target.clone(),
                    readonly: *readonly,
                    staged: false,
                })
                .chain(
                    record
                        .staged_mounts
                        .iter()
                        .map(|(_, source, target)| ObservedMount {
                            source: source.clone(),
                            target: target.clone(),
                            readonly: false,
                            staged: true,
                        }),
                )
                .collect(),
        })
    }
}

impl CreationFeatures {
    pub fn validate(&self) -> Result<()> {
        if self.network.hosts.len() > 32
            || self.network.cidrs.len() > 32
            || (!self.network.enabled
                && (!self.network.hosts.is_empty() || !self.network.cidrs.is_empty()))
            || (self.network.enabled
                && self.network.hosts.is_empty()
                && self.network.cidrs.is_empty())
            || !strictly_sorted(&self.network.hosts)
            || !strictly_sorted(&self.network.cidrs)
            || self.network.hosts.iter().any(|host| !valid_host(host))
            || self.network.cidrs.iter().any(|cidr| !valid_cidr(cidr))
            || self.ports.len() > 32
            || self.ports.iter().any(|p| p.host == 0 || p.guest == 0)
            || self
                .ports
                .windows(2)
                .any(|pair| pair[0].host >= pair[1].host)
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        if let Some(workload) = &self.workload {
            validate_workload(workload)?;
            // Match Workload.new's Command.new(["true"] ++ argv) contract.
            if workload.env.len() > 64
                || workload.env.iter().any(|(key, value)| {
                    key.len() > 128 || !environment_name(key) || value.len() > 8192
                })
                || workload
                    .entrypoint
                    .iter()
                    .chain(&workload.cmd)
                    .map(String::len)
                    .sum::<usize>()
                    > 65532
            {
                return Err(Error::before(ErrorCode::Validation));
            }
        }
        Ok(())
    }

    pub fn qualify(&self, manifest: &PackManifest) -> Result<()> {
        self.validate()?;
        if let Some(workload) = &self.workload {
            if manifest.mode != PackMode::Container || !manifest.secret_refs.is_empty() {
                return Err(Error::before(ErrorCode::Unsupported));
            }
            let inherited = resolved_workload(workload, manifest)?;
            validate_resolved(&inherited)?;
            // Startup uses the SDK's image RunConfig, which supports inherited
            // named users. Foreground execution's numeric-user gate is separate.
            if manifest
                .user
                .as_ref()
                .is_some_and(|user| user.is_empty() || !text(user, 1024 * 1024))
            {
                return Err(Error::before(ErrorCode::Validation));
            }
        }
        Ok(())
    }

    pub(crate) fn apply(&self, record: &mut VmRecord, manifest: &PackManifest) -> Result<()> {
        self.qualify(manifest)?;
        // A network device is required for inbound forwarding even with denied
        // egress. Explicit empty lists survive to_record's None optimization.
        record.network = self.network.enabled;
        record.network_backend = if self.network.enabled || !self.ports.is_empty() {
            Some(smolvm::network::NetworkBackend::VirtioNet)
        } else {
            None
        };
        record.allowed_cidrs = Some(self.network.cidrs.clone());
        record.dns_filter_hosts = Some(self.network.hosts.clone());
        record.ports = self.ports.iter().map(|p| (p.host, p.guest)).collect();
        if let Some(workload) = &self.workload {
            let resolved = resolved_workload(workload, manifest)?;
            record.entrypoint = resolved.entrypoint;
            record.cmd = resolved.cmd;
            record.env = resolved.env.into_iter().collect();
            record.workdir = resolved.workdir;
            record.user = manifest.user.clone();
        }
        Ok(())
    }
}

fn resolved_workload(
    request: &StartupWorkload,
    manifest: &PackManifest,
) -> Result<StartupWorkload> {
    let inherit = request.entrypoint.is_empty() && request.cmd.is_empty();
    let mut env = BTreeMap::new();
    for entry in &manifest.env {
        let (key, value) = entry
            .split_once('=')
            .ok_or(Error::before(ErrorCode::Validation))?;
        if key.is_empty() || env.insert(key.into(), value.into()).is_some() {
            return Err(Error::before(ErrorCode::Validation));
        }
    }
    env.extend(request.env.clone());
    Ok(StartupWorkload {
        entrypoint: if inherit {
            manifest.entrypoint.clone()
        } else {
            request.entrypoint.clone()
        },
        cmd: if inherit {
            manifest.cmd.clone()
        } else {
            request.cmd.clone()
        },
        env,
        workdir: request.workdir.clone().or_else(|| manifest.workdir.clone()),
    })
}

fn validate_workload(workload: &StartupWorkload) -> Result<()> {
    let argv = workload
        .entrypoint
        .iter()
        .chain(&workload.cmd)
        .collect::<Vec<_>>();
    if argv.len() > 255
        || workload.env.len() > 256
        || workload.entrypoint.first().is_some_and(String::is_empty)
        || workload.cmd.first().is_some_and(String::is_empty)
        || argv.iter().any(|arg| !text(arg, 16384))
        || workload.env.iter().any(|(key, value)| {
            key.is_empty() || key.contains('=') || !text(key, 16384) || !text(value, 16384)
        })
        || argv.iter().map(|s| s.len()).sum::<usize>()
            + workload
                .env
                .iter()
                .map(|(k, v)| k.len() + v.len())
                .sum::<usize>()
            > 65536 + 256 * (128 + 8192)
        || workload
            .workdir
            .as_ref()
            .is_some_and(|path| !path.starts_with('/') || !text(path, 4096))
    {
        return Err(Error::before(ErrorCode::Validation));
    }
    Ok(())
}

fn validate_resolved(workload: &StartupWorkload) -> Result<()> {
    // Request overrides obey Workload's public limits. Image inheritance has
    // its own bound: the already verified 1-MiB manifest plus bounded overrides.
    // Do not apply request entry/env counts to inherited image metadata.
    let argv = workload.entrypoint.iter().chain(&workload.cmd);
    let bytes = argv.clone().map(String::len).sum::<usize>()
        + workload
            .env
            .iter()
            .map(|(k, v)| k.len() + v.len())
            .sum::<usize>();
    if bytes > 2 * 1024 * 1024
        || workload.entrypoint.first().is_some_and(String::is_empty)
        || workload.cmd.first().is_some_and(String::is_empty)
        || argv.into_iter().any(|value| value.contains('\0'))
        || workload.env.iter().any(|(key, value)| {
            key.is_empty() || key.contains('=') || key.contains('\0') || value.contains('\0')
        })
        || workload
            .workdir
            .as_ref()
            .is_some_and(|path| !path.starts_with('/') || !text(path, 4096))
    {
        return Err(Error::before(ErrorCode::Validation));
    }
    Ok(())
}
fn text(value: &str, maximum: usize) -> bool {
    value.len() <= maximum && !value.contains('\0')
}
fn environment_name(value: &str) -> bool {
    let mut bytes = value.bytes();
    bytes
        .next()
        .is_some_and(|b| b.is_ascii_alphabetic() || b == b'_')
        && bytes.all(|b| b.is_ascii_alphanumeric() || b == b'_')
}
fn strictly_sorted(values: &[String]) -> bool {
    values.windows(2).all(|pair| pair[0] < pair[1])
}
fn valid_host(host: &str) -> bool {
    if host.len() > 253 || host.parse::<IpAddr>().is_ok() {
        return false;
    }
    let labels = host.split('.').collect::<Vec<_>>();
    labels.len() >= 2
        && labels.iter().all(|label| {
            !label.is_empty()
                && label.len() <= 63
                && label
                    .as_bytes()
                    .first()
                    .is_some_and(u8::is_ascii_alphanumeric)
                && label
                    .as_bytes()
                    .last()
                    .is_some_and(u8::is_ascii_alphanumeric)
                && label
                    .bytes()
                    .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
        })
}
fn valid_cidr(cidr: &str) -> bool {
    let Some((address, bits)) = cidr.split_once('/') else {
        return false;
    };
    let Ok(ip) = address.parse::<IpAddr>() else {
        return false;
    };
    let Ok(prefix) = bits.parse::<u32>() else {
        return false;
    };
    if canonical_address(ip) != address || prefix.to_string() != bits {
        return false;
    }
    match ip {
        IpAddr::V4(ip) if (1..=32).contains(&prefix) => {
            u32::from(ip) & u32::MAX.checked_shr(prefix).unwrap_or(0) == 0
        }
        IpAddr::V6(ip) if (1..=128).contains(&prefix) => {
            u128::from(ip) & u128::MAX.checked_shr(prefix).unwrap_or(0) == 0
        }
        _ => false,
    }
}

fn canonical_address(ip: IpAddr) -> String {
    if let IpAddr::V6(value) = ip {
        let bytes = value.octets();
        let ipv4 = std::net::Ipv4Addr::new(bytes[12], bytes[13], bytes[14], bytes[15]);
        // Match NetworkPolicy's Erlang :inet.ntoa grammar, including IPv4-
        // compatible addresses, while retaining the special :: and ::1 forms.
        if bytes[..12].iter().all(|byte| *byte == 0) && u32::from(ipv4) > 1 {
            return format!("::{ipv4}");
        }
        if bytes[..10].iter().all(|byte| *byte == 0) && bytes[10..12] == [255, 255] {
            return format!("::ffff:{ipv4}");
        }
    }
    ip.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn explicit_offline_configuration_keeps_ordinary_default_observations_compatible() {
        let mut record = VmRecord::new("bare-source".into(), 1, 512, vec![], vec![], false);
        assert!(MachineConfiguration::observe(&record).is_none());
        let explicit = MachineConfiguration::observe_explicit(&record);
        assert!(!explicit.network.enabled);
        assert!(explicit.network.hosts.is_empty() && explicit.network.cidrs.is_empty());
        assert!(explicit.ports.is_empty() && explicit.mounts.is_empty());
        assert!(explicit.backend.is_none());
        record.network = true;
        assert!(
            MachineConfiguration::observe_explicit(&record)
                .network
                .enabled
        );
        assert!(
            MachineConfiguration::observe(&record)
                .unwrap()
                .network
                .enabled
        );
    }

    fn features() -> CreationFeatures {
        CreationFeatures {
            network: NetworkPolicy {
                enabled: false,
                hosts: vec![],
                cidrs: vec![],
            },
            ports: vec![],
            workload: None,
        }
    }
    fn manifest() -> PackManifest {
        let mut value = PackManifest::new(
            "fixture".into(),
            "sha256:fixture".into(),
            "linux/arm64".into(),
            "macos".into(),
        );
        value.entrypoint = vec!["/bin/app".into()];
        value.cmd = vec!["--baked".into()];
        value.env = vec!["BAKED=private".into(), "OVERRIDE=old".into()];
        value.workdir = Some("/app".into());
        value.user = Some("app:staff".into());
        value
    }
    fn neutral() -> VmRecord {
        let mut record = VmRecord::new("owned".into(), 1, 512, vec![], vec![], false);
        record.entrypoint = vec!["/bin/true".into()];
        record.workdir = Some("/".into());
        record.user = Some("0".into());
        record
    }
    fn workload() -> StartupWorkload {
        StartupWorkload {
            entrypoint: vec![],
            cmd: vec![],
            env: BTreeMap::new(),
            workdir: None,
        }
    }

    #[test]
    fn offline_mount_observation_projects_actual_record_and_preserves_legacy_shape() {
        let mut record = neutral();
        assert!(MachineConfiguration::observe(&record).is_none());
        record.mounts = vec![("/approved/data".into(), "/mnt/volumes/data".into(), true)];
        let observed = MachineConfiguration::observe(&record).unwrap();
        assert!(!observed.network.enabled && observed.ports.is_empty());
        assert_eq!(observed.mounts[0].source, record.mounts[0].0);
        assert_eq!(observed.mounts[0].target, record.mounts[0].1);
        assert!(observed.mounts[0].readonly && !observed.mounts[0].staged);
        record.mounts.clear();
        record
            .staged_mounts
            .push((0, "/staged".into(), "/mnt/volumes/staged".into()));
        assert!(MachineConfiguration::observe(&record).unwrap().mounts[0].staged);
        record.staged_mounts.clear();
        record.ports.push((8080, 80));
        let legacy = serde_json::to_value(MachineConfiguration::observe(&record).unwrap()).unwrap();
        assert!(legacy.get("mounts").is_none());
    }

    #[test]
    fn offline_forwarding_retains_empty_egress_and_neutral_boot() {
        let mut request = features();
        request.ports.push(PortMapping {
            host: 8080,
            guest: 80,
        });
        let mut record = neutral();
        request.apply(&mut record, &manifest()).unwrap();
        assert!(!record.network);
        assert_eq!(record.allowed_cidrs, Some(vec![]));
        assert_eq!(record.dns_filter_hosts, Some(vec![]));
        assert_eq!(record.network_backend.unwrap().as_str(), "virtio-net");
        assert_eq!(record.ports, vec![(8080, 80)]);
        assert_eq!(record.entrypoint, vec!["/bin/true"]);
        assert!(record.env.is_empty());
        assert_eq!(record.user.as_deref(), Some("0"));
        let observed = MachineConfiguration::observe(&record).unwrap();
        assert!(observed.network == request.network && observed.ports == request.ports);
    }

    #[test]
    fn exact_allowlists_are_applied_without_destinations_added() {
        let mut request = features();
        request.network = NetworkPolicy {
            enabled: true,
            hosts: vec!["api.example.com".into()],
            cidrs: vec!["192.0.2.1/32".into(), "2001:db8::1/128".into()],
        };
        let mut record = neutral();
        request.apply(&mut record, &manifest()).unwrap();
        assert!(record.network);
        assert_eq!(
            record.dns_filter_hosts.as_ref().unwrap(),
            &request.network.hosts
        );
        assert_eq!(
            record.allowed_cidrs.as_ref().unwrap(),
            &request.network.cidrs
        );
        for cidr in [
            "::/64",
            "::1/128",
            "::192.0.2.1/128",
            "::ffff:192.0.2.1/128",
        ] {
            request.network.cidrs = vec![cidr.into()];
            assert!(request.validate().is_ok(), "{cidr}");
        }
        for cidr in [
            "0.0.0.0/0",
            "192.0.2.1/24",
            "192.0.2.0/024",
            "2001:DB8::/32",
            "::1/64",
            "::/0",
            "::c000:201/128",
            "::ffff:c000:201/128",
        ] {
            request.network.cidrs = vec![cidr.into()];
            assert!(request.validate().is_err(), "{cidr}");
        }
        request.network.cidrs.clear();
        for host in [
            "localhost",
            "EXAMPLE.com",
            "192.0.2.1",
            "*.example.com",
            "api.example.com.",
        ] {
            request.network.hosts = vec![host.into()];
            assert!(request.validate().is_err(), "{host}");
        }
    }

    #[test]
    fn workload_inherits_image_metadata_and_merges_env_without_numeric_user_restriction() {
        let mut request = features();
        let mut work = workload();
        work.env.insert("OVERRIDE".into(), "new".into());
        request.workload = Some(work);
        let image = manifest();
        let mut record = neutral();
        request.apply(&mut record, &image).unwrap();
        assert_eq!(record.entrypoint, image.entrypoint);
        assert_eq!(record.cmd, image.cmd);
        assert_eq!(record.user, image.user);
        assert_eq!(record.workdir, image.workdir);
        assert_eq!(record.restart.policy, smolvm::config::RestartPolicy::Never);
        assert!(!record.stop_on_exit);
        assert_eq!(
            record.env,
            vec![
                ("BAKED".into(), "private".into()),
                ("OVERRIDE".into(), "new".into())
            ]
        );
        let initial = crate::identity::material_hash(&record).unwrap();
        record.cmd.push("different".into());
        assert_ne!(initial, crate::identity::material_hash(&record).unwrap());
        let initial = crate::identity::material_hash(&record).unwrap();
        record.env[0].1 = "changed".into();
        assert_ne!(initial, crate::identity::material_hash(&record).unwrap());
    }

    #[test]
    fn inherited_image_metadata_does_not_acquire_request_override_limits() {
        let mut request = features();
        request.workload = Some(workload());
        let mut image = manifest();
        image.cmd = vec!["literal".into(); 300];
        image.env = (0..300).map(|n| format!("IMAGE_{n}=value")).collect();
        assert!(request.qualify(&image).is_ok());
        let mut record = neutral();
        request.apply(&mut record, &image).unwrap();
        assert_eq!(record.cmd.len(), 300);
        assert_eq!(record.env.len(), 300);
    }

    #[test]
    fn explicit_argv_replaces_both_image_arrays_without_a_shell() {
        let mut request = features();
        let mut work = workload();
        work.cmd = vec!["/bin/app".into(), "literal; $(text)".into(), "".into()];
        work.workdir = Some("/workspace".into());
        request.workload = Some(work.clone());
        let mut record = neutral();
        request.apply(&mut record, &manifest()).unwrap();
        assert!(record.entrypoint.is_empty());
        assert_eq!(record.cmd, work.cmd);
        assert_eq!(record.workdir, work.workdir);
    }

    #[test]
    fn qualification_rejects_bare_secrets_and_malformed_inherited_metadata() {
        let mut request = features();
        request.workload = Some(workload());
        let mut image = manifest();
        image.mode = PackMode::Vm;
        assert_eq!(
            request.qualify(&image).unwrap_err().code,
            ErrorCode::Unsupported
        );
        image.mode = PackMode::Container;
        image.secret_refs.insert(
            "TOKEN".into(),
            serde_json::from_value(serde_json::json!({"from_env":"PRIVATE_FIXTURE"})).unwrap(),
        );
        assert!(request.qualify(&image).is_err());
        image.secret_refs.clear();
        image.env.push("BAKED=duplicate".into());
        assert!(request.qualify(&image).is_err());
        image.env.clear();
        image.user = Some("bad\0user".into());
        assert!(request.qualify(&image).is_err());
    }

    #[test]
    fn public_workload_and_port_bounds_are_enforced_before_native_mutation() {
        let mut request = features();
        request.ports = vec![PortMapping { host: 0, guest: 80 }];
        assert!(request.validate().is_err());
        request.ports = vec![
            PortMapping {
                host: 80,
                guest: 80
            };
            2
        ];
        assert!(request.validate().is_err());
        request.ports.clear();
        let mut work = workload();
        work.env.insert("1INVALID".into(), "value".into());
        request.workload = Some(work.clone());
        assert!(request.validate().is_err());
        work.env.clear();
        work.cmd = vec!["x".repeat(16384); 4];
        request.workload = Some(work);
        assert!(request.validate().is_err());
    }
}
