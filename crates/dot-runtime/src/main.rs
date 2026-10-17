//! First slice of Dot's own Splash supervisor, ported from the Python runtime so
//! that the only Python left on the shipped path is Splash itself (a third-party
//! payload the owner keeps deliberately for speed).
//!
//! This slice carries the wire contract the Swift side already speaks: one JSON
//! line on stdout describing the started listener, or a failure line. The ordering,
//! the supervisor process tree and the TLS relay follow in later slices; nothing
//! here launches anything, so it cannot affect a running app.

use serde::Serialize;

pub const PROTOCOL: u8 = 1;

/// The only events this process writes to stdout. Field names and order are part of
/// the contract parsed by `BundledSplash.swift`; do not rename them.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub enum Event {
    /// A readiness line: the owned listener is up and the api key is live.
    Started {
        #[serde(rename = "protocol")]
        protocol: u8,
        pid: u32,
        port: u16,
        backend_port: u16,
        api_key: String,
        tls_certificate_sha256: String,
    },
    /// A bounded diagnostic: a stage and a reason, never free-form text.
    Failed {
        #[serde(rename = "protocol")]
        protocol: u8,
        stage: String,
        reason: String,
    },
}

impl Event {
    pub fn started(pid: u32, port: u16, backend_port: u16, api_key: &str, cert_sha256: &str) -> Self {
        Event::Started {
            protocol: PROTOCOL,
            pid,
            port,
            backend_port,
            api_key: api_key.to_string(),
            tls_certificate_sha256: cert_sha256.to_string(),
        }
    }

    pub fn failed(stage: &str, reason: &str) -> Self {
        Event::Failed { protocol: PROTOCOL, stage: stage.to_string(), reason: reason.to_string() }
    }

    /// The single line this process prints for the event, newline included.
    pub fn line(&self) -> String {
        let mut line = serde_json::to_string(self).expect("event serialises");
        line.push('\n');
        line
    }
}

/// A 64-character lowercase hex api key, matching `secrets.token_hex(32)` in the
/// Python runtime the Swift side was written against.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ApiKey(String);

impl ApiKey {
    pub fn generate() -> Self {
        let mut bytes = [0u8; 32];
        getrandom::getrandom(&mut bytes).expect("system randomness unavailable");
        Self(bytes.iter().map(|b| format!("{b:02x}")).collect())
    }

    pub fn from_hex(value: &str) -> Option<Self> {
        is_api_key(value).then(|| Self(value.to_string()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// The exact shape the Swift side accepts: 64 lowercase hex characters.
pub fn is_api_key(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

fn main() {
    // This slice deliberately refuses to pretend: the supervisor is not ported yet,
    // so it reports a bounded failure instead of starting a listener it cannot own.
    let event = Event::failed("supervisor", "not-implemented");
    print!("{}", event.line());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn started_line_matches_the_swift_contract() {
        let event = Event::started(4242, 51000, 51001, &"ab".repeat(32), &"cd".repeat(32));
        let line = event.line();
        assert!(line.ends_with('\n'));
        let parsed: serde_json::Value = serde_json::from_str(line.trim()).unwrap();
        assert_eq!(parsed["protocol"], 1);
        assert_eq!(parsed["event"], "started");
        assert_eq!(parsed["pid"], 4242);
        assert_eq!(parsed["port"], 51000);
        assert_eq!(parsed["backend_port"], 51001);
        assert_eq!(parsed["api_key"].as_str().unwrap().len(), 64);
        assert_eq!(parsed["tls_certificate_sha256"].as_str().unwrap().len(), 64);
        // Exactly the six documented keys plus the protocol tag, nothing else.
        assert_eq!(parsed.as_object().unwrap().len(), 7);
    }

    #[test]
    fn failed_line_is_bounded_and_typed() {
        let parsed: serde_json::Value =
            serde_json::from_str(Event::failed("readiness", "timeout").line().trim()).unwrap();
        assert_eq!(parsed["protocol"], 1);
        assert_eq!(parsed["event"], "failed");
        assert_eq!(parsed["stage"], "readiness");
        assert_eq!(parsed["reason"], "timeout");
    }

    #[test]
    fn api_keys_are_64_lowercase_hex_and_validate() {
        let key = ApiKey::generate();
        assert_eq!(key.as_str().len(), 64);
        assert!(is_api_key(key.as_str()));
        assert!(key.as_str().bytes().all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase()));
        assert!(ApiKey::from_hex(key.as_str()).is_some());
        // Two keys are not the same.
        assert_ne!(key.as_str(), ApiKey::generate().as_str());
        // Rejections.
        assert!(!is_api_key(""));
        assert!(!is_api_key(&"a".repeat(63)));
        assert!(!is_api_key(&"A".repeat(64)));
        assert!(!is_api_key(&"g".repeat(64)));
        assert!(ApiKey::from_hex(&"A".repeat(64)).is_none());
    }
}
