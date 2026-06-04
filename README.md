# Florence's Seismic Travel Bureau

A live earthquake visualiser. **Florence** — one tireless traveller — flies between
real USGS earthquake epicentres in chronological order on a dark Leaflet map,
stamping her passport and filing wry telegrams about each one.

This repo is packaged to run on a **Raspberry Pi**: either as a small always-on
LAN server you open from any device, or as a full-screen **kiosk** on a screen
wired to the Pi.

```
┌─ browser ─────────────┐      ┌─ Pi: server.py (stdlib) ─┐      ┌─ USGS ─┐
│ public/index.html     │ ───▶ │ /            static files │      │ GeoJSON│
│ Leaflet + tour engine │ ◀─── │ /api/feed    cache + proxy │ ──▶ │ feeds  │
│ live / cached / demo  │      │ /healthz     status        │ ◀── │  ~1/min│
└───────────────────────┘      └────────────────────────────┘      └────────┘
```

## What's new for deployment

- **Zero-dependency Python server** (`server.py`) — standard library only, no
  `pip install`. Runs on the Python that ships with Raspberry Pi OS.
- **Caching USGS proxy** at `/api/feed` — fetches once per minute, serves the
  **last-good copy from disk when USGS is unreachable**, so a kiosk on a flaky
  network keeps showing real data instead of breaking. Survives reboots.
- **Self-contained assets** — Leaflet is vendored under `public/vendor/`, so the
  app shell loads with no CDN (only the map tiles and the feed need the internet).
- **Live / Cached / Demo indicator** so you always know where the data came from.
- **Auto-refresh** — pulls new quakes on an interval (default 5 min) without a
  page reload; only ingests when something actually changed.
- **Kiosk loop mode** — the tour restarts forever, the cursor hides, and Chromium
  runs full-screen and respawns on crash.
- **Fullscreen toggle**, **settings persistence** (feed/speed/loop/auto remembered),
  and **URL parameters** for unattended configuration.
- Deploy tooling: a hardened **systemd unit**, an **installer**, a **kiosk setup**
  script (handles current Wayland/labwc *and* legacy X11), and **Docker**.

---

## Quick start

### 0. Get the files onto the Pi
```bash
scp -r florence-tracker pi@raspberrypi.local:~/      # or git clone, or a USB stick
cd ~/florence-tracker
```

### 1. Just run it (try before you install)
```bash
python3 server.py
# → http://<pi-ip>:8080/
```
No dependencies, nothing to install. `Ctrl-C` to stop.

### 2. Install as a service (starts on boot, restarts on crash) — recommended
```bash
sudo ./deploy/install.sh
```
This creates a locked-down `florence` user, installs the app to
`/opt/florence-tracker`, enables the systemd service, and verifies it's healthy.
Open `http://<pi-ip>:8080/` from any device on your network.

```bash
systemctl status florence-tracker        # state
journalctl -u florence-tracker -f        # live logs
systemd-analyze security florence-tracker # hardening audit
sudo ./deploy/install.sh --uninstall     # remove
```

### 3. Or run with Docker
```bash
curl -fsSL https://get.docker.com | sudo sh    # if Docker isn't installed yet
sudo usermod -aG docker $USER && newgrp docker
docker compose up -d --build
```
`docker compose ps` shows the health status; the feed cache lives in the
`florence-cache` volume.

---

## Kiosk mode (full-screen on a screen wired to the Pi)

With the server already running (step 2 or 3), run **as your desktop user — not
sudo**:

```bash
./deploy/kiosk-setup.sh
```

It detects your session and does the right thing:

- **Current Raspberry Pi OS (Bookworm) uses Wayland + labwc.** The script writes
  `~/.config/labwc/autostart` and launches Chromium via `/usr/bin/lwrespawn` so it
  respawns on crash. *(This is why most older kiosk tutorials silently fail on a
  fresh Pi — they edit the X11/LXDE autostart, which Wayland never reads.)*
- **Legacy X11/LXDE** (if you switched the Pi back to X11): pass `--x11` and it
  writes `~/.config/lxsession/LXDE-pi/autostart` with the classic `@`-prefixed
  lines (`xset` blanking-off, `unclutter`, Chromium).

It also enables desktop auto-login and disables screen blanking via
`raspi-config`. Then:

```bash
sudo reboot
```

Chromium comes up full-screen on `http://localhost:8080/?kiosk=1`, looping the
tour forever with the cursor hidden.

> **Helpers:** `sudo apt install -y wtype` (Wayland) or `sudo apt install -y unclutter`
> (X11) if prompted. Confirm your browser binary with `which chromium chromium-browser`.

---

## Configuration

### Server (environment variables)

| Variable | Default | Meaning |
|---|---|---|
| `FLORENCE_HOST` | `0.0.0.0` | Bind address (use `127.0.0.1` for kiosk-only) |
| `FLORENCE_PORT` | `8080` | Listen port |
| `FLORENCE_STATIC_DIR` | `./public` | Web root |
| `FLORENCE_CACHE_DIR` | `./cache` | Where last-good feeds are stored |
| `FLORENCE_CACHE_TTL` | `60` | Seconds before a feed is re-fetched (USGS updates ~1×/min) |
| `FLORENCE_UPSTREAM` | USGS summary base | Feed source |
| `FLORENCE_TIMEOUT` | `12` | Upstream fetch timeout (s) |
| `FLORENCE_LOG` | `INFO` | Log level |

```bash
sudo env PORT=9000 ./deploy/install.sh    # respects PORT / HOST / INSTALL_DIR / SERVICE_USER
```
> Use `sudo env VAR=…` — a plain `sudo VAR=…` is stripped by sudo's `env_reset`.

### App (URL parameters)

Append to the URL, e.g. `http://localhost:8080/?kiosk=1&feed=2.5_day&speed=4`.

| Param | Example | Effect |
|---|---|---|
| `kiosk` | `?kiosk=1` | Hide cursor, loop forever, auto-refresh on |
| `loop` | `?loop=1` | Restart the tour when it finishes |
| `auto` | `?auto=0` | Force auto-refresh off (default on) |
| `refresh` | `?refresh=600` | Auto-refresh interval in seconds (min 30) |
| `feed` | `?feed=significant_week` | Pick the feed on load |
| `speed` | `?speed=4` | Playback speed (1–8) |

Feed/speed/loop/auto are also remembered in `localStorage` between visits.

### Endpoints

| Path | Description |
|---|---|
| `/` | The app |
| `/api/feed?id=<feed>` | Cached USGS GeoJSON. Header `X-Florence-Cache: fresh\|live\|stale` |
| `/api/feeds` | The 20 allowed feed ids |
| `/healthz` | JSON: uptime, per-feed cache age, last fetch status |

The 20 feeds are `{significant,4.5,2.5,1.0,all}_{hour,day,week,month}`. Anything
else is rejected — `/api/feed` can't be turned into an open proxy.

---

## How resilience works

1. Browser asks the Pi for `/api/feed?id=…`.
2. The Pi serves its cached copy if it's < `FLORENCE_CACHE_TTL` old (`fresh`),
   otherwise makes **one** conditional request to USGS (`live`).
3. If USGS is slow/down, the Pi serves the **last-good copy from disk** (`stale`)
   and the app shows a **CACHED** badge — Florence keeps flying.
4. If the proxy itself is unreachable, the browser falls back to fetching USGS
   directly (USGS feeds are CORS-enabled). If *that* fails too, clearly-labelled
   **DEMO** data is shown so the screen is never blank.

---

## Troubleshooting

- **Kiosk doesn't start after reboot (Bookworm):** you're on Wayland/labwc but an
  old tutorial edited the X11 autostart. Re-run `./deploy/kiosk-setup.sh` (it
  targets labwc by default). Confirm auto-login is on (`raspi-config` → System
  Options → Boot/Auto Login → Desktop Autologin).
- **`chromium: command not found`:** `sudo apt install -y chromium`. Some images
  name it `chromium-browser`; the script checks both.
- **Map tiles are blank but markers show:** the Pi has no internet route to CARTO.
  Markers/feeds may still work from cache; tiles always need the network.
- **Docker `mem_limit` ignored / "No memory limit support":** enable cgroup memory
  — add `cgroup_enable=memory cgroup_memory=1` to the single line in
  `/boot/firmware/cmdline.txt` and reboot.
- **Service won't start:** `journalctl -u florence-tracker -n 50`. The hardened
  unit needs a writable `/var/cache/florence-tracker` (systemd creates it via
  `CacheDirectory=`); don't point `FLORENCE_CACHE_DIR` somewhere read-only.

---

## File layout

```
florence-tracker/
├── server.py                    zero-dependency server (static + caching proxy + health)
├── public/
│   ├── index.html               the app (vendored-Leaflet + new features)
│   └── vendor/leaflet/          self-hosted Leaflet 1.9.4 (js, css, images)
├── deploy/
│   ├── florence-tracker.service hardened systemd unit
│   ├── install.sh               install / upgrade / uninstall the service
│   └── kiosk-setup.sh           Chromium kiosk autostart (Wayland + X11)
├── Dockerfile                   multi-arch (arm64 + arm/v7) image
├── docker-compose.yml           one-command container deploy
├── Makefile                     run / install / kiosk / docker shortcuts
└── florence-seismic-bureau.html original single-file version (kept as a backup)
```

Data: live earthquake feeds © [USGS](https://earthquake.usgs.gov/). Map tiles ©
[OpenStreetMap](https://www.openstreetmap.org/copyright) & [CARTO](https://carto.com/attributions).
