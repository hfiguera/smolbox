//! Explicit ordinary Linux OCI witness. Default tests run only pure models.
//! SDK/guest errors retain the original owner for normal API cleanup; there are
//! no process signals, fault modes, lifecycle replays or adoption by saved name.
#[path = "proof_support/mod.rs"]
mod support;

use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest, Sha256};
use smolbox_engine::{
    Cancellation, Command, CreateOciRequest, CreationFeatures, CreationPresence, CreationReceipt,
    Engine, ImagePullRequest, NetworkPolicy, ObservedState, RegistryArtifactSource,
    RegistryCachePolicy, RegistryCreationIntent, Resources, StartupWorkload, Stream,
};
use std::collections::BTreeMap;
use std::io::{Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};
use support::{budget, read_private, retain_owner, save, PackageSettings, ProofResult};

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Settings {
    package: PathBuf,
    manifest_sha256: String,
    domain_json: PathBuf,
    source: ImagePullRequest,
    pull_source: ImagePullRequest,
    network: NetworkPolicy,
    startup_workload: Option<StartupWorkload>,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct RegistrySettings {
    package: PathBuf,
    manifest_sha256: String,
    domain_json: PathBuf,
    source: RegistryArtifactSource,
    max_bytes: u64,
    cache_policy: RegistryCachePolicy,
}
impl RegistrySettings {
    fn validate(&self) -> ProofResult<()> {
        self.source.validate()?;
        self.cache_policy.validate()?;
        if self.source.platform != "linux/amd64"
            || self.max_bytes == 0
            || self.max_bytes > 32 * 1024 * 1024 * 1024
            || self.max_bytes > self.cache_policy.max_bytes
        {
            return Err(
                "native registry source and explicit artifact/cache bounds required".into(),
            );
        }
        Ok(())
    }
}

enum Input {
    Oci(Box<(Settings, CreationFeatures)>),
    Registry(Box<RegistrySettings>),
}
impl Input {
    fn package(&self) -> PackageSettings {
        let (package, manifest_sha256, domain_json) = match self {
            Self::Oci(input) => (
                &input.0.package,
                &input.0.manifest_sha256,
                &input.0.domain_json,
            ),
            Self::Registry(input) => (&input.package, &input.manifest_sha256, &input.domain_json),
        };
        PackageSettings {
            package: package.clone(),
            manifest_sha256: manifest_sha256.clone(),
            domain_json: domain_json.clone(),
        }
    }
    fn exercise(self, session: &mut Session) -> ProofResult<serde_json::Value> {
        match self {
            Self::Oci(input) => session.exercise(&input.0, input.1.clone()),
            Self::Registry(input) => session.exercise_registry(&input),
        }
    }
}

const STARTUP_LINE: &str = "configured-v1:/tmp:0\n";
const STARTUP_SCRIPT: &str = "set -eu; test \"$SMOLBOX_STARTUP_WITNESS\" = configured-v1; test \"$PWD\" = /tmp; test \"$(id -u)\" = 0; mkdir -p /workspace; printf 'configured-v1:/tmp:0\\n' >> /workspace/ordinary-oci-startups";

fn startup_fixture() -> StartupWorkload {
    StartupWorkload {
        entrypoint: vec!["/bin/sh".into(), "-c".into()],
        cmd: vec![STARTUP_SCRIPT.into()],
        env: BTreeMap::from([("SMOLBOX_STARTUP_WITNESS".into(), "configured-v1".into())]),
        workdir: Some("/tmp".into()),
    }
}

impl Settings {
    fn features(&self) -> ProofResult<CreationFeatures> {
        self.source.validate()?;
        self.pull_source.validate()?;
        let native = if cfg!(target_arch = "aarch64") {
            "linux/arm64"
        } else {
            "linux/amd64"
        };
        if self.source.platform != native
            || self.pull_source.platform != native
            || self.source == self.pull_source
            || !self.network.enabled
        {
            return Err(
                "distinct native-platform sources and explicit guest network required".into(),
            );
        }
        if self
            .startup_workload
            .as_ref()
            .is_some_and(|workload| *workload != startup_fixture())
        {
            return Err("only the fixed ordinary startup fixture can be qualified".into());
        }
        let features = CreationFeatures {
            branch_https: false,
            network: self.network.clone(),
            ports: vec![],
            workload: self.startup_workload.clone(),
        };
        features.validate()?;
        Ok(features)
    }
}

struct Session {
    engine: Engine,
    output: PathBuf,
    receipt: Option<CreationReceipt>,
    create_entered: bool,
    start_entered: bool,
    deleted: bool,
    closed: bool,
}

fn main() {
    if let Err(error) = run() {
        eprintln!("ordinary source proof failed: {error}");
        std::process::exit(1);
    }
}
fn run() -> ProofResult<()> {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    if args == ["startup-fixture"] {
        println!("{}", serde_json::to_string(&startup_fixture())?);
        return Ok(());
    }
    if args.len() == 3 && args[0] == "control" {
        return control(Path::new(&args[1]), &args[2]);
    }
    if !cfg!(all(target_os = "linux", target_arch = "x86_64"))
        || args.len() != 3
        || !matches!(args[0].as_str(), "run" | "run-registry")
    {
        return Err(
            "Linux x86_64 only: oci-guest-proof run|run-registry SETTINGS_JSON OUTPUT | control OUTPUT ACTION"
                .into(),
        );
    }
    let input = if args[0] == "run" {
        let settings: Settings = read_private(Path::new(&args[1]))?;
        let features = settings.features()?;
        Input::Oci(Box::new((settings, features)))
    } else {
        let settings: RegistrySettings = read_private(Path::new(&args[1]))?;
        settings.validate()?;
        Input::Registry(Box::new(settings))
    };
    let output = PathBuf::from(&args[2]);
    support::output(&output, true)?;
    let socket = output.join("control.sock");
    let listener = UnixListener::bind(&socket)?;
    std::fs::set_permissions(&socket, std::fs::Permissions::from_mode(0o600))?;
    let engine = support::open_package(&input.package())?;
    let mut session = Session {
        engine,
        output: output.clone(),
        receipt: None,
        create_entered: false,
        start_entered: false,
        deleted: false,
        closed: false,
    };
    let result = input.exercise(&mut session).and_then(|mut report| {
        session.close_cleaned()?;
        report["normal_owner_shutdown"] = json!(true);
        save(&output.join("evidence.json"), &report)
    });
    if let Err(error) = &result {
        // Diagnostic persistence itself must never unwind an entered owner.
        let _ = save(
            &output.join("failure.json"),
            &json!({"error":error.to_string(),"owner_retained":true,"forced_termination":false}),
        );
        eprintln!("ordinary source failed; original engine retained for explicit normal cleanup");
        retain_owner(&listener, |stream| handle_control(&mut session, stream));
    }
    drop(listener);
    std::fs::remove_file(socket)?;
    result
}

impl Session {
    fn original(&self) -> ProofResult<&CreationReceipt> {
        self.receipt
            .as_ref()
            .ok_or("no returned original receipt; no adoption".into())
    }
    fn stage(&self, name: &str, value: serde_json::Value) -> ProofResult<()> {
        save(&self.output.join(format!("{name}.json")), &value)
    }
    fn start(&mut self, source: &ImagePullRequest) -> ProofResult<()> {
        self.start_entered = true;
        let observed = self.engine.start_oci_source_owned(
            self.original()?,
            source,
            Instant::now() + Duration::from_secs(600),
            Cancellation::new(),
        )?;
        if observed.state != ObservedState::Running {
            return Err("original OCI start did not observe Running".into());
        }
        Ok(())
    }
    fn command(&self, script: &str) -> ProofResult<()> {
        self.command_expect(script, b"smolbox-ordinary-oci-v1\n")
    }
    fn command_expect(&self, script: &str, expected: &[u8]) -> ProofResult<()> {
        self.command_as(script, expected, Some("0"))
    }
    fn command_as(&self, script: &str, expected: &[u8], user: Option<&str>) -> ProofResult<()> {
        let mut stdout = vec![];
        let mut stderr = vec![];
        let outcome = self.engine.exec(
            self.original()?,
            Command {
                argv: vec!["/bin/sh".into(), "-c".into(), script.into()],
                env: vec![],
                workdir: Some("/".into()),
                user: user.map(String::from),
                timeout: Duration::from_secs(30),
                max_output_bytes: 4096,
            },
            Cancellation::new(),
            |output| {
                match output.stream {
                    Stream::Stdout => stdout.extend(output.bytes),
                    Stream::Stderr => stderr.extend(output.bytes),
                }
                Ok(())
            },
        )?;
        if !outcome.success() || stdout != expected || !stderr.is_empty() {
            return Err("ordinary OCI command or retained data differs".into());
        }
        Ok(())
    }
    fn startup_probe(&self, starts: usize) -> ProofResult<()> {
        // One bounded foreground observation waits for the asynchronous startup
        // process. It never launches/retries the configured workload itself.
        if !matches!(starts, 1 | 2) {
            return Err("unsupported startup observation".into());
        }
        let script = format!("i=0; while [ \"$i\" -lt 200 ]; do if [ -f /workspace/ordinary-oci-startups ] && [ \"$(wc -l < /workspace/ordinary-oci-startups)\" -ge {starts} ]; then cat /workspace/ordinary-oci-startups; exit; fi; i=$((i+1)); sleep 0.05; done; exit 1");
        self.command_expect(&script, STARTUP_LINE.repeat(starts).as_bytes())?;
        self.stage(
            if starts == 1 { "startup-first" } else { "startup-restart" },
            json!({"observed_starts":starts,"explicit_entrypoint_cmd_env_workdir":true,"image_default_user":true,"duplicate_startup_observed":false}),
        )
    }
    fn stop(&self) -> ProofResult<()> {
        if self
            .engine
            .stop_with_budget(self.original()?, &budget()?)?
            .state
            != ObservedState::Stopped
        {
            return Err("normal stop unverified".into());
        }
        Ok(())
    }
    fn delete(&mut self) -> ProofResult<()> {
        if self.deleted {
            return Ok(());
        }
        if self.engine.inspect(self.original()?)?.state != ObservedState::Stopped {
            return Err("positive stopped state required for owned deletion".into());
        }
        if self
            .engine
            .delete_with_budget(self.original()?, &budget()?)?
            .state
            != ObservedState::Missing
        {
            return Err("original owned deletion unverified".into());
        }
        self.deleted = true;
        self.stage("deleted", json!({"owned_deleted":true}))
    }
    fn close_cleaned(&mut self) -> ProofResult<()> {
        if self.closed {
            return Ok(());
        }
        if !self.engine.available()
            || !self.deleted
            || self.engine.inspect(self.original()?)?.state != ObservedState::Missing
            || self.engine.inventory(&budget()?)?.count != 0
        {
            return Err("original owned cleanup is incomplete".into());
        }
        self.close()
    }
    fn close_unstarted(&mut self) -> ProofResult<()> {
        if self.create_entered
            || self.start_entered
            || !self.engine.available()
            || self.engine.inventory(&budget()?)?.count != 0
        {
            return Err("only never-entered, available, empty owner can close unstarted".into());
        }
        self.close()
    }
    fn close(&mut self) -> ProofResult<()> {
        if self
            .engine
            .shutdown()
            .iter()
            .any(|(_, result)| result.is_err())
        {
            return Err("normal engine shutdown incomplete".into());
        }
        self.closed = true;
        Ok(())
    }
    fn registry_start(&mut self) -> ProofResult<()> {
        self.start_entered = true;
        if self.engine.start(self.original()?)?.state != ObservedState::Running {
            return Err("original registry artifact not observed running".into());
        }
        Ok(())
    }
    fn exercise_registry(&mut self, settings: &RegistrySettings) -> ProofResult<serde_json::Value> {
        if self.engine.inventory(&budget()?)?.count != 0 {
            return Err("fresh registry witness requires empty SDK inventory".into());
        }
        self.stage("registry-settings", serde_json::to_value(settings)?)?;
        let intent = RegistryCreationIntent {
            name: format!("ordinary-registry-{}", support::random(12)?),
            owner_token: support::random(32)?,
            incarnation: support::random(16)?,
            source: settings.source.clone(),
            resources: Resources {
                cpus: 1,
                memory_mib: 512,
                storage_gib: 1,
                overlay_gib: 1,
            },
            labels: BTreeMap::new(),
            features: CreationFeatures {
                branch_https: false,
                network: NetworkPolicy {
                    enabled: false,
                    hosts: vec![],
                    cidrs: vec![],
                },
                ports: vec![],
                workload: None,
            },
        };
        self.stage("registry-creation-intent", json!({"name":intent.name,"owner_token":intent.owner_token,"incarnation":intent.incarnation,"source":intent.source,"resources":{"cpus":intent.resources.cpus,"memory_mib":intent.resources.memory_mib,"storage_gib":intent.resources.storage_gib,"overlay_gib":intent.resources.overlay_gib},"features":intent.features}))?;
        if !matches!(
            self.engine.inspect_registry_creation(&intent, &budget()?)?,
            CreationPresence::Absent
        ) {
            return Err("registry intent absence unverified; no adoption".into());
        }
        let deadline = Instant::now() + Duration::from_secs(120);
        let cold = self.engine.prepare_registry_blob(
            settings.source.clone(),
            settings.max_bytes,
            settings.cache_policy,
            deadline,
            Cancellation::new(),
        )?;
        if cold.already_cached() || cold.source() != &settings.source || cold.size() == 0 {
            return Err("fresh cold registry preparation differs".into());
        }
        let size = cold.size();
        self.stage(
            "registry-cold",
            json!({"source":cold.source(),"size_bytes":size,"cached":false}),
        )?;
        drop(cold);
        let warm = self.engine.prepare_registry_blob(
            settings.source.clone(),
            settings.max_bytes,
            settings.cache_policy,
            deadline,
            Cancellation::new(),
        )?;
        if !warm.already_cached() || warm.source() != &settings.source || warm.size() != size {
            return Err("warm registry preparation differs".into());
        }
        self.stage(
            "registry-warm",
            json!({"source":warm.source(),"size_bytes":size,"cached":true}),
        )?;
        drop(warm);
        let resources = intent.resources;
        self.create_entered = true;
        self.receipt = Some(self.engine.create_registry_cached(
            intent,
            size,
            settings.cache_policy,
            deadline,
            &Cancellation::new(),
        )?);
        save(&self.output.join("receipt.json"), self.original()?)?;
        self.registry_start()?;
        self.command_as("mkdir -p /workspace; printf 'smolbox-ordinary-registry-v1\\n' > /workspace/ordinary-registry-data; cat /workspace/ordinary-registry-data", b"smolbox-ordinary-registry-v1\n", None)?;
        self.stage(
            "registry-first-start",
            json!({"running":true,"data_written_and_read":true}),
        )?;
        self.stop()?;
        self.registry_start()?;
        self.command_as(
            "cat /workspace/ordinary-registry-data",
            b"smolbox-ordinary-registry-v1\n",
            None,
        )?;
        self.stage("registry-restart", json!({"data_retained":true}))?;
        self.stop()?;
        self.delete()?;
        let retained = self.engine.qualify_registry_cached(
            settings.source.clone(),
            size,
            settings.cache_policy,
            resources,
            Instant::now() + Duration::from_secs(120),
            Cancellation::new(),
        )?;
        if retained.source() != &settings.source {
            return Err("retained registry cache identity differs after owned deletion".into());
        }
        self.stage(
            "registry-cache-retained",
            json!({"source":retained.source(),"size_bytes":size,"pack_requalified":true}),
        )?;
        Ok(
            json!({"status":"passed","scope":"ordinary-owned-engine-registry-artifact","package_manifest_sha256":settings.manifest_sha256,"source":settings.source,"artifact_bytes":size,"cold_preparation":true,"warm_preparation":true,"cached_creation":true,"guest_network_enabled":false,"ordinary_restart":true,"data_retained":true,"owned_deleted":true,"host_cache_retained":true,"credential_workflow_qualified":false,"public_registry_admission_enabled":false,"crash_validation_performed":false,"distribution_approved":false}),
        )
    }
    fn exercise(
        &mut self,
        settings: &Settings,
        features: CreationFeatures,
    ) -> ProofResult<serde_json::Value> {
        if self.engine.inventory(&budget()?)?.count != 0 {
            return Err("fresh witness requires empty SDK inventory".into());
        }
        self.stage("settings", serde_json::to_value(settings)?)?;
        let source = self.engine.prepare_oci_metadata(
            settings.source.clone(),
            Instant::now() + Duration::from_secs(120),
            Cancellation::new(),
        )?;
        self.stage(
            "metadata",
            json!({"verified":true,"layers":source.layer_count()}),
        )?;
        let name = format!("ordinary-oci-{}", support::random(12)?);
        let request = CreateOciRequest {
            name,
            owner_token: support::random(32)?,
            incarnation: support::random(16)?,
            resources: Resources {
                cpus: 1,
                memory_mib: 512,
                storage_gib: 1,
                overlay_gib: 1,
            },
            labels: BTreeMap::new(),
            source,
            features,
        };
        self.stage("create-intent", json!({"name":request.name,"owner_token":request.owner_token,"incarnation":request.incarnation,"source":settings.source}))?;
        self.create_entered = true;
        let receipt = self.engine.create_oci(
            request,
            Instant::now() + Duration::from_secs(120),
            &Cancellation::new(),
        )?;
        self.receipt = Some(receipt);
        save(&self.output.join("receipt.json"), self.original()?)?;
        if !self
            .engine
            .list_images(self.original()?, &budget()?)?
            .is_empty()
        {
            return Err("stopped listing must remain passive/empty".into());
        }
        self.start(&settings.source)?;
        self.stage("first-start", json!({"running":true}))?;
        if settings.startup_workload.is_some() {
            self.startup_probe(1)?;
        }
        self.command("mkdir -p /workspace; printf 'smolbox-ordinary-oci-v1\\n' > /workspace/ordinary-oci-data; cat /workspace/ordinary-oci-data")?;
        let before = self.engine.list_images(self.original()?, &budget()?)?;
        if !before.iter().any(|image| settings.source.matches(image)) {
            return Err("initial pinned image absent from guest inventory".into());
        }
        let pulled = self.engine.pull_image_owned(
            self.original()?,
            settings.pull_source.clone(),
            Instant::now() + Duration::from_secs(600),
            Cancellation::new(),
        )?;
        if !settings.pull_source.matches(&pulled) {
            return Err("pulled image identity differs".into());
        }
        let after = self.engine.list_images(self.original()?, &budget()?)?;
        if !after.iter().any(|image| settings.source.matches(image))
            || !after
                .iter()
                .any(|image| settings.pull_source.matches(image))
        {
            return Err("pinned guest image inventory differs".into());
        }
        self.stage(
            "images",
            json!({"before":before,"after":after,"pulled":pulled}),
        )?;
        self.stop()?;
        if !self
            .engine
            .list_images(self.original()?, &budget()?)?
            .is_empty()
        {
            return Err("stopped listing dispatched guest work".into());
        }
        self.stage("stopped", json!({"stopped":true}))?;
        self.start(&settings.source)?;
        if settings.startup_workload.is_some() {
            self.startup_probe(2)?;
        }
        self.command("cat /workspace/ordinary-oci-data")?;
        self.stage(
            "restart",
            json!({"original_source_restarted":true,"data_retained":true}),
        )?;
        self.stop()?;
        self.delete()?;
        Ok(
            json!({"status":"passed","scope":"ordinary-owned-engine-oci-images","package_manifest_sha256":settings.manifest_sha256,"source":settings.source,"pull_source":settings.pull_source,"guest_network":settings.network,"startup_workload_configured":settings.startup_workload.is_some(),"startup_workload_behavior_qualified":settings.startup_workload.is_some(),"startup_workload_scope":settings.startup_workload.as_ref().map(|_| "fixed explicit argv/env/workdir and image default user; observed startup counters 1 then 2"),"guest_image_inventory":true,"managed_image_pull":true,"original_source_restart":true,"data_retained":true,"owned_deleted":self.deleted,"data_sha256":hex::encode(Sha256::digest(b"smolbox-ordinary-oci-v1\n")),"public_oci_admission_enabled":false,"crash_validation_performed":false,"distribution_approved":false}),
        )
    }
}

fn handle_control(session: &mut Session, stream: &mut UnixStream) -> ProofResult<bool> {
    stream.set_read_timeout(Some(Duration::from_secs(2)))?;
    stream.set_write_timeout(Some(Duration::from_secs(2)))?;
    let mut bytes = vec![];
    (&mut *stream).take(65).read_to_end(&mut bytes)?;
    let action = std::str::from_utf8(&bytes)?.trim();
    let result = match action {
        "status" => Ok(()),
        "stop" => session.stop(),
        "delete" => session.delete(),
        "close-cleaned" => session.close_cleaned(),
        "close-unstarted" => session.close_unstarted(),
        _ => Err("unknown control action".into()),
    };
    let closed = result.is_ok() && session.closed;
    let response = json!({"ok":result.is_ok(),"error":result.err().map(|e|e.to_string()),"original_receipt_retained":session.receipt.is_some(),"owned_deleted":session.deleted,"closed":closed});
    stream.write_all(&serde_json::to_vec(&response)?)?;
    Ok(closed)
}
fn control(output: &Path, action: &str) -> ProofResult<()> {
    support::output(output, false)?;
    let mut stream = UnixStream::connect(output.join("control.sock"))?;
    stream.set_read_timeout(Some(Duration::from_secs(40)))?;
    stream.set_write_timeout(Some(Duration::from_secs(2)))?;
    stream.write_all(action.as_bytes())?;
    stream.shutdown(std::net::Shutdown::Write)?;
    let mut bytes = vec![];
    stream.take(4097).read_to_end(&mut bytes)?;
    if bytes.len() > 4096 {
        return Err("control response exceeded bound".into());
    }
    let value: serde_json::Value = serde_json::from_slice(&bytes)?;
    println!("{value}");
    if value["ok"] != true {
        return Err("normal control did not complete".into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    // Pure input models: neither test opens a package/domain or starts a guest.
    fn settings() -> Settings {
        let platform = if cfg!(target_arch = "aarch64") {
            "linux/arm64"
        } else {
            "linux/amd64"
        };
        Settings {
            package: "/approved/package".into(),
            manifest_sha256: "a".repeat(64),
            domain_json: "/approved/domain.json".into(),
            source: ImagePullRequest {
                reference: format!("registry.example/team/base@sha256:{}", "b".repeat(64)),
                platform: platform.into(),
            },
            pull_source: ImagePullRequest {
                reference: format!("registry.example/team/other@sha256:{}", "c".repeat(64)),
                platform: platform.into(),
            },
            network: NetworkPolicy {
                enabled: true,
                hosts: vec!["registry.example".into()],
                cidrs: vec![],
            },
            startup_workload: None,
        }
    }

    #[test]
    fn fixture_requires_explicit_native_sources_and_preserves_exact_guest_policy() {
        let mut settings = settings();
        let features = settings.features().unwrap();
        assert!(features.network == settings.network);
        assert!(features.ports.is_empty() && features.workload.is_none());
        settings.network.enabled = false;
        assert!(settings.features().is_err());
        settings.network.enabled = true;
        settings.pull_source = settings.source.clone();
        assert!(settings.features().is_err());
        settings.pull_source.reference = "registry.example/team/other:latest".into();
        assert!(settings.features().is_err());
    }

    #[test]
    fn fixture_cannot_redirect_a_database_or_accept_per_request_registry_credentials() {
        for key in ["database", "vm_root", "identity_token", "proxy"] {
            let mut input = serde_json::to_value(settings()).unwrap();
            input[key] = json!("unexpected-input");
            assert!(serde_json::from_value::<Settings>(input).is_err());
        }
    }

    #[test]
    fn configured_startup_claim_requires_the_exact_observed_workload() {
        let mut settings = settings();
        settings.startup_workload = Some(startup_fixture());
        assert!(settings.features().is_ok());
        settings.startup_workload.as_mut().unwrap().env.clear();
        assert!(settings.features().is_err());
    }

    fn registry_settings() -> RegistrySettings {
        RegistrySettings {
            package: "/approved/package".into(),
            manifest_sha256: "a".repeat(64),
            domain_json: "/approved/domain.json".into(),
            source: RegistryArtifactSource {
                reference: format!("registry.example/team/pack@sha256:{}", "b".repeat(64)),
                platform: "linux/amd64".into(),
                content_sha256: "c".repeat(64),
            },
            max_bytes: 1024 * 1024,
            cache_policy: RegistryCachePolicy {
                max_bytes: 8 * 1024 * 1024,
                max_files: 2,
            },
        }
    }

    #[test]
    fn registry_fixture_requires_pinned_native_identity_and_explicit_host_cache_budget() {
        let mut settings = registry_settings();
        assert!(settings.validate().is_ok());
        settings.max_bytes = settings.cache_policy.max_bytes + 1;
        assert!(settings.validate().is_err());
        settings.max_bytes = 1024;
        settings.source.platform = "linux/arm64".into();
        assert!(settings.validate().is_err());
        settings.source.platform = "linux/amd64".into();
        settings.source.reference = "registry.example/team/pack:latest".into();
        assert!(settings.validate().is_err());
    }

    #[test]
    fn registry_fixture_rejects_credentials_proxy_and_alternate_native_domain() {
        for key in [
            "identity_token",
            "credential_ref",
            "proxy",
            "database",
            "vm_root",
        ] {
            let mut value = serde_json::to_value(registry_settings()).unwrap();
            value[key] = json!("unapproved");
            assert!(serde_json::from_value::<RegistrySettings>(value).is_err());
        }
    }
}
