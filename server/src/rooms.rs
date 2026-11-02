//! Versus rooms. They live in memory only: a room lasts one sitting, and scores reach the database through
//! the usual replay check. What a player reports during a song is only ever shown, never ranked: the
//! winner comes from `final_ex`, which only a verified replay sets.
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::time::{Duration, Instant};

pub const MAX_ROOMS: usize = 1000;
pub const MAX_PLAYERS: usize = 8;
/// Time for every player's chart to load, and a countdown after it.
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
    /// The last accepted live packet.
    pub live_at: Option<Instant>,
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
    /// What this round plays: the room's chart may have changed since.
    pub round_sha256: String,
    pub seed: u64,
    pub starts_at: Option<Instant>,
    pub players: Vec<Player>,
}

#[derive(Default)]
pub struct Rooms {
    rooms: HashMap<String, Room>,
    /// Makes each player's live key, so a key needs no table and survives a rejoin.
    secret: [u8; 32],
    pruned_at: Option<Instant>,
}

const LIVE_REQUEST: &[u8; 4] = b"AU1Q";
const LIVE_REPLY: &[u8; 4] = b"AU1R";
const LIVE_REQUEST_LEN: usize = 47;
/// A player's own limit, so one key cannot make the server work flat out.
const LIVE_MIN_GAP: Duration = Duration::from_millis(40);
const NO_START: u32 = u32::MAX;

fn le_u32(b: &[u8], at: usize) -> u32 {
    u32::from_le_bytes([b[at], b[at + 1], b[at + 2], b[at + 3]])
}

/// What a client reports each tick. The numbers are clamped, as they end up on other players' screens.
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
        live_at: None,
    }
}

impl Rooms {
    pub fn with_secret(secret: [u8; 32]) -> Rooms {
        Rooms {
            secret,
            ..Rooms::default()
        }
    }

    pub fn live_key(&self, code: &str, user: i64) -> [u8; 16] {
        let digest = Sha256::new()
            .chain_update(self.secret)
            .chain_update(code)
            .chain_update(user.to_le_bytes())
            .finalize();
        let mut key = [0u8; 16];
        key.copy_from_slice(&digest[..16]);
        key
    }

    /// One live UDP packet. Anything without a player's key gets no answer, so a forged source
    /// address cannot turn this into a flood at someone else.
    pub fn live(&mut self, packet: &[u8], now: Instant) -> Option<Vec<u8>> {
        if packet.len() != LIVE_REQUEST_LEN || &packet[..4] != LIVE_REQUEST {
            return None;
        }
        let code = std::str::from_utf8(&packet[4..10]).ok()?;
        if !valid_code(code) {
            return None;
        }
        if self.pruned_at.is_none_or(|at| now.duration_since(at) >= Duration::from_secs(1)) {
            self.prune(now);
            self.pruned_at = Some(now);
        }
        let room = self.rooms.get(code)?;
        let user = room
            .players
            .iter()
            .map(|p| p.user)
            .find(|u| self.live_key(code, *u) == packet[10..26])?;
        let room = self.rooms.get_mut(code)?;
        let current = room.round;
        let p = room.players.iter_mut().find(|p| p.user == user)?;
        if p.live_at.is_some_and(|at| now.duration_since(at) < LIVE_MIN_GAP) {
            return None;
        }
        p.live_at = Some(now);
        let flags = packet[46];
        let report = Report {
            round: le_u32(packet, 30),
            has_chart: flags & 1 != 0,
            ex: le_u32(packet, 34),
            judged: le_u32(packet, 38),
            gauge: f32::from_bits(le_u32(packet, 42)),
            done: flags & 2 != 0,
        };
        p.apply(&report, current, now);
        let starts_in = room.starts_at.filter(|at| *at > now).map_or(NO_START, |at| {
            at.duration_since(now).as_millis().min(NO_START as u128 - 1) as u32
        });
        let mut reply = Vec::with_capacity(17 + 17 * room.players.len());
        reply.extend_from_slice(LIVE_REPLY);
        reply.extend_from_slice(&packet[26..30]);
        reply.extend_from_slice(&current.to_le_bytes());
        reply.extend_from_slice(&starts_in.to_le_bytes());
        reply.push(room.players.len() as u8);
        for p in &room.players {
            reply.extend_from_slice(&(p.user as u32).to_le_bytes());
            reply.extend_from_slice(&p.ex.to_le_bytes());
            reply.extend_from_slice(&p.judged.to_le_bytes());
            reply.extend_from_slice(&p.gauge.to_bits().to_le_bytes());
            reply.push(p.done as u8);
        }
        Some(reply)
    }

    /// Silent players leave, and the host's seat passes on to whoever is left.
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
        self.remove_player(user);
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
            self.remove_player(user);
            let room = self.rooms.get_mut(code).ok_or(RoomError::NotFound)?;
            room.players.push(player(user, name, now));
        }
        Ok(())
    }

    fn remove_player(&mut self, user: i64) {
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

    /// Only from the named room: a late leave must not take a player out of the room they moved on to.
    pub fn leave(&mut self, code: &str, user: i64) {
        if self.rooms.get(code).is_some_and(|r| r.players.iter().any(|p| p.user == user)) {
            self.remove_player(user);
        }
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
        Ok(view(room, user, now))
    }

    /// Only the replay check calls this, with the score it computed. The seed ties a replay to this
    /// round, and the first one counts, so neither an old best nor a second try can win.
    pub fn record_final(&mut self, code: &str, user: i64, sha256: &str, seed: u64, ex: u32) {
        let Some(room) = self.rooms.get_mut(code) else {
            return;
        };
        if room.round == 0 || room.round_sha256 != sha256 || room.seed != seed {
            return;
        }
        if let Some(p) = room.players.iter_mut().find(|p| p.user == user && p.final_ex.is_none()) {
            p.final_ex = Some(ex);
            p.ex = ex;
            p.done = true;
        }
    }
}

fn view(room: &Room, me: i64, now: Instant) -> Value {
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
    json!({"sha256": room.sha256, "title": room.title, "round": room.round, "seed": room.seed.to_string(), "starts_in_ms": starts_in, "host": room.host == me, "players": players})
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

    fn live_packet(code: &str, key: &[u8; 16], ex: u32) -> Vec<u8> {
        let mut p = b"AU1Q".to_vec();
        p.extend_from_slice(code.as_bytes());
        p.extend_from_slice(key);
        p.extend_from_slice(&7u32.to_le_bytes());
        p.extend_from_slice(&1u32.to_le_bytes());
        p.extend_from_slice(&ex.to_le_bytes());
        p.extend_from_slice(&ex.to_le_bytes());
        p.extend_from_slice(&f32::NAN.to_bits().to_le_bytes());
        p.push(1);
        p
    }

    #[test]
    fn a_live_packet_needs_a_player_key_and_is_rate_limited() {
        let now = Instant::now();
        let mut rooms = Rooms::with_secret([9; 32]);
        room_with_two(&mut rooms, now);
        rooms.start("AAAAAA", 1, 8, now).unwrap();
        let key = rooms.live_key("AAAAAA", 2);
        assert_ne!(key, rooms.live_key("AAAAAA", 1));
        assert!(rooms.live(&live_packet("AAAAAA", &[0; 16], 5), now).is_none());
        assert!(rooms.live(&live_packet("ZZZZZZ", &key, 5), now).is_none());
        assert!(rooms.live(&[0; 47], now).is_none());
        assert!(rooms.live(&live_packet("AAAAAA", &key, 5)[..46], now).is_none());
        let reply = rooms.live(&live_packet("AAAAAA", &key, 1 << 30), now).unwrap();
        assert_eq!(&reply[..4], b"AU1R");
        assert_eq!(reply[4], 7, "the sequence number comes back");
        assert_eq!(reply[16], 2);
        let p = &rooms.rooms["AAAAAA"].players[1];
        assert_eq!((p.ex, p.gauge), (1 << 24, 0.0), "numbers are clamped");
        assert_eq!(p.final_ex, None, "and decide nothing");
        assert!(rooms.live(&live_packet("AAAAAA", &key, 5), now).is_none());
        let later = now + LIVE_MIN_GAP;
        assert!(rooms.live(&live_packet("AAAAAA", &key, 5), later).is_some());
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
        let v = rooms
            .report("AAAAAA", 2, &report(10), now)
            .ok()
            .unwrap();
        assert_eq!(v["seed"], "7");
        assert_eq!(v["starts_in_ms"], START_DELAY.as_millis() as u64);
        assert_eq!(v["players"][1]["ex"], 10);
        assert_eq!(rooms.start("AAAAAA", 1, 8, now), Err(RoomError::Busy), "players are still loading");
        assert_eq!(rooms.set_chart("AAAAAA", 1, "b", "t", now), Err(RoomError::Busy));
        let later = now + START_DELAY;
        rooms.start("AAAAAA", 1, 8, later).unwrap();
        let v = rooms
            .report("AAAAAA", 2, &report(10), later)
            .ok()
            .unwrap();
        // Round 1's report no longer counts in round 2.
        assert_eq!(v["players"][1]["ex"], 0);
    }

    #[test]
    fn a_report_never_sets_the_final_score_and_the_check_only_counts_on_the_room_chart() {
        let now = Instant::now();
        let mut rooms = Rooms::default();
        room_with_two(&mut rooms, now);
        rooms.start("AAAAAA", 1, 1, now).unwrap();
        let v = rooms
            .report("AAAAAA", 2, &report(9999), now)
            .ok()
            .unwrap();
        assert!(v["players"][1]["final_ex"].is_null());
        rooms.record_final("AAAAAA", 2, "other", 1, 5);
        rooms.record_final("AAAAAA", 2, SHA, 99, 5);
        let v = rooms
            .report("AAAAAA", 2, &report(9999), now)
            .ok()
            .unwrap();
        assert!(v["players"][1]["final_ex"].is_null());
        let later = now + START_DELAY;
        rooms.set_chart("AAAAAA", 1, "b", "t", later).unwrap();
        rooms.record_final("AAAAAA", 2, SHA, 1, 5);
        rooms.record_final("AAAAAA", 2, SHA, 1, 9);
        let v = rooms
            .report("AAAAAA", 1, &report(1), later)
            .ok()
            .unwrap();
        assert_eq!(v["players"][1]["final_ex"], 5, "the first check of the round counts, whatever the chart is now");
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
        assert_eq!(
            rooms.join("AAAAAA", 99, "p", now),
            Err(RoomError::Full)
        );
        assert_eq!(rooms.join("BBBBBB", 99, "p", now), Err(RoomError::NotFound));
        let later = now + PLAYER_TIMEOUT - Duration::from_secs(1);
        for user in 2..=MAX_PLAYERS as i64 {
            rooms.report("AAAAAA", user, &report(0), later).ok().unwrap();
        }
        let v = rooms
            .report("AAAAAA", 2, &report(0), now + PLAYER_TIMEOUT + Duration::from_secs(2))
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
        assert_eq!(rooms.join("AAAAAA", 2, "two", now), Err(RoomError::NotFound));
        rooms.leave("AAAAAA", 1);
        assert!(rooms.rooms.contains_key("BBBBBB"), "a late leave from the old room stays there");
        rooms.leave("BBBBBB", 1);
        assert!(!rooms.rooms.contains_key("BBBBBB"));
    }
}
