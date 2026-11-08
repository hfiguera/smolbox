//! Verified OCI creation metadata. Host fetching/credentials belong to the owned
//! preparation job; this verifier performs no network, registry or SDK mutation.
use crate::{CreationFeatures, Error, ErrorCode, ImagePullRequest, Resources, Result};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use smolvm::config::VmRecord;
use smolvm_pack::format::PackManifest;
use std::collections::BTreeMap;

pub const OCI_METADATA_BYTES: usize = 1024 * 1024;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Manifest {
    schema_version: u32,
    media_type: Option<String>,
    config: Descriptor,
    #[serde(deserialize_with = "layers")]
    layers: usize,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Descriptor {
    media_type: String,
    digest: String,
    size: u64,
}
fn layers<'de, D: serde::Deserializer<'de>>(decoder: D) -> std::result::Result<usize, D::Error> {
    struct Visitor;
    impl<'de> serde::de::Visitor<'de> for Visitor {
        type Value = usize;
        fn expecting(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            f.write_str("bounded OCI layer descriptors")
        }
        fn visit_seq<A: serde::de::SeqAccess<'de>>(
            self,
            mut seq: A,
        ) -> std::result::Result<usize, A::Error> {
            let mut count = 0;
            while let Some(layer) = seq.next_element::<Descriptor>()? {
                count += 1;
                if count > 65536
                    || !digest(&layer.digest)
                    || layer.size > i64::MAX as u64
                    || layer.media_type.is_empty()
                    || layer.media_type.len() > 128
                {
                    return Err(serde::de::Error::custom("invalid layer descriptor"));
                }
            }
            Ok(count)
        }
    }
    decoder.deserialize_seq(Visitor)
}
#[derive(Deserialize)]
struct Config {
    architecture: String,
    os: String,
    config: Defaults,
}
#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
struct Defaults {
    #[serde(default)]
    env: Option<Vec<String>>,
    #[serde(default)]
    entrypoint: Option<Vec<String>>,
    #[serde(default)]
    cmd: Option<Vec<String>>,
    #[serde(default)]
    working_dir: Option<String>,
    #[serde(default)]
    user: Option<String>,
}
fn digest(value: &str) -> bool {
    value
        .strip_prefix("sha256:")
        .is_some_and(|d| crate::domain::valid_hex(d, 64))
}

/// Configuration descriptor from an exact pinned platform manifest. This proves
/// only the requested config identity/size, not downloaded bytes or approval.
#[derive(Clone)]
pub struct OciConfigDescriptor {
    digest: String,
    size: u64,
}
impl OciConfigDescriptor {
    pub fn digest(&self) -> &str {
        &self.digest
    }
    pub fn size(&self) -> u64 {
        self.size
    }
}
fn verified_manifest(source: &ImagePullRequest, bytes: &[u8]) -> Result<Manifest> {
    source.validate()?;
    if bytes.is_empty() || bytes.len() > OCI_METADATA_BYTES {
        return Err(Error::before(ErrorCode::OutputLimit));
    }
    let expected = source
        .reference
        .rsplit_once("@sha256:")
        .ok_or(Error::before(ErrorCode::Validation))?
        .1;
    if hex::encode(Sha256::digest(bytes)) != expected {
        return Err(Error::before(ErrorCode::Validation));
    }
    let manifest: Manifest =
        serde_json::from_slice(bytes).map_err(|_| Error::before(ErrorCode::Validation))?;
    if manifest.schema_version != 2
        || manifest.media_type.as_deref().is_some_and(|kind| {
            !matches!(
                kind,
                "application/vnd.oci.image.manifest.v1+json"
                    | "application/vnd.docker.distribution.manifest.v2+json"
            )
        })
        || !matches!(
            manifest.config.media_type.as_str(),
            "application/vnd.oci.image.config.v1+json"
                | "application/vnd.docker.container.image.v1+json"
        )
        || !digest(&manifest.config.digest)
        || manifest.config.size == 0
        || manifest.config.size > OCI_METADATA_BYTES as u64
    {
        return Err(Error::before(ErrorCode::Validation));
    }
    Ok(manifest)
}

/// Constructed only by verifying exact platform-manifest/config bytes against
/// the selected digest-pinned intent. Does not confer operator source approval.
#[derive(Clone)]
pub struct VerifiedOci {
    source: ImagePullRequest,
    manifest: PackManifest,
    layer_count: usize,
}
impl VerifiedOci {
    pub fn verify(
        source: ImagePullRequest,
        manifest_bytes: &[u8],
        config_bytes: &[u8],
    ) -> Result<Self> {
        let manifest = verified_manifest(&source, manifest_bytes)?;
        if config_bytes.is_empty() || config_bytes.len() > OCI_METADATA_BYTES {
            return Err(Error::before(ErrorCode::OutputLimit));
        }
        if manifest.config.size != config_bytes.len() as u64
            || manifest.config.digest
                != format!("sha256:{}", hex::encode(Sha256::digest(config_bytes)))
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        let config: Config = serde_json::from_slice(config_bytes)
            .map_err(|_| Error::before(ErrorCode::Validation))?;
        if config.os != "linux"
            || config.architecture != source.platform.trim_start_matches("linux/")
        {
            return Err(Error::before(ErrorCode::Unsupported));
        }
        let mut metadata = PackManifest::new(
            source.reference.clone(),
            manifest.config.digest,
            source.platform.clone(),
            source.platform.clone(),
        );
        metadata.entrypoint = config.config.entrypoint.unwrap_or_default();
        metadata.cmd = config.config.cmd.unwrap_or_default();
        metadata.env = config.config.env.unwrap_or_default();
        metadata.workdir = config.config.working_dir.filter(|v| !v.is_empty());
        metadata.user = config.config.user.filter(|v| !v.is_empty());
        Ok(Self {
            source,
            manifest: metadata,
            layer_count: manifest.layers,
        })
    }
    /// Verify the manifest before selecting any configuration-blob request.
    pub fn configuration(source: &ImagePullRequest, bytes: &[u8]) -> Result<OciConfigDescriptor> {
        let manifest = verified_manifest(source, bytes)?;
        Ok(OciConfigDescriptor {
            digest: manifest.config.digest,
            size: manifest.config.size,
        })
    }
    pub fn source(&self) -> &ImagePullRequest {
        &self.source
    }
    pub fn layer_count(&self) -> usize {
        self.layer_count
    }
    pub(crate) fn qualify(&self, features: &CreationFeatures) -> Result<()> {
        if self.source.platform != native_oci_platform() {
            return Err(Error::before(ErrorCode::Unsupported));
        }
        features.qualify(&self.manifest)
    }
    pub(crate) fn record(
        &self,
        name: &str,
        resources: Resources,
        labels: BTreeMap<String, String>,
        features: &CreationFeatures,
    ) -> Result<VmRecord> {
        resources.validate()?;
        self.qualify(features)?;
        let mut record = smolvm::embedded::MachineSpec {
            name: name.into(),
            persistent: true,
            image: Some(self.source.reference.clone()),
            labels,
            resources: smolvm::agent::VmResources {
                cpus: resources.cpus,
                memory_mib: resources.memory_mib,
                storage_gib: Some(resources.storage_gib),
                overlay_gib: Some(resources.overlay_gib),
                network: false,
                allowed_cidrs: Some(vec![]),
                ..Default::default()
            },
            ..Default::default()
        }
        .to_record();
        record.entrypoint = vec!["/bin/true".into()];
        record.cmd = Vec::new();
        record.env = Vec::new();
        record.workdir = Some("/".into());
        record.user = Some("0".into());
        features.apply(&mut record, &self.manifest)?;
        // This field remains None for direct OCI creation. Imported local/
        // registry/checkpoint packs keep their source_smolmachine identity.
        if record.source_smolmachine.is_some() {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(record)
    }
}

pub(crate) fn native_oci_platform() -> &'static str {
    if cfg!(target_arch = "aarch64") {
        "linux/arm64"
    } else {
        "linux/amd64"
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    pub(crate) fn bytes() -> (ImagePullRequest, Vec<u8>, Vec<u8>) {
        let config = serde_json::to_vec(
            &serde_json::json!({"architecture":native_oci_platform().trim_start_matches("linux/"),
            "os":"linux","config":{"Entrypoint":["/app"],"Cmd":["serve"],"Env":["A=old","B=base"],
                "WorkingDir":"/workspace","User":"1234:2345"}}),
        )
        .unwrap();
        let manifest = serde_json::to_vec(&serde_json::json!({"schemaVersion":2,
            "mediaType":"application/vnd.oci.image.manifest.v1+json","config":{
                "mediaType":"application/vnd.oci.image.config.v1+json", "digest":format!("sha256:{}",hex::encode(Sha256::digest(&config))),
                "size":config.len()}, "layers":[]})).unwrap();
        let source = ImagePullRequest {
            reference: format!(
                "registry.example/app@sha256:{}",
                hex::encode(Sha256::digest(&manifest))
            ),
            platform: native_oci_platform().into(),
        };
        (source, manifest, config)
    }
    pub(crate) fn verified() -> VerifiedOci {
        let (source, manifest, config) = bytes();
        VerifiedOci::verify(source, &manifest, &config).unwrap()
    }
    pub(crate) fn features() -> CreationFeatures {
        CreationFeatures {
            network: crate::NetworkPolicy {
                enabled: true,
                hosts: vec!["registry.example".into()],
                cidrs: vec![],
            },
            ports: vec![],
            workload: None,
        }
    }
    #[test]
    fn configuration_descriptor_is_verified_before_a_blob_can_be_selected() {
        let (source, manifest, config) = bytes();
        let descriptor = VerifiedOci::configuration(&source, &manifest).unwrap();
        assert_eq!(
            descriptor.digest(),
            format!("sha256:{}", hex::encode(Sha256::digest(&config)))
        );
        assert_eq!(descriptor.size(), config.len() as u64);
        let original: serde_json::Value = serde_json::from_slice(&manifest).unwrap();
        for (field, value) in [
            ("size", serde_json::json!(0)),
            ("size", serde_json::json!(OCI_METADATA_BYTES + 1)),
            ("digest", serde_json::json!("sha256:invalid")),
            (
                "mediaType",
                serde_json::json!("application/vnd.smolmachines.machine.config.v1+json"),
            ),
        ] {
            let mut changed = original.clone();
            changed["config"][field] = value;
            let encoded = serde_json::to_vec(&changed).unwrap();
            let mut pinned = source.clone();
            pinned.reference = format!(
                "registry.example/app@sha256:{}",
                hex::encode(Sha256::digest(&encoded))
            );
            assert!(VerifiedOci::configuration(&pinned, &encoded).is_err());
        }
        let mut index = original;
        index["mediaType"] = serde_json::json!("application/vnd.oci.image.index.v1+json");
        let encoded = serde_json::to_vec(&index).unwrap();
        let mut pinned = source;
        pinned.reference = format!(
            "registry.example/app@sha256:{}",
            hex::encode(Sha256::digest(&encoded))
        );
        assert!(VerifiedOci::configuration(&pinned, &encoded).is_err());
    }
    #[test]
    fn manifests_bind_content_size_platform_and_configuration_without_network_or_indexes() {
        let (source, manifest, config) = bytes();
        let verified = VerifiedOci::verify(source.clone(), &manifest, &config).unwrap();
        assert!(verified.source() == &source);
        assert_eq!(verified.layer_count(), 0);
        let mut changed = config.clone();
        changed.push(b' ');
        assert!(VerifiedOci::verify(source.clone(), &manifest, &changed).is_err());
        let mut wrong = source.clone();
        wrong.platform = if source.platform == "linux/arm64" {
            "linux/amd64"
        } else {
            "linux/arm64"
        }
        .into();
        assert!(VerifiedOci::verify(wrong, &manifest, &config).is_err());
        for (key, value) in [
            ("schemaVersion", serde_json::json!(1)),
            (
                "mediaType",
                serde_json::json!("application/vnd.oci.image.index.v1+json"),
            ),
            (
                "config",
                serde_json::json!({"mediaType":"application/vnd.oci.image.config.v1+json", "digest":format!("sha256:{}","a".repeat(64)),"size":config.len()}),
            ),
        ] {
            let mut raw: serde_json::Value = serde_json::from_slice(&manifest).unwrap();
            raw[key] = value;
            let raw = serde_json::to_vec(&raw).unwrap();
            let mut selected = source.clone();
            selected.reference = format!(
                "registry.example/app@sha256:{}",
                hex::encode(Sha256::digest(&raw))
            );
            assert!(VerifiedOci::verify(selected, &raw, &config).is_err());
        }
        assert!(VerifiedOci::verify(source, &vec![b' '; OCI_METADATA_BYTES + 1], &config).is_err());
    }
    #[test]
    fn fresh_oci_records_are_neutral_or_exactly_resolve_approved_workload_inheritance() {
        let verified = verified();
        let resources = Resources {
            cpus: 1,
            memory_mib: 256,
            storage_gib: 1,
            overlay_gib: 1,
        };
        let mut features = features();
        let neutral = verified
            .record("owned", resources, BTreeMap::new(), &features)
            .unwrap();
        assert_eq!(
            neutral.image.as_deref(),
            Some(verified.source.reference.as_str())
        );
        assert!(neutral.source_smolmachine.is_none());
        assert_eq!(neutral.entrypoint, vec!["/bin/true"]);
        assert!(neutral.cmd.is_empty() && neutral.env.is_empty());
        features.workload = Some(crate::StartupWorkload {
            entrypoint: vec![],
            cmd: vec![],
            env: BTreeMap::from([("A".into(), "override".into())]),
            workdir: None,
        });
        let workload = verified
            .record("owned", resources, BTreeMap::new(), &features)
            .unwrap();
        assert_eq!(workload.entrypoint, vec!["/app"]);
        assert_eq!(workload.cmd, vec!["serve"]);
        assert_eq!(
            workload.env,
            BTreeMap::from([("A".into(), "override".into()), ("B".into(), "base".into())])
                .into_iter()
                .collect::<Vec<_>>()
        );
        assert_eq!(workload.user.as_deref(), Some("1234:2345"));
        assert_eq!(workload.workdir.as_deref(), Some("/workspace"));
        assert_eq!(workload.allowed_cidrs, Some(vec![]));
        assert_eq!(
            workload.dns_filter_hosts,
            Some(vec!["registry.example".into()])
        );
        features.workload.as_mut().unwrap().cmd = vec!["worker".into()];
        let explicit = verified
            .record("owned", resources, BTreeMap::new(), &features)
            .unwrap();
        assert!(explicit.entrypoint.is_empty());
        assert_eq!(explicit.cmd, vec!["worker"]);
        let mut pack = workload.clone();
        pack.source_smolmachine = Some("/approved/import.smolmachine".into());
        assert_ne!(
            crate::identity::material_hash(&workload).unwrap(),
            crate::identity::material_hash(&pack).unwrap()
        );
    }
}
