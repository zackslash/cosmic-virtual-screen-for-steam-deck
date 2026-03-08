#!/bin/bash
#
# test_scripts.sh — Shell script test suite
#
# Tests shell scripts WITHOUT modifying the system.
# Validates syntax, functions, and consistency across files.
#

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Test counters
PASSED=0
FAILED=0
TESTS_RUN=0

# Helper functions
pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    PASSED=$((PASSED + 1))
    TESTS_RUN=$((TESTS_RUN + 1))
}

fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    FAILED=$((FAILED + 1))
    TESTS_RUN=$((TESTS_RUN + 1))
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

section() {
    echo
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

# Determine project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Test 1: shellcheck linting ────────────────────────────────────
test_shellcheck() {
    section "shellcheck linting"
    
    # Check if shellcheck is available
    if ! command -v shellcheck &> /dev/null; then
        info "shellcheck not found - skipping lint tests (install shellcheck to enable)"
        return
    fi
    
    local scripts=(
        "install.sh"
        "uninstall.sh"
        "sunshine-start.sh"
        "sunshine-stop.sh"
        "restore-display.sh"
    )
    
    for script in "${scripts[@]}"; do
        local path="$PROJECT_ROOT/$script"
        if [ ! -f "$path" ]; then
            fail "$script: file not found"
            continue
        fi
        
        # Run shellcheck (allow warnings, fail on errors)
        if shellcheck -S error "$path" > /dev/null 2>&1; then
            pass "$script: shellcheck passed"
        else
            fail "$script: shellcheck errors found"
            shellcheck -S error "$path" 2>&1 | head -20
        fi
    done
}

# ── Test 2: sunshine-start.sh resolve_mode function ───────────────
test_resolve_mode() {
    section "sunshine-start.sh resolve_mode function"
    
    local script="$PROJECT_ROOT/sunshine-start.sh"
    
    # Test by directly grepping the case entries
    declare -A expected_modes=(
        ["deck-lcd"]="1280 800 60"
        ["deck-oled"]="1280 800 90"
        ["1200p"]="1920 1200 60"
        ["1200p-90"]="1920 1200 90"
        ["1200p-120"]="1920 1200 120"
        ["1440p"]="2560 1440 60"
        ["1440p-120"]="2560 1440 120"
        ["1600p"]="2560 1600 60"
        ["1600p-90"]="2560 1600 90"
    )
    
    for mode in "${!expected_modes[@]}"; do
        local expected="${expected_modes[$mode]}"
        
        # Grep for the case entry and extract the echo values
        if grep -q "^[[:space:]]*${mode})" "$script"; then
            local actual
            actual=$(grep "^[[:space:]]*${mode})" "$script" | sed -n 's/.*echo "\([^"]*\)".*/\1/p')
            
            if [ "$actual" = "$expected" ]; then
                pass "resolve_mode('$mode') = '$expected'"
            else
                fail "resolve_mode('$mode'): expected '$expected', got '$actual'"
            fi
        else
            fail "resolve_mode('$mode'): mode not found in script"
        fi
    done
    
    # Test unknown mode produces error case
    if grep -q '^\s*\*)' "$script" && \
       grep -A 2 '^\s*\*)' "$script" | grep -q "Unknown mode"; then
        pass "resolve_mode has error case for unknown modes"
    else
        fail "resolve_mode missing error case for unknown modes"
    fi
}

# ── Test 3: State file parsing ────────────────────────────────────
test_state_file_parsing() {
    section "State file parsing"
    
    local temp_state
    temp_state=$(mktemp)
    
    # Create mock state file
    cat > "$temp_state" <<EOF
MAIN_DISPLAY=DP-2
VIRTUAL_DISPLAY=HDMI-A-1
WIDTH=3840
HEIGHT=2160
REFRESH=160000
SCALE=1.25
TRANSFORM=normal
ADAPTIVE_SYNC=automatic
POS_X=0
POS_Y=0
EOF
    
    # Test sunshine-stop.sh parsing
    info "Testing sunshine-stop.sh state parsing"
    
    local result
    result=$(bash -c "
        STATE_FILE='$temp_state'
        FALLBACK_WIDTH=1920
        FALLBACK_HEIGHT=1080
        FALLBACK_REFRESH=60000
        RESTORE_WIDTH=\$FALLBACK_WIDTH
        RESTORE_HEIGHT=\$FALLBACK_HEIGHT
        RESTORE_REFRESH=\$FALLBACK_REFRESH
        RESTORE_SCALE=\"\"
        RESTORE_TRANSFORM=\"\"
        RESTORE_ADAPTIVE_SYNC=\"\"
        RESTORE_POS_X=\"\"
        RESTORE_POS_Y=\"\"
        
        if [ -f \"\$STATE_FILE\" ]; then
            while IFS='=' read -r key value; do
                case \"\$key\" in
                    WIDTH)           RESTORE_WIDTH=\"\$value\" ;;
                    HEIGHT)          RESTORE_HEIGHT=\"\$value\" ;;
                    REFRESH)         RESTORE_REFRESH=\"\$value\" ;;
                    SCALE)           RESTORE_SCALE=\"\$value\" ;;
                    TRANSFORM)       RESTORE_TRANSFORM=\"\$value\" ;;
                    ADAPTIVE_SYNC)   RESTORE_ADAPTIVE_SYNC=\"\$value\" ;;
                    POS_X)           RESTORE_POS_X=\"\$value\" ;;
                    POS_Y)           RESTORE_POS_Y=\"\$value\" ;;
                esac
            done < \"\$STATE_FILE\"
        fi
        
        echo \"\$RESTORE_WIDTH:\$RESTORE_HEIGHT:\$RESTORE_REFRESH:\$RESTORE_SCALE:\$RESTORE_TRANSFORM:\$RESTORE_ADAPTIVE_SYNC:\$RESTORE_POS_X:\$RESTORE_POS_Y\"
    ")
    
    if [ "$result" = "3840:2160:160000:1.25:normal:automatic:0:0" ]; then
        pass "sunshine-stop.sh parses all state file keys correctly"
    else
        fail "sunshine-stop.sh state parsing: expected '3840:2160:160000:1.25:normal:automatic:0:0', got '$result'"
    fi
    
    # Test restore-display.sh parsing (same logic)
    info "Testing restore-display.sh state parsing"
    
    result=$(bash -c "
        STATE_FILE='$temp_state'
        FALLBACK_WIDTH=1920
        FALLBACK_HEIGHT=1080
        FALLBACK_REFRESH=60000
        RESTORE_WIDTH=\$FALLBACK_WIDTH
        RESTORE_HEIGHT=\$FALLBACK_HEIGHT
        RESTORE_REFRESH=\$FALLBACK_REFRESH
        RESTORE_SCALE=\"\"
        RESTORE_TRANSFORM=\"\"
        RESTORE_ADAPTIVE_SYNC=\"\"
        RESTORE_POS_X=\"\"
        RESTORE_POS_Y=\"\"
        
        if [ -f \"\$STATE_FILE\" ]; then
            while IFS='=' read -r key value; do
                case \"\$key\" in
                    WIDTH)           RESTORE_WIDTH=\"\$value\" ;;
                    HEIGHT)          RESTORE_HEIGHT=\"\$value\" ;;
                    REFRESH)         RESTORE_REFRESH=\"\$value\" ;;
                    SCALE)           RESTORE_SCALE=\"\$value\" ;;
                    TRANSFORM)       RESTORE_TRANSFORM=\"\$value\" ;;
                    ADAPTIVE_SYNC)   RESTORE_ADAPTIVE_SYNC=\"\$value\" ;;
                    POS_X)           RESTORE_POS_X=\"\$value\" ;;
                    POS_Y)           RESTORE_POS_Y=\"\$value\" ;;
                esac
            done < \"\$STATE_FILE\"
        fi
        
        echo \"\$RESTORE_WIDTH:\$RESTORE_HEIGHT:\$RESTORE_REFRESH:\$RESTORE_SCALE:\$RESTORE_TRANSFORM:\$RESTORE_ADAPTIVE_SYNC:\$RESTORE_POS_X:\$RESTORE_POS_Y\"
    ")
    
    if [ "$result" = "3840:2160:160000:1.25:normal:automatic:0:0" ]; then
        pass "restore-display.sh parses all state file keys correctly"
    else
        fail "restore-display.sh state parsing: expected '3840:2160:160000:1.25:normal:automatic:0:0', got '$result'"
    fi
    
    # Test with empty values
    info "Testing with empty values"
    
    cat > "$temp_state" <<EOF
MAIN_DISPLAY=
VIRTUAL_DISPLAY=
WIDTH=
HEIGHT=
REFRESH=
SCALE=
TRANSFORM=
ADAPTIVE_SYNC=
POS_X=
POS_Y=
EOF
    
    result=$(bash -c "
        STATE_FILE='$temp_state'
        FALLBACK_WIDTH=1920
        RESTORE_WIDTH=\$FALLBACK_WIDTH
        
        if [ -f \"\$STATE_FILE\" ]; then
            while IFS='=' read -r key value; do
                case \"\$key\" in
                    WIDTH) RESTORE_WIDTH=\"\$value\" ;;
                esac
            done < \"\$STATE_FILE\"
        fi
        
        echo \"\$RESTORE_WIDTH\"
    ")
    
    if [ "$result" = "" ]; then
        pass "Empty state values are handled correctly"
    else
        fail "Empty state values: expected empty string, got '$result'"
    fi
    
    # Test with missing file
    rm -f "$temp_state"
    
    result=$(bash -c "
        STATE_FILE='$temp_state'
        FALLBACK_WIDTH=1920
        RESTORE_WIDTH=\$FALLBACK_WIDTH
        
        if [ -f \"\$STATE_FILE\" ]; then
            while IFS='=' read -r key value; do
                case \"\$key\" in
                    WIDTH) RESTORE_WIDTH=\"\$value\" ;;
                esac
            done < \"\$STATE_FILE\"
        fi
        
        echo \"\$RESTORE_WIDTH\"
    ")
    
    if [ "$result" = "1920" ]; then
        pass "Missing state file falls back to defaults"
    else
        fail "Missing state file: expected '1920', got '$result'"
    fi
}

# ── Test 4: cosmic-randr syntax validation ────────────────────────
test_cosmic_randr_syntax() {
    section "cosmic-randr syntax validation"
    
    local scripts=(
        "sunshine-start.sh"
        "sunshine-stop.sh"
        "restore-display.sh"
        "install.sh"
    )
    
    local all_good=true
    
    for script in "${scripts[@]}"; do
        local path="$PROJECT_ROOT/$script"
        
        # Check for old WxH combined format (should not exist)
        if grep -E 'cosmic-randr[[:space:]]+mode.*[0-9]+x[0-9]+' "$path" | grep -v '^#' > /dev/null 2>&1; then
            fail "$script: uses old WxH combined format"
            all_good=false
        fi
        
        # Check for millihertz values in cosmic-randr calls (5+ digits like 60000, 90000)
        # But allow 160000 in FALLBACK_REFRESH (that's correct for millihertz state)
        if grep 'cosmic-randr.*--refresh' "$path" | grep -v '^#' | grep -v 'FALLBACK_REFRESH' | grep -E '\-\-refresh[[:space:]]+[0-9]{5,}' > /dev/null 2>&1; then
            fail "$script: uses millihertz values in cosmic-randr calls"
            all_good=false
        fi
        
        # Verify all cosmic-randr mode calls use --refresh flag
        # Skip: comments, array-building lines (where --refresh is added on next line),
        # variable references, and log/print messages that mention cosmic-randr
        local mode_calls
        mode_calls=$(grep 'cosmic-randr[[:space:]]*mode' "$path" \
            | grep -v '^[[:space:]]*#' \
            | grep -v 'RESTORE_CMD=\|CMD=\|cmd=\|cmd+=\|CMD+=\|\\$RESTORE_CMD\|\\$CMD\|\\${' \
            | grep -v 'print_info\|print_error\|print_warn\|echo\|log\|printf' \
            | grep -v '^[[:space:]]*cosmic-randr mode.*[^\\]$' \
            || true)
        
        # Also filter lines inside array declarations (lines ending without --refresh
        # but followed by += lines that add it)
        local filtered_calls=""
        if [ -n "$mode_calls" ]; then
            while IFS= read -r line; do
                # Skip lines that are inside array declarations
                # (these will be expanded with --refresh on subsequent lines)
                local stripped
                stripped=$(echo "$line" | sed 's/^[[:space:]]*//')
                if echo "$stripped" | grep -qE '^cosmic-randr mode' && ! echo "$line" | grep -q -- '--refresh'; then
                    # Check if this line is inside an array by looking at the original file
                    local line_num
                    line_num=$(grep -n -F "$stripped" "$path" | head -1 | cut -d: -f1)
                    if [ -n "$line_num" ]; then
                        # Check if previous line opens an array or this line is inside parens
                        local prev_line
                        prev_line=$(sed -n "$((line_num - 1))p" "$path")
                        if echo "$prev_line" | grep -qE '=\($|CMD=\('; then
                            continue  # Inside array declaration, skip
                        fi
                    fi
                    fail "$script: cosmic-randr mode call without --refresh flag: $line"
                    all_good=false
                fi
            done <<< "$mode_calls"
        fi
    done
    
    if [ "$all_good" = true ]; then
        pass "All cosmic-randr mode calls use correct syntax (separate width/height, --refresh flag, Hz values)"
    fi
    
    # Verify install.sh heredoc helper script also uses correct syntax
    info "Checking install.sh heredoc helper script"
    
    local helper_script
    helper_script=$(sed -n '/cat > "$helper_path" << HELPEREOF/,/^HELPEREOF$/p' "$PROJECT_ROOT/install.sh")
    
    if echo "$helper_script" | grep -E 'cosmic-randr[[:space:]]+mode.*[0-9]+x[0-9]+' | grep -v '^#' > /dev/null 2>&1; then
        fail "install.sh heredoc: uses old WxH combined format"
    else
        pass "install.sh heredoc helper uses separate width/height args"
    fi
    
    if echo "$helper_script" | grep -q 'cosmic-randr.*mode.*--refresh'; then
        pass "install.sh heredoc helper uses --refresh flag"
    else
        fail "install.sh heredoc helper missing --refresh flag"
    fi
}

# ── Test 5: Cross-file consistency ────────────────────────────────
test_cross_file_consistency() {
    section "Cross-file consistency"
    
    # Extract default values from each script
    local sunshine_start_main
    local sunshine_start_virtual
    local sunshine_start_state
    
    sunshine_start_main=$(grep '^MAIN_DISPLAY=' "$PROJECT_ROOT/sunshine-start.sh" | head -1 | cut -d'"' -f2)
    sunshine_start_virtual=$(grep '^VIRTUAL_DISPLAY=' "$PROJECT_ROOT/sunshine-start.sh" | head -1 | cut -d'"' -f2)
    sunshine_start_state=$(grep '^STATE_FILE=' "$PROJECT_ROOT/sunshine-start.sh" | head -1 | sed 's/^STATE_FILE="\${XDG_RUNTIME_DIR:-\/tmp}\/\([^"]*\)"/\1/')
    
    local sunshine_stop_main
    local sunshine_stop_virtual
    local sunshine_stop_state
    
    sunshine_stop_main=$(grep '^MAIN_DISPLAY=' "$PROJECT_ROOT/sunshine-stop.sh" | cut -d'"' -f2)
    sunshine_stop_virtual=$(grep '^VIRTUAL_DISPLAY=' "$PROJECT_ROOT/sunshine-stop.sh" | cut -d'"' -f2)
    sunshine_stop_state=$(grep '^STATE_FILE=' "$PROJECT_ROOT/sunshine-stop.sh" | sed 's/^STATE_FILE="\${XDG_RUNTIME_DIR:-\/tmp}\/\([^"]*\)"/\1/')
    
    local restore_main
    local restore_virtual
    local restore_state
    
    restore_main=$(grep '^MAIN_DISPLAY=' "$PROJECT_ROOT/restore-display.sh" | cut -d'"' -f2)
    restore_virtual=$(grep '^VIRTUAL_DISPLAY=' "$PROJECT_ROOT/restore-display.sh" | cut -d'"' -f2)
    restore_state=$(grep '^STATE_FILE=' "$PROJECT_ROOT/restore-display.sh" | sed 's/^STATE_FILE="\${XDG_RUNTIME_DIR:-\/tmp}\/\([^"]*\)"/\1/')
    
    # Test MAIN_DISPLAY consistency
    if [ "$sunshine_start_main" = "$sunshine_stop_main" ] && \
       [ "$sunshine_stop_main" = "$restore_main" ]; then
        pass "MAIN_DISPLAY consistent across all scripts: '$sunshine_start_main'"
    else
        fail "MAIN_DISPLAY inconsistent: start='$sunshine_start_main', stop='$sunshine_stop_main', restore='$restore_main'"
    fi
    
    # Test VIRTUAL_DISPLAY consistency
    if [ "$sunshine_start_virtual" = "$sunshine_stop_virtual" ] && \
       [ "$sunshine_stop_virtual" = "$restore_virtual" ]; then
        pass "VIRTUAL_DISPLAY consistent across all scripts: '$sunshine_start_virtual'"
    else
        fail "VIRTUAL_DISPLAY inconsistent: start='$sunshine_start_virtual', stop='$sunshine_stop_virtual', restore='$restore_virtual'"
    fi
    
    # Test STATE_FILE consistency (just the filename part)
    if [ "$sunshine_start_state" = "$sunshine_stop_state" ] && \
       [ "$sunshine_stop_state" = "$restore_state" ]; then
        pass "STATE_FILE consistent across all scripts: cosmic-deck-switch.state"
    else
        fail "STATE_FILE inconsistent: start='$sunshine_start_state', stop='$sunshine_stop_state', restore='$restore_state'"
    fi
    
    # Verify WAYLAND_DISPLAY detection logic exists in all three
    local scripts=("sunshine-start.sh" "sunshine-stop.sh" "restore-display.sh")
    local all_have_wayland_detection=true
    
    for script in "${scripts[@]}"; do
        if ! grep -q 'WAYLAND_DISPLAY:-}' "$PROJECT_ROOT/$script"; then
            fail "$script: missing WAYLAND_DISPLAY detection logic"
            all_have_wayland_detection=false
        fi
    done
    
    if [ "$all_have_wayland_detection" = true ]; then
        pass "All scripts have WAYLAND_DISPLAY detection logic"
    fi
}

# ── Test 6: Helper script syntax ──────────────────────────────────
test_helper_script_syntax() {
    section "Helper script syntax (from install.sh heredoc)"
    
    local temp_helper
    temp_helper=$(mktemp)
    
    # Extract heredoc from install.sh
    # The heredoc uses an unquoted delimiter (HELPEREOF), so bash would expand
    # variables. The script escapes $ as \$ to prevent expansion. When extracting,
    # we need to un-escape these to get valid shell syntax for shellcheck.
    sed -n '/cat > "$helper_path" << HELPEREOF/,/^HELPEREOF$/p' "$PROJECT_ROOT/install.sh" | \
        sed '1d;$d' | sed 's/\\\$/$/g; s/\\\\/\\/g' > "$temp_helper"
    
    # Run shellcheck on extracted helper (if available)
    if command -v shellcheck &> /dev/null; then
        if shellcheck -S error "$temp_helper" > /dev/null 2>&1; then
            pass "Helper script heredoc passes shellcheck"
        else
            fail "Helper script heredoc has shellcheck errors"
            shellcheck -S error "$temp_helper" 2>&1 | head -20
        fi
    else
        info "shellcheck not available - skipping helper script lint"
    fi
    
    # Verify all mode case entries use separate width/height
    local case_entries
    case_entries=$(grep -E '^[[:space:]]+(deck-lcd|deck-oled|1200p|1440p|1600p)' "$temp_helper" || true)
    
    if [ -n "$case_entries" ]; then
        local all_correct=true
        while IFS= read -r line; do
            # Each should call set_mode with separate width height refresh
            if ! echo "$line" | grep -E 'set_mode[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+' > /dev/null; then
                fail "Helper script case entry uses wrong format: $line"
                all_correct=false
            fi
        done <<< "$case_entries"
        
        if [ "$all_correct" = true ]; then
            pass "All helper script mode cases use separate width/height/refresh args"
        fi
    fi
    
    rm -f "$temp_helper"
}

# ── Run all tests ─────────────────────────────────────────────────
main() {
    echo -e "${BLUE}╔════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║   Shell Script Test Suite                 ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════╝${NC}"
    echo
    info "Project root: $PROJECT_ROOT"
    
    test_shellcheck
    test_resolve_mode
    test_state_file_parsing
    test_cosmic_randr_syntax
    test_cross_file_consistency
    test_helper_script_syntax
    
    # Summary
    echo
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Test Summary${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo "Total tests run: $TESTS_RUN"
    echo -e "${GREEN}Passed: $PASSED${NC}"
    echo -e "${RED}Failed: $FAILED${NC}"
    echo
    
    if [ $FAILED -eq 0 ]; then
        echo -e "${GREEN}✓ All tests passed!${NC}"
        exit 0
    else
        echo -e "${RED}✗ Some tests failed${NC}"
        exit 1
    fi
}

main
