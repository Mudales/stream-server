#!/bin/sh
# Prepares the HTTPS certificate, then starts stream-server headless.
set -eu

CFG="${XDG_CONFIG_HOME:-/data/config}/stremio-server"
CERT="$CFG/https-cert.pem"
KEY="$CFG/https-key.pem"
mkdir -p "$CFG" "${XDG_CACHE_HOME:-/data/cache}/stremio-server"

if [ -f /certs/cert.pem ] && [ -f /certs/key.pem ]; then
  # Your own certificate, copied on every start so a renewal only needs a restart.
  cp /certs/cert.pem "$CERT"
  cp /certs/key.pem "$KEY"
  chmod 600 "$KEY"
  echo "[entrypoint] using certificate from /certs"
elif [ ! -s "$CERT" ] || [ ! -s "$KEY" ]; then
  SAN="DNS:localhost,IP:127.0.0.1"
  for h in $(echo "${CERT_HOSTS:-}" | tr ',' ' '); do
    case "$h" in
      *[!0-9.]*) SAN="$SAN,DNS:$h" ;;
      *)         SAN="$SAN,IP:$h" ;;
    esac
  done
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -subj "/CN=stremio-server" -addext "subjectAltName=$SAN" \
    -keyout "$KEY" -out "$CERT" 2>/dev/null
  chmod 600 "$KEY"
  echo "[entrypoint] generated self-signed certificate for $SAN"
fi

exec stream-server --no-tray "$@"
