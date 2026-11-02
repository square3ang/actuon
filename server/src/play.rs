//! The multiplayer connection: one WebSocket per player carries every room command and score, so nothing
//! about a room goes over plain HTTP. Each command gets exactly one answer, the room or an error.
use crate::rooms::{self, Report, RoomError, Rooms};
use serde::Deserialize;
use serde_json::{json, Value};
use std::io::{Read, Write};
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tungstenite::protocol::{Role, WebSocketConfig};
use tungstenite::{Message, WebSocket};

/// A player's own limit, so one connection cannot make the server work flat out.
const MIN_GAP: Duration = Duration::from_millis(40);
/// Far above any command: a title is the longest field.
const MAX_MESSAGE: usize = 4096;
const MAX_TITLE: usize = 256;

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum Command {
    Create {
        sha256: String,
        title: String,
    },
    Join {
        code: String,
    },
    Chart {
        sha256: String,
        title: String,
    },
    Start,
    Report {
        round: u32,
        has_chart: bool,
        ex: u32,
        judged: u32,
        gauge: f32,
        done: bool,
    },
}

pub struct Session {
    user: i64,
    name: String,
    code: Option<String>,
}

fn random_bytes<const N: usize>() -> Result<[u8; N], RoomError> {
    let mut raw = [0u8; N];
    getrandom::getrandom(&mut raw).map_err(|_| RoomError::TooMany)?;
    Ok(raw)
}

fn check_chart(sha256: &str, title: &str) -> Result<(), RoomError> {
    if crate::valid_sha(sha256) && title.chars().count() <= MAX_TITLE {
        Ok(())
    } else {
        Err(RoomError::BadRequest)
    }
}

impl Session {
    pub fn new(user: i64, name: String) -> Session {
        Session {
            user,
            name,
            code: None,
        }
    }

    pub fn handle(&mut self, rooms: &Mutex<Rooms>, text: &str, now: Instant) -> Value {
        self.apply(rooms, text, now).unwrap_or_else(|e| {
            let (status, error) = e.status();
            json!({"type": "error", "status": status, "error": error})
        })
    }

    fn apply(
        &mut self,
        rooms: &Mutex<Rooms>,
        text: &str,
        now: Instant,
    ) -> Result<Value, RoomError> {
        let command: Command = serde_json::from_str(text).map_err(|_| RoomError::BadRequest)?;
        let mut rooms = rooms.lock().unwrap_or_else(|e| e.into_inner());
        let user = self.user;
        match command {
            Command::Create { sha256, title } => {
                check_chart(&sha256, &title)?;
                let code = rooms::code_from(&random_bytes()?);
                rooms.create(code.clone(), user, &self.name, &sha256, &title, now)?;
                self.code = Some(code);
            }
            Command::Join { code } => {
                if !rooms::valid_code(&code) {
                    return Err(RoomError::NotFound);
                }
                rooms.join(&code, user, &self.name, now)?;
                self.code = Some(code);
            }
            Command::Chart { sha256, title } => {
                check_chart(&sha256, &title)?;
                rooms.set_chart(self.room()?, user, &sha256, &title, now)?;
            }
            // The seed goes out as a decimal string: JSON numbers lose the top bits.
            Command::Start => {
                rooms.start(self.room()?, user, u64::from_le_bytes(random_bytes()?), now)?
            }
            Command::Report {
                round,
                has_chart,
                ex,
                judged,
                gauge,
                done,
            } => {
                let report = Report {
                    round,
                    has_chart,
                    ex,
                    judged,
                    gauge,
                    done,
                };
                return rooms.report(self.room()?, user, &report, now);
            }
        }
        rooms.view_of(self.room()?, user, now)
    }

    fn room(&self) -> Result<&str, RoomError> {
        self.code.as_deref().ok_or(RoomError::NotFound)
    }
}

/// Runs one player's connection until it closes. `stream` has already been upgraded.
pub fn serve<S: Read + Write>(stream: S, rooms: &Mutex<Rooms>, mut session: Session) {
    let config = WebSocketConfig::default()
        .max_message_size(Some(MAX_MESSAGE))
        .max_frame_size(Some(MAX_MESSAGE));
    let mut ws = WebSocket::from_raw_socket(stream, Role::Server, Some(config));
    let mut last = Instant::now();
    loop {
        let text = match ws.read() {
            Ok(Message::Text(text)) => text,
            // tungstenite answers a ping itself, on the next read or send.
            Ok(Message::Ping(_) | Message::Pong(_)) => continue,
            _ => break,
        };
        std::thread::sleep(MIN_GAP.saturating_sub(last.elapsed()));
        last = Instant::now();
        let answer = session.handle(rooms, text.as_str(), last);
        if ws.send(Message::text(answer.to_string())).is_err() {
            break;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SHA: &str = "0000000000000000000000000000000000000000000000000000000000000000";

    #[test]
    fn a_session_runs_a_room() {
        let rooms = Mutex::new(Rooms::default());
        let now = Instant::now();
        let mut host = Session::new(1, "one".into());
        let mut guest = Session::new(2, "two".into());
        assert_eq!(
            host.handle(&rooms, "{\"type\":\"start\"}", now)["status"],
            404,
            "no room yet"
        );
        assert_eq!(host.handle(&rooms, "not json", now)["status"], 400);
        let bad = format!("{{\"type\":\"create\",\"sha256\":\"../x\",\"title\":\"t\"}}");
        assert_eq!(
            host.handle(&rooms, &bad, now)["status"],
            400,
            "a chart hash is checked"
        );
        let made = host.handle(
            &rooms,
            &format!("{{\"type\":\"create\",\"sha256\":\"{SHA}\",\"title\":\"t\"}}"),
            now,
        );
        assert_eq!(made["type"], "room");
        let code = made["code"].as_str().unwrap().to_string();
        assert_eq!(
            guest.handle(&rooms, "{\"type\":\"join\",\"code\":\"a/b\"}", now)["status"],
            404
        );
        let joined = guest.handle(
            &rooms,
            &format!("{{\"type\":\"join\",\"code\":\"{code}\"}}"),
            now,
        );
        assert_eq!(joined["players"].as_array().unwrap().len(), 2);
        assert_eq!(
            guest.handle(&rooms, "{\"type\":\"start\"}", now)["status"],
            403,
            "only the host starts"
        );
        assert_eq!(host.handle(&rooms, "{\"type\":\"start\"}", now)["round"], 1);
        let report = "{\"type\":\"report\",\"round\":1,\"has_chart\":true,\"ex\":7,\"judged\":4,\"gauge\":50,\"done\":false}";
        assert_eq!(guest.handle(&rooms, report, now)["players"][1]["ex"], 7);
        rooms.lock().unwrap().leave(2);
        let seen = host.handle(&rooms, report, now);
        assert_eq!(
            seen["players"].as_array().unwrap().len(),
            1,
            "a player who left is gone"
        );
    }
}
