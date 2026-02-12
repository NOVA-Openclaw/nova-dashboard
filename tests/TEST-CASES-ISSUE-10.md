Section 1 - Basic Functionality
- TC-10-13: Test that `/dashboard/postgres.json` works via nginx proxy (the dashboard is served at /dashboard/ path)
- TC-10-14: Test that `/dashboard/reports.json` works via nginx proxy

Section 3 - Data Visualization
- TC-10-35: Explicitly verify DATABASE section displays postgres stats (issue #8 verification) - check for table names, row counts, or connection status

Section 5 - Nginx Configuration:
- TC-10-50: Verify nginx `/reports/` location block serves files with correct MIME type (text/html)
- TC-10-51: Verify report symlinks resolve correctly (latest-devops-report.html → actual file)