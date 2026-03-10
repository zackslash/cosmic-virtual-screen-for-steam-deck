#!/bin/bash
#
# sunshine-stop-gamescope.sh — Sunshine session end script (Gamescope/HDR variant)
#
# Tears down the gamescope standalone KMS session that was started by
# sunshine-start-gamescope.sh, kills Steam (which runs inside gamescope),
# and switches back to the COSMIC VT so the desktop regains DRM master.
#
# Usage:
#   Add to Sunshine app prep-cmd "undo" field, or run manually:
#     ./sunshine-stop-gamescope.sh
#

set -euo pipefail

# State file written by sunshine-start-gamescope.sh
STATE_FILE="${XDG_RUNTIME_DIR:-/tmp}/cosmic-deck-switch-gamescope.state"

log() { echo "[sunshine-stop-gamescope] $*"; }

# ── Load saved state ──────────────────────────────────────────────

GAMESCOPE_PID=""
COSMIC_VT=""
VIRTUAL_DISPLAY="HDMI-A-1"
DRM_CARD=""

if [ -f "$STATE_FILE" ]; then
    while IFS='=' read -r key value; do
        case "$key" in
            GAMESCOPE_PID)   GAMESCOPE_PID="$value" ;;
            COSMIC_VT)       COSMIC_VT="$value" ;;
            VIRTUAL_DISPLAY) VIRTUAL_DISPLAY="$value" ;;
            DRM_CARD)        DRM_CARD="$value" ;;
        esac
    done < "$STATE_FILE"
    log "Loaded gamescope session state from $STATE_FILE"
else
    log "WARNING: No state file found at $STATE_FILE — cannot determine gamescope PID or COSMIC VT"
fi

# ── Main ───────────────────────────────────────────────────────────

log "Stopping gamescope/HDR streaming session"

# ── Step 1: Kill Steam children first, then gamescope ─────────────
if [ -n "$GAMESCOPE_PID" ] && kill -0 "$GAMESCOPE_PID" 2>/dev/null; then
    log "Sending SIGTERM to Steam children of gamescope (PID $GAMESCOPE_PID)..."
    pkill -TERM -P "$GAMESCOPE_PID" steam 2>/dev/null || true
    sleep 1

    log "Sending SIGTERM to gamescope (PID $GAMESCOPE_PID)..."
    kill -TERM "$GAMESCOPE_PID" 2>/dev/null || true

    # Wait up to 10s for graceful exit
    ELAPSED=0
    while [ "$ELAPSED" -lt 10 ]; do
        if ! kill -0 "$GAMESCOPE_PID" 2>/dev/null; then
            log "Gamescope exited cleanly after ${ELAPSED}s"
            break
        fi
        sleep 1
        ELAPSED=$((ELAPSED + 1))
    done

    # Force kill if still running
    if kill -0 "$GAMESCOPE_PID" 2>/dev/null; then
        log "Gamescope still running after 10s — sending SIGKILL..."
        kill -KILL "$GAMESCOPE_PID" 2>/dev/null || true
        sleep 1
    fi
else
    if [ -n "$GAMESCOPE_PID" ]; then
        log "Gamescope PID $GAMESCOPE_PID is not running (already exited)"
    else
        log "WARNING: No GAMESCOPE_PID in state — skipping process teardown"
    fi
fi

# ── Step 2: Switch back to COSMIC VT ──────────────────────────────
if [ -n "$COSMIC_VT" ]; then
    # Strip leading "tty" prefix to get the VT number (e.g. "tty2" → "2")
    VT_NUM="${COSMIC_VT#tty}"
    log "Switching back to COSMIC VT $VT_NUM (was $COSMIC_VT)..."
    sudo chvt "$VT_NUM" || log "WARNING: chvt $VT_NUM failed — COSMIC may need manual VT switch"
else
    log "WARNING: No COSMIC_VT in state — skipping VT switch"
fi

# ── Step 3: Wait for COSMIC to regain DRM master ──────────────────
log "Waiting 2s for COSMIC to regain DRM master..."
sleep 2

# ── Step 4: Clean up state file (keep log for debugging) ──────────
rm -f "$STATE_FILE"
log "Removed state file $STATE_FILE"
log "Gamescope session log preserved at ${XDG_RUNTIME_DIR:-/tmp}/gamescope-sunshine.log"

# ── Step 5: Restart Steam in COSMIC's session ─────────────────────
# We killed Steam in the start script to prevent IPC hand-off to the
# existing instance. Restart it now so the desktop is back to normal.
# Explicitly set WAYLAND_DISPLAY to COSMIC's socket — the current process
# environment may still carry gamescope-0 from the Sunshine drop-in.
if command -v steam > /dev/null 2>&1; then
    if ! pgrep -x steam > /dev/null 2>&1; then
        log "Restarting Steam in COSMIC session..."
        # Detect COSMIC's Wayland socket
        COSMIC_WAYLAND=""
        for sock in wayland-1 wayland-0; do
            if [ -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/$sock" ]; then
                COSMIC_WAYLAND="$sock"
                break
            fi
        done
        if [ -n "$COSMIC_WAYLAND" ]; then
            WAYLAND_DISPLAY="$COSMIC_WAYLAND" nohup steam > /dev/null 2>&1 &
            disown
            log "Steam restart launched (WAYLAND_DISPLAY=$COSMIC_WAYLAND)"
        else
            log "WARNING: Cannot detect COSMIC Wayland socket — Steam may not connect to desktop"
            nohup steam > /dev/null 2>&1 &
            disown
            log "Steam restart launched (no WAYLAND_DISPLAY set)"
        fi
    else
        log "Steam is already running — skipping restart"
    fi
fi

log "Gamescope/HDR session stopped — COSMIC restored"

# ── Step 6: Restore Sunshine to kms capture ───────────────────────
# Undo the sunshine.conf swap and systemd drop-in written by switch-to-hdr.sh,
# then restart Sunshine so it recaptures from COSMIC via KMS.
#
# This undo script runs while Sunshine is still alive (it runs this script
# as part of session teardown). We cannot call 'systemctl restart sunshine'
# directly — that would kill Sunshine and terminate this script too.
# Use 'systemd-run --no-block' to schedule the restart as an independent
# transient unit that fires after this script and Sunshine finish teardown.
# The client is already disconnected at this point, so no 503 risk.

SUNSHINE_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/sunshine/sunshine.conf"
# Backup is stored beside the config (persists across reboots for crash recovery)
SUNSHINE_CONF_BACKUP="${XDG_CONFIG_HOME:-$HOME/.config}/sunshine/sunshine.conf.gamescope-backup"
# Drop-in is in the runtime dir (auto-cleaned on reboot/logout)
SUNSHINE_DROPIN_DIR="${XDG_RUNTIME_DIR:-/tmp}/systemd/user/sunshine.service.d"
SUNSHINE_DROPIN="${SUNSHINE_DROPIN_DIR}/gamescope-wlr.conf"

log "Restoring Sunshine configuration..."

# Only restore if there is something to restore — guard against being run twice.
if [ -f "$SUNSHINE_CONF_BACKUP" ] || [ -f "$SUNSHINE_DROPIN" ]; then

# Restore original sunshine.conf from backup
if [ -f "$SUNSHINE_CONF_BACKUP" ]; then
    cp "$SUNSHINE_CONF_BACKUP" "$SUNSHINE_CONF"
    rm -f "$SUNSHINE_CONF_BACKUP"
    log "Restored sunshine.conf from backup"
else
    # No backup: just ensure capture = kms is set
    log "WARNING: No sunshine.conf backup found — patching capture = kms directly"
    if [ -f "$SUNSHINE_CONF" ]; then
        {
            grep -v '^capture[[:space:]]*=' "$SUNSHINE_CONF" || true
            echo "capture = kms"
        } > "${SUNSHINE_CONF}.tmp" && mv "${SUNSHINE_CONF}.tmp" "$SUNSHINE_CONF"
    else
        echo "capture = kms" > "$SUNSHINE_CONF"
    fi
fi

# Remove systemd drop-in (WAYLAND_DISPLAY=gamescope-0 must not persist)
if [ -f "$SUNSHINE_DROPIN" ]; then
    rm -f "$SUNSHINE_DROPIN"
    log "Removed systemd drop-in: $SUNSHINE_DROPIN"
    # Clean up empty drop-in dir if nothing else is in it
    rmdir "$SUNSHINE_DROPIN_DIR" 2>/dev/null || true
fi

# Defer Sunshine restart until after this script (and Sunshine's teardown) completes.
# Client is already disconnected so there is no 503 risk.
log "Scheduling Sunshine restart (fires after session teardown completes)..."
systemd-run --user --no-block --on-active=2 \
    -- sh -c 'systemctl --user daemon-reload && systemctl --user restart sunshine' \
    || {
    log "WARNING: systemd-run not available; falling back to nohup restart"
    nohup sh -c 'sleep 2; systemctl --user daemon-reload; systemctl --user restart sunshine' \
        > /dev/null 2>&1 &
    disown
}

log "Sunshine will restart in ~2s with capture=kms (COSMIC KMS capture restored)"

else
    log "Sunshine config already restored (no backup or drop-in found) — skipping"
fi
