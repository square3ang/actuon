#!/usr/bin/env python3
"""End-to-end IR test: server re-simulation decides the score. Usage: ir_e2e.py SERVER_BIN MKREPLAY CHART WORKDIR"""
import hashlib, json, os, socket, sqlite3, struct, subprocess, sys, time, urllib.error, urllib.parse, urllib.request

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
    env = {**os.environ, "IR_UDP_PUBLIC": "127.0.0.1:18732", "IR_UDP_BIND": "127.0.0.1:18732"}
    started = subprocess.Popen([server, "127.0.0.1:18731", os.path.join(work, "ir")], stderr=subprocess.DEVNULL, env=env)
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

def title_of(sha):
    return call("GET", f"/scores/{sha}")[1]["title"]

def clear_titles(version):
    db = sqlite3.connect(os.path.join(work, "ir", "ir.db"))
    db.execute("UPDATE chart SET title=''")
    db.execute(f"PRAGMA user_version={version}")
    db.commit()
    db.close()

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
    assert call("POST", f"/scores/{sha}?format=1", replay, old)[0] == 401, "rotated token must die"
    assert call("POST", f"/scores/{sha}?format=1", replay)[0] == 401
    assert call("POST", f"/scores/{sha}?format=1", replay, alice)[0] == 428
    chart_bytes = open(chart, "rb").read()
    assert call("PUT", f"/charts/{sha}?format=1", b"tampered" + chart_bytes, alice)[0] == 400
    garbage = b"not a chart"
    assert call("PUT", f"/charts/{hashlib.sha256(garbage).hexdigest()}?format=1", garbage, alice)[0] == 422, "only playable charts are stored"
    assert call("PUT", f"/charts/{sha}?format=1", chart_bytes, alice)[0] == 200
    assert call("PUT", f"/charts/{sha}?format=1", chart_bytes, alice)[0] == 200, "a chart already held costs nothing"
    assert not [f for f in os.listdir(os.path.join(work, "ir", "charts")) if ".tmp" in f], "no temporary files stay behind"
    assert call("POST", f"/scores/{sha}", replay, alice)[0] == 400, "the format comes with each score"
    status, r = call("POST", f"/scores/{sha}?format=1", replay, alice)
    assert status == 200, r
    assert r["ex"] > notes, r  # a perfect stream scores near the max, computed by the server
    assert r["prev_rank"] == 0, r
    best = r["ex"]
    assert call("POST", f"/scores/{sha}?format=1", b"ACTRgarbage", alice)[0] == 422
    assert call("GET", "/scores/" + "../etc")[0] in (400, 404)
    first_date = call("GET", "/me/scores", None, alice)[1]["scores"][0]["date"]
    time.sleep(1.1)
    assert call("POST", f"/scores/{sha}?format=1", replay, alice)[0] == 200
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
    status, r = call("POST", f"/scores/{sha}?format=1", replay, bob)
    assert status == 200 and r["prev_rank"] == 2, r  # the claim's place, before this score counted
    status, r = call("POST", f"/scores/{sha}?format=1", replay, bob)
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
    assert call("PUT", f"/charts/{cut_sha}?format=1", cut_chart, bob)[0] == 200
    assert call("POST", f"/scores/{cut_sha}?format=2", cut_replay, bob)[0] == 422, "a format that drops notes is refused"
    assert call("POST", f"/scores/{cut_sha}?format=1", cut_replay, bob)[0] == 200
    pms_sha, pms_chart, pms_replay = bms("real.pms", ["11", "22"])
    assert call("PUT", f"/charts/{pms_sha}?format=2", pms_chart, bob)[0] == 200
    assert call("POST", f"/scores/{pms_sha}?format=2", pms_replay, bob)[0] == 200, "a real PMS chart still ranks"

    host = call("POST", "/register", {"name": "roomhost", "password": "correct horse"})[1]["token"]
    guest = call("POST", "/register", {"name": "roomguest", "password": "correct horse"})[1]["token"]
    assert call("POST", "/rooms", {"sha256": "../x", "title": "t"}, host)[0] == 400, "a room's chart hash is checked"
    room = call("POST", "/rooms", {"sha256": sha, "title": "t"}, host)[1]["code"]
    assert call("POST", "/rooms/ZZZZZZ/join", None, guest)[0] == 404
    assert call("POST", "/rooms/a%2Fb/join", None, guest)[0] == 404, "a bad code is refused"
    assert call("POST", f"/rooms/{room}/join", None)[0] == 401, "a room needs a player"
    joined = call("POST", f"/rooms/{room}/join", None, guest)
    assert joined[0] == 200 and joined[1]["udp"] == "127.0.0.1:18732"
    assert call("POST", f"/rooms/{room}/start", None, guest)[0] == 403, "only the host starts"
    assert call("POST", f"/rooms/{room}/start", None, host)[0] == 200
    claim = {"round": 1, "has_chart": True, "ex": 999999, "judged": 1, "gauge": 100, "done": True}
    seen = call("POST", f"/rooms/{room}/report", claim, guest)[1]
    assert 0 < seen["starts_in_ms"] and seen["seed"] == call("POST", f"/rooms/{room}/report", claim, host)[1]["seed"]
    assert all(p["final_ex"] is None for p in seen["players"]), "a reported score decides nothing"
    live = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    live.settimeout(1)
    live.connect(("127.0.0.1", 18732))
    def live_packet(key):
        return b"AU1Q" + room.encode() + key + struct.pack("<IIIIfB", 1, 1, 1234, 5, 50.0, 1)
    live.send(live_packet(b"\0" * 16))
    try:
        live.recv(512)
        assert False, "a live packet without a key gets no reply"
    except TimeoutError:
        pass
    live.send(live_packet(bytes.fromhex(joined[1]["key"])))
    answer = live.recv(512)
    assert answer[:4] == b"AU1R" and answer[16] == 2 and 0 < struct.unpack("<I", answer[12:16])[0] <= 8000, answer
    seen = call("POST", f"/rooms/{room}/report", claim, host)[1]
    assert [p["ex"] for p in seen["players"] if p["name"] == "roomguest"] == [1234], "a live score reaches the room"
    assert call("POST", f"/scores/{sha}?format=1&room={room}", replay, guest)[0] == 200
    seen = call("POST", f"/rooms/{room}/report", claim, host)[1]
    assert [p["final_ex"] for p in seen["players"] if p["name"] == "roomguest"] == [notes * 2], "the checked replay decides"

    hoarder = call("POST", "/register", {"name": "hoarder", "password": "correct horse"})[1]["token"]
    def claims(start):
        return {"scores": [{"sha256": f"{i:064x}", "clear": 0, "ex": 0, "max_combo": 0, "miss": 0, "date": 1} for i in range(start, start + 7000)]}
    sent = [call("POST", "/me/claims", claims(n * 7000), hoarder)[0] for n in range(8)]
    assert sent == [200] * 7 + [429], sent
    assert len(call("GET", "/me/scores", None, hoarder)[1]["scores"]) == 49000, "a refused batch stores nothing"
    assert call("POST", "/me/claims", claims(0), hoarder)[0] == 200, "sending held rows again adds nothing"

    stop_server()
    clear_titles(0)
    proc = start_server()
    for _ in range(100):
        if title_of(sha):
            break
        time.sleep(0.1)
    assert title_of(sha), "old charts get named behind the workers"
    stop_server()
    clear_titles(1)
    proc = start_server()
    time.sleep(1)
    assert title_of(sha) == "", "and only once"
    print(f"IR e2e OK: ex {best} of max {notes * 2}")
finally:
    stop_server()
