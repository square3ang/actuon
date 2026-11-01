# Build from the repository root: the server links the Zig core.
FROM archlinux:latest AS build
RUN pacman -Syu --noconfirm zig rust gcc
WORKDIR /src
COPY . .
# Baseline: the default targets this machine's CPU, and the image would die with SIGILL on another.
RUN zig build core -Doptimize=ReleaseSafe -Dcpu=baseline
RUN cargo build --release --locked --manifest-path server/Cargo.toml

# The same base as the build, because the binary needs its glibc.
FROM archlinux:latest
RUN useradd --system --uid 8730 --create-home ir && install -d -o ir -g ir /data
COPY --from=build /src/server/target/release/actuon-ir /usr/local/bin/actuon-ir
USER ir
VOLUME /data
EXPOSE 8730
HEALTHCHECK --interval=10s --timeout=3s --retries=5 CMD curl -fsS http://127.0.0.1:8730/health
CMD ["actuon-ir", "0.0.0.0:8730", "/data"]
