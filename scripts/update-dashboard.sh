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
#   - update-anthropic-dashboard.sh (anthropic.json)
#
# USAGE:
#   NOVA_DASHBOARD_DIR=/path/to/output ./scripts/update-dashboard.sh
#
# CRON SETUP (single entry — runs every 5 min):
#   */5 * * * * /path/to/scripts/update-dashboard.sh >> /var/log/dashboard-cron.log 2>&1
#
# The Anthropic section self-throttles to 15-minute intervals.
# Each section is isolated in a subshell; a failure in one leaves the others unaffected.
#
# REQUIREMENTS: jq, psql, curl, openclaw (for system section)
#               op (1Password CLI, for anthropic section only)
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

    # Peer agents run their own OpenClaw gateways on dedicated ports.
    # Try HTTP health check first; fall back to process detection if the gateway isn't responding.

    # Newhart — graduated NOVA instance on port 18800
    local newhart_status="offline"
    if curl -s --max-time 2 "http://localhost:18800/health" > /dev/null 2>&1; then
        newhart_status="online"
    elif pgrep -u newhart -f "openclaw" > /dev/null 2>&1; then
        newhart_status="online"
    fi

    # Graybeard — IT/SysAdmin peer agent on port 18802
    local graybeard_status="offline"
    if curl -s --max-time 2 "http://localhost:18802/health" > /dev/null 2>&1; then
        graybeard_status="online"
    elif pgrep -u graybeard -f "openclaw" > /dev/null 2>&1; then
        graybeard_status="online"
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
  "peers": {
    "newhart": {
      "status": "$newhart_status",
      "port": 18800,
      "user": "newhart",
      "role": "NHR Agent",
      "dashboardUrl": null
    },
    "graybeard": {
      "status": "$graybeard_status",
      "port": 18802,
      "user": "graybeard",
      "role": "IT/SysAdmin",
      "dashboardUrl": null
    }
  },
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
# Section: Anthropic API Costs
# ====================
# Outputs: anthropic.json
# Data sources:
#   - Anthropic Admin API: /v1/organizations/cost_report (paginated)
#   - Anthropic Admin API: /v1/organizations/usage_report/messages (paginated)
#   - 1Password CLI for Admin API key retrieval
#   - session-activity.jsonl for active-time cost-per-hour calculation
# Throttle: skips update if anthropic.json is < 15 minutes old
# Previously: update-anthropic-dashboard.sh
# ====================
update_anthropic() {
    local out_file="${OUTPUT_DIR}/anthropic.json"
    local tmp_file="${out_file}.tmp"

    # --- Throttle: skip the expensive API calls if data is fresh enough ---
    # The Anthropic cost_report API has a ~15-minute reporting lag anyway,
    # so updating more frequently would return identical data.
    if [ -f "$out_file" ]; then
        local last_updated
        last_updated=$(jq -r '.updated // empty' "$out_file" 2>/dev/null || true)
        if [ -n "$last_updated" ]; then
            local last_epoch now_epoch age_minutes
            last_epoch=$(date -d "$last_updated" +%s 2>/dev/null || echo 0)
            now_epoch=$(date +%s)
            age_minutes=$(( (now_epoch - last_epoch) / 60 ))
            if [ "$age_minutes" -lt 15 ]; then
                echo "anthropic.json is only ${age_minutes}min old — skipping (throttle: 15min)" 
                return 0
            fi
        fi
    fi

    # --- Anthropic section runs with its own error handling ---
    # We run this in a subshell so errors don't kill the main script
    (
    set -euo pipefail

    # Paths (derive from HOME for portability)
    local log_file="${HOME}/.openclaw/workspace/logs/anthropic-stats.log"
    local spend_log="${HOME}/.openclaw/workspace/logs/anthropic-spend.jsonl"

    mkdir -p "$(dirname "$log_file")"
    mkdir -p "$(dirname "$out_file")"
    mkdir -p "$(dirname "$spend_log")"

    _log() { echo "$(date -Iseconds) - $1" | tee -a "$log_file"; }
    _error_exit() { _log "ERROR: $1"; exit 1; }

    _log "Starting Anthropic dashboard update"

    # Get admin key from 1Password
    if ! eval "$(gpg --decrypt ~/.secrets/1password-master.gpg 2>/dev/null | op signin --account family 2>&1)"; then
        _error_exit "Failed to sign in to 1Password"
    fi

    local admin_key
    admin_key=$(op item get "Anthropic API" --vault "NOVA Shared Vault" --fields "Admin API Key" --reveal 2>/dev/null)
    if [ -z "$admin_key" ]; then
        _error_exit "Failed to retrieve Anthropic Admin API key from 1Password"
    fi

    local current_month first_of_month end_date
    current_month=$(date +%Y-%m)
    first_of_month="${current_month}-01"
    end_date=$(date +%Y-%m-%d)

    # Helper: paginated API fetch
    # Args: $1 = URL, $2 = description
    _fetch_paginated() {
        local url="$1"
        local description="$2"
        local all_data="[]"
        local page_count=0
        local next_page=""

        _log "Fetching ${description} (with pagination)..."

        while true; do
            page_count=$((page_count + 1))
            local fetch_url="$url"
            if [ -n "$next_page" ] && [ "$next_page" != "null" ]; then
                if [[ "$fetch_url" == *"?"* ]]; then
                    fetch_url="${fetch_url}&next_page=${next_page}"
                else
                    fetch_url="${fetch_url}?next_page=${next_page}"
                fi
            fi

            _log "  Fetching page ${page_count}..."
            local response
            response=$(curl -sf "$fetch_url" \
                --header "anthropic-version: 2023-06-01" \
                --header "x-api-key: $admin_key") || {
                _error_exit "Failed to fetch ${description} (page ${page_count})"
            }

            if ! echo "$response" | jq empty 2>/dev/null; then
                _error_exit "Invalid JSON response for ${description} (page ${page_count})"
            fi

            local page_data
            page_data=$(echo "$response" | jq -c '.data // []')

            if [ "$page_data" = "[]" ] || [ "$page_data" = "null" ]; then
                if [ "$page_count" -eq 1 ]; then
                    _log "  Empty response for ${description}"
                    echo '{"data": []}'
                    return 0
                fi
            else
                all_data=$(jq -n --argjson all "$all_data" --argjson page "$page_data" '$all + $page')
            fi

            local has_more
            has_more=$(echo "$response" | jq -r '.has_more // false')
            next_page=$(echo "$response" | jq -r '.next_page // null')

            if [ "$has_more" != "true" ]; then
                _log "  Completed fetching ${description} (${page_count} pages)"
                break
            fi

            if [ -z "$next_page" ] || [ "$next_page" = "null" ]; then
                _log "  Warning: has_more=true but no next_page token for ${description}"
                break
            fi

            if [ "$page_count" -gt 100 ]; then
                _error_exit "Pagination exceeded 100 pages for ${description} - possible infinite loop"
            fi
        done

        echo "{\"data\": $all_data}"
    }

    # Fetch data
    local current_month_url all_time_url usage_url
    current_month_url="https://api.anthropic.com/v1/organizations/cost_report?starting_at=${first_of_month}T00:00:00Z&ending_at=${end_date}T23:59:59Z"
    all_time_url="https://api.anthropic.com/v1/organizations/cost_report?starting_at=2026-01-30T00:00:00Z&ending_at=${end_date}T23:59:59Z"
    usage_url="https://api.anthropic.com/v1/organizations/usage_report/messages?starting_at=2026-01-30T00:00:00Z&ending_at=${end_date}T23:59:59Z&bucket_width=1d"

    local api_response all_time_response usage_response
    api_response=$(_fetch_paginated "$current_month_url" "current month cost data")
    all_time_response=$(_fetch_paginated "$all_time_url" "all-time cost data")
    usage_response=$(_fetch_paginated "$usage_url" "usage data")

    # Parse and calculate
    local month_spend
    month_spend=$(echo "$api_response" | jq --arg month "$current_month" '
      [.data[]? | select(.starting_at | startswith($month)) | .results[]?.amount // 0 | tonumber] | add // 0 | . / 100 | . * 100 | round / 100
    ') || _error_exit "Failed to parse current month spend"

    local all_time_spend
    all_time_spend=$(echo "$all_time_response" | jq '
      [.data[]?.results[]?.amount // 0 | tonumber] | add // 0 | . / 100 | . * 100 | round / 100
    ') || _error_exit "Failed to parse all-time spend"

    local all_time_input all_time_output all_time_cache_read all_time_total_input
    all_time_input=$(echo "$usage_response" | jq '[.data[]?.results[]? | (.uncached_input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation.ephemeral_5m_input_tokens // 0) + (.cache_creation.ephemeral_1h_input_tokens // 0)] | add // 0')
    all_time_output=$(echo "$usage_response" | jq '[.data[]?.results[]?.output_tokens // 0] | add // 0')
    all_time_cache_read=$(echo "$usage_response" | jq '[.data[]?.results[]?.cache_read_input_tokens // 0] | add // 0')
    all_time_total_input=$(echo "$usage_response" | jq '[.data[]?.results[]? | (.uncached_input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation.ephemeral_5m_input_tokens // 0)] | add // 0')

    local all_time_cache_rate="null"
    if [ "$all_time_total_input" -gt 0 ]; then
        all_time_cache_rate=$(echo "$all_time_cache_read $all_time_total_input" | awk '{printf "%.1f", ($1/$2)*100}')
    fi

    local daily_data
    daily_data=$(echo "$api_response" | jq --arg month "$current_month" '
      [.data[]? | select(.starting_at | startswith($month)) | {
        date: (.starting_at | split("T")[0]),
        cost: (([.results[]?.amount // 0 | tonumber] | add // 0) / 100 | . * 100 | round / 100)
      }] | map(select(.cost > 0))
    ')

    local days_elapsed avg_daily days_in_month projected
    days_elapsed=$(echo "$daily_data" | jq 'length')
    avg_daily=$(echo "$month_spend $days_elapsed" | awk '{if($2>0) printf "%.2f", $1/$2; else print 0}')
    days_in_month=$(date -d "${current_month}-01 +1 month -1 day" +%d)
    projected=$(echo "$avg_daily $days_in_month" | awk '{printf "%.0f", $1*$2}')

    local over_limit="false"
    local alert_msg=""
    if (( $(echo "$projected > 5000" | bc -l) )); then
        over_limit="true"
        alert_msg="Projected monthly spend (~\$$projected) approaches/exceeds \$5,000 limit"
    fi

    local today_cost latest_date
    today_cost=$(echo "$daily_data" | jq --arg today "$end_date" '[.[]? | select(.date == $today) | .cost] | add // 0')
    latest_date="$end_date"

    if [ "$today_cost" = "0" ] || [ "$today_cost" = "null" ]; then
        latest_date=$(echo "$daily_data" | jq -r 'sort_by(.date) | last | .date // empty')
        if [ -n "$latest_date" ]; then
            today_cost=$(echo "$daily_data" | jq --arg d "$latest_date" '[.[]? | select(.date == $d) | .cost] | add // 0')
        else
            latest_date="$end_date"
            today_cost="0"
        fi
    fi
    today_cost="${today_cost:-0}"

    local latest_day_usage latest_input_raw latest_output_raw latest_cache_read latest_total_input
    latest_day_usage=$(echo "$usage_response" | jq --arg d "$latest_date" '[.data[]? | select(.starting_at | startswith($d)) | .results[0]] | first // {}')
    latest_input_raw=$(echo "$latest_day_usage" | jq '(.uncached_input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation.ephemeral_5m_input_tokens // 0)')
    latest_output_raw=$(echo "$latest_day_usage" | jq '.output_tokens // 0')
    latest_cache_read=$(echo "$latest_day_usage" | jq '.cache_read_input_tokens // 0')
    latest_total_input=$(echo "$latest_day_usage" | jq '(.uncached_input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation.ephemeral_5m_input_tokens // 0)')

    local latest_input latest_output
    if [ -z "$latest_input_raw" ] || [ "$latest_input_raw" = "null" ] || [ "$latest_input_raw" = "0" ]; then
        latest_input="null"
    else
        latest_input="$latest_input_raw"
    fi

    if [ -z "$latest_output_raw" ] || [ "$latest_output_raw" = "null" ] || [ "$latest_output_raw" = "0" ]; then
        latest_output="null"
    else
        latest_output="$latest_output_raw"
    fi

    local latest_cache_rate="null"
    if [ -n "$latest_total_input" ] && [ "$latest_total_input" != "null" ] && [ "$latest_total_input" != "0" ]; then
        latest_cache_rate=$(echo "$latest_cache_read $latest_total_input" | awk '{printf "%.1f", ($1/$2)*100}')
    fi

    local month_hours_elapsed wall_clock_cph="null"
    month_hours_elapsed=$((days_elapsed * 24))
    if [ "$month_hours_elapsed" -gt 0 ] && [ "$(echo "$month_spend > 0" | bc -l)" -eq 1 ]; then
        wall_clock_cph=$(echo "$month_spend $month_hours_elapsed" | awk '{printf "%.2f", $1/$2}')
    fi

    # Active time from session-activity.jsonl
    local session_activity_log="${HOME}/.openclaw/workspace/logs/session-activity.jsonl"
    local activity_state="${HOME}/.openclaw/workspace/logs/activity-state.json"
    local active_minutes="null" active_hours="null" working_cph="null"

    if [ -f "$session_activity_log" ]; then
        local month_active_minutes
        month_active_minutes=$(cat "$session_activity_log" 2>/dev/null | \
            grep "\"timestamp\":\"${current_month}" 2>/dev/null | \
            jq -s 'group_by(.timestamp | split("T")[0]) | map(max_by(.activeMinutes) | .activeMinutes) | add // 0' 2>/dev/null) || month_active_minutes="0"

        if [ -n "$month_active_minutes" ] && [ "$month_active_minutes" != "null" ] && [ "$month_active_minutes" != "0" ]; then
            active_minutes="$month_active_minutes"
            active_hours=$(echo "$month_active_minutes" | awk '{printf "%.2f", $1/60}')
            if [ "$(echo "$active_hours > 0" | bc -l 2>/dev/null || echo 0)" -eq 1 ] && \
               [ "$(echo "$month_spend > 0" | bc -l 2>/dev/null || echo 0)" -eq 1 ]; then
                working_cph=$(echo "$month_spend $active_hours" | awk '{printf "%.2f", $1/$2}')
            fi
        elif [ -f "$activity_state" ]; then
            active_minutes=$(jq -r '.activeMinutesToday // 0' "$activity_state" 2>/dev/null || echo "null")
            if [ "$active_minutes" != "null" ] && [ "$active_minutes" != "0" ]; then
                active_hours=$(echo "$active_minutes" | awk '{printf "%.2f", $1/60}')
            fi
        fi
    fi

    # Write JSON atomically (validate first)
    cat > "$tmp_file" << EOF
{
  "updated": "$(date -Iseconds)",
  "source": "Admin API (automated)",
  "yesterday": {
    "date": "$latest_date",
    "costDollars": $today_cost,
    "inputTokens": $latest_input,
    "outputTokens": $latest_output,
    "cacheHitRate": $latest_cache_rate
  },
  "currentMonth": {
    "month": "$current_month",
    "spend": $month_spend,
    "limit": 5000,
    "daysElapsed": $days_elapsed,
    "avgDailySpend": $avg_daily,
    "projectedMonthly": $projected,
    "resetDate": "$(date -d "${current_month}-01 +1 month" +%Y-%m-%d)"
  },
  "allTime": {
    "since": "2026-01-30",
    "totalSpend": $all_time_spend,
    "inputTokens": $all_time_input,
    "outputTokens": $all_time_output,
    "cacheHitRate": $all_time_cache_rate
  },
  "daily": $daily_data,
  "costPerHour": {
    "working": $working_cph,
    "wallClock": $wall_clock_cph,
    "activeMinutesMonth": $active_minutes,
    "activeHoursMonth": $active_hours,
    "wallClockHoursMonth": $month_hours_elapsed,
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
    "projectedOverLimit": $over_limit,
    "message": "$alert_msg"
  }
}
EOF

    if ! jq . "$tmp_file" > /dev/null 2>&1; then
        _error_exit "Generated invalid JSON for anthropic.json"
    fi

    mv "$tmp_file" "$out_file"

    echo "{\"timestamp\":\"$(date -Iseconds)\",\"monthSpend\":$month_spend,\"allTimeSpend\":$all_time_spend,\"avgDaily\":$avg_daily,\"projected\":$projected}" >> "$spend_log"

    _log "Dashboard updated: MTD=\$$month_spend, AllTime=\$$all_time_spend, Projected=\$$projected"
    if [ "$over_limit" = "true" ]; then
        _log "ALERT: $alert_msg"
    fi
    _log "Anthropic dashboard update completed successfully"

    ) || {
        echo "WARN: Anthropic section failed (exit $?) — other sections unaffected" >&2
    }
}

# ====================
# Main: Run all sections
# ====================
# Each section is invoked in a subshell ( ... ) so that:
#   1. set -e errors inside a section don't terminate the entire script
#   2. A failure in one section is logged as a warning and the rest continue
# The anthropic section manages its own subshell internally.
# ====================

echo "=== Nova Dashboard Update: $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

( update_system ) || echo "WARN: system.json update failed" >&2
( update_status ) || echo "WARN: status.json update failed" >&2
( update_staff )  || echo "WARN: staff.json update failed" >&2
( update_postgres ) || echo "WARN: postgres.json update failed" >&2
update_anthropic   # already handles its own errors internally

echo "=== Dashboard update complete ==="
