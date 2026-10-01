#!/usr/bin/env bash
# Install or update stream-server from the upstream .deb release (no compiling).
# Ubuntu 24.04+ on amd64, with a CPU that supports x86-64-v3 (AVX2).
#
#   curl -fsSL https://raw.githubusercontent.com/Mudales/stream-server/master/install-deb.sh | sudo bash
#   curl -fsSL https://raw.githubusercontent.com/Mudales/stream-server/master/install-deb.sh | sudo bash -s -- --https builtin
#
# Options:
#   --https nginx            nginx on :443 handles HTTPS and proxies to :11470 (default)
#   --https builtin          stream-server serves HTTPS itself on :12470
#   --https none             HTTP on :11470 only (put your own reverse proxy in front)
#   --cert FILE --key FILE   your certificate (full chain) and private key; default: self-signed
#   --hosts LIST             IPs/names for the self-signed certificate (default: this server's)
#   --version vX.Y.Z         release to install (default: latest)
set -euo pipefail

UPSTREAM="stremio-native/stream-server"
DATA_DIR=/var/lib/stream-server
CFG_DIR="$DATA_DIR/config/stremio-server"
CACHE_DIR="$DATA_DIR/cache/stremio-server"
TLS_DIR=/etc/stream-server/tls
HTTPS=nginx CERT="" KEY="" HOSTS="" VERSION=""

step() { printf '\n==== %s ====\n' "$1"; }
ok()   { printf '\033[32m✔ %s\033[0m\n' "$1"; }
warn() { printf '\033[33m! %s\033[0m\n' "$1"; }
die()  { printf '\033[31m✖ %s\033[0m\n' "$1" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --https)   HTTPS="${2:-}"; shift 2 ;;
    --cert)    CERT="${2:-}"; shift 2 ;;
    --key)     KEY="${2:-}"; shift 2 ;;
    --hosts)   HOSTS="${2:-}"; shift 2 ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done
case "$HTTPS" in nginx|builtin|none) ;; *) die "--https must be nginx, builtin or none" ;; esac
if [ -n "$CERT$KEY" ]; then
  [ -f "$CERT" ] && [ -f "$KEY" ] || die "--cert and --key must both point to existing files"
fi

# --- 1. Checks ----------------------------------------------------------------
step "Checking the system"
[ "$(id -u)" -eq 0 ] || die "run as root (sudo)"
[ "$(dpkg --print-architecture)" = amd64 ] || die "the .deb is amd64 only; use the Docker install instead"
glibc="$(getconf GNU_LIBC_VERSION | awk '{print $2}')"
[ "$(printf '%s\n' 2.39 "$glibc" | sort -V | head -1)" = 2.39 ] ||
  die "glibc $glibc is too old, the .deb needs Ubuntu 24.04 or newer"
missing=""
for flag in avx2 bmi1 bmi2 fma movbe abm; do
  grep -qw "$flag" /proc/cpuinfo || missing="$missing $flag"
done
if [ -n "$missing" ]; then
  die "CPU lacks x86-64-v3 features:$missing
  The release binary would crash (SIGILL). Options:
  - Proxmox VM: set Hardware > Processors > Type to 'host', then power the VM off and on
  - run it in an LXC container (it sees the host CPU)
  - use the Docker install (install.sh), which compiles for this CPU"
fi
ok "Ubuntu glibc $glibc, amd64, CPU supports x86-64-v3"

# --- 2. Download --------------------------------------------------------------
if [ -z "$VERSION" ]; then
  # github.com/<repo>/releases/latest redirects to .../releases/tag/<version>
  latest="$(curl -fsSLo /dev/null -w '%{url_effective}' "https://github.com/$UPSTREAM/releases/latest")"
  VERSION="${latest##*/}"
  [[ "$VERSION" == v* ]] || die "could not find the latest release"
fi
step "Downloading stream-server $VERSION"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
chmod 755 "$tmp"
deb="stream-server-linux-amd64.deb"
base="https://github.com/$UPSTREAM/releases/download/$VERSION"
curl -fsSL -o "$tmp/$deb" "$base/$deb"
curl -fsSL -o "$tmp/SHA256SUMS.txt" "$base/SHA256SUMS.txt"
sum="$(awk -v f="$deb" '$2 == f || $2 == "*" f { print $1; exit }' "$tmp/SHA256SUMS.txt")"
[ -n "$sum" ] || die "$deb is not listed in SHA256SUMS.txt"
echo "$sum  $tmp/$deb" | sha256sum -c --quiet - || die "checksum mismatch"
ok "downloaded and verified"

# --- 3. Install ---------------------------------------------------------------
step "Installing"
old_ver="$(dpkg-query -W -f='${Version}' server 2>/dev/null || true)"
new_ver="$(dpkg-deb -f "$tmp/$deb" Version)"
if [ -n "$old_ver" ] && [ "$old_ver" != "$new_ver" ] && [ -d "$CACHE_DIR" ]; then
  systemctl stop stream-server.service 2>/dev/null || true
  find "$CACHE_DIR" -mindepth 1 -delete
  ok "cleared the torrent cache of $old_ver"
fi
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$tmp/$deb" ffmpeg openssl curl >/dev/null
ok "package 'server' $new_ver installed (binary: /usr/bin/stream-server)"

id stream-server >/dev/null 2>&1 ||
  useradd --system --home-dir "$DATA_DIR" --shell /usr/sbin/nologin stream-server
mkdir -p "$CFG_DIR" "$CACHE_DIR"
chown -R stream-server:stream-server "$DATA_DIR"

# --- 4. Certificate -----------------------------------------------------------
# make_cert <cert> <key> <owner>: your files if given, otherwise self-signed (kept if it exists)
make_cert() {
  if [ -n "$CERT" ]; then
    install -m 644 -o "$3" "$CERT" "$1"
    install -m 600 -o "$3" "$KEY" "$2"
    ok "using your certificate ($CERT)"
  elif [ ! -s "$1" ] || [ ! -s "$2" ]; then
    local hosts="${HOSTS:-$(hostname -I | tr ' ' '\n' | grep -v -e ':' -e '^$' | paste -sd, -),$(hostname)}"
    local san="DNS:localhost,IP:127.0.0.1" h
    for h in $(echo "$hosts" | tr ',' ' '); do
      case "$h" in *[!0-9.]*) san="$san,DNS:$h" ;; *) san="$san,IP:$h" ;; esac
    done
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=stream-server" \
      -addext "subjectAltName=$san" -keyout "$2" -out "$1" 2>/dev/null
    chown "$3" "$1" "$2"
    chmod 600 "$2"
    ok "generated a self-signed certificate for $san"
  else
    ok "keeping the existing certificate $1"
  fi
}

step "HTTPS: $HTTPS"
case "$HTTPS" in
  builtin)
    make_cert "$CFG_DIR/https-cert.pem" "$CFG_DIR/https-key.pem" stream-server ;;
  nginx)
    mkdir -p "$TLS_DIR"
    make_cert "$TLS_DIR/cert.pem" "$TLS_DIR/key.pem" root
    listeners="$(ss -Hltnp 'sport = :443')"
    if [ -n "$listeners" ] && ! grep -q nginx <<<"$listeners"; then
      die "port 443 is used by another program; use --https none behind your existing proxy"
    fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx >/dev/null
    cat > /etc/nginx/sites-available/stream-server <<'EOF'
# stream-server: HTTPS on 443 -> http://127.0.0.1:11470
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name _;

    ssl_certificate     /etc/stream-server/tls/cert.pem;
    ssl_certificate_key /etc/stream-server/tls/key.pem;

    client_max_body_size 0;

    location / {
        proxy_pass http://127.0.0.1:11470;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Connection "";
        # video streams: no buffering, long timeouts
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
    }
}
EOF
    ln -sf /etc/nginx/sites-available/stream-server /etc/nginx/sites-enabled/stream-server
    nginx -t -q || die "nginx config test failed"
    systemctl enable --now nginx >/dev/null 2>&1
    systemctl reload nginx
    ok "nginx proxies https://:443 to :11470" ;;
  none)
    ok "no HTTPS, the server is on http://:11470" ;;
esac

# --- 5. Service ---------------------------------------------------------------
step "Starting the service"
cat > /etc/systemd/system/stream-server.service <<EOF
[Unit]
Description=Stream Server (Stremio streaming server)
After=network-online.target
Wants=network-online.target

[Service]
User=stream-server
Group=stream-server
Environment=HOME=$DATA_DIR
Environment=XDG_CONFIG_HOME=$DATA_DIR/config
Environment=XDG_CACHE_HOME=$DATA_DIR/cache
ExecStart=/usr/bin/stream-server --no-tray
Restart=on-failure
RestartSec=5
MemoryMax=2G
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=strict
ReadWritePaths=$DATA_DIR

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable stream-server.service >/dev/null 2>&1
systemctl restart stream-server.service

up=0
for _ in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:11470/heartbeat >/dev/null 2>&1; then up=1; break; fi
  sleep 2
done
[ "$up" = 1 ] && ok "server is up" || warn "no answer yet, check: journalctl -u stream-server -e"

ip="$(hostname -I | awk '{print $1}')"
step "Done"
case "$HTTPS" in
  nginx)   url="https://$ip" ;;
  builtin) url="https://$ip:12470" ;;
  none)    url="http://$ip:11470" ;;
esac
echo "Streaming server URL: $url"
[ -z "$CERT" ] && [ "$HTTPS" != none ] &&
  echo "Self-signed: open $url once in the browser and accept the certificate."
echo "In web.stremio.com: Settings -> Streaming server URL -> $url"
echo "Logs:   journalctl -u stream-server -f"
echo "Update: run this installer again"
