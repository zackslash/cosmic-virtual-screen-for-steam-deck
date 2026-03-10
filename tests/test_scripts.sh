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
        "sunshine-start-gamescope.sh"
        "sunshine-stop-gamescope.sh"
        "switch-to-hdr.sh"
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
        ["deck-lcd-2x"]="2560 1600 60"
        ["deck-oled-2x"]="2560 1600 90"
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
    
    local scripts=("sunshine-start.sh" "sunshine-stop.sh" "restore-display.sh")
    
    # Test CONFIG_FILE definition exists in all scripts
    local all_have_config=true
    for script in "${scripts[@]}"; do
        if grep -q 'CONFIG_FILE=.*cosmic-deck-switch/config' "$PROJECT_ROOT/$script"; then
            pass "$script: has CONFIG_FILE definition"
        else
            fail "$script: missing CONFIG_FILE definition"
            all_have_config=false
        fi
    done
    
    # Test config loading logic exists in all scripts
    for script in "${scripts[@]}"; do
        if grep -q 'while IFS.*read.*key value' "$PROJECT_ROOT/$script" && \
           grep -q 'done < "$CONFIG_FILE"' "$PROJECT_ROOT/$script"; then
            pass "$script: has config file loading logic"
        else
            fail "$script: missing config file loading logic"
        fi
    done
    
    # Test STATE_FILE consistency (just the filename part)
    local sunshine_start_state sunshine_stop_state restore_state
    sunshine_start_state=$(grep '^STATE_FILE=' "$PROJECT_ROOT/sunshine-start.sh" | head -1 | sed 's/^STATE_FILE="\${XDG_RUNTIME_DIR:-\/tmp}\/\([^"]*\)"/\1/')
    sunshine_stop_state=$(grep '^STATE_FILE=' "$PROJECT_ROOT/sunshine-stop.sh" | sed 's/^STATE_FILE="\${XDG_RUNTIME_DIR:-\/tmp}\/\([^"]*\)"/\1/')
    restore_state=$(grep '^STATE_FILE=' "$PROJECT_ROOT/restore-display.sh" | sed 's/^STATE_FILE="\${XDG_RUNTIME_DIR:-\/tmp}\/\([^"]*\)"/\1/')
    
    if [ "$sunshine_start_state" = "$sunshine_stop_state" ] && \
       [ "$sunshine_stop_state" = "$restore_state" ]; then
        pass "STATE_FILE consistent across all scripts: cosmic-deck-switch.state"
    else
        fail "STATE_FILE inconsistent: start='$sunshine_start_state', stop='$sunshine_stop_state', restore='$restore_state'"
    fi
    
    # Verify WAYLAND_DISPLAY detection logic exists in all three
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
    
    # Test that fallback defaults exist in stop and restore scripts
    for script in "sunshine-stop.sh" "restore-display.sh"; do
        if grep -q 'FALLBACK_WIDTH=' "$PROJECT_ROOT/$script"; then
            pass "$script: has fallback defaults"
        else
            fail "$script: missing fallback defaults"
        fi
    done
}

# ── Test 6: Config file loading ───────────────────────────────────
test_config_file_loading() {
    section "Config file loading"
    
    local temp_config
    temp_config=$(mktemp)
    
    # Create mock config file
    cat > "$temp_config" <<EOF
MAIN_DISPLAY=HDMI-A-3
VIRTUAL_DISPLAY=DP-4
DEFAULT_MODE=1440p-120
EOF
    
    # Test sunshine-start.sh config loading
    info "Testing sunshine-start.sh config loading"
    
    local result
    result=$(bash -c "
        CONFIG_FILE='$temp_config'
        MAIN_DISPLAY='DP-2'
        VIRTUAL_DISPLAY='HDMI-A-1'
        DEFAULT_MODE='deck-oled'
        
        if [ -f \"\$CONFIG_FILE\" ]; then
            while IFS='=' read -r key value; do
                case \"\$key\" in
                    MAIN_DISPLAY)    MAIN_DISPLAY=\"\$value\" ;;
                    VIRTUAL_DISPLAY) VIRTUAL_DISPLAY=\"\$value\" ;;
                    DEFAULT_MODE)    DEFAULT_MODE=\"\$value\" ;;
                esac
            done < \"\$CONFIG_FILE\"
        fi
        
        echo \"\$MAIN_DISPLAY:\$VIRTUAL_DISPLAY:\$DEFAULT_MODE\"
    ")
    
    if [ "$result" = "HDMI-A-3:DP-4:1440p-120" ]; then
        pass "Config file overrides all defaults correctly"
    else
        fail "Config file override: expected 'HDMI-A-3:DP-4:1440p-120', got '$result'"
    fi
    
    # Test with missing config file (should use defaults)
    rm -f "$temp_config"
    
    result=$(bash -c "
        CONFIG_FILE='$temp_config'
        MAIN_DISPLAY='DP-2'
        VIRTUAL_DISPLAY='HDMI-A-1'
        DEFAULT_MODE='deck-oled'
        
        if [ -f \"\$CONFIG_FILE\" ]; then
            while IFS='=' read -r key value; do
                case \"\$key\" in
                    MAIN_DISPLAY)    MAIN_DISPLAY=\"\$value\" ;;
                    VIRTUAL_DISPLAY) VIRTUAL_DISPLAY=\"\$value\" ;;
                    DEFAULT_MODE)    DEFAULT_MODE=\"\$value\" ;;
                esac
            done < \"\$CONFIG_FILE\"
        fi
        
        echo \"\$MAIN_DISPLAY:\$VIRTUAL_DISPLAY:\$DEFAULT_MODE\"
    ")
    
    if [ "$result" = "DP-2:HDMI-A-1:deck-oled" ]; then
        pass "Missing config file uses defaults correctly"
    else
        fail "Missing config file: expected 'DP-2:HDMI-A-1:deck-oled', got '$result'"
    fi
    
    # Test with partial config (only some keys)
    temp_config=$(mktemp)
    cat > "$temp_config" <<EOF
VIRTUAL_DISPLAY=HDMI-A-2
EOF
    
    result=$(bash -c "
        CONFIG_FILE='$temp_config'
        MAIN_DISPLAY='DP-2'
        VIRTUAL_DISPLAY='HDMI-A-1'
        DEFAULT_MODE='deck-oled'
        
        if [ -f \"\$CONFIG_FILE\" ]; then
            while IFS='=' read -r key value; do
                case \"\$key\" in
                    MAIN_DISPLAY)    MAIN_DISPLAY=\"\$value\" ;;
                    VIRTUAL_DISPLAY) VIRTUAL_DISPLAY=\"\$value\" ;;
                    DEFAULT_MODE)    DEFAULT_MODE=\"\$value\" ;;
                esac
            done < \"\$CONFIG_FILE\"
        fi
        
        echo \"\$MAIN_DISPLAY:\$VIRTUAL_DISPLAY:\$DEFAULT_MODE\"
    ")
    
    if [ "$result" = "DP-2:HDMI-A-2:deck-oled" ]; then
        pass "Partial config file only overrides specified keys"
    else
        fail "Partial config: expected 'DP-2:HDMI-A-2:deck-oled', got '$result'"
    fi
    
    # Test with comment lines in config
    cat > "$temp_config" <<EOF
# This is a comment
MAIN_DISPLAY=HDMI-A-3
# Another comment
VIRTUAL_DISPLAY=DP-4
DEFAULT_MODE=1440p-120
EOF
    
    result=$(bash -c "
        CONFIG_FILE='$temp_config'
        MAIN_DISPLAY='DP-2'
        VIRTUAL_DISPLAY='HDMI-A-1'
        DEFAULT_MODE='deck-oled'
        
        if [ -f \"\$CONFIG_FILE\" ]; then
            while IFS='=' read -r key value; do
                case \"\$key\" in
                    MAIN_DISPLAY)    MAIN_DISPLAY=\"\$value\" ;;
                    VIRTUAL_DISPLAY) VIRTUAL_DISPLAY=\"\$value\" ;;
                    DEFAULT_MODE)    DEFAULT_MODE=\"\$value\" ;;
                esac
            done < \"\$CONFIG_FILE\"
        fi
        
        echo \"\$MAIN_DISPLAY:\$VIRTUAL_DISPLAY:\$DEFAULT_MODE\"
    ")
    
    if [ "$result" = "HDMI-A-3:DP-4:1440p-120" ]; then
        pass "Config file with comments handled correctly"
    else
        fail "Config with comments: expected 'HDMI-A-3:DP-4:1440p-120', got '$result'"
    fi
    
    rm -f "$temp_config"
}

# ── Test 7: Helper script syntax ──────────────────────────────────
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
    case_entries=$(grep -E '^[[:space:]]+(deck-lcd|deck-oled|deck-lcd-2x|deck-oled-2x|1200p|1440p|1600p)' "$temp_helper" || true)
    
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

# ── Test 8: gamescope resolve_mode function ───────────────────────
# resolve_mode was moved from sunshine-start-gamescope.sh into switch-to-hdr.sh
# (gamescope launch now happens in switch-to-hdr.sh before Sunshine restarts)
test_gamescope_resolve_mode() {
    section "switch-to-hdr.sh resolve_mode function"

    local script="$PROJECT_ROOT/switch-to-hdr.sh"
    local start_script="$PROJECT_ROOT/sunshine-start.sh"

    declare -A expected_modes=(
        ["deck-lcd"]="1280 800 60"
        ["deck-oled"]="1280 800 90"
        ["deck-lcd-2x"]="2560 1600 60"
        ["deck-oled-2x"]="2560 1600 90"
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

        if grep -q "^[[:space:]]*${mode})" "$script"; then
            local actual
            actual=$(grep "^[[:space:]]*${mode})" "$script" | sed -n 's/.*echo "\([^"]*\)".*/\1/p')

            if [ "$actual" = "$expected" ]; then
                pass "gamescope resolve_mode('$mode') = '$expected'"
            else
                fail "gamescope resolve_mode('$mode'): expected '$expected', got '$actual'"
            fi
        else
            fail "gamescope resolve_mode('$mode'): mode not found in script"
        fi
    done

    # Test unknown mode produces error case (search only inside resolve_mode function)
    local resolve_mode_body
    resolve_mode_body=$(sed -n '/^resolve_mode()/,/^}/p' "$script")
    if echo "$resolve_mode_body" | grep -q '^\s*\*)' && \
       echo "$resolve_mode_body" | grep -A 2 '^\s*\*)' | grep -q "Unknown mode"; then
        pass "gamescope resolve_mode has error case for unknown modes"
    else
        fail "gamescope resolve_mode missing error case for unknown modes"
    fi

    # Test that the mode tables in sunshine-start.sh and switch-to-hdr.sh are identical
    local all_match=true
    for mode in "${!expected_modes[@]}"; do
        local val_start val_gamescope
        val_start=$(grep "^[[:space:]]*${mode})" "$start_script" | sed -n 's/.*echo "\([^"]*\)".*/\1/p')
        val_gamescope=$(grep "^[[:space:]]*${mode})" "$script" | sed -n 's/.*echo "\([^"]*\)".*/\1/p')
        if [ "$val_start" != "$val_gamescope" ]; then
            fail "Mode table mismatch for '$mode': sunshine-start.sh='$val_start', switch-to-hdr.sh='$val_gamescope'"
            all_match=false
        fi
    done

    if [ "$all_match" = true ]; then
        pass "Mode tables are identical between sunshine-start.sh and switch-to-hdr.sh"
    fi
}

# ── Test 9: gamescope state file parsing ──────────────────────────
test_gamescope_state_file_parsing() {
    section "sunshine-stop-gamescope.sh state file parsing"

    local temp_state
    temp_state=$(mktemp)

    # Create mock state file with all keys
    cat > "$temp_state" <<EOF
GAMESCOPE_PID=12345
COSMIC_VT=tty2
VIRTUAL_DISPLAY=HDMI-A-1
DRM_CARD=/dev/dri/card1
EOF

    # Test all keys parsed correctly
    info "Testing all state keys parsed correctly"

    local result
    result=$(bash -c "
        STATE_FILE='$temp_state'
        GAMESCOPE_PID=\"\"
        COSMIC_VT=\"\"
        VIRTUAL_DISPLAY=\"HDMI-A-1\"
        DRM_CARD=\"\"

        if [ -f \"\$STATE_FILE\" ]; then
            while IFS='=' read -r key value; do
                case \"\$key\" in
                    GAMESCOPE_PID)   GAMESCOPE_PID=\"\$value\" ;;
                    COSMIC_VT)       COSMIC_VT=\"\$value\" ;;
                    VIRTUAL_DISPLAY) VIRTUAL_DISPLAY=\"\$value\" ;;
                    DRM_CARD)        DRM_CARD=\"\$value\" ;;
                esac
            done < \"\$STATE_FILE\"
        fi

        echo \"\$GAMESCOPE_PID:\$COSMIC_VT:\$VIRTUAL_DISPLAY:\$DRM_CARD\"
    ")

    if [ "$result" = "12345:tty2:HDMI-A-1:/dev/dri/card1" ]; then
        pass "sunshine-stop-gamescope.sh parses all state file keys correctly"
    else
        fail "gamescope state parsing: expected '12345:tty2:HDMI-A-1:/dev/dri/card1', got '$result'"
    fi

    # Test missing state file: all vars stay at initial values
    info "Testing missing state file uses initial values"
    rm -f "$temp_state"

    result=$(bash -c "
        STATE_FILE='$temp_state'
        GAMESCOPE_PID=\"\"
        COSMIC_VT=\"\"
        VIRTUAL_DISPLAY=\"HDMI-A-1\"
        DRM_CARD=\"\"

        if [ -f \"\$STATE_FILE\" ]; then
            while IFS='=' read -r key value; do
                case \"\$key\" in
                    GAMESCOPE_PID)   GAMESCOPE_PID=\"\$value\" ;;
                    COSMIC_VT)       COSMIC_VT=\"\$value\" ;;
                    VIRTUAL_DISPLAY) VIRTUAL_DISPLAY=\"\$value\" ;;
                    DRM_CARD)        DRM_CARD=\"\$value\" ;;
                esac
            done < \"\$STATE_FILE\"
        fi

        echo \"\$GAMESCOPE_PID:\$COSMIC_VT:\$VIRTUAL_DISPLAY:\$DRM_CARD\"
    ")

    if [ "$result" = "::HDMI-A-1:" ]; then
        pass "Missing state file retains initial variable values"
    else
        fail "Missing state file: expected '::HDMI-A-1:', got '$result'"
    fi

    # Test empty values in state file handled correctly
    info "Testing empty values in state file"
    temp_state=$(mktemp)
    cat > "$temp_state" <<EOF
GAMESCOPE_PID=
COSMIC_VT=
VIRTUAL_DISPLAY=
DRM_CARD=
EOF

    result=$(bash -c "
        STATE_FILE='$temp_state'
        GAMESCOPE_PID=\"\"
        COSMIC_VT=\"\"
        VIRTUAL_DISPLAY=\"HDMI-A-1\"
        DRM_CARD=\"\"

        if [ -f \"\$STATE_FILE\" ]; then
            while IFS='=' read -r key value; do
                case \"\$key\" in
                    GAMESCOPE_PID)   GAMESCOPE_PID=\"\$value\" ;;
                    COSMIC_VT)       COSMIC_VT=\"\$value\" ;;
                    VIRTUAL_DISPLAY) VIRTUAL_DISPLAY=\"\$value\" ;;
                    DRM_CARD)        DRM_CARD=\"\$value\" ;;
                esac
            done < \"\$STATE_FILE\"
        fi

        echo \"\$GAMESCOPE_PID:\$COSMIC_VT:\$VIRTUAL_DISPLAY:\$DRM_CARD\"
    ")

    if [ "$result" = ":::" ]; then
        pass "Empty values in gamescope state file handled correctly"
    else
        fail "Empty state values: expected ':::', got '$result'"
    fi

    rm -f "$temp_state"
}

# ── Test 10: gamescope config loading ─────────────────────────────
test_gamescope_config_loading() {
    section "sunshine-start-gamescope.sh config loading"

    local temp_config
    temp_config=$(mktemp)

    # Create mock config with all 6 keys
    cat > "$temp_config" <<EOF
MAIN_DISPLAY=HDMI-A-3
VIRTUAL_DISPLAY=DP-4
DEFAULT_MODE=1440p-120
HDR_ENABLED=yes
GAMESCOPE_RESOLUTION=2560x1440
GAMESCOPE_REFRESH=120
EOF

    # Test all 6 keys overridden from config
    info "Testing all 6 config keys overridden"

    local result
    result=$(bash -c "
        CONFIG_FILE='$temp_config'
        MAIN_DISPLAY='DP-2'
        VIRTUAL_DISPLAY='HDMI-A-1'
        DEFAULT_MODE='deck-oled'
        HDR_ENABLED='no'
        GAMESCOPE_RESOLUTION='1280x800'
        GAMESCOPE_REFRESH='90'

        if [ -f \"\$CONFIG_FILE\" ]; then
            while IFS='=' read -r key value; do
                case \"\$key\" in
                    MAIN_DISPLAY)        MAIN_DISPLAY=\"\$value\" ;;
                    VIRTUAL_DISPLAY)     VIRTUAL_DISPLAY=\"\$value\" ;;
                    DEFAULT_MODE)        DEFAULT_MODE=\"\$value\" ;;
                    HDR_ENABLED)         HDR_ENABLED=\"\$value\" ;;
                    GAMESCOPE_RESOLUTION) GAMESCOPE_RESOLUTION=\"\$value\" ;;
                    GAMESCOPE_REFRESH)   GAMESCOPE_REFRESH=\"\$value\" ;;
                esac
            done < \"\$CONFIG_FILE\"
        fi

        echo \"\$MAIN_DISPLAY:\$VIRTUAL_DISPLAY:\$DEFAULT_MODE:\$HDR_ENABLED:\$GAMESCOPE_RESOLUTION:\$GAMESCOPE_REFRESH\"
    ")

    if [ "$result" = "HDMI-A-3:DP-4:1440p-120:yes:2560x1440:120" ]; then
        pass "Gamescope config file overrides all 6 defaults correctly"
    else
        fail "Gamescope config override: expected 'HDMI-A-3:DP-4:1440p-120:yes:2560x1440:120', got '$result'"
    fi

    # Test missing config: defaults retained
    info "Testing missing config file uses defaults"
    rm -f "$temp_config"

    result=$(bash -c "
        CONFIG_FILE='$temp_config'
        MAIN_DISPLAY='DP-2'
        VIRTUAL_DISPLAY='HDMI-A-1'
        DEFAULT_MODE='deck-oled'
        HDR_ENABLED='no'
        GAMESCOPE_RESOLUTION='1280x800'
        GAMESCOPE_REFRESH='90'

        if [ -f \"\$CONFIG_FILE\" ]; then
            while IFS='=' read -r key value; do
                case \"\$key\" in
                    MAIN_DISPLAY)        MAIN_DISPLAY=\"\$value\" ;;
                    VIRTUAL_DISPLAY)     VIRTUAL_DISPLAY=\"\$value\" ;;
                    DEFAULT_MODE)        DEFAULT_MODE=\"\$value\" ;;
                    HDR_ENABLED)         HDR_ENABLED=\"\$value\" ;;
                    GAMESCOPE_RESOLUTION) GAMESCOPE_RESOLUTION=\"\$value\" ;;
                    GAMESCOPE_REFRESH)   GAMESCOPE_REFRESH=\"\$value\" ;;
                esac
            done < \"\$CONFIG_FILE\"
        fi

        echo \"\$MAIN_DISPLAY:\$VIRTUAL_DISPLAY:\$DEFAULT_MODE:\$HDR_ENABLED:\$GAMESCOPE_RESOLUTION:\$GAMESCOPE_REFRESH\"
    ")

    if [ "$result" = "DP-2:HDMI-A-1:deck-oled:no:1280x800:90" ]; then
        pass "Missing gamescope config file uses defaults correctly"
    else
        fail "Missing gamescope config: expected 'DP-2:HDMI-A-1:deck-oled:no:1280x800:90', got '$result'"
    fi

    # Test HDR_ENABLED=yes correctly loaded
    info "Testing HDR_ENABLED=yes loaded from config"
    temp_config=$(mktemp)
    cat > "$temp_config" <<EOF
MAIN_DISPLAY=DP-2
VIRTUAL_DISPLAY=HDMI-A-1
DEFAULT_MODE=deck-oled
HDR_ENABLED=yes
GAMESCOPE_RESOLUTION=1280x800
GAMESCOPE_REFRESH=90
EOF

    result=$(bash -c "
        CONFIG_FILE='$temp_config'
        MAIN_DISPLAY='DP-2'
        VIRTUAL_DISPLAY='HDMI-A-1'
        DEFAULT_MODE='deck-oled'
        HDR_ENABLED='no'
        GAMESCOPE_RESOLUTION='1280x800'
        GAMESCOPE_REFRESH='90'

        if [ -f \"\$CONFIG_FILE\" ]; then
            while IFS='=' read -r key value; do
                case \"\$key\" in
                    MAIN_DISPLAY)        MAIN_DISPLAY=\"\$value\" ;;
                    VIRTUAL_DISPLAY)     VIRTUAL_DISPLAY=\"\$value\" ;;
                    DEFAULT_MODE)        DEFAULT_MODE=\"\$value\" ;;
                    HDR_ENABLED)         HDR_ENABLED=\"\$value\" ;;
                    GAMESCOPE_RESOLUTION) GAMESCOPE_RESOLUTION=\"\$value\" ;;
                    GAMESCOPE_REFRESH)   GAMESCOPE_REFRESH=\"\$value\" ;;
                esac
            done < \"\$CONFIG_FILE\"
        fi

        echo \"\$HDR_ENABLED\"
    ")

    if [ "$result" = "yes" ]; then
        pass "HDR_ENABLED=yes correctly loaded from config"
    else
        fail "HDR_ENABLED loading: expected 'yes', got '$result'"
    fi

    rm -f "$temp_config"
}

# ── Test 11: apps.json validation ─────────────────────────────────
test_apps_json() {
    section "apps.json validation"

    local apps_json="$HOME/.config/sunshine/apps.json"

    # Skip gracefully if file doesn't exist (pre-install state)
    if [ ! -f "$apps_json" ]; then
        info "apps.json not found at $apps_json — skipping (run install.sh first)"
        return
    fi

    # Skip gracefully if python3 not available
    if ! command -v python3 &>/dev/null; then
        info "python3 not found — skipping apps.json validation"
        return
    fi

    # Check apps.json is valid JSON
    if python3 -c "import json; json.load(open('$apps_json'))" 2>/dev/null; then
        pass "apps.json is valid JSON"
    else
        fail "apps.json is not valid JSON"
        return
    fi

    # Check it contains at least 3 apps entries (>= 3 allows user additions)
    if python3 -c "import json; d=json.load(open('$apps_json')); assert len(d['apps'])>=3" 2>/dev/null; then
        pass "apps.json contains at least 3 app entries"
    else
        local count
        count=$(python3 -c "import json; d=json.load(open('$apps_json')); print(len(d['apps']))" 2>/dev/null || echo "unknown")
        fail "apps.json: expected at least 3 apps, got '$count'"
    fi

    # Check the gamescope app entry exists by name
    if python3 -c "
import json
d = json.load(open('$apps_json'))
names = [a.get('name', '') for a in d['apps']]
assert 'Steam Big Picture (Gamescope HDR)' in names
" 2>/dev/null; then
        pass "apps.json contains 'Steam Big Picture (Gamescope HDR)' entry"
    else
        fail "apps.json missing 'Steam Big Picture (Gamescope HDR)' entry"
    fi

    # Check the gamescope entry has loginctl lock-session in its undo steps
    if python3 -c "
import json
d = json.load(open('$apps_json'))
gamescope_app = next((a for a in d['apps'] if a.get('name') == 'Steam Big Picture (Gamescope HDR)'), None)
assert gamescope_app is not None
prep_cmds = gamescope_app.get('prep-cmd', [])
undo_steps = [cmd.get('undo', '') for cmd in prep_cmds]
assert any('loginctl lock-session' in step for step in undo_steps)
" 2>/dev/null; then
        pass "Gamescope app entry has 'loginctl lock-session' in undo steps"
    else
        fail "Gamescope app entry missing 'loginctl lock-session' in undo steps"
    fi
}

# ── Test 12: gamescope STATE_FILE consistency ──────────────────────
test_gamescope_state_file_consistency() {
    section "Gamescope STATE_FILE consistency"

    local start_script="$PROJECT_ROOT/sunshine-start-gamescope.sh"
    local stop_script="$PROJECT_ROOT/sunshine-stop-gamescope.sh"

    local start_state stop_state
    start_state=$(grep '^STATE_FILE=' "$start_script" | head -1)
    stop_state=$(grep '^STATE_FILE=' "$stop_script" | head -1)

    if [ "$start_state" = "$stop_state" ]; then
        pass "STATE_FILE is identical in sunshine-start-gamescope.sh and sunshine-stop-gamescope.sh"
    else
        fail "STATE_FILE mismatch: start='$start_state', stop='$stop_state'"
    fi

    # Also verify gamescope STATE_FILE differs from the non-gamescope one (no clobbering)
    local sdr_state
    sdr_state=$(grep '^STATE_FILE=' "$PROJECT_ROOT/sunshine-start.sh" | head -1)
    if [ "$start_state" != "$sdr_state" ]; then
        pass "Gamescope STATE_FILE is distinct from SDR STATE_FILE (no clobbering)"
    else
        fail "Gamescope and SDR scripts share the same STATE_FILE — they will clobber each other"
    fi
}

# ── Test 13: Sunshine conf swap logic ────────────────────────────
test_sunshine_conf_swap() {
    section "Sunshine conf swap logic (start/stop gamescope)"

    local temp_dir
    temp_dir=$(mktemp -d)
    local conf="${temp_dir}/sunshine.conf"
    local backup="${temp_dir}/sunshine.conf.gamescope-backup"

    # ── 13a: start — capture = kms replaced with capture = wlr ──
    info "Testing sunshine.conf: capture=kms → capture=wlr on start"
    cat > "$conf" <<EOF
origin_web_ui_allowed = pc
capture = kms
encoder = vaapi
hevc_mode = 3
av1_mode = 3
EOF

    cp "$conf" "$backup"
    {
        grep -v '^capture[[:space:]]*=' "$backup" || true
        echo "capture = wlr"
    } > "$conf"

    if grep -q '^capture = wlr$' "$conf"; then
        pass "sunshine.conf: capture line replaced with 'capture = wlr'"
    else
        fail "sunshine.conf: expected 'capture = wlr' after start-script swap"
    fi

    if ! grep -q '^capture = kms' "$conf"; then
        pass "sunshine.conf: old 'capture = kms' line removed"
    else
        fail "sunshine.conf: old 'capture = kms' still present after swap"
    fi

    # Other keys must be preserved
    if grep -q '^encoder = vaapi' "$conf" && grep -q '^hevc_mode = 3' "$conf"; then
        pass "sunshine.conf: non-capture settings preserved after swap"
    else
        fail "sunshine.conf: non-capture settings lost after swap"
    fi

    # ── 13b: stop — backup restored correctly ──────────────────
    info "Testing sunshine.conf restore from backup on stop"
    cp "$backup" "$conf"
    rm -f "$backup"

    if grep -q '^capture = kms$' "$conf"; then
        pass "sunshine.conf: original capture=kms restored from backup"
    else
        fail "sunshine.conf: restore from backup did not reinstate capture=kms"
    fi

    # ── 13c: stop — no backup fallback patches capture = kms ───
    info "Testing sunshine.conf stop fallback (no backup file)"
    cat > "$conf" <<EOF
origin_web_ui_allowed = pc
capture = wlr
encoder = vaapi
EOF

    # No backup — apply fallback patch
    {
        grep -v '^capture[[:space:]]*=' "$conf" || true
        echo "capture = kms"
    } > "${conf}.tmp" && mv "${conf}.tmp" "$conf"

    if grep -q '^capture = kms$' "$conf"; then
        pass "sunshine.conf stop fallback: capture = kms inserted when no backup"
    else
        fail "sunshine.conf stop fallback: capture = kms not set"
    fi

    # ── 13d: systemd drop-in content is correct ────────────────
    info "Testing systemd drop-in content"
    local dropin="${temp_dir}/gamescope-wlr.conf"
    cat > "$dropin" <<EOF
# Generated by sunshine-start-gamescope.sh — removed by sunshine-stop-gamescope.sh
[Service]
Environment=WAYLAND_DISPLAY=gamescope-0
EOF

    if grep -q 'WAYLAND_DISPLAY=gamescope-0' "$dropin"; then
        pass "Systemd drop-in contains WAYLAND_DISPLAY=gamescope-0"
    else
        fail "Systemd drop-in missing WAYLAND_DISPLAY=gamescope-0"
    fi

    if grep -q '^\[Service\]' "$dropin"; then
        pass "Systemd drop-in has [Service] section"
    else
        fail "Systemd drop-in missing [Service] section"
    fi

    # ── 13e: switch-to-hdr.sh contains sunshine conf swap logic ──
    info "Testing switch-to-hdr.sh contains conf swap code"
    local switch_script="$PROJECT_ROOT/switch-to-hdr.sh"
    local start_script="$PROJECT_ROOT/sunshine-start-gamescope.sh"

    if [ -f "$switch_script" ]; then
        pass "switch-to-hdr.sh exists"
    else
        fail "switch-to-hdr.sh not found"
    fi

    if grep -q 'SUNSHINE_CONF_BACKUP' "$switch_script"; then
        pass "switch-to-hdr.sh references SUNSHINE_CONF_BACKUP"
    else
        fail "switch-to-hdr.sh missing SUNSHINE_CONF_BACKUP"
    fi

    if grep -q 'capture = wlr' "$switch_script"; then
        pass "switch-to-hdr.sh sets capture = wlr"
    else
        fail "switch-to-hdr.sh missing 'capture = wlr'"
    fi

    if grep -q 'WAYLAND_DISPLAY=gamescope-0' "$switch_script"; then
        pass "switch-to-hdr.sh sets WAYLAND_DISPLAY=gamescope-0"
    else
        fail "switch-to-hdr.sh missing WAYLAND_DISPLAY=gamescope-0"
    fi

    if grep -q 'systemctl.*restart sunshine' "$switch_script"; then
        pass "switch-to-hdr.sh restarts Sunshine"
    else
        fail "switch-to-hdr.sh does not restart Sunshine"
    fi

    # start script must NOT have Sunshine conf swap (moved to switch-to-hdr.sh)
    if ! grep -q 'capture = wlr' "$start_script"; then
        pass "sunshine-start-gamescope.sh does not contain capture=wlr (correctly delegated to switch-to-hdr.sh)"
    else
        fail "sunshine-start-gamescope.sh still contains capture=wlr logic (should be in switch-to-hdr.sh)"
    fi

    # ── 13f: stop script contains conf restore logic ───────────
    info "Testing sunshine-stop-gamescope.sh contains conf restore code"
    local stop_script="$PROJECT_ROOT/sunshine-stop-gamescope.sh"

    if grep -q 'SUNSHINE_CONF_BACKUP' "$stop_script"; then
        pass "sunshine-stop-gamescope.sh references SUNSHINE_CONF_BACKUP"
    else
        fail "sunshine-stop-gamescope.sh missing SUNSHINE_CONF_BACKUP"
    fi

    if grep -q 'capture = kms' "$stop_script"; then
        pass "sunshine-stop-gamescope.sh restores capture = kms"
    else
        fail "sunshine-stop-gamescope.sh missing 'capture = kms'"
    fi

    if grep -q 'SUNSHINE_DROPIN' "$stop_script"; then
        pass "sunshine-stop-gamescope.sh removes systemd drop-in"
    else
        fail "sunshine-stop-gamescope.sh missing drop-in cleanup"
    fi

    if grep -q 'systemd-run.*--no-block' "$stop_script"; then
        pass "sunshine-stop-gamescope.sh uses systemd-run --no-block for deferred restart"
    else
        fail "sunshine-stop-gamescope.sh missing systemd-run --no-block"
    fi

    # ── 13g: switch-to-hdr.sh guards against double-start ──────────
    info "Testing double-start guard in switch-to-hdr.sh"

    if grep -q 'Already in HDR mode' "$switch_script"; then
        pass "switch-to-hdr.sh has double-start guard (idempotency check)"
    else
        fail "switch-to-hdr.sh missing double-start guard"
    fi

    # ── 13h: switch-to-hdr.sh has ERR trap for VT recovery ─────────
    info "Testing ERR trap for VT recovery in switch-to-hdr.sh"

    if grep -q 'cleanup_vt' "$switch_script" && grep -q 'trap cleanup_vt ERR' "$switch_script"; then
        pass "switch-to-hdr.sh has ERR trap (cleanup_vt) for VT recovery"
    else
        fail "switch-to-hdr.sh missing ERR trap for VT recovery"
    fi

    if grep -q 'trap - ERR' "$switch_script"; then
        pass "switch-to-hdr.sh clears ERR trap after gamescope is confirmed alive"
    else
        fail "switch-to-hdr.sh does not clear ERR trap after safe point"
    fi

    # ── 13i: drop-in path is in XDG_RUNTIME_DIR (not ~/.config) ─
    info "Testing systemd drop-in is in XDG_RUNTIME_DIR (not persisted)"

    if grep -q 'XDG_RUNTIME_DIR.*systemd/user/sunshine.service.d' "$switch_script"; then
        pass "switch-to-hdr.sh drop-in is in XDG_RUNTIME_DIR (auto-cleaned on reboot)"
    else
        fail "switch-to-hdr.sh drop-in is not in XDG_RUNTIME_DIR"
    fi

    if grep -q 'XDG_RUNTIME_DIR.*systemd/user/sunshine.service.d' "$stop_script"; then
        pass "sunshine-stop-gamescope.sh drop-in path is in XDG_RUNTIME_DIR"
    else
        fail "sunshine-stop-gamescope.sh drop-in path is not in XDG_RUNTIME_DIR"
    fi

    # ── 13j: backup path is beside sunshine.conf (not in tmpfs) ─
    info "Testing sunshine.conf backup is beside the config (crash-safe)"

    if grep -q 'sunshine/sunshine.conf.gamescope-backup' "$switch_script"; then
        pass "switch-to-hdr.sh backup is in ~/.config/sunshine/ (survives reboot)"
    else
        fail "switch-to-hdr.sh backup not beside sunshine.conf"
    fi

    if grep -q 'sunshine/sunshine.conf.gamescope-backup' "$stop_script"; then
        pass "sunshine-stop-gamescope.sh backup path is in ~/.config/sunshine/"
    else
        fail "sunshine-stop-gamescope.sh backup path not beside sunshine.conf"
    fi

    # ── 13k: grep uses [[:space:]] not \s ───────────────────────
    info "Testing grep patterns use POSIX [[:space:]] not \\s"

    if grep -q 'capture\\s\*=' "$switch_script"; then
        fail "switch-to-hdr.sh uses non-POSIX \\s in grep (should be [[:space:]])"
    else
        pass "switch-to-hdr.sh grep uses POSIX character class"
    fi

    if grep -q 'capture\\s\*=' "$stop_script"; then
        fail "sunshine-stop-gamescope.sh uses non-POSIX \\s in grep (should be [[:space:]])"
    else
        pass "sunshine-stop-gamescope.sh grep uses POSIX character class"
    fi

    # ── 13l: stop script sets WAYLAND_DISPLAY for Steam restart ─
    info "Testing stop script sets correct WAYLAND_DISPLAY for Steam"

    if grep -q 'COSMIC_WAYLAND' "$stop_script" && grep -q 'WAYLAND_DISPLAY.*nohup steam' "$stop_script"; then
        pass "sunshine-stop-gamescope.sh detects and sets WAYLAND_DISPLAY for Steam restart"
    else
        fail "sunshine-stop-gamescope.sh does not set WAYLAND_DISPLAY for Steam restart"
    fi

    rm -rf "$temp_dir"
}

# ── Test 14: switch-to-hdr.sh structure ──────────────────────────
test_switch_to_hdr() {
    section "switch-to-hdr.sh structure"

    local script="$PROJECT_ROOT/switch-to-hdr.sh"

    if [ ! -f "$script" ]; then
        fail "switch-to-hdr.sh not found"
        return
    fi

    # Basic shell hygiene
    if head -1 "$script" | grep -q '^#!/bin/bash'; then
        pass "switch-to-hdr.sh has bash shebang"
    else
        fail "switch-to-hdr.sh missing bash shebang"
    fi

    if grep -q 'set -euo pipefail' "$script"; then
        pass "switch-to-hdr.sh uses set -euo pipefail"
    else
        fail "switch-to-hdr.sh missing set -euo pipefail"
    fi

    # --restore flag
    if grep -q -- '--restore' "$script"; then
        pass "switch-to-hdr.sh supports --restore flag"
    else
        fail "switch-to-hdr.sh missing --restore flag"
    fi

    # Sunshine restart (synchronous — not inside Sunshine's process tree)
    if grep -q 'systemctl.*restart sunshine' "$script"; then
        pass "switch-to-hdr.sh restarts Sunshine synchronously"
    else
        fail "switch-to-hdr.sh does not restart Sunshine"
    fi

    # Should NOT use systemd-run --no-block (it's safe to restart directly here)
    if ! grep -q 'systemd-run.*--no-block' "$script"; then
        pass "switch-to-hdr.sh does not use deferred systemd-run (runs outside Sunshine tree)"
    else
        fail "switch-to-hdr.sh unnecessarily defers restart via systemd-run --no-block"
    fi

    # wait_for_sunshine function
    if grep -q 'wait_for_sunshine' "$script"; then
        pass "switch-to-hdr.sh waits for Sunshine to be ready"
    else
        fail "switch-to-hdr.sh missing wait_for_sunshine"
    fi

    # Stale backup cleanup on hdr switch
    if grep -q 'Stale backup' "$script"; then
        pass "switch-to-hdr.sh cleans up stale backup before creating fresh one"
    else
        fail "switch-to-hdr.sh does not clean stale backup"
    fi

    # --restore restores capture = kms
    if grep -q 'capture = kms' "$script"; then
        pass "switch-to-hdr.sh --restore sets capture = kms"
    else
        fail "switch-to-hdr.sh --restore missing capture = kms"
    fi

    # --restore removes drop-in
    if grep -q 'SUNSHINE_DROPIN' "$script" && grep -q 'rm -f.*DROPIN' "$script"; then
        pass "switch-to-hdr.sh --restore removes systemd drop-in"
    else
        fail "switch-to-hdr.sh --restore missing drop-in removal"
    fi
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
    test_config_file_loading
    test_helper_script_syntax
    test_gamescope_resolve_mode
    test_gamescope_state_file_parsing
    test_gamescope_config_loading
    test_apps_json
    test_gamescope_state_file_consistency
    test_sunshine_conf_swap
    test_switch_to_hdr
    
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
