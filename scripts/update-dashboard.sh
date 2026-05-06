#!/usr/bin/env bash
# =============================================================================
# Nova Dashboard Updater (Consolidated)
# =============================================================================
#
# Populates all JSON data files read by dashboard/index.html.
# Replaces five separate cron scripts with a single entry point:
#   - update-dashboard.sh        (system.json)
#   - update-dashboard-status.sh (status.json)
#   - update-staff-dashboard.sh  (staff.json)
#   - dashboard-postgres.sh      (postgres.json)
#   - update-anthropic-dashboard.sh (openrouter.json, formerly anthropic.json)
#
# USAGE:
#   NOVA_DASHBOARD_DIR=/path/to/output ./scripts/update-dashboard.sh
#
# CRON SETUP (single entry — runs every 5 min):
#   */5 * * * * /path/to/scripts/update-dashboard.sh >> /var/log/dashboard-cron.log 2>&1
#
# The OpenRouter section self-throttles to 15-minute intervals.
# Each section is isolated in a subshell; a failure in one leaves the others unaffected.
#
# REQUIREMENTS: jq, psql, curl, openclaw (for system section)
#               OPENROUTER_API_KEY env var (for openrouter section)
# =============================================================================

set -e  # Exit on error at script level; individual sections trap their own errors

# ====================
# Dependency checks
# ====================
for cmd in jq psql curl; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: Required dependency '$cmd' not found in PATH" >&2
        exit 1
    fi
done

# ====================
# Flock — prevent concurrent execution
# ====================
LOCK_FILE="/tmp/nova-dashboard-update-$(whoami).lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "Another instance is already running (lock: $LOCK_FILE). Exiting." >&2
    exit 0
fi

# ====================
# Configuration
# ====================
OUTPUT_DIR="${NOVA_DASHBOARD_DIR:-$HOME/www/static/dashboard}"
mkdir -p "$OUTPUT_DIR"

# Ensure PATH includes common tool locations (cron environment is stripped)
export PATH="/home/linuxbrew/.linuxbrew/bin:/home/$(whoami)/.npm-global/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# ====================
# Helper: derive_db_name
# ====================
derive_db_name() {
    local db_user
    if [ -n "${PGUSER:-}" ]; then
        db_user="$PGUSER"
    else
        if ! db_user=$(whoami 2>&1); then
            echo "ERROR: Failed to determine username (whoami failed)" >&2
            return 1
        fi
    fi

    local db_base="${db_user//-/_}"
    local db_name="${db_base}_memory"

    if ! echo "$db_name" | grep -qE '^[a-zA-Z_][a-zA-Z0-9_]*$'; then
        echo "ERROR: Derived database name '$db_name' is invalid for PostgreSQL" >&2
        return 1
    fi

    if [ "${#db_name}" -gt 63 ]; then
        echo "ERROR: Derived database name '$db_name' exceeds PostgreSQL max length (63 bytes)" >&2
        return 1
    fi

    echo "$db_name"
}

# ====================
# Section: System — Gateway, Channel Status, and System Metrics
# ====================
# Outputs: system.json
# Data sources:
#   - `openclaw health --json` for gateway/channel status
#   - /proc/uptime, /proc/loadavg, free, df, nproc, ip route for system metrics
# ====================
update_system() {
    local out_file="${OUTPUT_DIR}/system.json"
    local tmp_file="${out_file}.tmp"

    # --- Gateway & channel status ---
    # Default to stopped/empty until we confirm the gateway responds
    local gateway_status="stopped"
    local channels_json="{}"

    local health_raw
    if health_raw=$(timeout 15 openclaw health --json --timeout 10000 2>/dev/null); then
        # Strip any non-JSON prefix lines (logging output before the JSON object).
        # The openclaw CLI may emit log lines before the JSON payload; sed discards them.
        local health_json
        health_json=$(echo "$health_raw" | sed -n '/^{/,$p')

        if echo "$health_json" | jq empty 2>/dev/null; then
            gateway_status="running"

            # Build channels object from probe data.
            # openclaw health --json returns:
            #   { channels: { <name>: { probe: { ok, elapsedMs, bot, team } } } }
            # We map each channel to: { status, latencyMs?, bot?, team? }
            # Null fields are stripped with_entries(select(.value != null)) for cleaner JSON.
            channels_json=$(echo "$health_json" | jq -c '
                .channels // {} | to_entries | map({
                    key: .key,
                    value: (
                        .value |
                        {
                            status: (if (.probe.ok // false) then "online" else "offline" end),
                            latencyMs: (.probe.elapsedMs // null),
                            bot: (.probe.bot.username // .probe.bot.name // null),
                            team: (if (.probe.team.name // null) != null then .probe.team.name else null end)
                        } |
                        # Remove null fields so the JSON stays lean
                        with_entries(select(.value != null))
                    )
                }) | from_entries
            ' 2>/dev/null || echo "{}")
        fi
    else
        # Fallback when `openclaw health` fails or times out.
        # Check for the gateway process directly — gives "running" without channel data.
        if pgrep -u "$(whoami)" -f "openclaw-gateway" > /dev/null 2>&1; then
            gateway_status="running"
        else
            gateway_status="stopped"
        fi
        channels_json="{}"
    fi

    # --- System metrics (read directly from /proc and standard Linux tools) ---
    local uptime_seconds
    uptime_seconds=$(cut -d' ' -f1 /proc/uptime | cut -d'.' -f1)
    local load
    load=$(cut -d' ' -f1-3 /proc/loadavg)
    local load_1
    load_1=$(echo "$load" | cut -d' ' -f1)

    local mem_total mem_used mem_percent
    mem_total=$(free -m | awk '/^Mem:/ {print $2}')
    mem_used=$(free -m | awk '/^Mem:/ {print $3}')
    mem_percent=$((mem_used * 100 / mem_total))

    local disk_total disk_used disk_percent
    disk_total=$(df -BG / | awk 'NR==2 {gsub("G",""); print $2}')
    disk_used=$(df -BG / | awk 'NR==2 {gsub("G",""); print $3}')
    disk_percent=$(df / | awk 'NR==2 {gsub("%",""); print $5}')

    local cpu_cores
    cpu_cores=$(nproc)

    local proc_count
    proc_count=$(ps aux | wc -l)

    local default_iface
    default_iface=$(ip route | grep default | awk '{print $5}' | head -1)
    local net_rx net_tx
    net_rx=$(cat "/sys/class/net/${default_iface}/statistics/rx_bytes" 2>/dev/null || echo 0)
    net_tx=$(cat "/sys/class/net/${default_iface}/statistics/tx_bytes" 2>/dev/null || echo 0)

    # Human-readable uptime
    local days hours mins uptime_human
    days=$((uptime_seconds / 86400))
    hours=$(( (uptime_seconds % 86400) / 3600 ))
    mins=$(( (uptime_seconds % 3600) / 60 ))
    if [ "$days" -gt 0 ]; then
        uptime_human="${days}d ${hours}h"
    else
        uptime_human="${hours}h ${mins}m"
    fi

    # Write JSON atomically
    jq -n \
        --arg updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg gateway "$gateway_status" \
        --argjson channels "$channels_json" \
        --arg uptime_human "$uptime_human" \
        --argjson uptime_seconds "$uptime_seconds" \
        --arg load_avg "$load" \
        --argjson load_1 "$load_1" \
        --argjson cpu_cores "$cpu_cores" \
        --argjson mem_total "$mem_total" \
        --argjson mem_used "$mem_used" \
        --argjson mem_percent "$mem_percent" \
        --argjson disk_total "$disk_total" \
        --argjson disk_used "$disk_used" \
        --argjson disk_percent "$disk_percent" \
        --argjson net_rx "$net_rx" \
        --argjson net_tx "$net_tx" \
        --argjson processes "$proc_count" \
        '{
            updated: $updated,
            gateway: $gateway,
            channels: $channels,
            uptime: { seconds: $uptime_seconds, human: $uptime_human },
            load: { avg: $load_avg, load1: $load_1 },
            cpu: { cores: $cpu_cores },
            memory: { totalMB: $mem_total, usedMB: $mem_used, percent: $mem_percent },
            disk: { totalGB: $disk_total, usedGB: $disk_used, percent: $disk_percent },
            network: { rxBytes: $net_rx, txBytes: $net_tx },
            processes: $processes
        }' > "$tmp_file" \
    && mv "$tmp_file" "$out_file" \
    && echo "system.json updated at $(date)"
}

# ====================
# Section: Agent Status
# ====================
# Outputs: status.json
# Data sources:
#   - PostgreSQL (entity_facts table) for compaction count/timestamp
#   - Context window and session data come from the agent when active;
#     this cron script sets them to zero/placeholder defaults.
# Previously: update-dashboard-status.sh
# ====================
update_status() {
    local out_file="${OUTPUT_DIR}/status.json"
    local tmp_file="${out_file}.tmp"
    local db_name

    if ! db_name=$(derive_db_name); then
        echo "WARN: Could not derive DB name; skipping status.json update" >&2
        return 0
    fi

    # Fetch compaction count and timestamp from the database.
    # entity_id=1 is NOVA's primary agent entity; key='compaction_count' stores the running total.
    local compaction_data compactions last_compaction
    compaction_data=$(psql -d "$db_name" -t -A -F'|' -c \
        "SELECT value, data->>'lastCompaction' FROM entity_facts WHERE entity_id=1 AND key='compaction_count';" \
        2>/dev/null || true)
    compactions=$(echo "$compaction_data" | cut -d'|' -f1 | tr -d ' ')
    last_compaction=$(echo "$compaction_data" | cut -d'|' -f2)

    compactions=${compactions:-0}
    if [ -z "$last_compaction" ] || [ "$last_compaction" = "" ]; then
        last_compaction="null"
    else
        last_compaction="\"$last_compaction\""
    fi

    local updated
    updated=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Read model and agent name from openclaw.json (dynamic, not hardcoded)
    local openclaw_config="${HOME}/.openclaw/openclaw.json"
    local model_string="unknown"
    local agent_name="nova"

    if [ -f "$openclaw_config" ]; then
        # Primary model: agents.defaults.model.primary or agents.defaults.model (string)
        model_string=$(jq -r '
            .agents.defaults.model.primary //
            (if (.agents.defaults.model | type) == "string" then .agents.defaults.model else null end) //
            "unknown"
        ' "$openclaw_config" 2>/dev/null || echo "unknown")

        # Agent name: first agent in list with id matching the primary, or the first one
        # For NOVA, we look for the main agent identity
        agent_name=$(jq -r '
            (.agents.list[] | select(.id == "nova") | .id) //
            (.agents.list[0].id) //
            "main"
        ' "$openclaw_config" 2>/dev/null || echo "nova")
    fi

    # Derive provider from model string prefix (e.g., "openrouter/anthropic/claude-opus-4-6")
    local provider=""
    if [[ "$model_string" == openrouter/* ]]; then
        provider="OpenRouter"
    elif [[ "$model_string" == anthropic/* ]]; then
        provider="Anthropic"
    elif [[ "$model_string" == openai/* ]]; then
        provider="OpenAI"
    elif [[ "$model_string" == google/* ]]; then
        provider="Google"
    fi

    cat > "$tmp_file" << EOF
{
  "context": {
    "used": 0,
    "total": 200000,
    "percent": 0
  },
  "compactions": $compactions,
  "model": "$model_string",
  "provider": $([ -n "$provider" ] && echo "\"$provider\"" || echo "null"),
  "lastCompaction": $last_compaction,
  "updated": "$updated",
  "session": "agent:${agent_name}:main",
  "source": "cron"
}
EOF

    mv "$tmp_file" "$out_file"
    echo "status.json updated at $updated"
}

# ====================
# Section: Staff
# ====================
# Outputs: staff.json
# Data sources:
#   - PostgreSQL (agents table) for active agent list
#   - HTTP health check on localhost:18800 for Newhart (graduated NHR instance)
# Previously: update-staff-dashboard.sh
# ====================
update_staff() {
    local out_file="${OUTPUT_DIR}/staff.json"
    local tmp_file="${out_file}.tmp"
    local db_name

    # Newhart is a graduated NOVA instance running its own OpenClaw gateway on port 18800.
    # Try HTTP health check first; fall back to process detection if the gateway isn't responding.
    local newhart_status="offline"
    if curl -s --max-time 2 "http://localhost:18800/health" > /dev/null 2>&1; then
        newhart_status="online"
    elif pgrep -u newhart -f "openclaw" > /dev/null 2>&1; then
        newhart_status="online"
    fi

    # Query agents from database
    local agents_json="[]"
    if db_name=$(derive_db_name 2>/dev/null); then
        agents_json=$(psql -d "$db_name" -t -A -c "
SELECT json_agg(row_to_json(t))
FROM (
    SELECT
        id,
        name,
        nickname,
        role,
        model,
        status,
        instance_type,
        persistent,
        collaborative,
        home_dir,
        unix_user,
        updated_at
    FROM agents
    WHERE status = 'active'
    ORDER BY
        CASE instance_type
            WHEN 'primary' THEN 1
            WHEN 'subagent' THEN 2
            ELSE 3
        END,
        name
) t;
" 2>/dev/null || echo "[]")
    fi

    if [ -z "$agents_json" ] || [ "$agents_json" = "null" ]; then
        agents_json="[]"
    fi

    cat > "$tmp_file" << EOF
{
  "updated": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "newhart": {
    "status": "$newhart_status",
    "port": 18800,
    "user": "newhart",
    "dashboardUrl": null
  },
  "agents": $agents_json,
  "metrics": {
    "note": "Token/cost tracking coming soon - requires Anthropic API metadata attribution"
  }
}
EOF

    mv "$tmp_file" "$out_file"
    echo "staff.json updated at $(date)"
}

# ====================
# Section: PostgreSQL Stats
# ====================
# Outputs: postgres.json
# Data sources:
#   - pg_database_size() for database size
#   - pg_stat_database for performance counters (cache hit ratio, transactions, tuples)
#   - pg_tables + pg_total_relation_size for per-table sizes
# Previously: dashboard-postgres.sh
# ====================
update_postgres() {
    local out_file="${OUTPUT_DIR}/postgres.json"
    local tmp_file="${out_file}.tmp"
    local db_name

    if ! db_name=$(derive_db_name 2>/dev/null); then
        echo "WARN: Could not derive DB name; skipping postgres.json update" >&2
        return 0
    fi

    local db_size db_size_pretty connections
    db_size=$(psql -d "$db_name" -t -c "SELECT pg_database_size('$db_name');" 2>/dev/null | xargs || echo 0)
    db_size_pretty=$(psql -d "$db_name" -t -c "SELECT pg_size_pretty(pg_database_size('$db_name'));" 2>/dev/null | xargs || echo "-")
    connections=$(psql -d "$db_name" -t -c "SELECT count(*) FROM pg_stat_activity WHERE datname = '$db_name';" 2>/dev/null | xargs || echo 0)

    local db_stats
    db_stats=$(psql -d "$db_name" -t -A -F'|' -c "
SELECT
  numbackends,
  xact_commit,
  xact_rollback,
  blks_read,
  blks_hit,
  CASE WHEN (blks_read + blks_hit) > 0
    THEN ROUND(100.0 * blks_hit / (blks_read + blks_hit), 2)
    ELSE 0
  END as cache_hit_ratio,
  tup_returned,
  tup_fetched,
  tup_inserted,
  tup_updated,
  tup_deleted
FROM pg_stat_database
WHERE datname = '$db_name';
" 2>/dev/null | head -1 || echo "0|0|0|0|0|0|0|0|0|0|0")

    local num_backends xacts_commit xacts_rollback blks_read blks_hit cache_hit_ratio
    local tup_returned tup_fetched tup_inserted tup_updated tup_deleted
    IFS='|' read -r num_backends xacts_commit xacts_rollback blks_read blks_hit cache_hit_ratio \
        tup_returned tup_fetched tup_inserted tup_updated tup_deleted <<< "$db_stats"

    local tables_json
    tables_json=$(psql -d "$db_name" -t -A -c "
SELECT json_agg(t) FROM (
  SELECT
    tablename as name,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as size,
    pg_total_relation_size(schemaname||'.'||tablename) as bytes,
    COALESCE((
      SELECT reltuples::bigint
      FROM pg_class
      WHERE oid = (schemaname||'.'||tablename)::regclass
    ), 0) as rows
  FROM pg_tables
  WHERE schemaname = 'public'
  ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC
  LIMIT 20
) t;
" 2>/dev/null || echo "[]")

    if [ -z "$tables_json" ] || [ "$tables_json" = "null" ]; then
        tables_json="[]"
    fi

    cat > "$tmp_file" << EOF
{
  "updated": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "database": {
    "name": "$db_name",
    "sizeBytes": ${db_size:-0},
    "size": "${db_size_pretty:--}",
    "connections": ${connections:-0}
  },
  "stats": {
    "backends": ${num_backends:-0},
    "transactions": {
      "commits": ${xacts_commit:-0},
      "rollbacks": ${xacts_rollback:-0}
    },
    "blocks": {
      "read": ${blks_read:-0},
      "hit": ${blks_hit:-0}
    },
    "cacheHitRatio": ${cache_hit_ratio:-0},
    "tuples": {
      "returned": ${tup_returned:-0},
      "fetched": ${tup_fetched:-0},
      "inserted": ${tup_inserted:-0},
      "updated": ${tup_updated:-0},
      "deleted": ${tup_deleted:-0}
    }
  },
  "tables": ${tables_json}
}
EOF

    mv "$tmp_file" "$out_file"
    echo "postgres.json updated at $(date)"
}

# ====================
# Section: OpenRouter API Costs
# ====================
# Outputs: openrouter.json (and anthropic.json as a back-compat symlink)
# Data sources:
#   - OpenRouter: GET /api/v1/credits     (total_credits, total_usage)
#   - Local snapshot log: logs/openrouter-snapshots.jsonl
#         Each update appends {timestamp, total_usage, total_credits}.
#         Daily/monthly deltas are derived from this log.
#   - session-activity.jsonl for active-time cost-per-hour calculation
# Throttle: skips update if openrouter.json is < 15 minutes old
# ====================
update_openrouter() {
    local out_file="${OUTPUT_DIR}/openrouter.json"
    local compat_file="${OUTPUT_DIR}/anthropic.json"
    local tmp_file="${out_file}.tmp"

    # --- Throttle: avoid hammering the OpenRouter API ---
    if [ -f "$out_file" ]; then
        local last_updated
        last_updated=$(jq -r '.updated // empty' "$out_file" 2>/dev/null || true)
        if [ -n "$last_updated" ]; then
            local last_epoch now_epoch age_minutes
            last_epoch=$(date -d "$last_updated" +%s 2>/dev/null || echo 0)
            now_epoch=$(date +%s)
            age_minutes=$(( (now_epoch - last_epoch) / 60 ))
            if [ "$age_minutes" -lt 15 ]; then
                echo "openrouter.json is only ${age_minutes}min old — skipping (throttle: 15min)"
                return 0
            fi
        fi
    fi

    (
    set -euo pipefail

    local log_file="${HOME}/.openclaw/workspace/logs/openrouter-stats.log"
    local spend_log="${HOME}/.openclaw/workspace/logs/openrouter-spend.jsonl"
    local snapshot_log="${HOME}/.openclaw/workspace/logs/openrouter-snapshots.jsonl"

    mkdir -p "$(dirname "$log_file")"
    mkdir -p "$(dirname "$out_file")"
    mkdir -p "$(dirname "$spend_log")"
    mkdir -p "$(dirname "$snapshot_log")"

    _log() { echo "$(date -Iseconds) - $1" | tee -a "$log_file"; }
    _error_exit() { _log "ERROR: $1"; exit 1; }

    _log "Starting OpenRouter dashboard update"

    if [ -z "${OPENROUTER_API_KEY:-}" ]; then
        _error_exit "OPENROUTER_API_KEY is not set in the environment"
    fi

    # --- Fetch /credits ---
    local credits_response total_usage total_credits
    credits_response=$(curl -sfS --max-time 20 \
        -H "Authorization: Bearer ${OPENROUTER_API_KEY}" \
        https://openrouter.ai/api/v1/credits) || \
        _error_exit "Failed to call /api/v1/credits"

    if ! echo "$credits_response" | jq empty 2>/dev/null; then
        _error_exit "Invalid JSON from /api/v1/credits"
    fi

    total_usage=$(echo "$credits_response" | jq -r '.data.total_usage // 0')
    total_credits=$(echo "$credits_response" | jq -r '.data.total_credits // 0')

    if [ -z "$total_usage" ] || [ "$total_usage" = "null" ]; then
        _error_exit "No total_usage in /credits response"
    fi

    # --- Append snapshot ---
    local now_iso
    now_iso=$(date -Iseconds)
    echo "{\"timestamp\":\"${now_iso}\",\"total_usage\":${total_usage},\"total_credits\":${total_credits}}" \
        >> "$snapshot_log"

    # --- Derive daily + MTD from snapshot log ---
    # For each UTC day, take the first (earliest) snapshot as that day's starting usage.
    # A day's cost = next_day_first_total_usage - this_day_first_total_usage.
    # The current day's cost = current total_usage - today's first snapshot.
    local current_month first_of_month end_date today
    current_month=$(date -u +%Y-%m)
    first_of_month="${current_month}-01"
    end_date=$(date -u +%Y-%m-%d)
    today="$end_date"

    # Extract daily-first snapshots for the current month using jq.
    # Output: [{date, first_total_usage}] sorted ascending by date.
    local daily_firsts
    daily_firsts=$(jq -sc --arg month "$current_month" '
        [ .[]
          | select(.timestamp | startswith($month))
          | {date: (.timestamp | split("T")[0]), ts: .timestamp, total_usage: .total_usage}
        ]
        | group_by(.date)
        | map(min_by(.ts))
        | sort_by(.date)
        | map({date: .date, first_total_usage: .total_usage})
    ' "$snapshot_log" 2>/dev/null || echo "[]")

    if [ -z "$daily_firsts" ] || [ "$daily_firsts" = "null" ]; then
        daily_firsts="[]"
    fi

    # Build daily cost series: per-day cost = next_day.first - this_day.first,
    # except current day which is (current total_usage - today's first snapshot).
    local daily_data
    daily_data=$(jq -c --argjson current "$total_usage" --arg today "$today" '
        . as $arr
        | [range(0; length) as $i
           | $arr[$i] as $d
           | (if $i + 1 < ($arr|length) then $arr[$i+1].first_total_usage
              else $current end) as $next_first
           | {date: $d.date, cost: (($next_first - $d.first_total_usage) * 100 | round / 100)}
          ]
        | map(select(.cost > 0.005 or .date == $today))
    ' <<<"$daily_firsts")

    if [ -z "$daily_data" ] || [ "$daily_data" = "null" ]; then
        daily_data="[]"
    fi

    # MTD spend = current total_usage - first snapshot of the month's first_total_usage.
    # If we have no prior snapshots this month, MTD = 0 for this invocation
    # (the next run will see a delta).
    local month_start_usage month_spend
    month_start_usage=$(echo "$daily_firsts" | jq -r '.[0].first_total_usage // empty')
    if [ -z "$month_start_usage" ]; then
        month_spend="0.00"
    else
        month_spend=$(awk -v c="$total_usage" -v s="$month_start_usage" 'BEGIN{printf "%.2f", c-s}')
    fi

    # days_elapsed: number of distinct UTC days covered by daily_data (at least 1)
    local days_elapsed days_in_month avg_daily projected
    days_elapsed=$(echo "$daily_data" | jq 'length')
    if [ "$days_elapsed" -lt 1 ]; then
        days_elapsed=1
    fi
    days_in_month=$(date -u -d "${first_of_month} +1 month -1 day" +%d)
    avg_daily=$(awk -v m="$month_spend" -v d="$days_elapsed" 'BEGIN{if(d>0)printf "%.2f", m/d; else print 0}')
    projected=$(awk -v a="$avg_daily" -v d="$days_in_month" 'BEGIN{printf "%.0f", a*d}')

    local limit=5000
    local over_limit="false"
    local alert_msg=""
    if awk -v p="$projected" -v L="$limit" 'BEGIN{exit !(p>L)}'; then
        over_limit="true"
        alert_msg="Projected monthly spend (~\$${projected}) approaches/exceeds \$${limit} limit"
    fi

    # Yesterday / latest-day cost
    local latest_date latest_cost
    latest_date=$(echo "$daily_data" | jq -r 'sort_by(.date) | last.date // empty')
    latest_cost=$(echo "$daily_data" | jq -r --arg d "$latest_date" '[.[]|select(.date==$d)|.cost]|add // 0')
    if [ -z "$latest_date" ]; then
        latest_date="$today"
        latest_cost="0"
    fi

    # All-time totals come straight from /credits
    local all_time_spend
    all_time_spend=$(awk -v u="$total_usage" 'BEGIN{printf "%.2f", u}')
    local all_time_since
    all_time_since=$(jq -s 'min_by(.timestamp).timestamp // empty' "$snapshot_log" 2>/dev/null | tr -d '"' | cut -c1-10)
    if [ -z "$all_time_since" ] || [ "$all_time_since" = "null" ]; then
        all_time_since="$today"
    fi

    # Cost-per-hour (active + wall clock) using session-activity.jsonl
    local session_activity_log="${HOME}/.openclaw/workspace/logs/session-activity.jsonl"
    local activity_state="${HOME}/.openclaw/workspace/logs/activity-state.json"
    local active_minutes="null" active_hours="null" working_cph="null" wall_clock_cph="null"
    local month_hours_elapsed
    month_hours_elapsed=$((days_elapsed * 24))

    if awk -v m="$month_spend" -v h="$month_hours_elapsed" 'BEGIN{exit !(m>0 && h>0)}'; then
        wall_clock_cph=$(awk -v m="$month_spend" -v h="$month_hours_elapsed" 'BEGIN{printf "%.2f", m/h}')
    fi

    if [ -f "$session_activity_log" ]; then
        local month_active_minutes
        month_active_minutes=$(grep "\"timestamp\":\"${current_month}" "$session_activity_log" 2>/dev/null | \
            jq -s 'group_by(.timestamp | split("T")[0]) | map(max_by(.activeMinutes) | .activeMinutes) | add // 0' 2>/dev/null) || month_active_minutes="0"

        if [ -n "$month_active_minutes" ] && [ "$month_active_minutes" != "null" ] && [ "$month_active_minutes" != "0" ]; then
            active_minutes="$month_active_minutes"
            active_hours=$(awk -v m="$month_active_minutes" 'BEGIN{printf "%.2f", m/60}')
            if awk -v ah="$active_hours" -v m="$month_spend" 'BEGIN{exit !(ah>0 && m>0)}'; then
                working_cph=$(awk -v m="$month_spend" -v h="$active_hours" 'BEGIN{printf "%.2f", m/h}')
            fi
        elif [ -f "$activity_state" ]; then
            active_minutes=$(jq -r '.activeMinutesToday // 0' "$activity_state" 2>/dev/null || echo "null")
            if [ "$active_minutes" != "null" ] && [ "$active_minutes" != "0" ]; then
                active_hours=$(awk -v m="$active_minutes" 'BEGIN{printf "%.2f", m/60}')
            fi
        fi
    fi

    # Write JSON atomically (validate first)
    cat > "$tmp_file" << EOF
{
  "updated": "$(date -Iseconds)",
  "source": "OpenRouter /credits + local snapshots",
  "provider": "openrouter",
  "yesterday": {
    "date": "${latest_date}",
    "costDollars": ${latest_cost},
    "inputTokens": null,
    "outputTokens": null,
    "cacheHitRate": null
  },
  "currentMonth": {
    "month": "${current_month}",
    "spend": ${month_spend},
    "limit": ${limit},
    "daysElapsed": ${days_elapsed},
    "avgDailySpend": ${avg_daily},
    "projectedMonthly": ${projected},
    "resetDate": "$(date -u -d "${first_of_month} +1 month" +%Y-%m-%d)"
  },
  "allTime": {
    "since": "${all_time_since}",
    "totalSpend": ${all_time_spend},
    "inputTokens": null,
    "outputTokens": null,
    "cacheHitRate": null,
    "totalCredits": ${total_credits}
  },
  "daily": ${daily_data},
  "costPerHour": {
    "working": ${working_cph},
    "wallClock": ${wall_clock_cph},
    "activeMinutesMonth": ${active_minutes},
    "activeHoursMonth": ${active_hours},
    "wallClockHoursMonth": ${month_hours_elapsed},
    "scope": "month",
    "source": "session-activity.jsonl",
    "note": "Monthly average from actual tracked activity"
  },
  "aws": {
    "enabled": false,
    "monthlyEstimate": null,
    "dailyEstimate": null,
    "note": "AWS costs not yet integrated"
  },
  "alerts": {
    "projectedOverLimit": ${over_limit},
    "message": "${alert_msg}"
  }
}
EOF

    if ! jq . "$tmp_file" > /dev/null 2>&1; then
        _error_exit "Generated invalid JSON for openrouter.json"
    fi

    mv "$tmp_file" "$out_file"

    # Back-compat: keep anthropic.json in sync until frontend migration is complete.
    cp "$out_file" "$compat_file"

    echo "{\"timestamp\":\"$(date -Iseconds)\",\"monthSpend\":${month_spend},\"allTimeSpend\":${all_time_spend},\"avgDaily\":${avg_daily},\"projected\":${projected}}" >> "$spend_log"

    _log "Dashboard updated: MTD=\$${month_spend}, AllTime=\$${all_time_spend}, Projected=\$${projected}"
    if [ "$over_limit" = "true" ]; then
        _log "ALERT: $alert_msg"
    fi
    _log "OpenRouter dashboard update completed successfully"

    ) || {
        echo "WARN: OpenRouter section failed (exit $?) — other sections unaffected" >&2
    }
}

# ====================
# Main: Run all sections
# ====================
# Each section is invoked in a subshell ( ... ) so that:
#   1. set -e errors inside a section don't terminate the entire script
#   2. A failure in one section is logged as a warning and the rest continue
# The openrouter section manages its own subshell internally.
# ====================

echo "=== Nova Dashboard Update: $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

( update_system ) || echo "WARN: system.json update failed" >&2
( update_status ) || echo "WARN: status.json update failed" >&2
( update_staff )  || echo "WARN: staff.json update failed" >&2
( update_postgres ) || echo "WARN: postgres.json update failed" >&2
update_openrouter  # already handles its own errors internally

echo "=== Dashboard update complete ==="
