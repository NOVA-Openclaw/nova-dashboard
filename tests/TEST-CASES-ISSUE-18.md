# Test Cases for Issue #18: Update deployment scripts to use systemctl for process control

## 1. systemctl restart works correctly

**Objective:** Verify that the `deploy.sh` script successfully restarts the nova-dashboard service using `systemctl`.

**Steps:**

1.  Execute `scripts/deploy.sh`.
2.  Check the output of `systemctl --user status nova-dashboard` to ensure the service is active and running.
3.  Verify that the service's PID has changed after the restart.

**Expected Result:**

*   `systemctl --user status nova-dashboard` should show the service as active and running with a new PID.
*   The dashboard should be accessible via `http://localhost:3847/`

## 2. Health check verifies service running

**Objective:** Verify that the `deploy.sh` script includes a health check to confirm the service is running after the restart.

**Steps:**

1.  Execute `scripts/deploy.sh`.
2.  Examine the output of the script in `~/clawd/logs/dashboard-deploy.log` to confirm the health check was performed.
3.  Manually perform the health check (curl `http://localhost:3847/`) to ensure the dashboard is accessible.

**Expected Result:**

*   The log file should contain a line indicating the health check was performed and successful.
*   `curl http://localhost:3847/` should return a 200 OK status.

## 3. Wake alert still fires

**Objective:** Verify that the wake alert notification continues to function after the changes to the deployment script.

**Steps:**

1.  Ensure that the `OPENCLAW_TOKEN` environment variable is set.
2.  Execute `scripts/deploy.sh`.
3.  Check the output of the script in `~/clawd/logs/dashboard-deploy.log` to confirm the wake alert was sent.
4.  Verify that a wake alert message is received (e.g., via Signal).

**Expected Result:**

*   The log file should contain a line indicating the wake alert was sent successfully.
*   A wake alert message should be received with the correct commit hash and timestamp.

## 4. No PID file usage

**Objective:** Verify that the `deploy.sh` script no longer uses PID files for process management.

**Steps:**

1.  Execute `scripts/deploy.sh`.
2.  Check for the existence of the PID file (`$HOME/clawd/nova-dashboard/.dashboard.pid`).

**Expected Result:**

*   The PID file should not be created or used by the script.

## 5. Graceful handling if service doesn't exist

**Objective:** Verify the script handles the case where the `nova-dashboard` systemd service does not exist gracefully.

**Steps:**

1.  Stop and disable the `nova-dashboard` systemd service: `systemctl --user stop nova-dashboard && systemctl --user disable nova-dashboard`
2.  Execute `scripts/deploy.sh`.
3.  Check the output of the script in `~/clawd/logs/dashboard-deploy.log` and the exit code of the script.

**Expected Result:**

*   The script should not error out. It should log a warning or message indicating the service was not found.
*   The script should continue to function, potentially starting the service.
*   `systemctl --user status nova-dashboard` should show the service status as "inactive (dead)" or "enabled; disabled" if the service was not running before the deployment.
