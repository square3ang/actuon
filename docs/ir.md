# Internet ranking server

`server/` is a self-hosted IR in Rust. It accepts a replay, re-simulates it with the same Zig core through FFI in a child
process with a 30 s limit, and stores the score it computes itself, not one the client claims.

```sh
zig build core -Doptimize=ReleaseSafe
cd server && cargo build --release
./target/release/actuon-ir 127.0.0.1:8730 ir-data
```

Client: set `ir_url` in `config.json`, then run `actuon ir-register URL NAME` with the password on stdin. Use
`actuon ir-rival NAME` to add a rival. A server that lacks a chart asks the client to upload it, so it holds copies of
the charts played on it. Check that you are allowed to host them.

`tests/ir_e2e.py` runs the whole round trip.
