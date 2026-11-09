//! Bounded read-only OCI image/registry sidecar metadata transport. No SDK
//! convenience fetch, settings migration or VM launch. Operator credentials are
//! operation-local and never copied into source/result identity.
use crate::{
    Cancellation, Error, ErrorCode, ImagePullRequest, Result, VerifiedOci, OCI_METADATA_BYTES,
};
use reqwest::{header, Client, Response, StatusCode, Url};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::time::{Duration, Instant};

const TOKEN_BYTES: usize = 64 * 1024;
const CHALLENGE_BYTES: usize = 8192;
const BEARER_BYTES: usize = 16 * 1024;

struct Location {
    origin: Url,
    repository: String,
    digest: String,
    credential: crate::registry_account::Credential,
}
impl Location {
    fn new(source: &ImagePullRequest) -> Result<Self> {
        source.validate()?;
        let reference = smolvm::registry::Reference::parse(&source.reference)
            .map_err(|_| Error::before(ErrorCode::Validation))?;
        let (raw, raw_digest) = source
            .reference
            .rsplit_once('@')
            .ok_or(Error::before(ErrorCode::Validation))?;
        let (registry, repository) = raw
            .split_once('/')
            .ok_or(Error::before(ErrorCode::Validation))?;
        if reference.registry != registry
            || reference.repository() != repository
            || reference.digest.as_deref() != Some(raw_digest)
            || reference.tag.is_some()
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        // Exact documented infrastructure aliases, not suffix/mirror rewrites.
        let endpoint = match registry {
            "docker.io" => "registry-1.docker.io",
            "smolmachines.com" => "registry.smolmachines.com",
            _ => registry,
        };
        let host = endpoint.split(':').next().unwrap_or_default();
        let local = host == "localhost"
            || host
                .parse::<std::net::Ipv4Addr>()
                .is_ok_and(|address| address.is_loopback());
        let origin = Url::parse(&format!(
            "{}://{endpoint}",
            if local { "http" } else { "https" }
        ))
        .map_err(|_| Error::before(ErrorCode::Validation))?;
        let expected = endpoint.split(':').next().unwrap_or_default();
        if origin.host_str() != Some(expected)
            || !origin.username().is_empty()
            || origin.password().is_some()
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(Self {
            origin,
            repository: repository.into(),
            digest: raw_digest.into(),
            credential: crate::registry_account::Credential::Anonymous,
        })
    }
    fn with_account(
        mut self,
        reference: &str,
        family: crate::registry_account::Family,
        context: Option<crate::registry_account::Context<'_>>,
        explicit: Option<&crate::RegistryIdentityCredential>,
    ) -> Result<Self> {
        if let Some(context) = context {
            let registry = reference
                .split('/')
                .next()
                .ok_or(Error::before(ErrorCode::Validation))?;
            let selected =
                crate::registry_account::load(registry, family, explicit.is_some(), &context)?;
            self.origin = selected.origin;
            self.credential = selected.credential;
        }
        if let Some(credential) = explicit {
            credential.validate_registry(&self.origin)?;
        }
        Ok(self)
    }
    fn url(&self, kind: &str, digest: &str) -> Result<Url> {
        self.origin
            .join(&format!("v2/{}/{kind}/{digest}", self.repository))
            .map_err(|_| Error::before(ErrorCode::Validation))
    }
}

struct Challenge {
    realm: Url,
    service: Option<String>,
    scope: String,
}
impl Challenge {
    fn parse(value: &str, location: &Location) -> Result<Self> {
        Self::parse_with_credential(value, location, None)
    }
    fn parse_with_credential(
        value: &str,
        location: &Location,
        credential: Option<&crate::RegistryIdentityCredential>,
    ) -> Result<Self> {
        let invalid = || Error::before(ErrorCode::Validation);
        if value.len() > CHALLENGE_BYTES {
            return Err(invalid());
        }
        let (scheme, mut rest) = value.split_once(' ').ok_or_else(invalid)?;
        if !scheme.eq_ignore_ascii_case("bearer") {
            return Err(invalid());
        }
        let mut fields = BTreeMap::new();
        // Bounded quoted parameters; no duplicate keys, escaped URLs, alternative
        // auth schemes, registry-supplied write scopes or arbitrary destinations.
        loop {
            rest = rest.trim_start();
            let (key, tail) = rest.split_once('=').ok_or_else(invalid)?;
            let tail = tail.trim_start().strip_prefix('"').ok_or_else(invalid)?;
            let (item, tail) = tail.split_once('"').ok_or_else(invalid)?;
            if !matches!(key.trim(), "realm" | "service" | "scope")
                || item.contains('\\')
                || item.contains('\0')
                || fields.insert(key.trim(), item).is_some()
            {
                return Err(invalid());
            }
            rest = tail.trim_start();
            if rest.is_empty() {
                break;
            }
            rest = rest.strip_prefix(',').ok_or_else(invalid)?;
        }
        let realm = Url::parse(fields.get("realm").ok_or_else(invalid)?).map_err(|_| invalid())?;
        let same = realm.origin() == location.origin.origin();
        let docker_auth = location.origin.host_str() == Some("registry-1.docker.io")
            && realm.host_str() == Some("auth.docker.io")
            && realm.scheme() == "https"
            && realm.port_or_known_default() == Some(443);
        let approved = credential.is_some_and(|credential| credential.accepts(&realm))
            || (credential.is_none()
                && location.credential.approved_realm(&location.origin, &realm));
        let account_exchange = credential.is_none()
            && matches!(
                location.credential,
                crate::registry_account::Credential::Basic { .. }
                    | crate::registry_account::Credential::Identity { .. }
            );
        if (!same && !docker_auth && !approved)
            || (account_exchange && !approved)
            || !realm.username().is_empty()
            || realm.password().is_some()
            || realm.fragment().is_some()
            || realm.query().is_some()
        {
            return Err(invalid());
        }
        let scope = format!("repository:{}:pull", location.repository);
        if fields.get("scope").is_some_and(|value| *value != scope) {
            return Err(invalid());
        }
        Ok(Self {
            realm,
            service: fields.get("service").map(|value| (*value).into()),
            scope,
        })
    }
}

async fn read_body(mut response: Response, maximum: usize) -> Result<Vec<u8>> {
    if response.status() != StatusCode::OK {
        // Never buffer or disclose registry/token error bodies.
        return Err(Error::uncertain(ErrorCode::Native));
    }
    if response
        .content_length()
        .is_some_and(|size| size > maximum as u64)
    {
        return Err(Error::uncertain(ErrorCode::OutputLimit));
    }
    let mut bytes = Vec::with_capacity(maximum);
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| Error::uncertain(ErrorCode::Native))?
    {
        if chunk.len() > maximum.saturating_sub(bytes.len()) {
            return Err(Error::uncertain(ErrorCode::OutputLimit));
        }
        bytes.extend_from_slice(&chunk);
    }
    Ok(bytes)
}

async fn token(
    client: &Client,
    challenge: Challenge,
    cancel: &Cancellation,
    credential: Option<&crate::RegistryIdentityCredential>,
    account: &crate::registry_account::Credential,
) -> Result<String> {
    if cancel.is_cancelled() {
        return Err(Error::uncertain(ErrorCode::State));
    }
    let request = token_request_account(client, challenge, credential, Some(account))?;
    let response = request
        .send()
        .await
        .map_err(|_| Error::uncertain(ErrorCode::Native))?;
    let bytes = read_body(response, TOKEN_BYTES).await?;
    decode_token(&bytes)
}

#[cfg(test)]
fn token_request(
    client: &Client,
    challenge: Challenge,
    credential: Option<&crate::RegistryIdentityCredential>,
) -> Result<reqwest::RequestBuilder> {
    token_request_account(client, challenge, credential, None)
}

fn token_request_account(
    client: &Client,
    challenge: Challenge,
    credential: Option<&crate::RegistryIdentityCredential>,
    account: Option<&crate::registry_account::Credential>,
) -> Result<reqwest::RequestBuilder> {
    if credential.is_some_and(|credential| !credential.accepts(&challenge.realm)) {
        return Err(Error::uncertain(ErrorCode::Validation));
    }
    let mut url = challenge.realm;
    {
        let mut query = url.query_pairs_mut();
        if let Some(service) = &challenge.service {
            query.append_pair("service", service);
        }
        query.append_pair("scope", &challenge.scope);
    }
    let mut request = client.get(url);
    if let Some(credential) = credential {
        let mut authorization =
            header::HeaderValue::from_str(&format!("Bearer {}", credential.token()))
                .map_err(|_| Error::uncertain(ErrorCode::Validation))?;
        authorization.set_sensitive(true);
        request = request.header(header::AUTHORIZATION, authorization);
    } else if let Some(account) = account {
        use crate::registry_account::Credential;
        match account {
            Credential::Identity { token, .. } => {
                let mut value = header::HeaderValue::from_str(&format!("Bearer {token}"))
                    .map_err(|_| Error::uncertain(ErrorCode::Validation))?;
                value.set_sensitive(true);
                request = request.header(header::AUTHORIZATION, value);
            }
            Credential::Basic { username, password } => {
                request = request.basic_auth(username, Some(password));
            }
            _ => {}
        }
    }
    Ok(request)
}

fn decode_token(bytes: &[u8]) -> Result<String> {
    if bytes.is_empty() || bytes.len() > TOKEN_BYTES {
        return Err(Error::uncertain(ErrorCode::OutputLimit));
    }
    #[derive(serde::Deserialize)]
    struct Token {
        token: Option<String>,
        access_token: Option<String>,
    }
    let parsed: Token =
        serde_json::from_slice(bytes).map_err(|_| Error::uncertain(ErrorCode::Native))?;
    let token = match (parsed.token, parsed.access_token) {
        (Some(token), None) | (None, Some(token)) => token,
        (Some(token), Some(other)) if token == other => token,
        _ => return Err(Error::uncertain(ErrorCode::Native)),
    };
    if token.is_empty()
        || token.len() > BEARER_BYTES
        || token.bytes().any(|byte| !matches!(byte, 0x21..=0x7e))
    {
        return Err(Error::uncertain(ErrorCode::Native));
    }
    Ok(token)
}

async fn get(
    client: &Client,
    location: &Location,
    url: Url,
    accept: &'static str,
    maximum: usize,
    bearer: &mut Option<String>,
    cancel: &Cancellation,
) -> Result<Vec<u8>> {
    read_body(
        get_response(client, location, url, accept, bearer, cancel).await?,
        maximum,
    )
    .await
}

async fn get_response(
    client: &Client,
    location: &Location,
    url: Url,
    accept: &'static str,
    bearer: &mut Option<String>,
    cancel: &Cancellation,
) -> Result<Response> {
    get_response_with_credential(client, location, url, accept, bearer, cancel, None).await
}
async fn get_response_with_credential(
    client: &Client,
    location: &Location,
    url: Url,
    accept: &'static str,
    bearer: &mut Option<String>,
    cancel: &Cancellation,
    credential: Option<&crate::RegistryIdentityCredential>,
) -> Result<Response> {
    if cancel.is_cancelled() {
        return Err(Error::uncertain(ErrorCode::State));
    }
    let request = |bearer: &Option<String>| {
        registry_request(
            client,
            location,
            url.clone(),
            accept,
            bearer.as_deref(),
            credential,
        )
    };
    if cancel.is_cancelled() {
        return Err(Error::uncertain(ErrorCode::State));
    }
    let response = request(bearer)
        .send()
        .await
        .map_err(|_| Error::uncertain(ErrorCode::Native))?;
    if response.status() != StatusCode::UNAUTHORIZED {
        return Ok(response);
    }
    if bearer.is_some() {
        return Err(Error::uncertain(ErrorCode::Native));
    }
    let mut headers = response.headers().get_all(header::WWW_AUTHENTICATE).iter();
    let value = headers
        .next()
        .and_then(|value| value.to_str().ok())
        .ok_or(Error::uncertain(ErrorCode::Native))?;
    if headers.next().is_some() {
        return Err(Error::uncertain(ErrorCode::Native));
    }
    let challenge = if credential.is_some() {
        Challenge::parse_with_credential(value, location, credential)
    } else {
        Challenge::parse(value, location)
    }
    .map_err(|e| Error::uncertain(e.code))?;
    drop(response);
    *bearer = Some(token(client, challenge, cancel, credential, &location.credential).await?);
    // One authentication retry of the identical read, not a mutation replay.
    if cancel.is_cancelled() {
        return Err(Error::uncertain(ErrorCode::State));
    }
    let response = request(bearer)
        .send()
        .await
        .map_err(|_| Error::uncertain(ErrorCode::Native))?;
    Ok(response)
}

fn registry_request(
    client: &Client,
    location: &Location,
    url: Url,
    accept: &'static str,
    bearer: Option<&str>,
    explicit: Option<&crate::RegistryIdentityCredential>,
) -> reqwest::RequestBuilder {
    let mut request = client.get(url).header(header::ACCEPT, accept);
    if let Some(token) = bearer.or_else(|| {
        if explicit.is_none() {
            location.credential.direct_bearer()
        } else {
            None
        }
    }) {
        request = request.bearer_auth(token);
    }
    request
}

fn fetch(
    source: ImagePullRequest,
    location: Location,
    deadline: Instant,
    cancel: &Cancellation,
) -> Result<VerifiedOci> {
    bounded(deadline, cancel, |remaining| {
        fetch_documents(source, location, remaining, cancel)
    })
}

fn bounded<T, F, Fut>(deadline: Instant, cancel: &Cancellation, operation: F) -> Result<T>
where
    F: FnOnce(Duration) -> Fut,
    Fut: std::future::Future<Output = Result<T>>,
{
    let remaining = deadline.saturating_duration_since(Instant::now());
    if remaining.is_zero() || cancel.is_cancelled() {
        return Err(Error::before(ErrorCode::State));
    }
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .max_blocking_threads(1)
        .build()
        .map_err(|_| Error::before(ErrorCode::Native))?;
    // A blocked system resolver remains on this owned job; Runtime drop waits
    // for it. Caller observation can expire without releasing that job's leases.
    runtime.block_on(async {
        let operation = tokio::time::timeout_at(
            tokio::time::Instant::from_std(deadline),
            operation(remaining),
        );
        let cancelled = async {
            loop {
                if cancel.is_cancelled() {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        };
        tokio::select! {
            biased;
            _ = cancelled => Err(Error::uncertain(ErrorCode::State)),
            result = operation => result.map_err(|_| Error::uncertain(ErrorCode::State))?,
        }
    })
}

async fn fetch_documents(
    source: ImagePullRequest,
    location: Location,
    remaining: Duration,
    cancel: &Cancellation,
) -> Result<VerifiedOci> {
    let client = client(remaining)?;
    let mut bearer = None;
    let manifest = get(
        &client, &location, location.url("manifests", &location.digest)?,
        "application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json",
        OCI_METADATA_BYTES, &mut bearer, cancel,
    ).await?;
    let descriptor = VerifiedOci::configuration(&source, &manifest)?;
    let response = get_response(
        &client,
        &location,
        location.url("blobs", descriptor.digest())?,
        "application/octet-stream",
        &mut bearer,
        cancel,
    )
    .await?;
    let response = follow_blob_redirect(&client, &location, response, cancel).await?;
    let config = read_body(response, descriptor.size() as usize).await?;
    VerifiedOci::verify(source, &manifest, &config)
}

async fn follow_blob_redirect(
    client: &Client,
    location: &Location,
    response: Response,
    cancel: &Cancellation,
) -> Result<Response> {
    if response.status().is_redirection() {
        let destination = blob_redirect(location, &response)?;
        drop(response);
        if cancel.is_cancelled() {
            return Err(Error::uncertain(ErrorCode::State));
        }
        // A fresh request carries neither the registry bearer nor account
        // credentials. The client still forbids automatic/second redirects.
        Ok(client
            .get(destination)
            .header(header::ACCEPT, "application/octet-stream")
            .send()
            .await
            .map_err(|_| Error::uncertain(ErrorCode::Native))?)
    } else {
        Ok(response)
    }
}

fn blob_redirect(location: &Location, response: &Response) -> Result<Url> {
    let mut destinations = response.headers().get_all(header::LOCATION).iter();
    let destination = destinations
        .next()
        .and_then(|value| value.to_str().ok())
        .ok_or(Error::uncertain(ErrorCode::Native))?;
    if destinations.next().is_some() {
        return Err(Error::uncertain(ErrorCode::Validation));
    }
    blob_destination(location, response.status(), destination)
}

fn blob_destination(location: &Location, status: StatusCode, value: &str) -> Result<Url> {
    let invalid = || Error::uncertain(ErrorCode::Validation);
    if !matches!(
        status,
        StatusCode::TEMPORARY_REDIRECT | StatusCode::PERMANENT_REDIRECT
    ) || value.len() > CHALLENGE_BYTES
    {
        return Err(invalid());
    }
    // Match exact registry/CDN pairs for credential-free signed blob downloads.
    let host = match location.origin.as_str() {
        "https://registry-1.docker.io/" => "production.cloudfront.docker.com",
        "https://ghcr.io/" => "pkg-containers.githubusercontent.com",
        _ => return Err(invalid()),
    };
    let url = Url::parse(value).map_err(|_| invalid())?;
    if url.scheme() != "https"
        || url.host_str() != Some(host)
        || url.port_or_known_default() != Some(443)
        || !url.username().is_empty()
        || url.password().is_some()
        || url.fragment().is_some()
    {
        return Err(invalid());
    }
    Ok(url)
}

fn client(remaining: Duration) -> Result<Client> {
    Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        // Keep all retries inside the explicit bounded registry/auth protocol.
        .retry(reqwest::retry::never())
        .http1_only()
        .pool_max_idle_per_host(0)
        .no_gzip()
        .no_brotli()
        .no_deflate()
        .no_zstd()
        .timeout(remaining)
        .connect_timeout(remaining.min(Duration::from_secs(10)))
        .read_timeout(remaining.min(Duration::from_secs(30)))
        .build()
        .map_err(|_| Error::before(ErrorCode::Native))
}

async fn cache_blob(
    response: Response,
    cache: &crate::registry_artifact::RegistryCache,
    source: &crate::RegistryArtifactSource,
    descriptor: &crate::RegistryBlobDescriptor,
    deadline: Instant,
    cancel: &Cancellation,
) -> Result<()> {
    if response.status() != StatusCode::OK {
        return Err(Error::uncertain(ErrorCode::Native));
    }
    if response
        .content_length()
        .is_some_and(|size| size != descriptor.size())
    {
        return Err(Error::uncertain(ErrorCode::OutputLimit));
    }
    cache.verify()?;
    let mut staged = tempfile::NamedTempFile::new_in(cache.directory())
        .map_err(|_| Error::uncertain(ErrorCode::Io))?;
    let mut response = response;
    let mut count = 0u64;
    let mut hash = Sha256::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| Error::uncertain(ErrorCode::Native))?
    {
        if cancel.is_cancelled() || Instant::now() >= deadline {
            return Err(Error::uncertain(ErrorCode::State));
        }
        if chunk.len() as u64 > descriptor.size().saturating_sub(count) {
            return Err(Error::uncertain(ErrorCode::OutputLimit));
        }
        count += chunk.len() as u64;
        hash.update(&chunk);
        staged
            .write_all(&chunk)
            .map_err(|_| Error::uncertain(ErrorCode::Io))?;
    }
    if count != descriptor.size() || hex::encode(hash.finalize()) != source.content_sha256 {
        return Err(Error::uncertain(ErrorCode::Validation));
    }
    if cancel.is_cancelled() || Instant::now() >= deadline {
        return Err(Error::uncertain(ErrorCode::State));
    }
    staged
        .as_file()
        .sync_all()
        .map_err(|_| Error::uncertain(ErrorCode::Io))?;
    staged
        .as_file()
        .set_permissions(std::fs::Permissions::from_mode(0o400))
        .map_err(|_| Error::uncertain(ErrorCode::Io))?;
    staged
        .as_file()
        .sync_all()
        .map_err(|_| Error::uncertain(ErrorCode::Io))?;
    cache.verify()?;
    staged
        .persist_noclobber(cache.path(source))
        .map_err(|_| Error::uncertain(ErrorCode::Conflict))?;
    cache.sync()?;
    if !cache.lookup(source, descriptor.size(), deadline, cancel)? {
        return Err(Error::uncertain(ErrorCode::Validation));
    }
    Ok(())
}

impl crate::Engine {
    /// Download/rehash approved registry content in the private domain cache.
    /// This does not validate a pack's architecture or grant creation authority.
    /// The enclosing bridge selects the source and host cache allowance first.
    pub fn prepare_registry_blob(
        &self,
        source: crate::RegistryArtifactSource,
        max_bytes: u64,
        cache_policy: crate::RegistryCachePolicy,
        deadline: Instant,
        cancel: Cancellation,
    ) -> Result<crate::RegistryCachedBlob> {
        self.prepare_registry_blob_with_credential(
            source,
            max_bytes,
            cache_policy,
            deadline,
            cancel,
            None,
        )
    }

    /// Identity tokens are exchanged only at the exact host-approved HTTPS realm;
    /// neither registry reads nor persisted source/result metadata contain them.
    pub fn prepare_registry_blob_with_credential(
        &self,
        source: crate::RegistryArtifactSource,
        max_bytes: u64,
        cache_policy: crate::RegistryCachePolicy,
        deadline: Instant,
        cancel: Cancellation,
        credential: Option<crate::RegistryIdentityCredential>,
    ) -> Result<crate::RegistryCachedBlob> {
        if cancel.is_cancelled() || Instant::now() >= deadline || !self.available() {
            return Err(Error::before(ErrorCode::State));
        }
        source.validate()?;
        cache_policy.validate()?;
        if deadline.saturating_duration_since(Instant::now()) > Duration::from_secs(86400) {
            return Err(Error::before(ErrorCode::Validation));
        }
        let location = Location::new(&ImagePullRequest {
            reference: source.reference.clone(),
            platform: source.platform.clone(),
        })?;
        if let Some(credential) = &credential {
            credential.validate_registry(&location.origin)?;
        }
        self.domain.verify()?;
        let permit = self
            .jobs
            .acquire(crate::jobs::Demand::registry_download(max_bytes)?)?;
        let domain = self.domain.clone();
        let account = self.registry_account_enabled().then(|| self.jobs.clone());
        crate::oci_start::observe_owned(self.jobs.clone(), deadline, cancel.clone(), move || {
            let _lease = permit;
            domain.verify()?;
            if cancel.is_cancelled() || Instant::now() >= deadline {
                return Err(Error::before(ErrorCode::State));
            }
            let location = location.with_account(
                &source.reference,
                crate::registry_account::Family::Machines,
                account
                    .as_ref()
                    .map(|pool| crate::registry_account::Context {
                        pool,
                        deadline,
                        cancel: &cancel,
                    }),
                credential.as_ref(),
            )?;
            let job_cancel = &cancel;
            let result = bounded(deadline, &cancel, |remaining| async move {
                let client = client(remaining)?;
                let mut bearer = None;
                let response = get_response_with_credential(
                    &client,
                    &location,
                    location.url("manifests", &location.digest)?,
                    "application/vnd.oci.image.manifest.v1+json",
                    &mut bearer,
                    job_cancel,
                    credential.as_ref(),
                )
                .await?;
                let manifest = read_body(response, OCI_METADATA_BYTES).await?;
                let descriptor = source.verify_manifest(&manifest, max_bytes)?;
                if job_cancel.is_cancelled() || Instant::now() >= deadline {
                    return Err(Error::uncertain(ErrorCode::State));
                }
                let cache = crate::registry_artifact::RegistryCache::open(&domain.directory)?;
                cache.admit(0, cache_policy, deadline, job_cancel)?;
                let cached = cache.lookup(&source, descriptor.size(), deadline, job_cancel)?;
                if !cached {
                    // The metadata pool serializes registry jobs. Account every
                    // retained entry before blob dispatch; no implicit eviction.
                    cache.admit(descriptor.size(), cache_policy, deadline, job_cancel)?;
                    let response = get_response_with_credential(
                        &client,
                        &location,
                        location.url("blobs", descriptor.digest())?,
                        "application/octet-stream",
                        &mut bearer,
                        job_cancel,
                        credential.as_ref(),
                    )
                    .await?;
                    let response =
                        follow_blob_redirect(&client, &location, response, job_cancel).await?;
                    cache_blob(response, &cache, &source, &descriptor, deadline, job_cancel)
                        .await?;
                }
                domain.verify().map_err(|e| Error::uncertain(e.code))?;
                if job_cancel.is_cancelled() || Instant::now() >= deadline {
                    return Err(Error::uncertain(ErrorCode::State));
                }
                Ok(crate::RegistryCachedBlob::new(
                    cache.path(&source),
                    source,
                    descriptor.size(),
                    cached,
                ))
            })?;
            Ok(result)
        })
    }

    /// Bounded manifest observation for a pinned registry sidecar. The bridge
    /// must select an approved source first. This does not prepare/cache a pack,
    /// validate its architecture or confer creation authority. Credentials and
    /// mirrors are resolved from the verified host's operation-local account view.
    pub fn prepare_registry_descriptor(
        &self,
        source: crate::RegistryArtifactSource,
        max_bytes: u64,
        deadline: Instant,
        cancel: Cancellation,
    ) -> Result<crate::RegistryBlobDescriptor> {
        if cancel.is_cancelled() || Instant::now() >= deadline || !self.available() {
            return Err(Error::before(ErrorCode::State));
        }
        source.validate()?;
        if max_bytes == 0
            || max_bytes > 32 * 1024 * 1024 * 1024
            || deadline.saturating_duration_since(Instant::now()) > Duration::from_secs(86400)
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        let location = Location::new(&ImagePullRequest {
            reference: source.reference.clone(),
            platform: source.platform.clone(),
        })?;
        self.domain.verify()?;
        let permit = self.jobs.acquire(crate::jobs::Demand::oci_metadata())?;
        let domain = self.domain.clone();
        let account = self.registry_account_enabled().then(|| self.jobs.clone());
        crate::oci_start::observe_owned(self.jobs.clone(), deadline, cancel.clone(), move || {
            let _lease = permit;
            domain.verify()?;
            if cancel.is_cancelled() || Instant::now() >= deadline {
                return Err(Error::before(ErrorCode::State));
            }
            let location = location.with_account(
                &source.reference,
                crate::registry_account::Family::Machines,
                account
                    .as_ref()
                    .map(|pool| crate::registry_account::Context {
                        pool,
                        deadline,
                        cancel: &cancel,
                    }),
                None,
            )?;
            let job_cancel = &cancel;
            let descriptor = bounded(deadline, &cancel, |remaining| async move {
                let client = client(remaining)?;
                let manifest = get(
                    &client,
                    &location,
                    location.url("manifests", &location.digest)?,
                    "application/vnd.oci.image.manifest.v1+json",
                    OCI_METADATA_BYTES,
                    &mut None,
                    job_cancel,
                )
                .await?;
                source.verify_manifest(&manifest, max_bytes)
            })?;
            domain.verify().map_err(|e| Error::uncertain(e.code))?;
            if cancel.is_cancelled() || Instant::now() >= deadline {
                return Err(Error::uncertain(ErrorCode::State));
            }
            Ok(descriptor)
        })
    }

    /// Read exact platform-manifest/config metadata without VM or cache mutation.
    /// The enclosing bridge must first select an operator-approved source. This
    /// anonymous path grants no package feature or machine creation authority.
    pub fn prepare_oci_metadata(
        &self,
        source: ImagePullRequest,
        deadline: Instant,
        cancel: Cancellation,
    ) -> Result<VerifiedOci> {
        if cancel.is_cancelled() || Instant::now() >= deadline || !self.available() {
            return Err(Error::before(ErrorCode::State));
        }
        if deadline.saturating_duration_since(Instant::now()) > Duration::from_secs(86400) {
            return Err(Error::before(ErrorCode::Validation));
        }
        let location = Location::new(&source)?;
        self.domain.verify()?;
        let permit = self.jobs.acquire(crate::jobs::Demand::oci_metadata())?;
        let domain = self.domain.clone();
        let account = self.registry_account_enabled().then(|| self.jobs.clone());
        crate::oci_start::observe_owned(self.jobs.clone(), deadline, cancel.clone(), move || {
            let _lease = permit;
            domain.verify()?;
            if cancel.is_cancelled() {
                return Err(Error::before(ErrorCode::State));
            }
            let location = location.with_account(
                &source.reference,
                crate::registry_account::Family::Images,
                account
                    .as_ref()
                    .map(|pool| crate::registry_account::Context {
                        pool,
                        deadline,
                        cancel: &cancel,
                    }),
                None,
            )?;
            let verified = fetch(source, location, deadline, &cancel)?;
            domain.verify().map_err(|e| Error::uncertain(e.code))?;
            if cancel.is_cancelled() || Instant::now() >= deadline {
                return Err(Error::uncertain(ErrorCode::State));
            }
            Ok(verified)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sha2::{Digest, Sha256};
    use std::io::{Read, Write};
    use std::net::{TcpListener, TcpStream};

    fn source(reference: &str) -> ImagePullRequest {
        ImagePullRequest {
            reference: format!("{reference}@sha256:{}", "a".repeat(64)),
            platform: crate::oci::native_oci_platform().into(),
        }
    }

    #[test]
    fn mirror_prefix_and_account_credentials_stay_on_their_intended_requests() {
        use crate::registry_account::Credential;
        let client = client(Duration::from_secs(2)).unwrap();
        let mut location = Location::new(&source("registry.example/team/app")).unwrap();
        location.origin = Url::parse("https://mirror.example/prefix/").unwrap();
        let url = location.url("manifests", &location.digest).unwrap();
        assert!(url.path().starts_with("/prefix/v2/team/app/manifests/"));
        let explicit = crate::RegistryIdentityCredential::new(
            "explicit-private".into(),
            "https://auth.example/token",
        )
        .unwrap();
        for account in [
            Credential::Identity {
                token: "identity-private".into(),
                realm: None,
            },
            Credential::Basic {
                username: "user".into(),
                password: "password-private".into(),
            },
            Credential::Bearer("direct-private".into()),
        ] {
            location.credential = account;
            let request = registry_request(
                &client,
                &location,
                url.clone(),
                "application/json",
                None,
                None,
            )
            .build()
            .unwrap();
            match &location.credential {
                Credential::Bearer(_) => {
                    let value = &request.headers()[header::AUTHORIZATION];
                    assert_eq!(value, "Bearer direct-private");
                    assert!(value.is_sensitive());
                }
                _ => assert!(!request.headers().contains_key(header::AUTHORIZATION)),
            }
            let request = registry_request(
                &client,
                &location,
                url.clone(),
                "application/json",
                None,
                Some(&explicit),
            )
            .build()
            .unwrap();
            assert!(!request.headers().contains_key(header::AUTHORIZATION));
            let request = registry_request(
                &client,
                &location,
                url.clone(),
                "application/json",
                Some("exchanged-private"),
                Some(&explicit),
            )
            .build()
            .unwrap();
            assert_eq!(
                request.headers()[header::AUTHORIZATION],
                "Bearer exchanged-private"
            );
        }
    }

    #[test]
    fn account_exchange_guards_realms_and_sends_sensitive_auth_only_to_exchange() {
        use crate::registry_account::Credential;
        let client = client(Duration::from_secs(2)).unwrap();
        let mut location = Location::new(&source("ghcr.io/team/app")).unwrap();
        for (account, expected) in [
            (
                Credential::Basic {
                    username: "user".into(),
                    password: "pass".into(),
                },
                "Basic dXNlcjpwYXNz",
            ),
            (
                Credential::Identity {
                    token: "identity-private".into(),
                    realm: Some(Url::parse("https://ghcr.io/token").unwrap()),
                },
                "Bearer identity-private",
            ),
        ] {
            location.credential = account;
            for unapproved in [
                r#"Bearer realm="http://ghcr.io/token""#,
                r#"Bearer realm="https://other.example/token""#,
            ] {
                assert!(Challenge::parse(unapproved, &location).is_err());
            }
            let challenge = Challenge::parse(
                r#"Bearer realm="https://ghcr.io/token",scope="repository:team/app:pull""#,
                &location,
            )
            .unwrap();
            let request =
                token_request_account(&client, challenge, None, Some(&location.credential))
                    .unwrap()
                    .build()
                    .unwrap();
            let value = &request.headers()[header::AUTHORIZATION];
            assert_eq!(value, expected);
            assert!(value.is_sensitive());
            assert!(!format!("{request:?}").contains("identity-private"));
            assert_eq!(
                request.url().query(),
                Some("scope=repository%3Ateam%2Fapp%3Apull")
            );
        }
        location.credential = Credential::Bearer("direct-private".into());
        let challenge =
            Challenge::parse(r#"Bearer realm="https://ghcr.io/token""#, &location).unwrap();
        let request = token_request_account(&client, challenge, None, Some(&location.credential))
            .unwrap()
            .build()
            .unwrap();
        assert!(!request.headers().contains_key(header::AUTHORIZATION));
        let explicit = crate::RegistryIdentityCredential::new(
            "explicit-private".into(),
            "https://ghcr.io/token",
        )
        .unwrap();
        let challenge = Challenge::parse_with_credential(
            r#"Bearer realm="https://ghcr.io/token""#,
            &location,
            Some(&explicit),
        )
        .unwrap();
        let request = token_request_account(
            &client,
            challenge,
            Some(&explicit),
            Some(&location.credential),
        )
        .unwrap()
        .build()
        .unwrap();
        assert_eq!(
            request.headers()[header::AUTHORIZATION],
            "Bearer explicit-private"
        );
    }
    fn request(stream: &mut TcpStream) -> String {
        stream
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        let mut bytes = Vec::new();
        while !bytes.ends_with(b"\r\n\r\n") {
            assert!(bytes.len() < 16384);
            let mut byte = [0];
            stream.read_exact(&mut byte).unwrap();
            bytes.push(byte[0]);
        }
        String::from_utf8(bytes).unwrap()
    }

    #[test]
    fn registry_blob_redirect_requires_the_exact_https_host_pair() {
        let docker = Location::new(&source("docker.io/library/alpine")).unwrap();
        let ghcr = Location::new(&source("ghcr.io/team/app")).unwrap();
        let docker_host = "production.cloudfront.docker.com";
        let ghcr_host = "pkg-containers.githubusercontent.com";
        let other = Location::new(&source("registry.example/team/app")).unwrap();
        for (registry, host, other_host) in [
            (&docker, docker_host, ghcr_host),
            (&ghcr, ghcr_host, docker_host),
        ] {
            let endpoint = format!("https://{host}/blob?signature=private");
            for status in [
                StatusCode::TEMPORARY_REDIRECT,
                StatusCode::PERMANENT_REDIRECT,
            ] {
                assert_eq!(
                    blob_destination(registry, status, &endpoint)
                        .unwrap()
                        .as_str(),
                    endpoint
                );
            }
            for invalid in [
                format!("http://{host}/blob"),
                format!("https://{host}:444/blob"),
                format!("https://{host}.evil.example/blob"),
                format!("https://user@{host}/blob"),
                format!("https://{host}/blob#fragment"),
                format!("https://{other_host}/blob"),
            ] {
                assert!(
                    blob_destination(registry, StatusCode::TEMPORARY_REDIRECT, &invalid).is_err()
                );
            }
            assert!(blob_destination(registry, StatusCode::FOUND, &endpoint).is_err());
            assert!(blob_destination(&other, StatusCode::TEMPORARY_REDIRECT, &endpoint).is_err());
        }
        for endpoint in [
            "https://other.docker.com/blob",
            "/relative",
            "https://127.0.0.1/blob",
        ] {
            assert!(blob_destination(&docker, StatusCode::TEMPORARY_REDIRECT, endpoint).is_err());
        }
    }
    fn reply(stream: &mut TcpStream, status: &str, extra: &str, bytes: &[u8]) {
        write!(
            stream,
            "HTTP/1.1 {status}\r\nConnection: close\r\nContent-Length: {}\r\n{extra}\r\n",
            bytes.len()
        )
        .unwrap();
        stream.write_all(bytes).unwrap();
    }
    fn fixture(listener: &TcpListener, manifest: &[u8]) -> ImagePullRequest {
        ImagePullRequest {
            reference: format!(
                "127.0.0.1:{}/team/app@sha256:{}",
                listener.local_addr().unwrap().port(),
                hex::encode(Sha256::digest(manifest))
            ),
            platform: crate::oci::native_oci_platform().into(),
        }
    }

    #[test]
    fn registry_blob_errors_oversized_short_and_wrong_bytes_leave_no_published_content() {
        let blob = b"bounded-blob";
        let content = hex::encode(Sha256::digest(blob));
        let manifest=serde_json::to_vec(&serde_json::json!({
            "schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json",
            "config":{"mediaType":"application/vnd.smolmachines.machine.config.v1+json","digest":format!("sha256:{}","b".repeat(64)),"size":2},
            "layers":[{"mediaType":"application/vnd.smolmachines.smolmachine.v1","digest":format!("sha256:{content}"),"size":blob.len()}]
        })).unwrap();
        for failure in [
            "error",
            "oversized",
            "short",
            "wrong",
            "chunked",
            "redirect",
        ] {
            let temp = tempfile::tempdir().unwrap();
            let cache = crate::registry_artifact::RegistryCache::open(temp.path()).unwrap();
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let image = fixture(&listener, &manifest);
            let source = crate::RegistryArtifactSource {
                reference: image.reference.clone(),
                platform: image.platform.clone(),
                content_sha256: content.clone(),
            };
            let descriptor = source
                .verify_manifest(&manifest, blob.len() as u64)
                .unwrap();
            std::thread::scope(|scope| {
                let peer=scope.spawn(|| {
                    let (mut stream,_)=listener.accept().unwrap(); request(&mut stream);
                    match failure {
                        "error" => write!(stream,"HTTP/1.1 500 Failed\r\nConnection: close\r\nContent-Length: 999999999\r\n\r\n").unwrap(),
                        "oversized" => write!(stream,"HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: {}\r\n\r\n",blob.len()+1).unwrap(),
                        "short" => { write!(stream,"HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: {}\r\n\r\n",blob.len()).unwrap(); stream.write_all(b"short").unwrap(); },
                        "wrong" => reply(&mut stream,"200 OK","",&vec![b'x';blob.len()]),
                        "chunked" => write!(stream,"HTTP/1.1 200 OK\r\nConnection: close\r\nTransfer-Encoding: chunked\r\n\r\n10\r\n0123456789abcdef\r\n0\r\n\r\n").unwrap(),
                        "redirect" => reply(&mut stream,"307 Temporary Redirect","Location: https://production.cloudfront.docker.com/unauthorized\r\n",b""),
                        _ => unreachable!(),
                    }
                });
                let cancel = Cancellation::new();
                let deadline = Instant::now() + Duration::from_secs(3);
                let location = Location::new(&image).unwrap();
                let client = client(Duration::from_secs(3)).unwrap();
                let result = bounded(deadline, &cancel, |_remaining| async {
                    let response = get_response(
                        &client,
                        &location,
                        location.url("blobs", descriptor.digest())?,
                        "application/octet-stream",
                        &mut None,
                        &cancel,
                    )
                    .await?;
                    let response =
                        follow_blob_redirect(&client, &location, response, &cancel).await?;
                    cache_blob(response, &cache, &source, &descriptor, deadline, &cancel).await
                });
                assert!(result.is_err(), "{failure}");
                peer.join().unwrap();
            });
            assert_eq!(
                std::fs::read_dir(cache.directory()).unwrap().count(),
                0,
                "{failure}"
            );
        }
    }

    #[test]
    fn explicit_registry_blob_cancellation_removes_private_partial_without_publication() {
        let temp = tempfile::tempdir().unwrap();
        let cache = crate::registry_artifact::RegistryCache::open(temp.path()).unwrap();
        let blob = b"bounded-blob";
        let content = hex::encode(Sha256::digest(blob));
        let manifest=serde_json::to_vec(&serde_json::json!({
            "schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json",
            "config":{"mediaType":"application/vnd.smolmachines.machine.config.v1+json","digest":format!("sha256:{}","b".repeat(64)),"size":2},
            "layers":[{"mediaType":"application/vnd.smolmachines.smolmachine.v1","digest":format!("sha256:{content}"),"size":blob.len()}]
        })).unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let image = fixture(&listener, &manifest);
        let source = crate::RegistryArtifactSource {
            reference: image.reference.clone(),
            platform: image.platform.clone(),
            content_sha256: content,
        };
        let descriptor = source
            .verify_manifest(&manifest, blob.len() as u64)
            .unwrap();
        let cancel = Cancellation::new();
        let (finish_send, finish) = std::sync::mpsc::sync_channel(1);
        std::thread::scope(|scope| {
            let peer = scope.spawn(move || {
                let (mut stream, _) = listener.accept().unwrap();
                request(&mut stream);
                write!(
                    stream,
                    "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: {}\r\n\r\n",
                    blob.len()
                )
                .unwrap();
                stream.write_all(&blob[..1]).unwrap();
                finish.recv_timeout(Duration::from_secs(3)).unwrap();
            });
            let trigger = scope.spawn(|| {
                let until = Instant::now() + Duration::from_secs(2);
                while std::fs::read_dir(cache.directory()).unwrap().count() == 0 {
                    assert!(Instant::now() < until);
                    std::thread::sleep(Duration::from_millis(1));
                }
                cancel.cancel();
            });
            let location = Location::new(&image).unwrap();
            let deadline = Instant::now() + Duration::from_secs(3);
            let client = client(Duration::from_secs(3)).unwrap();
            assert!(bounded(deadline, &cancel, |_| async {
                let response = get_response(
                    &client,
                    &location,
                    location.url("blobs", descriptor.digest())?,
                    "application/octet-stream",
                    &mut None,
                    &cancel,
                )
                .await?;
                cache_blob(response, &cache, &source, &descriptor, deadline, &cancel).await
            })
            .is_err());
            trigger.join().unwrap();
            finish_send.send(()).unwrap();
            peer.join().unwrap();
        });
        assert_eq!(std::fs::read_dir(cache.directory()).unwrap().count(), 0);
    }

    #[test]
    fn source_locations_preserve_pinned_repositories_and_only_exact_infrastructure_aliases() {
        for (registry, endpoint) in [
            ("docker.io", "https://registry-1.docker.io"),
            ("smolmachines.com", "https://registry.smolmachines.com"),
            ("registry.example", "https://registry.example"),
            ("localhost:5000", "http://localhost:5000"),
            ("127.0.0.2:5000", "http://127.0.0.2:5000"),
            ("10.0.0.1:5000", "https://10.0.0.1:5000"),
            (
                "unrelatedsmolmachines.com",
                "https://unrelatedsmolmachines.com",
            ),
        ] {
            let location = Location::new(&source(&format!("{registry}/team/app"))).unwrap();
            assert_eq!(location.origin.as_str(), format!("{endpoint}/"));
            assert_eq!(location.repository, "team/app");
            assert_eq!(location.digest, format!("sha256:{}", "a".repeat(64)));
        }
        assert!(Location::new(&source("127.000.0.1/team/app")).is_err());
    }

    #[test]
    fn anonymous_challenges_cannot_expand_destinations_scopes_or_forward_credentials() {
        let location = Location::new(&source("registry.example/team/app")).unwrap();
        let accepted = Challenge::parse(r#"Bearer realm="https://registry.example/token",service="registry.example",scope="repository:team/app:pull""#, &location).unwrap();
        assert_eq!(accepted.scope, "repository:team/app:pull");
        for value in [
            r#"Bearer realm="https://other.example/token""#,
            r#"Bearer realm="http://registry.example/token""#,
            r#"Bearer realm="https://user:secret@registry.example/token""#,
            r#"Bearer realm="https://registry.example/token#extra""#,
            r#"Bearer realm="https://registry.example/token?scope=write""#,
            r#"Bearer realm="https://registry.example/token",scope="repository:team/app:pull,push""#,
            r#"Bearer realm="https://registry.example/token",scope="repository:other/app:pull""#,
            r#"Bearer realm="https://registry.example/token",realm="https://registry.example/other""#,
            r#"Basic realm="https://registry.example/token""#,
        ] {
            assert!(Challenge::parse(value, &location).is_err());
        }
        let docker = Location::new(&source("docker.io/library/app")).unwrap();
        assert!(
            Challenge::parse(r#"Bearer realm="https://auth.docker.io/token""#, &docker).is_ok()
        );
        assert!(Challenge::parse(
            r#"Bearer realm="https://auth.docker.io:444/token""#,
            &docker
        )
        .is_err());
    }

    #[test]
    fn credential_challenges_require_exact_operator_realm_and_read_only_repository_scope() {
        let location = Location::new(&source("registry.example/team/app")).unwrap();
        let credential = crate::RegistryIdentityCredential::new(
            "private-identity".into(),
            "https://auth.example/exchange",
        )
        .unwrap();
        let approved = Challenge::parse_with_credential(
            r#"Bearer realm="https://auth.example/exchange",scope="repository:team/app:pull""#,
            &location,
            Some(&credential),
        )
        .unwrap();
        assert!(credential.accepts(&approved.realm));
        assert!(
            Challenge::parse(r#"Bearer realm="https://auth.example/exchange""#, &location).is_err()
        );
        for value in [
            r#"Bearer realm="https://auth.example/other""#,
            r#"Bearer realm="https://auth.example/exchange",scope="repository:team/app:pull,push""#,
            r#"Bearer realm="https://auth.example/exchange",scope="repository:other/app:pull""#,
        ] {
            assert!(Challenge::parse_with_credential(value, &location, Some(&credential)).is_err());
        }
        // A same-origin anonymous realm is not authorization to send identity.
        let same = Challenge::parse_with_credential(
            r#"Bearer realm="https://registry.example/token""#,
            &location,
            Some(&credential),
        )
        .unwrap();
        assert!(!credential.accepts(&same.realm));
    }

    #[test]
    fn unapproved_token_endpoint_receives_no_identity_request() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let credential = crate::RegistryIdentityCredential::new(
            "private-identity".into(),
            "https://auth.example/exchange",
        )
        .unwrap();
        let challenge = Challenge {
            realm: Url::parse(&format!(
                "http://127.0.0.1:{}/token",
                listener.local_addr().unwrap().port()
            ))
            .unwrap(),
            service: None,
            scope: "repository:team/app:pull".into(),
        };
        let cancel = Cancellation::new();
        assert!(bounded(
            Instant::now() + Duration::from_secs(2),
            &cancel,
            |remaining| async move {
                token(
                    &client(remaining)?,
                    challenge,
                    &Cancellation::new(),
                    Some(&credential),
                    &crate::registry_account::Credential::Anonymous,
                )
                .await
            }
        )
        .is_err());
        listener.set_nonblocking(true).unwrap();
        assert_eq!(
            listener.accept().unwrap_err().kind(),
            std::io::ErrorKind::WouldBlock
        );
    }

    #[test]
    fn identity_exchange_request_is_exact_scoped_and_rotation_has_no_shared_state() {
        let client = client(Duration::from_secs(2)).unwrap();
        for secret in ["identity-one", "identity-two"] {
            let credential = crate::RegistryIdentityCredential::new(
                secret.into(),
                "https://auth.example/exchange",
            )
            .unwrap();
            let location = Location::new(&source("registry.example/team/app")).unwrap();
            let challenge=Challenge::parse_with_credential(r#"Bearer realm="https://auth.example/exchange",service="registry.example",scope="repository:team/app:pull""#,&location,Some(&credential)).unwrap();
            let request = token_request(&client, challenge, Some(&credential))
                .unwrap()
                .build()
                .unwrap();
            assert_eq!(request.url().as_str(),"https://auth.example/exchange?service=registry.example&scope=repository%3Ateam%2Fapp%3Apull");
            assert_eq!(
                request.headers()[header::AUTHORIZATION],
                format!("Bearer {secret}")
            );
            assert!(!format!("{:?}", request.headers()).contains(secret));
            assert!(request.body().is_none());
        }
        for body in [
            br#"{"token":"one","access_token":"two"}"#.as_slice(),
            br#"{"error":"private-provider-detail"}"#.as_slice(),
            br#"{"token":"line\nbreak"}"#.as_slice(),
        ] {
            let error = decode_token(body).err().unwrap();
            assert!(!format!("{error:?}").contains("private"));
        }
        assert_eq!(
            decode_token(br#"{"token":"same","access_token":"same"}"#).unwrap(),
            "same"
        );
    }

    #[test]
    fn ordinary_registry_fixture_fetches_exact_manifest_then_config_without_vm_or_cache_entry() {
        let (_, manifest, config) = crate::oci::tests::bytes();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let source = fixture(&listener, &manifest);
        let location = Location::new(&source).unwrap();
        let paths = [
            location
                .url("manifests", &location.digest)
                .unwrap()
                .path()
                .to_string(),
            location
                .url(
                    "blobs",
                    &format!("sha256:{}", hex::encode(Sha256::digest(&config))),
                )
                .unwrap()
                .path()
                .to_string(),
        ];
        std::thread::scope(|scope| {
            let peer = scope.spawn(|| {
                for (path, body) in paths.iter().zip([&manifest, &config]) {
                    let (mut stream, _) = listener.accept().unwrap();
                    let request = request(&mut stream);
                    assert!(request.starts_with(&format!("GET {path} HTTP/1.1\r\n")));
                    assert!(!request.to_ascii_lowercase().contains("authorization:"));
                    reply(&mut stream, "200 OK", "", body);
                }
            });
            let verified = fetch(
                source.clone(),
                location,
                Instant::now() + Duration::from_secs(5),
                &Cancellation::new(),
            )
            .unwrap();
            assert!(verified.source() == &source);
            assert_eq!(verified.layer_count(), 0);
            peer.join().unwrap();
        });
    }

    #[test]
    fn ordinary_anonymous_token_exchange_retries_only_the_same_pinned_read_and_reuses_no_global_state(
    ) {
        let (_, manifest, config) = crate::oci::tests::bytes();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let source = fixture(&listener, &manifest);
        let location = Location::new(&source).unwrap();
        std::thread::scope(|scope| {
            let peer = scope.spawn(|| {
                for stage in 0..4 {
                    let (mut stream, _) = listener.accept().unwrap();
                    let request = request(&mut stream);
                    match stage {
                        0 => {
                            assert!(request.starts_with(&format!("GET /v2/team/app/manifests/{} HTTP/1.1", location.digest)));
                            assert!(!request.to_ascii_lowercase().contains("authorization:"));
                            reply(&mut stream, "401 Unauthorized", &format!("WWW-Authenticate: Bearer realm=\"{}token\",scope=\"repository:team/app:pull\"\r\n", location.origin), b"");
                        }
                        1 => {
                            assert!(request.starts_with("GET /token?scope=repository%3Ateam%2Fapp%3Apull HTTP/1.1"));
                            assert!(!request.to_ascii_lowercase().contains("authorization:"));
                            reply(&mut stream, "200 OK", "", br#"{"token":"fixture-anonymous"}"#);
                        }
                        2 | 3 => {
                            assert!(request.to_ascii_lowercase().contains("authorization: bearer fixture-anonymous\r\n"));
                            if stage == 2 { assert!(request.starts_with(&format!("GET /v2/team/app/manifests/{} HTTP/1.1", location.digest))); }
                            else { assert!(request.starts_with("GET /v2/team/app/blobs/sha256:")); }
                            reply(&mut stream, "200 OK", "", if stage == 2 { &manifest } else { &config });
                        }
                        _ => unreachable!(),
                    }
                }
            });
            assert!(fetch(
                source.clone(),
                Location::new(&source).unwrap(),
                Instant::now() + Duration::from_secs(5),
                &Cancellation::new()
            )
            .is_ok());
            peer.join().unwrap();
        });
    }

    #[test]
    fn oversized_headers_error_bodies_redirects_and_changed_manifests_never_select_a_config_request(
    ) {
        let (_, manifest, _) = crate::oci::tests::bytes();
        for failure in ["oversized", "error", "redirect", "changed"] {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let source = fixture(&listener, &manifest);
            std::thread::scope(|scope| {
                let peer = scope.spawn(|| {
                    let (mut stream, _) = listener.accept().unwrap();
                    request(&mut stream);
                    match failure {
                        "oversized" => write!(stream, "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: {}\r\n\r\n", OCI_METADATA_BYTES + 1).unwrap(),
                        "error" => write!(stream, "HTTP/1.1 500 Failed\r\nConnection: close\r\nContent-Length: 999999999\r\n\r\n").unwrap(),
                        "redirect" => reply(&mut stream, "302 Found", "Location: /must-not-follow\r\n", b""),
                        "changed" => { let mut changed = manifest.clone(); changed.push(b' '); reply(&mut stream, "200 OK", "", &changed); }
                        _ => unreachable!(),
                    }
                });
                assert!(fetch(
                    source.clone(),
                    Location::new(&source).unwrap(),
                    Instant::now() + Duration::from_secs(5),
                    &Cancellation::new()
                )
                .is_err());
                peer.join().unwrap();
            });
            listener.set_nonblocking(true).unwrap();
            assert_eq!(
                listener.accept().unwrap_err().kind(),
                std::io::ErrorKind::WouldBlock
            );
        }
    }

    #[test]
    fn absolute_deadline_and_explicit_cancellation_end_stalled_read_without_a_second_request() {
        for cancelled in [false, true] {
            let (_, manifest, _) = crate::oci::tests::bytes();
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let source = fixture(&listener, &manifest);
            let cancel = Cancellation::new();
            let (entered_send, entered) = std::sync::mpsc::sync_channel(1);
            let (finish_send, finish) = std::sync::mpsc::sync_channel(1);
            std::thread::scope(|scope| {
                let peer = scope.spawn(move || {
                    let (mut stream, _) = listener.accept().unwrap();
                    request(&mut stream);
                    entered_send.send(()).unwrap();
                    finish.recv_timeout(Duration::from_secs(3)).unwrap();
                });
                let deadline = Instant::now()
                    + if cancelled {
                        Duration::from_secs(2)
                    } else {
                        Duration::from_millis(100)
                    };
                let job_cancel = cancel.clone();
                let job = scope.spawn(move || {
                    fetch(
                        source.clone(),
                        Location::new(&source).unwrap(),
                        deadline,
                        &job_cancel,
                    )
                });
                entered.recv_timeout(Duration::from_secs(2)).unwrap();
                if cancelled {
                    cancel.cancel();
                }
                assert!(job.join().unwrap().is_err());
                finish_send.send(()).unwrap();
                peer.join().unwrap();
            });
        }
    }
}
