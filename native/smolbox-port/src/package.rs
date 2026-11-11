use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use smolbox_protocol::{Artifact, PackageIdentity, SafeCode, SdkIdentity};
use std::collections::BTreeSet;
use std::fs::{File, OpenOptions};
use std::io::Read;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Component, Path, PathBuf};

const MAX_METADATA: u64 = 4 * 1024 * 1024;
const MAX_ASSETS: usize = 16384;
const MAX_ASSET_BYTES: u64 = 32 * 1024 * 1024 * 1024;

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    pub schema: u8,
    pub target_id: String,
    pub generation: String,
    pub allow_initialize: bool,
    pub package_manifest_sha256: String,
    pub approved_artifacts: Vec<Artifact>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub approved_oci_sources: Option<Vec<smolbox_protocol::OciSource>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub approved_registry_sources: Option<Vec<RegistryApproval>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub approved_checkpoints: Option<Vec<CheckpointApproval>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub approved_export_destinations: Option<Vec<ExportApproval>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub approved_volume_policy: Option<smolbox_engine::LocalVolumePolicy>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub approved_branches: Option<Vec<smolbox_protocol::BranchApproval>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub publish_address: Option<String>,
}

fn validate_branch_catalog(
    schema: u8,
    branches: Option<&[smolbox_protocol::BranchApproval]>,
) -> Result<(), SafeCode> {
    if let Some(branches) = branches {
        if schema != 2 || branches.is_empty() || branches.len() > 32 * 32 {
            return Err(SafeCode::Validation);
        }
        let mut seen = std::collections::BTreeMap::new();
        for branch in branches {
            branch.validate().map_err(|_| SafeCode::Validation)?;
            let (resources, overheads) = seen
                .entry(&branch.id)
                .or_insert((&branch.resources, BTreeSet::new()));
            // One public policy may serve profiles with distinct host overhead.
            // Its backing allowance cannot change between those variants.
            if *resources != &branch.resources
                || overheads.len() >= 32
                || !overheads.insert(branch.host_overhead_mb)
            {
                return Err(SafeCode::Validation);
            }
        }
        if seen.len() > 32 {
            return Err(SafeCode::Validation);
        }
    }
    Ok(())
}

/// Operator-only destination/TLS approval; requests carry IDs, hashes and caps.
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ExportApproval {
    pub id: String,
    pub registry: String,
    pub repository: String,
    pub credential_ref: String,
    pub immutable_tags: bool,
    pub allow_insecure_loopback: bool,
    pub ca_cert_file: Option<PathBuf>,
    pub ca_certificate_sha256: Option<String>,
    pub destination_sha256: String,
    pub max_artifact_bytes: u64,
    pub max_staging_bytes: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conversion_resources: Option<smolbox_engine::ExportConversionResources>,
    #[serde(skip)]
    pub resolved: Option<smolbox_engine::ApprovedExportDestination>,
}
impl ExportApproval {
    pub fn resolve(&mut self) -> Result<(), SafeCode> {
        if let Some(resources) = &self.conversion_resources {
            resources.validate().map_err(|_| SafeCode::Validation)?;
            if self.max_staging_bytes > resources.disk_gb * 1_073_741_824 {
                return Err(SafeCode::Validation);
            }
        }
        let limits = smolbox_protocol::ExportLimits::default();
        if (smolbox_protocol::OciSource {
            reference: format!(
                "{}/{}@sha256:{}",
                self.registry,
                self.repository,
                "0".repeat(64)
            ),
            platform: "linux/amd64".into(),
        })
        .validate()
        .is_err()
            || !valid_hash(&self.destination_sha256)
            || self.max_artifact_bytes == 0
            || self.max_artifact_bytes > self.max_staging_bytes
            || self.max_staging_bytes > limits.staging_bytes
            || self.credential_ref.is_empty()
            || self.credential_ref.len() > 128
            || matches!(self.credential_ref.as_str(), "." | "..")
            || !self
                .credential_ref
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(&byte))
        {
            return Err(SafeCode::Validation);
        }
        let pem = match (&self.ca_cert_file, &self.ca_certificate_sha256) {
            (None, None) => None,
            (Some(path), Some(expected))
                if path.is_absolute() && path.as_os_str().len() <= 4096 && valid_hash(expected) =>
            {
                let bytes = bounded_file(path, 256 * 1024)?;
                if hash_bytes(&bytes) != *expected {
                    return Err(SafeCode::Validation);
                }
                Some(bytes)
            }
            _ => return Err(SafeCode::Validation),
        };
        let destination = smolbox_engine::ApprovedExportDestination {
            id: self.id.clone(),
            registry: self.registry.clone(),
            repository: self.repository.clone(),
            immutable_tags: self.immutable_tags,
            allow_insecure_loopback: self.allow_insecure_loopback,
            ca_certificate_pem: pem,
        };
        destination.validate().map_err(|_| SafeCode::Validation)?;
        if destination.digest().map_err(|_| SafeCode::Validation)? != self.destination_sha256 {
            return Err(SafeCode::Validation);
        }
        self.resolved = Some(destination);
        Ok(())
    }
    pub fn matches(&self, request: &smolbox_protocol::ExportRequest) -> bool {
        self.resolved.is_some()
            && self.id == request.destination_id
            && self.destination_sha256 == request.destination_sha256
            && request.max_artifact_bytes <= self.max_artifact_bytes
            && request.max_staging_bytes <= self.max_staging_bytes
    }
}

/// Operator-only checkpoint paths. Requests carry just the immutable identity.
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CheckpointApproval {
    pub source: smolbox_protocol::CheckpointIdentity,
    pub path: PathBuf,
    pub max_bytes: u64,
    pub sdk_version: String,
    pub host_platform: String,
    pub resources: smolbox_protocol::Resources,
}
impl CheckpointApproval {
    pub fn matches(
        &self,
        source: &smolbox_protocol::CheckpointIdentity,
        resources: &smolbox_protocol::Resources,
    ) -> bool {
        self.source == *source && self.resources == *resources
    }
    pub fn engine(&self) -> Result<smolbox_engine::ApprovedCheckpoint, SafeCode> {
        self.source.validate().map_err(|_| SafeCode::Validation)?;
        self.resources
            .validate()
            .map_err(|_| SafeCode::Validation)?;
        let approval = smolbox_engine::ApprovedCheckpoint {
            artifact: smolbox_engine::ApprovedCheckpointArtifact {
                path: self.path.clone(),
                sha256: self.source.sha256.clone(),
                max_bytes: self.max_bytes,
                guest_platform: self.source.guest_platform().into(),
            },
            sdk_version: self.sdk_version.clone(),
            host_platform: self.host_platform.clone(),
            resources: smolbox_engine::Resources {
                cpus: self.resources.cpus,
                memory_mib: self.resources.memory_mib,
                storage_gib: self.resources.storage_gib,
                overlay_gib: self.resources.overlay_gib,
            },
        };
        approval.validate().map_err(|_| SafeCode::Validation)?;
        Ok(approval)
    }
}

/// Non-secret source/policy catalog. Tokens arrive separately per operation.
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RegistryApproval {
    pub source: smolbox_engine::RegistryArtifactSource,
    pub max_bytes: u64,
    pub cache_policy: smolbox_engine::RegistryCachePolicy,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub credential_ref: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub token_realm: Option<String>,
}
impl RegistryApproval {
    pub fn matches(
        &self,
        source: &smolbox_protocol::RegistrySource,
        credential_ref: Option<&str>,
    ) -> bool {
        self.source.reference == source.reference
            && self.source.platform == source.platform
            && self.source.content_sha256 == source.content_sha256
            && self.credential_ref.as_deref() == credential_ref
    }
    fn validate(&self) -> Result<(), SafeCode> {
        self.source.validate().map_err(|_| SafeCode::Validation)?;
        self.cache_policy
            .validate()
            .map_err(|_| SafeCode::Validation)?;
        if self.max_bytes == 0 || self.max_bytes > smolbox_engine::JOB_REGISTRY_STAGING_BYTES {
            return Err(SafeCode::Validation);
        }
        match (&self.credential_ref, &self.token_realm) {
            (None, None) => {}
            (Some(reference), Some(realm)) => {
                if matches!(reference.as_str(), "." | "..")
                    || reference.is_empty()
                    || reference.len() > 128
                    || !reference
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
                {
                    return Err(SafeCode::Validation);
                }
                smolbox_engine::RegistryIdentityCredential::validate_realm(realm)
                    .map_err(|_| SafeCode::Validation)?;
                smolbox_engine::RegistryIdentityCredential::validate_destination(
                    &self.source.reference,
                )
                .map_err(|_| SafeCode::Validation)?;
            }
            _ => return Err(SafeCode::Validation),
        }
        Ok(())
    }
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Manifest {
    pub schema: u8,
    pub policy: serde_json::Value,
    pub identity: PackageIdentity,
    pub assets: Vec<Asset>,
    pub host_tools: Vec<HostTool>,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HostTool {
    pub path: String,
    pub sha256: String,
}
#[derive(Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum Asset {
    File {
        path: String,
        sha256: String,
        bytes: u64,
        mode: u32,
    },
    Symlink {
        path: String,
        target: String,
    },
}
impl Asset {
    fn path(&self) -> &str {
        match self {
            Self::File { path, .. } | Self::Symlink { path, .. } => path,
        }
    }
}

pub struct VerifiedPackage {
    pub root: PathBuf,
    pub identity: PackageIdentity,
    pub templates: smolbox_engine::ApprovedTemplates,
    pub export_assets: Option<smolbox_engine::ApprovedExportAssets>,
}
pub fn source_sha256() -> String {
    hash_bytes(include_bytes!("../../vendor/source.json"))
}
// Package approval is platform-specific. The macOS/default policy retains its
// earlier descriptor; Linux volumes still require explicit operator approval.
#[cfg(target_os = "linux")]
const POLICY_BYTES: &[u8] = include_bytes!("../../policy-linux.json");
#[cfg(not(target_os = "linux"))]
const POLICY_BYTES: &[u8] = include_bytes!("../../policy.json");

fn policy_matches(manifest: &Manifest) -> bool {
    manifest.schema == 3
        && serde_json::from_slice::<serde_json::Value>(POLICY_BYTES)
            .is_ok_and(|expected| manifest.policy == expected)
}
pub fn sdk_identity() -> Result<SdkIdentity, SafeCode> {
    let policy: serde_json::Value =
        serde_json::from_slice(POLICY_BYTES).map_err(|_| SafeCode::Package)?;
    let sdk: SdkIdentity =
        serde_json::from_value(policy["sdk"].clone()).map_err(|_| SafeCode::Package)?;
    sdk.validate().map_err(|_| SafeCode::Package)?;
    if sdk.sdk_version != smolvm::VERSION || sdk.source_revision != smolbox_engine::SMOLVM_REVISION
    {
        return Err(SafeCode::Package);
    }
    Ok(sdk)
}
pub fn hash_bytes(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}
pub fn read_config(path: &Path) -> Result<Config, SafeCode> {
    // A full 32-policy by 32-profile branch catalog needs more than 64 KiB.
    // Only configurations carrying that bounded catalog receive the allowance.
    let bytes = bounded_file(path, 512 * 1024)?;
    let mut config: Config = serde_json::from_slice(&bytes).map_err(|_| SafeCode::Validation)?;
    if config.approved_branches.is_none() && bytes.len() > 65536 {
        return Err(SafeCode::Validation);
    }
    let domain = smolbox_protocol::DomainIdentity {
        target_id: config.target_id.clone(),
        generation: config.generation.clone(),
    };
    // Reuse receipt validation for the stable ID/generation scalar grammar.
    let receipt = smolbox_protocol::Receipt {
        target_id: domain.target_id,
        domain_generation: domain.generation,
        name: "validation".into(),
        owner_token: "0".repeat(64),
        incarnation: "0".repeat(32),
        material_sha256: "0".repeat(64),
        material: None,
    };
    receipt.validate().map_err(|_| SafeCode::Validation)?;
    if config.schema != 2
        || !valid_hash(&config.package_manifest_sha256)
        || config.approved_artifacts.len() > 64
    {
        return Err(SafeCode::Validation);
    }
    if let Some(destinations) = &mut config.approved_export_destinations {
        if destinations.is_empty() || destinations.len() > 32 {
            return Err(SafeCode::Validation);
        }
        let mut seen = BTreeSet::new();
        for destination in destinations {
            destination.resolve()?;
            if !seen.insert(destination.id.clone()) {
                return Err(SafeCode::Validation);
            }
        }
    }
    validate_branch_catalog(config.schema, config.approved_branches.as_deref())?;
    if let Some(policy) = &config.approved_volume_policy {
        policy.validate().map_err(|_| SafeCode::Validation)?;
    }
    if let Some(checkpoints) = &config.approved_checkpoints {
        if checkpoints.is_empty() || checkpoints.len() > 32 {
            return Err(SafeCode::Validation);
        }
        let mut seen = BTreeSet::new();
        for checkpoint in checkpoints {
            checkpoint.engine()?;
            if !seen.insert(&checkpoint.source.id) {
                return Err(SafeCode::Validation);
            }
        }
    }
    if config.publish_address.as_ref().is_some_and(|value| {
        value
            .parse::<std::net::Ipv4Addr>()
            .map_or(true, |ip| ip.to_string() != *value)
    }) {
        return Err(SafeCode::Validation);
    }
    if let Some(sources) = &config.approved_oci_sources {
        if sources.len() > 32 {
            return Err(SafeCode::Validation);
        }
        let mut seen = BTreeSet::new();
        for source in sources {
            source.validate().map_err(|_| SafeCode::Validation)?;
            smolbox_engine::ImagePullRequest {
                reference: source.reference.clone(),
                platform: source.platform.clone(),
            }
            .validate()
            .map_err(|_| SafeCode::Validation)?;
            if !seen.insert((&source.reference, &source.platform)) {
                return Err(SafeCode::Validation);
            }
        }
    }
    if let Some(sources) = &config.approved_registry_sources {
        if config.schema != 2 || sources.is_empty() || sources.len() > 32 {
            return Err(SafeCode::Validation);
        }
        let mut seen = BTreeSet::new();
        let mut policy = None;
        for approval in sources {
            approval.validate()?;
            if !seen.insert((
                &approval.source.reference,
                &approval.source.platform,
                &approval.source.content_sha256,
                &approval.credential_ref,
            )) || policy.is_some_and(|policy| policy != approval.cache_policy)
            {
                return Err(SafeCode::Validation);
            }
            policy = Some(approval.cache_policy);
        }
    }
    for artifact in &config.approved_artifacts {
        if !Path::new(&artifact.path).is_absolute()
            || !valid_hash(&artifact.sha256)
            || artifact.max_bytes == 0
            || artifact.max_bytes > MAX_ASSET_BYTES
            || !matches!(
                artifact.guest_platform.as_str(),
                "linux/amd64" | "linux/arm64"
            )
        {
            return Err(SafeCode::Validation);
        }
    }
    Ok(config)
}

pub fn verify(executable: &Path, manifest_sha256: &str) -> Result<VerifiedPackage, SafeCode> {
    let root = executable.parent().ok_or(SafeCode::Package)?.to_path_buf();
    let bytes = bounded_file(&root.join("package.json"), MAX_METADATA)?;
    if hash_bytes(&bytes) != manifest_sha256 {
        return Err(SafeCode::Package);
    }
    let manifest: Manifest = serde_json::from_slice(&bytes).map_err(|_| SafeCode::Package)?;
    let identity = &manifest.identity;
    if !policy_matches(&manifest)
        || identity.engine_version != env!("CARGO_PKG_VERSION")
        || identity.smolvm_revision != smolbox_engine::SMOLVM_REVISION
        || identity.source_sha256 != source_sha256()
        || identity.platform != platform()
        || identity.architecture != std::env::consts::ARCH
        || !valid_hash(&identity.build_sha256)
        || !valid_hash(&identity.assets_sha256)
        || manifest.assets.len() > MAX_ASSETS
        || manifest.assets.is_empty()
    {
        return Err(SafeCode::Package);
    }
    if bounded_file(&root.join("SMOLBOX-POLICY.json"), 8192)? != POLICY_BYTES
        || bounded_file(&root.join("NATIVE-SOURCE.json"), 8192)?
            != include_bytes!("../../vendor/source.json")
    {
        return Err(SafeCode::Package);
    }
    if hash_file(executable, MAX_ASSET_BYTES)? != identity.build_sha256
        || hash_bytes(&serde_json::to_vec(&manifest.assets).map_err(|_| SafeCode::Package)?)
            != identity.assets_sha256
    {
        return Err(SafeCode::Package);
    }
    let mut paths = BTreeSet::new();
    let mut total = 0u64;
    for asset in &manifest.assets {
        let relative = safe_relative(asset.path())?;
        if !paths.insert(asset.path().to_string()) {
            return Err(SafeCode::Package);
        }
        check_parents(&root, &relative)?;
        let path = root.join(relative);
        let meta = std::fs::symlink_metadata(&path).map_err(|_| SafeCode::Package)?;
        match asset {
            Asset::File {
                sha256,
                bytes,
                mode,
                ..
            } => {
                total = total.checked_add(*bytes).ok_or(SafeCode::Package)?;
                if !meta.is_file()
                    || *bytes > MAX_ASSET_BYTES
                    || total > MAX_ASSET_BYTES
                    || meta.len() != *bytes
                    || (meta.permissions().mode() & 0o777) != *mode
                    || !valid_hash(sha256)
                    || hash_file(&path, *bytes)? != *sha256
                {
                    return Err(SafeCode::Package);
                }
            }
            Asset::Symlink {
                path: relative,
                target,
            } => {
                // Guest-rootfs absolute links are guest paths, never host paths.
                // Verification uses read_link only; no asset traversal follows them.
                if !relative.starts_with("agent-rootfs/")
                    || !meta.file_type().is_symlink()
                    || target.is_empty()
                    || target.len() > 4096
                    || std::fs::read_link(&path).map_err(|_| SafeCode::Package)?
                        != Path::new(target)
                {
                    return Err(SafeCode::Package);
                }
            }
        }
    }
    for required in required_assets() {
        if !manifest
            .assets
            .iter()
            .any(|asset| matches!(asset, Asset::File { path, .. } if path == required))
        {
            return Err(SafeCode::Package);
        }
    }
    // Require every shipped file/link to be declared. The SDK writes only its
    // known rootfs-readiness markers and decompressed templates after preflight.
    verify_inventory(&root.join("lib"), &root, &paths)?;
    verify_inventory(&root.join("agent-rootfs"), &root, &paths)?;
    entitlement(executable)?;
    if manifest.host_tools.len() != 1 {
        return Err(SafeCode::Package);
    }
    let resize = resolve_resize2fs().ok_or(SafeCode::Package)?;
    if manifest.host_tools[0].path != resize.to_str().ok_or(SafeCode::Package)?
        || hash_file(&resize, 64 * 1024 * 1024)? != manifest.host_tools[0].sha256
    {
        return Err(SafeCode::Package);
    }
    Ok(VerifiedPackage {
        templates: approved_templates(&root, &manifest.assets)?,
        export_assets: approved_export_assets(&root, &manifest.assets)?,
        root,
        identity: manifest.identity,
    })
}
fn approved_export_assets(
    root: &Path,
    assets: &[Asset],
) -> Result<Option<smolbox_engine::ApprovedExportAssets>, SafeCode> {
    // Older approved packages contain only the rootfs directory. Do not invent
    // a tar from inventory or make their unchanged setup depend on new assets.
    if !assets
        .iter()
        .any(|asset| asset.path() == "agent-rootfs.tar")
    {
        return Ok(None);
    }
    let names = if cfg!(target_os = "macos") {
        [
            "agent-rootfs.tar",
            "lib/libkrun.dylib",
            "lib/libkrunfw.5.dylib",
        ]
    } else {
        ["agent-rootfs.tar", "lib/libkrun.so", "lib/libkrunfw.so.5"]
    };
    let mut files = Vec::new();
    for name in names {
        let matches: Vec<_> = assets.iter().filter(|asset| asset.path() == name).collect();
        let [Asset::File {
            path,
            sha256,
            bytes,
            mode,
        }] = matches.as_slice()
        else {
            return Err(SafeCode::Package);
        };
        if *bytes == 0
            || *bytes > 2 * 1024 * 1024 * 1024
            || !valid_hash(sha256)
            || *mode & 0o022 != 0
        {
            return Err(SafeCode::Package);
        }
        files.push(smolbox_engine::ApprovedExportAsset {
            name: name.into(),
            path: root.join(path),
            sha256: sha256.clone(),
            max_bytes: *bytes,
        });
    }
    Ok(Some(smolbox_engine::ApprovedExportAssets { files }))
}

fn approved_templates(
    root: &Path,
    assets: &[Asset],
) -> Result<smolbox_engine::ApprovedTemplates, SafeCode> {
    let evidence = |name: &str| {
        assets
            .iter()
            .find_map(|asset| match asset {
                Asset::File {
                    path,
                    sha256,
                    bytes,
                    ..
                } if path == name => Some(smolbox_engine::TemplateFile {
                    path: root.join(path),
                    sha256: sha256.clone(),
                    bytes: *bytes,
                }),
                _ => None,
            })
            .ok_or(SafeCode::Package)
    };
    let template = |name: &str| {
        Ok(smolbox_engine::ApprovedTemplate {
            plain: evidence(name)?,
            compressed: evidence(&format!("{name}.zst"))?,
        })
    };
    Ok(smolbox_engine::ApprovedTemplates {
        storage: template("storage-template.ext4")?,
        overlay: template("overlay-template.ext4")?,
    })
}
fn required_assets() -> Vec<&'static str> {
    let mut assets = vec![
        "SMOLBOX-LICENSE",
        "SMOLVM-LICENSE",
        "SMOLVM-LICENSES.md",
        "NATIVE-SOURCE.json",
        "SMOLBOX-POLICY.json",
        "storage-template.ext4.zst",
        "overlay-template.ext4.zst",
        "storage-template.ext4",
        "overlay-template.ext4",
        "agent-rootfs/usr/local/bin/smolvm-agent",
    ];
    if cfg!(target_os = "macos") {
        assets.extend([
            "lib/libkrun.dylib",
            "lib/libkrunfw.5.dylib",
            "lib/libkrunfw.dylib",
            "lib/libepoxy.0.dylib",
            "lib/libvirglrenderer.1.dylib",
            "lib/libMoltenVK.dylib",
        ]);
    } else {
        assets.extend(["lib/libkrun.so", "lib/libkrunfw.so"]);
    }
    assets
}
fn verify_inventory(
    directory: &Path,
    root: &Path,
    declared: &BTreeSet<String>,
) -> Result<(), SafeCode> {
    let mut directories = vec![directory.to_path_buf()];
    let mut count = 0;
    while let Some(directory) = directories.pop() {
        if !std::fs::symlink_metadata(&directory)
            .map_err(|_| SafeCode::Package)?
            .is_dir()
        {
            return Err(SafeCode::Package);
        }
        for entry in std::fs::read_dir(directory).map_err(|_| SafeCode::Package)? {
            let path = entry.map_err(|_| SafeCode::Package)?.path();
            count += 1;
            if count > MAX_ASSETS * 2 {
                return Err(SafeCode::Package);
            }
            let meta = std::fs::symlink_metadata(&path).map_err(|_| SafeCode::Package)?;
            if meta.is_dir() {
                directories.push(path);
            } else {
                let relative = path
                    .strip_prefix(root)
                    .map_err(|_| SafeCode::Package)?
                    .to_str()
                    .ok_or(SafeCode::Package)?;
                let marker = path
                    .file_name()
                    .is_some_and(|name| name.to_string_lossy().starts_with(".smolvm-ready."));
                if !(declared.contains(relative) || marker && meta.is_file() && meta.len() <= 4096)
                {
                    return Err(SafeCode::Package);
                }
            }
        }
    }
    Ok(())
}
fn safe_relative(path: &str) -> Result<PathBuf, SafeCode> {
    let path = PathBuf::from(path);
    if path.as_os_str().is_empty()
        || path.as_os_str().len() > 4096
        || path
            .components()
            .any(|part| !matches!(part, Component::Normal(_)))
    {
        return Err(SafeCode::Package);
    }
    Ok(path)
}
fn check_parents(root: &Path, relative: &Path) -> Result<(), SafeCode> {
    let mut parent = root.to_path_buf();
    let mut components = relative.components().peekable();
    while let Some(component) = components.next() {
        if components.peek().is_none() {
            break;
        }
        parent.push(component);
        if !std::fs::symlink_metadata(&parent)
            .map_err(|_| SafeCode::Package)?
            .is_dir()
        {
            return Err(SafeCode::Package);
        }
    }
    Ok(())
}
fn open_file(path: &Path) -> Result<File, SafeCode> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(path)
        .map_err(|_| SafeCode::Package)?;
    if !file.metadata().map_err(|_| SafeCode::Package)?.is_file() {
        return Err(SafeCode::Package);
    }
    Ok(file)
}
fn bounded_file(path: &Path, max: u64) -> Result<Vec<u8>, SafeCode> {
    let mut bytes = Vec::new();
    open_file(path)?
        .take(max + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| SafeCode::Package)?;
    if bytes.len() as u64 > max {
        return Err(SafeCode::Package);
    }
    Ok(bytes)
}
pub fn hash_file(path: &Path, max: u64) -> Result<String, SafeCode> {
    let mut file = open_file(path)?;
    let mut buffer = [0; 65536];
    let mut hash = Sha256::new();
    let mut total = 0;
    loop {
        let count = file.read(&mut buffer).map_err(|_| SafeCode::Package)?;
        if count == 0 {
            break;
        }
        total += count as u64;
        if total > max {
            return Err(SafeCode::Package);
        }
        hash.update(&buffer[..count]);
    }
    Ok(hex::encode(hash.finalize()))
}
fn valid_hash(hash: &str) -> bool {
    hash.len() == 64
        && hash
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
fn platform() -> &'static str {
    if cfg!(target_os = "macos") {
        "macos"
    } else {
        "linux"
    }
}
fn resolve_resize2fs() -> Option<PathBuf> {
    let fixed = [
        "/opt/homebrew/opt/e2fsprogs/sbin",
        "/usr/local/opt/e2fsprogs/sbin",
        "/opt/homebrew/sbin",
        "/usr/local/sbin",
        "/sbin",
        "/usr/sbin",
    ];
    fixed
        .into_iter()
        .map(PathBuf::from)
        .chain(std::env::split_paths(
            &std::env::var_os("PATH").unwrap_or_default(),
        ))
        .map(|directory| directory.join("resize2fs"))
        .find(|path| {
            path.is_absolute()
                && path.is_file()
                && path
                    .metadata()
                    .is_ok_and(|m| m.permissions().mode() & 0o111 != 0)
        })
}
#[cfg(target_os = "macos")]
fn entitlement(executable: &Path) -> Result<(), SafeCode> {
    use std::io::Write;
    let mut verify = std::process::Command::new("/usr/bin/codesign");
    verify.args(["--verify", "--strict"]).arg(executable);
    utility(verify)?;
    let mut display = std::process::Command::new("/usr/bin/codesign");
    display.args(["-d", "--entitlements", ":-"]).arg(executable);
    let plist = utility(display)?;
    let mut file = tempfile::NamedTempFile::new().map_err(|_| SafeCode::Package)?;
    file.write_all(&plist).map_err(|_| SafeCode::Package)?;
    let mut extract = std::process::Command::new("/usr/bin/plutil");
    extract
        .args([
            "-extract",
            r"com\.apple\.security\.hypervisor",
            "raw",
            "-o",
            "-",
        ])
        .arg(file.path());
    if utility(extract)? != b"true\n" {
        return Err(SafeCode::Package);
    }
    Ok(())
}
#[cfg(target_os = "macos")]
fn utility(mut command: std::process::Command) -> Result<Vec<u8>, SafeCode> {
    use std::process::Stdio;
    use std::time::{Duration, Instant};
    let mut child = command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| SafeCode::Package)?;
    let stdout = child.stdout.take().ok_or(SafeCode::Package)?;
    let overflow = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let oversized = overflow.clone();
    let reader = std::thread::spawn(move || {
        let mut bytes = Vec::new();
        let result = stdout.take(65537).read_to_end(&mut bytes);
        oversized.store(bytes.len() > 65536, std::sync::atomic::Ordering::Release);
        result.map(|_| bytes)
    });
    let started = Instant::now();
    let success = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status.success(),
            Ok(None)
                if started.elapsed() < Duration::from_secs(5)
                    && !overflow.load(std::sync::atomic::Ordering::Acquire) =>
            {
                std::thread::sleep(Duration::from_millis(10))
            }
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                break false;
            }
        }
    };
    let bytes = reader
        .join()
        .map_err(|_| SafeCode::Package)?
        .map_err(|_| SafeCode::Package)?;
    if !success || bytes.len() > 65536 {
        return Err(SafeCode::Package);
    }
    Ok(bytes)
}
#[cfg(not(target_os = "macos"))]
fn entitlement(_: &Path) -> Result<(), SafeCode> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn policy_manifest() -> Manifest {
        Manifest {
            schema: 3,
            policy: serde_json::from_slice(POLICY_BYTES).unwrap(),
            identity: PackageIdentity {
                engine_version: env!("CARGO_PKG_VERSION").into(),
                smolvm_revision: smolbox_engine::SMOLVM_REVISION.into(),
                source_sha256: source_sha256(),
                build_sha256: "a".repeat(64),
                assets_sha256: "b".repeat(64),
                platform: platform().into(),
                architecture: std::env::consts::ARCH.into(),
            },
            assets: vec![],
            host_tools: vec![],
        }
    }
    #[test]
    fn clean_package_policy_is_exact_and_legacy_manifests_cannot_be_relabelled() {
        let mut manifest = policy_manifest();
        assert!(policy_matches(&manifest));
        assert_eq!(
            manifest.policy["port_protocol_minor"],
            smolbox_protocol::PARITY_PROTOCOL_MINOR
        );
        assert_eq!(
            manifest.policy["port_protocol_major"],
            smolbox_protocol::PARITY_PROTOCOL_MAJOR
        );
        assert!(sdk_identity().is_ok());
        let fixture_bytes = if cfg!(target_os = "linux") {
            include_str!("../../smolbox-protocol/fixtures/hello-v2-linux-branches-preflight.json")
        } else {
            include_str!("../../smolbox-protocol/fixtures/hello-v2-macos-branches.json")
        };
        let fixture: smolbox_protocol::ServerMessage = serde_json::from_str(fixture_bytes).unwrap();
        let smolbox_protocol::ServerMessage::Hello { hello } = fixture else {
            unreachable!()
        };
        assert!(hello.validate().is_ok());
        let sdk = sdk_identity().ok().unwrap();
        // Compare the feature contract with the historical 1.22.0 descriptor.
        // The SDK pin and later features are checked separately.
        let mut fixture_features = sdk.feature_versions.clone();
        assert_eq!(fixture_features.remove("exports"), Some(1));
        assert_eq!(fixture_features.remove("branch_release_env"), Some(1));
        if cfg!(target_os = "linux") {
            assert_eq!(fixture_features.remove("branch_static_egress"), Some(1));
            assert_eq!(fixture_features.remove("branch_https_credentials"), Some(1));
        }
        assert_eq!(
            hello.sdk.as_deref().unwrap().feature_versions,
            fixture_features
        );
        assert!(hello.capabilities == sdk.capabilities());
        let mut negotiated = smolbox_protocol::Limits::for_sdk(&sdk);
        let export_limits = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/export-limits-v1.json"
        ))
        .unwrap();
        assert!(negotiated.exports.take() == Some(export_limits));
        assert!(hello.limits == negotiated);
        let buffered = smolbox_protocol::Limits::for_sdk(&sdk_identity().ok().unwrap())
            .buffered
            .unwrap();
        assert_eq!(
            manifest.policy["buffered_limits"],
            serde_json::to_value(&buffered).unwrap()
        );
        assert_eq!(
            buffered.metadata_bytes,
            smolbox_engine::COMMAND_METADATA_BYTES
        );
        let limits = smolbox_protocol::Limits::for_sdk(&sdk_identity().ok().unwrap());
        assert_eq!(
            manifest.policy.get("volume_limits"),
            limits
                .volumes
                .as_ref()
                .map(|value| serde_json::to_value(value).unwrap())
                .as_ref()
        );
        assert_eq!(
            sdk.feature_versions.get("volumes").copied(),
            if cfg!(target_os = "linux") {
                Some(1)
            } else {
                None
            }
        );
        let terminals = limits.terminals.as_ref().unwrap();
        assert_eq!(terminals.input_bytes, smolbox_engine::TERMINAL_CHUNK_BYTES);
        assert_eq!(
            terminals.total_input_bytes,
            smolbox_engine::TERMINAL_INPUT_BYTES
        );
        assert_eq!(
            terminals.output_events,
            smolbox_engine::TERMINAL_BUFFER_EVENTS as u64
        );
        let logs = limits.logs.as_ref().unwrap();
        assert_eq!(
            manifest.policy["log_limits"],
            serde_json::to_value(logs).unwrap()
        );
        assert_eq!(logs.lines, smolbox_engine::LOG_LINES);
        assert_eq!(logs.line_bytes, smolbox_engine::LOG_LINE_BYTES as u64);
        assert_eq!(
            logs.raw_line_bytes,
            smolbox_engine::LOG_RAW_LINE_BYTES as u64
        );
        assert_eq!(logs.memory_bytes, smolbox_engine::LOG_MEMORY_BYTES);
        assert_eq!(logs.output_bytes, smolbox_engine::LOG_OUTPUT_BYTES);
        assert_eq!(logs.poll_ms, smolbox_engine::LOG_POLL_MS);
        assert_eq!(
            manifest.policy["job_limits"],
            serde_json::to_value(&limits.jobs).unwrap()
        );
        let jobs = limits.jobs.unwrap();
        assert_eq!(jobs.work_slots, smolbox_engine::JOB_WORK_SLOTS as u64);
        assert_eq!(
            jobs.agent_request_bytes,
            smolbox_engine::AGENT_REQUEST_BYTES as u64
        );
        assert_eq!(
            jobs.agent_reply_overhead_bytes,
            smolbox_engine::AGENT_REPLY_OVERHEAD as u64
        );
        assert_eq!(
            jobs.observation_slots,
            smolbox_engine::JOB_CONTROL_SLOTS as u64
        );
        assert_eq!(jobs.worker_children, smolbox_engine::JOB_CHILDREN as u64);
        assert_eq!(jobs.staging_bytes, smolbox_engine::JOB_STAGING_BYTES);
        assert_eq!(jobs.descriptors, smolbox_engine::JOB_DESCRIPTORS as u64);
        assert_eq!(
            jobs.control_fd_headroom,
            smolbox_engine::JOB_CONTROL_HEADROOM as u64
        );
        assert_eq!(
            manifest.policy["creation_limits"],
            serde_json::to_value(
                smolbox_protocol::Limits::for_sdk(&sdk_identity().ok().unwrap()).creation
            )
            .unwrap()
        );
        assert_eq!(
            manifest.policy["observation_limits"],
            serde_json::to_value(
                smolbox_protocol::Limits::for_sdk(&sdk_identity().ok().unwrap()).observations
            )
            .unwrap()
        );
        assert_eq!(
            manifest.policy["native_cancel_grace_ms"],
            smolbox_protocol::CANCEL_GRACE_MS
        );
        assert_eq!(
            manifest.policy["sdk_observation_schema"],
            smolbox_engine::OBSERVATION_SCHEMA
        );
        manifest.policy["domain_ownership"] = "independent_writers_supported".into();
        assert!(!policy_matches(&manifest));
        manifest = policy_manifest();
        manifest.policy["boot_owner_guard"] = 0.into();
        assert!(!policy_matches(&manifest));
        manifest = policy_manifest();
        manifest.policy["unknown_extension"] = true.into();
        assert!(!policy_matches(&manifest));
        manifest = policy_manifest();
        manifest.schema = 1;
        assert!(!policy_matches(&manifest));
        let mut legacy = serde_json::to_value(manifest).unwrap();
        legacy.as_object_mut().unwrap().remove("policy");
        assert!(serde_json::from_value::<Manifest>(legacy).is_err());
    }
    #[test]
    fn asset_paths_cannot_escape_or_follow_parent_symlinks() {
        for path in ["", "/absolute", "../outside", "lib/../outside"] {
            assert!(safe_relative(path).is_err());
        }
        let root = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        std::os::unix::fs::symlink(outside.path(), root.path().join("lib")).unwrap();
        assert!(check_parents(root.path(), Path::new("lib/a")).is_err());
    }
    #[test]
    fn metadata_and_file_digests_are_capped_and_final_symlinks_are_rejected() {
        let root = tempfile::tempdir().unwrap();
        let file = root.path().join("file");
        std::fs::write(&file, b"private contents").unwrap();
        assert!(bounded_file(&file, 3).is_err());
        assert!(hash_file(&file, 3).is_err());
        let link = root.path().join("link");
        std::os::unix::fs::symlink(&file, &link).unwrap();
        assert!(open_file(&link).is_err());
        assert!(verify(&root.path().join("smolbox-port"), &"0".repeat(64)).is_err());
    }
    #[test]
    fn checkpoint_catalog_is_exact_bounded_and_operator_only() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("config.json");
        let base = serde_json::json!({"schema":2,"target_id":"test","generation":"ab".repeat(16),"allow_initialize":false,"package_manifest_sha256":"cd".repeat(32),"approved_artifacts":[]});
        let host = smolvm::platform::Platform::current().host_oci_platform();
        let architecture = if host == "linux/amd64" {
            "x86_64"
        } else {
            "aarch64"
        };
        let approval = serde_json::json!({
            "source":{"kind":"checkpoint","id":"idle-v1","sha256":"a".repeat(64),"architecture":architecture},
            "path":"/operator/idle.smolcheckpoint","max_bytes":smolbox_engine::CHECKPOINT_ARTIFACT_BYTES,
            "sdk_version":smolvm::VERSION,"host_platform":host,
            "resources":{"cpus":1,"memory_mib":256,"storage_gib":1,"overlay_gib":1}
        });
        std::fs::write(&path, serde_json::to_vec(&base).unwrap()).unwrap();
        assert_eq!(
            serde_json::to_value(read_config(&path).ok().unwrap()).unwrap(),
            base
        );
        let mut value = base.clone();
        value["approved_checkpoints"] = serde_json::json!([approval.clone()]);
        std::fs::write(&path, serde_json::to_vec(&value).unwrap()).unwrap();
        let config = read_config(&path).ok().unwrap();
        let engine = config.approved_checkpoints.unwrap()[0]
            .engine()
            .ok()
            .unwrap();
        assert_eq!(
            engine.artifact.path,
            Path::new("/operator/idle.smolcheckpoint")
        );
        assert_eq!(engine.resources.memory_mib, 256);
        // Catalog parsing validates approval without opening the operator's file.
        for (key, invalid) in [
            ("path", serde_json::json!("relative")),
            ("max_bytes", serde_json::json!(0)),
            (
                "max_bytes",
                serde_json::json!(smolbox_engine::CHECKPOINT_ARTIFACT_BYTES + 1),
            ),
            ("sdk_version", serde_json::json!("1.20.2")),
            ("host_platform", serde_json::json!("other/host")),
            ("credential", serde_json::json!("forbidden")),
        ] {
            let mut entry = approval.clone();
            entry[key] = invalid;
            value["approved_checkpoints"] = serde_json::json!([entry]);
            std::fs::write(&path, serde_json::to_vec(&value).unwrap()).unwrap();
            assert!(read_config(&path).is_err(), "{key}");
        }
        let mut crossed = approval.clone();
        crossed["source"]["sha256"] = serde_json::json!("b".repeat(64));
        for entries in [
            vec![],
            vec![approval.clone(); 33],
            vec![approval.clone(), crossed],
        ] {
            value["approved_checkpoints"] = serde_json::json!(entries);
            std::fs::write(&path, serde_json::to_vec(&value).unwrap()).unwrap();
            assert!(read_config(&path).is_err());
        }
        let mut request = approval["source"].clone();
        request["path"] = serde_json::json!("/caller/input");
        assert!(serde_json::from_value::<smolbox_protocol::CheckpointIdentity>(request).is_err());
    }

    #[test]
    fn registry_catalog_keeps_tokens_out_and_has_exact_coherent_bounded_policy() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("config.json");
        let base = serde_json::json!({"schema":2,"target_id":"test","generation":"ab".repeat(16),"allow_initialize":false,"package_manifest_sha256":"cd".repeat(32),"approved_artifacts":[]});
        let approval = serde_json::json!({"source":{"reference":format!("registry.example/team/app@sha256:{}","a".repeat(64)),"platform":"linux/arm64","content_sha256":"b".repeat(64)},"max_bytes":1024,"cache_policy":{"max_bytes":4096,"max_files":2}});
        let mut authenticated = approval.clone();
        authenticated["credential_ref"] = serde_json::json!("tenant-read");
        authenticated["token_realm"] = serde_json::json!("https://auth.example/exchange");
        for entry in [&approval, &authenticated] {
            let mut value = base.clone();
            value["approved_registry_sources"] = serde_json::json!([entry]);
            std::fs::write(&path, serde_json::to_vec(&value).unwrap()).unwrap();
            let config = read_config(&path).ok().unwrap();
            let selected = &config.approved_registry_sources.as_ref().unwrap()[0];
            let source = smolbox_protocol::RegistrySource {
                reference: selected.source.reference.clone(),
                platform: selected.source.platform.clone(),
                content_sha256: selected.source.content_sha256.clone(),
            };
            assert!(selected.matches(&source, selected.credential_ref.as_deref()));
            assert!(!selected.matches(&source, Some("wrong-ref")));
            let mut crossed = source;
            crossed.content_sha256 = "c".repeat(64);
            assert!(!selected.matches(&crossed, selected.credential_ref.as_deref()));
            assert_eq!(serde_json::to_value(config).unwrap(), value);
        }
        let mut combined = base.clone();
        combined["approved_registry_sources"] =
            serde_json::json!([approval.clone(), authenticated.clone()]);
        std::fs::write(&path, serde_json::to_vec(&combined).unwrap()).unwrap();
        assert!(read_config(&path).is_ok());
        let mut another = authenticated.clone();
        another["credential_ref"] = serde_json::json!("tenant-other");
        combined["approved_registry_sources"] = serde_json::json!([authenticated.clone(), another]);
        std::fs::write(&path, serde_json::to_vec(&combined).unwrap()).unwrap();
        assert!(read_config(&path).is_ok());
        for (field, invalid) in [
            ("identity_token", serde_json::json!("private")),
            ("credential_ref", serde_json::json!("missing-realm")),
            (
                "token_realm",
                serde_json::json!("https://auth.example/exchange"),
            ),
            ("max_bytes", serde_json::json!(0)),
            (
                "cache_policy",
                serde_json::json!({"max_bytes":0,"max_files":2}),
            ),
        ] {
            let mut entry = approval.clone();
            entry[field] = invalid;
            let mut value = base.clone();
            value["approved_registry_sources"] = serde_json::json!([entry]);
            std::fs::write(&path, serde_json::to_vec(&value).unwrap()).unwrap();
            assert!(read_config(&path).is_err(), "{field}");
        }
        let mut different = approval.clone();
        different["source"]["content_sha256"] = serde_json::json!("c".repeat(64));
        different["cache_policy"]["max_files"] = serde_json::json!(3);
        for entries in [
            vec![],
            vec![approval.clone(); 33],
            vec![approval.clone(); 2],
            vec![approval.clone(), different],
        ] {
            let mut value = base.clone();
            value["approved_registry_sources"] = serde_json::json!(entries);
            std::fs::write(&path, serde_json::to_vec(&value).unwrap()).unwrap();
            assert!(read_config(&path).is_err());
        }
        let mut source = approval.clone();
        source["source"]["identity_token"] = serde_json::json!("private");
        let mut value = base.clone();
        value["approved_registry_sources"] = serde_json::json!([source]);
        std::fs::write(&path, serde_json::to_vec(&value).unwrap()).unwrap();
        assert!(read_config(&path).is_err());
        let mut private = authenticated.clone();
        private["source"]["reference"] =
            serde_json::json!(format!("127.0.0.1/team/app@sha256:{}", "a".repeat(64)));
        let mut value = base.clone();
        value["approved_registry_sources"] = serde_json::json!([private]);
        std::fs::write(&path, serde_json::to_vec(&value).unwrap()).unwrap();
        assert!(read_config(&path).is_err());
        for (reference, realm) in [
            ("..", "https://auth.example/exchange"),
            ("safe", "http://auth.example/exchange"),
            ("safe", "https://127.0.0.1/exchange"),
        ] {
            let mut entry = approval.clone();
            entry["credential_ref"] = serde_json::json!(reference);
            entry["token_realm"] = serde_json::json!(realm);
            let mut value = base.clone();
            value["approved_registry_sources"] = serde_json::json!([entry]);
            std::fs::write(&path, serde_json::to_vec(&value).unwrap()).unwrap();
            assert!(read_config(&path).is_err());
        }
        let mut value = base.clone();
        value["schema"] = serde_json::json!(1);
        value["approved_registry_sources"] = serde_json::json!([approval]);
        std::fs::write(&path, serde_json::to_vec(&value).unwrap()).unwrap();
        assert!(read_config(&path).is_err());
    }

    #[test]
    fn volume_catalog_accepts_only_operator_policy_shape_and_normalized_root() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("config.json");
        let base = serde_json::json!({"schema":2,"target_id":"test","generation":"ab".repeat(16),"allow_initialize":false,"package_manifest_sha256":"cd".repeat(32),"approved_artifacts":[]});
        let mut value = base.clone();
        value["approved_volume_policy"] =
            serde_json::json!({"id":"local","root":"/srv/smolvm/volumes"});
        std::fs::write(&path, serde_json::to_vec(&value).unwrap()).unwrap();
        let config = read_config(&path).ok().unwrap();
        assert_eq!(config.approved_volume_policy.unwrap().id, "local");
        for policy in [
            serde_json::json!({"id":"local","root":"relative"}),
            serde_json::json!({"id":"local","root":"/srv/../outside"}),
            serde_json::json!({"id":"local","root":"/srv//volumes"}),
            serde_json::json!({"id":"local","root":"/srv/volumes","adopt_existing":true}),
            serde_json::json!([]),
            serde_json::Value::Null,
        ] {
            value["approved_volume_policy"] = policy;
            std::fs::write(&path, serde_json::to_vec(&value).unwrap()).unwrap();
            if value["approved_volume_policy"].is_null() {
                // Optional catalog omission/null cannot authorize a request.
                assert!(read_config(&path)
                    .ok()
                    .unwrap()
                    .approved_volume_policy
                    .is_none());
            } else {
                assert!(read_config(&path).is_err());
            }
        }
    }

    #[test]
    fn negotiated_volume_bounds_match_engine_constants_and_platform_policy() {
        let limits = smolbox_protocol::VolumeLimits::default();
        assert_eq!(limits.work_ms, smolbox_engine::VOLUME_WORK_MS);
        assert_eq!(limits.observation_ms, smolbox_engine::VOLUME_OBSERVATION_MS);
        assert_eq!(
            limits.record_bytes,
            smolbox_engine::VOLUME_RECORD_BYTES as u64
        );
        assert_eq!(
            limits.delete_entries,
            smolbox_engine::VOLUME_DELETE_ENTRIES as u64
        );
        assert_eq!(
            limits.ancestor_bytes,
            smolbox_engine::VOLUME_ANCESTOR_BYTES as u64
        );
        assert_eq!(
            limits.control_metadata_bytes,
            smolbox_engine::JOB_CONTROL_METADATA_BYTES
        );
        assert_eq!(
            limits.observation_metadata_bytes,
            smolbox_engine::VOLUME_OBSERVATION_METADATA_BYTES
        );
        assert_eq!(
            smolbox_protocol::Limits::for_sdk(&sdk_identity().ok().unwrap())
                .volumes
                .is_some(),
            cfg!(target_os = "linux")
        );
    }

    #[test]
    fn capture_resolution_has_the_exact_independent_material_control_allowance() {
        assert_eq!(
            smolbox_protocol::CAPTURE_RESOLUTION_METADATA_BYTES,
            smolbox_engine::JOB_MATERIAL_CONTROL_METADATA_BYTES
        );
        assert_eq!(
            smolbox_protocol::CAPTURE_RESOLUTION_METADATA_BYTES,
            32 * 1024 * 1024
        );
    }

    #[test]
    fn oci_catalog_is_optional_exact_bounded_and_cannot_add_auth_or_tag_intent() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("config.json");
        let base = serde_json::json!({"schema":2,"target_id":"test","generation":"ab".repeat(16),"allow_initialize":false,
            "package_manifest_sha256":"cd".repeat(32),"approved_artifacts":[]});
        let source = serde_json::json!({"reference":format!("registry.example/app@sha256:{}","a".repeat(64)),"platform":"linux/arm64"});
        for catalog in [
            None,
            Some(serde_json::json!([])),
            Some(serde_json::json!([source.clone()])),
        ] {
            let mut value = base.clone();
            if let Some(catalog) = catalog {
                value["approved_oci_sources"] = catalog;
            }
            std::fs::write(&path, serde_json::to_vec(&value).unwrap()).unwrap();
            let config = read_config(&path).ok().unwrap();
            if config.approved_oci_sources.is_none() {
                assert_eq!(serde_json::to_value(config).unwrap(), base);
            }
        }
        let mut auth = source.clone();
        auth["auth"] = serde_json::json!("PRIVATE=discard");
        let mut tag = source.clone();
        tag["reference"] = serde_json::json!("registry.example/app:tag");
        let mut bad_host = source.clone();
        bad_host["reference"] = serde_json::json!(format!("reg/app@sha256:{}", "a".repeat(64)));
        for entries in [
            vec![source.clone(); 33],
            vec![source.clone(); 2],
            vec![auth],
            vec![tag],
            vec![bad_host],
        ] {
            let mut value = base.clone();
            value["approved_oci_sources"] = serde_json::json!(entries);
            std::fs::write(&path, serde_json::to_vec(&value).unwrap()).unwrap();
            assert!(read_config(&path).is_err());
        }
    }

    #[test]
    fn unknown_config_fields_and_invalid_bindings_fail_without_engine_open() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("config.json");
        let mut config = serde_json::json!({"schema":2,"target_id":"test","generation":"ab".repeat(16),"allow_initialize":false,
            "package_manifest_sha256":"cd".repeat(32),"approved_artifacts":[]});
        std::fs::write(&path, serde_json::to_vec(&config).unwrap()).unwrap();
        assert!(read_config(&path).is_ok());
        for address in ["127.0.0.1", "0.0.0.0", "192.0.2.1"] {
            config["publish_address"] = address.into();
            std::fs::write(&path, serde_json::to_vec(&config).unwrap()).unwrap();
            assert!(read_config(&path).is_ok());
        }
        for address in ["localhost", "::1", "127.000.0.1", "127.0.0.1:8080"] {
            config["publish_address"] = address.into();
            std::fs::write(&path, serde_json::to_vec(&config).unwrap()).unwrap();
            assert!(read_config(&path).is_err());
        }
        config.as_object_mut().unwrap().remove("publish_address");
        config["schema"] = 1.into();
        std::fs::write(&path, serde_json::to_vec(&config).unwrap()).unwrap();
        assert!(read_config(&path).is_err());
        config["schema"] = 2.into();
        config["db_path"] = serde_json::json!("/arbitrary/db");
        std::fs::write(&path, serde_json::to_vec(&config).unwrap()).unwrap();
        assert!(read_config(&path).is_err());
        config.as_object_mut().unwrap().remove("db_path");
        config["generation"] = serde_json::json!("short");
        std::fs::write(&path, serde_json::to_vec(&config).unwrap()).unwrap();
        assert!(read_config(&path).is_err());
    }
    #[test]
    fn export_assets_select_only_manifest_approved_regular_files_and_preserve_legacy_omission() {
        let root = Path::new("/operator/package");
        assert!(approved_export_assets(root, &[]).ok().unwrap().is_none());
        let names = if cfg!(target_os = "macos") {
            [
                "agent-rootfs.tar",
                "lib/libkrun.dylib",
                "lib/libkrunfw.5.dylib",
            ]
        } else {
            ["agent-rootfs.tar", "lib/libkrun.so", "lib/libkrunfw.so.5"]
        };
        let entries = || {
            names
                .iter()
                .map(|name| Asset::File {
                    path: (*name).into(),
                    sha256: "a".repeat(64),
                    bytes: 1024,
                    mode: 0o400,
                })
                .collect::<Vec<_>>()
        };
        let approved = approved_export_assets(root, &entries())
            .ok()
            .unwrap()
            .unwrap();
        assert_eq!(approved.files.len(), 3);
        for (file, name) in approved.files.iter().zip(names) {
            assert_eq!(file.path, root.join(name));
            assert_eq!(file.name, name);
            assert_eq!(file.sha256, "a".repeat(64));
            assert_eq!(file.max_bytes, 1024);
        }
        for change in 0..7 {
            let mut invalid = entries();
            match change {
                0 => {
                    invalid.pop();
                }
                1 => {
                    invalid[0] = Asset::Symlink {
                        path: "agent-rootfs.tar".into(),
                        target: "elsewhere".into(),
                    }
                }
                2 => {
                    if let Asset::File { bytes, .. } = &mut invalid[0] {
                        *bytes = 0;
                    }
                }
                3 => {
                    if let Asset::File { bytes, .. } = &mut invalid[0] {
                        *bytes = 2 * 1024 * 1024 * 1024 + 1;
                    }
                }
                4 => {
                    if let Asset::File { sha256, .. } = &mut invalid[0] {
                        *sha256 = "bad".into();
                    }
                }
                5 => {
                    if let Asset::File { mode, .. } = &mut invalid[0] {
                        *mode = 0o666;
                    }
                }
                _ => invalid.push(Asset::File {
                    path: "agent-rootfs.tar".into(),
                    sha256: "a".repeat(64),
                    bytes: 1024,
                    mode: 0o400,
                }),
            }
            assert!(approved_export_assets(root, &invalid).is_err());
        }
    }
    #[test]
    #[ignore = "ordinary operator-approved local package fixture; no engine or VM"]
    fn ordinary_manifest_rootfs_archive_matches_approved_guest_files() {
        let package = std::fs::canonicalize(
            std::env::var_os("SMOLBOX_EXPORT_PACKAGE").expect("explicit package fixture"),
        )
        .unwrap();
        let digest =
            std::env::var("SMOLBOX_EXPORT_PACKAGE_SHA256").expect("explicit package approval");
        let verified = verify(&package.join("smolbox-port"), &digest)
            .ok()
            .expect("package preflight");
        let selected = verified.export_assets.expect("declared export assets");
        assert_eq!(selected.files.len(), 3);
        let manifest: Manifest =
            serde_json::from_slice(&std::fs::read(package.join("package.json")).unwrap()).unwrap();
        let expected: std::collections::BTreeMap<_, _> = manifest
            .assets
            .iter()
            .filter_map(|asset| {
                asset
                    .path()
                    .strip_prefix("agent-rootfs/")
                    .map(|name| (name.to_owned(), asset))
            })
            .collect();
        let tar = selected
            .files
            .iter()
            .find(|file| file.name == "agent-rootfs.tar")
            .unwrap();
        let mut archive = tar::Archive::new(File::open(&tar.path).unwrap());
        let mut seen = BTreeSet::new();
        for (index, entry) in archive.entries().unwrap().enumerate() {
            assert!(index < 32768);
            let mut entry = entry.unwrap();
            let path = entry.path().unwrap().into_owned();
            let name = path.to_str().unwrap();
            assert!(path
                .components()
                .all(|part| matches!(part, Component::Normal(_))));
            assert!(!name
                .split('/')
                .any(|part| part.starts_with(".smolvm-ready.")));
            assert_eq!(entry.header().uid().unwrap(), 0);
            assert_eq!(entry.header().gid().unwrap(), 0);
            assert_eq!(entry.header().mtime().unwrap(), 0);
            assert!(seen.insert(name.to_owned()));
            match entry.header().entry_type() {
                kind if kind.is_file() => {
                    let Asset::File {
                        sha256,
                        bytes,
                        mode,
                        ..
                    } = expected.get(name).expect("declared guest file")
                    else {
                        panic!("guest file kind");
                    };
                    assert_eq!(entry.size(), *bytes);
                    assert_eq!(entry.header().mode().unwrap() & 0o777, *mode);
                    let mut hash = Sha256::new();
                    let mut buffer = [0; 64 * 1024];
                    loop {
                        let count = entry.read(&mut buffer).unwrap();
                        if count == 0 {
                            break;
                        }
                        hash.update(&buffer[..count]);
                    }
                    assert_eq!(&hex::encode(hash.finalize()), sha256);
                }
                kind if kind.is_symlink() => {
                    let Asset::Symlink { target, .. } =
                        expected.get(name).expect("declared guest link")
                    else {
                        panic!("guest link kind");
                    };
                    assert_eq!(entry.link_name().unwrap().unwrap(), Path::new(target));
                }
                kind if kind.is_dir() => {
                    assert!(package.join("agent-rootfs").join(&path).is_dir());
                }
                _ => panic!("unsupported guest archive kind"),
            }
        }
        assert!(expected.keys().all(|name| seen.contains(name)));
        assert!(seen.contains("usr/local/bin/smolvm-agent"));
    }
    #[test]
    fn export_catalog_resolves_operator_trust_once_and_bounds_match_executing_engine() {
        let proof: Vec<smolbox_protocol::ExportPublication> = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/export-publications-v1.json"
        ))
        .unwrap();
        let identity = &proof[0].identity;
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("config.json");
        let base = serde_json::json!({"schema":2,"target_id":"test","generation":"ab".repeat(16),"allow_initialize":false,"package_manifest_sha256":"cd".repeat(32),"approved_artifacts":[]});
        let approval = serde_json::json!({"id":identity.destination_id,"registry":identity.registry,"repository":identity.repository,"credential_ref":"publisher","immutable_tags":true,"allow_insecure_loopback":false,"ca_cert_file":null,"ca_certificate_sha256":null,"destination_sha256":identity.destination_sha256,"max_artifact_bytes":1048576,"max_staging_bytes":4194304});
        let mut value = base;
        value["approved_export_destinations"] = serde_json::json!([approval.clone()]);
        std::fs::write(&path, serde_json::to_vec(&value).unwrap()).unwrap();
        let config = read_config(&path).ok().unwrap();
        let selected = &config.approved_export_destinations.as_ref().unwrap()[0];
        assert!(selected.resolved.is_some());
        assert_eq!(
            selected.resolved.as_ref().unwrap().digest().unwrap(),
            identity.destination_sha256
        );
        assert!(!serde_json::to_string(selected)
            .unwrap()
            .contains("resolved"));
        for field in [
            "credential_ref",
            "destination_sha256",
            "max_staging_bytes",
            "immutable_tags",
        ] {
            let mut invalid = value.clone();
            invalid["approved_export_destinations"][0][field] = match field {
                "max_staging_bytes" => serde_json::json!(0),
                "immutable_tags" => serde_json::json!(false),
                _ => serde_json::json!("../invalid"),
            };
            std::fs::write(&path, serde_json::to_vec(&invalid).unwrap()).unwrap();
            assert!(read_config(&path).is_err());
        }
        value["approved_export_destinations"] = serde_json::json!([approval.clone(), approval]);
        std::fs::write(&path, serde_json::to_vec(&value).unwrap()).unwrap();
        assert!(read_config(&path).is_err());
        let fifo = root.path().join("trust-fifo");
        let name = std::ffi::CString::new(fifo.to_str().unwrap()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
        let mut invalid = value.clone();
        invalid["approved_export_destinations"] = serde_json::json!([{
            "id":identity.destination_id,"registry":identity.registry,"repository":identity.repository,"credential_ref":"publisher","immutable_tags":true,"allow_insecure_loopback":false,"ca_cert_file":fifo,"ca_certificate_sha256":"a".repeat(64),"destination_sha256":identity.destination_sha256,"max_artifact_bytes":1048576,"max_staging_bytes":4194304}]);
        std::fs::write(&path, serde_json::to_vec(&invalid).unwrap()).unwrap();
        assert!(read_config(&path).is_err());
        let limits = smolbox_protocol::ExportLimits::default();
        assert_eq!(
            limits.staging_bytes,
            smolbox_engine::JOB_EXPORT_STAGING_BYTES
        );
        assert_eq!(limits.metadata_bytes, smolbox_engine::EXPORT_METADATA_BYTES);
        assert_eq!(
            limits.upload_chunk_bytes,
            smolbox_engine::EXPORT_UPLOAD_CHUNK_BYTES
        );
        assert_eq!(
            limits.registry_requests,
            smolbox_engine::EXPORT_REGISTRY_REQUESTS
        );
        assert_eq!(limits.record_bytes, smolbox_engine::EXPORT_RECORD_BYTES);
        assert_eq!(limits.records, smolbox_engine::EXPORT_RECORDS as u64);
        assert_eq!(
            limits.retirement_metadata_bytes,
            smolbox_engine::JOB_MATERIAL_CONTROL_METADATA_BYTES
        );
        assert_eq!(
            limits.asset_file_bytes,
            smolbox_engine::EXPORT_ASSET_FILE_BYTES
        );
        assert_eq!(
            limits.asset_total_bytes,
            smolbox_engine::EXPORT_ASSET_TOTAL_BYTES
        );
        assert_eq!(
            limits.control_metadata_bytes,
            smolbox_engine::JOB_CONTROL_METADATA_BYTES
        );
        assert_eq!(
            limits.observation_metadata_bytes,
            smolbox_engine::VOLUME_OBSERVATION_METADATA_BYTES
        );
    }
}

#[cfg(test)]
mod branch_catalog_tests {
    use super::*;
    use std::fs;
    #[test]
    fn branch_catalog_is_bounded_unique_major_two_and_preserves_absent_legacy_shape() {
        let rows: Vec<serde_json::Value> = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/branch-creation-v1.json"
        ))
        .unwrap();
        let approval: smolbox_protocol::BranchApproval =
            serde_json::from_value(rows[0]["request"]["approval"].clone()).unwrap();
        assert!(validate_branch_catalog(1, None).is_ok());
        assert!(validate_branch_catalog(1, Some(std::slice::from_ref(&approval))).is_err());
        assert!(validate_branch_catalog(2, Some(&[])).is_err());
        assert!(validate_branch_catalog(2, Some(std::slice::from_ref(&approval))).is_ok());
        let mut duplicate = approval.clone();
        duplicate.resources.disk_gb += 1;
        assert!(validate_branch_catalog(2, Some(&[approval.clone(), duplicate])).is_err());
        assert!(validate_branch_catalog(2, Some(&[approval.clone(), approval.clone()])).is_err());
        let mut variant = approval.clone();
        variant.host_overhead_mb += 1;
        assert!(validate_branch_catalog(2, Some(&[approval.clone(), variant])).is_ok());
        let policies: Vec<_> = (0..33)
            .map(|index| {
                let mut value = approval.clone();
                value.id = format!("policy-{index}");
                value
            })
            .collect();
        assert!(validate_branch_catalog(2, Some(&policies)).is_err());
        let overheads: Vec<_> = (0..33)
            .map(|index| {
                let mut value = approval.clone();
                value.host_overhead_mb += index;
                value
            })
            .collect();
        assert!(validate_branch_catalog(2, Some(&overheads)).is_err());
        let complete: Vec<_> = (0..32)
            .flat_map(|policy| {
                let approval = &approval;
                (0..32).map(move |overhead| {
                    let mut value = approval.clone();
                    value.id = format!("policy-{policy}");
                    value.host_overhead_mb += overhead;
                    value
                })
            })
            .collect();
        assert!(validate_branch_catalog(2, Some(&complete)).is_ok());
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("config.json");
        let mut config = serde_json::json!({
            "schema": 2,
            "target_id": "branches",
            "generation": "a".repeat(32),
            "allow_initialize": false,
            "package_manifest_sha256": "b".repeat(64),
            "approved_artifacts": [],
            "approved_branches": complete
        });
        let bytes = serde_json::to_vec(&config).unwrap();
        assert!(bytes.len() > 65536);
        assert!(bytes.len() < 512 * 1024);
        fs::write(&path, bytes).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        assert!(read_config(&path).is_ok());
        config.as_object_mut().unwrap().remove("approved_branches");
        let mut bytes = serde_json::to_vec(&config).unwrap();
        bytes.resize(65537, b' ');
        fs::write(&path, &bytes).unwrap();
        assert!(read_config(&path).is_err());
        bytes.resize(512 * 1024 + 1, b' ');
        fs::write(&path, bytes).unwrap();
        assert!(read_config(&path).is_err());
        assert!(validate_branch_catalog(2, Some(&vec![approval.clone(); 1025])).is_err());
        let mut invalid = approval;
        invalid.host_overhead_mb = 0;
        assert!(validate_branch_catalog(2, Some(&[invalid])).is_err());
    }
}
