FROM alpine:3.22
RUN apk add --no-cache rclone sqlite
COPY backup.sh /usr/local/bin/backup.sh
# The server's uid: SQLite's WAL files in the shared volume must stay writable for both.
USER 8730
ENTRYPOINT ["sh", "/usr/local/bin/backup.sh"]
