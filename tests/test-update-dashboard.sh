#!/usr/bin/env bash
# Test suite for scripts/update-dashboard.sh
# Validates that the consolidated script produces valid JSON output files
# Usage: bash tests/test-update-dashboard.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="${REPO_DIR}/scripts/update-dashboard.sh"

# Use a temp output directory so we don't clobber production
TEMP_OUT="$(mktemp -d)"
trap 'rm -rf "$TEMP_OUT"' EXIT

PASS=0
FAIL=0
SKIP=0

pass() { echo "  ✅ PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  ❌ FAIL: $1"; FAIL=$((FAIL+1)); }
skip() { echo "  ⏭  SKIP: $1"; SKIP=$((SKIP+1)); }

echo ""
echo "=== Nova Dashboard Script Tests ==="
echo "Script:     $SCRIPT"
echo "Output dir: $TEMP_OUT"
echo ""

# --- Test 1: Script exists and is executable ---
echo "[ Script sanity ]"
if [ -f "$SCRIPT" ]; then
    pass "script file exists"
else
    fail "script file not found: $SCRIPT"
    echo "Cannot continue — script missing"
    exit 1
fi

if [ -x "$SCRIPT" ]; then
    pass "script is executable"
else
    fail "script is not executable (run: chmod +x scripts/update-dashboard.sh)"
fi

# --- Test 2: Script runs without error ---
echo ""
echo "[ Execution ]"
# We override NOVA_DASHBOARD_DIR so output goes to temp dir
# We set a timeout to avoid hanging (e.g., if OpenRouter API hangs)
# The OpenRouter section will likely fail (no API key in test env) — that's OK
if NOVA_DASHBOARD_DIR="$TEMP_OUT" timeout 120 bash "$SCRIPT" > "$TEMP_OUT/run.log" 2>&1; then
    pass "script exited with code 0"
else
    EXIT_CODE=$?
    # Exit code from flock (already running) is 0 — this means a real failure
    fail "script exited with non-zero code: $EXIT_CODE"
    echo "    --- stdout/stderr ---"
    cat "$TEMP_OUT/run.log" | head -30
    echo "    --- end ---"
fi

# --- Test 3: All expected JSON files are produced ---
echo ""
echo "[ Output files ]"
EXPECTED_FILES=(system.json status.json staff.json postgres.json)
# openrouter.json may not be produced if API credentials are absent — that's tolerable
# but we still check it if it exists

for f in "${EXPECTED_FILES[@]}"; do
    if [ -f "$TEMP_OUT/$f" ]; then
        pass "$f was produced"
    else
        fail "$f was NOT produced"
    fi
done

# openrouter.json is optional in test environment (requires OPENROUTER_API_KEY)
if [ -f "$TEMP_OUT/openrouter.json" ]; then
    pass "openrouter.json was produced (bonus)"
else
    skip "openrouter.json not produced (expected in CI — requires OPENROUTER_API_KEY env var)"
fi

# --- Test 4: Each produced file is valid JSON ---
echo ""
echo "[ JSON validity ]"
for f in system.json status.json staff.json postgres.json; do
    if [ -f "$TEMP_OUT/$f" ]; then
        if jq . "$TEMP_OUT/$f" > /dev/null 2>&1; then
            pass "$f is valid JSON"
        else
            fail "$f is NOT valid JSON"
            echo "    Content: $(head -5 "$TEMP_OUT/$f")"
        fi
    else
        skip "$f validity check (file not produced)"
    fi
done

# --- Test 5: system.json schema ---
echo ""
echo "[ system.json schema ]"
SYSTEM_FILE="$TEMP_OUT/system.json"
if [ -f "$SYSTEM_FILE" ]; then
    # gateway field
    GATEWAY=$(jq -r '.gateway // empty' "$SYSTEM_FILE" 2>/dev/null)
    if [ "$GATEWAY" = "running" ] || [ "$GATEWAY" = "stopped" ]; then
        pass "system.json has 'gateway' field with value '$GATEWAY'"
    else
        fail "system.json 'gateway' field missing or invalid (got: '$GATEWAY')"
    fi

    # channels object
    CHANNELS_TYPE=$(jq -r 'if .channels then .channels | type else "missing" end' "$SYSTEM_FILE" 2>/dev/null)
    if [ "$CHANNELS_TYPE" = "object" ]; then
        pass "system.json has 'channels' object"
    else
        fail "system.json 'channels' is not an object (got type: '$CHANNELS_TYPE')"
    fi

    # updated timestamp
    UPDATED=$(jq -r '.updated // empty' "$SYSTEM_FILE" 2>/dev/null)
    if [ -n "$UPDATED" ]; then
        pass "system.json has 'updated' timestamp: $UPDATED"
    else
        fail "system.json missing 'updated' field"
    fi
else
    skip "system.json schema checks (file not produced)"
fi

# --- Test 6: All produced JSON files have updated timestamps ---
echo ""
echo "[ 'updated' timestamps ]"
for f in system.json status.json staff.json postgres.json; do
    if [ -f "$TEMP_OUT/$f" ]; then
        UPDATED=$(jq -r '.updated // empty' "$TEMP_OUT/$f" 2>/dev/null)
        if [ -n "$UPDATED" ]; then
            pass "$f has 'updated' field: $UPDATED"
        else
            fail "$f missing 'updated' field"
        fi
    else
        skip "$f updated check (file not produced)"
    fi
done

# --- Test 7: Flock prevents concurrent execution ---
echo ""
echo "[ Flock / concurrency protection ]"
LOCK_FILE="/tmp/nova-dashboard-update-$(whoami).lock"
# Acquire the lock ourselves, then verify the script exits gracefully (not with error)
(
    flock -n 9 || { skip "Could not acquire flock for test — skipping concurrency test"; exit 0; }
    # Lock is held; now run the script in background — it should exit 0 (already running, not an error)
    NOVA_DASHBOARD_DIR="$TEMP_OUT" timeout 5 bash "$SCRIPT" > "$TEMP_OUT/flock-test.log" 2>&1
    FLOCK_EXIT=$?
    # Script should exit 0 (graceful "already running" message)
    if [ "$FLOCK_EXIT" -eq 0 ]; then
        pass "concurrent execution exits gracefully (exit 0)"
    else
        fail "concurrent execution returned exit $FLOCK_EXIT (expected 0)"
    fi
) 9>"$LOCK_FILE"

# --- Summary ---
echo ""
echo "=== Test Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
echo "  SKIP: $SKIP"
echo ""

if [ "$FAIL" -gt 0 ]; then
    echo "❌ $FAIL test(s) failed"
    exit 1
else
    echo "✅ All tests passed"
    exit 0
fi
