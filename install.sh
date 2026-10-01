#!/usr/bin/env bash
# Install or update stream-server (Docker) on a Linux server.
#
#   curl -fsSL https://raw.githubusercontent.com/Mudales/stream-server/master/install.sh | sudo bash
#
# Environment overrides:
#   INSTALL_DIR      where the repo is checked out       (default: /opt/stream-server)
#   REPO_URL         git repository to install from      (default: this fork)
#   BRANCH           branch to track                     (default: master)
#   CERT_HOSTS       IPs/hostnames for the self-signed certificate (default: this server's IPs)
#   OLD_STREMIO_DIR  folder of the old server.js setup, if its container is already gone
#   ASSUME_YES=1     answer "yes" to every cleanup question
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/Mudales/stream-server.git}"
BRANCH="${BRANCH:-master}"
INSTALL_DIR="${INSTALL_DIR:-/opt/stream-server}"
ASSUME_YES="${ASSUME_YES:-0}"
LABEL="io.github.mudales.stream-server"

step() { printf '\n==== %s ====\n' "$1"; }
ok()   { printf '\033[32m✔ %s\033[0m\n' "$1"; }
warn() { printf '\033[33m! %s\033[0m\n' "$1"; }
die()  { printf '\033[31m✖ %s\033[0m\n' "$1" >&2; exit 1; }

confirm() {
  [ "$ASSUME_YES" = 1 ] && return 0
  local reply
  if ! read -r -p "$1 [y/N] " reply </dev/tty 2>/dev/null; then
    warn "no terminal to ask, skipping (set ASSUME_YES=1 to allow)"
    return 1
  fi
  [[ "$reply" =~ ^[Yy]$ ]]
}

# --- 1. Prerequisites ---------------------------------------------------------
step "Checking prerequisites"
[ "$(id -u)" -eq 0 ] || die "run as root (sudo)"
command -v git    >/dev/null || die "git is not installed (apt install git)"
command -v curl   >/dev/null || die "curl is not installed (apt install curl)"
command -v docker >/dev/null || die "Docker is not installed: https://docs.docker.com/engine/install/ubuntu/"
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is missing (apt install docker-compose-plugin)"
ok "git, curl, docker and docker compose found"

# --- 2. Old server.js setup ---------------------------------------------------
step "Looking for the old server.js setup"
found_old=0

if systemctl list-unit-files stremio-manager.service 2>/dev/null | grep -q stremio-manager; then
  found_old=1
  warn "found stremio-manager.service (it starts the old container on demand)"
  if confirm "Stop, disable and remove stremio-manager.service?"; then
    systemctl disable --now stremio-manager.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/stremio-manager.service
    systemctl daemon-reload
    ok "stremio-manager.service removed"
  else
    warn "kept it; it may start the old container again and take ports 11470/443"
  fi
fi

old_data=""
if docker container inspect stremio >/dev/null 2>&1 &&
   [ -z "$(docker container inspect -f '{{ index .Config.Labels "io.github.mudales.stream-server" }}' stremio)" ]; then
  found_old=1
  old_data="$(docker container inspect -f '{{ range .Mounts }}{{ if eq .Destination "/root/.stremio-server" }}{{ .Source }}{{ end }}{{ end }}' stremio)"
  old_image="$(docker container inspect -f '{{ .Image }}' stremio)"
  warn "found the old 'stremio' container"
  if confirm "Remove the old container and its image?"; then
    docker rm -f stremio >/dev/null
    docker image rm "$old_image" >/dev/null 2>&1 || true
    ok "old container and image removed"
  else
    die "the old container uses the same name and ports; remove it first"
  fi
fi

if [ -z "$old_data" ] && [ -n "${OLD_STREMIO_DIR:-}" ]; then
  old_data="$OLD_STREMIO_DIR/stremio-server"
fi
if [ -n "$old_data" ] && [ -d "$old_data/stremio-cache" ]; then
  found_old=1
  size="$(du -sh "$old_data/stremio-cache" | cut -f1)"
  if confirm "Delete the old server.js cache $old_data/stremio-cache ($size)?"; then
    rm -rf "$old_data/stremio-cache"
    ok "old cache deleted"
  fi
fi
[ "$found_old" = 1 ] || ok "nothing to clean up"

# --- 3. Fetch the code --------------------------------------------------------
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

# --- 4. Configuration ---------------------------------------------------------
step "Configuring"
if [ ! -f .env ]; then
  hosts="${CERT_HOSTS:-$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v -e ':' -e '^$' | paste -sd, -),$(hostname)}"
  printf 'CERT_HOSTS=%s\n' "$hosts" > .env
  ok "wrote .env (CERT_HOSTS=$hosts)"
else
  # Older installers wrote TARGET_CPU automatically; drop it so the build uses "native".
  sed -i -e '/^TARGET_CPU=$/d' -e '/^TARGET_CPU=x86-64-v2$/d' .env
  ok "keeping existing .env"
fi

# --- 5. Cache from a previous version -----------------------------------------
last="$(cat data/.installed-rev 2>/dev/null || true)"
if [ -n "$last" ] && [ "$last" != "$rev" ] && [ -d data/cache ]; then
  step "Clearing cache from previous version ($last)"
  docker compose down >/dev/null 2>&1 || true
  rm -rf data/cache
  ok "torrent cache cleared (settings and certificate kept)"
fi

# --- 6. Build and start -------------------------------------------------------
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
