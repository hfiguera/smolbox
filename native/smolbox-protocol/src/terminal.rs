use crate::{decode_chunk, InvalidMessage};
use serde::{Deserialize, Serialize};
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TerminalLimits {
    pub session_ms: u64,
    pub buffer_bytes: u64,
    pub input_bytes: u64,
    pub total_input_bytes: u64,
    pub attach_ms: u64,
    pub close_ms: u64,
    pub input_slots: u64,
    pub output_events: u64,
    pub descriptors: u64,
}
impl Default for TerminalLimits {
    fn default() -> Self {
        Self {
            session_ms: 86_400_000,
            buffer_bytes: 1_048_576,
            input_bytes: 65536,
            total_input_bytes: 16_777_216,
            attach_ms: 30000,
            close_ms: 5000,
            input_slots: 2,
            output_events: 1024,
            descriptors: 20,
        }
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TerminalSpec {
    pub program: String,
    pub cols: u16,
    pub rows: u16,
    pub session_ms: u64,
    pub idle_ms: u64,
    pub attach_ms: u64,
    pub close_ms: u64,
    pub max_buffer_bytes: u64,
    pub max_input_bytes: u64,
    pub total_input_bytes: u64,
}
impl TerminalSpec {
    pub fn validate(&self) -> Result<(), InvalidMessage> {
        if self.program.is_empty()
            || self.program.len() > 4096
            || self.program.contains('\0')
            || self.cols == 0
            || self.rows == 0
            || !(1000..=86_400_000).contains(&self.session_ms)
            || !(1000..=self.session_ms).contains(&self.idle_ms)
            || !(100..=30000).contains(&self.attach_ms)
            || !(1..=5000).contains(&self.close_ms)
            || !(1024..=1_048_576).contains(&self.max_buffer_bytes)
            || !(1..=65536).contains(&self.max_input_bytes)
            || !(1..=16_777_216).contains(&self.total_input_bytes)
        {
            return Err(InvalidMessage);
        }
        Ok(())
    }
}
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "snake_case", deny_unknown_fields)]
pub enum TerminalAction {
    Attach,
    Input { data_base64: String },
    Resize { cols: u16, rows: u16 },
    Close,
}
impl TerminalAction {
    pub fn validate(&self) -> Result<(), InvalidMessage> {
        match self {
            Self::Input { data_base64 } => {
                if decode_chunk(data_base64)?.is_empty() {
                    return Err(InvalidMessage);
                }
            }
            Self::Resize { cols, rows } if *cols == 0 || *rows == 0 => return Err(InvalidMessage),
            _ => {}
        }
        Ok(())
    }
}
