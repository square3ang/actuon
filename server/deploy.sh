#!/bin/sh
# Usage: server/deploy.sh root@HOST (RHEL-like host; fill server/.env first; needs zig, cargo, rustup musl target)
set -eu
target=${1:?usage: server/deploy.sh root@HOST}
cd "$(dirname "$0")/.."

for key in RCLONE_CONFIG_BACKUP_ENDPOINT RCLONE_CONFIG_BACKUP_ACCESS_KEY_ID RCLONE_CONFIG_BACKUP_SECRET_ACCESS_KEY S3_BUCKET; do
	grep -q "^$key=." server/.env 2>/dev/null || { echo "set $key in server/.env" >&2; exit 1; }
done

# Built here (a small host runs out of memory), static for any libc, baseline CPU to avoid SIGILL.
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
dnf -y -q install sqlite curl
# EPEL has no rclone for Rocky 8: rclone's own package, checked against the sum it published.
if [ "$(rclone version 2>/dev/null | head -n 1)" != "rclone v1.75.2" ]; then
	curl -fsSLo /tmp/rclone.rpm https://downloads.rclone.org/v1.75.2/rclone-v1.75.2-linux-amd64.rpm
	echo "d5174054cf94075c32faf25961687622b8d366b788972ea9fbcedba59013e320  /tmp/rclone.rpm" | sha256sum -c -
	dnf -y -q install /tmp/rclone.rpm
	rm /tmp/rclone.rpm
fi
id actuon >/dev/null 2>&1 || useradd --system --home-dir /var/lib/actuon --shell /sbin/nologin actuon
install -d -m 0700 -o actuon -g actuon /var/lib/actuon
# One-time Podman migration; to go back, run `podman-compose -f compose.yml.old up -d` in /opt/actuon/server.
if [ -f /opt/actuon/server/compose.yml ]; then
	(cd /opt/actuon/server && podman-compose down)
	if [ ! -e /var/lib/actuon/ir.db ]; then
		cp -a "$(podman volume inspect server_data --format '{{.Mountpoint}}')/." /var/lib/actuon/
		chown -R actuon:actuon /var/lib/actuon
		# cp -a also copied the volume's mode, which lets anyone read the password hashes.
		chmod 0700 /var/lib/actuon
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
journalctl -u actuon-backup -n 20 -o cat --no-pager | grep -E 'backed up|nothing to back up' | tail -n 1
REMOTE
echo "deployed to $target"
