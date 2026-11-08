//! Volume-specific inputs atop shared ordinary package/default-domain setup.
#[path = "../proof_support/mod.rs"]
mod proof_support;
pub use proof_support::{budget, output, random, read_private, retain_owner, save, ProofResult};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Settings {
    pub package: PathBuf,
    pub manifest_sha256: String,
    pub artifact: PathBuf,
    pub artifact_sha256: String,
    pub domain_json: PathBuf,
}

pub fn open(settings: &Settings) -> ProofResult<smolbox_engine::Engine> {
    if !settings.artifact.is_absolute() || settings.artifact.canonicalize()? != settings.artifact {
        return Err("explicit canonical artifact required".into());
    }
    proof_support::open_package(&proof_support::PackageSettings {
        package: settings.package.clone(),
        manifest_sha256: settings.manifest_sha256.clone(),
        domain_json: settings.domain_json.clone(),
    })
}
