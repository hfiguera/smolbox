//! Bounded machine-local observations. These values grant no pull/source authority.
use crate::{Error, ErrorCode, Result};
use serde::{Deserialize, Serialize};

pub const IMAGE_OUTPUT_BYTES: u64 = 8 * 1024 * 1024;
pub const IMAGE_COUNT: usize = 1024;
pub const IMAGE_REPLY_BYTES: usize = 2 * 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ImageObservation {
    pub reference: String,
    pub digest: String,
    pub size: u64,
    pub architecture: String,
    pub os: String,
    pub layer_count: u64,
}
impl ImageObservation {
    pub fn validate(&self) -> Result<()> {
        let text = |s: &str, max| !s.is_empty() && s.len() <= max && !s.contains('\0');
        if !text(&self.reference, 1024)
            || !text(&self.architecture, 64)
            || !text(&self.os, 64)
            || !(self.digest == "packed"
                || self
                    .digest
                    .strip_prefix("sha256:")
                    .is_some_and(|d| crate::domain::valid_hex(d, 64)))
            || self.size > i64::MAX as u64
            || self.layer_count > 65536
        {
            return Err(Error::before(ErrorCode::Validation));
        }
        Ok(())
    }
}

// Deserialize only the HTTP projection. SDK ImageInfo's layers, environment and
// command fields are ignored without constructing their vectors/JSON values.
#[derive(Deserialize)]
struct GuestImage {
    reference: String,
    digest: String,
    size: u64,
    architecture: String,
    os: String,
    layer_count: u64,
}
impl From<GuestImage> for ImageObservation {
    fn from(i: GuestImage) -> Self {
        Self {
            reference: i.reference,
            digest: i.digest,
            size: i.size,
            architecture: i.architecture,
            os: i.os,
            layer_count: i.layer_count,
        }
    }
}

#[derive(Deserialize)]
struct Reply {
    status: String,
    #[serde(deserialize_with = "inventory")]
    data: Vec<ImageObservation>,
}
fn inventory<'de, D: serde::Deserializer<'de>>(
    decoder: D,
) -> std::result::Result<Vec<ImageObservation>, D::Error> {
    struct Visitor;
    impl<'de> serde::de::Visitor<'de> for Visitor {
        type Value = Vec<ImageObservation>;
        fn expecting(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            f.write_str("at most 1024 machine-local images")
        }
        fn visit_seq<A: serde::de::SeqAccess<'de>>(
            self,
            mut seq: A,
        ) -> std::result::Result<Self::Value, A::Error> {
            let mut values = Vec::new();
            while let Some(image) = seq.next_element::<GuestImage>()? {
                if values.len() == IMAGE_COUNT {
                    return Err(serde::de::Error::custom("image count exceeded"));
                }
                let image = ImageObservation::from(image);
                image
                    .validate()
                    .map_err(|_| serde::de::Error::custom("invalid image"))?;
                values.push(image);
            }
            Ok(values)
        }
    }
    decoder.deserialize_seq(Visitor)
}

pub(crate) fn decode_reply(bytes: &[u8]) -> Result<Vec<ImageObservation>> {
    if bytes.is_empty() || bytes.len() > IMAGE_REPLY_BYTES {
        return Err(Error::before(ErrorCode::Validation));
    }
    // Avoid an internally tagged enum here: serde buffers tagged content before
    // decoding it, which would allocate the very metadata being discarded.
    let reply: Reply =
        serde_json::from_slice(bytes).map_err(|_| Error::before(ErrorCode::Validation))?;
    if reply.status != "ok" {
        return Err(Error::before(ErrorCode::Validation));
    }
    Ok(reply.data)
}

#[derive(Deserialize)]
struct SingleReply {
    status: String,
    data: GuestImage,
}
pub(crate) fn decode_pulled(bytes: &[u8]) -> Result<ImageObservation> {
    if bytes.is_empty() || bytes.len() > IMAGE_REPLY_BYTES {
        return Err(Error::before(ErrorCode::Validation));
    }
    let reply: SingleReply =
        serde_json::from_slice(bytes).map_err(|_| Error::before(ErrorCode::Validation))?;
    if reply.status != "ok" {
        return Err(Error::before(ErrorCode::Validation));
    }
    let image = ImageObservation::from(reply.data);
    image.validate()?;
    Ok(image)
}

pub(crate) fn run(request: &crate::transfer_worker::Request) -> Result<u64> {
    use std::io::Write;
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
    let crate::transfer_worker::Kind::Images { deadline_ns } = request.kind else {
        return Err(Error::before(ErrorCode::Validation));
    };
    let remaining = std::time::Duration::from_nanos(
        deadline_ns.saturating_sub(crate::buffered::monotonic_ns()?),
    );
    if remaining.is_zero() || remaining > std::time::Duration::from_secs(30) {
        return Err(Error::before(ErrorCode::State));
    }
    let mut connection = crate::agent_io::BoundedAgent::connect_images(&request.socket)?;
    let remaining = std::time::Duration::from_nanos(
        deadline_ns.saturating_sub(crate::buffered::monotonic_ns()?),
    );
    if remaining.is_zero() {
        return Err(Error::before(ErrorCode::State));
    }
    let _timeout = connection
        .client
        .set_extended_read_timeout(remaining)
        .map_err(|_| Error::uncertain(ErrorCode::Native))?;
    // A projection relay bounds and validates the guest frame before SDK Value
    // allocation. SDK owns the public request and response protocol.
    connection
        .client
        .send_raw(&smolvm_protocol::AgentRequest::ListImages)
        .map_err(|_| Error::uncertain(ErrorCode::Native))?;
    let response = connection
        .client
        .recv_raw()
        .map_err(|_| Error::uncertain(ErrorCode::Native))?;
    let smolvm_protocol::AgentResponse::Ok { data: Some(data) } = response else {
        return Err(Error::uncertain(ErrorCode::Native));
    };
    let images: Vec<smolvm_protocol::ImageInfo> =
        serde_json::from_value(data).map_err(|_| Error::uncertain(ErrorCode::Native))?;
    let projected: Vec<_> = images
        .into_iter()
        .map(|i| ImageObservation {
            reference: i.reference,
            digest: i.digest,
            size: i.size,
            architecture: i.architecture,
            os: i.os,
            layer_count: i.layer_count as u64,
        })
        .collect();
    let bytes = serde_json::to_vec(&projected).map_err(|_| Error::uncertain(ErrorCode::Native))?;
    if bytes.len() as u64 > request.max_bytes || crate::buffered::monotonic_ns()? >= deadline_ns {
        return Err(Error::uncertain(ErrorCode::State));
    }
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(&request.staging)
        .map_err(|_| Error::uncertain(ErrorCode::Io))?;
    let meta = file
        .metadata()
        .map_err(|_| Error::uncertain(ErrorCode::Io))?;
    if (meta.dev(), meta.ino()) != (request.staging_device, request.staging_inode) {
        return Err(Error::uncertain(ErrorCode::Ownership));
    }
    file.write_all(&bytes)
        .and_then(|()| file.sync_all())
        .map_err(|_| Error::uncertain(ErrorCode::Io))?;
    Ok(bytes.len() as u64)
}

impl crate::Engine {
    /// Passive receipt-bound inventory. Never calls started_handle, start, manager
    /// initialization or readiness probes; empty does not prove cache absence.
    pub fn list_images(
        &self,
        receipt: &crate::CreationReceipt,
        budget: &crate::ReadBudget,
    ) -> Result<Vec<ImageObservation>> {
        self.with_images(receipt, budget, Ok)
    }

    /// Keep all native job/spool/ownership leases until credited forwarding ends.
    pub fn list_images_stream(
        &self,
        receipt: &crate::CreationReceipt,
        budget: &crate::ReadBudget,
        mut emit: impl FnMut(&[u8]) -> std::result::Result<(), ()>,
    ) -> Result<(u64, u64)> {
        self.with_images(receipt, budget, |images| {
            let count = images.len() as u64;
            let bytes =
                serde_json::to_vec(&images).map_err(|_| Error::uncertain(ErrorCode::Native))?;
            if bytes.len() as u64 > IMAGE_OUTPUT_BYTES {
                return Err(Error::uncertain(ErrorCode::OutputLimit));
            }
            for chunk in bytes.chunks(crate::transfer_worker::CHUNK as usize) {
                budget
                    .check()
                    .map_err(|_| Error::uncertain(ErrorCode::State))?;
                emit(chunk).map_err(|_| Error::uncertain(ErrorCode::Io))?;
            }
            budget
                .check()
                .map_err(|_| Error::uncertain(ErrorCode::State))?;
            Ok((count, bytes.len() as u64))
        })
    }

    fn with_images<T>(
        &self,
        receipt: &crate::CreationReceipt,
        budget: &crate::ReadBudget,
        consume: impl FnOnce(Vec<ImageObservation>) -> Result<T>,
    ) -> Result<T> {
        use std::io::{Read, Seek, SeekFrom};
        budget.check()?;
        receipt.validate(self.binding())?;
        let gate = self.gate(&receipt.name)?;
        let machine = gate
            .try_lock()
            .map_err(|_| Error::before(ErrorCode::Conflict))?;
        let source = self.source_lease(receipt)?;
        let record = self.image_record(receipt, budget)?;
        let state = crate::identity::record_state(&record, false);
        if self.runtime_pid(&receipt.name).is_some_and(|pid| {
            smolvm::process::is_alive(pid)
                && (record.pid != Some(pid) || state != crate::ObservedState::Running)
        }) {
            return Err(Error::before(ErrorCode::Ownership));
        }
        budget.check()?;
        match state {
            crate::ObservedState::Stopped => return consume(Vec::new()),
            crate::ObservedState::Running => {}
            _ => return Err(Error::before(ErrorCode::State)),
        }
        let supervisor = self
            .transfers
            .as_ref()
            .ok_or(Error::before(ErrorCode::Unsupported))?;
        let remaining = budget
            .deadline
            .saturating_duration_since(std::time::Instant::now());
        let deadline_ns = crate::buffered::monotonic_ns()?
            .checked_add(
                u64::try_from(remaining.as_nanos())
                    .map_err(|_| Error::before(ErrorCode::Validation))?,
            )
            .ok_or(Error::before(ErrorCode::Validation))?;
        let prepared = supervisor.prepare(
            &self.transfer_directory()?,
            self.vm_directory(&receipt.name).join("agent.sock"),
            &crate::FileOptions {
                guest_path: "/images".into(),
                max_bytes: IMAGE_OUTPUT_BYTES,
                timeout: remaining,
                mode: None,
            },
            crate::transfer_worker::Kind::Images { deadline_ns },
        )?;
        budget.check()?;
        let crate::transfer_supervisor::RunResult::Collected(mut collected) = supervisor.run(
            prepared,
            Box::new((machine, source, self.domain.clone())),
            budget.deadline,
            &budget.cancel,
        )?
        else {
            return Err(Error::uncertain(ErrorCode::Native));
        };
        if !collected.outcome.success() || !collected.outcome.native_acknowledged {
            return Err(Error::uncertain(ErrorCode::Native));
        }
        collected.prepared.spool.verify()?;
        let file = &mut collected.prepared.spool.file;
        let length = file
            .metadata()
            .map_err(|_| Error::uncertain(ErrorCode::Io))?
            .len();
        if length != collected.outcome.observed_bytes || length > IMAGE_OUTPUT_BYTES {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        file.seek(SeekFrom::Start(0))
            .map_err(|_| Error::uncertain(ErrorCode::Io))?;
        let mut bytes = Vec::new();
        file.take(IMAGE_OUTPUT_BYTES + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| Error::uncertain(ErrorCode::Io))?;
        if bytes.len() as u64 != length {
            return Err(Error::uncertain(ErrorCode::Ownership));
        }
        let images: Vec<ImageObservation> =
            serde_json::from_slice(&bytes).map_err(|_| Error::uncertain(ErrorCode::Native))?;
        if images.len() > IMAGE_COUNT || images.iter().any(|i| i.validate().is_err()) {
            return Err(Error::uncertain(ErrorCode::Native));
        }
        budget
            .check()
            .map_err(|_| Error::uncertain(ErrorCode::State))?;
        // Neither disappearance during the query nor returned image references
        // can change source approval, ownership or stopped/deletion evidence.
        let after = self
            .image_record(receipt, budget)
            .map_err(|_| Error::uncertain(ErrorCode::State))?;
        if after.pid.zip(after.pid_start_time) != record.pid.zip(record.pid_start_time)
            || crate::identity::record_state(&after, false) != crate::ObservedState::Running
        {
            return Err(Error::uncertain(ErrorCode::State));
        }
        budget
            .check()
            .map_err(|_| Error::uncertain(ErrorCode::State))?;
        consume(images)
    }
    fn image_record(
        &self,
        receipt: &crate::CreationReceipt,
        budget: &crate::ReadBudget,
    ) -> Result<smolvm::config::VmRecord> {
        let record = self
            .observation_record(&receipt.name, budget)?
            .ok_or(Error::before(ErrorCode::State))?;
        self.verify_record(receipt, &record)?;
        Ok(record)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn image() -> serde_json::Value {
        serde_json::json!({"reference":"example@sha256:abc", "digest":"packed",
            "size":0,"architecture":"arm64","os":"linux","layer_count":0,
            "layers":[{"unneeded":[1,2,3]}], "env":["secret=discarded"]})
    }
    fn reply(images: Vec<serde_json::Value>) -> Vec<u8> {
        serde_json::to_vec(&serde_json::json!({"status":"ok","data":images})).unwrap()
    }
    #[test]
    fn projection_discards_unneeded_guest_fields_and_preserves_packed_semantics() {
        let result = decode_reply(&reply(vec![image()])).unwrap();
        assert_eq!(result[0].digest, "packed");
        let public = serde_json::to_value(&result[0]).unwrap();
        assert_eq!(public.as_object().unwrap().len(), 6);
        assert_eq!(public["layerCount"], 0);
        assert!(!serde_json::to_string(&public).unwrap().contains("secret"));
        assert!(decode_reply(&reply(vec![])).unwrap().is_empty());
    }
    #[test]
    fn bounded_inventory_rejects_excess_and_invalid_observations() {
        assert_eq!(
            decode_reply(&reply(vec![image(); IMAGE_COUNT]))
                .unwrap()
                .len(),
            IMAGE_COUNT
        );
        assert!(decode_reply(&reply(vec![image(); IMAGE_COUNT + 1])).is_err());
        for (field, value) in [
            ("digest", serde_json::json!("sha256:abcd")),
            ("reference", serde_json::json!("")),
            ("os", serde_json::json!("lin\0ux")),
            ("architecture", serde_json::json!("x".repeat(65))),
            ("size", serde_json::json!(u64::MAX)),
            ("layer_count", serde_json::json!(65537)),
        ] {
            let mut i = image();
            i[field] = value;
            assert!(decode_reply(&reply(vec![i])).is_err(), "{field}");
        }
        assert!(decode_reply(&vec![b' '; IMAGE_REPLY_BYTES + 1]).is_err());
        assert!(decode_reply(br#"{"status":"error","message":"private"}"#).is_err());
    }
}
