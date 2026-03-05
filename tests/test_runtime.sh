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

echo "=== Runtime Tests (integration - requires running stack with demo preset) ==="

SANDCTL="$AGENTBOX_DIR/sandctl"
if [ ! -x "$SANDCTL" ]; then
    echo "SKIP: sandctl not found or not executable"
    exit 0
fi

export AGENTBOX_DIR

# Guard: check sandbox is running
if ! "$SANDCTL" status &>/dev/null 2>&1; then
    echo "SKIP: sandbox not running"
    exit 0
fi

# Guard: verify demo preset is active (or switch to it)
CURRENT_PRESET="${AGENTBOX_PRESET:-opencode}"
if [ "$CURRENT_PRESET" != "demo" ]; then
    echo "NOTE: Switching to demo preset for testing..."
    "$SANDCTL" agent use demo
    "$SANDCTL" restart
    # Wait for SSH
    sleep 5
fi

# Ensure any previous runtime is stopped
"$SANDCTL" stop 2>/dev/null || true
sleep 1

# Test 1: sandctl run starts background process
"$SANDCTL" run
sleep 3
if "$SANDCTL" workspace exec -- test -f /workspace/.agentbox/runtime.pid; then
    pass "run creates PID file"
else
    fail "run did not create PID file"
fi

# Test 2: sandctl ps shows running
PS_OUTPUT=$("$SANDCTL" ps)
if echo "$PS_OUTPUT" | grep -qi "running"; then
    pass "ps shows running"
else
    fail "ps does not show running: $PS_OUTPUT"
fi

# Test 3: runtime logs shows output
sleep 5  # Let heartbeat write some logs
LOGS=$("$SANDCTL" runtime logs)
if echo "$LOGS" | grep -q "demo-agent"; then
    pass "runtime logs shows demo-agent output"
else
    fail "runtime logs empty or missing demo-agent output"
fi

# Test 4: health check passed (demo agent creates healthy marker)
if "$SANDCTL" workspace exec -- test -f /workspace/.agentbox/demo/healthy; then
    pass "health marker exists"
else
    fail "health marker not found"
fi

# Test 5: autostart state file exists on host
if [ -f "$AGENTBOX_DIR/state/runtime.json" ]; then
    pass "host-side autostart state file exists"
else
    fail "host-side autostart state file missing"
fi

# Test 6: sandctl stop kills process
"$SANDCTL" stop
sleep 2
PS_OUTPUT=$("$SANDCTL" ps)
if echo "$PS_OUTPUT" | grep -qi "not running"; then
    pass "stop kills runtime"
else
    fail "stop did not kill runtime: $PS_OUTPUT"
fi

# Test 7: autostart state removed after stop
if [ ! -f "$AGENTBOX_DIR/state/runtime.json" ]; then
    pass "autostart state removed after stop"
else
    fail "autostart state still present after stop"
fi

# Cleanup: restore original preset if changed
if [ "$CURRENT_PRESET" != "demo" ]; then
    "$SANDCTL" agent use "$CURRENT_PRESET"
    "$SANDCTL" restart
fi

summary
