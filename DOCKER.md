# Self-hosting with Docker

This fork adds a Docker setup so stream-server runs headless on a home server and
can be used as the streaming server for <https://web.stremio.com> (or any Stremio app).

## Quick install (Ubuntu / Debian)

Needs: Docker Engine with the compose plugin, `git`, `curl`.

```bash
curl -fsSL https://raw.githubusercontent.com/Mudales/stream-server/master/install.sh | sudo bash
```

The installer:

1. Finds the old `server.js` setup (`stremio-manager.service`, the old `stremio` container and its
   `stremio-cache` folder) and asks before removing each one.
2. Clones this repo to `/opt/stream-server` (or updates it).
3. Writes `.env` with the server's IPs for the certificate, and picks `x86-64-v2` if the CPU has no AVX2.
4. After an update to a new commit, clears the old torrent cache (settings and certificate are kept).
5. Builds the image, starts the container and waits for `/heartbeat`.

Run the same command again to update. Options are environment variables, listed at the top of
[`install.sh`](install.sh) (`INSTALL_DIR`, `BRANCH`, `CERT_HOSTS`, `OLD_STREMIO_DIR`, `ASSUME_YES=1`).

## Manual install

```bash
git clone https://github.com/Mudales/stream-server.git /opt/stream-server
cd /opt/stream-server
mkdir -p data certs
echo "CERT_HOSTS=192.168.1.10,stremio.lan" > .env   # your server's IP / hostname
docker compose up -d --build
```

## Ports

| Host  | Container | Use |
|-------|-----------|-----|
| 11470 | 11470     | HTTP API and streams |
| 443   | 12470     | HTTPS (needed by web.stremio.com) |

If port 443 is already taken (nginx, Caddy…), change the left side in `docker-compose.yml`,
or point your reverse proxy at `http://localhost:11470` and remove the `443` line.

## HTTPS certificate

web.stremio.com is served over HTTPS, so the browser only talks to a streaming server over HTTPS.
The server reads two files from `data/config/stremio-server/`:

| File             | Content |
|------------------|---------|
| `https-cert.pem` | certificate (public key + names, signed) |
| `https-key.pem`  | private key — keep it secret |

**Default: self-signed.** If they don't exist, the container creates them on first start, valid for
10 years for `localhost` and the names in `CERT_HOSTS`. Open `https://<server-ip>` once in each
browser and accept the warning; after that web.stremio.com can connect.

**Your own certificate** (for example Let's Encrypt for a real domain): put the files in `./certs`:

| Put in `./certs` | From Let's Encrypt |
|------------------|--------------------|
| `cert.pem`       | `fullchain.pem` |
| `key.pem`        | `privkey.pem` |

then `docker compose restart`. They are copied in on every start, so after a renewal replace the files
and restart. The certificate must match the address you type into Stremio.

**New self-signed certificate** (e.g. the IP changed): edit `CERT_HOSTS` in `.env`, delete
`data/config/stremio-server/https-*.pem`, then `docker compose up -d`.

## Connect web.stremio.com

Settings → Streaming → **Streaming server URL** → `https://<server-ip>` (or your domain).

## Data and cache

| Path | Content |
|------|---------|
| `data/config/stremio-server/` | `settings.json`, logs, HTTPS certificate |
| `data/cache/stremio-server/`  | torrent cache |

The cache is cleaned automatically: 60 s after download activity and every hour, oldest files first,
down to the cache size from Stremio's settings (default 10 GB). Files being streamed are kept.

## Commands

```bash
cd /opt/stream-server
docker logs -f stremio        # logs
docker compose restart        # restart
docker compose down           # stop
sudo ./install.sh             # update
```

Uninstall: `docker compose down --rmi local && sudo rm -rf /opt/stream-server`.

## Notes

- The image is built from this repo's source, so your own changes are included. The first build
  compiles libtorrent and a release Rust binary (LTO): 15–30+ minutes and about 4 GB of RAM.
- `.cargo/config.toml` targets `x86-64-v3` (AVX2). Set `TARGET_CPU=x86-64-v2` in `.env` for older CPUs.
- Hardware transcoding: uncomment the `/dev/dri` device in `docker-compose.yml`.
