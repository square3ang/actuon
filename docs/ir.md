# Internet ranking server

`server/` is a self-hosted IR in Rust. It accepts a replay, re-simulates it with the same Zig core through FFI in a child
process with a 30 s limit, and stores the score it computes itself, not one the client claims.

Scores and accounts live in SQLite in WAL mode (`ir.db`), and uploaded charts next to it in the data directory.

```sh
cd server
docker compose up -d --build
```

It listens on `127.0.0.1:8730` over plain HTTP, so put a TLS proxy in front before opening it to the internet. Use one
that buffers request bodies, as nginx does by default: a worker waits for the whole body, so a few very slow clients could
otherwise hold all eight.

Registration allows 10 accounts an hour per client address, and login 10 tries a minute per address and name. Each account
can store 64 MiB of charts and 50,000 unverified claims, the server 20 GiB of charts, and an upload must parse as a chart
with notes. Two chart or replay checks run at once, one per player, and four password hashes: the next gets a 503 until
one ends. Each check runs in a child process with a 1 GiB address space limit, a 30 s CPU limit and no way to open files.
A PMS score is refused when reading the chart as BMS finds more notes, because PMS parsing drops channels it has no lane for.

To run it without Docker:

```sh
zig build core -Doptimize=ReleaseSafe
cd server && cargo build --release
./target/release/actuon-ir 127.0.0.1:8730 ir-data
```

Run one instance on a local disk: WAL does not work over a network filesystem, and login attempt counters live in the
process, so a restart resets them. A database from an older server opens as it is.

To install or update it on a Linux host over SSH, fill in `server/.env` from `server/.env.example`, then run
`server/deploy.sh root@HOST`. It builds the images with Docker locally, copies them and the working tree to `/opt/actuon`,
installs Podman and podman-compose with dnf, starts the server and runs one backup to prove the bucket works. The host must
be RHEL-like, such as Rocky Linux.

Behind Cloudflare's proxy, run `server/cloudflare_firewall.sh` as root on a firewalld host so only Cloudflare can reach ports
80 and 443. Run it again when Cloudflare's address list changes. Set Cloudflare's SSL mode to Full (strict).

## Backups

The `backup` service sends the database and charts to any S3-compatible storage, such as Cloudflare R2, every 6 hours.
It keeps database copies for 30 days and charts for good. The bucket must exist. In `server/`:

```sh
cp .env.example .env    # then fill in the S3 values
docker compose up -d --build
docker compose logs backup
```

A failed backup is only logged, as `backup failed`, and tried again in 6 hours. Backups hold password and token hashes
and are not encrypted, so keep the bucket private.

A database with no accounts is not uploaded, so an empty one cannot become the newest copy.

To restore the newest copy, stop the server first. Add a name from the bucket's `db/` folder after `restore` to pick an
older one. The database it replaces stays as `ir.db.before-restore-TIME`, even when it is corrupt.

```sh
docker compose stop ir
docker compose run --rm --no-deps backup restore
docker compose up -d
```

Scores saved since the last backup are lost, but players can send them again with IR sync.

## Client

Client: the IR server is `https://ir.actuon.app` unless changed in Settings > Online, where Create IR account and Sign in to
IR also are, with Change IR name. A name is also what you sign in with, and it is public in rankings. Changing it keeps your
scores and rivals, and the old name stops working. Nothing goes to the server before you sign in, except when you open a ranking. The password goes to the
server and only the token it returns is saved. From a terminal, `actuon ir-register URL NAME` and `actuon ir-login URL NAME`
do the same with the password on stdin. Use `actuon ir-rival NAME` to add a rival. A server that lacks a chart asks the client to upload it, so it holds copies of
the charts played on it. Check that you are allowed to host them.

Settings > Online has IR sync. Upload sends every saved replay that beats your best verified EX or clear on the server.
Local scores still ahead of the server after that, such as ones imported from beatoraja or LR2, go to `POST /me/claims`.
Nothing checks a claim, so anyone can claim any score. Rankings mark it unverified and place it below every verified score,
table standings leave it out, and any verified score of the same player on that chart replaces it. Download merges your rows on the server into the local database through `GET /me/scores`.
Neither direction lowers a score.

Once signed in, song select fetches the selected chart's ranking after the cursor rests for 0.4 s. It shows in the built-in
BEST panel and reaches select skins through the same ids as below, and skins' IR online option turns on.

Result skins get the chart's ranking, your rank before and after the upload, and the clear counts through beatoraja's IR
ids. Your own row is named `YOU`, and unverified rows end in `(unv.)`. The wheel, Up and Down, and the skin's slider
scroll the list through the first 1000 places.

`tests/ir_e2e.py` runs the whole round trip.

Replays played in CN or HCN mode on a chart that leaves its LN type open are refused: they change the note count, so they cannot rank on the chart's board.

## Versus rooms

Players on one server race the same chart with the same seed. Rooms live in memory, so a restart ends them.

| Request | Does |
| --- | --- |
| `POST /rooms` `{sha256,title}` | Creates a room, returns `code` |
| `POST /rooms/CODE/join`, `/leave` | Enters or leaves. A player is in one room at a time |
| `POST /rooms/CODE/chart` `{sha256,title}` | Host only: changes the chart |
| `POST /rooms/CODE/start` | Host only: starts a round after 8 seconds. 409 while one is about to start, as for `/chart` |
| `POST /rooms/CODE/report` `{round,has_chart,ex,judged,gauge,done}` | Sends this player's live numbers, returns the room |

The responses to `POST /rooms` and `/join` also hold `key` and `udp`. With `IR_UDP_PUBLIC=host:port` set, the server listens
on `IR_UDP_BIND` (default `0.0.0.0:8740`) and clients send their live numbers there ten times a second, in little-endian:

| Packet | Layout |
| --- | --- |
| Request, 47 bytes | `AU1Q`, code (6), key (16), seq, round, ex, judged, gauge (f32), flags (u8: 1 has chart, 2 done) |
| Reply | `AU1R`, seq, round, ms until start (`0xFFFFFFFF` for none), count (u8), then per player: id, ex, judged, gauge (f32), done (u8) |

A packet without a player's key gets no reply, so a forged source address cannot aim replies at someone else. With no UDP
reply for 2 seconds, as on a network that blocks it, the client reports over HTTP four times a second instead. Without
`IR_UDP_PUBLIC`, every client does. HTTP still carries names, the chart, the seed and final scores.

UDP cannot pass through Cloudflare's proxy, and the address in `IR_UDP_PUBLIC` is given to every player in a room. Pointing
it at the origin reveals an address the proxy otherwise hides, so use a separate host or address if that matters. Open the
port too: `firewall-cmd --permanent --add-port=8740/udp && firewall-cmd --reload`.

A replay counts for a round only with that round's chart and seed, and only the first one does.

Reported numbers are only shown while the round runs. A round is decided by `final_ex`, which is set when the
player's replay passes the usual check: `POST /scores/SHA?format=N&room=CODE`.

## Web page

`web/` renders recent verified scores and each chart's ranking as plain HTML from this API, with no script in the browser. `GET /recent?limit=` (1 to 100, default 50) is the public feed behind it.

```sh
web/target/release/actuon-web 127.0.0.1:8731 http://127.0.0.1:8730
```

The server names a chart when it checks the upload. Older charts get named once, in the background, after the first start.

To share the API's host name, send the page's paths to it and leave everything else on the API. `PUT /charts/{sha}` stays on the API, so split that path by method:

```nginx
map $request_method $ir_charts { GET 127.0.0.1:8731; default 127.0.0.1:8730; }
# Inside the server block:
location = / { proxy_pass http://127.0.0.1:8731; }
location ~ ^/(style\.css|logo\.svg|icon\.svg|fonts/) { proxy_pass http://127.0.0.1:8731; }
location /charts/ { proxy_pass http://$ir_charts; proxy_set_header Host $host; proxy_set_header X-Real-IP $http_cf_connecting_ip; }
```

Register and login attempts count per client, so the proxy must name the client in `X-Real-IP`. Without it, every player
shares the proxy's count, and ten signups an hour lock out everyone. Set it in the server block, and again in any location
with its own `proxy_set_header`, because nginx does not inherit into those:

```nginx
# Behind Cloudflare, where the firewall admits nothing else. Without Cloudflare, use $remote_addr.
proxy_set_header X-Real-IP $http_cf_connecting_ip;
```

Keep port 8730 closed to everything but the proxy: anyone reaching it directly can name any address.
