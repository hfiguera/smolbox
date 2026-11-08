use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use smolbox_engine::{
    ApprovedTemplate, ApprovedTemplates, Cancellation, DomainBinding, Engine, Executable,
    ExecutableLocator, HostContext, ReadBudget, TemplateFile,
};
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::{Component, Path, PathBuf};
use std::time::Duration;

pub type ProofResult<T> = Result<T, Box<dyn std::error::Error>>;

pub struct PackageSettings {
    pub package: PathBuf,
    pub manifest_sha256: String,
    pub domain_json: PathBuf,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Domain {
    target_id: String,
    generation: String,
}

pub fn budget() -> ProofResult<ReadBudget> {
    Ok(ReadBudget::new(
        Duration::from_secs(30),
        Cancellation::new(),
    )?)
}

pub fn random(bytes: usize) -> ProofResult<String> {
    let mut entropy = vec![0; bytes];
    getrandom::fill(&mut entropy).map_err(|_| "entropy unavailable")?;
    Ok(hex::encode(entropy))
}

pub fn output(path: &Path, fresh: bool) -> ProofResult<()> {
    if !path.is_absolute()
        || path.as_os_str().len() > 88
        || path
            .components()
            .any(|p| matches!(p, Component::ParentDir | Component::CurDir))
    {
        return Err(
            "absolute normalized output path <=88 bytes required for control socket".into(),
        );
    }
    if fresh {
        std::fs::DirBuilder::new().mode(0o700).create(path)?;
    }
    let metadata = std::fs::symlink_metadata(path)?;
    if !metadata.is_dir()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.mode() & 0o077 != 0
    {
        return Err("private original output directory required".into());
    }
    for ancestor in path.ancestors() {
        if std::fs::symlink_metadata(ancestor)?
            .file_type()
            .is_symlink()
        {
            return Err("redirected output path".into());
        }
    }
    Ok(())
}

pub fn save<T: Serialize>(path: &Path, value: &T) -> ProofResult<()> {
    let parent = path.parent().ok_or("missing evidence parent")?;
    let bytes = serde_json::to_vec_pretty(value)?;
    if bytes.len() > 64 * 1024 {
        return Err("evidence exceeds bound".into());
    }
    let mut staged = tempfile::NamedTempFile::new_in(parent)?;
    staged.write_all(&bytes)?;
    staged.as_file().sync_all()?;
    staged.persist_noclobber(path)?;
    File::open(parent)?.sync_all()?;
    Ok(())
}

pub fn read_private<T: serde::de::DeserializeOwned>(path: &Path) -> ProofResult<T> {
    let metadata = std::fs::symlink_metadata(path)?;
    if !path.is_absolute()
        || !metadata.is_file()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.mode() & 0o077 != 0
        || metadata.len() > 64 * 1024
    {
        return Err("bounded private original metadata required".into());
    }
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(path)?;
    let mut bytes = vec![];
    (&mut file).take(64 * 1024 + 1).read_to_end(&mut bytes)?;
    if bytes.len() > 64 * 1024 {
        return Err("metadata grew beyond bound".into());
    }
    Ok(serde_json::from_slice(&bytes)?)
}

fn hash(path: &Path, max: u64) -> ProofResult<String> {
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(path)?;
    if !file.metadata()?.is_file() || file.metadata()?.len() > max {
        return Err("package input exceeds bound".into());
    }
    let mut hash = Sha256::new();
    let mut bytes = [0; 65536];
    let mut total = 0;
    loop {
        let n = file.read(&mut bytes)?;
        if n == 0 {
            break;
        }
        total += n as u64;
        if total > max {
            return Err("package input grew beyond bound".into());
        }
        hash.update(&bytes[..n]);
    }
    Ok(hex::encode(hash.finalize()))
}

pub fn open_package(settings: &PackageSettings) -> ProofResult<Engine> {
    for path in [&settings.package, &settings.domain_json] {
        if !path.is_absolute() || path.canonicalize()? != *path {
            return Err("explicit canonical inputs required".into());
        }
    }
    if hash(&settings.package.join("package.json"), 4 * 1024 * 1024)? != settings.manifest_sha256 {
        return Err("approved manifest digest differs".into());
    }
    let manifest: Value =
        serde_json::from_slice(&std::fs::read(settings.package.join("package.json"))?)?;
    if manifest["schema"] != 3
        || manifest["identity"]["platform"] != "linux"
        || manifest["identity"]["architecture"] != "x86_64"
        || manifest["identity"]["smolvm_revision"] != smolbox_engine::SMOLVM_REVISION
    {
        return Err("package tuple differs from this Linux witness".into());
    }
    let assets = manifest["assets"]
        .as_array()
        .ok_or("missing asset inventory")?;
    if assets.is_empty() || assets.len() > 16384 {
        return Err("asset inventory exceeds bound".into());
    }
    let mut total = 0_u64;
    let mut names = std::collections::BTreeSet::new();
    for asset in assets {
        let relative = Path::new(asset["path"].as_str().ok_or("invalid asset path")?);
        if relative.as_os_str().is_empty()
            || relative.is_absolute()
            || relative
                .components()
                .any(|p| !matches!(p, Component::Normal(_)))
            || !names.insert(relative)
        {
            return Err("invalid or duplicate asset path".into());
        }
        let path = settings.package.join(relative);
        for ancestor in path
            .parent()
            .ok_or("missing asset parent")?
            .ancestors()
            .take_while(|p| p.starts_with(&settings.package))
        {
            if !std::fs::symlink_metadata(ancestor)?.is_dir() {
                return Err("redirected asset parent".into());
            }
        }
        let metadata = std::fs::symlink_metadata(&path)?;
        match asset["kind"].as_str() {
            Some("file") => {
                let bytes = asset["bytes"].as_u64().ok_or("invalid asset length")?;
                total = total.checked_add(bytes).ok_or("asset length overflow")?;
                if total > 8 * 1024 * 1024 * 1024
                    || !metadata.is_file()
                    || metadata.len() != bytes
                    || metadata.mode() & 0o777
                        != asset["mode"].as_u64().ok_or("missing asset mode")? as u32
                    || hash(&path, bytes)?
                        != asset["sha256"].as_str().ok_or("missing asset hash")?
                {
                    return Err("package asset differs".into());
                }
            }
            Some("symlink")
                if metadata.file_type().is_symlink()
                    && std::fs::read_link(&path)?.to_str() == asset["target"].as_str() => {}
            _ => return Err("package asset kind differs".into()),
        }
    }
    let helper = Executable {
        path: settings.package.join("smolbox-port"),
        sha256: manifest["identity"]["build_sha256"]
            .as_str()
            .ok_or("missing helper digest")?
            .into(),
    };
    if hash(&helper.path, 256 * 1024 * 1024)? != helper.sha256 {
        return Err("approved helper differs".into());
    }
    let domain: Domain = read_private(&settings.domain_json)?;
    let binding = DomainBinding::default_paths(domain.target_id, domain.generation)?;
    std::env::set_var("SMOLVM_IMAGE_SEEDS", "0");
    std::env::set_var("SMOLVM_BOOT_BINARY", &helper.path);
    std::env::set_var("SMOLVM_LIB_DIR", settings.package.join("lib"));
    std::env::set_var("SMOLVM_AGENT_ROOTFS", settings.package.join("agent-rootfs"));
    let host = HostContext::capture(
        binding.clone(),
        random(16)?,
        settings.manifest_sha256.clone(),
        ExecutableLocator {
            boot: helper.clone(),
            file_worker: helper,
            library_directory: settings.package.join("lib"),
        },
    )?;
    let mut engine = Engine::open_with_host(binding, false, host)?;
    std::env::set_var("SMOLVM_BOOT_BINARY", engine.prepare_boot_launcher()?);
    let file = |name: &str| -> ProofResult<TemplateFile> {
        let entry = assets
            .iter()
            .find(|e| e["kind"] == "file" && e["path"] == name)
            .ok_or("missing approved template")?;
        Ok(TemplateFile {
            path: settings.package.join(name),
            sha256: entry["sha256"]
                .as_str()
                .ok_or("invalid template hash")?
                .into(),
            bytes: entry["bytes"].as_u64().ok_or("invalid template bytes")?,
        })
    };
    engine.prepare_templates(
        ApprovedTemplates {
            storage: ApprovedTemplate {
                plain: file("storage-template.ext4")?,
                compressed: file("storage-template.ext4.zst")?,
            },
            overlay: ApprovedTemplate {
                plain: file("overlay-template.ext4")?,
                compressed: file("overlay-template.ext4.zst")?,
            },
        },
        &settings.manifest_sha256,
    )?;
    Ok(engine)
}

/// A failed ordinary witness keeps its original engine in the caller's closure.
/// Socket errors and unsuccessful controls cannot retire that owner.
pub fn retain_owner(
    listener: &std::os::unix::net::UnixListener,
    mut control: impl FnMut(&mut std::os::unix::net::UnixStream) -> ProofResult<bool>,
) {
    loop {
        let mut stream = match listener.accept() {
            Ok((stream, _)) => stream,
            Err(_) => continue,
        };
        if matches!(control(&mut stream), Ok(true)) {
            return;
        }
    }
}
