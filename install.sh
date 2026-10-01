#!/usr/bin/env bash
# Install or update stream-server with Docker, compiled from this repo for this CPU.
#
#   curl -fsSL https://raw.githubusercontent.com/Mudales/stream-server/master/install.sh | sudo bash
#
# Environment overrides:
#   INSTALL_DIR   where the repo is checked out     (default: /opt/stream-server)
#   REPO_URL      git repository to install from    (default: this fork)
#   BRANCH        branch to track                   (default: master)
#   CERT_HOSTS    IPs/hostnames for the self-signed certificate (default: this server's IPs)
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/Mudales/stream-server.git}"
BRANCH="${BRANCH:-master}"
INSTALL_DIR="${INSTALL_DIR:-/opt/stream-server}"
LABEL="io.github.mudales.stream-server"

step() { printf '\n==== %s ====\n' "$1"; }
ok()   { printf '\033[32m✔ %s\033[0m\n' "$1"; }
warn() { printf '\033[33m! %s\033[0m\n' "$1"; }
die()  { printf '\033[31m✖ %s\033[0m\n' "$1" >&2; exit 1; }

# --- 1. Prerequisites ---------------------------------------------------------
step "Checking prerequisites"
[ "$(id -u)" -eq 0 ] || die "run as root (sudo)"
command -v git    >/dev/null || die "git is not installed (apt install git)"
command -v curl   >/dev/null || die "curl is not installed (apt install curl)"
command -v docker >/dev/null || die "Docker is not installed: https://docs.docker.com/engine/install/ubuntu/"
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is missing (apt install docker-compose-plugin)"
ok "git, curl, docker and docker compose found"

# --- 2. Fetch the code --------------------------------------------------------
step "Fetching $REPO_URL ($BRANCH)"
if [ -d "$INSTALL_DIR/.git" ]; then
  git -C "$INSTALL_DIR" fetch --quiet origin "$BRANCH"
  git -C "$INSTALL_DIR" checkout --quiet "$BRANCH"
  git -C "$INSTALL_DIR" merge --quiet --ff-only "origin/$BRANCH"
else
  git clone --quiet --branch "$BRANCH" "$REPO_URL" "$INSTALL_DIR"
fi
cd "$INSTALL_DIR"
rev="$(git rev-parse --short HEAD)"
mkdir -p data certs
ok "$INSTALL_DIR at commit $rev"

# --- 3. Configuration ---------------------------------------------------------
step "Configuring"
if [ ! -f .env ]; then
  hosts="${CERT_HOSTS:-$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v -e ':' -e '^$' | paste -sd, -),$(hostname)}"
  printf 'CERT_HOSTS=%s\n' "$hosts" > .env
  ok "wrote .env (CERT_HOSTS=$hosts)"
else
  # Earlier versions of this script wrote TARGET_CPU; drop it so the build uses "native".
  sed -i -e '/^TARGET_CPU=$/d' -e '/^TARGET_CPU=x86-64-v2$/d' .env
  ok "keeping existing .env"
fi

# --- 4. Cache from a previous version -----------------------------------------
last="$(cat data/.installed-rev 2>/dev/null || true)"
if [ -n "$last" ] && [ "$last" != "$rev" ] && [ -d data/cache ]; then
  step "Clearing cache from previous version ($last)"
  docker compose down >/dev/null 2>&1 || true
  rm -rf data/cache
  ok "torrent cache cleared (settings and certificate kept)"
fi

# --- 5. Build and start -------------------------------------------------------
step "Building and starting (the first build compiles libtorrent + Rust: 15-30+ min)"
docker compose up -d --build
echo "$rev" > data/.installed-rev
docker image prune -f --filter "label=$LABEL" >/dev/null

step "Waiting for the server"
up=0
for _ in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:11470/heartbeat >/dev/null 2>&1; then up=1; break; fi
  sleep 2
done
[ "$up" = 1 ] && ok "server is up" || warn "no answer yet, check: docker logs stremio"

ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
step "Done"
echo "HTTP:   http://$ip:11470"
echo "HTTPS:  https://$ip   (self-signed: open it once in the browser and accept the certificate)"
echo "Stremio web: Settings -> Streaming server URL -> https://$ip"
echo "Logs:   docker logs -f stremio"
echo "Update: run this installer again"
