//! Bounded JSON value decoding with duplicate-key rejection. Generic Value
//! decoding would silently choose the last duplicate ownership/operation field.
use crate::{MAX_COLLECTION_ENTRIES, MAX_STRING_BYTES};
use serde::de::{Deserialize, Deserializer, Error, MapAccess, SeqAccess, Visitor};
use serde_json::{Map, Number, Value};
use std::fmt;

pub(crate) struct StrictValue(pub Value);
impl<'de> Deserialize<'de> for StrictValue {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        deserializer.deserialize_any(StrictVisitor).map(Self)
    }
}
struct StrictVisitor;
impl<'de> Visitor<'de> for StrictVisitor {
    type Value = Value;
    fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("bounded JSON value")
    }
    fn visit_unit<E: Error>(self) -> Result<Value, E> {
        Ok(Value::Null)
    }
    fn visit_bool<E: Error>(self, value: bool) -> Result<Value, E> {
        Ok(Value::Bool(value))
    }
    fn visit_i64<E: Error>(self, value: i64) -> Result<Value, E> {
        Ok(Value::Number(value.into()))
    }
    fn visit_u64<E: Error>(self, value: u64) -> Result<Value, E> {
        Ok(Value::Number(value.into()))
    }
    fn visit_f64<E: Error>(self, value: f64) -> Result<Value, E> {
        Number::from_f64(value)
            .map(Value::Number)
            .ok_or_else(|| E::custom("invalid number"))
    }
    fn visit_str<E: Error>(self, value: &str) -> Result<Value, E> {
        if value.len() > MAX_STRING_BYTES {
            return Err(E::custom("string limit"));
        }
        Ok(Value::String(value.into()))
    }
    fn visit_string<E: Error>(self, value: String) -> Result<Value, E> {
        if value.len() > MAX_STRING_BYTES {
            return Err(E::custom("string limit"));
        }
        Ok(Value::String(value))
    }
    fn visit_seq<A: SeqAccess<'de>>(self, mut sequence: A) -> Result<Value, A::Error> {
        let mut values = Vec::new();
        while let Some(value) = sequence.next_element::<StrictValue>()? {
            if values.len() >= MAX_COLLECTION_ENTRIES {
                return Err(A::Error::custom("collection limit"));
            }
            values.push(value.0);
        }
        Ok(Value::Array(values))
    }
    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Value, A::Error> {
        let mut values = Map::new();
        while let Some(key) = map.next_key::<String>()? {
            if key.len() > 128
                || values.len() >= MAX_COLLECTION_ENTRIES
                || values.contains_key(&key)
            {
                return Err(A::Error::custom("invalid object"));
            }
            values.insert(key, map.next_value::<StrictValue>()?.0);
        }
        Ok(Value::Object(values))
    }
}
