//! Compact buffered command input; decoded fields retain ordinary validation.
use crate::{BufferedCommand, InvalidMessage};
use serde::Deserialize;
use serde_json::Value;
use std::collections::BTreeMap;
pub const COMMAND_PAYLOAD_BYTES: usize = 704 * 1024;
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Payload {
    schema: u8,
    chunks: Vec<String>,
}
pub(crate) fn expand(value: &mut Value) -> Result<(), InvalidMessage> {
    let Some(op) = value.get_mut("operation").and_then(Value::as_object_mut) else {
        return Ok(());
    };
    let Some(encoded) = op.remove("command_payload") else {
        return Ok(());
    };
    if !matches!(
        op.get("operation").and_then(Value::as_str),
        Some("exec_buffered" | "exec_background" | "exec_stream")
    ) || op.contains_key("command")
    {
        return Err(InvalidMessage);
    }
    let payload: Payload = serde_json::from_value(encoded).map_err(|_| InvalidMessage)?;
    if payload.schema != 1 || payload.chunks.is_empty() || payload.chunks.len() > 11 {
        return Err(InvalidMessage);
    }
    let mut bytes = Vec::new();
    for (index, chunk) in payload.chunks.iter().enumerate() {
        let data = crate::decode_chunk(chunk)?;
        if index + 1 < payload.chunks.len() && data.len() != crate::MAX_CHUNK_BYTES {
            return Err(InvalidMessage);
        }
        if bytes.len() + data.len() > COMMAND_PAYLOAD_BYTES {
            return Err(InvalidMessage);
        }
        bytes.extend(data);
    }
    let mut input = Input(&bytes);
    if input.take(5)? != b"SBCM\x01" {
        return Err(InvalidMessage);
    }
    let count = input.count(256)?;
    let argv = (0..count)
        .map(|_| input.string(16384))
        .collect::<Result<Vec<_>, _>>()?;
    let count = input.count(64)?;
    let mut env = BTreeMap::new();
    for _ in 0..count {
        let key = input.string(128)?;
        let value = input.string(8192)?;
        if env.insert(key, value).is_some() {
            return Err(InvalidMessage);
        }
    }
    let workdir = input.optional(4096)?;
    let user = input.optional(128)?;
    let stdin = input.optional(65536)?;
    let max_output_bytes =
        u64::from_be_bytes(input.take(8)?.try_into().map_err(|_| InvalidMessage)?);
    if !input.0.is_empty() {
        return Err(InvalidMessage);
    }
    let command = BufferedCommand {
        argv,
        env,
        workdir,
        user,
        stdin,
        max_output_bytes,
    };
    command.validate()?;
    op.insert(
        "command".into(),
        serde_json::to_value(command).map_err(|_| InvalidMessage)?,
    );
    Ok(())
}
struct Input<'a>(&'a [u8]);
impl Input<'_> {
    fn take(&mut self, n: usize) -> Result<&[u8], InvalidMessage> {
        if n > self.0.len() {
            return Err(InvalidMessage);
        }
        let (value, rest) = self.0.split_at(n);
        self.0 = rest;
        Ok(value)
    }
    fn count(&mut self, max: usize) -> Result<usize, InvalidMessage> {
        let n = u16::from_be_bytes(self.take(2)?.try_into().map_err(|_| InvalidMessage)?) as usize;
        if n > max {
            return Err(InvalidMessage);
        }
        Ok(n)
    }
    fn string(&mut self, max: usize) -> Result<String, InvalidMessage> {
        let n = u32::from_be_bytes(self.take(4)?.try_into().map_err(|_| InvalidMessage)?) as usize;
        if n > max {
            return Err(InvalidMessage);
        }
        String::from_utf8(self.take(n)?.to_vec()).map_err(|_| InvalidMessage)
    }
    fn optional(&mut self, max: usize) -> Result<Option<String>, InvalidMessage> {
        match self.take(1)?[0] {
            0 => Ok(None),
            1 => self.string(max).map(Some),
            _ => Err(InvalidMessage),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn fixture() -> (Value, Vec<u8>) {
        let value: Value =
            serde_json::from_str(include_str!("../fixtures/buffered-command-request.json"))
                .unwrap();
        let bytes = crate::decode_chunk(
            value["operation"]["command_payload"]["chunks"][0]
                .as_str()
                .unwrap(),
        )
        .unwrap();
        (value, bytes)
    }

    fn with_bytes(mut value: Value, bytes: &[u8]) -> Value {
        let encoded = if bytes.is_empty() {
            String::new()
        } else {
            crate::encode_chunk(bytes).unwrap()
        };
        value["operation"]["command_payload"]["chunks"] = json!([encoded]);
        value
    }

    #[test]
    fn truncated_or_extended_command_never_decodes() {
        let (value, bytes) = fixture();
        for end in 0..bytes.len() {
            assert!(expand(&mut with_bytes(value.clone(), &bytes[..end])).is_err());
        }
        let mut extended = bytes.clone();
        extended.push(0);
        assert!(expand(&mut with_bytes(value.clone(), &extended)).is_err());
        assert!(expand(&mut with_bytes(value, &bytes)).is_ok());
    }

    #[test]
    fn hostile_lengths_flags_and_utf8_are_rejected_before_command_admission() {
        let (value, bytes) = fixture();
        let mut hostile = bytes.clone();
        hostile[5..7].copy_from_slice(&257u16.to_be_bytes());
        assert!(expand(&mut with_bytes(value.clone(), &hostile)).is_err());
        hostile = bytes.clone();
        hostile[7..11].copy_from_slice(&u32::MAX.to_be_bytes());
        assert!(expand(&mut with_bytes(value.clone(), &hostile)).is_err());
        hostile = bytes.clone();
        hostile[11] = 255;
        assert!(expand(&mut with_bytes(value.clone(), &hostile)).is_err());
        // Empty argv/env followed by an invalid optional-field discriminator.
        let hostile = b"SBCM\x01\x00\x00\x00\x00\x02";
        assert!(expand(&mut with_bytes(value, hostile)).is_err());
    }
}
