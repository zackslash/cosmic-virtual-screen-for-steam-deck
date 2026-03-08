#!/bin/bash
#
# run-tests.sh — Docker test runner
#
# Builds and runs the test container for cosmic-virtual-screen-for-steam-deck
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Building test container..."
docker build -f "$SCRIPT_DIR/Dockerfile.test" -t cosmic-vscreen-tests "$SCRIPT_DIR"

echo
echo "Running tests..."
docker run --rm cosmic-vscreen-tests
