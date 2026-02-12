# Database Naming Convention Migration Guide

**Version:** 1.0  
**Last Updated:** 2026-02-12  
**Related Issues:** [#2](https://github.com/NOVA-Openclaw/nova-dashboard/issues/2), [#11](https://github.com/NOVA-Openclaw/nova-dashboard/issues/11)

## Overview

The nova-dashboard now uses **dynamic database naming** based on the OS username instead of a hardcoded `nova_memory` database name. This change enables:

- Multiple agents on the same PostgreSQL server with isolated databases
- Better multi-tenant support
- Consistent naming conventions across environments

### The Change

**OLD Convention (hardcoded):**
```bash
psql -d nova_memory
```

**NEW Convention (dynamic):**
```bash
DB_USER="${PGUSER:-$(whoami)}"
DB_NAME="${DB_USER//-/_}_memory"
psql -d "$DB_NAME"
```

### Database Naming Examples

| OS Username    | PGUSER (if set) | Database Name          |
|----------------|-----------------|------------------------|
| `nova`         | (not set)       | `nova_memory`          |
| `nova-staging` | (not set)       | `nova_staging_memory`  |
| `agent2`        | (not set)       | `agent2_memory`         |
| `agent1`      | (not set)       | `agent1_memory`       |
| `test-user`    | `nova`          | `nova_memory`          |

**Note:** Hyphens in usernames are automatically converted to underscores to comply with PostgreSQL identifier rules.

---

## Quick Start (Upgrading?)

If you already have nova-dashboard installed with the old `nova_memory` database:

```bash
./scripts/deploy.sh --migrate
```

This will guide you through the migration interactively. For detailed manual migration steps, see [Phase 3: Migration](#phase-3-migration) below.

---

## Affected Systems

This change impacts any system or script that references the database by name:

### 1. **Other AI Agents** (any agents sharing the database)
- **Impact:** If they use `nova_memory` directly in connection strings or queries
- **Location:** Agent configuration files, environment variables, connection strings
- **Action Required:** Update to use dynamic naming or set `PGUSER` environment variable

### 2. **Cron Jobs**
- **Impact:** Scheduled scripts that query or update the database
- **Common patterns:**
  - `/etc/cron.d/*` entries
  - `/etc/cron.{daily,hourly,weekly}/*` scripts
  - User crontabs (`crontab -l`)
- **Action Required:** Update scripts to derive database name dynamically

### 3. **External Scripts**
- **Impact:** Backup scripts, monitoring tools, custom utilities
- **Common patterns:**
  - `psql -d nova_memory -c "..."`
  - `pg_dump nova_memory`
  - Shell scripts with hardcoded database references
- **Action Required:** Replace hardcoded references with dynamic derivation

### 4. **Systemd Services**
- **Impact:** Services that connect to the database (e.g., `nova-dashboard.service`)
- **Location:** `/etc/systemd/user/` or `/etc/systemd/system/`
- **Action Required:** Verify service environment variables

### 5. **Documentation & READMEs**
- **Impact:** Setup guides, runbooks, onboarding documentation
- **Action Required:** Update examples to show dynamic naming convention

---

## Step-by-Step Migration Guide

### Phase 1: Discovery (Find What Needs Updating)

#### Step 1.1: Run the Inventory Script

```bash
cd ~/clawd/nova-dashboard
./scripts/find-legacy-refs.sh
```

This script searches:
- All system and user cron jobs
- `~/clawd/` directory
- PostgreSQL commands with `nova_memory`

**Save the output for review:**
```bash
./scripts/find-legacy-refs.sh > /tmp/migration-inventory.txt
```

#### Step 1.2: Check for Legacy Database

```bash
psql -lqt | cut -d \| -f 1 | grep -w "nova_memory"
```

If found, note the database size:
```bash
psql -d nova_memory -c "SELECT pg_size_pretty(pg_database_size('nova_memory'));"
```

#### Step 1.3: Identify Agent Dependencies

For each agent running on this server:
1. Check their config files for database references
2. Verify their username (what does `whoami` return when they run?)
3. Determine if they share the same PostgreSQL server

**Example check for an agent:
```bash
sudo -u agent1 whoami              # Verify username
sudo -u agent1 psql -l             # List databases accessible to agent1
grep -r "nova_memory" /home/agent1 # Search config files
```

---

### Phase 2: Backup (Safety First!)

#### Step 2.1: Backup Existing Database

```bash
# Create backup directory
mkdir -p ~/backups/database-migration
cd ~/backups/database-migration

# Full database backup
pg_dump nova_memory > nova_memory_backup_$(date +%Y%m%d_%H%M%S).sql

# Verify backup
ls -lh nova_memory_backup_*.sql
```

#### Step 2.2: Backup Cron Jobs

```bash
# User crontab
crontab -l > ~/backups/database-migration/crontab_backup_$(date +%Y%m%d_%H%M%S).txt

# System cron jobs (if you have access)
sudo tar czf ~/backups/database-migration/system-cron_backup_$(date +%Y%m%d_%H%M%S).tar.gz /etc/cron.* 2>/dev/null
```

#### Step 2.3: Backup Scripts

```bash
# Backup clawd directory
tar czf ~/backups/database-migration/clawd_backup_$(date +%Y%m%d_%H%M%S).tar.gz ~/clawd/
```

---

### Phase 3: Migration (Apply Changes)

#### Option A: Automated Migration (Recommended for `nova` username)

If your OS username is `nova`, no migration is needed! The database name remains `nova_memory`.

#### Option B: Rename Database (Recommended for other usernames)

```bash
# 1. Determine new database name
DB_USER=$(whoami)
NEW_DB_NAME="${DB_USER//-/_}_memory"
echo "New database name will be: $NEW_DB_NAME"

# 2. Verify you're the only user connected
psql -d nova_memory -c "SELECT * FROM pg_stat_activity WHERE datname = 'nova_memory';"

# 3. Terminate other connections (if needed)
psql -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'nova_memory' AND pid <> pg_backend_pid();"

# 4. Rename the database
psql -c "ALTER DATABASE nova_memory RENAME TO $NEW_DB_NAME;"

# 5. Verify the rename
psql -l | grep "$NEW_DB_NAME"
```

#### Option C: Use PGUSER Environment Variable (Temporary Workaround)

If you can't rename the database yet, set `PGUSER=nova` to force using `nova_memory`:

```bash
# Add to your shell profile
echo 'export PGUSER=nova' >> ~/.bashrc
source ~/.bashrc

# Or set per-script
export PGUSER=nova
./scripts/deploy.sh
```

**Warning:** This is a temporary workaround. Plan to migrate to proper naming convention.

#### Option D: Migrate with deploy.sh --migrate Flag

```bash
cd ~/clawd/nova-dashboard
./scripts/deploy.sh --migrate
```

This interactive mode will:
1. Detect if `nova_memory` exists and differs from the new naming convention
2. Offer to rename the database
3. Search for cron references
4. Guide you through the migration

---

### Phase 4: Update Scripts & Configs

#### Step 4.1: Update Cron Jobs

For each cron entry found in Phase 1, replace hardcoded references:

**Before:**
```bash
*/5 * * * * psql -d nova_memory -c "SELECT update_dashboard_status();" >> /var/log/dashboard.log 2>&1
```

**After (Method 1 - Inline derivation):**
```bash
*/5 * * * * DB_NAME="${PGUSER:-$(whoami)}"; DB_NAME="${DB_NAME//-/_}_memory"; psql -d "$DB_NAME" -c "SELECT update_dashboard_status();" >> /var/log/dashboard.log 2>&1
```

**After (Method 2 - Use updated script):**
```bash
*/5 * * * * ~/clawd/nova-dashboard/scripts/update-dashboard-status.sh >> /var/log/dashboard.log 2>&1
```

Apply changes:
```bash
crontab -e  # Edit and save
```

#### Step 4.2: Update External Scripts

For scripts in `~/clawd/` or elsewhere:

**Before:**
```bash
#!/bin/bash
psql -d nova_memory -c "SELECT * FROM agent_chat LIMIT 10;"
```

**After:**
```bash
#!/bin/bash
# Derive database name
DB_USER="${PGUSER:-$(whoami)}"
DB_NAME="${DB_USER//-/_}_memory"

psql -d "$DB_NAME" -c "SELECT * FROM agent_chat LIMIT 10;"
```

#### Step 4.3: Update Agent Configs

**For other agents sharing the database:

Locate their database configuration:
```bash
# Example locations
~/clawd/agent1/.env
~/clawd/agent1/config.json
~/.openclaw/skills/*/config.yml
```

**Update connection strings:**

Before:
```env
DATABASE_URL=postgresql://localhost/nova_memory
```

After:
```env
# Option 1: Set PGUSER to override
PGUSER=agent1

# Option 2: Use specific database
DATABASE_URL=postgresql://localhost/agent1_memory
```

Restart the agent service:
```bash
systemctl --user restart agent1.service
```

#### Step 4.4: Update Systemd Services

Check service files for database references:
```bash
systemctl --user cat nova-dashboard.service
```

If the service hardcodes `nova_memory`, update it:
```bash
systemctl --user edit nova-dashboard.service
```

Add:
```ini
[Service]
Environment="PGUSER=nova"
```

Reload and restart:
```bash
systemctl --user daemon-reload
systemctl --user restart nova-dashboard.service
```

---

### Phase 5: Verification

#### Step 5.1: Verify Database Connectivity

```bash
# Test connection with new naming
DB_USER=$(whoami)
DB_NAME="${DB_USER//-/_}_memory"

psql -d "$DB_NAME" -c "SELECT 1;"
```

#### Step 5.2: Verify Scripts Run Correctly

```bash
# Test deploy script
cd ~/clawd/nova-dashboard
./scripts/deploy.sh

# Test update script
./scripts/update-dashboard-status.sh
```

Check logs:
```bash
tail -f ~/clawd/logs/dashboard-deploy.log
tail -f ~/clawd/logs/dashboard.log
```

#### Step 5.3: Verify Cron Jobs

```bash
# Check cron logs (varies by system)
grep "dashboard" /var/log/syslog
journalctl --user -u cron.service
```

Or manually trigger a cron job:
```bash
# Copy the command from crontab and run it
/path/to/your/cron-script.sh
```

#### Step 5.4: Verify Other Agents

For each agent (any agents sharing the database):

```bash
# Check service status
systemctl --user status agent1.service

# Check logs
journalctl --user -u agent1.service -n 50

# Test database connectivity as that user
sudo -u agent1 psql -l
```

#### Step 5.5: Run Full System Test

1. Trigger a deployment: `cd ~/clawd/nova-dashboard && git pull`
2. Check dashboard is accessible: `curl http://localhost:3847/`
3. Verify data updates: Watch dashboard for 5-10 minutes
4. Check all agents are responding normally

---

## Rollback Procedures

If something goes wrong, follow these steps to revert:

### Rollback Step 1: Restore Database

```bash
cd ~/backups/database-migration

# Drop the renamed database (if it exists)
psql -c "DROP DATABASE IF EXISTS ${DB_USER//-/_}_memory;"

# Restore from backup
psql -c "CREATE DATABASE nova_memory;"
psql nova_memory < nova_memory_backup_YYYYMMDD_HHMMSS.sql
```

### Rollback Step 2: Restore Cron Jobs

```bash
cd ~/backups/database-migration

# Restore user crontab
crontab crontab_backup_YYYYMMDD_HHMMSS.txt

# Verify
crontab -l
```

### Rollback Step 3: Restore Scripts

```bash
cd ~/backups/database-migration

# Extract backup
tar xzf clawd_backup_YYYYMMDD_HHMMSS.tar.gz -C /tmp/

# Selectively restore modified files
cp /tmp/home/$(whoami)/clawd/path/to/script.sh ~/clawd/path/to/script.sh
```

### Rollback Step 4: Revert nova-dashboard

```bash
cd ~/clawd/nova-dashboard

# Check out previous version (before migration)
git log --oneline  # Find commit before migration
git checkout <commit-hash>

# Redeploy
./scripts/deploy.sh
```

### Rollback Step 5: Verify System Recovery

Follow the verification steps from Phase 5 to ensure everything is back to normal.

---

## Troubleshooting

### Issue: "database does not exist"

**Symptom:**
```
psql: error: connection to server on socket "/var/run/postgresql/.s.PGSQL.5432" failed: FATAL:  database "nova_staging_memory" does not exist
```

**Solution:**
```bash
# Check what database name the script is using
DB_USER="${PGUSER:-$(whoami)}"
DB_NAME="${DB_USER//-/_}_memory"
echo "Expected database: $DB_NAME"

# Create it if missing
createdb "$DB_NAME"

# Or restore from backup
psql -c "CREATE DATABASE $DB_NAME;"
psql "$DB_NAME" < ~/backups/database-migration/nova_memory_backup_*.sql
```

### Issue: Permission denied on database operations

**Symptom:**
```
ERROR:  permission denied to rename database
```

**Solution:**
```bash
# Ensure you're the owner
psql -d postgres -c "ALTER DATABASE nova_memory OWNER TO $(whoami);"

# Or run as postgres user
sudo -u postgres psql -c "ALTER DATABASE nova_memory RENAME TO newname_memory;"
```

### Issue: Active connections prevent rename

**Symptom:**
```
ERROR:  database "nova_memory" is being accessed by other users
```

**Solution:**
```bash
# Find active connections
psql -d postgres -c "SELECT pid, usename, application_name FROM pg_stat_activity WHERE datname = 'nova_memory';"

# Terminate them (carefully!)
psql -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'nova_memory' AND pid <> pg_backend_pid();"

# Retry rename
psql -c "ALTER DATABASE nova_memory RENAME TO ${DB_USER//-/_}_memory;"
```

### Issue: Cron jobs still failing after migration

**Symptom:**
Cron logs show database connection errors after migration.

**Solution:**
```bash
# 1. Check crontab syntax
crontab -l | grep -i database

# 2. Test the command manually
/path/to/cron-script.sh

# 3. Check cron environment
# Add to crontab for debugging:
* * * * * env > /tmp/cron-env.txt

# Compare with your shell environment
env | sort > /tmp/shell-env.txt
diff /tmp/cron-env.txt /tmp/shell-env.txt
```

### Issue: Multiple agents on same server

**Symptom:**
other agents sharing the database need separate databases, but both scripts use `whoami`.

**Solution:**
Each agent should:
1. Run as a separate OS user (already the case)
2. Get their own database: `agent1_memory`, `agent2_memory`
3. Use the updated scripts that derive DB name from their username

**Verify:**
```bash
# As agent1 user
sudo -u agent1 bash -c 'echo "Username: $(whoami)"; DB_NAME="$(whoami)"; DB_NAME="${DB_NAME//-/_}_memory"; echo "Database: $DB_NAME"'

# As agent2 user
sudo -u agent2 bash -c 'echo "Username: $(whoami)"; DB_NAME="$(whoami)"; DB_NAME="${DB_NAME//-/_}_memory"; echo "Database: $DB_NAME"'
```

---

## Best Practices

### For New Installations

1. **Use dynamic naming from the start** - Don't hardcode `nova_memory`
2. **Set PGUSER consistently** - If you must override, set it in shell profile
3. **Document your setup** - Note which agents use which databases
4. **Test before production** - Run migration on staging environment first

### For Multi-Agent Environments

1. **One database per agent** - Use separate OS users and databases
2. **Shared schema pattern** - If agents must share data, use PostgreSQL schemas:
   ```sql
   CREATE SCHEMA IF NOT EXISTS shared;
   GRANT USAGE ON SCHEMA shared TO agent1, agent2;
   ```
3. **Connection pooling** - For high-traffic scenarios, use PgBouncer

### For Maintenance

1. **Backup before changes** - Always backup before migrations
2. **Test in staging** - Validate migration steps on test environment
3. **Monitor after changes** - Watch logs for 24-48 hours post-migration
4. **Document deviations** - If you use non-standard setup, document it

---

## Quick Reference

### Derive Database Name (Shell)

```bash
DB_USER="${PGUSER:-$(whoami)}"
DB_NAME="${DB_USER//-/_}_memory"
echo "$DB_NAME"
```

### Check Current Database

```bash
psql -l | grep memory
```

### Test Connection

```bash
DB_USER="${PGUSER:-$(whoami)}"
DB_NAME="${DB_USER//-/_}_memory"
psql -d "$DB_NAME" -c "SELECT current_database();"
```

### Find All References

```bash
cd ~/clawd/nova-dashboard
./scripts/find-legacy-refs.sh
```

### Force Use of nova_memory

```bash
export PGUSER=nova
# Now all scripts will use nova_memory
```

---

## Support & Feedback

- **Issues:** [GitHub Issues](https://github.com/NOVA-Openclaw/nova-dashboard/issues)
- **Documentation:** [README.md](README.md)
- **Related:** [IMPLEMENTATION-ISSUE-2.md](IMPLEMENTATION-ISSUE-2.md)

---

**Document Version:** 1.0  
**Last Updated:** 2026-02-12  
**Maintainer:** NOVA (nova@dustintrammell.com)
