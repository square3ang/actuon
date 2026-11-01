#!/usr/bin/env python3
"""Backup and restore round trip against a local rclone remote. Usage: backup_check.py BACKUP_SH WORKDIR"""
import glob, os, sqlite3, subprocess, sys

script, work = os.path.abspath(sys.argv[1]), sys.argv[2]
data, bucket = os.path.join(work, "data"), os.path.join(work, "bucket")
os.makedirs(os.path.join(data, "charts"))
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
db.execute("INSERT INTO t VALUES('kept')")
db.commit()  # stays open, so this row is only in ir.db-wal
write(os.path.join(data, "charts", "abc"), "chart")
write(os.path.join(data, "charts", "abc.tmp123"), "half an upload")

r = run("once")
assert r.returncode == 0, r.stderr
assert len(copies()) == 1
assert os.listdir(os.path.join(bucket, "charts")) == ["abc"], "temporary uploads stay out"

os.utime(copies()[0], (1, 1))
old = copies()[0]
os.rename(old, os.path.join(bucket, "db", "ir-20000101-000000.db.gz"))
assert run("once").returncode == 0
assert len(copies()) == 1 and "ir-2000" not in copies()[0], "copies past 30 days go"

db.execute("INSERT INTO t VALUES('after backup')")
db.commit()
db.close()
os.remove(os.path.join(data, "charts", "abc"))
r = run("restore")
assert r.returncode == 0, r.stderr
db = sqlite3.connect(os.path.join(data, "ir.db"))
assert db.execute("SELECT v FROM t").fetchall() == [("kept",)]
db.close()
assert os.path.exists(os.path.join(data, "charts", "abc"))
db = sqlite3.connect(os.path.join(data, "ir.db.before-restore"))
assert len(db.execute("SELECT v FROM t").fetchall()) == 2, "the replaced database stays"
db.close()

write(copies()[0], "not gzip")
before = open(os.path.join(data, "ir.db"), "rb").read()
assert run("restore").returncode != 0, "a broken backup is refused"
assert open(os.path.join(data, "ir.db"), "rb").read() == before, "and replaces nothing"
print("backup OK")
