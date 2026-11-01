# Build from the repository root: the page embeds the brand assets and fonts.
FROM archlinux:latest AS build
RUN pacman -Syu --noconfirm rust gcc
WORKDIR /src
COPY web web
COPY assets assets
RUN cargo build --release --locked --manifest-path web/Cargo.toml

# The same base as the build, because the binary needs its glibc.
FROM archlinux:latest
RUN useradd --system --uid 8731 --create-home web
COPY --from=build /src/web/target/release/actuon-web /usr/local/bin/actuon-web
USER web
EXPOSE 8731
HEALTHCHECK --interval=10s --timeout=3s --retries=5 CMD curl -fsS -o /dev/null http://127.0.0.1:8731/style.css
CMD ["actuon-web", "0.0.0.0:8731", "http://ir:8730"]
