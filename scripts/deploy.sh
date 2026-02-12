#!/bin/bash
# nova-dashboard deployment script
# Called by post-merge hook after git pull

set -e

DASHBOARD_DIR="$HOME/clawd/nova-dashboard"
LOG_FILE="$HOME/clawd/logs/dashboard-deploy.log"
OPENCLAW_TOKEN="${OPENCLAW_TOKEN:-}"
MIGRATE_MODE=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --migrate)
            MIGRATE_MODE=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--migrate]"
            exit 1
            ;;
    esac
done

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

# Migration mode: check for legacy nova_memory database
if [ "$MIGRATE_MODE" = true ]; then
    log "=== MIGRATION MODE ACTIVATED ==="
    
    # Check if legacy nova_memory exists and is different from new name
    if [ "$DB_NAME" != "nova_memory" ]; then
        if psql -lqt 2>/dev/null | cut -d \| -f 1 | grep -qw "nova_memory"; then
            log "Found legacy database: nova_memory"
            log "Target database name: $DB_NAME"
            echo ""
            echo "MIGRATION OPTIONS:"
            echo "  1) Rename nova_memory → $DB_NAME (recommended)"
            echo "  2) Create database alias (view)"
            echo "  3) Skip migration"
            echo ""
            read -p "Choose option (1-3): " migration_choice
            
            case $migration_choice in
                1)
                    log "Renaming database nova_memory → $DB_NAME..."
                    if psql -c "ALTER DATABASE nova_memory RENAME TO $DB_NAME;" 2>&1 | tee -a "$LOG_FILE"; then
                        log "✅ Database renamed successfully"
                    else
                        log "❌ Database rename failed"
                        exit 1
                    fi
                    ;;
                2)
                    log "Creating alias is not supported at database level."
                    log "You can set PGUSER=nova to continue using nova_memory."
                    exit 1
                    ;;
                3)
                    log "Skipping database migration"
                    ;;
                *)
                    log "Invalid choice, exiting"
                    exit 1
                    ;;
            esac
        else
            log "No legacy nova_memory database found"
        fi
        
        # Search for cron references to nova_memory
        log ""
        log "Searching for hardcoded 'nova_memory' references in cron jobs..."
        if grep -r "nova_memory" /etc/cron* ~/clawd/ 2>/dev/null | grep -v "^Binary file"; then
            log "⚠️  Found hardcoded references above. Please update them manually."
            log "See MIGRATION.md for guidance."
        else
            log "No cron references found"
        fi
    else
        log "Database name is already nova_memory (no migration needed)"
    fi
    
    log "=== MIGRATION CHECK COMPLETE ==="
    echo ""
fi

cd "$DASHBOARD_DIR"

log "Starting nova-dashboard deployment..."
log "Commit: $(git rev-parse --short HEAD)"

# Install dependencies if package.json changed
if git diff HEAD~1 --name-only 2>/dev/null | grep -q "package.json"; then
    log "package.json changed, running npm install..."
    npm install
fi

# Restart dashboard service via systemctl
log "Restarting dashboard service..."
if systemctl --user restart nova-dashboard 2>&1 | tee -a "$LOG_FILE"; then
    log "Service restart command completed"
elif systemctl --user start nova-dashboard 2>&1 | tee -a "$LOG_FILE"; then
    log "⚠️ Service restart failed, but start succeeded"
else
    log "⚠️ Warning: systemctl commands failed (service may not exist)"
fi

# Verify it started
sleep 3

# Check systemctl status
if systemctl --user is-active nova-dashboard >/dev/null 2>&1; then
    SERVICE_STATUS="active"
    log "✅ Service is active"
else
    SERVICE_STATUS="inactive"
    log "⚠️ Service is not active"
fi

# Check HTTP health
if curl -s -o /dev/null -w "%{http_code}" http://localhost:3847/ | grep -q "200"; then
    log "✅ Dashboard deployed successfully (HTTP 200)"
else
    log "⚠️ Dashboard may not have started correctly (HTTP check failed)"
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
