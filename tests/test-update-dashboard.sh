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
FAKE_NODE_DIR=""
trap 'rm -rf "$TEMP_OUT" "$FAKE_NODE_DIR"' EXIT

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
# We set a timeout to avoid hanging (e.g., if anthropic API hangs)
# The anthropic section will likely fail (no API key in test env) — that's OK
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
# anthropic.json may not be produced if API credentials are absent — that's tolerable
# but we still check it if it exists

for f in "${EXPECTED_FILES[@]}"; do
    if [ -f "$TEMP_OUT/$f" ]; then
        pass "$f was produced"
    else
        fail "$f was NOT produced"
    fi
done

# anthropic.json is optional in test environment (requires 1Password + API key)
if [ -f "$TEMP_OUT/anthropic.json" ]; then
    pass "anthropic.json was produced (bonus)"
else
    skip "anthropic.json not produced (expected in CI — requires 1Password + Admin API key)"
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

    # healthState + healthError (#37 / #39)
    HEALTH_STATE=$(jq -r '.healthState // empty' "$SYSTEM_FILE" 2>/dev/null)
    if [ "$HEALTH_STATE" = "ok" ] || [ "$HEALTH_STATE" = "unknown" ]; then
        pass "system.json has 'healthState' field with value '$HEALTH_STATE'"
    else
        fail "system.json 'healthState' missing or invalid (got: '$HEALTH_STATE')"
    fi

    # channels object (real measurement) or null (query failed)
    CHANNELS_TYPE=$(jq -r 'if .channels == null then "null" else (.channels | type) end' "$SYSTEM_FILE" 2>/dev/null)
    if [ "$CHANNELS_TYPE" = "object" ] && [ "$HEALTH_STATE" = "ok" ]; then
        pass "system.json has 'channels' object when healthState is ok"
    elif [ "$CHANNELS_TYPE" = "null" ] && [ "$HEALTH_STATE" = "unknown" ]; then
        pass "system.json has 'channels' null when healthState is unknown"
    else
        fail "system.json 'channels' type '$CHANNELS_TYPE' inconsistent with healthState '$HEALTH_STATE'"
    fi

    # healthError present when state is unknown, null when ok
    HEALTH_ERROR=$(jq -r '.healthError // empty' "$SYSTEM_FILE" 2>/dev/null)
    if [ "$HEALTH_STATE" = "ok" ] && [ -z "$HEALTH_ERROR" ]; then
        pass "system.json healthError is null/empty when healthState is ok"
    elif [ "$HEALTH_STATE" = "unknown" ] && [ -n "$HEALTH_ERROR" ]; then
        pass "system.json healthError is populated when healthState is unknown: $HEALTH_ERROR"
    else
        fail "system.json healthError '$HEALTH_ERROR' inconsistent with healthState '$HEALTH_STATE'"
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

# --- Test 8: PATH ordering does not let unsupported node blank openclaw health ---
echo ""
echo "[ PATH ordering / node guard ]"
FAKE_NODE_DIR="$(mktemp -d)"

cat > "$FAKE_NODE_DIR/node" <<'EOF'
#!/usr/bin/env bash
# Fake unsupported node (matches linuxbrew v25.5.0 that OpenClaw rejects)
echo "v25.5.0"
EOF
chmod +x "$FAKE_NODE_DIR/node"

# Verify the fake node reports the unsupported version
if [ "$("$FAKE_NODE_DIR/node" --version)" = "v25.5.0" ]; then
    pass "fake unsupported node created"
else
    fail "fake unsupported node not created correctly"
fi

# Find a real supported node on this host (system paths are safe because we
# reorder PATH in the script, but we need one to exist for the guard to succeed).
REAL_NODE=""
for candidate in /usr/bin/node /usr/local/bin/node /opt/node/bin/node; do
    if [ -x "$candidate" ]; then
        v=$("$candidate" --version 2>/dev/null | sed 's/^v//')
        if printf '%s\n%s\n' "22.22.3" "$v" | sort -V -C; then
            REAL_NODE="$candidate"
            break
        fi
    fi
done

if [ -n "$REAL_NODE" ]; then
    NODE_TEST_OUT="$(mktemp -d)"
    # Put the fake node first in PATH, as linuxbrew would be. The script should
    # still produce a valid system.json because it resolves the supported node
    # explicitly rather than trusting PATH order.
    PATH="$FAKE_NODE_DIR:/usr/bin:/bin:/usr/local/bin:/home/nova/.npm-global/bin" \
        NOVA_DASHBOARD_DIR="$NODE_TEST_OUT" \
        timeout 60 bash "$SCRIPT" --sections=system > "$NODE_TEST_OUT/run.log" 2>&1
    SCRIPT_EXIT=$?

    if [ "$SCRIPT_EXIT" -eq 0 ] && [ -f "$NODE_TEST_OUT/system.json" ] && \
       jq . "$NODE_TEST_OUT/system.json" >/dev/null 2>&1; then
        pass "script resolves supported node even when unsupported node is first in PATH"
    else
        fail "script did not resolve supported node with bad PATH first"
        echo "    --- log ---"
        head -30 "$NODE_TEST_OUT/run.log"
        echo "    --- end ---"
    fi
    rm -rf "$NODE_TEST_OUT"
else
    skip "PATH-ordering test (no supported system node found)"
fi

# --- Test 9: node-resolve.sh helpers ---
echo ""
echo "[ node-resolve.sh helpers ]"

LIB_FILE="${REPO_DIR}/scripts/lib/node-resolve.sh"
if [ -f "$LIB_FILE" ]; then
    # Unit-test the version predicate directly.
    (
        # shellcheck source=scripts/lib/node-resolve.sh
        source "$LIB_FILE"

        FAILED=0
        check_version() {
            local version="$1" expected="$2"
            if node_version_supported "$version"; then
                [ "$expected" = "ok" ] || { echo "  unexpected pass for $version"; FAILED=$((FAILED+1)); }
            else
                [ "$expected" = "fail" ] || { echo "  unexpected fail for $version"; FAILED=$((FAILED+1)); }
            fi
        }

        check_version "22.22.3"   "ok"
        check_version "22.23.2"   "ok"
        check_version "22.22.2"   "fail"
        check_version "23.0.0"    "fail"
        check_version "24.15.0"   "ok"
        check_version "24.14.9"   "fail"
        check_version "25.9.0"    "ok"
        check_version "25.8.0"    "fail"
        check_version "26.0.0"    "ok"

        exit "$FAILED"
    )
    LIB_TEST_EXIT=$?
    if [ "$LIB_TEST_EXIT" -eq 0 ]; then
        pass "node_version_supported accepts/rejects expected versions"
    else
        fail "node_version_supported returned unexpected results for $LIB_TEST_EXIT version(s)"
    fi

    # Verify the resolver can find a supported node on this host.
    RESOLVED_NODE=$(
        # shellcheck source=scripts/lib/node-resolve.sh
        source "$LIB_FILE" >/dev/null 2>&1
        resolve_supported_node
    )
    if [ -n "$RESOLVED_NODE" ] && [ -x "$RESOLVED_NODE" ]; then
        pass "resolve_supported_node finds executable node ($RESOLVED_NODE)"
    else
        fail "resolve_supported_node did not return an executable node"
    fi
else
    fail "node-resolve.sh library not found at $LIB_FILE"
fi

# --- Test 10: Health query exit 0 with empty stdout is reported as unknown ---
echo ""
echo "[ Health exit-0 empty stdout ]"
EMPTY_HEALTH_OUT="$(mktemp -d)"
FAKE_OPENCLAW_EMPTY="$EMPTY_HEALTH_OUT/openclaw"

cat > "$FAKE_OPENCLAW_EMPTY" <<'EOF'
#!/usr/bin/env bash
# Fake openclaw that exits 0 but prints nothing (the #37 silent-failure case)
if [[ "$*" == *"health"* ]]; then
    exit 0
fi
exit 1
EOF
chmod +x "$FAKE_OPENCLAW_EMPTY"

cat > "$EMPTY_HEALTH_OUT/node" <<'EOF'
#!/usr/bin/env bash
# Fake node: supports OpenClaw engine range, delegates to first arg
if [ "$1" = "--version" ]; then
    echo "v22.23.2"
    exit 0
fi
exec "$@"
EOF
chmod +x "$EMPTY_HEALTH_OUT/node"

NODE_BIN="$EMPTY_HEALTH_OUT/node" \
    OPENCLAW_BIN="$FAKE_OPENCLAW_EMPTY" \
    NOVA_DASHBOARD_DIR="$EMPTY_HEALTH_OUT" \
    timeout 60 bash "$SCRIPT" --sections=system > "$EMPTY_HEALTH_OUT/run.log" 2>&1
SCRIPT_EXIT=$?

if [ "$SCRIPT_EXIT" -eq 0 ] && [ -f "$EMPTY_HEALTH_OUT/system.json" ] && \
   jq . "$EMPTY_HEALTH_OUT/system.json" >/dev/null 2>&1; then
    pass "script exits 0 and produces valid system.json when health returns empty stdout"
else
    fail "script did not handle empty health stdout"
    head -30 "$EMPTY_HEALTH_OUT/run.log"
fi

HS=$(jq -r '.healthState // empty' "$EMPTY_HEALTH_OUT/system.json" 2>/dev/null)
HE=$(jq -r '.healthError // empty' "$EMPTY_HEALTH_OUT/system.json" 2>/dev/null)
CH=$(jq -r 'if .channels == null then "null" else (.channels | type) end' "$EMPTY_HEALTH_OUT/system.json" 2>/dev/null)

if [ "$HS" = "unknown" ]; then
    pass "healthState is 'unknown' for empty stdout"
else
    fail "expected healthState='unknown' for empty stdout, got '$HS'"
fi

if [ -n "$HE" ] && [[ "$HE" == *"EMPTY output"* ]]; then
    pass "healthError reports empty output reason"
else
    fail "expected healthError mentioning EMPTY output, got '$HE'"
fi

if [ "$CH" = "null" ]; then
    pass "channels is null (not {}) for empty stdout failure"
else
    fail "expected channels=null for empty stdout failure, got type '$CH'"
fi
rm -rf "$EMPTY_HEALTH_OUT"

# --- Test 11: Health query exit 0 with unparseable JSON is reported as unknown ---
echo ""
echo "[ Health exit-0 unparseable JSON ]"
BAD_JSON_OUT="$(mktemp -d)"
FAKE_OPENCLAW_BAD="$BAD_JSON_OUT/openclaw"

cat > "$FAKE_OPENCLAW_BAD" <<'EOF'
#!/usr/bin/env bash
# Fake openclaw that exits 0 but prints output starting with '{' that is not valid JSON
if [[ "$*" == *"health"* ]]; then
    echo '{"broken":'
    exit 0
fi
exit 1
EOF
chmod +x "$FAKE_OPENCLAW_BAD"

cat > "$BAD_JSON_OUT/node" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then
    echo "v22.23.2"
    exit 0
fi
exec "$@"
EOF
chmod +x "$BAD_JSON_OUT/node"

NODE_BIN="$BAD_JSON_OUT/node" \
    OPENCLAW_BIN="$FAKE_OPENCLAW_BAD" \
    NOVA_DASHBOARD_DIR="$BAD_JSON_OUT" \
    timeout 60 bash "$SCRIPT" --sections=system > "$BAD_JSON_OUT/run.log" 2>&1
SCRIPT_EXIT=$?

if [ "$SCRIPT_EXIT" -eq 0 ] && [ -f "$BAD_JSON_OUT/system.json" ] && \
   jq . "$BAD_JSON_OUT/system.json" >/dev/null 2>&1; then
    pass "script exits 0 and produces valid system.json when health returns unparseable JSON"
else
    fail "script did not handle unparseable health JSON"
    head -30 "$BAD_JSON_OUT/run.log"
fi

HS=$(jq -r '.healthState // empty' "$BAD_JSON_OUT/system.json" 2>/dev/null)
HE=$(jq -r '.healthError // empty' "$BAD_JSON_OUT/system.json" 2>/dev/null)
CH=$(jq -r 'if .channels == null then "null" else (.channels | type) end' "$BAD_JSON_OUT/system.json" 2>/dev/null)

if [ "$HS" = "unknown" ]; then
    pass "healthState is 'unknown' for unparseable JSON"
else
    fail "expected healthState='unknown' for unparseable JSON, got '$HS'"
fi

if [ -n "$HE" ] && [[ "$HE" == *"not valid JSON"* ]]; then
    pass "healthError reports invalid JSON reason"
else
    fail "expected healthError mentioning invalid JSON, got '$HE'"
fi

if [ "$CH" = "null" ]; then
    pass "channels is null (not {}) for unparseable JSON failure"
else
    fail "expected channels=null for unparseable JSON failure, got type '$CH'"
fi
rm -rf "$BAD_JSON_OUT"

# --- Test 12: --anthropic-only runs only the Anthropic section ---
echo ""
echo "[ --anthropic-only section selection ]"
ANTH_OUT="$(mktemp -d)"
NOVA_DASHBOARD_DIR="$ANTH_OUT" timeout 60 bash "$SCRIPT" --anthropic-only > "$ANTH_OUT/run.log" 2>&1 || true

# system.json, status.json, staff.json, postgres.json must NOT be produced
UNWANTED_FILES=0
for f in system.json status.json staff.json postgres.json; do
    if [ -f "$ANTH_OUT/$f" ]; then
        UNWANTED_FILES=$((UNWANTED_FILES + 1))
        fail "--anthropic-only produced $f (should only run anthropic section)"
    fi
done
if [ "$UNWANTED_FILES" -eq 0 ]; then
    pass "--anthropic-only did not produce non-anthropic files"
fi

# The log should mention the anthropic section
if grep -qE "anthropic|Anthropic|Sections: .*anthropic" "$ANTH_OUT/run.log"; then
    pass "--anthropic-only log mentions anthropic section"
else
    fail "--anthropic-only log did not mention anthropic section"
fi
rm -rf "$ANTH_OUT"

# --- Test 13: update-anthropic-dashboard.sh wrapper delegates correctly ---
echo ""
echo "[ update-anthropic-dashboard.sh wrapper ]"
WRAPPER="${REPO_DIR}/scripts/update-anthropic-dashboard.sh"
if [ -x "$WRAPPER" ]; then
    WRAPPER_OUT="$(mktemp -d)"
    NOVA_DASHBOARD_DIR="$WRAPPER_OUT" timeout 60 bash "$WRAPPER" > "$WRAPPER_OUT/run.log" 2>&1 || true
    if grep -qE "Sections: .*anthropic|--anthropic-only" "$WRAPPER_OUT/run.log"; then
        pass "update-anthropic-dashboard.sh delegates to --anthropic-only"
    else
        fail "update-anthropic-dashboard.sh did not delegate to --anthropic-only"
        echo "    --- log ---"
        head -30 "$WRAPPER_OUT/run.log"
        echo "    --- end ---"
    fi
    rm -rf "$WRAPPER_OUT"
else
    fail "update-anthropic-dashboard.sh wrapper is missing or not executable"
fi

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
