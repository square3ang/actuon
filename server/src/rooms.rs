//! Live reports are only shown: the winner is `final_ex`, set only by a verified replay.
use serde_json::{json, Value};
use std::collections::HashMap;
use std::time::{Duration, Instant};

pub const MAX_ROOMS: usize = 1000;
pub const MAX_PLAYERS: usize = 8;
pub const START_DELAY: Duration = Duration::from_secs(8);
/// Clients report several times a second, so this much silence means gone.
const PLAYER_TIMEOUT: Duration = Duration::from_secs(30);
const CODE_LEN: usize = 6;
/// No 0, O, 1 or I: a code is read out loud.
const CODE_ALPHABET: &[u8] = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

#[derive(Debug, PartialEq)]
pub enum RoomError {
    NotFound,
    Full,
    NotHost,
    TooMany,
    Busy,
    BadRequest,
}

impl RoomError {
    pub fn status(&self) -> (u16, &'static str) {
        match self {
            RoomError::NotFound => (404, "no such room"),
            RoomError::Full => (409, "room is full"),
            RoomError::NotHost => (403, "only the host can do that"),
            RoomError::TooMany => (503, "too many rooms"),
            RoomError::Busy => (409, "a round is about to start"),
            RoomError::BadRequest => (400, "bad request"),
        }
    }
}

pub struct Player {
    pub user: i64,
    pub name: String,
    pub has_chart: bool,
    pub ex: u32,
    pub judged: u32,
    pub gauge: f32,
    pub done: bool,
    pub final_ex: Option<u32>,
    pub seen: Instant,
}

impl Player {
    fn apply(&mut self, r: &Report, current: u32, now: Instant) {
        self.seen = now;
        self.has_chart = r.has_chart;
        // A report sent before a new round started must not fill it with the last song's score.
        if r.round == current {
            self.ex = r.ex.min(1 << 24);
            self.judged = r.judged.min(1 << 24);
            self.gauge = if r.gauge.is_finite() {
                r.gauge.clamp(0.0, 100.0)
            } else {
                0.0
            };
            self.done = r.done;
        }
    }
}

pub struct Room {
    pub host: i64,
    pub sha256: String,
    pub title: String,
    pub round: u32,
    pub round_sha256: String,
    pub seed: u64,
    pub starts_at: Option<Instant>,
    pub players: Vec<Player>,
}

#[derive(Default)]
pub struct Rooms {
    rooms: HashMap<String, Room>,
}

/// Clamped: the numbers end up on other players' screens.
pub struct Report {
    pub round: u32,
    pub has_chart: bool,
    pub ex: u32,
    pub judged: u32,
    pub gauge: f32,
    pub done: bool,
}

pub fn code_from(raw: &[u8; CODE_LEN]) -> String {
    raw.iter()
        .map(|b| CODE_ALPHABET[*b as usize % CODE_ALPHABET.len()] as char)
        .collect()
}

pub fn valid_code(code: &str) -> bool {
    code.len() == CODE_LEN && code.bytes().all(|b| CODE_ALPHABET.contains(&b))
}

fn player(user: i64, name: &str, now: Instant) -> Player {
    Player {
        user,
        name: name.to_string(),
        has_chart: false,
        ex: 0,
        judged: 0,
        gauge: 0.0,
        done: false,
        final_ex: None,
        seen: now,
    }
}

impl Rooms {
    fn prune(&mut self, now: Instant) {
        self.rooms.retain(|_, room| {
            room.players
                .retain(|p| now.duration_since(p.seen) < PLAYER_TIMEOUT);
            if let Some(first) = room.players.first() {
                if !room.players.iter().any(|p| p.user == room.host) {
                    room.host = first.user;
                }
                true
            } else {
                false
            }
        });
    }

    pub fn create(
        &mut self,
        code: String,
        user: i64,
        name: &str,
        sha256: &str,
        title: &str,
        now: Instant,
    ) -> Result<(), RoomError> {
        self.prune(now);
        // One room at a time: leaving the old one keeps a player from filling the table.
        self.leave(user);
        if self.rooms.len() >= MAX_ROOMS || self.rooms.contains_key(&code) {
            return Err(RoomError::TooMany);
        }
        self.rooms.insert(
            code,
            Room {
                host: user,
                sha256: sha256.to_string(),
                title: title.to_string(),
                round: 0,
                round_sha256: String::new(),
                seed: 0,
                starts_at: None,
                players: vec![player(user, name, now)],
            },
        );
        Ok(())
    }

    pub fn join(
        &mut self,
        code: &str,
        user: i64,
        name: &str,
        now: Instant,
    ) -> Result<(), RoomError> {
        self.prune(now);
        if !self.rooms.contains_key(code) {
            return Err(RoomError::NotFound);
        }
        let room = self.rooms.get(code).ok_or(RoomError::NotFound)?;
        if !room.players.iter().any(|p| p.user == user) {
            if room.players.len() >= MAX_PLAYERS {
                return Err(RoomError::Full);
            }
            self.leave(user);
            let room = self.rooms.get_mut(code).ok_or(RoomError::NotFound)?;
            room.players.push(player(user, name, now));
        }
        Ok(())
    }

    pub fn leave(&mut self, user: i64) {
        self.rooms.retain(|_, room| {
            room.players.retain(|p| p.user != user);
            if room.host == user {
                if let Some(first) = room.players.first() {
                    room.host = first.user;
                }
            }
            !room.players.is_empty()
        });
    }

    fn room_of_host(&mut self, code: &str, user: i64) -> Result<&mut Room, RoomError> {
        let room = self.rooms.get_mut(code).ok_or(RoomError::NotFound)?;
        if room.host != user {
            return Err(RoomError::NotHost);
        }
        Ok(room)
    }

    pub fn set_chart(
        &mut self,
        code: &str,
        user: i64,
        sha256: &str,
        title: &str,
        now: Instant,
    ) -> Result<(), RoomError> {
        let room = self.room_of_host(code, user)?;
        // Players are already loading the round's chart.
        if room.starts_at.is_some_and(|at| at > now) {
            return Err(RoomError::Busy);
        }
        room.sha256 = sha256.to_string();
        room.title = title.to_string();
        room.starts_at = None;
        for p in &mut room.players {
            p.has_chart = false;
        }
        Ok(())
    }

    pub fn start(
        &mut self,
        code: &str,
        user: i64,
        seed: u64,
        now: Instant,
    ) -> Result<(), RoomError> {
        let room = self.room_of_host(code, user)?;
        if room.sha256.is_empty() {
            return Err(RoomError::BadRequest);
        }
        // A start replaces the clock, so repeating it could keep players on the loading screen.
        if room.starts_at.is_some_and(|at| at > now) {
            return Err(RoomError::Busy);
        }
        room.round += 1;
        room.round_sha256 = room.sha256.clone();
        room.seed = seed;
        room.starts_at = Some(now + START_DELAY);
        for p in &mut room.players {
            p.ex = 0;
            p.judged = 0;
            p.done = false;
            p.final_ex = None;
        }
        Ok(())
    }

    pub fn report(
        &mut self,
        code: &str,
        user: i64,
        r: &Report,
        now: Instant,
    ) -> Result<Value, RoomError> {
        self.prune(now);
        let room = self.rooms.get_mut(code).ok_or(RoomError::NotFound)?;
        let current = room.round;
        let p = room
            .players
            .iter_mut()
            .find(|p| p.user == user)
            .ok_or(RoomError::NotFound)?;
        p.apply(r, current, now);
        Ok(view(code, room, user, now))
    }

    pub fn view_of(&self, code: &str, user: i64, now: Instant) -> Result<Value, RoomError> {
        let room = self.rooms.get(code).ok_or(RoomError::NotFound)?;
        Ok(view(code, room, user, now))
    }

    /// Only the replay check calls this. The seed ties a replay to this round and the first counts, so no old best or retry wins.
    pub fn record_final(&mut self, code: &str, user: i64, sha256: &str, seed: u64, ex: u32) {
        let Some(room) = self.rooms.get_mut(code) else {
            return;
        };
        if room.round == 0 || room.round_sha256 != sha256 || room.seed != seed {
            return;
        }
        if let Some(p) = room
            .players
            .iter_mut()
            .find(|p| p.user == user && p.final_ex.is_none())
        {
            p.final_ex = Some(ex);
            p.ex = ex;
            p.done = true;
        }
    }
}

fn view(code: &str, room: &Room, me: i64, now: Instant) -> Value {
    let players: Vec<Value> = room
        .players
        .iter()
        .map(|p| {
            json!({"id": p.user as u32, "name": p.name, "you": p.user == me, "host": p.user == room.host, "has_chart": p.has_chart, "ex": p.ex, "judged": p.judged, "gauge": p.gauge, "done": p.done, "final_ex": p.final_ex})
        })
        .collect();
    // A delay, not a time: the clients' clocks are not this server's.
    let starts_in = room
        .starts_at
        .filter(|at| *at > now)
        .map(|at| at.duration_since(now).as_millis() as u64);
    json!({"type": "room", "code": code, "sha256": room.sha256, "title": room.title, "round": room.round, "seed": room.seed.to_string(), "starts_in_ms": starts_in, "host": room.host == me, "players": players})
}

#[cfg(test)]
mod tests {
    use super::*;

    const SHA: &str = "a";

    fn report(ex: u32) -> Report {
        Report {
            round: 1,
            has_chart: true,
            ex,
            judged: ex,
            gauge: 50.0,
            done: false,
        }
    }

    fn room_with_two(rooms: &mut Rooms, now: Instant) {
        rooms
            .create("AAAAAA".into(), 1, "one", SHA, "t", now)
            .unwrap();
        rooms.join("AAAAAA", 2, "two", now).unwrap();
    }

    #[test]
    fn codes_are_checked_and_avoid_lookalikes() {
        assert!(valid_code(&code_from(&[0, 255, 3, 200, 9, 31])));
        assert!(!valid_code("AAAAA"));
        assert!(!valid_code("AAAAA0"));
        assert!(!valid_code("../../"));
    }

    #[test]
    fn only_the_host_starts_and_a_start_clears_the_last_round() {
        let now = Instant::now();
        let mut rooms = Rooms::default();
        room_with_two(&mut rooms, now);
        assert_eq!(rooms.start("AAAAAA", 2, 7, now), Err(RoomError::NotHost));
        rooms.start("AAAAAA", 1, 7, now).unwrap();
        let v = rooms.report("AAAAAA", 2, &report(10), now).ok().unwrap();
        assert_eq!(v["seed"], "7");
        assert_eq!(v["starts_in_ms"], START_DELAY.as_millis() as u64);
        assert_eq!(v["players"][1]["ex"], 10);
        assert_eq!(
            rooms.start("AAAAAA", 1, 8, now),
            Err(RoomError::Busy),
            "players are still loading"
        );
        assert_eq!(
            rooms.set_chart("AAAAAA", 1, "b", "t", now),
            Err(RoomError::Busy)
        );
        let later = now + START_DELAY;
        rooms.start("AAAAAA", 1, 8, later).unwrap();
        let v = rooms.report("AAAAAA", 2, &report(10), later).ok().unwrap();
        assert_eq!(v["players"][1]["ex"], 0);
    }

    #[test]
    fn a_report_never_sets_the_final_score_and_the_check_only_counts_on_the_room_chart() {
        let now = Instant::now();
        let mut rooms = Rooms::default();
        room_with_two(&mut rooms, now);
        rooms.start("AAAAAA", 1, 1, now).unwrap();
        let v = rooms.report("AAAAAA", 2, &report(9999), now).ok().unwrap();
        assert!(v["players"][1]["final_ex"].is_null());
        rooms.record_final("AAAAAA", 2, "other", 1, 5);
        rooms.record_final("AAAAAA", 2, SHA, 99, 5);
        let v = rooms.report("AAAAAA", 2, &report(9999), now).ok().unwrap();
        assert!(v["players"][1]["final_ex"].is_null());
        let later = now + START_DELAY;
        rooms.set_chart("AAAAAA", 1, "b", "t", later).unwrap();
        rooms.record_final("AAAAAA", 2, SHA, 1, 5);
        rooms.record_final("AAAAAA", 2, SHA, 1, 9);
        let v = rooms.report("AAAAAA", 1, &report(1), later).ok().unwrap();
        assert_eq!(
            v["players"][1]["final_ex"], 5,
            "the first check of the round counts, whatever the chart is now"
        );
        assert!(v["starts_in_ms"].is_null(), "a past start is not announced");
    }

    #[test]
    fn a_full_room_refuses_and_a_silent_host_hands_over() {
        let now = Instant::now();
        let mut rooms = Rooms::default();
        room_with_two(&mut rooms, now);
        for user in 3..=MAX_PLAYERS as i64 {
            rooms.join("AAAAAA", user, "p", now).unwrap();
        }
        assert_eq!(rooms.join("AAAAAA", 99, "p", now), Err(RoomError::Full));
        assert_eq!(rooms.join("BBBBBB", 99, "p", now), Err(RoomError::NotFound));
        let later = now + PLAYER_TIMEOUT - Duration::from_secs(1);
        for user in 2..=MAX_PLAYERS as i64 {
            rooms
                .report("AAAAAA", user, &report(0), later)
                .ok()
                .unwrap();
        }
        let v = rooms
            .report(
                "AAAAAA",
                2,
                &report(0),
                now + PLAYER_TIMEOUT + Duration::from_secs(2),
            )
            .ok()
            .unwrap();
        assert_eq!(v["host"], true);
        assert_eq!(v["players"].as_array().unwrap().len(), MAX_PLAYERS - 1);
    }

    #[test]
    fn a_new_room_leaves_the_old_one_and_an_empty_room_goes() {
        let now = Instant::now();
        let mut rooms = Rooms::default();
        rooms
            .create("AAAAAA".into(), 1, "one", SHA, "t", now)
            .unwrap();
        rooms
            .create("BBBBBB".into(), 1, "one", SHA, "t", now)
            .unwrap();
        assert_eq!(
            rooms.join("AAAAAA", 2, "two", now),
            Err(RoomError::NotFound)
        );
        rooms.leave(1);
        assert!(!rooms.rooms.contains_key("BBBBBB"));
    }
}
