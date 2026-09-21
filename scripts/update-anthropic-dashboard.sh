#!/usr/bin/env bash
# =============================================================================
# Anthropic Dashboard Updater — backward-compatible wrapper
# =============================================================================
#
# This script is the canonical entry point for cron jobs that were previously
# configured to run update-anthropic-dashboard.sh directly. It delegates to the
# consolidated update-dashboard.sh so the Anthropic logic has a single source
# of truth and carries fixes such as the #17 pagination fix.
#
# USAGE:
#   ./scripts/update-anthropic-dashboard.sh
#
# CRON SETUP:
#   */5 * * * * /path/to/scripts/update-anthropic-dashboard.sh >> /var/log/anthropic-dashboard-cron.log 2>&1
#
# The underlying consolidated script throttles the Anthropic API calls to
# 15-minute intervals, so a 5-minute cron frequency is safe.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/update-dashboard.sh" --anthropic-only "$@"
