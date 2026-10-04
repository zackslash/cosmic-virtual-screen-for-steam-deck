#!/bin/bash
#
# sunshine-cleanup.sh — Emergency display restoration after unclean Sunshine shutdown
#
# Called by systemd ExecStopPost= after every Sunshine stop.
# Only acts if /tmp/sunshine-streaming exists (meaning undo prep-cmds didn't run).
#

SENTINEL="/tmp/sunshine-streaming"
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

if [ ! -f "$SENTINEL" ]; then
    echo "[sunshine-cleanup] Clean shutdown detected, nothing to do."
    exit 0
fi

echo "[sunshine-cleanup] Unclean shutdown detected — sentinel file exists. Running emergency cleanup."

# Run the same stop script that undo prep-cmd would have run
"$SCRIPT_DIR/sunshine-stop.sh"

# Run the other undo actions that prep-cmd would have handled
loginctl lock-session || true
setsid steam steam://close/bigpicture &

# Remove sentinel (sunshine-stop.sh doesn't do this)
rm -f "$SENTINEL"

echo "[sunshine-cleanup] Emergency cleanup complete."
