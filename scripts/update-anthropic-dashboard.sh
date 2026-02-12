#!/bin/bash
# Automated Anthropic dashboard update - runs via system cron
# Updates ~/www/static/dashboard/anthropic.json with cost data from Admin API

set -euo pipefail  # Added -u for unset variable detection, -o pipefail for pipe failures

# Ensure PATH includes necessary tools (for cron environment)
export PATH="/home/linuxbrew/.linuxbrew/bin:/home/nova/.npm-global/bin:$PATH"
export HOME="/home/nova"

LOG_FILE="${HOME}/clawd/logs/anthropic-stats.log"
DASHBOARD_FILE="${HOME}/www/static/dashboard/anthropic.json"
SPEND_LOG="${HOME}/clawd/logs/anthropic-spend.jsonl"

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$(dirname "$DASHBOARD_FILE")"
mkdir -p "$(dirname "$SPEND_LOG")"

log() {
    echo "$(date -Iseconds) - $1" | tee -a "$LOG_FILE"
}

error_exit() {
    log "ERROR: $1"
    exit 1
}

log "Starting Anthropic dashboard update"

# Get admin key from 1Password with better error handling
if ! eval $(gpg --decrypt ~/.secrets/1password-master.gpg 2>/dev/null | op signin --account family 2>&1); then
    error_exit "Failed to sign in to 1Password"
fi

ADMIN_KEY=$(op item get "Anthropic API" --vault "NOVA Shared Vault" --fields "Admin API Key" --reveal 2>/dev/null)
if [ -z "$ADMIN_KEY" ]; then
    error_exit "Failed to retrieve Anthropic Admin API key from 1Password"
fi

# Fetch data from API - use start of current month for monthly data
CURRENT_MONTH=$(date +%Y-%m)
FIRST_OF_MONTH="${CURRENT_MONTH}-01"
END_DATE=$(date +%Y-%m-%d)

# Helper function to fetch paginated API data
# Args: $1 = URL, $2 = description
fetch_paginated() {
    local url="$1"
    local description="$2"
    local all_data="[]"
    local page_count=0
    local next_page=""
    
    log "Fetching ${description} (with pagination)..."
    
    while true; do
        page_count=$((page_count + 1))
        
        # Build URL with next_page token if available
        local fetch_url="$url"
        if [ -n "$next_page" ] && [ "$next_page" != "null" ]; then
            # Add next_page parameter
            if [[ "$fetch_url" == *"?"* ]]; then
                fetch_url="${fetch_url}&next_page=${next_page}"
            else
                fetch_url="${fetch_url}?next_page=${next_page}"
            fi
        fi
        
        log "  Fetching page ${page_count}..."
        
        # Fetch the page
        local response
        response=$(curl -sf "$fetch_url" \
            --header "anthropic-version: 2023-06-01" \
            --header "x-api-key: $ADMIN_KEY") || {
            error_exit "Failed to fetch ${description} (page ${page_count})"
        }
        
        # Validate JSON response
        if ! echo "$response" | jq empty 2>/dev/null; then
            error_exit "Invalid JSON response for ${description} (page ${page_count})"
        fi
        
        # Extract data array from this page
        local page_data
        page_data=$(echo "$response" | jq -c '.data // []')
        
        # Handle empty response
        if [ "$page_data" = "[]" ] || [ "$page_data" = "null" ]; then
            if [ "$page_count" -eq 1 ]; then
                log "  Empty response for ${description}"
                echo '{"data": []}'
                return 0
            fi
        else
            # Append this page's data to accumulated data
            all_data=$(jq -n --argjson all "$all_data" --argjson page "$page_data" '$all + $page')
        fi
        
        # Check for pagination
        local has_more
        has_more=$(echo "$response" | jq -r '.has_more // false')
        next_page=$(echo "$response" | jq -r '.next_page // null')
        
        if [ "$has_more" != "true" ]; then
            log "  Completed fetching ${description} (${page_count} pages)"
            break
        fi
        
        if [ -z "$next_page" ] || [ "$next_page" = "null" ]; then
            log "  Warning: has_more=true but no next_page token for ${description}"
            break
        fi
        
        # Safety check: prevent infinite loops
        if [ "$page_count" -gt 100 ]; then
            error_exit "Pagination exceeded 100 pages for ${description} - possible infinite loop"
        fi
    done
    
    # Return accumulated data wrapped in response format
    echo "{\"data\": $all_data}"
}

# Fetch current month data with pagination
CURRENT_MONTH_URL="https://api.anthropic.com/v1/organizations/cost_report?starting_at=${FIRST_OF_MONTH}T00:00:00Z&ending_at=${END_DATE}T23:59:59Z"
API_RESPONSE=$(fetch_paginated "$CURRENT_MONTH_URL" "current month cost data")

# Fetch all-time data with pagination (from account start Jan 30, 2026)
ALL_TIME_URL="https://api.anthropic.com/v1/organizations/cost_report?starting_at=2026-01-30T00:00:00Z&ending_at=${END_DATE}T23:59:59Z"
ALL_TIME_RESPONSE=$(fetch_paginated "$ALL_TIME_URL" "all-time cost data")

# Fetch usage data (tokens) from usage_report endpoint with pagination
USAGE_URL="https://api.anthropic.com/v1/organizations/usage_report/messages?starting_at=2026-01-30T00:00:00Z&ending_at=${END_DATE}T23:59:59Z&bucket_width=1d"
USAGE_RESPONSE=$(fetch_paginated "$USAGE_URL" "usage data")

# Parse and calculate (amounts in cents, divide by 100)

# Calculate current month spend
MONTH_SPEND=$(echo "$API_RESPONSE" | jq --arg month "$CURRENT_MONTH" '
  [.data[]? | select(.starting_at | startswith($month)) | .results[]?.amount // 0 | tonumber] | add // 0 | . / 100 | . * 100 | round / 100
') || error_exit "Failed to parse current month spend"

# Calculate all-time spend
ALL_TIME_SPEND=$(echo "$ALL_TIME_RESPONSE" | jq '
  [.data[]?.results[]?.amount // 0 | tonumber] | add // 0 | . / 100 | . * 100 | round / 100
') || error_exit "Failed to parse all-time spend"

# Calculate all-time token usage
ALL_TIME_INPUT=$(echo "$USAGE_RESPONSE" | jq '[.data[]?.results[]? | (.uncached_input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation.ephemeral_5m_input_tokens // 0) + (.cache_creation.ephemeral_1h_input_tokens // 0)] | add // 0')
ALL_TIME_OUTPUT=$(echo "$USAGE_RESPONSE" | jq '[.data[]?.results[]?.output_tokens // 0] | add // 0')
ALL_TIME_CACHE_READ=$(echo "$USAGE_RESPONSE" | jq '[.data[]?.results[]?.cache_read_input_tokens // 0] | add // 0')
ALL_TIME_TOTAL_INPUT=$(echo "$USAGE_RESPONSE" | jq '[.data[]?.results[]? | (.uncached_input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation.ephemeral_5m_input_tokens // 0)] | add // 0')

# Calculate cache hit rate (all-time)
if [ "$ALL_TIME_TOTAL_INPUT" -gt 0 ]; then
    ALL_TIME_CACHE_RATE=$(echo "$ALL_TIME_CACHE_READ $ALL_TIME_TOTAL_INPUT" | awk '{printf "%.1f", ($1/$2)*100}')
else
    ALL_TIME_CACHE_RATE="null"
fi

# Get daily data for current month
DAILY_DATA=$(echo "$API_RESPONSE" | jq --arg month "$CURRENT_MONTH" '
  [.data[]? | select(.starting_at | startswith($month)) | {
    date: (.starting_at | split("T")[0]),
    cost: (([.results[]?.amount // 0 | tonumber] | add // 0) / 100 | . * 100 | round / 100)
  }] | map(select(.cost > 0))
')

DAYS_ELAPSED=$(echo "$DAILY_DATA" | jq 'length')
AVG_DAILY=$(echo "$MONTH_SPEND $DAYS_ELAPSED" | awk '{if($2>0) printf "%.2f", $1/$2; else print 0}')
DAYS_IN_MONTH=$(date -d "${CURRENT_MONTH}-01 +1 month -1 day" +%d)
PROJECTED=$(echo "$AVG_DAILY $DAYS_IN_MONTH" | awk '{printf "%.0f", $1*$2}')

# Check if over limit
OVER_LIMIT="false"
ALERT_MSG=""
if (( $(echo "$PROJECTED > 5000" | bc -l) )); then
    OVER_LIMIT="true"
    ALERT_MSG="Projected monthly spend (~\$$PROJECTED) approaches/exceeds \$5,000 limit"
fi

# Get most recent day's cost and usage for "yesterday" section
TODAY_COST=$(echo "$DAILY_DATA" | jq --arg today "$END_DATE" '[.[]? | select(.date == $today) | .cost] | add // 0')
LATEST_DATE="$END_DATE"

# If today has no cost data, find the most recent day with data
if [ "$TODAY_COST" = "0" ] || [ "$TODAY_COST" = "null" ]; then
    LATEST_DATE=$(echo "$DAILY_DATA" | jq -r 'sort_by(.date) | last | .date // empty')
    if [ -n "$LATEST_DATE" ]; then
        TODAY_COST=$(echo "$DAILY_DATA" | jq --arg d "$LATEST_DATE" '[.[]? | select(.date == $d) | .cost] | add // 0')
    else
        LATEST_DATE="$END_DATE"
        TODAY_COST="0"
    fi
fi

# Ensure TODAY_COST is never empty or null string
TODAY_COST="${TODAY_COST:-0}"

# Get latest day's token usage
LATEST_DAY_USAGE=$(echo "$USAGE_RESPONSE" | jq --arg d "$LATEST_DATE" '[.data[]? | select(.starting_at | startswith($d)) | .results[0]] | first // {}')
LATEST_INPUT_RAW=$(echo "$LATEST_DAY_USAGE" | jq '(.uncached_input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation.ephemeral_5m_input_tokens // 0)')
LATEST_OUTPUT_RAW=$(echo "$LATEST_DAY_USAGE" | jq '.output_tokens // 0')
LATEST_CACHE_READ=$(echo "$LATEST_DAY_USAGE" | jq '.cache_read_input_tokens // 0')
LATEST_TOTAL_INPUT=$(echo "$LATEST_DAY_USAGE" | jq '(.uncached_input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation.ephemeral_5m_input_tokens // 0)')

# Handle missing usage data (API lags cost data by ~3 days)
# Set to null (JSON null, not string) when data is missing/zero
if [ -z "$LATEST_INPUT_RAW" ] || [ "$LATEST_INPUT_RAW" = "null" ] || [ "$LATEST_INPUT_RAW" = "0" ]; then
    LATEST_INPUT="null"
else
    LATEST_INPUT="$LATEST_INPUT_RAW"
fi

if [ -z "$LATEST_OUTPUT_RAW" ] || [ "$LATEST_OUTPUT_RAW" = "null" ] || [ "$LATEST_OUTPUT_RAW" = "0" ]; then
    LATEST_OUTPUT="null"
else
    LATEST_OUTPUT="$LATEST_OUTPUT_RAW"
fi

# Calculate cache hit rate for latest day
if [ -n "$LATEST_TOTAL_INPUT" ] && [ "$LATEST_TOTAL_INPUT" != "null" ] && [ "$LATEST_TOTAL_INPUT" != "0" ]; then
    LATEST_CACHE_RATE=$(echo "$LATEST_CACHE_READ $LATEST_TOTAL_INPUT" | awk '{printf "%.1f", ($1/$2)*100}')
else
    LATEST_CACHE_RATE="null"
fi

# Monthly cost per hour calculation
MONTH_HOURS_ELAPSED=$((DAYS_ELAPSED * 24))
WALL_CLOCK_CPH="null"
if [ "$MONTH_HOURS_ELAPSED" -gt 0 ] && [ "$(echo "$MONTH_SPEND > 0" | bc -l)" -eq 1 ]; then
    WALL_CLOCK_CPH=$(echo "$MONTH_SPEND $MONTH_HOURS_ELAPSED" | awk '{printf "%.2f", $1/$2}')
fi

# Get actual active time from session-activity.jsonl
SESSION_ACTIVITY_LOG="${HOME}/clawd/logs/session-activity.jsonl"
ACTIVITY_STATE="${HOME}/clawd/logs/activity-state.json"
ACTIVE_MINUTES="null"
ACTIVE_HOURS="null"
WORKING_CPH="null"

if [ -f "$SESSION_ACTIVITY_LOG" ]; then
    # Get all entries for this month, take max per day, sum them
    MONTH_ACTIVE_MINUTES=$(cat "$SESSION_ACTIVITY_LOG" 2>/dev/null | \
        grep "\"timestamp\":\"${CURRENT_MONTH}" 2>/dev/null | \
        jq -s 'group_by(.timestamp | split("T")[0]) | map(max_by(.activeMinutes) | .activeMinutes) | add // 0' 2>/dev/null) || MONTH_ACTIVE_MINUTES="0"
    
    if [ -n "$MONTH_ACTIVE_MINUTES" ] && [ "$MONTH_ACTIVE_MINUTES" != "null" ] && [ "$MONTH_ACTIVE_MINUTES" != "0" ]; then
        ACTIVE_MINUTES="$MONTH_ACTIVE_MINUTES"
        ACTIVE_HOURS=$(echo "$MONTH_ACTIVE_MINUTES" | awk '{printf "%.2f", $1/60}')
        if [ "$(echo "$ACTIVE_HOURS > 0" | bc -l 2>/dev/null || echo 0)" -eq 1 ] && [ "$(echo "$MONTH_SPEND > 0" | bc -l 2>/dev/null || echo 0)" -eq 1 ]; then
            WORKING_CPH=$(echo "$MONTH_SPEND $ACTIVE_HOURS" | awk '{printf "%.2f", $1/$2}')
        fi
    elif [ -f "$ACTIVITY_STATE" ]; then
        # Fallback to state file for current activity only
        ACTIVE_MINUTES=$(jq -r '.activeMinutesToday // 0' "$ACTIVITY_STATE" 2>/dev/null || echo "null")
        if [ "$ACTIVE_MINUTES" != "null" ] && [ "$ACTIVE_MINUTES" != "0" ]; then
            ACTIVE_HOURS=$(echo "$ACTIVE_MINUTES" | awk '{printf "%.2f", $1/60}')
        fi
    fi
fi

# Write dashboard JSON with atomic write (write to temp, then move)
TEMP_DASHBOARD="${DASHBOARD_FILE}.tmp"
cat > "$TEMP_DASHBOARD" << EOF
{
  "updated": "$(date -Iseconds)",
  "source": "Admin API (automated)",
  "yesterday": {
    "date": "$LATEST_DATE",
    "costDollars": $TODAY_COST,
    "inputTokens": $LATEST_INPUT,
    "outputTokens": $LATEST_OUTPUT,
    "cacheHitRate": $LATEST_CACHE_RATE
  },
  "currentMonth": {
    "month": "$CURRENT_MONTH",
    "spend": $MONTH_SPEND,
    "limit": 5000,
    "daysElapsed": $DAYS_ELAPSED,
    "avgDailySpend": $AVG_DAILY,
    "projectedMonthly": $PROJECTED,
    "resetDate": "$(date -d "${CURRENT_MONTH}-01 +1 month" +%Y-%m-%d)"
  },
  "allTime": {
    "since": "2026-01-30",
    "totalSpend": $ALL_TIME_SPEND,
    "inputTokens": $ALL_TIME_INPUT,
    "outputTokens": $ALL_TIME_OUTPUT,
    "cacheHitRate": $ALL_TIME_CACHE_RATE
  },
  "daily": $DAILY_DATA,
  "costPerHour": {
    "working": $WORKING_CPH,
    "wallClock": $WALL_CLOCK_CPH,
    "activeMinutesMonth": $ACTIVE_MINUTES,
    "activeHoursMonth": $ACTIVE_HOURS,
    "wallClockHoursMonth": $MONTH_HOURS_ELAPSED,
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
    "projectedOverLimit": $OVER_LIMIT,
    "message": "$ALERT_MSG"
  }
}
EOF

# Validate JSON before moving to final location
if ! jq . "$TEMP_DASHBOARD" > /dev/null 2>&1; then
    error_exit "Generated invalid JSON"
fi

mv "$TEMP_DASHBOARD" "$DASHBOARD_FILE"

# Append to spend log
echo "{\"timestamp\":\"$(date -Iseconds)\",\"monthSpend\":$MONTH_SPEND,\"allTimeSpend\":$ALL_TIME_SPEND,\"avgDaily\":$AVG_DAILY,\"projected\":$PROJECTED}" >> "$SPEND_LOG"

log "Dashboard updated: MTD=\$$MONTH_SPEND, AllTime=\$$ALL_TIME_SPEND, Projected=\$$PROJECTED"

# Alert if projected > 90% of limit
if [ "$OVER_LIMIT" = "true" ]; then
    log "ALERT: $ALERT_MSG"
fi

log "Anthropic dashboard update completed successfully"
