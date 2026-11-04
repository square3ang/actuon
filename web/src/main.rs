//! Usage: actuon-web ADDR IR_URL

use serde::{de::DeserializeOwned, Deserialize};
use std::{sync::Arc, thread, time::Duration};
use tiny_http::{Header, Method, Request, Response, Server};

const CSS: &str = include_str!("style.css");
const LOGO: &str = include_str!("../../assets/brand/actuon_widelogo.svg");
const ICON: &str = include_str!("../../assets/brand/actuon_icon.svg");
const FONT_MEDIUM: &[u8] = include_bytes!("../../assets/fonts/SUITE-Medium.ttf");
const FONT_BOLD: &[u8] = include_bytes!("../../assets/fonts/SUITE-ExtraBold.ttf");
const CLEAR_NAMES: [&str; 11] = [
    "NO PLAY",
    "FAILED",
    "ASSIST EASY",
    "LIGHT ASSIST",
    "EASY",
    "NORMAL",
    "HARD",
    "EX HARD",
    "FULL COMBO",
    "PERFECT",
    "MAX",
];
/// EASY in beatoraja's clear numbering, which the server uses.
const FIRST_CLEAR: usize = 4;
const WORKERS: usize = 4;

#[derive(Deserialize)]
struct Recent {
    scores: Vec<RecentScore>,
}

#[derive(Deserialize)]
struct RecentScore {
    sha256: String,
    name: String,
    ex: u32,
    clear: usize,
    miss: u32,
    date: i64,
    #[serde(default)]
    title: String,
}

#[derive(Deserialize)]
struct Ranking {
    #[serde(default)]
    title: String,
    #[serde(default)]
    artist: String,
    scores: Vec<RankedScore>,
    total: u32,
    /// Players per lamp, indexed like `CLEAR_NAMES`.
    clears: [u32; 11],
}

#[derive(Deserialize)]
struct RankedScore {
    name: String,
    ex: u32,
    clear: usize,
    miss: u32,
    max_combo: u32,
    date: i64,
    verified: bool,
}

fn fetch<T: DeserializeOwned>(ir: &ureq::Agent, url: &str) -> Result<T, ureq::Error> {
    ir.get(url).call()?.body_mut().read_json()
}

fn is_sha256(s: &str) -> bool {
    s.len() == 64
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// Days-to-civil from Howard Hinnant's date algorithms; a date crate would be used for this alone.
fn utc_date(unix: i64) -> String {
    let z = unix.div_euclid(86400) + 719468;
    let era = z.div_euclid(146097);
    let doe = z.rem_euclid(146097);
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!("{year}-{month:02}-{:02}", doy - (153 * mp + 2) / 5 + 1)
}

/// Every string from the IR passes through here; the templates below are literals and numbers.
fn esc(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for ch in s.chars() {
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            _ => out.push(ch),
        }
    }
    out
}

fn digits(n: u32, cells: usize) -> String {
    let text = format!("{n:0cells$}");
    let lit = text.trim_start_matches('0');
    let lit = if lit.is_empty() { "0" } else { lit };
    let off = &text[..text.len() - lit.len()];
    format!(r#"<span class="digits"><span class="off">{off}</span>{lit}</span>"#)
}

fn lamp(clear: usize) -> String {
    let known = clear.min(CLEAR_NAMES.len() - 1);
    format!(
        r#"<span class="lamp lamp-{known}"><i></i>{}</span>"#,
        CLEAR_NAMES[known]
    )
}

fn notice(text: &str) -> String {
    format!(r#"<p class="notice">{text}</p>"#)
}

fn lookup(refused: bool) -> String {
    let alert = if refused {
        r#"<p class="refused" role="alert">Not a SHA-256 hash</p>"#
    } else {
        ""
    };
    format!(
        r#"<form action="/" method="get" class="lookup"><label for="chart">CHART SHA-256</label><input id="chart" name="chart" required maxlength="64" autocomplete="off" spellcheck="false"><button>Open</button>{alert}</form>"#
    )
}

fn chart_name(title: &str, sha: &str) -> String {
    esc(if title.is_empty() { &sha[..16] } else { title })
}

fn recent_rows(scores: Vec<RecentScore>) -> String {
    let rows: String = scores
        .iter()
        .map(|s| {
            format!(
                r#"<tr><td class="clip"><a href="/charts/{}">{}</a></td><td class="clip">{}</td><td>{}</td><td class="num">{}</td><td class="num wide">{}</td><td class="num wide dim">{}</td></tr>"#,
                esc(&s.sha256), chart_name(&s.title, &s.sha256), esc(&s.name), lamp(s.clear), digits(s.ex, 5), s.miss, utc_date(s.date)
            )
        })
        .collect();
    format!(
        r#"<table><thead><tr><th>CHART</th><th>PLAYER</th><th class="lamp-col">LAMP</th><th class="num ex">EX SCORE</th><th class="num wide">BP</th><th class="num wide">DATE</th></tr></thead><tbody>{rows}</tbody></table>"#
    )
}

fn home(recent: Option<Recent>, refused: bool) -> String {
    let body = match recent {
        None => notice("Could not reach the IR server"),
        Some(r) if r.scores.is_empty() => notice("No verified scores yet."),
        Some(r) => recent_rows(r.scores),
    };
    format!(
        r#"{}<section class="panel"><h1>RECENT VERIFIED SCORES</h1>{body}</section>"#,
        lookup(refused)
    )
}

fn readout(label: &str, n: u32) -> String {
    format!(
        r#"<div class="panel readout"><span>{label}</span>{}</div>"#,
        digits(n, 5)
    )
}

fn ranking_rows(scores: Vec<RankedScore>) -> String {
    let rows: String = scores
        .iter()
        .enumerate()
        .map(|(i, s)| {
            let claim = if s.verified { "" } else { r#"<span class="claim">UNVERIFIED</span>"# };
            format!(
                r#"<tr><td class="num">{}</td><td class="clip">{}{claim}</td><td>{}</td><td class="num">{}</td><td class="num wide">{}</td><td class="num wide">{}</td><td class="num wide dim">{}</td></tr>"#,
                i + 1, esc(&s.name), lamp(s.clear), digits(s.ex, 5), s.miss, s.max_combo, utc_date(s.date)
            )
        })
        .collect();
    format!(
        r#"<table><thead><tr><th class="num rank">RANK</th><th>PLAYER</th><th class="lamp-col">LAMP</th><th class="num ex">EX SCORE</th><th class="num wide">BP</th><th class="num wide">MAX COMBO</th><th class="num wide">DATE</th></tr></thead><tbody>{rows}</tbody></table>"#
    )
}

fn chart(sha: &str, ranking: Option<Ranking>) -> String {
    let (title, artist) = ranking.as_ref().map_or_else(
        || (esc(sha), String::new()),
        |r| (chart_name(&r.title, sha), esc(&r.artist)),
    );
    let body = match ranking {
        None => notice("Could not reach the IR server"),
        Some(r) => {
            let list = if r.scores.is_empty() {
                notice("No scores on this chart.")
            } else {
                ranking_rows(r.scores)
            };
            format!(
                r#"<div class="readouts">{}{}</div><section class="panel"><h1>RANKING</h1>{list}</section>"#,
                readout("PLAYERS", r.total),
                readout("CLEARS", r.clears[FIRST_CLEAR..].iter().sum())
            )
        }
    };
    format!(
        r#"<div class="chart-head"><h1 class="title">{title}</h1><p class="artist">{artist}</p><p class="sha">{}</p></div>{body}"#,
        esc(sha)
    )
}

fn not_found() -> String {
    notice("Nothing here.")
}

fn document(title: &str, main: String) -> String {
    format!(
        r#"<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>{title} - actuon IR</title><link rel="stylesheet" href="/style.css"><link rel="icon" href="/icon.svg"></head><body><header><a href="https://actuon.app"><img src="/logo.svg" alt="actuon"></a></header><main>{main}</main></body></html>"#
    )
}

fn html(status: u16, body: String) -> Response<std::io::Cursor<Vec<u8>>> {
    with_type(
        Response::from_string(body).with_status_code(status),
        "text/html; charset=utf-8",
    )
    // No script runs here: anything that gets past escaping still does nothing.
    .with_header(
        Header::from_bytes(
            "Content-Security-Policy",
            "default-src 'none'; style-src 'self'; img-src 'self'; font-src 'self'; form-action 'self'",
        )
        .unwrap(),
    )
}

fn with_type(
    r: Response<std::io::Cursor<Vec<u8>>>,
    content_type: &str,
) -> Response<std::io::Cursor<Vec<u8>>> {
    r.with_header(Header::from_bytes("Content-Type", content_type).unwrap())
}

fn asset(bytes: &[u8], content_type: &str) -> Response<std::io::Cursor<Vec<u8>>> {
    with_type(Response::from_data(bytes.to_vec()), content_type)
        .with_header(Header::from_bytes("Cache-Control", "public, max-age=300").unwrap())
}

fn respond(url: &str, ir: &ureq::Agent, ir_url: &str) -> Response<std::io::Cursor<Vec<u8>>> {
    let (path, query) = url.split_once('?').unwrap_or((url, ""));
    match path {
        "/style.css" => asset(CSS.as_bytes(), "text/css; charset=utf-8"),
        "/logo.svg" => asset(LOGO.as_bytes(), "image/svg+xml"),
        "/icon.svg" => asset(ICON.as_bytes(), "image/svg+xml"),
        "/fonts/SUITE-Medium.ttf" => asset(FONT_MEDIUM, "font/ttf"),
        "/fonts/SUITE-ExtraBold.ttf" => asset(FONT_BOLD, "font/ttf"),
        "/" => {
            let asked = query
                .split('&')
                .find_map(|p| p.strip_prefix("chart="))
                .map(str::to_ascii_lowercase);
            if let Some(sha) = asked.as_deref().filter(|s| is_sha256(s)) {
                return html(303, String::new()).with_header(
                    Header::from_bytes("Location", format!("/charts/{sha}")).unwrap(),
                );
            }
            let recent = fetch(ir, &format!("{ir_url}/recent"))
                .inspect_err(|e| eprintln!("recent: {e}"))
                .ok();
            let status = if recent.is_some() { 200 } else { 502 };
            html(
                status,
                document("Recent scores", home(recent, asked.is_some())),
            )
        }
        _ => match path.strip_prefix("/charts/").filter(|s| is_sha256(s)) {
            Some(sha) => {
                let ranking = fetch(ir, &format!("{ir_url}/scores/{sha}"))
                    .inspect_err(|e| eprintln!("ranking: {e}"))
                    .ok();
                let status = if ranking.is_some() { 200 } else { 502 };
                html(status, document("Chart ranking", chart(sha, ranking)))
            }
            None => html(404, document("Not found", not_found())),
        },
    }
}

fn worker(server: Arc<Server>, ir: ureq::Agent, ir_url: String) {
    loop {
        let Ok(req): Result<Request, _> = server.recv() else {
            continue;
        };
        let response = if *req.method() == Method::Get {
            respond(req.url(), &ir, &ir_url)
        } else {
            html(405, document("Not found", not_found()))
        };
        if let Err(e) = req.respond(response) {
            eprintln!("respond: {e}");
        }
    }
}

fn main() {
    let mut args = std::env::args().skip(1);
    let (Some(addr), Some(ir_url)) = (args.next(), args.next()) else {
        eprintln!("usage: actuon-web ADDR IR_URL");
        std::process::exit(2);
    };
    let server = Arc::new(Server::http(&addr).unwrap_or_else(|e| panic!("bind {addr}: {e}")));
    let ir: ureq::Agent = ureq::Agent::config_builder()
        .timeout_global(Some(Duration::from_secs(5)))
        .build()
        .into();
    let workers: Vec<_> = (0..WORKERS)
        .map(|_| {
            let (server, ir, ir_url) = (server.clone(), ir.clone(), ir_url.clone());
            thread::spawn(move || worker(server, ir, ir_url))
        })
        .collect();
    for w in workers {
        w.join().unwrap();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn serde_json_from<T: DeserializeOwned>(s: &str) -> T {
        serde_json::from_str(s).unwrap()
    }

    #[test]
    fn only_a_lowercase_hash_is_a_chart() {
        assert!(is_sha256(&"a0".repeat(32)));
        assert!(!is_sha256(&"A0".repeat(32)));
        assert!(!is_sha256("../../health"));
        assert!(!is_sha256(&"a".repeat(63)));
    }

    #[test]
    fn dates_are_utc_days() {
        assert_eq!(utc_date(0), "1970-01-01");
        assert_eq!(utc_date(951782400), "2000-02-29");
        assert_eq!(utc_date(1793491200), "2026-11-01");
    }

    #[test]
    fn digits_dim_only_leading_zeros() {
        assert!(digits(1842, 5).contains(">0</span>1842"));
        assert!(digits(0, 5).contains(">0000</span>0"));
    }

    #[test]
    fn the_ir_ranking_answer_parses() {
        let answer = r#"{"clears":[0,1,1,1,0,1,1,0,0,0,1],"rank":0,"total":4,"scores":[{"clear":10,"date":1,"ex":16,"max_combo":8,"miss":0,"name":"a","verified":true,"you":false}]}"#;
        let r: Ranking = serde_json_from(answer);
        assert_eq!(r.clears[FIRST_CLEAR..].iter().sum::<u32>(), 3);
    }

    #[test]
    fn a_player_name_cannot_inject_markup() {
        let scores = vec![RankedScore {
            name: "<script>x</script>".into(),
            ex: 1,
            clear: 99,
            miss: 0,
            max_combo: 1,
            date: 0,
            verified: false,
        }];
        let page = document("t", ranking_rows(scores));
        assert!(!page.contains("<script>"));
        assert!(
            page.contains("UNVERIFIED") && page.contains("MAX"),
            "an unknown lamp clamps"
        );
        // The chart's title and artist come from uploads too, and a quote must not end an attribute.
        let r: Ranking = serde_json_from(
            r#"{"title":"<b>t</b>","artist":"a\"<i>","clears":[0,0,0,0,0,0,0,0,0,0,0],"total":0,"scores":[]}"#,
        );
        let head = chart(&"a0".repeat(32), Some(r));
        assert!(!head.contains("<b>") && !head.contains("<i>"));
        assert!(head.contains(r#"<p class="artist">a&quot;&lt;i&gt;</p>"#));
        let recent = recent_rows(vec![RecentScore {
            sha256: "a0".repeat(32),
            name: "n".into(),
            ex: 0,
            clear: 0,
            miss: 0,
            date: 0,
            title: "<script>".into(),
        }]);
        assert!(!recent.contains("<script>"));
    }

    #[test]
    fn a_bad_lookup_and_a_dead_ir_are_said_plainly() {
        let dead: ureq::Agent = ureq::Agent::config_builder().build().into();
        let bad = respond("/?chart=nope", &dead, "http://127.0.0.1:1");
        assert_eq!(bad.status_code().0, 502);
        assert_eq!(
            respond("/charts/..%2Fhealth", &dead, "http://127.0.0.1:1")
                .status_code()
                .0,
            404
        );
        let found = respond(
            &format!("/?chart={}", "A0".repeat(32)),
            &dead,
            "http://127.0.0.1:1",
        );
        assert_eq!(found.status_code().0, 303);
    }
}
