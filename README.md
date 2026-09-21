# NOVA Dashboard

A lightweight, real-time status dashboard for AI agents running on [OpenClaw](https://github.com/openclaw/openclaw) (formerly Clawdbot).

## Features

- **Gateway & Channel Status**: Three-tier display (🟢 Online / 🟡 Running / 🔴 Offline) with per-channel breakdown
- **Agent Status**: Context window usage, compaction count, model info
- **Staff Roster**: Active agents and their status, powered by database
- **Anthropic API Costs**: Daily spend, monthly projections, budget alerts
- **System Stats**: CPU, memory, disk, load average, top processes
- **PostgreSQL Stats**: Database size, cache hit ratio, table breakdown
- **Auto-refresh**: Updates every 5 minutes
- **Mobile-friendly**: Responsive design

## Architecture

```
nova-dashboard/
├── dashboard/
│   └── index.html          # The dashboard UI (single-file frontend)
├── scripts/
│   ├── update-dashboard.sh # Consolidated cron script — updates all JSON data files
│   └── lib/
│       └── node-resolve.sh # Resolves a supported node/openclaw binary explicitly (PATH-ordering guard)
├── nginx/
│   └── reports.conf        # Nginx config for reports endpoint
├── server.js               # Express + WebSocket server (serves dashboard/)
├── system.example.json     # Example schema for system.json
├── status.example.json     # Example schema for status.json
└── anthropic.example.json  # Example schema for anthropic.json
```

The Node.js server (`server.js`) serves files from the `dashboard/` directory. The frontend (`dashboard/index.html`) reads JSON data files from the server's static data path and displays them in real-time.

## Setup

### 1. Clone and install

```bash
git clone https://github.com/NOVA-Openclaw/nova-dashboard.git
cd nova-dashboard
npm install
```

### 2. Copy example configs

```bash
cp status.example.json /path/to/data/status.json
cp anthropic.example.json /path/to/data/anthropic.json
cp system.example.json /path/to/data/system.json
```

The data path defaults to `$HOME/www/static/dashboard/`. See [Configuration](#configuration).

### 3. Start the server

```bash
PORT=3847 node server.js
```

### 4. Set up the cron job

Install the update script and add a single cron entry:

```bash
# Copy to your preferred scripts location
cp scripts/update-dashboard.sh /path/to/scripts/update-dashboard.sh
chmod +x /path/to/scripts/update-dashboard.sh

# Add to crontab (runs every 5 minutes)
crontab -e
```

Add this line:

```cron
*/5 * * * * /path/to/scripts/update-dashboard.sh >> /var/log/dashboard-cron.log 2>&1
```

The Anthropic section throttles itself internally to 15-minute intervals — a single 5-minute cron entry handles everything.

### 5. (Optional) Add nginx proxy with basic auth

See `nginx/reports.conf` for an example nginx configuration.

## JSON Data Sources

The dashboard reads five JSON files populated by `scripts/update-dashboard.sh`:

| File | Description | Update Interval |
|------|-------------|-----------------|
| `system.json` | Gateway status, channels, system metrics | Every 5 min |
| `status.json` | Agent context, compaction count, model | Every 5 min |
| `staff.json` | Active agents from database, Newhart status | Every 5 min |
| `postgres.json` | Database size, stats, table breakdown | Every 5 min |
| `anthropic.json` | API cost tracking, token usage | Every 15 min (throttled) |

### Gateway & Channel Status Model

`system.json` now includes gateway and per-channel status:

```json
{
  "gateway": "running",
  "healthState": "ok",
  "healthError": null,
  "channels": {
    "slack":    { "status": "online", "latencyMs": 32, "bot": "mybot", "team": "My Team" },
    "telegram": { "status": "online", "latencyMs": 386, "bot": "@example_bot" },
    "signal":   { "status": "offline" }
  }
}
```

**Gateway values:** `"running"` | `"stopped"`  
**Channel values:** `"online"` | `"offline"`

The frontend derives a three-tier display from these values:
- 🟢 **Online** — gateway running AND at least one channel online
- 🟡 **Running** — gateway running but no channels online
- 🔴 **Offline** — gateway stopped

Data comes from `openclaw health --json`. See `system.example.json` for the full schema.

#### `healthState` / `healthError` — fail-loud health semantics

`healthState` and `healthError` distinguish a real measurement from a failed query, so a blanked payload is never indistinguishable from a genuinely empty one:

| `healthState` | `channels` | `healthError` | Meaning |
|---------------|------------|----------------|---------|
| `"ok"` | object (real measurement) | `null` | `openclaw health --json` succeeded and was parsed |
| `"unknown"` | `null` (never `{}`) | populated with the reason | The health query failed — non-zero exit, empty stdout, or unparseable JSON |

When `healthState` is `"unknown"`, `gateway` may still report `"running"` — that value comes from a `pgrep` liveness check on the `openclaw-gateway` process, **not** from the health query. It is a liveness hint only and must never be treated as confirmation that channel data is accurate. `channels` is explicitly `null` (not `{}`) in this state so consumers can tell "no data" apart from "zero channels configured."

## The Update Script

`scripts/update-dashboard.sh` is the single consolidated script that replaces five separate scripts previously used. It handles all five data sources in one run, with each section isolated so a failure in one doesn't break the others.

`scripts/update-anthropic-dashboard.sh` is a thin backward-compatible wrapper that execs `update-dashboard.sh --anthropic-only`. It exists so cron entries still pointing at the old filename keep working, while the Anthropic-cost logic has a single source of truth in `update-dashboard.sh`. Use `--sections=comma,list` (e.g. `--sections=system,status`) or `--anthropic-only` to run a subset of sections manually; see `./scripts/update-dashboard.sh --help` for the full option list.

### What it does

| Section | Output | Notes |
|---------|--------|-------|
| `update_system()` | `system.json` | Calls `openclaw health --json`, reads `/proc` |
| `update_status()` | `status.json` | Queries PostgreSQL for compaction data |
| `update_staff()` | `staff.json` | Queries `agents` table, checks Newhart port |
| `update_postgres()` | `postgres.json` | Reads `pg_stat_database`, table sizes |
| `update_anthropic()` | `anthropic.json` | Calls Anthropic Admin API via 1Password |

### Requirements

- `jq` — JSON processing
- `psql` — PostgreSQL client
- `curl` — HTTP requests (Anthropic API)
- `openclaw` — For gateway/channel health check, plus a Node.js runtime satisfying OpenClaw's `engines` range (`>=22.22.3 <23`, `>=24.15.0 <25`, or `>=25.9.0`)
- `op` (1Password CLI) — For Anthropic API key retrieval (anthropic section only)

### Node.js / openclaw binary resolution (PATH-ordering guard)

`scripts/lib/node-resolve.sh` explicitly resolves a supported Node.js runtime and the `openclaw` binary before calling `openclaw health --json`. This exists because on hosts where an unsupported Node install (e.g. linuxbrew's node) sits earlier in `PATH` than the system node, `openclaw health --json` would exit with no usable output and no visible error — a plausible-looking but wrong dashboard state (see issues #37/#38).

Resolution order for `resolve_supported_node()`:
1. `NODE_BIN` environment variable, if set (operator override — must point to an executable satisfying the supported version range)
2. `node` currently on `PATH`, if its version is supported
3. Well-known install paths: `/usr/bin/node`, `/usr/local/bin/node`, `/opt/node/bin/node`
4. `nvm` installs under `$HOME/.nvm/versions/node` (newest version first)

Resolution order for `resolve_openclaw_bin()`:
1. `OPENCLAW_BIN` environment variable, if set (operator override)
2. `openclaw` on `PATH`
3. `$HOME/.npm-global/bin/openclaw`

If no supported node or no `openclaw` binary can be found, `update_system()` aborts the `system.json` update and logs an error — it does **not** fall back to a silently blanked payload.

**Operator overrides:**

```bash
# Force a specific node interpreter (e.g. for unusual installs or testing)
export NODE_BIN=/opt/node/bin/node

# Force a specific openclaw executable
export OPENCLAW_BIN=/custom/path/to/openclaw
```

### Configuration

Set `NOVA_DASHBOARD_DIR` to override the default output directory:

```bash
export NOVA_DASHBOARD_DIR=/custom/path/to/dashboard/data
```

Default: `$HOME/www/static/dashboard`

### Install pattern

The script lives in the repo at `scripts/update-dashboard.sh` and gets copied to a production path (e.g., `~/scripts/`) for cron use. This keeps the source of truth in version control while the deployed copy runs independently.

## Production Deployment (NOVA)

**Server details:**
- Service: `nova-dashboard.service` (systemd --user)
- Port: 3847 (proxied via nginx)
- Data: `$HOME/www/static/dashboard/*.json`

### Deploying changes

```bash
# Pull latest
cd /path/to/nova-dashboard
git pull

# The post-merge hook runs deploy.sh automatically.
# To deploy manually:
./scripts/deploy.sh

# Restart the service
systemctl --user restart nova-dashboard

# Check status
systemctl --user status nova-dashboard

# View logs
journalctl --user -u nova-dashboard -f
```

### Making frontend changes

The dashboard frontend is a single file: `dashboard/index.html`. Edit it directly — no build step required.

```bash
# Edit the frontend
nano dashboard/index.html

# Restart service to pick up changes (if server caches files)
systemctl --user restart nova-dashboard

# Commit
git add dashboard/index.html
git commit -m "feat: description"
git push
```

## Customization

- Replace `dashboard/avatar.png` with your agent's avatar
- Replace `favicon.png` with your preferred icon
- Edit CSS variables in `dashboard/index.html` for theming

## Security

⚠️ **Never commit credentials!** The `.gitignore` excludes:
- `.htpasswd` (basic auth credentials)
- `.htaccess` (server config)
- Runtime JSON files (may contain sensitive data)

**Architecture principle:** The dashboard is a static HTML page that reads from external JSON files. Credentials are NEVER in source code — they're in:
- Server-side scripts that populate JSON files
- `.htpasswd` for basic auth (gitignored)
- 1Password (for Anthropic API key)

## Contributing

### Security requirements

This repo uses a **pre-commit hook** that automatically scans for secrets:

```bash
# The hook runs automatically on commit and checks for:
# - API keys (sk-ant-*, sk-*, AKIA*)
# - Password/secret strings
# - Forbidden files (.htpasswd, .htaccess, runtime JSONs)
```

### Before committing

1. Run `git status` — ensure no `.htpasswd`, `.htaccess`, or `*.json` (non-example) files are staged
2. The pre-commit hook will block suspicious patterns
3. If blocked, review and remove secrets before retrying

### If you accidentally commit a secret

1. **Immediately rotate the credential** (it's already compromised)
2. Use [BFG Repo-Cleaner](https://rtyley.github.io/bfg-repo-cleaner/) to purge from history
3. Force-push the cleaned history
4. Notify maintainers

## Database Naming

The update script derives the PostgreSQL database name dynamically from the OS username:

```
username → username_memory
nova     → nova_memory
```

See [MIGRATION.md](MIGRATION.md) for migration guidance when upgrading from the hardcoded `nova_memory` convention.

## License

MIT License — use freely, attribution appreciated.

## Credits

Created by [NOVA](https://nova.dustintrammell.com) ✨

Built for use with [OpenClaw](https://openclaw.ai) (formerly Clawdbot) by [Trammell Ventures](https://trammellventures.com).
