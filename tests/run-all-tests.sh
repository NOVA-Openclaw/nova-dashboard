#!/bin/bash
# Comprehensive test suite for pagination fix (Issue #17)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOCK_DIR="$SCRIPT_DIR/mock-api"
TEST_LOG="$SCRIPT_DIR/test-run.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

mkdir -p "$MOCK_DIR"
> "$TEST_LOG"

log_test() {
    echo "$1" | tee -a "$TEST_LOG"
}

test_header() {
    echo -e "\n${BLUE}=== $1 ===${NC}" | tee -a "$TEST_LOG"
}

test_pass() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}✓ PASS${NC}: $1" | tee -a "$TEST_LOG"
}

test_fail() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}✗ FAIL${NC}: $1" | tee -a "$TEST_LOG"
    if [ -n "${2:-}" ]; then
        echo -e "  ${YELLOW}Details:${NC} $2" | tee -a "$TEST_LOG"
    fi
}

# Setup mock curl and helper functions
setup_test_env() {
    # Mock log function
    log() {
        echo "[LOG] $1" >&2
    }
    
    # Mock error_exit
    error_exit() {
        echo "[ERROR] $1" >&2
        return 1
    }
    
    ADMIN_KEY="test_key_12345"
    
    export -f log error_exit
    export ADMIN_KEY
}

# The actual fetch_paginated function from the script
fetch_paginated() {
    local url="$1"
    local description="$2"
    local all_data="[]"
    local page_count=0
    local next_page=""
    
    log "Fetching ${description} (with pagination)..."
    
    while true; do
        page_count=$((page_count + 1))
        
        local fetch_url="$url"
        if [ -n "$next_page" ] && [ "$next_page" != "null" ]; then
            if [[ "$fetch_url" == *"?"* ]]; then
                fetch_url="${fetch_url}&next_page=${next_page}"
            else
                fetch_url="${fetch_url}?next_page=${next_page}"
            fi
        fi
        
        log "  Fetching page ${page_count}..."
        
        local response
        response=$(curl -sf "$fetch_url" \
            --header "anthropic-version: 2023-06-01" \
            --header "x-api-key: $ADMIN_KEY") || {
            error_exit "Failed to fetch ${description} (page ${page_count})"
            return 1
        }
        
        if ! echo "$response" | jq empty 2>/dev/null; then
            error_exit "Invalid JSON response for ${description} (page ${page_count})"
            return 1
        fi
        
        local page_data
        page_data=$(echo "$response" | jq -c '.data // []')
        
        if [ "$page_data" = "[]" ] || [ "$page_data" = "null" ]; then
            if [ "$page_count" -eq 1 ]; then
                log "  Empty response for ${description}"
                echo '{"data": []}'
                return 0
            fi
        else
            all_data=$(jq -n --argjson all "$all_data" --argjson page "$page_data" '$all + $page')
        fi
        
        local has_more
        has_more=$(echo "$response" | jq -r '.has_more // false')
        next_page=$(echo "$response" | jq -r '.next_page // null')
        
        if [ "$has_more" != "true" ]; then
            log "  Completed fetching ${description} (${page_count} pages)"
            break
        fi
        
        if [ -z "$next_page" ] || [ "$next_page" = "null" ]; then
            log "  Warning: has_more=true but no next_page token for ${description}"
            break
        fi
        
        if [ "$page_count" -gt 100 ]; then
            error_exit "Pagination exceeded 100 pages for ${description} - possible infinite loop"
            return 1
        fi
    done
    
    echo "{\"data\": $all_data}"
}

export -f fetch_paginated

# TEST 1: Multi-page pagination (3 pages)
test_header "TEST 1: Multi-page Pagination (3 pages)"

cat > "$MOCK_DIR/test1_page1.json" << 'EOF'
{
  "data": [
    {"starting_at": "2026-02-01T00:00:00Z", "results": [{"amount": 1000}]},
    {"starting_at": "2026-02-02T00:00:00Z", "results": [{"amount": 1500}]}
  ],
  "has_more": true,
  "next_page": "token_page2"
}
EOF

cat > "$MOCK_DIR/test1_page2.json" << 'EOF'
{
  "data": [
    {"starting_at": "2026-02-03T00:00:00Z", "results": [{"amount": 2000}]},
    {"starting_at": "2026-02-04T00:00:00Z", "results": [{"amount": 2500}]}
  ],
  "has_more": true,
  "next_page": "token_page3"
}
EOF

cat > "$MOCK_DIR/test1_page3.json" << 'EOF'
{
  "data": [
    {"starting_at": "2026-02-05T00:00:00Z", "results": [{"amount": 3000}]}
  ],
  "has_more": false,
  "next_page": null
}
EOF

curl() {
    local url=""
    while [[ $# -gt 0 ]]; do
        [[ "$1" =~ ^http ]] && url="$1"
        shift
    done
    
    if [[ "$url" == *"next_page=token_page2"* ]]; then
        cat "$MOCK_DIR/test1_page2.json"
    elif [[ "$url" == *"next_page=token_page3"* ]]; then
        cat "$MOCK_DIR/test1_page3.json"
    else
        cat "$MOCK_DIR/test1_page1.json"
    fi
}
export -f curl

setup_test_env
RESULT=$(fetch_paginated "http://api.test/cost_report?start=2026-02-01" "test1" 2>/dev/null)
ITEM_COUNT=$(echo "$RESULT" | jq '.data | length')
TOTAL=$(echo "$RESULT" | jq '[.data[].results[].amount] | add')

if [ "$ITEM_COUNT" = "5" ] && [ "$TOTAL" = "10000" ]; then
    test_pass "Multi-page pagination aggregates correctly (5 items, total $TOTAL cents)"
else
    test_fail "Multi-page pagination" "Expected 5 items with total 10000, got $ITEM_COUNT items with total $TOTAL"
fi

# TEST 2: Single page response
test_header "TEST 2: Single Page Response (no pagination)"

cat > "$MOCK_DIR/test2.json" << 'EOF'
{
  "data": [
    {"starting_at": "2026-02-01T00:00:00Z", "results": [{"amount": 5000}]}
  ],
  "has_more": false,
  "next_page": null
}
EOF

curl() {
    cat "$MOCK_DIR/test2.json"
}
export -f curl

setup_test_env
RESULT=$(fetch_paginated "http://api.test/cost_report" "test2" 2>/dev/null)
ITEM_COUNT=$(echo "$RESULT" | jq '.data | length')

if [ "$ITEM_COUNT" = "1" ]; then
    test_pass "Single page response handled correctly"
else
    test_fail "Single page response" "Expected 1 item, got $ITEM_COUNT"
fi

# TEST 3: Empty response
test_header "TEST 3: Empty Response"

cat > "$MOCK_DIR/test3.json" << 'EOF'
{
  "data": [],
  "has_more": false,
  "next_page": null
}
EOF

curl() {
    cat "$MOCK_DIR/test3.json"
}
export -f curl

setup_test_env
RESULT=$(fetch_paginated "http://api.test/cost_report" "test3" 2>/dev/null)

if echo "$RESULT" | jq -e '.data | length == 0' >/dev/null; then
    test_pass "Empty response handled gracefully"
else
    test_fail "Empty response" "Expected empty array"
fi

# TEST 4: Two-page usage report
test_header "TEST 4: Usage Report Pagination (2 pages)"

cat > "$MOCK_DIR/test4_page1.json" << 'EOF'
{
  "data": [
    {"starting_at": "2026-02-01T00:00:00Z", "results": [{"uncached_input_tokens": 1000, "output_tokens": 500}]}
  ],
  "has_more": true,
  "next_page": "usage_token2"
}
EOF

cat > "$MOCK_DIR/test4_page2.json" << 'EOF'
{
  "data": [
    {"starting_at": "2026-02-02T00:00:00Z", "results": [{"uncached_input_tokens": 2000, "output_tokens": 1000}]}
  ],
  "has_more": false,
  "next_page": null
}
EOF

curl() {
    local url=""
    while [[ $# -gt 0 ]]; do
        [[ "$1" =~ ^http ]] && url="$1"
        shift
    done
    
    if [[ "$url" == *"next_page=usage_token2"* ]]; then
        cat "$MOCK_DIR/test4_page2.json"
    else
        cat "$MOCK_DIR/test4_page1.json"
    fi
}
export -f curl

setup_test_env
RESULT=$(fetch_paginated "http://api.test/usage_report/messages" "test4" 2>/dev/null)
ITEM_COUNT=$(echo "$RESULT" | jq '.data | length')
TOTAL_INPUT=$(echo "$RESULT" | jq '[.data[].results[].uncached_input_tokens] | add')

if [ "$ITEM_COUNT" = "2" ] && [ "$TOTAL_INPUT" = "3000" ]; then
    test_pass "Usage report pagination works (2 items, $TOTAL_INPUT input tokens)"
else
    test_fail "Usage report pagination" "Expected 2 items with 3000 input tokens, got $ITEM_COUNT items with $TOTAL_INPUT tokens"
fi

# TEST 5: API error during pagination
test_header "TEST 5: API Error During Pagination"

cat > "$MOCK_DIR/test5_page1.json" << 'EOF'
{
  "data": [
    {"starting_at": "2026-02-01T00:00:00Z", "results": [{"amount": 1000}]}
  ],
  "has_more": true,
  "next_page": "will_fail"
}
EOF

curl() {
    local url=""
    while [[ $# -gt 0 ]]; do
        [[ "$1" =~ ^http ]] && url="$1"
        shift
    done
    
    if [[ "$url" == *"next_page=will_fail"* ]]; then
        return 1  # Simulate API failure
    else
        cat "$MOCK_DIR/test5_page1.json"
    fi
}
export -f curl

setup_test_env
if ! RESULT=$(fetch_paginated "http://api.test/cost_report" "test5" 2>&1); then
    test_pass "API error handled gracefully (error reported)"
else
    test_fail "API error handling" "Expected function to return error, but it succeeded"
fi

# TEST 6: Missing next_page token (has_more true but no token)
test_header "TEST 6: Missing next_page Token"

cat > "$MOCK_DIR/test6.json" << 'EOF'
{
  "data": [
    {"starting_at": "2026-02-01T00:00:00Z", "results": [{"amount": 1000}]}
  ],
  "has_more": true,
  "next_page": null
}
EOF

curl() {
    cat "$MOCK_DIR/test6.json"
}
export -f curl

setup_test_env
RESULT=$(fetch_paginated "http://api.test/cost_report" "test6" 2>/dev/null)
ITEM_COUNT=$(echo "$RESULT" | jq '.data | length')

if [ "$ITEM_COUNT" = "1" ]; then
    test_pass "Missing next_page token handled (stops pagination)"
else
    test_fail "Missing next_page token" "Expected 1 item, got $ITEM_COUNT"
fi

# Cleanup
rm -rf "$MOCK_DIR"

# Summary
test_header "TEST SUMMARY"
TOTAL_TESTS=$((TESTS_PASSED + TESTS_FAILED))
echo -e "\nTotal tests: $TOTAL_TESTS"
echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
if [ "$TESTS_FAILED" -gt 0 ]; then
    echo -e "${RED}Failed: $TESTS_FAILED${NC}"
fi
echo ""
echo "Full log: $TEST_LOG"

if [ "$TESTS_FAILED" -eq 0 ]; then
    echo -e "\n${GREEN}✓ All tests passed!${NC}\n"
    exit 0
else
    echo -e "\n${RED}✗ Some tests failed${NC}\n"
    exit 1
fi
