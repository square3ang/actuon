# Internet ranking server

`server/` is a self-hosted IR in Rust. It accepts a replay, re-simulates it with the same Zig core through FFI in a child
process with a 30 s limit, and stores the score it computes itself, not one the client claims.

Scores and accounts live in PostgreSQL, login attempt counters in Redis, and uploaded charts in the data directory.

```sh
cd server
cp .env.example .env    # then set POSTGRES_PASSWORD
docker compose up -d --build
```

It listens on `127.0.0.1:8730` over plain HTTP, so put a TLS proxy in front before opening it to the internet. Use one
that buffers request bodies, as nginx does by default: a worker waits for the whole body, so a few very slow clients could
otherwise hold all eight.

Registration allows 60 accounts an hour across the server. Each account can store 512 MiB of charts, and an upload must
parse as a chart with notes. Four chart or replay checks run at once, and the next gets a 503 until one ends. Each check
runs in a child process with a 4 GiB address space limit.

To run it without Docker, set `DATABASE_URL` and `REDIS_URL`, then:

```sh
zig build core -Doptimize=ReleaseSafe
cd server && cargo build --release
./target/release/actuon-ir 127.0.0.1:8730 ir-data
```

To move an older SQLite server, start the new one once so it creates the tables, then run the following in `server/`:

```sh
python3 migrate_sqlite.py ir-data/ir.db | docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U actuon actuon
docker compose cp ir-data/charts ir:/data
```

The `ir` container runs as a non-root user, so check that it owns the copied charts with
`docker compose exec -u root ir chown -R ir:ir /data/charts`.

Client: set `ir_url` in `config.json`, then run `actuon ir-register URL NAME` with the password on stdin. Use
`actuon ir-rival NAME` to add a rival. A server that lacks a chart asks the client to upload it, so it holds copies of
the charts played on it. Check that you are allowed to host them.

Settings > Online has IR sync. Upload sends every saved replay that beats your best verified EX or clear on the server.
Local scores still ahead of the server after that, such as ones imported from beatoraja or LR2, go to `POST /me/claims`.
Nothing checks a claim, so anyone can claim any score. Rankings mark it unverified and place it below every verified score,
table standings leave it out, and any verified score of the same player on that chart replaces it. Download merges your rows on the server into the local database through `GET /me/scores`.
Neither direction lowers a score.

Result skins get the chart's ranking, your rank before and after the upload, and the clear counts through beatoraja's IR
ids. Your own row is named `YOU`, and unverified rows end in `(unv.)`. The wheel, Up and Down, and the skin's slider
scroll the list through the first 1000 places.

`tests/ir_e2e.py` runs the whole round trip.

Replays played in CN or HCN mode on a chart that leaves its LN type open are refused: they change the note count, so they cannot rank on the chart's board.
