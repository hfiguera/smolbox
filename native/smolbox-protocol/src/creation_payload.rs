//! Bounded compact UTF-8 creation intent. This codec is private to the Port
//! bridge; the engine and durable controller retain the original typed intent.
use crate::{CreationFeatures, InvalidMessage, NetworkPolicy, PortMapping, StartupWorkload};
use serde::Deserialize;
use serde_json::Value;
use std::collections::BTreeMap;

pub const MAX_CREATION_PAYLOAD: usize = 640 * 1024;
pub const MAX_CREATION_CHUNKS: usize = 10;
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Payload {
    schema: u8,
    chunks: Vec<String>,
}

pub(crate) fn expand(value: &mut Value) -> Result<bool, InvalidMessage> {
    let Some(operation) = value.get_mut("operation").and_then(Value::as_object_mut) else {
        return Ok(false);
    };
    let name = operation
        .get("operation")
        .and_then(Value::as_str)
        .ok_or(InvalidMessage)?
        .to_owned();
    let fields = if matches!(
        name.as_str(),
        "create"
            | "inspect_creation"
            | "create_oci"
            | "inspect_oci_creation"
            | "create_registry_prepared"
            | "inspect_registry_creation"
    ) {
        operation
            .get_mut("create")
            .and_then(Value::as_object_mut)
            .ok_or(InvalidMessage)?
    } else {
        operation
    };
    let Some(encoded) = fields.remove("features_payload") else {
        return Ok(false);
    };
    if !matches!(
        name.as_str(),
        "create"
            | "inspect_creation"
            | "qualify_creation"
            | "create_oci"
            | "inspect_oci_creation"
            | "qualify_oci_creation"
            | "qualify_registry_creation"
            | "create_registry_prepared"
            | "inspect_registry_creation"
    ) || fields.contains_key("features")
    {
        return Err(InvalidMessage);
    }
    let payload: Payload = serde_json::from_value(encoded).map_err(|_| InvalidMessage)?;
    if payload.schema != 1
        || payload.chunks.is_empty()
        || payload.chunks.len() > MAX_CREATION_CHUNKS
    {
        return Err(InvalidMessage);
    }
    let mut bytes = Vec::new();
    for (index, chunk) in payload.chunks.iter().enumerate() {
        let data = crate::decode_chunk(chunk)?;
        if index + 1 < payload.chunks.len() && data.len() != crate::MAX_CHUNK_BYTES {
            return Err(InvalidMessage);
        }
        if bytes.len() + data.len() > MAX_CREATION_PAYLOAD {
            return Err(InvalidMessage);
        }
        bytes.extend(data);
    }
    let features = decode(&bytes)?;
    fields.insert(
        "features".into(),
        serde_json::to_value(features).map_err(|_| InvalidMessage)?,
    );
    Ok(true)
}

fn decode(bytes: &[u8]) -> Result<CreationFeatures, InvalidMessage> {
    let mut input = Input(bytes);
    if input.take(5)? != b"SBCF\x01" {
        return Err(InvalidMessage);
    }
    let network = NetworkPolicy {
        enabled: input.flag()?,
        hosts: input.strings(32, 253)?,
        cidrs: input.strings(32, 49)?,
    };
    let count = input.count(32)?;
    let mut ports = Vec::with_capacity(count);
    for _ in 0..count {
        ports.push(PortMapping {
            host: input.u16()?,
            guest: input.u16()?,
        });
    }
    let workload = if input.flag()? {
        let entrypoint = input.strings(255, 16384)?;
        let cmd = input.strings(255, 16384)?;
        let count = input.count(64)?;
        let mut env = BTreeMap::new();
        for _ in 0..count {
            let key = input.string(128)?;
            let value = input.string(8192)?;
            if env.insert(key, value).is_some() {
                return Err(InvalidMessage);
            }
        }
        let workdir = if input.flag()? {
            Some(input.string(4096)?)
        } else {
            None
        };
        Some(StartupWorkload {
            entrypoint,
            cmd,
            env,
            workdir,
        })
    } else {
        None
    };
    if !input.0.is_empty() {
        return Err(InvalidMessage);
    }
    let features = CreationFeatures {
        branch_https: false,
        network,
        ports,
        workload,
        compact: false,
    };
    features.validate()?;
    Ok(features)
}
struct Input<'a>(&'a [u8]);
impl Input<'_> {
    fn take(&mut self, size: usize) -> Result<&[u8], InvalidMessage> {
        if size > self.0.len() {
            return Err(InvalidMessage);
        }
        let (value, rest) = self.0.split_at(size);
        self.0 = rest;
        Ok(value)
    }
    fn flag(&mut self) -> Result<bool, InvalidMessage> {
        match self.take(1)?[0] {
            0 => Ok(false),
            1 => Ok(true),
            _ => Err(InvalidMessage),
        }
    }
    fn u16(&mut self) -> Result<u16, InvalidMessage> {
        Ok(u16::from_be_bytes(
            self.take(2)?.try_into().map_err(|_| InvalidMessage)?,
        ))
    }
    fn count(&mut self, max: usize) -> Result<usize, InvalidMessage> {
        let count = self.u16()? as usize;
        if count > max {
            return Err(InvalidMessage);
        }
        Ok(count)
    }
    fn string(&mut self, max: usize) -> Result<String, InvalidMessage> {
        let size =
            u32::from_be_bytes(self.take(4)?.try_into().map_err(|_| InvalidMessage)?) as usize;
        if size > max {
            return Err(InvalidMessage);
        }
        String::from_utf8(self.take(size)?.to_vec()).map_err(|_| InvalidMessage)
    }
    fn strings(&mut self, count: usize, max: usize) -> Result<Vec<String>, InvalidMessage> {
        let size = self.count(count)?;
        (0..size).map(|_| self.string(max)).collect()
    }
}
