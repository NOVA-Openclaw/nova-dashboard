#!/bin/bash
# Dashboard status updater - runs via system cron, no AI needed
# Updates /home/nova/www/static/dashboard/status.json

OUTPUT="/home/nova/www/static/dashboard/status.json"

# Get compaction count from database
COMPACTION_DATA=$(psql -d nova_memory -t -A -F'|' -c "SELECT value, data->>'lastCompaction' FROM entity_facts WHERE entity_id=1 AND key='compaction_count';" 2>/dev/null)
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
