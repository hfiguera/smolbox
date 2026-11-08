use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use smolbox_protocol::{Artifact, PackageIdentity, SafeCode};
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
}
pub fn source_sha256() -> String {
    hash_bytes(include_bytes!("../../vendor/source.json"))
}
fn policy_matches(manifest: &Manifest) -> bool {
    manifest.schema == 2
        && serde_json::from_slice::<serde_json::Value>(include_bytes!("../../policy.json"))
            .is_ok_and(|expected| manifest.policy == expected)
}
pub fn hash_bytes(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}
pub fn read_config(path: &Path) -> Result<Config, SafeCode> {
    let config: Config =
        serde_json::from_slice(&bounded_file(path, 65536)?).map_err(|_| SafeCode::Validation)?;
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
    };
    receipt.validate().map_err(|_| SafeCode::Validation)?;
    if config.schema != 1
        || !valid_hash(&config.package_manifest_sha256)
        || config.approved_artifacts.len() > 64
    {
        return Err(SafeCode::Validation);
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
    if bounded_file(&root.join("SMOLBOX-POLICY.json"), 8192)? != include_bytes!("../../policy.json")
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
        root,
        identity: manifest.identity,
    })
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
                if !declared.contains(relative) && !(marker && meta.is_file() && meta.len() <= 4096)
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
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
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
            schema: 2,
            policy: serde_json::from_slice(include_bytes!("../../policy.json")).unwrap(),
            identity: PackageIdentity {
                engine_version: "0.1.0".into(),
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
            smolbox_protocol::PROTOCOL_MINOR
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
    fn unknown_config_fields_and_invalid_bindings_fail_without_engine_open() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("config.json");
        let mut config = serde_json::json!({"schema":1,"target_id":"test","generation":"ab".repeat(16),"allow_initialize":false,
            "package_manifest_sha256":"cd".repeat(32),"approved_artifacts":[]});
        std::fs::write(&path, serde_json::to_vec(&config).unwrap()).unwrap();
        assert!(read_config(&path).is_ok());
        config["db_path"] = serde_json::json!("/arbitrary/db");
        std::fs::write(&path, serde_json::to_vec(&config).unwrap()).unwrap();
        assert!(read_config(&path).is_err());
        config.as_object_mut().unwrap().remove("db_path");
        config["generation"] = serde_json::json!("short");
        std::fs::write(&path, serde_json::to_vec(&config).unwrap()).unwrap();
        assert!(read_config(&path).is_err());
    }
}
