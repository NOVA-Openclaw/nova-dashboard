#!/bin/bash
# nova-dashboard deployment script
# Called by post-merge hook after git pull

set -e

DASHBOARD_DIR="$HOME/clawd/nova-dashboard"
LOG_FILE="$HOME/clawd/logs/dashboard-deploy.log"
PID_FILE="$HOME/clawd/nova-dashboard/.dashboard.pid"
OPENCLAW_TOKEN="${OPENCLAW_TOKEN:-}"

log() {
    echo "[$(date -Iseconds)] $1" | tee -a "$LOG_FILE"
}

# Derive database name from OS username
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

cd "$DASHBOARD_DIR"

log "Starting nova-dashboard deployment..."
log "Commit: $(git rev-parse --short HEAD)"

# Install dependencies if package.json changed
if git diff HEAD~1 --name-only 2>/dev/null | grep -q "package.json"; then
    log "package.json changed, running npm install..."
    npm install
fi

# Stop existing process if running
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        log "Stopping existing dashboard (PID $OLD_PID)..."
        kill "$OLD_PID"
        sleep 2
    fi
    rm -f "$PID_FILE"
fi

# Start dashboard
log "Starting dashboard..."
nohup node server.js > "$HOME/clawd/logs/dashboard.log" 2>&1 &
NEW_PID=$!
echo "$NEW_PID" > "$PID_FILE"

# Verify it started (serve dashboard at root for nginx proxy)
sleep 3
if curl -s -o /dev/null -w "%{http_code}" http://localhost:3847/ | grep -q "200"; then
    log "✅ Dashboard deployed successfully (PID $NEW_PID)"
else
    log "⚠️ Dashboard may not have started correctly"
fi

# Notify via agent_chat
COMMIT_HASH=$(git rev-parse --short HEAD)
TIMESTAMP=$(date -Iseconds)
REPO_NAME="nova-dashboard"

# Ensure database exists (create if needed)
if ! psql -lqt 2>/dev/null | cut -d \| -f 1 | grep -qw "$DB_NAME"; then
    log "Database '$DB_NAME' does not exist, creating..."
    if ! createdb "$DB_NAME" 2>&1 | tee -a "$LOG_FILE"; then
        log "ERROR: Failed to create database '$DB_NAME'"
        exit 1
    fi
    log "Database '$DB_NAME' created successfully"
fi

# Insert deployment notification
if ! psql -d "$DB_NAME" -q << EOF
INSERT INTO agent_chat (sender, message, mentions)
VALUES ('system', '$REPO_NAME auto-deployed via post-merge hook.
Commit: $COMMIT_HASH
Time: $TIMESTAMP', ARRAY['NOVA']);
EOF
then
    log "Warning: Failed to insert deployment notification into database (table may not exist yet)"
fi

# Alert NOVA via wake event
ALERT_MESSAGE="🚀 Deployment: $REPO_NAME @ $COMMIT_HASH ($TIMESTAMP)"

if [ -n "$OPENCLAW_TOKEN" ]; then
    if curl -X POST http://localhost:18789/api/cron/wake \
         -H "Authorization: Bearer $OPENCLAW_TOKEN" \
         -H "Content-Type: application/json" \
         -d "{\"text\":\"$ALERT_MESSAGE\",\"mode\":\"now\"}" \
         --max-time 5 --silent --show-error 2>&1; then
        log "Wake alert sent successfully"
    else
        log "Warning: Wake alert failed (non-fatal)"
    fi
else
    log "Warning: OPENCLAW_TOKEN not set, skipping wake alert"
fi

log "Deployment complete"
