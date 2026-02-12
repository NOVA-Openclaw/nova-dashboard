# Test Cases for Issue #11: Database Naming Convention Migration

## 1. Documentation Completeness and Correctness

### 1.1. Affected Systems Coverage

*   **Test Case 1.1.1:** Verify that the documentation explicitly mentions and provides migration guidance for:
    *   Other agents (Newhart, Argus) using the memory schema.
    *   Cron jobs referencing `nova_memory`.
    *   External scripts using `psql -d nova_memory`.
*   **Test Case 1.1.2:** For each affected system, verify that the documentation provides:
    *   Specific steps to identify existing dependencies on `nova_memory`.
    *   Detailed instructions on how to update these dependencies to use the new naming convention.
    *   Examples of the necessary changes (e.g., updated connection strings, modified SQL queries).
*   **Test Case 1.1.3:** Verify that the documentation includes a clear explanation of the new naming convention and how it works.

### 1.2. Verification Methods

*   **Test Case 1.2.1:**  Verify that the documentation describes how to validate that the migration was successful for each affected system.
    *   For example, how to check that Newhart and Argus are correctly accessing the migrated database.
    *   How to confirm that cron jobs are running correctly with the updated database connection.
    *   How to verify that external scripts can connect to the database using the new naming convention.
*   **Test Case 1.2.2:**  Verify that the documentation includes instructions on how to monitor the system after the migration to ensure that no unexpected issues arise.

### 1.3. Rollback Procedures

*   **Test Case 1.1.14:** Documentation includes a checklist/inventory script that finds all hardcoded `nova_memory` references in a given directory (helps users audit their own systems)

*   **Test Case 1.3.1:**  Verify that the documentation provides clear and concise instructions on how to roll back to the previous database naming convention in case of failure.
*   **Test Case 1.3.2:**  Verify that the rollback instructions include:
    *   Steps to revert any changes made to affected systems (agents, cron jobs, scripts).
    *   Instructions on how to restore the original `nova_memory` database (e.g., from a backup).
    *   Considerations for data loss during rollback.

## 2. Migration Script/Flag Testing (Assuming a `--migrate` flag is added)

### 2.1. Basic Migration

*   **Test Case 2.1.1:**  Run the migration script/flag (`--migrate`) on a test environment with a database using the old naming convention (`nova_memory`).
    *   Verify that the script completes successfully without errors.
    *   Verify that the database is correctly migrated to the new naming convention.
    *   Verify that all data is preserved during the migration.
*   **Test Case 2.1.2:**  After the migration, verify that all affected systems (agents, cron jobs, scripts) can connect to the database using the new naming convention.

### 2.2. Idempotency

*   **Test Case 2.2.1:**  Run the migration script/flag multiple times on the same database.
    *   Verify that the script does not produce errors on subsequent runs.
    *   Verify that the database remains in a consistent state after each run.

### 2.3. Rollback (using a hypothetical `--rollback` flag)

*   **Test Case 2.3.1:**  After running the migration script/flag, run the rollback script/flag (`--rollback`).
    *   Verify that the script completes successfully without errors.
    *   Verify that the database is correctly reverted to the old naming convention (`nova_memory`).
    *   Verify that all data is preserved during the rollback.
*   **Test Case 2.3.2:**  After the rollback, verify that all affected systems can connect to the database using the old naming convention.

### 2.4. Error Handling

*   **Test Case 2.4.1:**  Run the migration script/flag with invalid parameters.
    *   Verify that the script produces appropriate error messages.
    *   Verify that the database is not modified.
*   **Test Case 2.4.2:**  Simulate a failure during the migration process (e.g., by interrupting the script).
    *   Verify that the script handles the failure gracefully.
    *   Verify that the database is left in a consistent state (either fully migrated or fully rolled back).

## 3. Multi-Agent Environment Testing

*   **Test Case 3.1.1:**  In a multi-agent environment (with Newhart and Argus), migrate the database using the script/flag.
    *   Verify that all agents can connect to the database after the migration.
    *   Verify that the agents function correctly and perform their intended tasks.
*   **Test Case 3.1.2:**  Rollback the database in a multi-agent environment.
    *   Verify that all agents can connect to the database after the rollback.
    *   Verify that the agents function correctly.
*   **Test Case 3.1.31:** Specific test with `nova-staging` user (our actual staging environment) - verifies `nova_staging_memory` database works end-to-end
*   **Test Case 3.1.32:** Test that agents with hyphens in username (e.g., `nova-staging`) correctly get underscore conversion in database name

## 4. Upgrade Path Verification

*   **Test Case 4.1.1:** Test upgrading from various previous versions of NOVA that used the `nova_memory` naming convention.  Ensure the migration process works correctly and data integrity is maintained.

## 5. Dependency Discovery:

*   **Test Case 5.1.50:** Document/test a command to list all cron jobs referencing `nova_memory`: `grep -r "nova_memory" /etc/cron* ~/clawd/`
*   **Test Case 5.1.51:** Document/test finding all scripts with hardcoded database name: `grep -r "psql.*nova_memory" ~/clawd/`


