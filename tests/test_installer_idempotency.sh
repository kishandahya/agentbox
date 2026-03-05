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

echo "=== Installer Idempotency Tests ==="

INSTALL_SH="$REPO_ROOT/install.sh"

# Test: Script has proper header
if head -2 "$INSTALL_SH" | grep -q 'set -euo pipefail'; then
    pass "install.sh has set -euo pipefail"
else
    fail "install.sh missing set -euo pipefail"
fi

# Test: Script passes bash syntax check
if bash -n "$INSTALL_SH" 2>/dev/null; then
    pass "install.sh passes bash -n syntax check"
else
    fail "install.sh has syntax errors"
fi

# Test: Docker installation has idempotency guard
if grep -q 'command -v docker\|which docker\|docker.*--version\|docker compose version' "$INSTALL_SH"; then
    pass "Docker install has existence check"
else
    fail "Docker install missing idempotency guard"
fi

# Test: SSH key generation has idempotency guard
if grep -q 'id_agentbox.*exist\|-f.*id_agentbox\|already.*exist' "$INSTALL_SH"; then
    pass "SSH key generation has existence check"
else
    fail "SSH key generation missing idempotency guard"
fi

# Test: Squid config rendering preserves user allowlist
if grep -q 'allowlist.txt.*exist\|-f.*allowlist.txt' "$INSTALL_SH"; then
    pass "Allowlist copy has existence check (preserves customizations)"
else
    fail "Allowlist copy missing existence check"
fi

# Test: iptables uses check-before-add pattern
if grep -q 'iptables -C\|iptables.*--check' "$INSTALL_SH"; then
    pass "iptables uses check-before-add (-C) pattern"
else
    fail "iptables missing check-before-add pattern"
fi

# Test: systemctl daemon-reload is called
if grep -q 'daemon-reload' "$INSTALL_SH"; then
    pass "systemd daemon-reload is called"
else
    fail "Missing systemd daemon-reload"
fi

# Test: Script installs sandctl to PATH
if grep -q 'ln.*sandctl.*/usr/local/bin\|install.*sandctl.*/usr/local/bin' "$INSTALL_SH"; then
    pass "sandctl is installed to /usr/local/bin"
else
    fail "sandctl not installed to PATH"
fi

# Test: Script has OS version check
if grep -q '22.04\|24.04\|VERSION_ID' "$INSTALL_SH"; then
    pass "OS version check present"
else
    fail "OS version check missing"
fi

# Test: Script handles .env backup
if grep -q 'backup\|\.env\.bak\|\.env\.old\|cp.*\.env' "$INSTALL_SH"; then
    pass ".env backup/preservation logic present"
else
    fail ".env backup logic missing"
fi

summary
