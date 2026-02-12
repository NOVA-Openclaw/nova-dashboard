## Test Cases for Issue #15: Remove Legacy IT Report

**Objective:** Verify the complete removal of the legacy `NOVA_IT_Report` from the dashboard.

**Test Cases:**

1.  **Verify `itReport` entry is removed from `reports.json`**
    *   **Description:** Ensure the `itReport` entry is absent from the `reports.json` file.
    *   **Steps:**
        1.  Read the contents of `reports.json`.
        2.  Check for the existence of the `itReport` key.
    *   **Expected Result:** The `itReport` key should not be found in the `reports.json` file.

2.  **Verify `latest-it-report.html` symlink is removed**
    *   **Description:** Confirm the `latest-it-report.html` symbolic link has been deleted.
    *   **Steps:**
        1.  Check for the existence of the `latest-it-report.html` file.
    *   **Expected Result:** The `latest-it-report.html` file should not exist.

3.  **Verify `update-report-links.sh` no longer processes `NOVA_IT_Report_*`**
    *   **Description:** Ensure the `update-report-links.sh` script does not contain any references to `NOVA_IT_Report_*`.
    *   **Steps:**
        1.  Read the contents of `update-report-links.sh`.
        2.  Search for any lines containing `NOVA_IT_Report_*`.
    *   **Expected Result:** No lines in the script should reference `NOVA_IT_Report_*`.

4.  **Verify Dashboard HTML doesn't reference `itReport`**
    *   **Description:** Confirm that the dashboard HTML files do not contain any links or references to `itReport`.
    *   **Steps:**
        1.  Identify the relevant dashboard HTML files.
        2.  Read the contents of each HTML file.
        3.  Search for any occurrences of `itReport` within the HTML code.
    *   **Expected Result:** No occurrences of `itReport` should be found in the dashboard HTML files.
