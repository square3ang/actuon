#!/usr/bin/env python3
"""Usage: ir_e2e.py SERVER_BIN MKREPLAY CHART WORKDIR"""
import hashlib, json, os, socket, struct, subprocess, sys, time, urllib.error, urllib.parse, urllib.request

server, mkreplay, chart, work = sys.argv[1:5]
base = "http://127.0.0.1:18731"

def call(method, path, body=None, token=None, ip=None):
    headers = {"Authorization": "Bearer " + token} if token else {}
    if ip:
        headers["X-Real-IP"] = ip
    if isinstance(body, dict):
        body = json.dumps(body).encode()
    req = urllib.request.Request(base + path, data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        return e.code, json.load(e)

replay_path = os.path.join(work, "perfect.actr")
out = subprocess.run([mkreplay, chart, replay_path], capture_output=True, text=True, check=True)
sha, notes = out.stderr.split()[0], int(out.stderr.split()[1])
replay = open(replay_path, "rb").read()

def start_server():
    started = subprocess.Popen([server, "127.0.0.1:18731", os.path.join(work, "ir")], stderr=subprocess.DEVNULL)
    for _ in range(100):
        try:
            if call("GET", "/health")[0] == 200:
                break
        except OSError:
            time.sleep(0.1)
    return started

def stop_server():
    proc.terminate()
    proc.wait()

chart_bytes = open(chart, "rb").read()

def score(sha, token, replay=replay, chart=chart_bytes, query="format=1"):
    return call("POST", f"/scores/{sha}?{query}&chart={len(chart)}", chart + replay, token)

proc = start_server()
try:
    assert call("POST", "/register", {"name": "a", "password": "short"})[0] == 400
    status, r = call("POST", "/register", {"name": "alice", "password": "correct horse"})
    assert status == 200, r
    alice = r["token"]
    assert call("POST", "/register", {"name": "alice", "password": "correct horse"})[0] == 409
    assert call("POST", "/login", {"name": "alice", "password": "wrong password"})[0] == 401
    status, r = call("POST", "/login", {"name": "alice", "password": "correct horse"})
    assert status == 200
    old, alice = alice, r["token"]
    assert score(sha, old)[0] == 401, "rotated token must die"
    assert score(sha, None)[0] == 401
    assert call("POST", f"/scores/{sha}?format=1", replay, alice)[0] == 400, "a score needs its chart"
    assert call("POST", f"/scores/{sha}?format=1&chart={10**9}", replay, alice)[0] == 400, "the chart length must fit the upload"
    assert score(sha, alice, chart=b"tampered" + chart_bytes)[0] == 400
    garbage = b"not a chart"
    assert score(hashlib.sha256(garbage).hexdigest(), alice, chart=garbage)[0] == 422, "only playable charts count"
    assert score(sha, alice, query="x=1")[0] == 400, "the format comes with each score"
    status, r = score(sha, alice)
    assert status == 200, r
    assert r["ex"] > notes, r  # a perfect stream scores near the max, computed by the server
    assert r["prev_rank"] == 0, r
    best = r["ex"]
    assert score(sha, alice, replay=b"ACTRgarbage")[0] == 422
    assert sorted(os.listdir(os.path.join(work, "ir"))) == ["ir.db", "ir.db-shm", "ir.db-wal"], "the server keeps no chart"
    assert call("GET", "/scores/" + "../etc")[0] in (400, 404)
    first_date = call("GET", "/me/scores", None, alice)[1]["scores"][0]["date"]
    time.sleep(1.1)
    assert score(sha, alice)[0] == 200
    assert call("GET", "/me/scores", None, alice)[1]["scores"][0]["date"] == first_date, "no improvement, so the tiebreak date stays"
    recent = call("GET", "/recent")[1]["scores"]
    assert recent and recent[0]["sha256"] == sha and recent[0]["title"] == call("GET", f"/scores/{sha}")[1]["title"] != "" and "pass" not in recent[0] and "token" not in recent[0]
    status, r = call("GET", f"/scores/{sha}")
    assert r["scores"][0] == {**r["scores"][0], "name": "alice", "ex": best}, r
    assert call("GET", "/me/scores")[0] == 401
    status, r = call("GET", "/me/scores", None, alice)
    assert status == 200 and [(s["sha256"], s["ex"]) for s in r["scores"]] == [(sha, best)], r
    bob = call("POST", "/register", {"name": "bob", "password": "battery staple"})[1]["token"]
    assert call("GET", "/me/scores", None, bob)[1]["scores"] == [], "scores are per player"
    claim = {"sha256": sha, "clear": 5, "ex": best - 1, "max_combo": 1, "miss": 0, "date": 1}
    assert call("POST", "/me/claims", {"scores": [claim]})[0] == 401
    assert call("POST", "/me/claims", {"scores": [{**claim, "sha256": "../x"}]}, bob)[0] == 400
    assert call("POST", "/me/claims", {"scores": [claim]}, bob)[0] == 200
    rows = call("GET", f"/scores/{sha}")[1]["scores"]
    assert [(s["name"], s["verified"]) for s in rows] == [("alice", True), ("bob", False)], rows
    assert call("POST", "/me/claims", {"scores": [{**claim, "ex": best + 1}]}, alice)[0] == 200
    rows = call("GET", f"/scores/{sha}")[1]["scores"]
    assert [(s["name"], s["ex"], s["verified"]) for s in rows][0] == ("alice", best, True), "a verified score replaces any claim of its player"
    assert call("POST", "/me/claims", {"scores": [{**claim, "ex": 4000000000}]}, bob)[0] == 200
    rows = call("GET", f"/scores/{sha}")[1]["scores"]
    assert [(s["name"], s["verified"]) for s in rows] == [("alice", True), ("bob", False)], "a claim stays below verified scores"
    assert len([s for s in rows if s["name"] == "alice"]) == 1, "one row per player"
    status, r = score(sha, bob)
    assert status == 200 and r["prev_rank"] == 2, r  # the claim's place, before this score counted
    status, r = score(sha, bob)
    assert status == 200 and r["prev_rank"] == 2, r
    rows = call("GET", f"/scores/{sha}")[1]["scores"]
    assert ("bob", best, True) in [(s["name"], s["ex"], s["verified"]) for s in rows], "a verified score replaces a lower claim"
    assert sorted(s["verified"] for s in call("GET", "/me/scores", None, alice)[1]["scores"]) == [False, True]
    assert call("PUT", "/rivals/nobody", None, bob)[0] == 404
    assert call("PUT", "/rivals/alice", None, bob)[0] == 200
    assert call("GET", "/rivals", None, bob)[1]["rivals"] == ["alice"]
    assert [(s["name"], s["verified"]) for s in call("GET", f"/scores/{sha}/rivals", None, bob)[1]["scores"]] == [("alice", True), ("bob", True)]
    wide = "\ud55c \uae00/x"
    assert call("POST", "/register", {"name": wide, "password": "correct horse"})[0] == 200
    encoded = urllib.parse.quote(wide, safe="")
    assert call("PUT", f"/rivals/{encoded}", None, bob)[0] == 200
    assert wide in call("GET", "/rivals", None, bob)[1]["rivals"]
    assert call("DELETE", f"/rivals/{encoded}", None, bob)[0] == 200
    assert wide not in call("GET", "/rivals", None, bob)[1]["rivals"]
    players = call("POST", "/table-ranking", {"sha256": [sha]})[1]["players"]
    assert [(p["name"], p["ex"], p["played"]) for p in players] == [("alice", best, 1), ("bob", best, 1)], "claims stay out of totals"
    r = call("GET", f"/scores/{sha}?limit=1", None, bob)[1]
    assert (r["rank"], r["total"], sum(r["clears"]), len(r["scores"])) == (2, 2, 2, 1), r
    assert r["scores"][0]["you"] is False
    r = call("GET", f"/scores/{sha}?limit=1&offset=1", None, bob)[1]
    assert (r["offset"], r["total"], [s["you"] for s in r["scores"]]) == (1, 2, [True]), "a page starts at its offset"
    r = call("GET", f"/scores/{sha}", None, bob)[1]
    assert [s["you"] for s in r["scores"]] == [False, True], r
    assert call("GET", f"/scores/{sha}")[1]["rank"] == 0, "no token, no rank"
    assert call("GET", f"/scores/{sha}", None, "bad token")[0] == 200
    assert call("POST", "/table-ranking", {"sha256": ["../x"]})[0] == 400
    assert call("POST", "/me/name", {"name": "alicia"})[0] == 401
    assert call("POST", "/me/name", {"name": ""}, alice)[0] == 400
    assert call("POST", "/me/name", {"name": "x" * 33}, alice)[0] == 400
    assert call("POST", "/me/name", {"name": "bob"}, alice)[0] == 409
    assert call("POST", "/me/name", {"name": "alice"}, alice)[0] == 200, "keeping your own name is no conflict"
    assert call("POST", "/me/name", {"name": "alicia"}, alice)[0] == 200
    rows = call("GET", f"/scores/{sha}")[1]["scores"]
    assert ("alicia", best) in [(s["name"], s["ex"]) for s in rows] and "alice" not in [s["name"] for s in rows], "scores follow the new name"
    assert call("GET", "/rivals", None, bob)[1]["rivals"] == ["alicia"], "rivals follow the new name"
    assert call("POST", "/login", {"name": "alice", "password": "correct horse"})[0] == 401, "the old name no longer logs in"
    assert call("POST", "/login", {"name": "alicia", "password": "correct horse"})[0] == 200
    guess = {"name": "nobody", "password": "wrong password"}
    assert [call("POST", "/login", guess)[0] for _ in range(11)] == [401] * 10 + [429], "attempts are counted"
    stop_server()
    proc = start_server()
    assert call("POST", "/login", guess)[0] == 429, "a restart keeps the count"
    assert call("POST", "/login", guess, None, "198.51.100.1")[0] == 401, "another client has its own count"
    account = {"name": "throttled", "password": "correct horse"}
    tries = [call("POST", "/register", {**account, "name": f"throttled{i}"}, None, "198.51.100.2")[0] for i in range(11)]
    assert tries == [200] * 10 + [429], tries
    assert call("POST", "/register", account, None, "198.51.100.3")[0] == 200, "one client's signups leave others alone"

    def bms(name, channels):
        path = os.path.join(work, name)
        with open(path, "w") as f:
            f.write("#TITLE format\n#BPM 120\n#WAV01 a.wav\n" + "".join(f"#001{c}:01\n" for c in channels))
        made = path + ".actr"
        hash_ = subprocess.run([mkreplay, path, made], capture_output=True, text=True, check=True).stderr.split()[0]
        return hash_, open(path, "rb").read(), open(made, "rb").read()

    # PMS has no lane for channel 16, so naming the format would leave only the easy note to judge.
    cut_sha, cut_chart, cut_replay = bms("cut.bms", ["11", "16"])
    assert score(cut_sha, bob, cut_replay, cut_chart, "format=2")[0] == 422, "a format that drops notes is refused"
    assert score(cut_sha, bob, cut_replay, cut_chart)[0] == 200
    pms_sha, pms_chart, pms_replay = bms("real.pms", ["11", "22"])
    assert score(pms_sha, bob, pms_replay, pms_chart, "format=2")[0] == 200, "a real PMS chart still ranks"

    host = call("POST", "/register", {"name": "roomhost", "password": "correct horse"})[1]["token"]
    guest = call("POST", "/register", {"name": "roomguest", "password": "correct horse"})[1]["token"]
    import base64
    class Play:
        def __init__(self, token, key="dGhlIHNhbXBsZSBub25jZQ=="):
            self.sock = socket.create_connection(("127.0.0.1", 18731), timeout=10)
            auth = f"Authorization: Bearer {token}\r\n" if token else ""
            self.sock.sendall(f"GET /play HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: {key}\r\n{auth}\r\n".encode())
            head = b""
            while b"\r\n\r\n" not in head:
                head += self.sock.recv(1)
            self.status = int(head.split()[1])
            want = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
            assert self.status != 101 or want.encode() in head, head
        def recv_exact(self, n):
            data = b""
            while len(data) < n:
                data += self.sock.recv(n - len(data))
            return data
        def ask(self, message):
            payload = json.dumps(message).encode()
            mask = os.urandom(4)
            size = bytes([0x80 | len(payload)]) if len(payload) < 126 else bytes([0x80 | 126]) + struct.pack(">H", len(payload))
            self.sock.sendall(bytes([0x81]) + size + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))
            head = self.recv_exact(2)
            n = head[1] & 0x7F
            if n == 126:
                n = struct.unpack(">H", self.recv_exact(2))[0]
            return json.loads(self.recv_exact(n))
        def close(self):
            self.sock.close()

    assert Play(None).status == 401, "a room needs a player"
    assert call("GET", "/play", None, host)[0] == 400, "plain HTTP gets no room"
    host_play, guest_play = Play(host), Play(guest)
    assert host_play.status == 101 and guest_play.status == 101
    assert host_play.ask({"type": "create", "sha256": "../x", "title": "t"})["status"] == 400, "a room's chart hash is checked"
    room = host_play.ask({"type": "create", "sha256": sha, "title": "t"})["code"]
    assert guest_play.ask({"type": "join", "code": "ZZZZZZ"})["status"] == 404
    assert guest_play.ask({"type": "join", "code": "a/b"})["status"] == 404, "a bad code is refused"
    assert len(guest_play.ask({"type": "join", "code": room})["players"]) == 2
    assert guest_play.ask({"type": "start"})["status"] == 403, "only the host starts"
    assert host_play.ask({"type": "start"})["round"] == 1
    assert host_play.ask({"type": "start"})["status"] == 409, "players are still loading"
    claim = {"type": "report", "round": 1, "has_chart": True, "ex": 1234, "judged": 5, "gauge": 50, "done": False}
    seen = guest_play.ask(claim)
    assert 0 < seen["starts_in_ms"] <= 8000 and seen["seed"] == host_play.ask({**claim, "ex": 0})["seed"]
    assert all(p["final_ex"] is None for p in seen["players"]), "a reported score decides nothing"
    seen = host_play.ask({**claim, "ex": 0})
    assert [p["ex"] for p in seen["players"] if p["name"] == "roomguest"] == [1234], "a live score reaches the room"
    assert score(sha, guest, query=f"format=1&room={room}")[0] == 200
    seen = host_play.ask({**claim, "ex": 0})
    assert all(p["final_ex"] is None for p in seen["players"]), "a replay from another round decides nothing"
    subprocess.run([mkreplay, chart, replay_path + ".round", seen["seed"]], capture_output=True, check=True)
    round_replay = open(replay_path + ".round", "rb").read()
    assert score(sha, guest, round_replay, query=f"format=1&room={room}")[0] == 200
    seen = host_play.ask({**claim, "ex": 0})
    assert [p["final_ex"] for p in seen["players"] if p["name"] == "roomguest"] == [notes * 2], "the checked replay decides"
    rejoined = Play(guest)
    assert len(rejoined.ask({"type": "join", "code": room})["players"]) == 2
    guest_play.close()
    time.sleep(0.2)
    assert len(host_play.ask({**claim, "ex": 0})["players"]) == 2, "an old connection closing keeps a player who reconnected"
    spare = [Play(guest) for _ in range(3)]
    assert [p.status for p in spare] == [101, 101, 101] and Play(guest).status == 429, "one player cannot take every connection"
    for p in spare:
        p.close()
    rejoined.close()
    time.sleep(0.2)
    assert len(host_play.ask({**claim, "ex": 0})["players"]) == 1, "a closed connection leaves the room"
    host_play.close()

    def varint(b, i):
        v = shift = 0
        while True:
            v |= (b[i] & 0x7F) << shift
            i += 1
            if b[i - 1] < 0x80:
                return v, i
            shift += 7
    def put(v):
        out = b""
        while v >= 0x80:
            out += bytes([v & 0x7F | 0x80])
            v >>= 7
        return out + bytes([v])
    def head(rep):
        _, i = varint(rep, 74)  # seed
        n, i = varint(rep, i)
        for _ in range(n):
            _, i = varint(rep, i)
        return rep[:i]
    def events(rep):
        count, i = varint(rep, len(head(rep)))
        evs, t = [], 0
        for _ in range(count):
            z, i = varint(rep, i)
            t += (z >> 1) ^ -(z & 1)
            evs.append((t, rep[i]))
            i += 1
        return evs
    def rebuild(rep, evs, gauge=None):
        out, t = bytearray(head(rep) + put(len(evs))), 0
        for when, key in evs:
            out += put(((when - t) << 1) ^ ((when - t) >> 63)) + bytes([key])
            t = when
        if gauge is not None:
            out[69] = gauge
        return bytes(out)
    long_path = os.path.join(work, "long.bms")
    with open(long_path, "w") as f:
        f.write("#BPM 120\n#WAV01 a.wav\n" + "".join(f"#00{m}11:{'01' * 16}\n" for m in range(1, 5)))
    long_out = subprocess.run([mkreplay, long_path, long_path + ".actr"], capture_output=True, text=True, check=True).stderr.split()
    long_sha, long_notes, long_chart = long_out[0], int(long_out[1]), open(long_path, "rb").read()
    long_replay = open(long_path + ".actr", "rb").read()
    perfect = events(long_replay)
    merger = call("POST", "/register", {"name": "merger", "password": "correct horse"})[1]["token"]
    # Drop the middle note: the best EX, but a broken combo and one BP.
    mid = len(perfect) // 4 * 2
    status, broken = score(long_sha, merger, rebuild(long_replay, perfect[:mid] + perfect[mid + 2:]), long_chart)
    assert status == 200 and broken["miss"] == 1 and broken["max_combo"] < long_notes, broken
    # Every note late: less EX, but a full combo and no BP.
    status, late = score(long_sha, merger, rebuild(long_replay, [(t + 50_000, k) for t, k in perfect]), long_chart)
    assert status == 200 and late["ex"] < broken["ex"] and late["max_combo"] == long_notes and late["miss"] == 0, late
    got = call("GET", "/me/scores", None, merger)[1]["scores"]
    assert [(s["ex"], s["max_combo"], s["miss"]) for s in got] == [(broken["ex"], long_notes, 0)], "each field keeps its own best"
    # A HARD gauge that empties stops judging, and the notes it never reached are BP too.
    status, failed = score(long_sha, merger, rebuild(long_replay, [], gauge=3), long_chart)
    assert status == 200 and failed["clear"] == 1 and failed["miss"] == long_notes, failed
    other = "e" * 64
    assert call("POST", "/me/claims", {"scores": [{"sha256": other, "clear": 4, "ex": 90, "max_combo": 5, "miss": 9, "date": 1}]}, merger)[0] == 200
    assert call("POST", "/me/claims", {"scores": [{"sha256": other, "clear": 1, "ex": 10, "max_combo": 50, "miss": 2, "date": 1}]}, merger)[0] == 200
    got = [(s["clear"], s["ex"], s["max_combo"], s["miss"]) for s in call("GET", "/me/scores", None, merger)[1]["scores"] if s["sha256"] == other]
    assert got == [(4, 90, 50, 2)], "a claim keeps each field's best too"

    hoarder = call("POST", "/register", {"name": "hoarder", "password": "correct horse"})[1]["token"]
    def claims(start):
        return {"scores": [{"sha256": f"{i:064x}", "clear": 0, "ex": 0, "max_combo": 0, "miss": 0, "date": 1} for i in range(start, start + 7000)]}
    sent = [call("POST", "/me/claims", claims(n * 7000), hoarder)[0] for n in range(8)]
    assert sent == [200] * 7 + [429], sent
    assert len(call("GET", "/me/scores", None, hoarder)[1]["scores"]) == 49000, "a refused batch stores nothing"
    assert call("POST", "/me/claims", claims(0), hoarder)[0] == 200, "sending held rows again adds nothing"
    print(f"IR e2e OK: ex {best} of max {notes * 2}")
finally:
    stop_server()
