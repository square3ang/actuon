# Internet ranking server

`server/` is a self-hosted IR in Rust. It accepts a replay, re-simulates it with the same Zig core through FFI in a child
process with a 30 s limit, and stores the score it computes itself, not one the client claims.

Each score comes with its chart: `POST /scores/SHA?format=N&chart=LEN`, whose body is the chart's LEN bytes and then the
replay. The chart must hash to SHA. The server checks both and keeps only the chart's title and artist, never the file.

Scores and accounts live in SQLite in WAL mode (`ir.db`) in the data directory.

It listens on `127.0.0.1:8730` over plain HTTP, so put a TLS proxy in front before opening it to the internet. Use one
that buffers request bodies, as nginx does by default: the server holds each body in memory until it is whole, so many very
slow clients would otherwise add up. A score upload can be 32 MiB, a 16 MiB chart and a 16 MiB replay, so let the proxy take that
much (`client_max_body_size 32m`).

Registration allows 10 accounts a day per client address, and login 10 tries a minute per address and name. Each account
can hold 50,000 unverified claims, and a chart must parse with notes. Two checks run at once, one per player, and four password hashes: the next gets a 503 until
one ends. A chart longer than an hour, or a replay that runs ten minutes past its chart, is refused, so no check
runs long. A name is 1 to 32 letters, digits, spaces inside, or `_ - . /`. Each check runs in a child process with a 1 GiB address space limit, a 30 s CPU limit and no way to open files.
A PMS score is refused when reading the chart as BMS finds more notes, because PMS parsing drops channels it has no lane for.

To run it by hand:

```sh
zig build core -Doptimize=ReleaseSafe
cd server && cargo build --release
./target/release/actuon-ir 127.0.0.1:8730 ir-data
```

Run one instance on a local disk: WAL does not work over a network filesystem, and rooms live in the process. Login and
registration attempts are counted in the database, so a restart keeps them. A database from an older server opens as it is.

To install or update it on a Linux host over SSH, fill in `server/.env` from `server/.env.example`, then run
`server/deploy.sh root@HOST`. It builds static binaries of the server and the web page here, which needs
`rustup target add x86_64-unknown-linux-musl`. It copies them to `/opt/actuon/bin` and installs them as the systemd services
`actuon-ir` and `actuon-web`. The data lives in `/var/lib/actuon`, and one backup runs to prove the bucket works. The host
must be RHEL-like, such as Rocky Linux. A host set up by the old Docker deploy has its data moved out of the Podman volume
once, and the volume is kept.

Behind Cloudflare's proxy, run `server/cloudflare_firewall.sh` as root on a firewalld host so only Cloudflare can reach ports
80 and 443. Run it again when Cloudflare's address list changes. Set Cloudflare's SSL mode to Full (strict).

## Backups

The `actuon-backup.timer` sends the database to any S3-compatible storage, such as Cloudflare R2, every 6 hours. It
keeps copies for 30 days. The bucket must exist, and `server/.env` names it.

A failed backup shows in `systemctl --failed` and `journalctl -u actuon-backup`, and the timer tries again in 6 hours.
Backups hold password and token hashes and are not encrypted, so keep the bucket private.

A database with no accounts is not uploaded, so an empty one cannot become the newest copy.

To restore the newest copy, stop the server first. Add a name from the bucket's `db/` folder after `restore` to pick an
older one. The database it replaces stays as `ir.db.before-restore-TIME`, even when it is corrupt.

```sh
systemctl stop actuon-ir
systemd-run --wait --pipe -p User=actuon -p EnvironmentFile=/etc/actuon/backup.env -E DATA_DIR=/var/lib/actuon \
    sh /opt/actuon/bin/backup.sh restore
systemctl start actuon-ir
```

Scores saved since the last backup are lost, but players can send them again with IR sync.

## Client

Client: the IR server is `https://ir.actuon.app` unless changed in Settings > Online, where Create IR account and Sign in to
IR also are, with Change IR name. A name is also what you sign in with, and it is public in rankings. Changing it keeps your
scores and rivals, and the old name stops working. Nothing goes to the server before you sign in, except when you open a ranking. The password goes to the
server and only the token it returns is saved. From a terminal, `actuon ir-register URL NAME` and `actuon ir-login URL NAME`
do the same with the password on stdin. Use `actuon ir-rival NAME` to add a rival. Every score upload
sends its chart along, and a score whose chart file is gone from the library cannot be sent.

Settings > Online has IR sync. Upload sends every saved replay that beats your best verified EX or clear on the server.
Local scores still ahead of the server after that, such as ones imported from beatoraja or LR2, go to `POST /me/claims`.
Nothing checks a claim, so anyone can claim any score. Rankings mark it unverified and place it below every verified score,
table standings leave it out, and any verified score of the same player on that chart replaces it. Download merges your rows on the server into the local database through `GET /me/scores`.
Neither direction lowers a score.

Once signed in, song select fetches the selected chart's ranking after the cursor rests for 0.4 s. It shows in the built-in
BEST panel and reaches select skins through the same ids as below, and skins' IR online option turns on.

Result skins get the chart's ranking, your rank before and after the upload, and the clear counts through beatoraja's IR
ids. Your own row is named `YOU`, and unverified rows end in `(unv.)`. The wheel, Up and Down, and the skin's slider
scroll the whole list: `GET /scores/SHA?limit=N&offset=M` sends up to 1000 places at a time, and the next page is fetched
as the list scrolls past the one loaded.

`tests/ir_e2e.py` runs the whole round trip.

Replays played in CN or HCN mode on a chart that leaves its LN type open are refused: they change the note count, so they cannot rank on the chart's board.

## Versus rooms

Players on one server race the same chart with the same seed. Rooms live in memory, so a restart ends them.

Everything about a room goes over one WebSocket per player: `GET /play` with the usual `Authorization` header, on the
same port and through the same proxy as the rest of the API. Nothing falls back to plain HTTP. Each message is a JSON text
with a `type`, and each gets exactly one answer: the room (`"type": "room"`) or `{"type": "error", "status", "error"}`, with
an HTTP status number to tell the cases apart.

| Message | Does |
| --- | --- |
| `{type: "create", sha256, title}` | Creates a room; the answer holds its `code`. Both empty opens it with no chart, and `start` is a 400 until the host sets one |
| `{type: "join", code}` | Enters a room. A player is in one room at a time |
| `{type: "chart", sha256, title}` | Host only: changes the chart |
| `{type: "start"}` | Host only: starts a round after 8 seconds. 409 while one is about to start, as for `chart` |
| `{type: "report", round, has_chart, ex, judged, gauge, done}` | This player's live numbers |

The room answer holds `starts_in_ms` until the round starts. A player whose chart loads after that starts the song as far
in as the others are, and the notes it skipped count as missed.

Closing a player's last connection leaves the room, so a client that reconnects keeps its seat while the server still
holds the dropped connection. A player can have four connections open. The client reports ten times a second; the server answers no faster than once per
40 ms per player, and at most 1024 players are connected at once. Room list and matchmaking are to come as more types.

nginx drops the upgrade unless told to pass it on, which turns every room request into a 400:

```nginx
location = /play {
    proxy_pass http://127.0.0.1:8730;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
}
```

A replay counts for a round only with that round's chart and seed, and only the first one does.

Reported numbers are only shown while the round runs. A round is decided by `final_ex`, which is set when the
player's replay passes the usual check: `POST /scores/SHA?format=N&chart=LEN&room=CODE`.

## Web page

`web/` renders recent verified scores and each chart's ranking as plain HTML from this API, with no script in the browser. `GET /recent?limit=` (1 to 100, default 50) is the public feed behind it.

```sh
web/target/release/actuon-web 127.0.0.1:8731 http://127.0.0.1:8730
```

The server names a chart each time it checks a score on it.

To share the API's host name, send the page's paths to it and leave everything else on the API:

```nginx
location = / { proxy_pass http://127.0.0.1:8731; }
location ~ ^/(style\.css|logo\.svg|icon\.svg|fonts/) { proxy_pass http://127.0.0.1:8731; }
location /charts/ { proxy_pass http://127.0.0.1:8731; proxy_set_header Host $host; proxy_set_header X-Real-IP $http_cf_connecting_ip; }
```

Register and login attempts count per client, so the proxy must name the client in `X-Real-IP`. Without it, every player
shares the proxy's count, and ten signups a day lock out everyone. Set it in the server block, and again in any location
with its own `proxy_set_header`, because nginx does not inherit into those:

```nginx
# Behind Cloudflare, where the firewall admits nothing else. Without Cloudflare, use $remote_addr.
proxy_set_header X-Real-IP $http_cf_connecting_ip;
```

Keep port 8730 closed to everything but the proxy: anyone reaching it directly can name any address.
