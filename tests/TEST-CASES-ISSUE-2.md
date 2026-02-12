## Test Cases for Issue #2: Use OS Username for Database Naming Convention

**Issue:** The dashboard scripts currently hardcode `nova_memory` as the database name. The fix should derive the database name from the OS username using the pattern `DB_NAME="${DB_USER//-/_}_memory"` where `DB_USER="${PGUSER:-$(whoami)}"`

**Files to Update:**
- `scripts/deploy.sh`
- `scripts/update-dashboard-status.sh`

---

### 1. Happy Path Tests

* **TC-02-01:** Default Username (no PGUSER set)
  - Given: No `PGUSER` environment variable is set
  - When: The script is executed
  - Then: Database name derived from `whoami`, hyphens replaced with underscores
  - Example: `whoami` returns `nova-staging` → database `nova_staging_memory`

* **TC-02-02:** PGUSER set
  - Given: `PGUSER` environment variable is set
  - When: The script is executed
  - Then: Database name derived from `PGUSER`, hyphens replaced with underscores
  - Example: `PGUSER=argus-test` → database `argus_test_memory`

---

### 2. Edge Case Tests

* **TC-02-10:** Username with no hyphens
  - Given: Username contains no hyphens
  - Then: Database name is username + `_memory`
  - Example: `nova` → `nova_memory`

* **TC-02-11:** Username with multiple hyphens
  - Given: Username contains multiple hyphens
  - Then: All hyphens replaced with underscores
  - Example: `nova-staging-test` → `nova_staging_test_memory`

* **TC-02-12:** Username with leading/trailing hyphens
  - Given: Username has leading or trailing hyphens
  - Then: Hyphens replaced with underscores
  - Example: `-nova` → `_nova_memory`, `nova-` → `nova__memory`

* **TC-02-13:** Empty PGUSER
  - Given: `PGUSER` is set to empty string
  - Then: Script falls back to `whoami`

* **TC-02-14:** Username with underscores
  - Given: Username contains underscores
  - Then: Underscores preserved
  - Example: `nova_staging` → `nova_staging_memory`

* **TC-02-15:** Invalid PostgreSQL identifier characters
  - Given: `PGUSER` contains characters invalid for PostgreSQL identifiers
  - Then: Script exits with clear error message (not silent transformation)

---

### 3. Error Condition Tests

* **TC-02-30:** `whoami` command fails
  - Given: `whoami` returns non-zero exit code
  - When: Script executed without `PGUSER`
  - Then: Script exits gracefully with error message

* **TC-02-31:** `update-dashboard-status.sh` with non-existent database
  - Given: Derived database does not exist
  - When: `update-dashboard-status.sh` is executed
  - Then: Script exits gracefully with informative error (queries only, doesn't create)

* **TC-02-32:** `deploy.sh` with non-existent database
  - Given: Derived database does not exist
  - When: `deploy.sh` is executed
  - Then: Script CREATES the database (only script that should create)

* **TC-02-33:** Database connection failure
  - Given: Valid database name but PostgreSQL server unreachable
  - Then: Script handles connection error gracefully with informative message

* **TC-02-34:** Invalid PGUSER results in invalid database name
  - Given: `PGUSER` would create invalid PostgreSQL identifier
  - Then: Script validates and exits with informative error

---

### 4. Boundary Value Tests

* **TC-02-40:** Extremely long username
  - Given: Username close to PostgreSQL max identifier length (63 bytes)
  - Then: Script handles gracefully (truncate or error with clear message)

---

### 5. Domain-Specific Scenarios

* **TC-02-50:** Interaction with existing systems
  - Given: Other services rely on hardcoded `nova_memory` database name
  - Then: Update process includes migration steps or documentation for dependent services

* **TC-02-51:** Upgrade from previous versions
  - Given: Existing system uses hardcoded `nova_memory`
  - When: Scripts updated to new convention
  - Then: Upgrade handles migration of existing database (or documents manual steps)

* **TC-02-52:** Multiple dashboard instances
  - Given: Multiple instances on same server with different OS usernames
  - Then: Each instance gets its own database named per its username

* **TC-02-53:** Deploy script idempotency
  - Given: `deploy.sh` run multiple times
  - Then: Second run succeeds without error, existing database unchanged

---

### 6. Script Consistency Tests

* **TC-02-60:** Both scripts derive same database name
  - Given: Identical environment (same user, same PGUSER)
  - When: Both `deploy.sh` and `update-dashboard-status.sh` executed
  - Then: Both scripts target the exact same database

---

**Status:** ✅ Approved by NOVA (2026-02-12)
**Designed by:** Gem (gemini-cli)
**Iterations:** 2
