#!/bin/bash
#
# sunshine-start-gamescope.sh — Sunshine session start script (Gamescope/HDR variant)
#
# Alternative to sunshine-start.sh that launches gamescope as a standalone
# KMS compositor, bypassing COSMIC entirely. This is the correct approach
# for HDR streaming — gamescope sets HDR_OUTPUT_METADATA directly on the
# DRM connector, which COSMIC does not currently support.
#
# How it works:
#   1. COSMIC's VT is noted, then we chvt to a free VT so logind deactivates
#      COSMIC's session and cosmic-comp drops DRM master.
#   2. Gamescope is launched via seatd-launch (SUID root), which starts a
#      private seatd instance that grants DRM master to gamescope without
#      requiring logind or an active VT.
#   3. Steam runs inside gamescope's Wayland session.
#   4. On stop, gamescope is killed and we chvt back to COSMIC's VT.
#
# Prerequisites:
#   - seatd-launch must be SUID root: sudo chmod u+s /usr/bin/seatd-launch
#   - sudo chvt must be passwordless: /etc/sudoers.d/chvt
#   - Both are configured by install.sh
#
# Usage:
#   Add to Sunshine app prep-cmd "do" field, or run manually:
#     ./sunshine-start-gamescope.sh [mode]
#
#   Modes: deck-lcd, deck-oled, deck-lcd-2x, deck-oled-2x, 1200p, 1200p-90,
#          1200p-120, 1440p, 1440p-120, 1600p, 1600p-90
#   Default: deck-oled (or DEFAULT_MODE from config)
#

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────
# Loaded from config file (written by install.sh), with fallback defaults
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/cosmic-deck-switch/config"

MAIN_DISPLAY="DP-2"
VIRTUAL_DISPLAY="HDMI-A-1"
DEFAULT_MODE="deck-oled"
HDR_ENABLED="no"

if [ -f "$CONFIG_FILE" ]; then
    while IFS='=' read -r key value; do
        case "$key" in
            MAIN_DISPLAY)    MAIN_DISPLAY="$value" ;;
            VIRTUAL_DISPLAY) VIRTUAL_DISPLAY="$value" ;;
            DEFAULT_MODE)    DEFAULT_MODE="$value" ;;
            HDR_ENABLED)     HDR_ENABLED="$value" ;;
        esac
    done < "$CONFIG_FILE"
fi

# State file for this gamescope session
STATE_FILE="${XDG_RUNTIME_DIR:-/tmp}/cosmic-deck-switch-gamescope.state"
# ───────────────────────────────────────────────────────────────────

MODE="${1:-$DEFAULT_MODE}"

log() { echo "[sunshine-start-gamescope] $*"; }

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

# ── Main ───────────────────────────────────────────────────────────

log "Starting gamescope/HDR session for Sunshine streaming"
log "Mode: $MODE | Virtual: $VIRTUAL_DISPLAY | HDR: $HDR_ENABLED"

# ── Guard: abort if a session is already active ───────────────────
if [ -f "$STATE_FILE" ]; then
    log "ERROR: A gamescope session appears to be already active (state file exists: $STATE_FILE)"
    log "Run sunshine-stop-gamescope.sh first, or remove $STATE_FILE if it is stale"
    exit 1
fi

# ── Step 1: Save current COSMIC VT ────────────────────────────────
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

# ── Step 2: Find the DRM card for the virtual display ──────────────
log "Locating DRM card for $VIRTUAL_DISPLAY..."
DRM_CARD=""
for syspath in /sys/class/drm/card*-${VIRTUAL_DISPLAY}; do
    [ -e "$syspath" ] || continue
    # Extract card name: e.g. card1-HDMI-A-1 → card1
    cardname="${syspath##*/}"       # card1-HDMI-A-1
    cardname="${cardname%%-*}"      # card1 (strip from first dash onward)
    # Verify the device node exists
    if [ -e "/dev/dri/${cardname}" ]; then
        DRM_CARD="/dev/dri/${cardname}"
        break
    fi
done

if [ -z "$DRM_CARD" ]; then
    log "ERROR: Could not find DRM card for $VIRTUAL_DISPLAY under /sys/class/drm/"
    exit 1
fi
log "Found DRM card: $DRM_CARD"

# ── Step 3: Resolve mode ──────────────────────────────────────────
read -r WIDTH HEIGHT REFRESH <<< "$(resolve_mode "$MODE")"
log "Resolved mode: ${WIDTH}x${HEIGHT}@${REFRESH}Hz"

# ── Step 4: Switch to a free VT so COSMIC releases DRM master ─────
log "Finding a free VT..."
GAMESCOPE_VT="$(find_free_vt)"
log "Switching to VT $GAMESCOPE_VT (releases COSMIC's DRM master)..."
sudo chvt "$GAMESCOPE_VT"
# Give cosmic-comp time to process the PauseDevice signal from logind
sleep 1
log "Switched to VT $GAMESCOPE_VT"

# Safety net: if anything fails from here until gamescope is confirmed running,
# chvt back to COSMIC so the user is not stranded on a blank VT.
_COSMIC_VT_NUM="${COSMIC_VT#tty}"
cleanup_vt() {
    log "ERROR: Script failed after VT switch — restoring COSMIC VT ${_COSMIC_VT_NUM}..."
    sudo chvt "$_COSMIC_VT_NUM" 2>/dev/null || true
}
trap cleanup_vt ERR

# ── Step 4b: Kill any running Steam instance ──────────────────────
# Steam's IPC mechanism causes a new `steam` invocation to hand off to an
# existing instance rather than starting fresh. Since that instance is
# attached to COSMIC's Wayland session (not gamescope's), gamescope's
# child process immediately exits with a broken pipe. Kill it first so
# gamescope spawns a genuinely new Steam in its own session.
if pgrep -x steam > /dev/null 2>&1; then
    log "Stopping existing Steam instance..."
    pkill -x steam 2>/dev/null || true
    # Wait up to 5s for Steam to exit cleanly
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

# ── Step 5: Launch gamescope via seatd-launch ─────────────────────
LOG_FILE="${XDG_RUNTIME_DIR:-/tmp}/gamescope-sunshine.log"
log "Launching gamescope via seatd-launch (output → $LOG_FILE)..."

# seatd-launch must be SUID root (installed by install.sh).
# It starts a private seatd instance as root, then drops to our real UID
# (luke) to run gamescope. This grants gamescope DRM master without
# requiring logind or an active VT binding.
#
# Use --ready-fd (-R 3) to get a reliable signal when gamescope has
# initialised KMS. We pipe fd 3 through a FIFO; read blocks until
# gamescope closes/writes to it or the 30s timeout fires.
#
# Flag reference (gamescope 3.16+):
#   -W/--output-width   output resolution width
#   -H/--output-height  output resolution height
#   -r/--nested-refresh refresh rate (fps)
#   -R/--ready-fd       readiness notification fd

PIPE_DIR="$(mktemp -d)"
mkfifo "${PIPE_DIR}/ready"
trap 'rm -rf "${PIPE_DIR:-}" 2>/dev/null' EXIT

# Build gamescope args; conditionally enable HDR
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

# ── Step 6: Wait for gamescope to be ready ────────────────────────
log "Waiting for gamescope to signal readiness (timeout 30s)..."
TIMEOUT=30
READY=false

# Read blocks until gamescope writes/closes the pipe, or the timeout fires.
# Discard the actual content; we only care that the pipe became readable.
if read -r -t "$TIMEOUT" _ < "${PIPE_DIR}/ready" 2>/dev/null; then
    READY=true
fi

rm -rf "${PIPE_DIR}"
trap - EXIT

# Abort if gamescope already died
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

# ── Step 7: Save final state ──────────────────────────────────────
cat > "$STATE_FILE" <<EOF
COSMIC_VT=$COSMIC_VT
GAMESCOPE_PID=$GAMESCOPE_PID
VIRTUAL_DISPLAY=$VIRTUAL_DISPLAY
DRM_CARD=$DRM_CARD
EOF
log "Saved gamescope session state to $STATE_FILE"

log "Gamescope/HDR streaming session started — PID $GAMESCOPE_PID on $DRM_CARD"
log "Sunshine should already be configured for wlr capture (run switch-to-hdr.sh before connecting)"
