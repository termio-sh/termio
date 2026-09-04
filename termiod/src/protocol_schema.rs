//! The published API schema, baked into the binary.
//!
//! `docs/api/session-protocol.schema.json` is generated from the types in
//! [`crate::protocol`] by the `termiod-schema` bin (`scripts/generate-api-schema.sh`),
//! so it describes the messages this build actually answers rather than the
//! ones someone remembered to write down. Embedding it is what lets
//! `termio api schema` answer on a VPS that has the binary and none of the
//! checkout.

/// The schema document, verbatim.
pub const SCHEMA: &str = include_str!("../../docs/api/session-protocol.schema.json");

#[cfg(test)]
mod tests {
    use super::SCHEMA;
    use crate::protocol::PROTOCOL_VERSION;

    /// Catches the schema that was never regenerated after the protocol moved.
    /// The full generated-output comparison needs the `schema` feature and runs
    /// in CI; this one runs in every `cargo test` and catches the version skew
    /// that matters most to a client reading the file.
    #[test]
    fn schema_describes_this_protocol_version() {
        let document: serde_json::Value =
            serde_json::from_str(SCHEMA).expect("the shipped schema is valid JSON");
        assert_eq!(
            document["protocol"].as_u64(),
            Some(u64::from(PROTOCOL_VERSION)),
            "docs/api/session-protocol.schema.json is stale — \
             run scripts/generate-api-schema.sh"
        );
        assert!(
            document["schemas"]["control"]["oneOf"]
                .as_array()
                .is_some_and(|ops| ops.len() > 20),
            "the control schema lost its operations"
        );
    }
}
