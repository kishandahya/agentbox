#!/usr/bin/env bash
# Quick smoke test for agentbox installation
# Run after: sudo ./install.sh
set -euo pipefail

echo "=== Agentbox Smoke Test ==="

# 1. Check sandctl is available
command -v sandctl >/dev/null || { echo "FAIL: sandctl not on PATH"; exit 1; }
echo "PASS: sandctl on PATH"

# 2. Check stack status
sandctl status || { echo "FAIL: stack not running"; exit 1; }
echo "PASS: stack running"

# 3. Check SSH
sandctl workspace exec -- echo "hello from sandbox" || { echo "FAIL: SSH failed"; exit 1; }
echo "PASS: SSH works"

# 4. Check doctor
sandctl doctor || echo "WARN: doctor reported issues (may be expected in some environments)"

# 5. Write/read round-trip
echo "smoke-test-$(date +%s)" | sandctl write-file .smoke-test.txt
sandctl read-file .smoke-test.txt | grep -q "smoke-test-" || { echo "FAIL: write/read failed"; exit 1; }
sandctl workspace exec -- rm -f /workspace/.smoke-test.txt
echo "PASS: workspace write/read"

echo ""
echo "=== Smoke test passed ==="
echo "Next steps:"
echo "  1. sandctl ssh"
echo "  2. opencode auth login  (complete OAuth in browser)"
echo "  3. exit"
echo "  4. sandctl run"
