#!/bin/bash
#
# switch-to-hdr.sh — Switch to gamescope/HDR streaming mode
#
# Launches gamescope as a standalone KMS compositor on a free VT, then
# reconfigures Sunshine to capture from it via wlr-screencopy.
#
# Run this BEFORE connecting from Moonlight. Gamescope must be running
# before Sunshine restarts (Sunshine hard-fails if WAYLAND_DISPLAY=gamescope-0
# does not exist at startup — there is no lazy retry).
#
# Usage:
#   ./switch-to-hdr.sh          — start gamescope + switch Sunshine to wlr
#   ./switch-to-hdr.sh --restore — kill gamescope + restore Sunshine to kms
#
# Flow:
#   1. chvt to a free VT (releases COSMIC's DRM master)
#   2. Launch gamescope via seatd-launch (gets DRM master, sets HDR_OUTPUT_METADATA)
#   3. Wait for gamescope to signal readiness (--ready-fd)
#   4. Write capture=wlr to sunshine.conf
#   5. Install systemd drop-in (WAYLAND_DISPLAY=gamescope-0)
#   6. Restart Sunshine (gamescope-0 now exists — Sunshine starts cleanly)
#   7. Wait for Sunshine HTTPS port
#
# The companion scripts sunshine-start-gamescope.sh / sunshine-stop-gamescope.sh
# are configured as Sunshine prep-cmds in apps.json.
# sunshine-start-gamescope.sh is now just a guard (verifies gamescope is alive).
# sunshine-stop-gamescope.sh handles session teardown on disconnect.
#

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/cosmic-deck-switch/config"

VIRTUAL_DISPLAY="HDMI-A-1"
DEFAULT_MODE="deck-oled"
HDR_ENABLED="no"

if [ -f "$CONFIG_FILE" ]; then
    while IFS='=' read -r key value; do
        case "$key" in
            VIRTUAL_DISPLAY) VIRTUAL_DISPLAY="$value" ;;
            DEFAULT_MODE)    DEFAULT_MODE="$value" ;;
            HDR_ENABLED)     HDR_ENABLED="$value" ;;
        esac
    done < "$CONFIG_FILE"
fi

# Mode: first arg (if not --restore), else DEFAULT_MODE
MODE="$DEFAULT_MODE"
if [ "${1:-}" != "--restore" ] && [ -n "${1:-}" ]; then
    MODE="$1"
fi

RESTORE=false
if [ "${1:-}" = "--restore" ]; then
    RESTORE=true
fi

log() { echo "[switch-to-hdr] $*"; }

# XDG_RUNTIME_DIR is required for the systemd drop-in path and state file.
# It is set by the login session (PAM/systemd); if missing, bail early
# rather than silently falling back to /tmp where systemd won't find the drop-in.
if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
    log "ERROR: XDG_RUNTIME_DIR is not set — cannot install systemd drop-in"
    log "       Run this script from an interactive login session, not a bare shell"
    exit 1
fi

SUNSHINE_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/sunshine/sunshine.conf"
# Backup stored beside the config so it survives reboots (crash recovery)
SUNSHINE_CONF_BACKUP="${XDG_CONFIG_HOME:-$HOME/.config}/sunshine/sunshine.conf.gamescope-backup"
# Drop-in in runtime dir so it is auto-cleaned on reboot/logout
SUNSHINE_DROPIN_DIR="${XDG_RUNTIME_DIR}/systemd/user/sunshine.service.d"
SUNSHINE_DROPIN="${SUNSHINE_DROPIN_DIR}/gamescope-wlr.conf"

# State file shared with sunshine-start/stop-gamescope.sh
STATE_FILE="${XDG_RUNTIME_DIR}/cosmic-deck-switch-gamescope.state"

# ── Helpers ────────────────────────────────────────────────────────

# Resolve mode name to WIDTH HEIGHT REFRESH
resolve_mode() {
    local mode="$1"
    case "$mode" in
        deck-lcd)     echo "1280 800 60" ;;
        deck-oled)    echo "1280 800 90" ;;
        deck-lcd-2x)  echo "2560 1600 60" ;;
        deck-oled-2x) echo "2560 1600 90" ;;
        1200p)        echo "1920 1200 60" ;;
        1200p-90)     echo "1920 1200 90" ;;
        1200p-120)    echo "1920 1200 120" ;;
        1440p)        echo "2560 1440 60" ;;
        1440p-120)    echo "2560 1440 120" ;;
        1600p)        echo "2560 1600 60" ;;
        1600p-90)     echo "2560 1600 90" ;;
        *)
            log "ERROR: Unknown mode '$mode'"
            log "Valid modes: deck-lcd, deck-oled, deck-lcd-2x, deck-oled-2x, 1200p, 1200p-90, 1200p-120, 1440p, 1440p-120, 1600p, 1600p-90"
            exit 1
            ;;
    esac
}

# Find the lowest-numbered VT with no active process on it
find_free_vt() {
    for vt in $(seq 3 12); do
        if ! fuser "/dev/tty${vt}" 2>/dev/null | grep -q '[0-9]'; then
            echo "$vt"
            return 0
        fi
    done
    log "ERROR: No free VT found in range tty3–tty12"
    return 1
}

# Wait for Sunshine to be accepting connections (polls HTTPS port 47990)
wait_for_sunshine() {
    local timeout="${1:-30}"
    local elapsed=0
    log "Waiting for Sunshine to be ready (timeout ${timeout}s)..."
    while [ "$elapsed" -lt "$timeout" ]; do
        if curl -sk --max-time 2 "https://localhost:47990" > /dev/null 2>&1; then
            log "Sunshine is ready"
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    log "WARNING: Sunshine did not respond within ${timeout}s — it may still be starting up"
    return 1
}

# ── Switch to HDR mode ────────────────────────────────────────────
switch_to_hdr() {
    log "Switching to HDR/gamescope streaming mode..."
    log "Mode: $MODE | Virtual: $VIRTUAL_DISPLAY | HDR: $HDR_ENABLED"

    # Idempotency: if state file exists and gamescope is running, we are already
    # in HDR mode. Rerunning would overwrite the backup with the wlr config.
    if [ -f "$STATE_FILE" ]; then
        EXISTING_PID=""
        while IFS='=' read -r key value; do
            [ "$key" = "GAMESCOPE_PID" ] && EXISTING_PID="$value"
        done < "$STATE_FILE"
        if [ -n "$EXISTING_PID" ] && kill -0 "$EXISTING_PID" 2>/dev/null; then
            log "Already in HDR mode (gamescope PID $EXISTING_PID is running) — nothing to do"
            log "Connect from Moonlight and launch 'Steam Big Picture (Gamescope HDR)'"
            exit 0
        else
            log "WARNING: Stale state file found (gamescope not running) — cleaning up"
            rm -f "$STATE_FILE"
        fi
    fi

    # ── Step 1: Save current COSMIC VT ────────────────────────────
    log "Saving current COSMIC VT..."
    COSMIC_VT="$(cat /sys/class/tty/tty0/active)"
    log "COSMIC is on $COSMIC_VT"

    # Write initial state (GAMESCOPE_PID filled in after launch)
    cat > "$STATE_FILE" <<EOF
COSMIC_VT=$COSMIC_VT
GAMESCOPE_PID=
VIRTUAL_DISPLAY=$VIRTUAL_DISPLAY
DRM_CARD=
EOF

    # ── Step 2: Find the DRM card for the virtual display ─────────
    log "Locating DRM card for $VIRTUAL_DISPLAY..."
    DRM_CARD=""
    for syspath in /sys/class/drm/card*-${VIRTUAL_DISPLAY}; do
        [ -e "$syspath" ] || continue
        cardname="${syspath##*/}"
        cardname="${cardname%%-*}"
        if [ -e "/dev/dri/${cardname}" ]; then
            DRM_CARD="/dev/dri/${cardname}"
            break
        fi
    done

    if [ -z "$DRM_CARD" ]; then
        log "ERROR: Could not find DRM card for $VIRTUAL_DISPLAY under /sys/class/drm/"
        rm -f "$STATE_FILE"
        exit 1
    fi
    log "Found DRM card: $DRM_CARD"

    # ── Step 3: Resolve mode ──────────────────────────────────────
    read -r WIDTH HEIGHT REFRESH <<< "$(resolve_mode "$MODE")"
    log "Resolved mode: ${WIDTH}x${HEIGHT}@${REFRESH}Hz"

    # ── Step 4: Switch to a free VT so COSMIC releases DRM master ─
    log "Finding a free VT..."
    GAMESCOPE_VT="$(find_free_vt)"
    log "Switching to VT $GAMESCOPE_VT (releases COSMIC's DRM master)..."
    sudo chvt "$GAMESCOPE_VT"
    sleep 1
    log "Switched to VT $GAMESCOPE_VT"

    # Safety net: if anything fails until gamescope is confirmed alive,
    # chvt back to COSMIC so the user is not stranded on a blank VT.
    _COSMIC_VT_NUM="${COSMIC_VT#tty}"
    cleanup_vt() {
        log "ERROR: Script failed after VT switch — restoring COSMIC VT ${_COSMIC_VT_NUM}..."
        rm -f "$STATE_FILE"
        sudo chvt "$_COSMIC_VT_NUM" 2>/dev/null || true
    }
    trap cleanup_vt ERR

    # ── Step 4b: Kill any running Steam instance ──────────────────
    if pgrep -x steam > /dev/null 2>&1; then
        log "Stopping existing Steam instance..."
        pkill -x steam 2>/dev/null || true
        for _ in $(seq 1 10); do
            pgrep -x steam > /dev/null 2>&1 || break
            sleep 0.5
        done
        if pgrep -x steam > /dev/null 2>&1; then
            log "Steam did not exit cleanly, sending SIGKILL..."
            pkill -9 -x steam 2>/dev/null || true
            sleep 1
        fi
        log "Steam stopped"
    fi

    # ── Step 5: Launch gamescope via seatd-launch ─────────────────
    LOG_FILE="${XDG_RUNTIME_DIR}/gamescope-sunshine.log"
    log "Launching gamescope via seatd-launch (output → $LOG_FILE)..."

    PIPE_DIR="$(mktemp -d)"
    mkfifo "${PIPE_DIR}/ready"
    trap 'rm -rf "${PIPE_DIR:-}" 2>/dev/null; cleanup_vt' EXIT

    GAMESCOPE_ARGS=(
        --backend drm
        --prefer-output "${VIRTUAL_DISPLAY}"
        -W "${WIDTH}" -H "${HEIGHT}"
        -r "${REFRESH}"
        --fullscreen
        -R 3
    )
    if [ "${HDR_ENABLED:-no}" = "yes" ]; then
        GAMESCOPE_ARGS+=(--hdr-enabled)
    fi

    GAMESCOPE_DRM_DEVICES="$DRM_CARD" \
    seatd-launch -- \
        gamescope \
            "${GAMESCOPE_ARGS[@]}" \
            -- steam -gamepadui -steamos3 -steampal -steamdeck \
        > "$LOG_FILE" 2>&1 \
        3>"${PIPE_DIR}/ready" &

    GAMESCOPE_PID=$!
    log "Gamescope launched with PID $GAMESCOPE_PID"

    # ── Step 6: Wait for gamescope to be ready ────────────────────
    log "Waiting for gamescope to signal readiness (timeout 30s)..."
    TIMEOUT=30
    READY=false

    if read -r -t "$TIMEOUT" _ < "${PIPE_DIR}/ready" 2>/dev/null; then
        READY=true
    fi

    rm -rf "${PIPE_DIR}"
    # Clear EXIT trap (PIPE_DIR is gone; keep ERR trap until gamescope is verified)
    trap - EXIT

    if ! kill -0 "$GAMESCOPE_PID" 2>/dev/null; then
        log "ERROR: Gamescope exited prematurely — check $LOG_FILE"
        exit 1
    fi

    # Gamescope is alive — clear the VT recovery trap
    trap - ERR

    if $READY; then
        log "Gamescope is ready"
    else
        log "WARNING: Gamescope readiness not confirmed after ${TIMEOUT}s — continuing anyway"
    fi

    # ── Step 7: Save final state ──────────────────────────────────
    cat > "$STATE_FILE" <<EOF
COSMIC_VT=$COSMIC_VT
GAMESCOPE_PID=$GAMESCOPE_PID
VIRTUAL_DISPLAY=$VIRTUAL_DISPLAY
DRM_CARD=$DRM_CARD
EOF
    log "Saved gamescope session state to $STATE_FILE"

    # ── Step 8: Reconfigure Sunshine to use wlr capture ──────────
    log "Reconfiguring Sunshine for wlr capture..."

    # Remove any stale backup from a previous crashed session
    if [ -f "$SUNSHINE_CONF_BACKUP" ]; then
        log "WARNING: Stale backup found — removing before creating fresh backup"
        rm -f "$SUNSHINE_CONF_BACKUP"
    fi

    # Back up current sunshine.conf
    if [ -f "$SUNSHINE_CONF" ]; then
        cp "$SUNSHINE_CONF" "$SUNSHINE_CONF_BACKUP"
        log "Backed up sunshine.conf → sunshine.conf.gamescope-backup"
    fi

    # Rewrite sunshine.conf: replace capture line with wlr
    {
        if [ -f "$SUNSHINE_CONF_BACKUP" ]; then
            grep -v '^capture[[:space:]]*=' "$SUNSHINE_CONF_BACKUP" || true
        fi
        echo "capture = wlr"
    } > "$SUNSHINE_CONF"
    log "sunshine.conf: capture = wlr"

    # Write systemd drop-in to inject WAYLAND_DISPLAY=gamescope-0
    mkdir -p "$SUNSHINE_DROPIN_DIR"
    cat > "$SUNSHINE_DROPIN" <<EOF
# Generated by switch-to-hdr.sh — removed by switch-to-hdr.sh --restore
[Service]
Environment=WAYLAND_DISPLAY=gamescope-0
EOF
    log "Wrote systemd drop-in: $SUNSHINE_DROPIN"

    # Restart Sunshine — gamescope-0 now exists so Sunshine starts cleanly
    log "Restarting Sunshine (gamescope is already running)..."
    systemctl --user daemon-reload
    systemctl --user restart sunshine

    # Wait for Sunshine to be accepting connections
    wait_for_sunshine 60 || true

    echo
    log "Done. Gamescope and Sunshine are running."
    log "Connect from Moonlight and launch 'Steam Big Picture (Gamescope HDR)'"
}

# ── Restore to SDR mode (kms capture) ────────────────────────────
switch_to_sdr() {
    log "Restoring to SDR/COSMIC mode..."

    # ── Tear down gamescope if running ────────────────────────────
    GAMESCOPE_PID=""
    COSMIC_VT=""
    if [ -f "$STATE_FILE" ]; then
        while IFS='=' read -r key value; do
            case "$key" in
                GAMESCOPE_PID) GAMESCOPE_PID="$value" ;;
                COSMIC_VT)     COSMIC_VT="$value" ;;
            esac
        done < "$STATE_FILE"
    fi

    if [ -n "$GAMESCOPE_PID" ] && kill -0 "$GAMESCOPE_PID" 2>/dev/null; then
        log "Sending SIGTERM to gamescope (PID $GAMESCOPE_PID)..."
        kill -TERM "$GAMESCOPE_PID" 2>/dev/null || true
        ELAPSED=0
        while [ "$ELAPSED" -lt 10 ]; do
            kill -0 "$GAMESCOPE_PID" 2>/dev/null || break
            sleep 1
            ELAPSED=$((ELAPSED + 1))
        done
        if kill -0 "$GAMESCOPE_PID" 2>/dev/null; then
            log "Gamescope still running — sending SIGKILL..."
            kill -KILL "$GAMESCOPE_PID" 2>/dev/null || true
            sleep 1
        fi
        log "Gamescope stopped"
    else
        log "Gamescope is not running (PID: ${GAMESCOPE_PID:-none})"
    fi

    # ── Switch back to COSMIC VT ──────────────────────────────────
    if [ -n "$COSMIC_VT" ]; then
        VT_NUM="${COSMIC_VT#tty}"
        log "Switching back to COSMIC VT $VT_NUM..."
        sudo chvt "$VT_NUM" || log "WARNING: chvt $VT_NUM failed"
        sleep 2
    else
        log "WARNING: No COSMIC_VT in state — skipping VT switch"
    fi

    # ── Clean up state file ───────────────────────────────────────
    rm -f "$STATE_FILE"

    # ── Restore Sunshine config ───────────────────────────────────
    if [ -f "$SUNSHINE_CONF_BACKUP" ] || [ -f "$SUNSHINE_DROPIN" ]; then
        if [ -f "$SUNSHINE_CONF_BACKUP" ]; then
            cp "$SUNSHINE_CONF_BACKUP" "$SUNSHINE_CONF"
            rm -f "$SUNSHINE_CONF_BACKUP"
            log "Restored sunshine.conf from backup"
        else
            log "WARNING: No backup found — patching capture = kms directly"
            if [ -f "$SUNSHINE_CONF" ]; then
                {
                    grep -v '^capture[[:space:]]*=' "$SUNSHINE_CONF" || true
                    echo "capture = kms"
                } > "${SUNSHINE_CONF}.tmp" && mv "${SUNSHINE_CONF}.tmp" "$SUNSHINE_CONF"
            else
                echo "capture = kms" > "$SUNSHINE_CONF"
            fi
        fi
        log "sunshine.conf: capture = kms"

        if [ -f "$SUNSHINE_DROPIN" ]; then
            rm -f "$SUNSHINE_DROPIN"
            rmdir "$SUNSHINE_DROPIN_DIR" 2>/dev/null || true
            log "Removed systemd drop-in"
        fi

        log "Restarting Sunshine with restored configuration..."
        systemctl --user daemon-reload
        systemctl --user restart sunshine
        wait_for_sunshine 60 || true
    else
        log "Sunshine config already restored (no backup or drop-in found) — skipping"
    fi

    echo
    log "Done. Sunshine is running with capture=kms (COSMIC desktop streaming)"
}

# ── Main ──────────────────────────────────────────────────────────
if $RESTORE; then
    switch_to_sdr
else
    switch_to_hdr
fi
