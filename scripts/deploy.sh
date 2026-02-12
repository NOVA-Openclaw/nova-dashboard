#!/bin/bash
# nova-dashboard deployment script
# Called by post-merge hook after git pull

set -e

DASHBOARD_DIR="$HOME/clawd/nova-dashboard"
LOG_FILE="$HOME/clawd/logs/dashboard-deploy.log"
PID_FILE="$HOME/clawd/nova-dashboard/.dashboard.pid"

log() {
    echo "[$(date -Iseconds)] $1" | tee -a "$LOG_FILE"
}

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
psql -d nova_memory -q << EOF
INSERT INTO agent_chat (sender, message, mentions)
VALUES ('system', 'nova-dashboard auto-deployed via post-merge hook.
Commit: $(git rev-parse --short HEAD)
Time: $(date -Iseconds)', ARRAY['NOVA']);
EOF

log "Deployment complete"
