#!/usr/bin/env bash
#
# Turn a Raspberry Pi into a full-screen Florence kiosk: Chromium launches on
# boot, fullscreen, pointed at the tracker, and respawns if it ever dies.
#
# Run this as the DESKTOP user (the one that auto-logs-in) — NOT with sudo —
# because it writes into that user's ~/.config. It will use sudo only for the
# apt install and the raspi-config tweaks, prompting as needed.
#
# Usage:
#   ./deploy/kiosk-setup.sh                         # kiosk → http://localhost:8080/?kiosk=1
#   ./deploy/kiosk-setup.sh http://localhost:8080/  # custom URL
#   ./deploy/kiosk-setup.sh --x11 <url>             # force the legacy X11/LXDE method
#
set -euo pipefail

URL_DEFAULT="http://localhost:8080/?kiosk=1"
FORCE=""
URL=""
for arg in "$@"; do
  case "$arg" in
    --x11)     FORCE="x11" ;;
    --wayland) FORCE="wayland" ;;
    http*)     URL="$arg" ;;
    *) echo "ignoring unknown arg: $arg" >&2 ;;
  esac
done
URL="${URL:-$URL_DEFAULT}"

say()  { printf '\033[1;33m▸ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;31m! %s\033[0m\n' "$*"; }

[ "$(id -u)" -ne 0 ] || { warn "Run this as your normal desktop user, not root/sudo."; exit 1; }

# --- which browser binary does this image actually have? ----------------------
BROWSER=""
for cand in chromium chromium-browser; do
  if command -v "$cand" >/dev/null 2>&1; then BROWSER="$cand"; break; fi
done
if [ -z "$BROWSER" ]; then
  warn "Chromium not found. Install it with:  sudo apt install -y chromium"
  BROWSER="chromium"  # write the config anyway; user can install after
fi

# --- detect the session: Wayland/labwc (current Pi OS) vs X11/LXDE (legacy) ---
SESSION="$FORCE"
if [ -z "$SESSION" ]; then
  if [ "${XDG_SESSION_TYPE:-}" = "wayland" ] || [ -n "${WAYLAND_DISPLAY:-}" ] \
     || pgrep -x labwc >/dev/null 2>&1 || [ -d "$HOME/.config/labwc" ]; then
    SESSION="wayland"
  elif [ "${XDG_SESSION_TYPE:-}" = "x11" ] || [ -d "$HOME/.config/lxsession" ]; then
    SESSION="x11"
  else
    # Bookworm desktop defaults to Wayland/labwc, so assume that when unsure.
    SESSION="wayland"
    warn "Could not detect the session type; assuming Wayland/labwc (current Pi OS default)."
    warn "If the kiosk doesn't start after reboot, re-run with --x11."
  fi
fi
say "Session: ${SESSION}   Browser: ${BROWSER}"
say "Kiosk URL: ${URL}"

# Common flags, then per-session extras. --kiosk already fullscreens, so
# --start-maximized is only a meaningful (X11-only) hint on X11; on Wayland we
# instead ask Chromium to render natively rather than through XWayland.
COMMON_FLAGS="--kiosk --incognito --noerrdialogs --disable-infobars --no-first-run \
--disable-session-crashed-bubble --disable-features=Translate \
--check-for-update-interval=31536000 --enable-features=OverlayScrollbar"
WAYLAND_FLAGS="${COMMON_FLAGS} --ozone-platform=wayland"
X11_FLAGS="${COMMON_FLAGS} --start-maximized"

backup() { [ -f "$1" ] && cp -f "$1" "$1.florence.bak.$$" && say "backed up $1 → $1.florence.bak.$$"; }

if [ "$SESSION" = "wayland" ]; then
  # ---- Wayland / labwc (Raspberry Pi OS Bookworm default) --------------------
  AUTOSTART="$HOME/.config/labwc/autostart"
  mkdir -p "$HOME/.config/labwc"
  backup "$AUTOSTART"
  # /usr/bin/lwrespawn re-launches Chromium if it crashes (labwc ignores the
  # old openbox '@' respawn prefix). RESPAWN falls back to a plain '&' if the
  # helper isn't on this image.
  RESPAWN="/usr/bin/lwrespawn"
  [ -x "$RESPAWN" ] || RESPAWN=""
  cat > "$AUTOSTART" <<EOF
# --- Florence kiosk (managed by florence-tracker/deploy/kiosk-setup.sh) ---
${RESPAWN} ${BROWSER} ${WAYLAND_FLAGS} "${URL}" &
EOF
  say "Wrote ${AUTOSTART}"
  [ -z "$RESPAWN" ] && warn "lwrespawn not found; Chromium will start but won't auto-respawn on crash."
  say "Cursor is hidden by the app itself when the URL includes ?kiosk=1 (the default)."
  warn "Under Wayland, screen blanking is governed by raspi-config (set below), not xset."
else
  # ---- legacy X11 / LXDE -----------------------------------------------------
  AUTOSTART="$HOME/.config/lxsession/LXDE-pi/autostart"
  mkdir -p "$HOME/.config/lxsession/LXDE-pi"
  backup "$AUTOSTART"
  # @-prefixed lines auto-respawn under openbox/LXDE; xset/unclutter are X11-only.
  cat > "$AUTOSTART" <<EOF
@xset s off
@xset -dpms
@xset s noblank
@unclutter -idle 0
@${BROWSER} ${X11_FLAGS} ${URL}
EOF
  say "Wrote ${AUTOSTART}"
  command -v unclutter >/dev/null 2>&1 || warn "Install 'unclutter' to hide the cursor:  sudo apt install -y unclutter"
fi

# --- system tweaks every kiosk needs (auto-login + no screen blanking) -------
say "Configuring auto-login to desktop + disabling screen blanking (needs sudo)…"
if command -v raspi-config >/dev/null 2>&1; then
  sudo raspi-config nonint do_boot_behaviour B4 2>/dev/null && say "enabled desktop auto-login" \
    || warn "could not set auto-login automatically — do it via: sudo raspi-config → System Options → Boot/Auto Login → Desktop Autologin"
  sudo raspi-config nonint do_blanking 1 2>/dev/null && say "disabled screen blanking" \
    || warn "could not disable blanking automatically — do it via: sudo raspi-config → Display Options → Screen Blanking → No"
else
  warn "raspi-config not present (not a Pi?). Set the display to auto-login and disable screen blanking manually."
fi

printf '\n\033[1;32m✓ Kiosk configured.\033[0m  Reboot to launch full-screen:  sudo reboot\n'
echo "  Make sure the server is running first:  sudo ./deploy/install.sh   (or  docker compose up -d)"
echo "  To undo:"
echo "    • delete ${AUTOSTART}  (a .florence.bak.* backup is alongside it)"
echo "    • re-enable login prompt + blanking:  sudo raspi-config nonint do_boot_behaviour B3; sudo raspi-config nonint do_blanking 0"
