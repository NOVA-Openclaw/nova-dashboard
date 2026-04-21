# NOVA Dashboard Architecture

## Overview

NOVA Dashboard is a real-time monitoring dashboard for the NOVA multi-agent system. It provides a web interface displaying system metrics, agent status, Anthropic API costs, and PostgreSQL statistics. The dashboard follows a **hybrid polling + WebSocket** architecture, where a consolidated cron script updates JSON data files on disk, and a lightweight Node.js server serves those files via HTTP and WebSocket push.

### System Diagram (ASCII)

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                               External Data Sources                             │
├──────────┬─────────────┬────────────────┬─────────────┬────────────────────────┤
│OpenClaw  │   System    │   PostgreSQL   │ Anthropic   │  Agent Chat & Logs     │
│gateway   │   (/proc)   │    (nova_      │ Admin API   │  (future integrations) │
│(health)  │             │    memory)     │             │                        │
└─────┬────┴──────┬──────┴────────┬───────┴──────┬──────┴────────────────────────┘
      │           │                │              │
      │           │                │              │
      │           │                │              │
      ▼           ▼                ▼              ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                        Consolidated Cron Script                                 │
│                         update-dashboard.sh                                     │
│                                                                                 │
│ ┌──────────────┐ ┌────────────┐ ┌────────────┐ ┌──────────────┐ ┌────────────┐ │
│ │  System      │ │   Status   │ │   Staff    │ │ PostgreSQL   │ │ Anthropic  │ │
│ │ (system.json)│ │(status.json│ │(staff.json)│ │(postgres.json│ │(anthropic. │ │
│ │              │ │            │ │            │ │              │ │  json)     │ │
│ └──────┬───────┘ └─────┬──────┘ └─────┬──────┘ └──────┬───────┘ └─────┬──────┘ │
└────────┼───────────────┼───────────────┼───────────────┼───────────────┼────────┘
         │               │               │               │               │
         └───────────────┼───────────────┼───────────────┼───────────────┘
                         │               │               │
                ┌────────▼───────────────▼───────────────▼───────────────┐
                │              JSON Data Directory                       │
                │              /home/nova/www/static/dashboard/          │
                └────────────────────────┬───────────────────────────────┘
                                         │
                                         │
┌────────────────────────────────────────▼───────────────────────────────────────┐
│                             Node.js Server (server.js)                         │
│   ┌──────────────────────────────────────────────────────────────────────┐    │
│   │ Express: serves static files (dashboard/index.html) & JSON endpoints │    │
│   └──────────────────────────────────────────────────────────────────────┘    │
│   ┌──────────────────────────────────────────────────────────────────────┐    │
│   │ WebSocket server: watches JSON files and pushes updates to clients   │    │
│   │ (currently backend-only; frontend uses polling)                      │    │
│   └──────────────────────────────────────────────────────────────────────┘    │
└────────────────────────────────────────┬───────────────────────────────────────┘
                                         │
                                         │
                                         ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                               Browser Client                                    │
│                               dashboard/index.html                              │
│                                                                                 │
│   ┌──────────────────────────────────────────────────────────────────────┐     │
│   │ Polling (fetch every 5 min): system.json, status.json, staff.json,   │     │
│   │ postgres.json, anthropic.json, processes.json, reports.json          │     │
│   └──────────────────────────────────────────────────────────────────────┘     │
│   ┌──────────────────────────────────────────────────────────────────────┐     │
│   │ WebSocket client (future) – not yet implemented                      │     │
│   └──────────────────────────────────────────────────────────────────────┘     │
└─────────────────────────────────────────────────────────────────────────────────┘
```

## Data Flow

Each dashboard panel receives data from a specific JSON file, which is produced by a dedicated section of the `update-dashboard.sh` cron script.

| Panel | JSON File | Data Source | Update Frequency |
|-------|-----------|-------------|------------------|
| **Gateway & Channels** | `system.json` | `openclaw health --json`, `/proc`, `free`, `df`, `nproc`, `ip route` | 5 minutes |
| **Agent Status** | `status.json` | PostgreSQL `entity_facts` table (`compaction_count`), `~/.openclaw/openclaw.json` | 5 minutes |
| **Staff Roster** | `staff.json` | PostgreSQL `agents` table, HTTP health check (`localhost:18800`) | 5 minutes |
| **PostgreSQL Stats** | `postgres.json` | `pg_stat_database`, `pg_tables`, `pg_database_size()` | 5 minutes |
| **Anthropic Costs** | `anthropic.json` | Anthropic Admin API (via 1Password), `session-activity.jsonl` | 15 minutes (throttled) |
| **Top Processes** | `processes.json` | `ps aux` (server-side endpoint) | On-demand (panel refresh) |
| **Reports** | `reports.json` | Static file (future integration) | Varies |

### System (`system.json`)

- **Writer:** `update_system()` in `update-dashboard.sh`
- **Schema:** See `system.example.json`. Contains gateway status (`running`/`stopped`), per‑channel status (`online`/`offline`), system metrics (uptime, load, memory, disk, network).
- **Reader:** `dashboard/index.html` → `loadSystem()` function.
- **Details:** The gateway status is derived from `openclaw health --json`; if that fails, falls back to process detection. Channels are mapped from the health probe response. System metrics are gathered directly from `/proc` and standard Linux utilities.

### Agent Status (`status.json`)

- **Writer:** `update_status()`.
- **Schema:** See `status.example.json`. Includes context window usage (currently static), compaction count (from `entity_facts`), model name (from `openclaw.json`), and the current session identifier.
- **Reader:** `loadStatus()`.
- **Note:** Context usage is not yet live‑tracked; the fields are placeholders for future integration.

### Staff (`staff.json`)

- **Writer:** `update_staff()`.
- **Schema:** Contains `newhart` (standalone NOVA instance) status and an array of active agents from the `agents` table.
- **Reader:** `loadStaff()`.
- **Integration:** Newhart is checked via HTTP health check on port 18800; agents are queried from PostgreSQL.

### PostgreSQL (`postgres.json`)

- **Writer:** `update_postgres()`.
- **Schema:** Database size, connection count, cache‑hit ratio, transaction commits/rollbacks, tuple statistics, and the 20 largest tables with row counts.
- **Reader:** `loadPostgres()`.

### Anthropic Costs (`anthropic.json`)

- **Writer:** `update_anthropic()`.
- **Schema:** The most complex file; includes month‑to‑date spend, daily breakdown, projections, token usage, cache‑hit rate, and cost‑per‑hour calculations based on tracked activity.
- **Reader:** `loadAnthropic()`.
- **Throttling:** The script skips the Anthropic API calls if the file is less than 15 minutes old (the API data only updates every ~15 minutes anyway).

### Processes (`processes.json`)

- **Writer:** Not a file; an on‑the‑fly endpoint (`GET /processes.json`) provided by `server.js`.
- **Reader:** `loadProcesses()` fetches this endpoint with query parameters (`sortBy=cpu|memory`, `limit=5`).
- **Implementation:** The endpoint runs `ps aux` and returns the top processes in JSON format.

### Reports (`reports.json`)

- **Writer:** Not currently automated; intended for future integration with daily digest and communication summaries.
- **Reader:** `loadReports()`.
- **Nginx role:** The `nginx/reports.conf` config maps the `/reports/` URL to a static directory where such reports could be placed.

## WebSocket + Polling Hybrid Model

- **WebSocket server:** `server.js` sets up a `ws` server that watches the JSON data files with `chokidar`. When any of `status.json`, `system.json`, `anthropic.json`, or `staff.json` changes, it broadcasts the new data to all connected WebSocket clients.
- **Current frontend:** The dashboard (`index.html`) does **not** yet implement a WebSocket client. Instead, it uses **polling**:
  - Initial page load fetches all JSON files.
  - `setInterval(refreshAll, 300000)` re‑fetches everything every 5 minutes (matching the cron interval).
- **Why hybrid?** The WebSocket infrastructure is in place for future low‑latency push updates (e.g., when a new agent comes online). The polling fallback ensures the dashboard works even if WebSocket connections fail, and it keeps the frontend simple.

## JSON Data File Contract

Each JSON file is written atomically (to a `.tmp` file then `mv`) to prevent partial reads. The frontend expects the exact schema described in the corresponding `.example.json` files. Missing fields are handled gracefully with fallback values.

**Common fields:**
- `updated` (ISO‑8601 timestamp) – when the data was generated.
- `source` (optional) – where the data came from (e.g., `"Admin API (automated)"`).

**Location:** All JSON files are stored in `DATA_DIR` (default: `/home/nova/www/static/dashboard/`). The directory is configurable via the `NOVA_DASHBOARD_DIR` environment variable in the cron script.

## Risk Analysis Feature

The repository description mentions “risk analysis,” but this feature is **not currently implemented** in the codebase. There is no dedicated risk‑assessment logic, panel, or data source. Future implementations could use the existing data (gateway status, channel outages, high API spend) to compute a risk score and display it as an additional dashboard panel.

## Activity Feed

Similarly, an “activity feed” is referenced but not yet built. The dashboard includes placeholder cards for “Daily Activity Digest” and “Communications Digest” that read from `reports.json`. These are intended to surface summaries from agent logs, chat transcripts, or external communications—future integration points.

## Cron Integration

- **Single cron entry:** `*/5 * * * *` runs `update-dashboard.sh` every 5 minutes.
- **Internal throttling:** The Anthropic section skips its API calls if `anthropic.json` is less than 15 minutes old, avoiding unnecessary requests and respecting API reporting latency.
- **Isolation:** Each section (`update_system`, `update_status`, etc.) runs in a subshell, so a failure in one does not prevent the others from updating.
- **Locking:** The script uses `flock` to prevent concurrent executions.

## Nginx `reports.conf` Role

The provided nginx configuration (`nginx/reports.conf`) maps the `/reports/` URL path to a static directory (`/home/nova/www/static/reports/`). This is intended to serve generated report files (e.g., PDF digests) that can be linked from the dashboard. The dashboard’s reports panel checks for the existence of these files via `reports.json`.

## Integration Points with the NOVA Ecosystem

- **OpenClaw gateway:** The `system.json` section calls `openclaw health --json` to obtain gateway and channel status.
- **PostgreSQL (`nova_memory`):** Used by `status.json`, `staff.json`, and `postgres.json` to query agent facts, agent list, and database statistics.
- **Agent chat (future):** Could be integrated to display recent conversations or agent‑to‑agent messages in an activity feed.
- **1Password CLI:** The Anthropic section uses `op` to retrieve the Anthropic Admin API key securely.
- **Session activity logs:** `session-activity.jsonl` is read to compute “working” cost‑per‑hour metrics.

## Extending: Adding a New Panel

To add a new data panel to the dashboard:

1. **Create a new JSON data source:**
   - Add a new section in `update-dashboard.sh` (e.g., `update_newpanel()`) that writes to `$OUTPUT_DIR/newpanel.json`.
   - Follow the atomic write pattern (`tmp` file → `mv`).
   - Include an `updated` timestamp.

2. **Add a corresponding example file:**
   - `cp newpanel.example.json` with the expected schema.

3. **Extend the server (optional):**
   - If you want the new file to be served via a dedicated endpoint, add a route in `server.js` (e.g., `app.get('/newpanel.json', ...)`).
   - Add the file to the `chokidar` watch list if WebSocket pushes are desired.

4. **Update the frontend:**
   - Add HTML markup for the new panel in `dashboard/index.html`.
   - Write a JavaScript loader function (`loadNewpanel()`) that fetches `newpanel.json` and updates the DOM.
   - Call the loader in `refreshAll()` and in the initial load.

5. **Update cron dependencies:**
   - Ensure any new command‑line tools required by the new section are installed and available in the cron environment.

## Security Considerations

- **No credentials in source:** API keys are retrieved via 1Password; database credentials come from the environment or `.pgpass`.
- **Git‑ignored data files:** Runtime JSON files are excluded from version control (see `.gitignore`).
- **Pre‑commit hooks:** The repository includes a secret‑scanning hook that blocks commits of API keys, passwords, and sensitive files.
- **Static serving:** The dashboard is a static HTML file; all logic runs client‑side or in the cron script. The Node.js server only serves static content and WebSocket connections.

## Deployment

- **Systemd service:** The dashboard server runs as a user‑level systemd service (`nova-dashboard.service`).
- **Deployment script:** `scripts/deploy.sh` handles updates (pulls git, restarts service).
- **Configuration:** The output directory can be changed via the `NOVA_DASHBOARD_DIR` environment variable.

## Future Directions

- **WebSocket client:** Implement real‑time updates in the frontend to eliminate the 5‑minute polling lag.
- **Risk analysis panel:** Compute a risk score based on system health, channel outages, and spending anomalies.
- **Activity feed:** Ingest agent‑chat logs or external communications to show a timeline of recent events.
- **Live context‑window tracking:** Replace the static context‑window placeholder with live data from the agent runtime.
- **Multi‑instance support:** Extend the staff panel to show status of multiple NOVA instances (beyond Newhart).

---
*Generated during D100 idle task — Roll #96: "Have Scribe document an undocumented project"*