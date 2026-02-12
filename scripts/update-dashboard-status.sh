#!/bin/bash
# Dashboard status updater - runs via system cron, no AI needed
# Updates /home/nova/www/static/dashboard/status.json

OUTPUT="/home/nova/www/static/dashboard/status.json"

# Derive database name from OS username (same logic as deploy.sh)
derive_db_name() {
    # Use PGUSER if set and non-empty, otherwise fall back to whoami
    if [ -n "${PGUSER:-}" ]; then
        DB_USER="$PGUSER"
    else
        if ! DB_USER=$(whoami 2>&1); then
            echo "ERROR: Failed to determine username (whoami failed)" >&2
            exit 1
        fi
    fi
    
    # Replace hyphens with underscores
    local db_base="${DB_USER//-/_}"
    DB_NAME="${db_base}_memory"
    
    # Validate PostgreSQL identifier (alphanumeric, underscore, max 63 bytes, no leading digit restriction for our use)
    # PostgreSQL identifiers: start with letter or underscore, contain letters, digits, underscores
    if ! echo "$DB_NAME" | grep -qE '^[a-zA-Z_][a-zA-Z0-9_]*$'; then
        echo "ERROR: Derived database name '$DB_NAME' contains invalid characters for PostgreSQL identifier" >&2
        echo "Username '$DB_USER' must contain only alphanumeric characters, hyphens, and underscores" >&2
        exit 1
    fi
    
    # Check length (PostgreSQL max identifier length is 63 bytes)
    if [ ${#DB_NAME} -gt 63 ]; then
        echo "ERROR: Derived database name '$DB_NAME' exceeds PostgreSQL maximum identifier length (63 bytes)" >&2
        exit 1
    fi
    
    echo "$DB_NAME"
}

# Get database name
DB_NAME=$(derive_db_name)

# Check if database exists (exit gracefully if not - this script only queries, doesn't create)
if ! psql -lqt 2>/dev/null | cut -d \| -f 1 | grep -qw "$DB_NAME"; then
    echo "Database '$DB_NAME' does not exist. Run deploy.sh first to create it." >&2
    exit 1
fi

# Get compaction count from database
COMPACTION_DATA=$(psql -d "$DB_NAME" -t -A -F'|' -c "SELECT value, data->>'lastCompaction' FROM entity_facts WHERE entity_id=1 AND key='compaction_count';" 2>/dev/null)
COMPACTIONS=$(echo "$COMPACTION_DATA" | cut -d'|' -f1 | tr -d ' ')
LAST_COMPACTION=$(echo "$COMPACTION_DATA" | cut -d'|' -f2)

# Default values if query fails
COMPACTIONS=${COMPACTIONS:-0}
if [ -z "$LAST_COMPACTION" ] || [ "$LAST_COMPACTION" = "" ]; then
    LAST_COMPACTION="null"
else
    LAST_COMPACTION="\"$LAST_COMPACTION\""
fi

# Get current timestamp
UPDATED=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Context info - we can't easily get this without the gateway, so use placeholder
# The dashboard JS can handle missing/stale context gracefully
# For accurate context, we'd need to query the gateway API
CONTEXT_USED=0
CONTEXT_TOTAL=200000
CONTEXT_PERCENT=0

# Write JSON
cat > "$OUTPUT" << EOF
{
  "context": {
    "used": $CONTEXT_USED,
    "total": $CONTEXT_TOTAL,
    "percent": $CONTEXT_PERCENT
  },
  "compactions": $COMPACTIONS,
  "model": "anthropic/claude-opus-4-5",
  "lastCompaction": $LAST_COMPACTION,
  "updated": "$UPDATED",
  "session": "agent:main:main",
  "source": "cron"
}
EOF

echo "Dashboard updated at $UPDATED"
