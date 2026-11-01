#!/usr/bin/env python3
"""End-to-end IR test: server re-simulation decides the score. Usage: ir_e2e.py SERVER_BIN MKREPLAY CHART WORKDIR"""
import hashlib, json, os, subprocess, sys, time, urllib.error, urllib.parse, urllib.request

server, mkreplay, chart, work = sys.argv[1:5]
base = "http://127.0.0.1:18731"

def call(method, path, body=None, token=None):
    headers = {"Authorization": "Bearer " + token} if token else {}
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
proc = subprocess.Popen([server, "127.0.0.1:18731", os.path.join(work, "ir")], stderr=subprocess.DEVNULL)
try:
    for _ in range(100):
        try:
            if call("GET", "/health")[0] == 200:
                break
        except OSError:
            time.sleep(0.1)
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
    guess = {"name": "nobody", "password": "wrong password"}
    assert [call("POST", "/login", guess)[0] for _ in range(11)] == [401] * 10 + [429], "attempts are counted"
    print(f"IR e2e OK: ex {best} of max {notes * 2}")
finally:
    proc.terminate()
    proc.wait()
