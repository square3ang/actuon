#!/bin/sh
# Copies the IR data directory to the rclone remote "backup". With no argument it repeats every 6 hours.
# Usage: backup.sh [once|restore]
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
	# .backup, because a plain copy of ir.db misses what is still in ir.db-wal.
	sqlite3 "$data/ir.db" ".backup '$work/ir.db'"
	check_db "$work/ir.db"
	gzip -c "$work/ir.db" >"$work/$name"
	rclone copyto "$work/$name" "$remote/db/$name"
	# After the database, so every chart it names is included. Names are hashes, so a held chart never changes.
	rclone copy "$data/charts" "$remote/charts" --ignore-existing --exclude '*.tmp*'
	# Only reached once the new copy is up, so a failing upload never eats the old ones.
	rclone delete "$remote/db" --min-age 30d
	echo "backed up $name"
}

# The server must be stopped: it would keep writing to the database this replaces.
restore() {
	name=$(rclone lsf "$remote/db" | sort | tail -n 1)
	[ -n "$name" ] || { echo "no backup in $remote/db" >&2; exit 1; }
	rclone copyto "$remote/db/$name" "$work/ir.db.gz"
	gzip -d "$work/ir.db.gz"
	check_db "$work/ir.db"
	mkdir -p "$data/charts"
	rclone copy "$remote/charts" "$data/charts" --ignore-existing
	[ ! -e "$data/ir.db" ] || sqlite3 "$data/ir.db" ".backup '$data/ir.db.before-restore'"
	rm -f "$data/ir.db-wal" "$data/ir.db-shm"
	cp "$work/ir.db" "$data/ir.db"
	echo "restored $name"
}

case ${1:-loop} in
once) once ;;
restore) restore ;;
loop)
	while :; do
		# A child process: inside "||" the shell would ignore set -e, and a failed step would not stop the rest.
		sh "$0" once || echo "backup failed, next try in 6 hours" >&2
		sleep 21600
	done
	;;
*)
	echo "usage: backup.sh [once|restore]" >&2
	exit 2
	;;
esac
