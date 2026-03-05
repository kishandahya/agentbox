#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENTBOX_DIR="${AGENTBOX_DIR:-$REPO_ROOT}"

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

echo "=== Egress Tests (integration - requires running stack) ==="

# Check prerequisites
if ! command -v docker &>/dev/null; then
    echo "SKIP: Docker not available"
    exit 0
fi

SANDCTL="$AGENTBOX_DIR/sandctl"
if [ ! -x "$SANDCTL" ]; then
    echo "SKIP: sandctl not found or not executable"
    exit 0
fi

# Check sandbox is running
if ! AGENTBOX_DIR="$AGENTBOX_DIR" "$SANDCTL" status &>/dev/null 2>&1; then
    echo "SKIP: sandbox not running (start with: sandctl up)"
    exit 0
fi

ssh_cmd() {
    AGENTBOX_DIR="$AGENTBOX_DIR" "$SANDCTL" workspace exec -- "$@"
}

# Verify curl exists in sandbox (MUST NOT skip silently)
if ! ssh_cmd which curl &>/dev/null; then
    fail "curl not found in sandbox -- egress tests cannot run without it"
    summary
    exit 1
fi

# Test 1: Allowlisted domain IS reachable through proxy
# Use github.com which is in the default allowlist
result=$(ssh_cmd curl -sf -o /dev/null -w '%{http_code}' --connect-timeout 10 https://github.com 2>/dev/null || echo "000")
if [ "$result" = "200" ] || [ "$result" = "301" ] || [ "$result" = "302" ]; then
    pass "Allowlisted domain (github.com) reachable: HTTP $result"
else
    fail "Allowlisted domain (github.com) NOT reachable: HTTP $result"
fi

# Test 2: Non-allowlisted domain is BLOCKED
# Use example.com which should NOT be in the allowlist
result=$(ssh_cmd curl -sf -o /dev/null -w '%{http_code}' --connect-timeout 10 --proxy-insecure https://example.com 2>/dev/null || echo "000")
if [ "$result" = "403" ] || [ "$result" = "000" ]; then
    pass "Non-allowlisted domain (example.com) blocked: HTTP $result"
else
    fail "Non-allowlisted domain (example.com) NOT blocked: HTTP $result (expected 403 or connection refused)"
fi

# Test 3: Direct connection (bypassing proxy) should fail
# Try connecting without using the proxy env vars
# The sandbox network is internal-only, so direct connections should time out
result=$(ssh_cmd env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY curl -sf -o /dev/null -w '%{http_code}' --connect-timeout 5 https://example.com 2>/dev/null || echo "000")
if [ "$result" = "000" ]; then
    pass "Direct connection (bypassing proxy) fails as expected"
else
    fail "Direct connection (bypassing proxy) succeeded: HTTP $result -- network isolation may be broken"
fi

# Test 4: Another non-allowlisted domain to avoid false positives
result=$(ssh_cmd curl -sf -o /dev/null -w '%{http_code}' --connect-timeout 10 https://evil-exfiltration-test.example.org 2>/dev/null || echo "000")
if [ "$result" = "403" ] || [ "$result" = "000" ]; then
    pass "Second non-allowlisted domain blocked"
else
    fail "Second non-allowlisted domain NOT blocked: HTTP $result"
fi

summary
