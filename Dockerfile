# syntax=docker/dockerfile:1
# Headless stream-server image (see DOCKER.md).

# ---------- build ----------
FROM ubuntu:24.04 AS build
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential cmake curl ca-certificates git pkg-config \
      libssl-dev libboost-dev libclang-dev \
      libgtk-3-dev libayatana-appindicator3-dev \
 && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable
ENV PATH=/root/.cargo/bin:$PATH \
    LIBTORRENT_STATIC=1 \
    PKG_CONFIG_PATH=/usr/local/lib/pkgconfig

# libtorrent 2.1.1, built the same way as the upstream release CI
COPY .github/scripts/install-libtorrent.sh /tmp/install-libtorrent.sh
RUN bash /tmp/install-libtorrent.sh

WORKDIR /src
COPY . .
# .cargo/config.toml pins x86-64-v3 (AVX2), which crashes with SIGILL on CPUs/VMs without it
# (e.g. Proxmox's default CPU type). RUSTFLAGS overrides that; the default "native" builds for
# the CPU doing the build, i.e. the server that will run it.
ARG TARGET_CPU=""
RUN RUSTFLAGS="-C target-cpu=${TARGET_CPU:-native}" cargo build --release -p server \
 && cp target/release/server /stream-server

# ---------- runtime ----------
FROM ubuntu:24.04
ARG DEBIAN_FRONTEND=noninteractive
# GTK/dbus/fontconfig are only linked in for the desktop tray; the server runs with --no-tray.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ffmpeg openssl ca-certificates curl \
      libgtk-3-0t64 libayatana-appindicator3-1 libfontconfig1 libdbus-1-3 \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /stream-server /usr/local/bin/stream-server
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
LABEL io.github.mudales.stream-server="1"
ENV XDG_CONFIG_HOME=/data/config \
    XDG_CACHE_HOME=/data/cache
VOLUME /data
EXPOSE 11470 12470
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s \
  CMD curl -fsS http://127.0.0.1:11470/heartbeat >/dev/null || exit 1
ENTRYPOINT ["/entrypoint.sh"]
