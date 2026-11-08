//! One bounded OCI publication attempt. Tokens/config bytes never enter journals
//! or public diagnostics. OCI format types come from the unmodified SDK.
use crate::export_staging::{ExportStagedFile, Stage};
use crate::{CreationReceipt, Engine, Error, ErrorCode, PackedExport, ReadBudget, Result};
use reqwest::{header, Client, Method, StatusCode, Url};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use smolvm_registry::{
    OciDescriptor, OciIndex, OciIndexManifest, OciManifest, OciPlatform, CONFIG_MEDIA_TYPE,
    INDEX_MEDIA_TYPE, LAYER_MEDIA_TYPE, MANIFEST_MEDIA_TYPE,
};
use std::time::{Duration, Instant};

pub const EXPORT_METADATA_BYTES: u64 = 1024 * 1024;
pub const EXPORT_UPLOAD_CHUNK_BYTES: u64 = 1024 * 1024;
pub const EXPORT_REGISTRY_REQUESTS: u64 = 1_048_576;
const METADATA_BYTES: usize = EXPORT_METADATA_BYTES as usize;
const ACK_BYTES: usize = METADATA_BYTES;
const UPLOAD_BYTES: usize = EXPORT_UPLOAD_CHUNK_BYTES as usize;
const REQUESTS: usize = EXPORT_REGISTRY_REQUESTS as usize;
fn before(code: ErrorCode) -> Error {
    Error::before(code)
}
fn unknown(code: ErrorCode) -> Error {
    Error::uncertain(code)
}
fn sha(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

/// Operator repository/TLS grant. The public Runtime separately owns permanent
/// tag claims and additional resource approval; this does not attest registry policy.
#[derive(Clone)]
pub struct ApprovedExportDestination {
    pub id: String,
    pub registry: String,
    pub repository: String,
    pub immutable_tags: bool,
    pub allow_insecure_loopback: bool,
    pub ca_certificate_pem: Option<Vec<u8>>,
}
impl std::fmt::Debug for ApprovedExportDestination {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ApprovedExportDestination")
            .field("id", &self.id)
            .finish_non_exhaustive()
    }
}
pub struct RegistryPublishCredential {
    token: String,
}
impl std::fmt::Debug for RegistryPublishCredential {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("RegistryPublishCredential(<redacted>)")
    }
}
impl RegistryPublishCredential {
    pub fn new(token: String) -> Result<Self> {
        let body = token.trim_end_matches('=');
        if token.is_empty()
            || token.len() > 16384
            || body.is_empty()
            || !body
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || b"._~+/-".contains(&byte))
        {
            return Err(before(ErrorCode::Validation));
        }
        Ok(Self { token })
    }
}
impl ApprovedExportDestination {
    pub fn validate(&self) -> Result<()> {
        self.origin().map(|_| ())
    }
    fn origin(&self) -> Result<Url> {
        if !crate::domain::valid_id(&self.id)
            || !self.immutable_tags
            || self.registry.len() > 260
            || self.repository.len() > 256
        {
            return Err(before(ErrorCode::Validation));
        }
        crate::ImagePullRequest {
            reference: format!(
                "{}/{}@sha256:{}",
                self.registry,
                self.repository,
                "0".repeat(64)
            ),
            platform: crate::oci::native_oci_platform().into(),
        }
        .validate()?;
        let endpoint = match self.registry.as_str() {
            "docker.io" => "registry-1.docker.io",
            "smolmachines.com" => "registry.smolmachines.com",
            other => other,
        };
        let origin = Url::parse(&format!(
            "{}://{endpoint}/",
            if self.allow_insecure_loopback {
                "http"
            } else {
                "https"
            }
        ))
        .map_err(|_| before(ErrorCode::Validation))?;
        if self.allow_insecure_loopback
            && (!matches!(origin.host_str(), Some("localhost" | "127.0.0.1"))
                || self.ca_certificate_pem.is_some())
        {
            return Err(before(ErrorCode::Validation));
        }
        if let Some(pem) = &self.ca_certificate_pem {
            if pem.is_empty()
                || pem.len() > 256 * 1024
                || reqwest::Certificate::from_pem(pem).is_err()
            {
                return Err(before(ErrorCode::Validation));
            }
        }
        Ok(origin)
    }
    pub fn digest(&self) -> Result<String> {
        crate::material::hash(&(
            "smolbox-export-destination-v1",
            &self.id,
            &self.registry,
            &self.repository,
            self.immutable_tags,
            self.allow_insecure_loopback,
            self.ca_certificate_pem.as_ref().map(|pem| sha(pem)),
        ))
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ExportPublicationIdentity {
    pub destination_id: String,
    pub destination_sha256: String,
    pub registry: String,
    pub repository: String,
    pub tag: String,
    pub platform_tag: String,
    pub platform: String,
    pub content_sha256: String,
    pub size_bytes: u64,
    pub config_sha256: String,
    pub manifest_sha256: String,
    pub index_sha256: String,
}
impl std::fmt::Debug for ExportPublicationIdentity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ExportPublicationIdentity")
            .field("size_bytes", &self.size_bytes)
            .finish_non_exhaustive()
    }
}
fn valid_tag(value: &str) -> bool {
    let tag = value.as_bytes();
    !tag.is_empty()
        && tag.len() <= 100
        && (tag[0].is_ascii_alphanumeric() || tag[0] == b'_')
        && tag
            .iter()
            .all(|byte| byte.is_ascii_alphanumeric() || b"_.-".contains(byte))
}
impl ExportPublicationIdentity {
    pub(crate) fn validate(&self) -> Result<()> {
        if !valid_tag(&self.tag)
            || !matches!(self.platform.as_str(), "linux/amd64" | "linux/arm64")
            || self.platform_tag != format!("{}-{}", self.tag, self.platform.replace('/', "-"))
            || self.registry.len() > 260
            || self.repository.len() > 256
            || !crate::domain::valid_id(&self.destination_id)
            || self.size_bytes == 0
            || self.size_bytes > crate::jobs::JOB_EXPORT_STAGING_BYTES
            || [
                &self.destination_sha256,
                &self.content_sha256,
                &self.config_sha256,
                &self.manifest_sha256,
                &self.index_sha256,
            ]
            .iter()
            .any(|value| !crate::domain::valid_hex(value, 64))
        {
            return Err(before(ErrorCode::Validation));
        }
        crate::ImagePullRequest {
            reference: format!(
                "{}/{}@sha256:{}",
                self.registry, self.repository, self.manifest_sha256
            ),
            platform: self.platform.clone(),
        }
        .validate()
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ExportPublication {
    pub schema: u8,
    pub source: CreationReceipt,
    pub operation_id: String,
    pub request_sha256: String,
    pub identity: ExportPublicationIdentity,
    pub proof_sha256: String,
}
impl std::fmt::Debug for ExportPublication {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ExportPublication")
            .field("schema", &self.schema)
            .finish_non_exhaustive()
    }
}
impl ExportPublication {
    pub fn validate(&self, binding: &crate::DomainBinding) -> Result<()> {
        self.source.validate(binding)?;
        if self.schema != 1
            || self.source.material.is_none()
            || !crate::domain::valid_id(&self.operation_id)
            || !crate::domain::valid_hex(&self.request_sha256, 64)
        {
            return Err(before(ErrorCode::Validation));
        }
        let actual = Self::new(
            self.source.clone(),
            self.operation_id.clone(),
            self.request_sha256.clone(),
            self.identity.clone(),
        )?;
        if actual.proof_sha256 != self.proof_sha256 {
            return Err(before(ErrorCode::Ownership));
        }
        Ok(())
    }
    pub(crate) fn new(
        source: CreationReceipt,
        operation_id: String,
        request_sha256: String,
        identity: ExportPublicationIdentity,
    ) -> Result<Self> {
        identity.validate()?;
        let proof_sha256 = crate::material::hash(&(
            "smolbox-export-publication-v1",
            &source,
            &operation_id,
            &request_sha256,
            &identity,
        ))?;
        Ok(Self {
            schema: 1,
            source,
            operation_id,
            request_sha256,
            identity,
            proof_sha256,
        })
    }
}
/// Retains source gates/work/scratch even after a registry acknowledgement.
/// Independent controller verification and explicit quiesced cleanup remain required.
pub struct PublishedExport {
    pub(crate) packed: PackedExport,
    pub(crate) publication: ExportPublication,
}
impl std::fmt::Debug for PublishedExport {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PublishedExport")
            .field("publication", &self.publication)
            .finish_non_exhaustive()
    }
}
impl PublishedExport {
    pub fn publication(&self) -> &ExportPublication {
        &self.publication
    }
    pub fn recheck(&self, engine: &Engine) -> Result<()> {
        self.packed.recheck(engine)
    }
    pub fn close(self, budget: &ReadBudget) -> Result<crate::ExportStageCleanup> {
        self.packed.close(budget)
    }
}

pub(crate) struct Plan {
    identity: ExportPublicationIdentity,
    config: Vec<u8>,
    manifest: Vec<u8>,
    index: Vec<u8>,
}
impl Plan {
    pub(crate) fn from_artifact(
        stage: &Stage,
        artifact: &ExportStagedFile,
        destination: &ApprovedExportDestination,
        tag: &str,
        budget: &ReadBudget,
    ) -> Result<Self> {
        budget.check()?;
        destination.validate()?;
        if !valid_tag(tag) {
            return Err(before(ErrorCode::Validation));
        }
        let mut footer = [0; smolvm_pack::FOOTER_SIZE];
        let offset = artifact
            .size_bytes
            .checked_sub(footer.len() as u64)
            .ok_or(before(ErrorCode::Validation))?;
        stage.read_at("artifact.smolmachine", offset, &mut footer, budget)?;
        let footer = smolvm_pack::PackFooter::from_bytes(&footer)
            .map_err(|_| before(ErrorCode::Validation))?;
        if footer.stub_size != 0
            || footer.assets_offset != 0
            || footer.manifest_offset != footer.assets_size
            || footer.manifest_size == 0
            || footer.manifest_size > METADATA_BYTES as u64
            || footer.manifest_offset.checked_add(footer.manifest_size) != Some(offset)
        {
            return Err(before(ErrorCode::Validation));
        }
        let mut config = vec![0; footer.manifest_size as usize];
        for (index, chunk) in config.chunks_mut(64 * 1024).enumerate() {
            stage.read_at(
                "artifact.smolmachine",
                footer.manifest_offset + (index * 64 * 1024) as u64,
                chunk,
                budget,
            )?;
        }
        let metadata = smolvm_pack::PackManifest::from_json(&config)
            .map_err(|_| before(ErrorCode::Validation))?;
        if metadata.platform != crate::oci::native_oci_platform() || metadata.checkpoint.is_some() {
            return Err(before(ErrorCode::Validation));
        }
        // Match the SDK push config representation, including full pack metadata.
        let config =
            serde_json::to_vec_pretty(&metadata).map_err(|_| before(ErrorCode::Validation))?;
        if config.len() > METADATA_BYTES {
            return Err(before(ErrorCode::OutputLimit));
        }
        let config_sha256 = sha(&config);
        let platform = OciPlatform::parse(&metadata.platform);
        let manifest = OciManifest {
            schema_version: 2,
            media_type: MANIFEST_MEDIA_TYPE.into(),
            artifact_type: Some(LAYER_MEDIA_TYPE.into()),
            config: OciDescriptor {
                media_type: CONFIG_MEDIA_TYPE.into(),
                digest: format!("sha256:{config_sha256}"),
                size: config.len() as u64,
            },
            layers: vec![OciDescriptor {
                media_type: LAYER_MEDIA_TYPE.into(),
                digest: format!("sha256:{}", artifact.sha256),
                size: artifact.size_bytes,
            }],
            annotations: Some(std::collections::BTreeMap::from([
                (
                    "org.opencontainers.image.title".into(),
                    format!("{}:{tag}", destination.repository),
                ),
                (
                    "com.smolmachines.pack.mode".into(),
                    format!("{:?}", metadata.mode).to_lowercase(),
                ),
            ])),
        };
        let manifest =
            serde_json::to_vec_pretty(&manifest).map_err(|_| before(ErrorCode::Validation))?;
        let manifest_sha256 = sha(&manifest);
        let index = OciIndex {
            schema_version: 2,
            media_type: INDEX_MEDIA_TYPE.into(),
            manifests: vec![OciIndexManifest {
                media_type: MANIFEST_MEDIA_TYPE.into(),
                digest: format!("sha256:{manifest_sha256}"),
                size: manifest.len() as u64,
                platform: Some(platform),
            }],
        };
        let index = serde_json::to_vec_pretty(&index).map_err(|_| before(ErrorCode::Validation))?;
        let identity = ExportPublicationIdentity {
            destination_id: destination.id.clone(),
            destination_sha256: destination.digest()?,
            registry: destination.registry.clone(),
            repository: destination.repository.clone(),
            tag: tag.into(),
            platform_tag: format!("{tag}-{}", metadata.platform.replace('/', "-")),
            platform: metadata.platform,
            content_sha256: artifact.sha256.clone(),
            size_bytes: artifact.size_bytes,
            config_sha256,
            manifest_sha256,
            index_sha256: sha(&index),
        };
        identity.validate()?;
        budget.check()?;
        Ok(Self {
            identity,
            config,
            manifest,
            index,
        })
    }
}

fn client(destination: &ApprovedExportDestination, budget: &ReadBudget) -> Result<Client> {
    let remaining = budget.deadline.saturating_duration_since(Instant::now());
    let mut builder = Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        // Native attempt/request accounting includes every dispatched request.
        .retry(reqwest::retry::never())
        .http1_only()
        .pool_max_idle_per_host(0)
        .no_gzip()
        .no_brotli()
        .no_deflate()
        .no_zstd()
        .timeout(remaining)
        .connect_timeout(remaining.min(Duration::from_secs(10)));
    if let Some(pem) = &destination.ca_certificate_pem {
        builder = builder.add_root_certificate(
            reqwest::Certificate::from_pem(pem).map_err(|_| before(ErrorCode::Validation))?,
        );
    }
    builder.build().map_err(|_| before(ErrorCode::Native))
}
async fn bounded_attempt<T>(
    budget: &ReadBudget,
    operation: impl std::future::Future<Output = Result<T>>,
) -> Result<T> {
    tokio::select! {
        biased;
        _ = async { loop { if budget.cancel.is_cancelled() {break;} tokio::time::sleep(Duration::from_millis(5)).await; } } => Err(unknown(ErrorCode::State)),
        result = tokio::time::timeout_at(tokio::time::Instant::from_std(budget.deadline), operation) => result.map_err(|_| unknown(ErrorCode::State))?,
    }
}

pub(crate) fn publish(
    stage: &mut Stage,
    artifact: &ExportStagedFile,
    plan: &Plan,
    destination: &ApprovedExportDestination,
    credential: &RegistryPublishCredential,
    budget: &ReadBudget,
    source_check: impl Fn() -> Result<()>,
) -> Result<ExportPublication> {
    budget.check()?;
    let origin = destination.origin()?;
    if plan.identity.destination_sha256 != destination.digest()?
        || plan.identity.content_sha256 != artifact.sha256
        || plan.identity.size_bytes != artifact.size_bytes
    {
        return Err(before(ErrorCode::Ownership));
    }
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .max_blocking_threads(1)
        .build()
        .map_err(|_| before(ErrorCode::Native))?;
    let client = client(destination, budget)?;
    stage.prepare_publication(plan.identity.clone())?;
    // No retry/resume path exists after preparation. The original job and stage
    // allowance survive until Runtime drop also collects any resolver thread.
    let attempt = runtime.block_on(async {
        let operation = async {
            let mut session = Session {
                client,
                origin,
                destination,
                credential,
                budget,
                requests: 0,
            };
            for tag in [&plan.identity.tag, &plan.identity.platform_tag] {
                let url = session.url(&format!("manifests/{tag}"))?;
                let response = session.send(Method::HEAD, url, None, None).await?;
                if response.status() != StatusCode::NOT_FOUND {
                    return Err(unknown(ErrorCode::Conflict));
                }
            }
            budget.check().map_err(|e| unknown(e.code))?;
            stage.enter_publication()?;
            session
                .blob(
                    &plan.identity.content_sha256,
                    artifact.size_bytes,
                    |offset, buffer| stage.read_at("artifact.smolmachine", offset, buffer, budget),
                )
                .await?;
            session
                .blob(
                    &plan.identity.config_sha256,
                    plan.config.len() as u64,
                    |offset, buffer| {
                        buffer.copy_from_slice(
                            &plan.config[offset as usize..offset as usize + buffer.len()],
                        );
                        Ok(())
                    },
                )
                .await?;
            for (name, bytes, kind, fresh) in [
                (
                    format!("sha256:{}", plan.identity.manifest_sha256),
                    &plan.manifest,
                    MANIFEST_MEDIA_TYPE,
                    false,
                ),
                (
                    plan.identity.platform_tag.clone(),
                    &plan.manifest,
                    MANIFEST_MEDIA_TYPE,
                    true,
                ),
                (
                    plan.identity.tag.clone(),
                    &plan.index,
                    INDEX_MEDIA_TYPE,
                    true,
                ),
            ] {
                let url = session.url(&format!("manifests/{name}"))?;
                let response = session.manifest(url, bytes, kind, fresh).await?;
                if response.status() != StatusCode::CREATED {
                    return Err(unknown(ErrorCode::Native));
                }
                digest_header(&response, &sha(bytes))?;
                ack(response).await?;
            }
            Ok(())
        };
        bounded_attempt(budget, operation).await
    });
    attempt.map_err(|e| unknown(e.code))?;
    budget.check().map_err(|e| unknown(e.code))?;
    source_check().map_err(|e| unknown(e.code))?;
    stage.complete_publication().map_err(|e| unknown(e.code))
}
struct Session<'a> {
    client: Client,
    origin: Url,
    destination: &'a ApprovedExportDestination,
    credential: &'a RegistryPublishCredential,
    budget: &'a ReadBudget,
    requests: usize,
}
impl Session<'_> {
    fn url(&self, path: &str) -> Result<Url> {
        self.origin
            .join(&format!("v2/{}/{path}", self.destination.repository))
            .map_err(|_| unknown(ErrorCode::Validation))
    }
    fn request(&mut self, method: Method, url: Url) -> Result<reqwest::RequestBuilder> {
        self.budget.check().map_err(|e| unknown(e.code))?;
        self.requests += 1;
        if self.requests > REQUESTS || url.origin() != self.origin.origin() {
            return Err(unknown(ErrorCode::OutputLimit));
        }
        Ok(self
            .client
            .request(method, url)
            .bearer_auth(&self.credential.token)
            .header(
                header::ACCEPT,
                format!("{MANIFEST_MEDIA_TYPE}, {INDEX_MEDIA_TYPE}"),
            ))
    }
    async fn send(
        &mut self,
        method: Method,
        url: Url,
        body: Option<Vec<u8>>,
        range: Option<(u64, u64)>,
    ) -> Result<reqwest::Response> {
        let mut request = self
            .request(method, url)?
            .header(header::CONTENT_TYPE, "application/octet-stream");
        request = if let Some(body) = body {
            request.body(body)
        } else {
            request.header(header::CONTENT_LENGTH, 0)
        };
        if let Some((start, end)) = range {
            request = request.header(header::CONTENT_RANGE, format!("{start}-{end}"));
        }
        request.send().await.map_err(|_| unknown(ErrorCode::Native))
    }
    async fn manifest(
        &mut self,
        url: Url,
        bytes: &[u8],
        kind: &str,
        fresh: bool,
    ) -> Result<reqwest::Response> {
        let mut request = self
            .request(Method::PUT, url)?
            .header(header::CONTENT_TYPE, kind)
            .body(bytes.to_vec());
        if fresh {
            request = request.header(header::IF_NONE_MATCH, "*");
        }
        request.send().await.map_err(|_| unknown(ErrorCode::Native))
    }
    fn location(&self, response: &reqwest::Response) -> Result<Url> {
        let mut values = response.headers().get_all(header::LOCATION).iter();
        let value = values
            .next()
            .and_then(|value| value.to_str().ok())
            .ok_or(unknown(ErrorCode::Validation))?;
        if value.len() > 8192 || values.next().is_some() {
            return Err(unknown(ErrorCode::Validation));
        }
        let url = response
            .url()
            .join(value)
            .map_err(|_| unknown(ErrorCode::Validation))?;
        if url.origin() != self.origin.origin()
            || !url.username().is_empty()
            || url.password().is_some()
            || url.fragment().is_some()
            || url.query_pairs().any(|(key, _)| key == "digest")
        {
            return Err(unknown(ErrorCode::Validation));
        }
        Ok(url)
    }
    async fn blob(
        &mut self,
        digest: &str,
        size: u64,
        mut read: impl FnMut(u64, &mut [u8]) -> Result<()>,
    ) -> Result<()> {
        let response = self
            .send(Method::POST, self.url("blobs/uploads/")?, None, None)
            .await?;
        if response.status() != StatusCode::ACCEPTED {
            return Err(unknown(ErrorCode::Native));
        }
        let mut upload = self.location(&response)?;
        ack(response).await?;
        let mut offset = 0;
        let mut hash = Sha256::new();
        while offset < size {
            self.budget.check().map_err(|e| unknown(e.code))?;
            let take = (size - offset).min(UPLOAD_BYTES as u64) as usize;
            let mut chunk = vec![0; take];
            for (index, part) in chunk.chunks_mut(256 * 1024).enumerate() {
                read(offset + (index * 256 * 1024) as u64, part).map_err(|e| unknown(e.code))?;
            }
            hash.update(&chunk);
            let end = offset + take as u64 - 1;
            let response = self
                .send(Method::PATCH, upload, Some(chunk), Some((offset, end)))
                .await?;
            if response.status() != StatusCode::ACCEPTED
                || response
                    .headers()
                    .get(header::RANGE)
                    .and_then(|value| value.to_str().ok())
                    != Some(format!("0-{end}").as_str())
            {
                return Err(unknown(ErrorCode::Native));
            }
            upload = self.location(&response)?;
            ack(response).await?;
            offset += take as u64;
        }
        if format!("{:x}", hash.finalize()) != digest {
            return Err(unknown(ErrorCode::Ownership));
        }
        upload
            .query_pairs_mut()
            .append_pair("digest", &format!("sha256:{digest}"));
        let response = self.send(Method::PUT, upload, None, None).await?;
        if response.status() != StatusCode::CREATED {
            return Err(unknown(ErrorCode::Native));
        }
        digest_header(&response, digest)?;
        ack(response).await
    }
}
fn digest_header(response: &reqwest::Response, expected: &str) -> Result<()> {
    let mut values = response.headers().get_all("docker-content-digest").iter();
    // Some compliant registries omit the digest response header; when present it
    // must identify the exact bytes we sent. Controller verification remains separate.
    if let Some(value) = values.next() {
        if value.to_str().ok() != Some(format!("sha256:{expected}").as_str())
            || values.next().is_some()
        {
            return Err(unknown(ErrorCode::Ownership));
        }
    }
    Ok(())
}
async fn ack(mut response: reqwest::Response) -> Result<()> {
    if response
        .content_length()
        .is_some_and(|bytes| bytes > ACK_BYTES as u64)
    {
        return Err(unknown(ErrorCode::OutputLimit));
    }
    let mut total = 0;
    while let Some(bytes) = response
        .chunk()
        .await
        .map_err(|_| unknown(ErrorCode::Native))?
    {
        total += bytes.len();
        if total > ACK_BYTES {
            return Err(unknown(ErrorCode::OutputLimit));
        }
    }
    Ok(())
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::export_assets::tests::budget;
    use std::collections::BTreeMap;
    use std::io::{Read, Write};
    use std::net::{TcpListener, TcpStream};
    use std::sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    };

    #[derive(Clone, Copy)]
    pub(crate) enum Fault {
        None,
        Conflict,
        Redirect,
        ForeignLocation,
        Range,
        Digest,
        OversizedAck,
        Unauthorized,
    }
    struct AckPause {
        entered: std::sync::mpsc::SyncSender<()>,
        resume: std::sync::mpsc::Receiver<()>,
    }
    pub(crate) struct Peer {
        pub(crate) destination: ApprovedExportDestination,
        events: Arc<Mutex<Vec<(String, String)>>>,
        stopped: Arc<AtomicBool>,
        thread: Option<std::thread::JoinHandle<()>>,
    }
    impl Peer {
        pub(crate) fn new(fault: Fault, cancel: Option<crate::Cancellation>) -> Self {
            Self::with_env(fault, cancel, vec!["SECRET=private-env-value".into()])
        }
        fn pause_first_ack() -> (
            Self,
            std::sync::mpsc::Receiver<()>,
            std::sync::mpsc::SyncSender<()>,
        ) {
            let (entered, paused) = std::sync::mpsc::sync_channel(1);
            let (release, resume) = std::sync::mpsc::sync_channel(1);
            (
                Self::with_env_and_pause(
                    Fault::None,
                    None,
                    vec![],
                    Some(AckPause { entered, resume }),
                ),
                paused,
                release,
            )
        }
        fn with_env(
            fault: Fault,
            cancel: Option<crate::Cancellation>,
            expected_env: Vec<String>,
        ) -> Self {
            Self::with_env_and_pause(fault, cancel, expected_env, None)
        }
        fn with_env_and_pause(
            fault: Fault,
            cancel: Option<crate::Cancellation>,
            expected_env: Vec<String>,
            mut pause: Option<AckPause>,
        ) -> Self {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            listener.set_nonblocking(true).unwrap();
            let registry = listener.local_addr().unwrap().to_string();
            let events = Arc::new(Mutex::new(vec![]));
            let stopped = Arc::new(AtomicBool::new(false));
            let stop = stopped.clone();
            let log = events.clone();
            let thread = std::thread::spawn(move || {
                let mut uploads: BTreeMap<String, Vec<u8>> = BTreeMap::new();
                let mut blobs: BTreeMap<String, Vec<u8>> = BTreeMap::new();
                let mut manifests = BTreeMap::new();
                let until = Instant::now() + Duration::from_secs(20);
                while !stop.load(Ordering::SeqCst) && Instant::now() < until {
                    let (mut stream, _) = match listener.accept() {
                        Ok(item) => item,
                        Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                            std::thread::sleep(Duration::from_millis(2));
                            continue;
                        }
                        Err(_) => break,
                    };
                    stream.set_nonblocking(false).unwrap();
                    stream
                        .set_read_timeout(Some(Duration::from_secs(3)))
                        .unwrap();
                    stream
                        .set_write_timeout(Some(Duration::from_secs(3)))
                        .unwrap();
                    let (method, target, headers, body) = read_request(&mut stream);
                    assert_eq!(
                        headers.get("authorization").map(String::as_str),
                        Some("Bearer fixture-push-token")
                    );
                    log.lock().unwrap().push((method.clone(), target.clone()));
                    if matches!(fault, Fault::Unauthorized) {
                        reply(&mut stream, 401, &[], b"secret registry diagnostic");
                        continue;
                    }
                    let url = Url::parse(&format!("http://registry.test{target}")).unwrap();
                    match method.as_str() {
                        "HEAD" => {
                            if matches!(fault, Fault::Conflict) {
                                reply(&mut stream, 200, &[], b"");
                            } else if matches!(fault, Fault::Redirect) {
                                reply(
                                    &mut stream,
                                    302,
                                    &[("Location", "http://127.0.0.1:1/forbidden".into())],
                                    b"",
                                );
                            } else {
                                reply(&mut stream, 404, &[], b"");
                            }
                        }
                        "POST" => {
                            assert!(body.is_empty());
                            let path = format!("/v2/team/artifact/blobs/uploads/{}", uploads.len());
                            uploads.insert(path.clone(), vec![]);
                            let location = if matches!(fault, Fault::ForeignLocation) {
                                "http://127.0.0.1:1/forbidden".into()
                            } else {
                                format!("{path}?opaque=session")
                            };
                            if matches!(fault, Fault::OversizedAck) {
                                reply(
                                    &mut stream,
                                    202,
                                    &[
                                        ("Location", location),
                                        ("Content-Length", (ACK_BYTES + 1).to_string()),
                                    ],
                                    b"",
                                );
                            } else {
                                reply(&mut stream, 202, &[("Location", location)], b"");
                            }
                        }
                        "PATCH" => {
                            let upload = uploads.get_mut(url.path()).unwrap();
                            assert_eq!(
                                headers.get("content-range").unwrap(),
                                &format!("{}-{}", upload.len(), upload.len() + body.len() - 1)
                            );
                            assert!(body.len() <= UPLOAD_BYTES);
                            upload.extend(body);
                            let range = if matches!(fault, Fault::Range) {
                                "0-incorrect".into()
                            } else {
                                format!("0-{}", upload.len() - 1)
                            };
                            if let Some(cancel) = &cancel {
                                cancel.cancel();
                            }
                            if let Some(pause) = pause.take() {
                                // A valid response header is insufficient credit:
                                // keep its bounded body incomplete until released.
                                write!(stream, "HTTP/1.1 202 Accepted\r\nLocation: {target}\r\nRange: {range}\r\nContent-Length: 1\r\nConnection: close\r\n\r\n").unwrap();
                                stream.flush().unwrap();
                                pause.entered.send(()).unwrap();
                                // Dropped test control never strands the peer.
                                let _ = pause.resume.recv_timeout(Duration::from_secs(5));
                                let _ = stream.write_all(b"x");
                            } else {
                                reply(
                                    &mut stream,
                                    202,
                                    &[("Location", target.clone()), ("Range", range)],
                                    b"",
                                );
                            }
                        }
                        "PUT" if url.path().contains("/blobs/uploads/") => {
                            assert!(body.is_empty());
                            let digest = url
                                .query_pairs()
                                .find(|(key, _)| key == "digest")
                                .unwrap()
                                .1
                                .into_owned();
                            let bytes = uploads.get(url.path()).unwrap();
                            assert_eq!(digest, format!("sha256:{}", sha(bytes)));
                            blobs.insert(digest.clone(), bytes.clone());
                            reply(
                                &mut stream,
                                201,
                                &[(
                                    "Docker-Content-Digest",
                                    if matches!(fault, Fault::Digest) {
                                        format!("sha256:{}", "0".repeat(64))
                                    } else {
                                        digest
                                    },
                                )],
                                b"",
                            );
                        }
                        "PUT" => {
                            let name = url.path().rsplit_once('/').unwrap().1;
                            if headers.get("content-type").map(String::as_str)
                                == Some(MANIFEST_MEDIA_TYPE)
                            {
                                let manifest: OciManifest = serde_json::from_slice(&body).unwrap();
                                assert_eq!(manifest.schema_version, 2);
                                assert_eq!(
                                    manifest.artifact_type.as_deref(),
                                    Some(LAYER_MEDIA_TYPE)
                                );
                                assert_eq!(manifest.layers.len(), 1);
                                assert_eq!(
                                    blobs[&manifest.config.digest].len() as u64,
                                    manifest.config.size
                                );
                                assert_eq!(
                                    blobs[&manifest.layers[0].digest].len() as u64,
                                    manifest.layers[0].size
                                );
                                let config = smolvm_pack::PackManifest::from_json(
                                    &blobs[&manifest.config.digest],
                                )
                                .unwrap();
                                assert_eq!(config.platform, crate::oci::native_oci_platform());
                                assert_eq!(config.env, expected_env);
                                if name.starts_with("sha256:") {
                                    assert_eq!(name, format!("sha256:{}", sha(&body)));
                                } else {
                                    assert_eq!(
                                        headers.get("if-none-match").map(String::as_str),
                                        Some("*")
                                    );
                                }
                            } else {
                                assert_eq!(
                                    headers.get("content-type").map(String::as_str),
                                    Some(INDEX_MEDIA_TYPE)
                                );
                                assert_eq!(
                                    headers.get("if-none-match").map(String::as_str),
                                    Some("*")
                                );
                                let index: OciIndex = serde_json::from_slice(&body).unwrap();
                                assert_eq!(index.manifests.len(), 1);
                                let entry = &index.manifests[0];
                                assert_eq!(
                                    entry.platform.as_ref().unwrap().label(),
                                    crate::oci::native_oci_platform()
                                );
                                let saved: &Vec<u8> = manifests.get(&entry.digest).unwrap();
                                assert_eq!(entry.size, saved.len() as u64);
                            }
                            let digest = format!("sha256:{}", sha(&body));
                            manifests.insert(name.to_owned(), body);
                            reply(&mut stream, 201, &[("Docker-Content-Digest", digest)], b"");
                        }
                        _ => panic!("unexpected test registry method"),
                    }
                }
            });
            Self {
                destination: ApprovedExportDestination {
                    id: "registry".into(),
                    registry,
                    repository: "team/artifact".into(),
                    immutable_tags: true,
                    allow_insecure_loopback: true,
                    ca_certificate_pem: None,
                },
                events,
                stopped,
                thread: Some(thread),
            }
        }
        pub(crate) fn credential() -> RegistryPublishCredential {
            RegistryPublishCredential::new("fixture-push-token".into()).unwrap()
        }
        fn events(&self) -> Vec<(String, String)> {
            self.events.lock().unwrap().clone()
        }
    }
    impl Drop for Peer {
        fn drop(&mut self) {
            self.stopped.store(true, Ordering::SeqCst);
            let result = self.thread.take().unwrap().join();
            if !std::thread::panicking() {
                assert!(result.is_ok(), "registry fixture failed");
            }
        }
    }
    fn read_request(stream: &mut TcpStream) -> (String, String, BTreeMap<String, String>, Vec<u8>) {
        let mut head = vec![];
        while !head.ends_with(b"\r\n\r\n") {
            assert!(head.len() < 32768);
            let mut byte = [0];
            stream.read_exact(&mut byte).unwrap();
            head.push(byte[0]);
        }
        let text = std::str::from_utf8(&head).unwrap();
        let mut lines = text.split("\r\n");
        let mut request = lines.next().unwrap().split_whitespace();
        let method = request.next().unwrap().to_owned();
        let target = request.next().unwrap().to_owned();
        let headers: BTreeMap<_, _> = lines
            .filter_map(|line| {
                line.split_once(':')
                    .map(|(key, value)| (key.to_ascii_lowercase(), value.trim().to_owned()))
            })
            .collect();
        let length = headers
            .get("content-length")
            .map(|value| value.parse::<usize>().unwrap())
            .unwrap_or(0);
        assert!(length <= METADATA_BYTES);
        let mut body = vec![0; length];
        stream.read_exact(&mut body).unwrap();
        (method, target, headers, body)
    }
    fn reply(stream: &mut TcpStream, status: u16, headers: &[(&str, String)], body: &[u8]) {
        let mut head = format!("HTTP/1.1 {status} Fixture\r\nConnection: close\r\n");
        if !headers.iter().any(|(key, _)| *key == "Content-Length") {
            head += &format!("Content-Length: {}\r\n", body.len());
        }
        for (key, value) in headers {
            head += &format!("{key}: {value}\r\n");
        }
        head += "\r\n";
        let _ = stream
            .write_all(head.as_bytes())
            .and_then(|_| stream.write_all(body));
    }
    fn packed() -> (
        tempfile::TempDir,
        Engine,
        CreationReceipt,
        Stage,
        ExportStagedFile,
    ) {
        let (temp, engine, source, mut stage, files, assets, manifest) =
            crate::export_pack::tests::fixture();
        let artifact = crate::export_pack::pack(
            &mut stage,
            &files,
            &assets,
            &manifest,
            256 * 1024 - 32,
            &budget(),
        )
        .unwrap();
        (temp, engine, source, stage, artifact)
    }
    #[test]
    fn modeled_container_pack_uses_single_attempt_registry_publication_and_exact_cleanup() {
        let peer = Peer::with_env(
            Fault::None,
            None,
            vec!["IMAGE_ONLY=private-env-value".into(), "PATH=/custom".into()],
        );
        let (temp, engine, source, mut stage, files, assets, manifest) =
            crate::export_pack::tests::container_fixture();
        let artifact = crate::export_pack::pack(
            &mut stage,
            &files,
            &assets,
            &manifest,
            256 * 1024,
            &budget(),
        )
        .unwrap();
        let plan = Plan::from_artifact(&stage, &artifact, &peer.destination, "release", &budget())
            .unwrap();
        let proof = publish(
            &mut stage,
            &artifact,
            &plan,
            &peer.destination,
            &Peer::credential(),
            &budget(),
            || Ok(()),
        )
        .unwrap();
        proof.validate(engine.binding()).unwrap();
        assert_eq!(
            engine
                .inspect_export_publication(&source, "launch-model", &"d".repeat(64), &budget())
                .unwrap(),
            Some(proof.clone())
        );
        assert!(publish(
            &mut stage,
            &artifact,
            &plan,
            &peer.destination,
            &Peer::credential(),
            &budget(),
            || Ok(())
        )
        .is_err());
        assert_eq!(peer.events().iter().filter(|(m, _)| m == "POST").count(), 2);
        assert_eq!(peer.events().iter().filter(|(m, _)| m == "PUT").count(), 5);
        assert_eq!(engine.jobs.counts().export_staging, 128 << 30);
        stage.close(&budget()).unwrap();
        assert_eq!(engine.jobs.counts().export_staging, 0);
        drop(engine);
        let reopened = crate::machine::tests::test_engine(temp.path());
        assert_eq!(
            reopened
                .inspect_export_publication(&source, "launch-model", &"d".repeat(64), &budget())
                .unwrap(),
            Some(proof)
        );
        assert!(reopened.available());
    }
    #[test]
    fn publication_streams_sdk_objects_and_records_exact_acknowledgement_without_releasing_scratch()
    {
        let peer = Peer::new(Fault::None, None);
        let (temp, engine, source, mut stage, artifact) = packed();
        let plan = Plan::from_artifact(&stage, &artifact, &peer.destination, "release", &budget())
            .unwrap();
        let proof = publish(
            &mut stage,
            &artifact,
            &plan,
            &peer.destination,
            &Peer::credential(),
            &budget(),
            || Ok(()),
        )
        .unwrap();
        proof.validate(engine.binding()).unwrap();
        assert!(
            engine
                .inspect_export_publication(&source, "pack", &"f".repeat(64), &budget())
                .unwrap()
                == Some(proof.clone())
        );
        assert!(publish(
            &mut stage,
            &artifact,
            &plan,
            &peer.destination,
            &Peer::credential(),
            &budget(),
            || Ok(())
        )
        .is_err());
        assert_eq!(
            peer.events()
                .iter()
                .filter(|(method, _)| method == "POST")
                .count(),
            2
        );
        assert_eq!(
            peer.events()
                .iter()
                .filter(|(method, _)| method == "PUT")
                .count(),
            5
        );
        assert!(engine.jobs.counts().export_staging > 0);
        let serialized = serde_json::to_string(&proof).unwrap();
        assert!(!serialized.contains("fixture-push-token"));
        assert!(!serialized.contains("private-env-value"));
        let mut bad = proof.clone();
        bad.identity.tag = "other".into();
        assert!(bad.validate(engine.binding()).is_err());
        stage.close(&budget()).unwrap();
        assert_eq!(engine.jobs.counts().export_staging, 0);
        drop(engine);
        let reopened = crate::machine::tests::test_engine(temp.path());
        assert!(
            reopened
                .inspect_export_publication(&source, "pack", &"f".repeat(64), &budget())
                .unwrap()
                == Some(proof)
        );
        assert!(reopened.available());
    }
    #[test]
    fn conflict_redirect_auth_range_digest_and_foreign_uploads_are_unknown_without_retry_or_adoption(
    ) {
        for fault in [
            Fault::Conflict,
            Fault::Redirect,
            Fault::Unauthorized,
            Fault::ForeignLocation,
            Fault::Range,
            Fault::Digest,
            Fault::OversizedAck,
        ] {
            let peer = Peer::new(fault, None);
            let (_temp, engine, source, mut stage, artifact) = packed();
            let plan =
                Plan::from_artifact(&stage, &artifact, &peer.destination, "release", &budget())
                    .unwrap();
            let error = publish(
                &mut stage,
                &artifact,
                &plan,
                &peer.destination,
                &Peer::credential(),
                &budget(),
                || Ok(()),
            )
            .unwrap_err();
            assert_eq!(error.dispatch, crate::Dispatch::MayHaveDispatched);
            assert!(engine
                .inspect_export_publication(&source, "pack", &"f".repeat(64), &budget())
                .unwrap()
                .is_none());
            let count = peer.events().len();
            assert!(count > 0);
            assert!(publish(
                &mut stage,
                &artifact,
                &plan,
                &peer.destination,
                &Peer::credential(),
                &budget(),
                || Ok(())
            )
            .is_err());
            assert_eq!(peer.events().len(), count);
            assert!(peer
                .events()
                .iter()
                .all(|(_, target)| !target.starts_with("http")));
            assert!(engine.jobs.counts().export_staging > 0);
            stage.close(&budget()).unwrap();
            assert_eq!(engine.jobs.counts().export_staging, 0);
        }
    }
    #[test]
    fn cancellation_and_failed_source_postcondition_keep_entered_publication_unresolved() {
        for cancel_during in [false, true] {
            let cancel = crate::Cancellation::default();
            let peer = Peer::new(Fault::None, cancel_during.then_some(cancel.clone()));
            let (_temp, engine, source, mut stage, artifact) = packed();
            let work = ReadBudget::for_export_work(Duration::from_secs(10), cancel).unwrap();
            let plan = Plan::from_artifact(&stage, &artifact, &peer.destination, "release", &work)
                .unwrap();
            assert!(publish(
                &mut stage,
                &artifact,
                &plan,
                &peer.destination,
                &Peer::credential(),
                &work,
                || Err(before(ErrorCode::Ownership))
            )
            .is_err());
            assert!(engine
                .inspect_export_publication(&source, "pack", &"f".repeat(64), &budget())
                .unwrap()
                .is_none());
            if cancel_during {
                assert!(!peer.events().iter().any(|(method, _)| method == "PUT"));
            } else {
                assert_eq!(
                    peer.events()
                        .iter()
                        .filter(|(method, _)| method == "PUT")
                        .count(),
                    5
                );
            }
            stage.close(&budget()).unwrap();
        }
    }
    #[test]
    fn artifact_credit_waits_for_complete_ack_and_retirement_retains_source_staging_and_control() {
        use std::sync::atomic::AtomicU64;
        use std::sync::mpsc::{self, RecvTimeoutError};
        // Incompressible private model input: the actual packed artifact must
        // exceed the command/file cap, without widening either public limit.
        let mut random = 0x7c83_19b2_d4a6_05efu64;
        let bytes: Vec<u8> = (0..17 * 1024 * 1024)
            .map(|_| {
                random ^= random << 13;
                random ^= random >> 7;
                random ^= random << 17;
                random as u8
            })
            .collect();
        for finish in ["complete", "cancel", "deadline"] {
            let (peer, paused, release) = Peer::pause_first_ack();
            let (_temp, engine, source, mut stage, files, assets, manifest) =
                crate::export_pack::tests::fixture_with_storage(&bytes, 64 << 20);
            let artifact = crate::export_pack::pack(
                &mut stage,
                &files,
                &assets,
                &manifest,
                32 << 20,
                &budget(),
            )
            .unwrap();
            assert!(artifact.size_bytes > 16 << 20);
            let plan =
                Plan::from_artifact(&stage, &artifact, &peer.destination, "release", &budget())
                    .unwrap();
            stage.prepare_publication(plan.identity).unwrap();
            stage.enter_publication().unwrap();
            let source_lease = engine.qualify_export_source(&source, &budget()).unwrap();
            let admitted = engine.jobs.counts();
            assert_eq!(admitted.export_staging, 64 << 20);
            assert_eq!(admitted.work, 1);
            assert_eq!(admitted.work_metadata, crate::JOB_METADATA_BYTES);
            let cancel = crate::Cancellation::default();
            let work = ReadBudget::for_export_work(
                Duration::from_secs(if finish == "deadline" { 3 } else { 30 }),
                cancel.clone(),
            )
            .unwrap();
            let read_bytes = AtomicU64::new(0);
            let (read_events, reads) = mpsc::channel();
            let (result_tx, result_rx) = mpsc::sync_channel(1);
            std::thread::scope(|scope| {
                let publisher = scope.spawn(|| {
                    let credential = Peer::credential();
                    let mut session = Session {
                        client: client(&peer.destination, &work).unwrap(),
                        origin: peer.destination.origin().unwrap(),
                        destination: &peer.destination,
                        credential: &credential,
                        budget: &work,
                        requests: 0,
                    };
                    let runtime = tokio::runtime::Builder::new_current_thread()
                        .enable_all()
                        .build()
                        .unwrap();
                    let result = runtime.block_on(bounded_attempt(
                        &work,
                        session.blob(&artifact.sha256, artifact.size_bytes, |offset, buffer| {
                            assert!(buffer.len() <= 256 * 1024);
                            assert_eq!(
                                read_bytes.fetch_add(buffer.len() as u64, Ordering::SeqCst),
                                offset
                            );
                            read_events.send(buffer.len()).unwrap();
                            stage.read_at("artifact.smolmachine", offset, buffer, &work)
                        }),
                    ));
                    result_tx.send(result).unwrap();
                });
                paused.recv_timeout(Duration::from_secs(5)).unwrap();
                for _ in 0..4 {
                    assert_eq!(
                        reads.recv_timeout(Duration::from_secs(1)).unwrap(),
                        256 * 1024
                    );
                }
                assert_eq!(read_bytes.load(Ordering::SeqCst), EXPORT_UPLOAD_CHUNK_BYTES);
                assert_eq!(
                    peer.events().iter().filter(|(m, _)| m == "PATCH").count(),
                    1
                );
                // Two observations remain independent of the fully charged work
                // memory/source job. A third control and another full source job reject.
                let first = engine
                    .jobs
                    .acquire(crate::jobs::Demand::export_observation())
                    .unwrap();
                let second = engine
                    .jobs
                    .acquire(crate::jobs::Demand::export_observation())
                    .unwrap();
                assert!(engine
                    .jobs
                    .acquire(crate::jobs::Demand::export_observation())
                    .is_err());
                assert!(engine
                    .jobs
                    .acquire(crate::jobs::Demand::export_source())
                    .is_err());
                drop((first, second));
                assert_eq!(engine.node_health(&budget()).unwrap().total, 1);
                source_lease.recheck(&engine).unwrap();
                assert!(engine.qualify_export_source(&source, &budget()).is_err());
                assert_eq!(engine.jobs.counts(), admitted);
                assert_eq!(
                    reads.recv_timeout(Duration::from_millis(100)),
                    Err(RecvTimeoutError::Timeout)
                );
                if finish != "complete" {
                    if finish == "cancel" {
                        cancel.cancel();
                    }
                    let error = result_rx
                        .recv_timeout(Duration::from_secs(4))
                        .unwrap()
                        .unwrap_err();
                    assert_eq!(error.code, ErrorCode::State);
                    assert_eq!(error.dispatch, crate::Dispatch::MayHaveDispatched);
                    assert_eq!(read_bytes.load(Ordering::SeqCst), EXPORT_UPLOAD_CHUNK_BYTES);
                    assert_eq!(
                        peer.events().iter().filter(|(m, _)| m == "PATCH").count(),
                        1
                    );
                    assert!(!peer.events().iter().any(|(m, _)| m == "PUT"));
                    release.send(()).unwrap();
                } else {
                    release.send(()).unwrap();
                    result_rx
                        .recv_timeout(Duration::from_secs(10))
                        .unwrap()
                        .unwrap();
                    assert_eq!(read_bytes.load(Ordering::SeqCst), artifact.size_bytes);
                    assert_eq!(
                        peer.events().iter().filter(|(m, _)| m == "PATCH").count() as u64,
                        artifact.size_bytes.div_ceil(EXPORT_UPLOAD_CHUNK_BYTES)
                    );
                    assert_eq!(peer.events().iter().filter(|(m, _)| m == "PUT").count(), 1);
                }
                publisher.join().unwrap();
            });
            assert_eq!(engine.jobs.counts(), admitted);
            assert_eq!(peer.events().iter().filter(|(m, _)| m == "POST").count(), 1);
            // A blob acknowledgement is not a complete OCI publication proof.
            assert!(engine
                .inspect_export_publication(&source, "pack", &"f".repeat(64), &budget())
                .unwrap()
                .is_none());
            source_lease.recheck(&engine).unwrap();
            stage.close(&budget()).unwrap();
            assert_eq!(engine.jobs.counts().export_staging, 0);
            assert_eq!(engine.jobs.counts().work, 1);
            assert!(engine.db.get_vm(&source.name).unwrap().is_some());
            drop(source_lease);
            assert_eq!(engine.jobs.counts(), crate::jobs::Counts::default());
        }
    }

    #[test]
    fn finite_chunk_upload_preserves_ranges_bytes_and_single_attempt() {
        let peer = Peer::new(Fault::None, None);
        let bytes: Vec<u8> = (0..UPLOAD_BYTES * 2 + 17)
            .map(|n| (n % 251) as u8)
            .collect();
        let work = budget();
        let credential = Peer::credential();
        let mut session = Session {
            client: client(&peer.destination, &work).unwrap(),
            origin: peer.destination.origin().unwrap(),
            destination: &peer.destination,
            credential: &credential,
            budget: &work,
            requests: 0,
        };
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        runtime
            .block_on(
                session.blob(&sha(&bytes), bytes.len() as u64, |offset, buffer| {
                    buffer.copy_from_slice(&bytes[offset as usize..offset as usize + buffer.len()]);
                    Ok(())
                }),
            )
            .unwrap();
        assert_eq!(
            peer.events()
                .iter()
                .filter(|(method, _)| method == "PATCH")
                .count(),
            3
        );
        assert_eq!(
            peer.events()
                .iter()
                .filter(|(method, _)| method == "POST")
                .count(),
            1
        );
        assert_eq!(
            peer.events()
                .iter()
                .filter(|(method, _)| method == "PUT")
                .count(),
            1
        );
    }
    #[test]
    fn destinations_tokens_and_tags_reject_before_network_or_intent() {
        for token in ["", "=", "with spaces", "a=b", "x\ny", "é"] {
            assert!(RegistryPublishCredential::new(token.into()).is_err());
        }
        let credential = Peer::credential();
        assert_eq!(
            format!("{credential:?}"),
            "RegistryPublishCredential(<redacted>)"
        );
        let peer = Peer::new(Fault::None, None);
        let (_temp, engine, source, mut stage, artifact) = packed();
        for tag in ["", "../tag", ":invalid", "line\nbreak", &"a".repeat(101)] {
            assert!(
                Plan::from_artifact(&stage, &artifact, &peer.destination, tag, &budget()).is_err()
            );
        }
        for change in 0..4 {
            let mut destination = peer.destination.clone();
            match change {
                0 => destination.immutable_tags = false,
                1 => destination.registry = "example.com".into(),
                2 => destination.ca_certificate_pem = Some(b"bad pem".to_vec()),
                _ => destination.repository = "../outside".into(),
            }
            assert!(destination.validate().is_err());
        }
        let plan = Plan::from_artifact(&stage, &artifact, &peer.destination, "release", &budget())
            .unwrap();
        let mut changed = peer.destination.clone();
        changed.repository = "different/repository".into();
        assert!(publish(
            &mut stage,
            &artifact,
            &plan,
            &changed,
            &credential,
            &budget(),
            || Ok(())
        )
        .is_err());
        let canceled = budget();
        canceled.cancel.cancel();
        assert!(publish(
            &mut stage,
            &artifact,
            &plan,
            &peer.destination,
            &credential,
            &canceled,
            || Ok(())
        )
        .is_err());
        assert!(peer.events().is_empty());
        assert!(engine
            .inspect_export_publication(&source, "pack", &"f".repeat(64), &budget())
            .unwrap()
            .is_none());
        stage.close(&budget()).unwrap();
    }
    #[test]
    fn shared_publication_fixture_validates_in_actual_engine_without_rewriting_canonical_authority()
    {
        let proofs: Vec<ExportPublication> = serde_json::from_str(include_str!(
            "../../smolbox-protocol/fixtures/export-publications-v1.json"
        ))
        .unwrap();
        let root = tempfile::tempdir().unwrap();
        for proof in proofs {
            let binding = crate::DomainBinding {
                target_id: proof.source.target_id.clone(),
                generation: proof.source.domain_generation.clone(),
                database: root.path().join("db"),
                vm_root: root.path().join("vms"),
            };
            proof.validate(&binding).unwrap();
            let rebuilt = ExportPublication::new(
                proof.source.clone(),
                proof.operation_id.clone(),
                proof.request_sha256.clone(),
                proof.identity.clone(),
            )
            .unwrap();
            assert!(rebuilt == proof);
            let mut bad = proof.clone();
            bad.identity.manifest_sha256 = "0".repeat(64);
            assert!(bad.validate(&binding).is_err());
        }
    }
}
