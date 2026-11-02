//! The HTTP shell around the server API. No sync decisions are made here;
//! see `qot_core::sync`.

use base64::{Engine, engine::general_purpose::STANDARD as B64};
use qot_core::sync::{Incoming, Outgoing};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::time::Duration;
use ureq::Agent;

pub struct Api {
    base: String,
    agent: Agent,
}

#[derive(Debug, Deserialize)]
pub struct DeviceStart {
    pub device_code: String,
    pub user_code: String,
    pub interval: u64,
    pub expires_in: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Tokens {
    pub access_token: String,
    pub refresh_token: String,
}

pub enum Poll {
    Pending,
    Done(Tokens),
    Failed(String),
}

#[derive(Debug)]
pub enum ApiError {
    /// The access token was refused; refresh and retry.
    Unauthorized,
    Other(String),
}

impl std::fmt::Display for ApiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ApiError::Unauthorized => f.write_str("not signed in (run `qot login`)"),
            ApiError::Other(e) => f.write_str(e),
        }
    }
}

pub struct Page {
    pub changes: Vec<Incoming>,
    pub more: bool,
}

impl Api {
    pub fn new(base: &str, timeout: Duration) -> Self {
        let agent: Agent = Agent::config_builder()
            .http_status_as_error(false)
            .timeout_global(Some(timeout))
            .build()
            .into();
        Api {
            base: base.trim_end_matches('/').to_string(),
            agent,
        }
    }

    fn post(&self, path: &str, token: Option<&str>, body: Value) -> Result<(u16, Value), ApiError> {
        let mut req = self.agent.post(format!("{}{}", self.base, path));
        if let Some(t) = token {
            req = req.header("authorization", format!("Bearer {t}"));
        }
        let mut res = req.send_json(body).map_err(net)?;
        let status = res.status().as_u16();
        let body = res.body_mut().read_json::<Value>().unwrap_or(Value::Null);
        Ok((status, body))
    }

    fn get(&self, path: &str, token: &str) -> Result<(u16, Value), ApiError> {
        let mut res = self
            .agent
            .get(format!("{}{}", self.base, path))
            .header("authorization", format!("Bearer {token}"))
            .call()
            .map_err(net)?;
        let status = res.status().as_u16();
        let body = res.body_mut().read_json::<Value>().unwrap_or(Value::Null);
        Ok((status, body))
    }

    pub fn start_device_login(&self, email: &str) -> Result<DeviceStart, ApiError> {
        match self.post("/api/auth/device", None, json!({ "email": email }))? {
            (200, body) => serde_json::from_value(body).map_err(|e| ApiError::Other(e.to_string())),
            (_, body) => Err(ApiError::Other(error_text(&body))),
        }
    }

    pub fn poll_device_login(&self, device_code: &str) -> Result<Poll, ApiError> {
        match self.post(
            "/api/auth/device/token",
            None,
            json!({ "device_code": device_code }),
        )? {
            (200, body) => Ok(Poll::Done(
                serde_json::from_value(body).map_err(|e| ApiError::Other(e.to_string()))?,
            )),
            (400, body) if body["error"] == "authorization_pending" => Ok(Poll::Pending),
            (_, body) => Ok(Poll::Failed(error_text(&body))),
        }
    }

    pub fn refresh(&self, refresh_token: &str) -> Result<String, ApiError> {
        match self.post(
            "/api/auth/refresh",
            None,
            json!({ "refresh_token": refresh_token }),
        )? {
            (200, body) => body["access_token"]
                .as_str()
                .map(String::from)
                .ok_or_else(|| ApiError::Other("no access_token in reply".into())),
            (401, _) => Err(ApiError::Unauthorized),
            (_, body) => Err(ApiError::Other(error_text(&body))),
        }
    }

    pub fn logout(&self, refresh_token: &str) -> Result<(), ApiError> {
        self.post(
            "/api/auth/logout",
            None,
            json!({ "refresh_token": refresh_token }),
        )
        .map(|_| ())
    }

    /// Pushes changes; returns the server's new cursor.
    pub fn push(&self, token: &str, changes: &[Outgoing]) -> Result<u64, ApiError> {
        let body = json!({
            "changes": changes
                .iter()
                .map(|c| json!({ "note_id": c.note_id, "data": B64.encode(&c.data) }))
                .collect::<Vec<_>>()
        });
        match self.post("/api/sync/push", Some(token), body)? {
            (200, body) => body["cursor"]
                .as_u64()
                .ok_or_else(|| ApiError::Other("no cursor in reply".into())),
            (401, _) => Err(ApiError::Unauthorized),
            (_, body) => Err(ApiError::Other(error_text(&body))),
        }
    }

    pub fn pull(&self, token: &str, since: u64) -> Result<Page, ApiError> {
        match self.get(&format!("/api/sync/pull?since={since}"), token)? {
            (200, body) => parse_page(&body).map_err(ApiError::Other),
            (401, _) => Err(ApiError::Unauthorized),
            (_, body) => Err(ApiError::Other(error_text(&body))),
        }
    }
}

fn parse_page(body: &Value) -> Result<Page, String> {
    let changes = body["changes"]
        .as_array()
        .ok_or("no changes in reply")?
        .iter()
        .map(|c| {
            Ok(Incoming {
                seq: c["seq"].as_u64().ok_or("change without seq")?,
                note_id: c["note_id"]
                    .as_str()
                    .ok_or("change without note_id")?
                    .to_string(),
                data: B64
                    .decode(c["data"].as_str().ok_or("change without data")?)
                    .map_err(|e| format!("bad change data: {e}"))?,
            })
        })
        .collect::<Result<Vec<_>, String>>()?;
    Ok(Page {
        changes,
        more: body["more"].as_bool().unwrap_or(false),
    })
}

fn error_text(body: &Value) -> String {
    body["error"]
        .as_str()
        .map(String::from)
        .unwrap_or_else(|| "unexpected reply from server".into())
}

fn net(e: ureq::Error) -> ApiError {
    ApiError::Other(format!("can't reach the server: {e}"))
}
