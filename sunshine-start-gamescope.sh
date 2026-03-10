#!/bin/bash
#
# sunshine-start-gamescope.sh — Sunshine prep-cmd "do" (Gamescope/HDR variant)
#
# Verifies that gamescope was already started by switch-to-hdr.sh before
# the Moonlight client connected. Gamescope must be running before Sunshine
# restarts — Sunshine hard-fails if WAYLAND_DISPLAY=gamescope-0 does not
# exist at startup. The actual gamescope launch lives in switch-to-hdr.sh.
#
# Usage:
#   Configured as the "do" field of a Sunshine prep-cmd in apps.json.
#   The "undo" field should point to sunshine-stop-gamescope.sh.
#
#   To start the HDR session manually:
#     ./switch-to-hdr.sh        — launches gamescope + reconfigures Sunshine
#     (connect from Moonlight, launch "Steam Big Picture (Gamescope HDR)")
#     ./switch-to-hdr.sh --restore  — tears down gamescope + restores Sunshine
#

set -euo pipefail

STATE_FILE="${XDG_RUNTIME_DIR:-/tmp}/cosmic-deck-switch-gamescope.state"

log() { echo "[sunshine-start-gamescope] $*"; }

if [ ! -f "$STATE_FILE" ]; then
    log "ERROR: No gamescope session found (state file missing: $STATE_FILE)"
    log "Run switch-to-hdr.sh before connecting from Moonlight"
    exit 1
fi

GAMESCOPE_PID=""
while IFS='=' read -r key value; do
    [ "$key" = "GAMESCOPE_PID" ] && GAMESCOPE_PID="$value"
done < "$STATE_FILE"

if [ -z "$GAMESCOPE_PID" ]; then
    log "ERROR: State file exists but GAMESCOPE_PID is empty"
    log "Run switch-to-hdr.sh to start a fresh HDR session"
    exit 1
fi

if ! kill -0 "$GAMESCOPE_PID" 2>/dev/null; then
    log "ERROR: Gamescope (PID $GAMESCOPE_PID) is not running"
    log "Run switch-to-hdr.sh to restart the HDR session"
    exit 1
fi

log "Gamescope is running (PID $GAMESCOPE_PID) — ready for HDR streaming"
