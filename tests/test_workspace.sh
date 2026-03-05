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

echo "=== Workspace Tests (integration - requires running stack) ==="

SANDCTL="$AGENTBOX_DIR/sandctl"
if [ ! -x "$SANDCTL" ]; then
    echo "SKIP: sandctl not found or not executable"
    exit 0
fi

# Guard: check sandbox is running
if ! AGENTBOX_DIR="$AGENTBOX_DIR" "$SANDCTL" status &>/dev/null 2>&1; then
    echo "SKIP: sandbox not running"
    exit 0
fi

export AGENTBOX_DIR

# Test 1: write-file and read-file round-trip
TEST_CONTENT="hello from agentbox test $(date +%s)"
echo "$TEST_CONTENT" | "$SANDCTL" write-file test_workspace.txt
RESULT=$("$SANDCTL" read-file test_workspace.txt)
if [ "$RESULT" = "$TEST_CONTENT" ]; then
    pass "write-file / read-file round-trip"
else
    fail "write-file / read-file mismatch: expected '$TEST_CONTENT', got '$RESULT'"
fi

# Test 2: list-files shows the test file
LISTING=$("$SANDCTL" list-files)
if echo "$LISTING" | grep -q "test_workspace.txt"; then
    pass "list-files shows test file"
else
    fail "list-files does not show test_workspace.txt"
fi

# Test 3: workspace exec
EXEC_RESULT=$("$SANDCTL" workspace exec -- cat /workspace/test_workspace.txt)
if [ "$EXEC_RESULT" = "$TEST_CONTENT" ]; then
    pass "workspace exec reads file correctly"
else
    fail "workspace exec mismatch"
fi

# Test 4: workspace exec with arguments
EXEC_RESULT=$("$SANDCTL" workspace exec -- echo "arg1" "arg2" "arg3")
if echo "$EXEC_RESULT" | grep -q "arg1 arg2 arg3"; then
    pass "workspace exec preserves arguments"
else
    fail "workspace exec lost arguments: got '$EXEC_RESULT'"
fi

# Test 5: upload and download round-trip
TMPFILE=$(mktemp)
echo "upload test content $(date +%s)" > "$TMPFILE"
"$SANDCTL" upload "$TMPFILE" test_upload.txt
DOWNLOAD_DIR=$(mktemp -d)
"$SANDCTL" download test_upload.txt "$DOWNLOAD_DIR/downloaded.txt"
if diff "$TMPFILE" "$DOWNLOAD_DIR/downloaded.txt" &>/dev/null; then
    pass "upload / download round-trip"
else
    fail "upload / download content mismatch"
fi
rm -rf "$TMPFILE" "$DOWNLOAD_DIR"

# Test 6: read-file path traversal protection
if "$SANDCTL" read-file "../etc/passwd" 2>/dev/null; then
    fail "path traversal not blocked for ../etc/passwd"
else
    pass "path traversal blocked"
fi

# Cleanup
"$SANDCTL" workspace exec -- rm -f /workspace/test_workspace.txt /workspace/test_upload.txt

summary
