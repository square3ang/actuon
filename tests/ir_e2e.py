#!/usr/bin/env python3
"""End-to-end IR test: server re-simulation decides the score. Usage: ir_e2e.py SERVER_BIN MKREPLAY CHART WORKDIR"""
import json, os, subprocess, sys, time, urllib.error, urllib.request

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
    assert call("POST", f"/scores/{sha}", replay, old)[0] == 401, "rotated token must die"
    assert call("POST", f"/scores/{sha}", replay)[0] == 401
    assert call("POST", f"/scores/{sha}", replay, alice)[0] == 428
    chart_bytes = open(chart, "rb").read()
    assert call("PUT", f"/charts/{sha}?format=1", b"tampered" + chart_bytes, alice)[0] == 400
    assert call("PUT", f"/charts/{sha}?format=1", chart_bytes, alice)[0] == 200
    status, r = call("POST", f"/scores/{sha}", replay, alice)
    assert status == 200, r
    assert r["ex"] > notes, r  # a perfect stream scores near the max, computed by the server
    best = r["ex"]
    assert call("POST", f"/scores/{sha}", b"ACTRgarbage", alice)[0] == 422
    assert call("GET", "/scores/" + "../etc")[0] in (400, 404)
    status, r = call("GET", f"/scores/{sha}")
    assert r["scores"][0] == {**r["scores"][0], "name": "alice", "ex": best}, r
    bob = call("POST", "/register", {"name": "bob", "password": "battery staple"})[1]["token"]
    assert call("PUT", "/rivals/nobody", None, bob)[0] == 404
    assert call("PUT", "/rivals/alice", None, bob)[0] == 200
    assert call("GET", "/rivals", None, bob)[1]["rivals"] == ["alice"]
    assert [s["name"] for s in call("GET", f"/scores/{sha}/rivals", None, bob)[1]["scores"]] == ["alice"]
    assert call("POST", "/table-ranking", {"sha256": [sha]})[1]["players"][0]["name"] == "alice"
    assert call("POST", "/table-ranking", {"sha256": ["../x"]})[0] == 400
    print(f"IR e2e OK: ex {best} of max {notes * 2}")
finally:
    proc.terminate()
    proc.wait()
