#!/usr/bin/env python3
"""Backup and restore round trip against a local rclone remote. Usage: backup_check.py BACKUP_SH WORKDIR"""
import glob, os, sqlite3, subprocess, sys

script, work = os.path.abspath(sys.argv[1]), sys.argv[2]
data, bucket = os.path.join(work, "data"), os.path.join(work, "bucket")
os.makedirs(data)
env = {**os.environ, "DATA_DIR": data, "S3_BUCKET": bucket, "RCLONE_CONFIG_BACKUP_TYPE": "local"}

def run(*args):
    return subprocess.run(["sh", script, *args], env=env, capture_output=True, text=True)

def write(path, text):
    with open(path, "w") as f:
        f.write(text)

def copies():
    return sorted(glob.glob(os.path.join(bucket, "db", "*.gz")))

assert run("once").returncode != 0, "no database, so no success"
db = sqlite3.connect(os.path.join(data, "ir.db"))
db.execute("PRAGMA journal_mode=WAL")
db.execute("PRAGMA wal_autocheckpoint=0")
db.execute("CREATE TABLE t(v)")
db.execute("CREATE TABLE user(id)")
db.commit()
r = run("once")
assert r.returncode == 0 and copies() == [], "a database with no accounts must not become the newest copy"
db.execute("INSERT INTO user VALUES(1)")
db.execute("INSERT INTO t VALUES('kept')")
db.commit()  # stays open, so this row is only in ir.db-wal

r = run("once")
assert r.returncode == 0, r.stderr
assert len(copies()) == 1

os.utime(copies()[0], (1, 1))
old = copies()[0]
os.rename(old, os.path.join(bucket, "db", "ir-20000101-000000.db.gz"))
assert run("once").returncode == 0
assert len(copies()) == 1 and "ir-2000" not in copies()[0], "copies past 30 days go"

db.execute("INSERT INTO t VALUES('after backup')")
db.commit()
db.close()
r = run("restore")
assert r.returncode == 0, r.stderr
db = sqlite3.connect(os.path.join(data, "ir.db"))
assert db.execute("SELECT v FROM t").fetchall() == [("kept",)]
db.close()
def replaced():
    return sorted(f for f in glob.glob(os.path.join(data, "ir.db.before-restore-*")) if not f.endswith(("-wal", "-shm")))

assert len(replaced()) == 1
db = sqlite3.connect(replaced()[0])
assert len(db.execute("SELECT v FROM t").fetchall()) == 2, "the replaced database stays, with what was in its WAL"
db.close()

# A corrupt database is the usual reason to restore, and it cannot be read to be saved.
write(os.path.join(data, "ir.db"), "corrupt, not a database at all")
r = run("restore")
assert r.returncode == 0, r.stderr
db = sqlite3.connect(os.path.join(data, "ir.db"))
assert db.execute("SELECT v FROM t").fetchall() == [("kept",)]
db.close()
assert len(replaced()) == 2, "a second restore overwrites nothing"
assert any(open(f, "rb").read().startswith(b"corrupt") for f in replaced()), "the corrupt file stays too"

older = os.path.join(bucket, "db", "ir-20100101-000000.db.gz")
os.rename(copies()[0], older)
db = sqlite3.connect(os.path.join(data, "ir.db"))
db.execute("INSERT INTO t VALUES('newer')")
db.commit()
db.close()
assert run("once").returncode == 0 and len(copies()) == 2
assert run("restore").returncode == 0
db = sqlite3.connect(os.path.join(data, "ir.db"))
assert len(db.execute("SELECT v FROM t").fetchall()) == 2, "the newest copy by default"
db.close()
assert run("restore", os.path.basename(older)).returncode == 0
db = sqlite3.connect(os.path.join(data, "ir.db"))
assert db.execute("SELECT v FROM t").fetchall() == [("kept",)], "or the one named"
db.close()
assert run("restore", "ir-19990101-000000.db.gz").returncode != 0, "a name with no copy is refused"

write(copies()[-1], "not gzip")
before = open(os.path.join(data, "ir.db"), "rb").read()
assert run("restore").returncode != 0, "a broken backup is refused"
assert open(os.path.join(data, "ir.db"), "rb").read() == before, "and replaces nothing"
print("backup OK")
