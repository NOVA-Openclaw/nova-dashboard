# Test Cases for Issue #7: Add Top Resource Consuming Processes to System Stats Section

**Status:** NOVA Reviewed ✓
**Review Date:** 2026-02-12
**Reviewer Notes:** 
- Dashboard uses server-side rendering (EJS templates) - UI tests should focus on HTML output
- Default should show top 5 processes (configurable)
- Consider adding auto-refresh interval option

## 1. Happy Path Tests

*   **TC1.1: Processes Displayed:** Verify that the top resource consuming processes are displayed in the system stats section.
*   **TC1.2: Correct Information:** Ensure that the displayed information (PID, User, CPU%, Memory%, Command) is accurate and matches the output of the `ps` command.
*   **TC1.3: Sorting by CPU:** Verify that the process list can be sorted by CPU usage in descending order.
*   **TC1.4: Sorting by Memory:** Verify that the process list can be sorted by memory usage in descending order.
*   **TC1.5: Refresh Functionality:** Ensure that the process list is updated correctly when the refresh button is clicked. The updated list should reflect the current resource consumption.

## 2. Edge Cases

*   **TC2.1: No Processes Running:** If no processes are running (other than system processes), verify that the system stats section displays an appropriate message (e.g., "No user processes running").
*   **TC2.2: High System Load:** When the system is under high load (CPU and memory), ensure that the display of the top processes remains responsive and accurate. Test with various load levels (e.g., 50%, 80%, 100% CPU utilization).
*   **TC2.3: Permission Issues (User Context):** Test the dashboard from different user accounts. Ensure that each user can only see processes that they have permission to view (i.e., their own processes).
*   **TC2.4: Long Process Names:** Verify that the display handles processes with very long command names correctly (e.g., truncate or wrap the text).
*   **TC2.5: Processes with Special Characters:** Ensure that processes with special characters in their command names (e.g., spaces, quotes, pipes) are displayed correctly without parsing errors.

## 3. Error Conditions

*   **TC3.1: `ps` Command Fails:** Simulate a failure of the `ps` command (e.g., by modifying permissions or renaming the executable). Verify that the system stats section displays an error message indicating the problem.
*   **TC3.2: Parsing Errors:** Introduce errors in the parsing logic (e.g., by modifying the expected output format of the `ps` command). Verify that the system stats section handles these errors gracefully and displays an appropriate error message.
*   **TC3.3: Invalid Data:** Test with corrupted or invalid data from the `ps` command output (e.g., negative CPU or memory usage). Ensure that the system stats section does not crash or display incorrect values.
*   **TC3.4: Resource Limit Exceeded:** If fetching process data consumes excessive resources, ensure the system gracefully handles the situation, preventing performance issues.

## 4. UI Tests

*   **TC4.1: Table Rendering:** Verify that the table displaying the processes renders correctly with appropriate headers (PID, User, CPU%, Memory%, Command) and formatting.
*   **TC4.2: Sorting Functionality:** Verify that the sorting functionality works correctly for all columns (CPU and memory). Ensure that the order of processes is as expected after sorting.
*   **TC4.3: Refresh Button:** Verify that the refresh button is present and functional. Clicking the button should update the process list with the latest data.
*   **TC4.4: Display of Large Numbers:** Verify that large values for PID, CPU%, and Memory% are displayed correctly (e.g., using appropriate formatting or scaling).
*   **TC4.5: Responsiveness:** Ensure that the system stats section is responsive and adapts correctly to different screen sizes and resolutions.
*   **TC4.6: UI Load Time:** Verify that the UI load time of the system stats section is within acceptable limits, even with a large number of processes running.
*   **TC4.7: Localization:** Verify that the UI elements are correctly localized for different languages.
*   **TC4.8: Accessibility:** Verify that the table is accessible to users with disabilities (e.g., using screen readers).
