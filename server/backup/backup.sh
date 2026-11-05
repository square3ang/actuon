#!/bin/sh
# Usage: backup.sh once|restore [NAME]
set -eu
data=${DATA_DIR:-/data}
remote=backup:${S3_BUCKET:?set S3_BUCKET}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

check_db() {
	[ "$(sqlite3 "$1" 'PRAGMA integrity_check')" = ok ] || { echo "$1 is corrupt" >&2; exit 1; }
}

once() {
	name=ir-$(date -u +%Y%m%d-%H%M%S).db.gz
	# sqlite3 would create an empty database and back that up.
	[ -f "$data/ir.db" ] || { echo "$data/ir.db does not exist" >&2; exit 1; }
	# Not a plain copy, which misses what is still in ir.db-wal, nor .backup, which restarts on every commit
	# and never finishes on a busy server: VACUUM INTO reads one snapshot.
	sqlite3 "$data/ir.db" "VACUUM INTO '$work/ir.db'"
	check_db "$work/ir.db"
	# A database that lost its accounts must not become the newest copy, which restore would pick.
	if [ "$(sqlite3 "$work/ir.db" 'SELECT EXISTS(SELECT 1 FROM user)' 2>/dev/null || echo 0)" != 1 ]; then
		echo "no accounts in $data/ir.db, nothing to back up"
		return
	fi
	gzip -c "$work/ir.db" >"$work/$name"
	rclone copyto "$work/$name" "$remote/db/$name"
	# Only reached once the new copy is up, so a failing upload never eats the old ones.
	rclone delete "$remote/db" --min-age 30d
	echo "backed up $name"
}

# The server must be stopped: it would keep writing to the database this replaces.
restore() {
	name=${1:-$(rclone lsf "$remote/db" | sort | tail -n 1)}
	[ -n "$name" ] || { echo "no backup in $remote/db" >&2; exit 1; }
	rclone copyto "$remote/db/$name" "$work/ir.db.gz"
	gzip -d "$work/ir.db.gz"
	check_db "$work/ir.db"
	# Copied first, so a full disk stops this before anything moves.
	cp "$work/ir.db" "$data/ir.db.restoring"
	# Moved, not read: the database being replaced may be the corrupt one. The pid keeps two restores apart.
	old=$data/ir.db.before-restore-$(date -u +%Y%m%d-%H%M%S)-$$
	for suffix in "" -wal -shm; do
		[ ! -e "$data/ir.db$suffix" ] || mv "$data/ir.db$suffix" "$old$suffix"
	done
	mv "$data/ir.db.restoring" "$data/ir.db"
	echo "restored $name"
}

case ${1:-} in
once) once ;;
restore) restore "${2:-}" ;;
*)
	echo "usage: backup.sh once|restore [NAME]" >&2
	exit 2
	;;
esac
