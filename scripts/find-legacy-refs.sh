#!/bin/bash
# find-legacy-refs.sh - Find all hardcoded nova_memory references
# Part of migration tooling for database naming convention change

set -e

echo "=========================================="
echo "Legacy Database Reference Finder"
echo "=========================================="
echo ""
echo "Searching for hardcoded 'nova_memory' references..."
echo ""

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

FOUND_COUNT=0

# Function to search and display results
search_location() {
    local location=$1
    local description=$2
    
    if [ ! -e "$location" ]; then
        echo -e "${YELLOW}[SKIP]${NC} $description: $location (not found)"
        return
    fi
    
    echo -e "${GREEN}[SCAN]${NC} $description: $location"
    
    # Search for nova_memory, excluding binary files and git directories
    if [ -d "$location" ]; then
        results=$(grep -r "nova_memory" "$location" 2>/dev/null | grep -v "^Binary file" | grep -v ".git/" || true)
    else
        results=$(grep "nova_memory" "$location" 2>/dev/null || true)
    fi
    
    if [ -n "$results" ]; then
        echo -e "${RED}  Found references:${NC}"
        echo "$results" | while IFS= read -r line; do
            echo "    $line"
            FOUND_COUNT=$((FOUND_COUNT + 1))
        done
    fi
    echo ""
}

# Search common locations
search_location "/etc/cron.d" "System cron jobs"
search_location "/etc/cron.daily" "Daily cron jobs"
search_location "/etc/cron.hourly" "Hourly cron jobs"
search_location "/etc/cron.weekly" "Weekly cron jobs"
search_location "/etc/cron.monthly" "Monthly cron jobs"
search_location "/var/spool/cron/crontabs" "User crontabs"

# User's crontab (requires special handling)
echo -e "${GREEN}[SCAN]${NC} User crontab"
user_cron=$(crontab -l 2>/dev/null | grep "nova_memory" || true)
if [ -n "$user_cron" ]; then
    echo -e "${RED}  Found references:${NC}"
    echo "$user_cron" | while IFS= read -r line; do
        echo "    $line"
    done
fi
echo ""

# Search in clawd directory
search_location "$HOME/clawd" "Clawd directory"

# Search for psql commands specifically
echo -e "${GREEN}[SCAN]${NC} PostgreSQL commands with nova_memory"
psql_refs=$(grep -r "psql.*nova_memory" "$HOME/clawd" 2>/dev/null | grep -v "^Binary file" | grep -v ".git/" || true)
if [ -n "$psql_refs" ]; then
    echo -e "${RED}  Found psql references:${NC}"
    echo "$psql_refs" | while IFS= read -r line; do
        echo "    $line"
    done
else
    echo "  No psql references found"
fi
echo ""

# Summary
echo "=========================================="
echo "SCAN COMPLETE"
echo "=========================================="
if [ $FOUND_COUNT -gt 0 ]; then
    echo -e "${RED}⚠️  Found hardcoded references to 'nova_memory'${NC}"
    echo ""
    echo "NEXT STEPS:"
    echo "  1. Review the references listed above"
    echo "  2. Update them to use dynamic database naming"
    echo "  3. See MIGRATION.md for detailed guidance"
    echo ""
    echo "TIP: Use PGUSER environment variable to override database name"
    echo "     export PGUSER=nova  # Forces nova_memory database"
else
    echo -e "${GREEN}✅ No hardcoded references found${NC}"
fi

exit 0
