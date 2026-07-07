#!/usr/bin/env bash
# Test fixture for issue #35 — channel status mapping from health output.
#
# Validates that the jq transform used by scripts/update-dashboard.sh maps the
# current `openclaw health --json` schema to the dashboard channel model:
#   connected=true        -> "online"
#   connected=false/null, running=true -> "idle"
#   otherwise             -> "offline"
# Bot and team fields are read from .bot.username / .team.name, and legacy
# .probe.ok paths still fall back correctly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE="${SCRIPT_DIR}/fixtures/health-sample.json"

PASS=0
FAIL=0

pass() { echo "  ✅ PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  ❌ FAIL: $1"; FAIL=$((FAIL+1)); }

# The same channel transform used by scripts/update-dashboard.sh.
CHANNEL_JQ='
    .channels // {} | to_entries | map({
        key: .key,
        value: (
            .value |
            {
                status: (
                    if (.connected // false) then "online"
                    elif (.running // false) then "idle"
                    elif (.probe.ok // false) then "online"
                    else "offline"
                    end
                ),
                latencyMs: (.probe.elapsedMs // null),
                bot: (.bot.username // .bot.name // .probe.bot.username // .probe.bot.name // null),
                team: (.team.name // .probe.team.name // null)
            } |
            with_entries(select(.value != null))
        )
    }) | from_entries
'

echo ""
echo "=== Issue #35: health output channel mapping ==="
echo "Fixture: $FIXTURE"
echo ""

# Apply the channel transform to the fixture.
CHANNELS_JSON=$(jq -c "$CHANNEL_JQ" "$FIXTURE")

echo "[ Channel status mapping ]"

check_status() {
    local channel="$1"
    local expected="$2"
    local actual
    actual=$(echo "$CHANNELS_JSON" | jq -r --arg ch "$channel" '.[$ch].status // empty')
    if [ "$actual" = "$expected" ]; then
        pass "${channel} -> ${expected}"
    else
        fail "${channel} expected ${expected}, got '${actual}'"
    fi
}

check_status "discord" "online"
check_status "slack" "online"
check_status "telegram" "online"
check_status "signal" "idle"
check_status "agent_chat" "idle"
check_status "offline_channel" "offline"

echo ""
echo "[ Bot / team field paths ]"

DISCORD_BOT=$(echo "$CHANNELS_JSON" | jq -r '.discord.bot // empty')
if [ "$DISCORD_BOT" = "NOVA" ]; then
    pass "discord bot name parsed from .bot.username"
else
    fail "discord bot name expected 'NOVA', got '${DISCORD_BOT}'"
fi

if echo "$CHANNELS_JSON" | jq -e '.discord | has("team")' >/dev/null 2>&1; then
    fail "discord team should be omitted when unavailable"
else
    pass "discord team omitted when unavailable"
fi

if echo "$CHANNELS_JSON" | jq -e '.discord | has("latencyMs")' >/dev/null 2>&1; then
    fail "discord latencyMs should be omitted when unavailable"
else
    pass "discord latencyMs omitted when unavailable"
fi

echo ""
echo "[ Legacy .probe.ok fallback ]"
LEGACY_JSON='{"channels":{"legacy":{"probe":{"ok":true,"elapsedMs":42,"bot":{"username":"oldbot"},"team":{"name":"oldteam"}}}}}'
LEGACY_OUT=$(echo "$LEGACY_JSON" | jq -c "$CHANNEL_JQ")
if [ "$(echo "$LEGACY_OUT" | jq -r '.legacy.status')" = "online" ]; then
    pass "legacy .probe.ok still maps to online"
else
    fail "legacy .probe.ok did not map to online"
fi
if [ "$(echo "$LEGACY_OUT" | jq -r '.legacy.bot')" = "oldbot" ]; then
    pass "legacy .probe.bot.username still parsed"
else
    fail "legacy .probe.bot.username not parsed"
fi
if [ "$(echo "$LEGACY_OUT" | jq -r '.legacy.team')" = "oldteam" ]; then
    pass "legacy .probe.team.name still parsed"
else
    fail "legacy .probe.team.name not parsed"
fi
if [ "$(echo "$LEGACY_OUT" | jq -r '.legacy.latencyMs')" = "42" ]; then
    pass "legacy .probe.elapsedMs still parsed"
else
    fail "legacy .probe.elapsedMs not parsed"
fi

echo ""
echo "=== Test Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
echo ""

if [ "$FAIL" -gt 0 ]; then
    echo "❌ $FAIL test(s) failed"
    exit 1
else
    echo "✅ All tests passed"
    exit 0
fi
