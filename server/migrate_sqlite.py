#!/usr/bin/env python3
"""Prints SQL that moves an old ir.db into PostgreSQL. Start the new server once first: it creates the tables.
Usage: migrate_sqlite.py ir.db | psql -v ON_ERROR_STOP=1 "$DATABASE_URL"
Accounts keep their ids and tokens. Running it twice adds nothing, and existing rows stay as they are."""
import sqlite3, sys

# new table, old table, new columns, old columns: only "user" had to change its name.
TABLES = [
    ("player", "user", "id,name,pass,token", "id,name,pass,token"),
    ("chart", "chart", "sha256,owner", "sha256,owner"),
    ("score", "score", "player,sha256,clear,ex,max_combo,miss,notes,gauge_type,date", "user,sha256,clear,ex,max_combo,miss,notes,gauge_type,date"),
    ("rival", "rival", "player,rival", "user,rival"),
    ("claim", "claim", "player,sha256,clear,ex,max_combo,miss,date", "user,sha256,clear,ex,max_combo,miss,date"),
]


def literal(v):
    if v is None:
        raise SystemExit("unexpected NULL: PostgreSQL requires a value here")
    return str(int(v)) if isinstance(v, int) else "'" + str(v).replace("'", "''") + "'"


def main():
    # Read only: the old database stays as the way back.
    db = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
    have = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    print("BEGIN;")
    for new, old, new_cols, old_cols in TABLES:
        if old not in have:  # claim is newer than some databases
            continue
        for row in db.execute(f'SELECT {old_cols} FROM "{old}"'):
            print(f"INSERT INTO {new}({new_cols}) VALUES({','.join(map(literal, row))}) ON CONFLICT DO NOTHING;")
    print("SELECT setval(pg_get_serial_sequence('player','id'), GREATEST((SELECT MAX(id) FROM player), 1));")
    print("COMMIT;")


main()
