#!/bin/bash
# Smoke test for demo preset -- runs inside the container
set -euo pipefail

echo "=== Demo Preset Smoke Test ==="

# 1. Check demo-agent binary exists
which demo-agent || { echo "FAIL: demo-agent not found"; exit 1; }
echo "PASS: demo-agent binary exists"

# 2. Start it in background
demo-agent &
AGENT_PID=$!
echo "Started demo-agent (pid=$AGENT_PID)"

# 3. Wait for health marker (max 10s)
for i in $(seq 1 10); do
    if [ -f /workspace/.agentbox/demo/healthy ]; then
        echo "PASS: health marker appeared after ${i}s"
        break
    fi
    sleep 1
done
[ -f /workspace/.agentbox/demo/healthy ] || { echo "FAIL: health marker not found"; kill $AGENT_PID 2>/dev/null; exit 1; }

# 4. Check log output
grep -q "demo-agent healthy" /workspace/.agentbox/demo/server.log || { echo "FAIL: missing log output"; kill $AGENT_PID 2>/dev/null; exit 1; }
echo "PASS: log output correct"

# 5. Clean shutdown
kill $AGENT_PID
wait $AGENT_PID 2>/dev/null || true
[ ! -f /workspace/.agentbox/demo/healthy ] && echo "PASS: clean shutdown" || echo "WARN: health marker not cleaned up"

echo "=== All smoke tests passed ==="
