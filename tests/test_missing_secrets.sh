#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

TESTS=0
PASSED=0
FAILED=0

pass() { TESTS=$((TESTS + 1)); PASSED=$((PASSED + 1)); echo "  PASS: $1"; }
fail() { TESTS=$((TESTS + 1)); FAILED=$((FAILED + 1)); echo "  FAIL: $1"; }
summary() {
    echo ""
    echo "Results: $PASSED/$TESTS passed, $FAILED failed"
    [ "$FAILED" -eq 0 ]
}

echo "=== Missing Secrets Tests ==="

# Test 1: Each preset with REQUIRED_ENV_VARS has non-empty values listed
for preset_dir in "$REPO_ROOT"/agents/*/; do
    preset_name=$(basename "$preset_dir")
    required_vars=$(source "$preset_dir/agent.env" && echo "${REQUIRED_ENV_VARS:-}")

    if [ -n "$required_vars" ]; then
        # Verify each listed var is a reasonable env var name
        all_valid=true
        for var in $required_vars; do
            if [[ "$var" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
                pass "$preset_name: $var is valid env var name"
            else
                fail "$preset_name: '$var' is not a valid env var name"
                all_valid=false
            fi
        done
    else
        # Presets with no required vars (like demo) should explicitly have empty string
        if grep -q 'REQUIRED_ENV_VARS=' "$preset_dir/agent.env"; then
            pass "$preset_name: REQUIRED_ENV_VARS explicitly declared (empty)"
        else
            fail "$preset_name: REQUIRED_ENV_VARS not declared at all"
        fi
    fi
done

# Test 2: install.sh has validation logic for REQUIRED_ENV_VARS
if grep -q 'REQUIRED_ENV_VARS' "$REPO_ROOT/install.sh"; then
    pass "install.sh references REQUIRED_ENV_VARS"
else
    fail "install.sh does not reference REQUIRED_ENV_VARS"
fi

# Test 3: install.sh has error messaging for missing vars
if grep -q 'not set\|missing\|required' "$REPO_ROOT/install.sh"; then
    pass "install.sh has error messages for missing vars"
else
    fail "install.sh missing error messages for missing vars"
fi

summary
