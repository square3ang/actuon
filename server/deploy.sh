#!/bin/sh
# Installs or updates the IR server on a Linux host over SSH, then proves a backup reaches the bucket.
# Fill in server/.env from server/.env.example first. SSH asks for its own password, at most once.
# Needs zig, cargo and `rustup target add x86_64-unknown-linux-musl` here, and a RHEL-like host such as Rocky Linux.
# Usage: server/deploy.sh root@HOST
set -eu
target=${1:?usage: server/deploy.sh root@HOST}
cd "$(dirname "$0")/.."

for key in RCLONE_CONFIG_BACKUP_ENDPOINT RCLONE_CONFIG_BACKUP_ACCESS_KEY_ID RCLONE_CONFIG_BACKUP_SECRET_ACCESS_KEY S3_BUCKET; do
	grep -q "^$key=." server/.env 2>/dev/null || { echo "set $key in server/.env" >&2; exit 1; }
done

# Built here: compiling Zig and Rust runs a small host out of memory. Static, so the host's libc does not matter,
# and baseline, so another CPU does not die with SIGILL.
musl=x86_64-unknown-linux-musl
zig build core -Doptimize=ReleaseSafe -Dcpu=baseline -Dtarget=x86_64-linux-musl -p zig-out/musl
export CC_x86_64_unknown_linux_musl="$PWD/server/musl-cc" AR_x86_64_unknown_linux_musl="zig ar"
cargo build --release --locked --target $musl --manifest-path server/Cargo.toml
cargo build --release --locked --target $musl --manifest-path web/Cargo.toml

stage=$(mktemp -d)
control=$(mktemp -d)
ssh_shared() { ssh -o ControlMaster=auto -o "ControlPath=$control/ssh" -o ControlPersist=60 "$@"; }
trap 'ssh -o "ControlPath=$control/ssh" -O exit "$target" 2>/dev/null || true; rm -rf "$control" "$stage"' EXIT

mkdir "$stage/bin"
cp server/target/$musl/release/actuon-ir web/target/$musl/release/actuon-web server/backup/backup.sh "$stage/bin"
cp -r server/systemd "$stage/systemd"
ssh_shared "$target" 'mkdir -p /opt/actuon /etc/actuon'
tar -czf - -C "$stage" bin systemd | ssh_shared "$target" 'tar -xzf - -C /opt/actuon'
# Through stdin: secrets on a command line would show in the process list.
ssh_shared "$target" 'umask 077; cat >/etc/actuon/backup.env' <server/.env

ssh_shared "$target" 'sh -s' <<'REMOTE'
set -eu
dnf -y -q install epel-release && dnf -y -q install rclone sqlite curl
id actuon >/dev/null 2>&1 || useradd --system --home-dir /var/lib/actuon --shell /sbin/nologin actuon
install -d -m 0700 -o actuon -g actuon /var/lib/actuon
# Once: the old deploy ran Podman containers, which hold the ports, and kept the data in their volume. The volume and
# compose.yml.old stay, so `podman-compose -f compose.yml.old up -d` in /opt/actuon/server goes back.
if [ -f /opt/actuon/server/compose.yml ]; then
	(cd /opt/actuon/server && podman-compose down)
	if [ ! -e /var/lib/actuon/ir.db ]; then
		cp -a "$(podman volume inspect server_data --format '{{.Mountpoint}}')/." /var/lib/actuon/
		chown -R actuon:actuon /var/lib/actuon
		echo "moved the data out of the Podman volume server_data"
	fi
	mv /opt/actuon/server/compose.yml /opt/actuon/server/compose.yml.old
fi
install -m 0644 /opt/actuon/systemd/* /etc/systemd/system/
systemctl daemon-reload
systemctl enable actuon-ir actuon-web actuon-backup.timer
systemctl restart actuon-ir actuon-web actuon-backup.timer
for url in http://127.0.0.1:8730/health http://127.0.0.1:8731/; do
	tries=0
	until curl -fsS -o /dev/null "$url"; do
		tries=$((tries + 1))
		[ "$tries" -lt 30 ] || { echo "$url did not come up" >&2; journalctl -u actuon-ir -u actuon-web -n 30 --no-pager >&2; exit 1; }
		sleep 2
	done
done
systemctl start actuon-backup || { journalctl -u actuon-backup -n 20 --no-pager >&2; exit 1; }
journalctl -u actuon-backup -n 1 -o cat --no-pager
REMOTE
echo "deployed to $target"
