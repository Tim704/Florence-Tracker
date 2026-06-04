#!/usr/bin/env bash
#
# Install Florence's Seismic Travel Bureau as a systemd service on Raspberry Pi
# OS (or any systemd Linux). Copies the app to /opt, creates a locked-down
# service user, installs + enables the unit, and verifies it actually came up.
#
# Usage:
#   sudo ./deploy/install.sh                     # install / upgrade
#   sudo env PORT=9000 ./deploy/install.sh       # override the listen port
#   sudo ./deploy/install.sh --uninstall         # remove service (keeps cache)
#
# Note: use `sudo env VAR=...` (not `sudo VAR=...`) — sudo's default env_reset
# would otherwise strip the variable before the script ever sees it.
# Overridable: PORT, HOST, INSTALL_DIR, SERVICE_USER.
#
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/florence-tracker}"
SERVICE_USER="${SERVICE_USER:-florence}"
SERVICE_NAME="florence-tracker"
PORT="${PORT:-8080}"
HOST="${HOST:-0.0.0.0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"

say()  { printf '\033[1;33m▸ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;31m! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run with sudo (need to create a user + write /etc/systemd)."

# ---------------------------------------------------------------- uninstall ---
if [ "${1:-}" = "--uninstall" ]; then
  say "Stopping and removing ${SERVICE_NAME}…"
  systemctl disable --now "${SERVICE_NAME}.service" 2>/dev/null || true
  rm -f "${UNIT_PATH}"
  systemctl daemon-reload
  say "Removed. App files in ${INSTALL_DIR} and cache in /var/cache/${SERVICE_NAME} were left in place."
  say "Delete them with:  sudo rm -rf ${INSTALL_DIR} /var/cache/${SERVICE_NAME}  and  sudo userdel ${SERVICE_USER}"
  exit 0
fi

# ------------------------------------------------------------------ install ---
command -v python3 >/dev/null || die "python3 not found (sudo apt install -y python3)."
[ -f "${REPO_DIR}/server.py" ]      || die "server.py not found next to this script."
[ -f "${REPO_DIR}/public/index.html" ] || die "public/index.html not found."

PYTHON_BIN="$(command -v python3)"

say "Creating service user '${SERVICE_USER}' (if missing)…"
if ! id "${SERVICE_USER}" >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin "${SERVICE_USER}"
fi

say "Installing app into ${INSTALL_DIR}…"
mkdir -p "${INSTALL_DIR}"
# copy server + web root; remove a stale public/ first so deletions propagate
cp -f "${REPO_DIR}/server.py" "${INSTALL_DIR}/server.py"
rm -rf "${INSTALL_DIR}/public"
cp -R "${REPO_DIR}/public" "${INSTALL_DIR}/public"
# app files are read-only to the service (ProtectSystem=strict enforces this too)
chown -R root:root "${INSTALL_DIR}"
chmod -R a+rX "${INSTALL_DIR}"

say "Rendering systemd unit → ${UNIT_PATH}…"
sed -e "s#/opt/florence-tracker#${INSTALL_DIR}#g" \
    -e "s#^User=florence#User=${SERVICE_USER}#" \
    -e "s#^Group=florence#Group=${SERVICE_USER}#" \
    -e "s#^Environment=FLORENCE_PORT=8080#Environment=FLORENCE_PORT=${PORT}#" \
    -e "s#^Environment=FLORENCE_HOST=0.0.0.0#Environment=FLORENCE_HOST=${HOST}#" \
    -e "s#^ExecStart=/usr/bin/python3#ExecStart=${PYTHON_BIN}#" \
    "${SCRIPT_DIR}/${SERVICE_NAME}.service" > "${UNIT_PATH}"

say "Enabling + starting service…"
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}.service" >/dev/null
systemctl restart "${SERVICE_NAME}.service"

# give it a moment, then confirm it's actually healthy (not just 'started')
probe_health() {
  python3 - "$PORT" <<'PY' || true
import sys, urllib.request
try:
    with urllib.request.urlopen("http://127.0.0.1:%s/healthz" % sys.argv[1], timeout=5) as r:
        print("ok" if r.status == 200 else "bad:%s" % r.status)
except Exception as e:
    print("unreachable:%s" % e)
PY
}

# Type=simple reports "active" the instant the process is exec'd — before the
# socket is bound. Poll /healthz so success means actually serving, not just spawned.
HEALTH="unreachable"
for _ in 1 2 3 4 5 6; do
  if ! systemctl is-active --quiet "${SERVICE_NAME}.service"; then break; fi
  HEALTH="$(probe_health)"
  [ "${HEALTH}" = "ok" ] && break
  sleep 1
done
if [ "${HEALTH}" != "ok" ]; then
  printf '\n'; journalctl -u "${SERVICE_NAME}.service" -n 25 --no-pager || true
  die "service did not become healthy (last probe: ${HEALTH}) — see the log above."
fi

# Exercise the caching proxy end-to-end: this resolves DNS + makes an outbound
# HTTPS call to USGS *from inside the systemd sandbox*, so a hardening directive
# that blocks egress shows up here (a plain /healthz would still report "ok").
UPSTREAM_OK="$(python3 - "$PORT" <<'PY' || true
import sys, urllib.request
try:
    with urllib.request.urlopen("http://127.0.0.1:%s/api/feed?id=significant_week" % sys.argv[1], timeout=20) as r:
        print(r.headers.get("X-Florence-Cache", "?") if r.status == 200 else "bad:%s" % r.status)
except Exception as e:
    print("unreachable:%s" % e)
PY
)"

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
printf '\n\033[1;32m✓ Florence is airborne.\033[0m\n'
echo "  service : systemctl status ${SERVICE_NAME}   (logs: journalctl -u ${SERVICE_NAME} -f)"
echo "  health  : ${HEALTH}"
case "${UPSTREAM_OK}" in
  live|fresh|stale) echo "  upstream: USGS reachable (${UPSTREAM_OK})" ;;
  *) warn "upstream: could NOT reach USGS from the service (${UPSTREAM_OK})."
     echo "           The app still works via the browser's direct-USGS fallback, but the"
     echo "           caching proxy is degraded. Check the Pi's network/DNS; if it works"
     echo "           outside systemd, loosen the unit's RestrictAddressFamilies/SystemCallFilter." ;;
esac
echo "  local   : http://localhost:${PORT}/"
[ -n "${IP}" ] && echo "  network : http://${IP}:${PORT}/   (open from any device on your LAN)"
echo
echo "Hardening audit:  systemd-analyze security ${SERVICE_NAME}"
echo "Kiosk display:    ./deploy/kiosk-setup.sh \"http://localhost:${PORT}/?kiosk=1\""
