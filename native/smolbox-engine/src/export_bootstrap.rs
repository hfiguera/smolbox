//! Isolated conversion worker I/O. Frozen metadata selects guest operations;
//! it never supplies source, helper/worker ownership or publication authority.
use crate::{ContainerExportPlan, ContainerLayerIo, Error, ErrorCode, ReadBudget, Result};
use serde::{Deserialize, Serialize};
use smolvm_protocol::{AgentRequest, AgentResponse};
use std::fs::File;
use std::io::{BufReader, Read};
use std::path::Path;
use std::time::{Duration, Instant};

pub(crate) const METADATA_BYTES: usize = 8 * 1024 * 1024;
const CONTROL_BYTES: usize = 64 * 1024;
pub(crate) const PLAN_BYTES: u64 = (METADATA_BYTES + crate::AGENT_REQUEST_BYTES) as u64;
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Expected {
    pub input_sha256: String,
    pub maximum: u64,
}
impl Expected {
    pub(crate) fn validate(&self) -> Result<()> {
        if !crate::domain::valid_hex(&self.input_sha256, 64)
            || self.maximum == 0
            || self.maximum > crate::JOB_EXPORT_STAGING_BYTES
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(())
    }
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Proof {
    pub input_sha256: String,
    pub bytes: u64,
    pub sha256: String,
    pub plan_bytes: u64,
    pub plan_sha256: String,
}
impl Proof {
    pub(crate) fn matches(&self, expected: &Expected) -> bool {
        self.input_sha256 == expected.input_sha256
            && self.bytes > 0
            && self.bytes <= expected.maximum
            && self.plan_bytes > 0
            && self.plan_bytes <= PLAN_BYTES
            && crate::domain::valid_hex(&self.sha256, 64)
            && crate::domain::valid_hex(&self.plan_sha256, 64)
    }
}
const MOUNT: &str = "mkdir -p /mnt/source-storage && mount -o ro /dev/vdc /mnt/source-storage";
const CACHE: &str = "for dir in layers configs manifests; do mount --bind /mnt/source-storage/$dir /storage/$dir; done";

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ContainerConversionInput {
    schema: u32,
    record: smolvm::config::VmRecord,
    record_sha256: String,
    maximum: u64,
    deadline_ns: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    imported: Option<crate::export_import::Snapshot>,
}
impl std::fmt::Debug for ContainerConversionInput {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ContainerConversionInput")
            .finish_non_exhaustive()
    }
}
/// Guest protocol evidence only. The parent must collect the actual worker,
/// recheck its source and independently verify/register the private output file.
pub struct ContainerConversionIo {
    pub input_sha256: String,
    pub plan: ContainerExportPlan,
    pub layer: ContainerLayerIo,
}
impl ContainerConversionInput {
    pub(crate) fn expected(&self) -> Result<Expected> {
        self.validate()?;
        Ok(Expected {
            input_sha256: crate::material::hash(self)?,
            maximum: self.maximum,
        })
    }
    pub(crate) fn from_record(
        record: smolvm::config::VmRecord,
        maximum: u64,
        budget: &ReadBudget,
    ) -> Result<Self> {
        Self::from_source(record, maximum, budget, None)
    }
    pub(crate) fn from_source(
        record: smolvm::config::VmRecord,
        maximum: u64,
        budget: &ReadBudget,
        imported: Option<crate::export_import::Snapshot>,
    ) -> Result<Self> {
        budget.check()?;
        let now = crate::buffered::monotonic_ns()?;
        let remaining = u64::try_from(
            budget
                .deadline
                .saturating_duration_since(Instant::now())
                .as_nanos(),
        )
        .map_err(|_| Error::before(ErrorCode::Validation))?;
        let input = Self {
            schema: 1,
            record_sha256: crate::material::hash(&record)?,
            record,
            maximum,
            deadline_ns: now
                .checked_add(remaining)
                .ok_or(Error::before(ErrorCode::Validation))?,
            imported,
        };
        input.validate()?;
        Ok(input)
    }
    fn validate(&self) -> Result<()> {
        if self.schema != 1
            || self.record_sha256 != crate::material::hash(&self.record)?
            || !crate::domain::valid_id(&self.record.name)
            || self.maximum == 0
            || self.maximum > crate::JOB_EXPORT_STAGING_BYTES
            || self.record.state != smolvm::config::RecordState::Stopped
            || self.record.pid.is_some()
            || self.record.pid_start_time.is_some()
            || self.record.paused_checkpoint.is_some()
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        if let Some(imported) = &self.imported {
            imported.validate(&self.record)?;
        } else {
            crate::export_container::registry_source(&self.record)?;
        }
        if serde_json::to_vec(self)
            .map_err(|_| Error::before(ErrorCode::Validation))?
            .len()
            > METADATA_BYTES
        {
            return Err(Error::before(ErrorCode::OutputLimit));
        }
        self.remaining()?;
        Ok(())
    }
    fn remaining(&self) -> Result<Duration> {
        let now = crate::buffered::monotonic_ns()?;
        let remaining = self
            .deadline_ns
            .checked_sub(now)
            .filter(|n| *n > 0)
            .ok_or(Error::before(ErrorCode::State))?;
        let remaining = Duration::from_nanos(remaining);
        if remaining > Duration::from_secs(86400) {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(remaining)
    }
}
// A direct struct visitor keeps sequence limits ahead of allocation. Serde's
// internally tagged enum would first buffer the complete body as Content.
enum CachedReply {
    Ok {
        data: Option<Box<crate::export_container::CachedImage>>,
    },
    Error,
}
impl<'de> Deserialize<'de> for CachedReply {
    fn deserialize<D: serde::Deserializer<'de>>(decoder: D) -> std::result::Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(rename_all = "snake_case")]
        enum Status {
            Ok,
            Error,
        }
        fn present<'de, D: serde::Deserializer<'de>>(
            decoder: D,
        ) -> std::result::Result<bool, D::Error> {
            serde::de::IgnoredAny::deserialize(decoder)?;
            Ok(true)
        }
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Reply {
            status: Status,
            data: Option<Box<crate::export_container::CachedImage>>,
            #[serde(default, deserialize_with = "present")]
            message: bool,
            #[serde(default, deserialize_with = "present")]
            code: bool,
        }
        let reply = Reply::deserialize(decoder)?;
        match reply.status {
            Status::Ok if !reply.message && !reply.code => Ok(Self::Ok { data: reply.data }),
            Status::Error if reply.message && reply.data.is_none() => Ok(Self::Error),
            _ => Err(serde::de::Error::custom("invalid cached reply")),
        }
    }
}

fn reply<T: serde::de::DeserializeOwned>(
    reader: &mut impl Read,
    cap: usize,
    budget: &ReadBudget,
) -> Result<T> {
    let mut header = [0; 4];
    reader
        .read_exact(&mut header)
        .map_err(|_| Error::uncertain(ErrorCode::Native))?;
    let size = u32::from_be_bytes(header) as usize;
    if size == 0 || size > cap {
        return Err(Error::uncertain(ErrorCode::OutputLimit));
    }
    // Streaming typed decode avoids constructing an unbounded serde Value tree
    // or a duplicate large body. CachedImage bounds each sequence before growth.
    let mut frame = reader.take(size as u64);
    let result = serde_json::from_reader(BufReader::with_capacity(64 * 1024, &mut frame))
        .map_err(|_| Error::uncertain(ErrorCode::Validation))?;
    if frame.limit() != 0 {
        return Err(Error::uncertain(ErrorCode::Validation));
    }
    budget.check().map_err(|e| Error::uncertain(e.code))?;
    Ok(result)
}
fn command(socket: &Path, script: &str, budget: &ReadBudget) -> Result<()> {
    budget.check()?;
    let timeout_ms = u64::try_from(
        budget
            .deadline
            .saturating_duration_since(Instant::now())
            .as_millis(),
    )
    .map_err(|_| Error::before(ErrorCode::Validation))?
    .max(1);
    let request = AgentRequest::VmExec {
        command: vec!["sh".into(), "-ec".into(), script.into()],
        env: vec![],
        workdir: None,
        timeout_ms: Some(timeout_ms),
        interactive: false,
        tty: false,
        background: false,
        stdin_data: None,
    };
    let mut reader = crate::export_stream::connect_request(socket, &request, budget)?;
    match reply::<AgentResponse>(&mut reader, CONTROL_BYTES, budget)? {
        AgentResponse::Completed { exit_code: 0, .. } => Ok(()),
        _ => Err(Error::uncertain(ErrorCode::Native)),
    }
}
/// Run only in the isolated owned conversion worker, with its parent-retained
/// source/job leases and authenticated helper socket. No pulls/rebase, arbitrary
/// shell or source boot is performed. Imported tar staging uses fixed private
/// guest paths and bounded streaming parts. Results grant no host custody.
pub fn run_container_conversion(
    input: &ContainerConversionInput,
    socket: &Path,
    output: &mut File,
    budget: &ReadBudget,
) -> Result<ContainerConversionIo> {
    budget.check()?;
    input.validate()?;
    crate::export_stream::validate_output(output)?;
    let budget = ReadBudget {
        deadline: budget.deadline.min(Instant::now() + input.remaining()?),
        cancel: budget.cancel.clone(),
    };
    let input_sha256 = crate::material::hash(input)?;
    // Open, pin, rehash and inspect the original imported sidecar before any
    // guest request. Parent source/FD/domain leases remain held through collection.
    let imported = input
        .imported
        .as_ref()
        .map(|snapshot| crate::export_import::Pack::from_snapshot(snapshot, &input.record, &budget))
        .transpose()?;
    command(socket, MOUNT, &budget)?;
    let plan = if let Some(pack) = &imported {
        stage_imported(pack, socket, &budget).map_err(|e| Error::uncertain(e.code))?;
        ContainerExportPlan::from_imported(&input.record, input.imported.as_ref().unwrap())?
    } else {
        command(socket, CACHE, &budget).map_err(|e| Error::uncertain(e.code))?;
        let query = AgentRequest::Query {
            image: crate::export_container::registry_source(&input.record)?.into(),
        };
        let mut reader = crate::export_stream::connect_request(socket, &query, &budget)
            .map_err(|e| Error::uncertain(e.code))?;
        let cached = match reply::<CachedReply>(&mut reader, METADATA_BYTES, &budget)? {
            CachedReply::Ok { data: Some(image) } => *image,
            _ => return Err(Error::uncertain(ErrorCode::Ownership)),
        };
        drop(reader);
        ContainerExportPlan::from_image(&input.record, cached)
            .map_err(|e| Error::uncertain(e.code))?
    };
    let layer =
        crate::stream_container_layer(socket, plan.request(), output, input.maximum, &budget)
            .map_err(|e| Error::uncertain(e.code))?;
    Ok(ContainerConversionIo {
        input_sha256,
        plan,
        layer,
    })
}

fn upload_part(
    socket: &Path,
    path: String,
    source: &mut dyn Read,
    bytes: u64,
    budget: &ReadBudget,
) -> Result<()> {
    if bytes == 0 || bytes > smolvm_protocol::FILE_TRANSFER_MAX_TOTAL {
        return Err(Error::before(ErrorCode::OutputLimit));
    }
    let mut peer = crate::export_stream::connect_request(
        socket,
        &AgentRequest::FileWriteBegin {
            path,
            mode: Some(0o400),
            uid: None,
            gid: None,
            total_size: bytes,
        },
        budget,
    )?;
    let ok = |peer: &mut crate::export_stream::Timed<'_>| -> Result<()> {
        match reply::<AgentResponse>(peer, CONTROL_BYTES, budget)? {
            AgentResponse::Ok { data: None } => Ok(()),
            _ => Err(Error::uncertain(ErrorCode::Native)),
        }
    };
    ok(&mut peer)?;
    let mut remaining = bytes;
    let mut buffer = vec![0; 64 * 1024];
    while remaining > 0 {
        budget.check().map_err(|e| Error::uncertain(e.code))?;
        let count = remaining.min(buffer.len() as u64) as usize;
        source
            .read_exact(&mut buffer[..count])
            .map_err(|_| Error::uncertain(ErrorCode::Io))?;
        remaining -= count as u64;
        peer.send(&AgentRequest::FileWriteChunk {
            data: buffer[..count].to_vec(),
            done: remaining == 0,
        })?;
        ok(&mut peer)?;
    }
    budget.check().map_err(|e| Error::uncertain(e.code))
}
fn part_layout(bytes: u64) -> Result<Vec<(String, u64)>> {
    if bytes == 0 || bytes > 128u64 << 30 {
        return Err(Error::before(ErrorCode::OutputLimit));
    }
    let mut parts = Vec::new();
    let mut remaining = bytes;
    while remaining > 0 {
        let bytes = remaining.min(smolvm_protocol::FILE_TRANSFER_MAX_TOTAL);
        parts.push((
            format!("/storage/imported/input/part-{:03}", parts.len()),
            bytes,
        ));
        remaining -= bytes;
    }
    Ok(parts)
}
fn stage_imported(
    pack: &crate::export_import::Pack,
    socket: &Path,
    budget: &ReadBudget,
) -> Result<()> {
    use sha2::{Digest, Sha256};
    struct Hashed<'a> {
        source: &'a mut dyn Read,
        hash: Sha256,
    }
    impl Read for Hashed<'_> {
        fn read(&mut self, bytes: &mut [u8]) -> std::io::Result<usize> {
            let count = self.source.read(bytes)?;
            self.hash.update(&bytes[..count]);
            Ok(count)
        }
    }
    command(
        socket,
        "mkdir /storage/imported && mkdir /storage/imported/input /storage/imported/layers",
        budget,
    )?;
    let mut failure = None;
    let result = pack.stream_layers(budget, &mut |path, bytes, source| {
        let outcome = (|| -> Result<()> {
            let digest = path.strip_prefix("layers/").and_then(|s| s.strip_suffix(".tar"))
                .filter(|s| crate::domain::valid_hex(s, 64)).ok_or(Error::before(ErrorCode::Validation))?;
            let mut source = Hashed { source, hash: Sha256::new() };
            let mut paths = Vec::new();
            for (path, part) in part_layout(bytes)? {
                upload_part(socket, path.clone(), &mut source, part, budget)?;
                paths.push(path);
            }
            if hex::encode(source.hash.finalize()) != digest { return Err(Error::uncertain(ErrorCode::Ownership)); }
            pack.verify(budget)?;
            let paths = paths.join(" ");
            command(socket, &format!("set -o pipefail && mkdir /storage/imported/layers/{digest} && (cat {paths} | tar xf - -C /storage/imported/layers/{digest}) && rm {paths}"), budget)
        })();
        if let Err(error) = outcome {
            failure = Some(error);
            return Err(std::io::Error::other("imported guest staging"));
        }
        Ok(())
    });
    if let Some(error) = failure {
        return Err(error);
    }
    result
}

/// Runs only after the parent has frozen metadata and retained helper authority.
/// Both writable descriptors are opened and checked before any guest request.
pub(crate) fn run_worker(
    request: &crate::transfer_worker::Request,
    metadata: &crate::transfer_worker::Blob,
    plan: &crate::transfer_worker::Blob,
    expected: &Expected,
) -> Result<Proof> {
    request.validate()?;
    let input: ContainerConversionInput = metadata.read(request.owner, METADATA_BYTES as u64)?;
    if input.expected()? != *expected {
        return Err(Error::before(ErrorCode::Ownership));
    }
    let mut output = writable(
        &request.staging,
        request.staging_device,
        request.staging_inode,
        request.owner.uid,
    )?;
    let mut plan_output = writable(&plan.path, plan.device, plan.inode, request.owner.uid)?;
    let budget = ReadBudget::for_export_work(input.remaining()?, crate::Cancellation::default())?;
    let result = run_container_conversion(&input, &request.socket, &mut output, &budget)?;
    let bytes =
        serde_json::to_vec(&result.plan).map_err(|_| Error::uncertain(ErrorCode::Validation))?;
    if bytes.is_empty() || bytes.len() as u64 > PLAN_BYTES {
        return Err(Error::uncertain(ErrorCode::OutputLimit));
    }
    use sha2::{Digest, Sha256};
    use std::io::Write;
    plan_output
        .write_all(&bytes)
        .and_then(|()| plan_output.sync_all())
        .map_err(|_| Error::uncertain(ErrorCode::Io))?;
    budget.check().map_err(|e| Error::uncertain(e.code))?;
    Ok(Proof {
        input_sha256: result.input_sha256,
        bytes: result.layer.bytes,
        sha256: result.layer.sha256,
        plan_bytes: bytes.len() as u64,
        plan_sha256: hex::encode(Sha256::digest(&bytes)),
    })
}
fn writable(path: &Path, device: u64, inode: u64, uid: u32) -> Result<File> {
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
    crate::host::unredirected(path)?;
    crate::host::private_directory(path.parent().ok_or(Error::before(ErrorCode::Ownership))?)?;
    let mut file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(path)
        .map_err(|_| Error::before(ErrorCode::Io))?;
    let info = file.metadata().map_err(|_| Error::before(ErrorCode::Io))?;
    if (info.dev(), info.ino()) != (device, inode) || info.uid() != uid {
        return Err(Error::before(ErrorCode::Ownership));
    }
    crate::export_stream::validate_output(&mut file)?;
    Ok(file)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::Cancellation;
    use sha2::Digest;
    use std::io::Write;
    use std::os::unix::net::UnixListener;
    fn budget() -> ReadBudget {
        ReadBudget::for_export_work(Duration::from_secs(10), Cancellation::default()).unwrap()
    }
    type ImportedFixture = (
        tempfile::TempDir,
        crate::Engine,
        crate::PreparedContainerExport,
        ContainerConversionInput,
        Vec<(String, Vec<u8>)>,
    );
    pub(crate) fn imported_fixture(budget: &ReadBudget) -> ImportedFixture {
        let temp = tempfile::tempdir_in("/tmp").unwrap();
        let (mut manifest, mut files) = crate::export_import::tests::payload();
        // Exercise multiple bounded upload chunks, not just a tiny tar.
        let mut archive = tar::Builder::new(Vec::new());
        let data = vec![b'x'; 256 * 1024];
        let mut header = tar::Header::new_gnu();
        header.set_size(data.len() as u64);
        header.set_mode(0o644);
        header.set_cksum();
        archive
            .append_data(&mut header, "usr/large", data.as_slice())
            .unwrap();
        let data = archive.into_inner().unwrap();
        let digest = hex::encode(sha2::Sha256::digest(&data));
        let original = manifest.assets.layers[1].path.clone();
        let path = format!("layers/{digest}.tar");
        *files.iter_mut().find(|(p, _)| p == &original).unwrap() = (path.clone(), data.clone());
        manifest.assets.layers[1] = smolvm_pack::format::LayerEntry {
            path,
            digest: format!("sha256:{digest}"),
            size: data.len() as u64,
        };
        let bytes = crate::export_import::tests::sidecar(&manifest, &files);
        let (engine, receipt, _) =
            crate::export_import::tests::fixture(temp.path(), "artifacts", &bytes, &manifest.image);
        let root = engine.vm_directory(&receipt.name);
        let disk = crate::disk_geometry::tests::raw(&root);
        std::fs::rename(disk, root.join(smolvm::storage::STORAGE_DISK_FILENAME)).unwrap();
        let mut source = engine
            .qualify_export_source(&receipt, budget)
            .unwrap()
            .prepare_container_export(&engine)
            .unwrap();
        source
            .reserve_conversion(
                &engine,
                &crate::ExportConversionResources {
                    slots: 1,
                    cpus: 4,
                    memory_mb: 4608,
                    disk_gb: 128,
                },
                1 << 30,
                128 << 30,
            )
            .unwrap();
        let input = source.conversion_input(&engine).unwrap();
        (temp, engine, source, input, files)
    }
    pub(crate) fn imported_peer(
        listener: UnixListener,
        files: Vec<(String, Vec<u8>)>,
        fail_upload: bool,
    ) -> std::thread::JoinHandle<Vec<AgentRequest>> {
        imported_peer_with_deadline(listener, files, fail_upload, None)
    }
    pub(crate) fn imported_peer_until(
        listener: UnixListener,
        files: Vec<(String, Vec<u8>)>,
        fail_upload: bool,
        deadline: Instant,
    ) -> std::thread::JoinHandle<Vec<AgentRequest>> {
        imported_peer_with_deadline(listener, files, fail_upload, Some(deadline))
    }
    fn imported_peer_with_deadline(
        listener: UnixListener,
        files: Vec<(String, Vec<u8>)>,
        fail_upload: bool,
        operation_deadline: Option<Instant>,
    ) -> std::thread::JoinHandle<Vec<AgentRequest>> {
        std::thread::spawn(move || {
            listener.set_nonblocking(true).unwrap();
            let mut requests = Vec::new();
            let mut uploaded = Vec::new();
            let expected: Vec<_> = files
                .into_iter()
                .filter(|(p, _)| p.starts_with("layers/"))
                .collect();
            let mut flattened = false;
            let connection_count = if fail_upload {
                3
            } else {
                3 + 2 * expected.len()
            };
            for _ in 0..connection_count {
                let deadline =
                    operation_deadline.unwrap_or_else(|| Instant::now() + Duration::from_secs(5));
                let (mut peer, _) = loop {
                    match listener.accept() {
                        Ok(peer) => break peer,
                        Err(error)
                            if error.kind() == std::io::ErrorKind::WouldBlock
                                && Instant::now() < deadline =>
                        {
                            std::thread::sleep(Duration::from_millis(2))
                        }
                        Err(error) => panic!("imported peer did not receive next request: {error}"),
                    }
                };
                peer.set_nonblocking(false).unwrap();
                peer.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
                let read = |peer: &mut std::os::unix::net::UnixStream| {
                    let mut header = [0; 4];
                    peer.read_exact(&mut header).unwrap();
                    let size = u32::from_be_bytes(header) as usize;
                    assert!(size <= crate::AGENT_REQUEST_BYTES);
                    let mut bytes = vec![0; size];
                    peer.read_exact(&mut bytes).unwrap();
                    serde_json::from_slice::<AgentRequest>(&bytes).unwrap()
                };
                let request = read(&mut peer);
                match &request {
                    AgentRequest::VmExec { command, .. } => {
                        assert_eq!(&command[..2], &["sh", "-ec"]);
                        assert!(
                            !command[2].contains("/packed_layers")
                                && !command[2].contains("/storage/layers/")
                        );
                        peer.write_all(&wire(AgentResponse::Completed {
                            exit_code: 0,
                            stdout: vec![],
                            stderr: vec![],
                        }))
                        .unwrap();
                    }
                    AgentRequest::FileWriteBegin {
                        total_size,
                        path,
                        mode,
                        ..
                    } => {
                        assert!(
                            *total_size <= smolvm_protocol::FILE_TRANSFER_MAX_TOTAL
                                && *total_size > 0
                        );
                        assert_eq!(path, "/storage/imported/input/part-000");
                        assert_eq!(*mode, Some(0o400));
                        if fail_upload {
                            peer.write_all(&wire(AgentResponse::Completed {
                                exit_code: 1,
                                stdout: vec![],
                                stderr: vec![],
                            }))
                            .unwrap();
                        } else {
                            peer.write_all(&wire(AgentResponse::Ok { data: None }))
                                .unwrap();
                            let mut bytes = Vec::new();
                            loop {
                                let chunk = read(&mut peer);
                                let AgentRequest::FileWriteChunk { data, done } = &chunk else {
                                    panic!("not an upload chunk")
                                };
                                assert!(!data.is_empty() && data.len() <= 64 * 1024);
                                bytes.extend_from_slice(data);
                                let done = *done;
                                requests.push(chunk);
                                peer.write_all(&wire(AgentResponse::Ok { data: None }))
                                    .unwrap();
                                if done {
                                    break;
                                }
                            }
                            assert_eq!(bytes.len() as u64, *total_size);
                            uploaded.push(bytes);
                        }
                    }
                    AgentRequest::FlattenLayers { lowerdirs, output } => {
                        assert!(output.is_none());
                        assert!(
                            lowerdirs[0].starts_with("/mnt/source-storage/overlays/persistent-")
                        );
                        assert!(lowerdirs
                            .iter()
                            .skip(1)
                            .all(|p| p.starts_with("/storage/imported/layers/")));
                        peer.write_all(&wire(AgentResponse::DataChunk {
                            data: expected[0].1.clone(),
                            done: true,
                        }))
                        .unwrap();
                        flattened = true;
                    }
                    _ => panic!("unexpected imported conversion request"),
                }
                requests.push(request);
            }
            if !fail_upload {
                assert!(flattened);
                assert_eq!(
                    uploaded,
                    expected
                        .into_iter()
                        .map(|(_, bytes)| bytes)
                        .collect::<Vec<_>>()
                );
            }
            requests
        })
    }
    #[test]
    fn imported_conversion_stages_verified_tars_without_cached_query_and_preserves_plan_order() {
        let b = budget();
        let (temp, engine, source, input, files) = imported_fixture(&b);
        let socket = temp.path().join("agent.sock");
        let peer = imported_peer(UnixListener::bind(&socket).unwrap(), files, false);
        let mut output = tempfile::NamedTempFile::new().unwrap();
        let result = run_container_conversion(&input, &socket, output.as_file_mut(), &b).unwrap();
        let requests = peer.join().unwrap();
        assert_eq!(
            requests
                .iter()
                .filter(|r| matches!(r, AgentRequest::VmExec { .. }))
                .count(),
            4
        );
        assert_eq!(result.input_sha256, input.expected().unwrap().input_sha256);
        let expected =
            ContainerExportPlan::from_imported(&input.record, input.imported.as_ref().unwrap())
                .unwrap();
        assert_eq!(
            crate::material::hash(&result.plan).unwrap(),
            crate::material::hash(&expected).unwrap()
        );
        source.recheck(&engine).unwrap();
        assert_eq!(engine.jobs.counts().work, 1);
        assert_eq!(engine.jobs.counts().children, 2);
    }
    #[test]
    fn imported_upload_rejection_stops_before_extract_and_flatten() {
        let b = budget();
        let (temp, _engine, _source, input, files) = imported_fixture(&b);
        let socket = temp.path().join("agent.sock");
        let peer = imported_peer(UnixListener::bind(&socket).unwrap(), files, true);
        let mut output = tempfile::NamedTempFile::new().unwrap();
        assert!(run_container_conversion(&input, &socket, output.as_file_mut(), &b).is_err());
        assert_eq!(peer.join().unwrap().len(), 3);
        assert_eq!(output.as_file().metadata().unwrap().len(), 0);
    }
    #[test]
    fn changed_imported_input_rejects_before_connecting_and_parts_cover_large_tars_without_raising_sdk_cap(
    ) {
        let b = budget();
        let (temp, _engine, _source, input, _files) = imported_fixture(&b);
        let socket = temp.path().join("agent.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        listener.set_nonblocking(true).unwrap();
        let snapshot = input.imported.as_ref().unwrap();
        let value = serde_json::to_value(snapshot).unwrap();
        let path = Path::new(value["path"].as_str().unwrap());
        std::fs::hard_link(path, path.with_extension("linked")).unwrap();
        let mut output = tempfile::NamedTempFile::new().unwrap();
        assert!(run_container_conversion(&input, &socket, output.as_file_mut(), &b).is_err());
        assert_eq!(
            listener.accept().unwrap_err().kind(),
            std::io::ErrorKind::WouldBlock
        );
        let parts = part_layout(5u64 << 30).unwrap();
        assert_eq!(parts.len(), 2);
        assert_eq!(parts[0].1, smolvm_protocol::FILE_TRANSFER_MAX_TOTAL);
        assert_eq!(parts[1].1, 1 << 30);
        assert_eq!(part_layout(128u64 << 30).unwrap().len(), 32);
        assert!(part_layout(0).is_err() && part_layout(u64::MAX).is_err());
    }
    pub(crate) fn record() -> smolvm::config::VmRecord {
        let mut r = smolvm::config::VmRecord::new("source".into(), 1, 512, vec![], vec![], false);
        r.state = smolvm::config::RecordState::Stopped;
        r.image = Some(format!(
            "registry.example/team/app@sha256:{}",
            "a".repeat(64)
        ));
        r.storage_gb = Some(1);
        r.overlay_gb = Some(1);
        r
    }
    pub(crate) fn cached() -> smolvm_protocol::ImageInfo {
        smolvm_protocol::ImageInfo {
            reference: record().image.unwrap(),
            digest: format!("sha256:{}", "a".repeat(64)),
            size: 1024,
            created: None,
            architecture: crate::oci::native_oci_platform()
                .rsplit('/')
                .next()
                .unwrap()
                .into(),
            os: "linux".into(),
            layer_count: 2,
            layers: vec![
                format!("sha256:{}", "b".repeat(64)),
                format!("sha256:{}", "c".repeat(64)),
            ],
            entrypoint: vec![],
            cmd: vec![],
            env: vec!["IMAGE=preserved".into()],
            workdir: None,
            user: Some("123".into()),
        }
    }
    fn wire(r: AgentResponse) -> Vec<u8> {
        smolvm_protocol::encode_message(&r).unwrap()
    }
    fn completed(code: i32) -> Vec<Vec<u8>> {
        vec![wire(AgentResponse::Completed {
            exit_code: code,
            stdout: vec![],
            stderr: vec![],
        })]
    }
    pub(crate) fn peer(
        listener: UnixListener,
        responses: Vec<Vec<Vec<u8>>>,
    ) -> std::thread::JoinHandle<Vec<AgentRequest>> {
        peer_with_deadline(listener, responses, None)
    }
    pub(crate) fn peer_until(
        listener: UnixListener,
        responses: Vec<Vec<Vec<u8>>>,
        deadline: Instant,
    ) -> std::thread::JoinHandle<Vec<AgentRequest>> {
        peer_with_deadline(listener, responses, Some(deadline))
    }
    fn peer_with_deadline(
        listener: UnixListener,
        responses: Vec<Vec<Vec<u8>>>,
        operation_deadline: Option<Instant>,
    ) -> std::thread::JoinHandle<Vec<AgentRequest>> {
        std::thread::spawn(move || {
            listener.set_nonblocking(true).unwrap();
            let mut requests = Vec::new();
            for frames in responses {
                let until =
                    operation_deadline.unwrap_or_else(|| Instant::now() + Duration::from_secs(3));
                let mut socket = loop {
                    match listener.accept() {
                        Ok((socket, _)) => break socket,
                        Err(e)
                            if e.kind() == std::io::ErrorKind::WouldBlock
                                && Instant::now() < until =>
                        {
                            std::thread::sleep(Duration::from_millis(2))
                        }
                        Err(e) => panic!("loopback accept: {e}"),
                    }
                };
                socket.set_nonblocking(false).unwrap();
                socket
                    .set_read_timeout(Some(Duration::from_secs(3)))
                    .unwrap();
                socket
                    .set_write_timeout(Some(Duration::from_secs(3)))
                    .unwrap();
                let mut header = [0; 4];
                socket.read_exact(&mut header).unwrap();
                let count = u32::from_be_bytes(header) as usize;
                assert!(count <= crate::AGENT_REQUEST_BYTES);
                let mut bytes = vec![0; count];
                socket.read_exact(&mut bytes).unwrap();
                requests.push(serde_json::from_slice(&bytes).unwrap());
                for frame in frames {
                    if socket.write_all(&frame).is_err() {
                        break;
                    }
                }
            }
            requests
        })
    }
    fn worker_request(
        root: &Path,
        input: &ContainerConversionInput,
    ) -> (
        crate::transfer_worker::Request,
        Vec<tempfile::NamedTempFile>,
    ) {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        let bytes = serde_json::to_vec(input).unwrap();
        let mut metadata = tempfile::NamedTempFile::new_in(root).unwrap();
        metadata.write_all(&bytes).unwrap();
        metadata
            .as_file()
            .set_permissions(std::fs::Permissions::from_mode(0o400))
            .unwrap();
        let output = tempfile::NamedTempFile::new_in(root).unwrap();
        let plan = tempfile::NamedTempFile::new_in(root).unwrap();
        let blob = |file: &tempfile::NamedTempFile, bytes: u64| {
            let m = file.as_file().metadata().unwrap();
            crate::transfer_worker::Blob {
                path: file.path().into(),
                device: m.dev(),
                inode: m.ino(),
                bytes,
            }
        };
        let output_blob = blob(&output, 0);
        let request = crate::transfer_worker::Request {
            schema: 1,
            operation: "a".repeat(32),
            owner: crate::OwnerIdentity::capture().unwrap(),
            socket: root.join("agent.sock"),
            staging: output_blob.path,
            staging_device: output_blob.device,
            staging_inode: output_blob.inode,
            guest_path: "/workspace/.smolbox-conversion".into(),
            max_bytes: input.maximum,
            kind: crate::transfer_worker::Kind::Conversion {
                metadata: blob(&metadata, bytes.len() as u64),
                plan: blob(&plan, PLAN_BYTES),
                expected: input.expected().unwrap(),
            },
        };
        (request, vec![metadata, output, plan])
    }
    #[test]
    fn worker_binds_two_spools_to_frozen_input_and_checks_writable_identity_before_guest_entry() {
        use sha2::{Digest, Sha256};
        use std::os::unix::fs::PermissionsExt;
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap();
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
        let budget = budget();
        let original = record();
        let input = ContainerConversionInput::from_record(original.clone(), 1024, &budget).unwrap();
        let (request, _files) = worker_request(&root, &input);
        let crate::transfer_worker::Kind::Conversion {
            metadata,
            plan,
            expected,
        } = &request.kind
        else {
            unreachable!()
        };
        let listener = UnixListener::bind(&request.socket).unwrap();
        let bad = Expected {
            input_sha256: "e".repeat(64),
            ..expected.clone()
        };
        assert_eq!(
            run_worker(&request, metadata, plan, &bad)
                .err()
                .unwrap()
                .code,
            ErrorCode::Ownership
        );
        let mut changed = plan.clone();
        changed.inode += 1;
        assert_eq!(
            run_worker(&request, metadata, &changed, expected)
                .err()
                .unwrap()
                .code,
            ErrorCode::Ownership
        );
        let server = peer(
            listener,
            vec![
                completed(0),
                completed(0),
                vec![wire(AgentResponse::Ok {
                    data: Some(serde_json::to_value(cached()).unwrap()),
                })],
                vec![wire(AgentResponse::DataChunk {
                    data: b"owned layer".to_vec(),
                    done: true,
                })],
            ],
        );
        let proof = run_worker(&request, metadata, plan, expected).unwrap();
        assert_eq!(server.join().unwrap().len(), 4);
        assert!(proof.matches(expected));
        assert_eq!(proof.bytes, 11);
        assert_eq!(proof.sha256, hex::encode(Sha256::digest(b"owned layer")));
        let bytes = std::fs::read(&plan.path).unwrap();
        assert_eq!(proof.plan_bytes, bytes.len() as u64);
        assert_eq!(proof.plan_sha256, hex::encode(Sha256::digest(&bytes)));
        let decoded: ContainerExportPlan = serde_json::from_slice(&bytes).unwrap();
        decoded.validate(&original).unwrap();
        let mut changed_record = original;
        changed_record.name = "foreign".into();
        assert!(decoded.validate(&changed_record).is_err());
        assert!(run_worker(&request, metadata, plan, expected).is_err()); // Spools are no longer empty.
    }

    #[test]
    fn fixed_mount_cache_query_and_flatten_preserve_sdk_precedence_and_metadata() {
        let temp = tempfile::tempdir().unwrap();
        let socket = temp.path().join("agent.sock");
        let server = peer(
            UnixListener::bind(&socket).unwrap(),
            vec![
                completed(0),
                completed(0),
                vec![wire(AgentResponse::Ok {
                    data: Some(serde_json::to_value(cached()).unwrap()),
                })],
                vec![
                    wire(AgentResponse::DataChunk {
                        data: b"private archive bytes".to_vec(),
                        done: false,
                    }),
                    wire(AgentResponse::DataChunk {
                        data: vec![],
                        done: true,
                    }),
                ],
            ],
        );
        let budget = budget();
        let record = record();
        let input = ContainerConversionInput::from_record(record.clone(), 1024, &budget).unwrap();
        let mut output = tempfile::NamedTempFile::new_in(temp.path()).unwrap();
        let result =
            run_container_conversion(&input, &socket, output.as_file_mut(), &budget).unwrap();
        let requests = server.join().unwrap();
        assert_eq!(requests.len(), 4);
        for (request, script) in requests[..2].iter().zip([MOUNT, CACHE]) {
            match request {
                AgentRequest::VmExec {
                    command,
                    env,
                    timeout_ms,
                    interactive,
                    tty,
                    background,
                    stdin_data,
                    ..
                } => {
                    assert_eq!(
                        command,
                        &vec!["sh".to_string(), "-ec".to_string(), script.to_string()]
                    );
                    assert!(env.is_empty() && timeout_ms.is_some());
                    assert!(!interactive && !tty && !background && stdin_data.is_none());
                }
                _ => panic!("unexpected setup request"),
            }
        }
        assert!(
            matches!(&requests[2], AgentRequest::Query { image } if Some(image) == record.image.as_ref())
        );
        assert_eq!(
            serde_json::to_vec(&requests[3]).unwrap(),
            serde_json::to_vec(result.plan.request()).unwrap()
        );
        assert_eq!(result.layer.bytes, 21);
        assert_eq!(result.input_sha256, crate::material::hash(&input).unwrap());
        let manifest = result
            .plan
            .seed_manifest(&record, result.layer.bytes)
            .unwrap();
        assert!(manifest.env.iter().any(|v| v == "IMAGE=preserved"));
        assert_eq!(manifest.user.as_deref(), Some("123"));
    }
    #[test]
    fn mount_failure_missing_cache_and_foreign_digest_never_dispatch_flatten() {
        for variant in 0..4 {
            let temp = tempfile::tempdir().unwrap();
            let socket = temp.path().join("agent.sock");
            let responses = match variant {
                0 => vec![completed(1)],
                1 => vec![completed(0), completed(1)],
                2 => vec![
                    completed(0),
                    completed(0),
                    vec![wire(AgentResponse::Error {
                        code: Some("NOT_FOUND".into()),
                        message: "missing".into(),
                    })],
                ],
                _ => {
                    let mut image = cached();
                    image.digest = format!("sha256:{}", "d".repeat(64));
                    vec![
                        completed(0),
                        completed(0),
                        vec![wire(AgentResponse::Ok {
                            data: Some(serde_json::to_value(image).unwrap()),
                        })],
                    ]
                }
            };
            let count = responses.len();
            let server = peer(UnixListener::bind(&socket).unwrap(), responses);
            let budget = budget();
            let input = ContainerConversionInput::from_record(record(), 1024, &budget).unwrap();
            let mut output = tempfile::NamedTempFile::new_in(temp.path()).unwrap();
            assert!(
                run_container_conversion(&input, &socket, output.as_file_mut(), &budget).is_err()
            );
            assert_eq!(server.join().unwrap().len(), count);
            assert_eq!(output.as_file().metadata().unwrap().len(), 0);
        }
    }
    #[test]
    fn cached_header_cap_precedes_allocation_and_empty_archive_is_unqualified() {
        for oversize in [false, true] {
            let temp = tempfile::tempdir().unwrap();
            let socket = temp.path().join("agent.sock");
            let mut responses = vec![completed(0), completed(0)];
            if oversize {
                responses.push(vec![((METADATA_BYTES + 1) as u32).to_be_bytes().to_vec()]);
            } else {
                responses.push(vec![wire(AgentResponse::Ok {
                    data: Some(serde_json::to_value(cached()).unwrap()),
                })]);
                responses.push(vec![wire(AgentResponse::DataChunk {
                    data: vec![],
                    done: true,
                })]);
            }
            let server = peer(UnixListener::bind(&socket).unwrap(), responses);
            let budget = budget();
            let input = ContainerConversionInput::from_record(record(), 1024, &budget).unwrap();
            let mut output = tempfile::NamedTempFile::new_in(temp.path()).unwrap();
            assert!(
                run_container_conversion(&input, &socket, output.as_file_mut(), &budget).is_err()
            );
            server.join().unwrap();
            assert_eq!(output.as_file().metadata().unwrap().len(), 0);
        }
    }
    #[test]
    fn frozen_hash_deadline_cancel_and_spool_reject_before_guest_mount() {
        let temp = tempfile::tempdir().unwrap();
        let budget = budget();
        let input = ContainerConversionInput::from_record(record(), 1024, &budget).unwrap();
        for variant in 0..4 {
            let mut input = input.clone();
            let mut output = tempfile::NamedTempFile::new_in(temp.path()).unwrap();
            match variant {
                0 => input.record.name = "changed".into(),
                1 => input.deadline_ns = 1,
                2 => input.maximum = 0,
                _ => {
                    output.as_file_mut().write_all(b"existing").unwrap();
                }
            }
            assert_eq!(
                run_container_conversion(
                    &input,
                    Path::new("/absent"),
                    output.as_file_mut(),
                    &budget
                )
                .err()
                .unwrap()
                .dispatch,
                crate::Dispatch::NotDispatched
            );
        }
        budget.cancel.cancel();
        let mut output = tempfile::NamedTempFile::new_in(temp.path()).unwrap();
        assert_eq!(
            run_container_conversion(&input, Path::new("/absent"), output.as_file_mut(), &budget)
                .err()
                .unwrap()
                .code,
            ErrorCode::State
        );
    }
}
