#!/bin/sh
# Installs or updates the IR server on a Linux host over SSH, then proves a backup reaches the bucket.
# Fill in server/.env from server/.env.example first. SSH asks for its own password, at most once.
# Usage: server/deploy.sh root@HOST
set -eu
target=${1:?usage: server/deploy.sh root@HOST}
cd "$(dirname "$0")/.."

for key in S3_ENDPOINT S3_BUCKET S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY; do
	grep -q "^$key=." server/.env 2>/dev/null || { echo "set $key in server/.env" >&2; exit 1; }
done

control=$(mktemp -d)
ssh_shared() { ssh -o ControlMaster=auto -o "ControlPath=$control/ssh" -o ControlPersist=60 "$@"; }
trap 'ssh -o "ControlPath=$control/ssh" -O exit "$target" 2>/dev/null || true; rm -rf "$control"' EXIT

ssh_shared "$target" 'mkdir -p /opt/actuon/server'
# Git's file list, so server/.env and build output stay out. Files not yet committed still go.
git ls-files -z -co --exclude-standard | tar --null -T - -czf - | ssh_shared "$target" 'tar -xzf - -C /opt/actuon'
# Through stdin: secrets on a command line would show in the process list.
ssh_shared "$target" 'umask 077; cat >/opt/actuon/server/.env' <server/.env

# Podman, because on Rocky 8 Docker's packages conflict with the system's runc and podman.
ssh_shared "$target" 'dnf -y -q install epel-release && dnf -y -q install podman podman-compose && systemctl enable podman-restart'
# Built here: compiling Zig and Rust runs a small host out of memory.
(cd server && docker compose build)
docker save localhost/actuon-ir localhost/actuon-web localhost/actuon-backup | gzip | ssh_shared "$target" 'gzip -d | podman load'
ssh_shared "$target" 'sh -s' <<'REMOTE'
set -eu
cd /opt/actuon/server
podman-compose down
podman-compose up -d --no-build
# podman-compose has no --wait.
tries=0
until curl -fsS http://127.0.0.1:8730/health; do
	tries=$((tries + 1))
	[ "$tries" -lt 30 ] || { echo "server did not come up" >&2; podman-compose logs ir >&2; exit 1; }
	sleep 2
done
echo
tries=0
until curl -fsS -o /dev/null http://127.0.0.1:8731/; do
	tries=$((tries + 1))
	[ "$tries" -lt 30 ] || { echo "web page did not come up" >&2; podman-compose logs web >&2; exit 1; }
	sleep 2
done
# Not podman-compose exec: it prints the S3 secret and puts it on the command line.
podman exec server_backup_1 sh /usr/local/bin/backup.sh once
REMOTE
echo "deployed to $target, and a backup reached the bucket"
