# Self-hosting

Run stream-server headless on a home server and use it as the streaming server for
<https://web.stremio.com> (or any Stremio app).

## Pick a method

|                 | **.deb** (`install-deb.sh`) | **Docker** (`install.sh`) |
|-----------------|-----------------------------|---------------------------|
| Install time    | about a minute, no compiling | 15–30+ min for the first build |
| CPU             | needs x86-64-v3 (AVX2: Intel Haswell / AMD Excavator, 2013+) | any, built for your CPU |
| OS              | Ubuntu 24.04+ amd64 (host, VM or LXC) | anything with Docker |
| Runs as         | systemd service | container |
| HTTPS           | nginx on 443 (default), built-in on 12470, or none | built-in, mapped to 443 |

RAM and CPU use while running are the same; it is the same program.

Check the CPU:

```bash
grep -o -w -e avx2 -e bmi2 -e fma /proc/cpuinfo | sort -u
```

All three must be listed for the .deb. On a **Proxmox VM** the default CPU type hides them: set
Hardware → Processors → Type to `host` and power the VM off and on. An **LXC container** sees
the host CPU directly.

## Option A: .deb (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/Mudales/stream-server/master/install-deb.sh | sudo bash
```

This downloads the latest upstream release, checks its SHA-256, installs it with `ffmpeg`, creates a
`stream-server` system user and a systemd service, and sets up HTTPS. Run it again to update; after an
update to a new version the old torrent cache is cleared (settings are kept).

Options go after `bash -s --`:

| Option | Meaning |
|--------|---------|
| `--https nginx` | default: nginx listens on 443 with the certificate and proxies to `127.0.0.1:11470` |
| `--https builtin` | the server serves HTTPS itself on port 12470 |
| `--https none` | HTTP on 11470 only, for use behind your own reverse proxy |
| `--cert FILE --key FILE` | your certificate (full chain) and private key; without them a self-signed one is created |
| `--hosts LIST` | IPs/names for the self-signed certificate, e.g. `192.168.1.10,stremio.lan` |
| `--version vX.Y.Z` | install a specific release |

Example with a Let's Encrypt certificate:

```bash
curl -fsSL https://raw.githubusercontent.com/Mudales/stream-server/master/install-deb.sh | sudo bash -s -- \
  --cert /etc/letsencrypt/live/stremio.example.com/fullchain.pem \
  --key  /etc/letsencrypt/live/stremio.example.com/privkey.pem
```

| Path | Content |
|------|---------|
| `/var/lib/stream-server/config/stremio-server/` | `settings.json`, logs (and the certificate with `--https builtin`) |
| `/var/lib/stream-server/cache/stremio-server/` | torrent cache |
| `/etc/stream-server/tls/` | certificate used by nginx |
| `/etc/nginx/sites-available/stream-server` | nginx site |

```bash
systemctl status stream-server
journalctl -u stream-server -f
```

Uninstall:

```bash
sudo systemctl disable --now stream-server
sudo apt remove server
sudo rm -f /etc/systemd/system/stream-server.service /etc/nginx/sites-enabled/stream-server /etc/nginx/sites-available/stream-server
sudo rm -rf /var/lib/stream-server /etc/stream-server
sudo userdel stream-server
```

(The upstream package is literally named `server`.)

## Option B: Docker

```bash
curl -fsSL https://raw.githubusercontent.com/Mudales/stream-server/master/install.sh | sudo bash
```

Clones this repo to `/opt/stream-server`, writes `.env` with the server's IPs for the certificate,
builds the image from source for this CPU and starts it. Run it again to update.

Manual:

```bash
git clone https://github.com/Mudales/stream-server.git /opt/stream-server
cd /opt/stream-server
mkdir -p data certs
echo "CERT_HOSTS=192.168.1.10,stremio.lan" > .env
docker compose up -d --build
```

| Host port | Container | Use |
|-----------|-----------|-----|
| 11470 | 11470 | HTTP |
| 443   | 12470 | HTTPS |

| Path | Content |
|------|---------|
| `data/config/stremio-server/` | `settings.json`, logs, HTTPS certificate |
| `data/cache/stremio-server/`  | torrent cache |
| `certs/` | optional: your own `cert.pem` (full chain) + `key.pem`, copied in on every start |

To get a fresh self-signed certificate (e.g. the IP changed): edit `CERT_HOSTS` in `.env`, delete
`data/config/stremio-server/https-*.pem`, then `docker compose up -d`.

```bash
docker logs -f stremio
docker compose restart
docker compose down --rmi local   # uninstall (then delete /opt/stream-server)
```

Notes: the first build needs about 4 GB of RAM. The binary is built for the CPU of the machine that
builds it; set `TARGET_CPU=x86-64-v2` in `.env` to build for other machines. For hardware transcoding,
uncomment the `/dev/dri` device in `docker-compose.yml`.

## HTTPS and certificates

web.stremio.com is an HTTPS page, so the browser only talks to a streaming server over HTTPS.
A certificate is two files:

| File | Content |
|------|---------|
| certificate (`cert.pem`, `https-cert.pem`, `fullchain.pem`) | the public key plus the names it is valid for, signed. Sent to every browser; not secret. |
| private key (`key.pem`, `https-key.pem`, `privkey.pem`) | proves the server owns the certificate. Never share it. |

A **self-signed** certificate is signed by the server itself, so browsers warn: open the server's
HTTPS address once in each browser and accept it. A certificate from a CA such as Let's Encrypt needs
a domain name but gives no warning. The name you type into Stremio must be in the certificate.

**Already have a reverse proxy** (nginx, Nginx Proxy Manager, Caddy, Traefik)? Install with
`--https none` (or use port 11470 of the Docker setup) and point the proxy at `http://<server>:11470`.
Turn off response buffering and raise read timeouts so video streams are not cut.

## Connect web.stremio.com

Settings → Streaming → **Streaming server URL** → the URL printed by the installer
(`https://<server-ip>` by default).

## Cache

Cleaned automatically: 60 s after download activity and every hour, oldest files first, down to the
cache size set in Stremio's settings (default 10 GB). Files being streamed are kept.
