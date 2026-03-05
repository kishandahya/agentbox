#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MODE="${1:---all}"

TOTAL_SUITES=0
PASSED_SUITES=0
FAILED_SUITES=0
SKIPPED_SUITES=0

run_test() {
    local name="$1"
    local script="$2"
    TOTAL_SUITES=$((TOTAL_SUITES + 1))

    echo ""
    echo "━━━ $name ━━━"

    if bash "$script"; then
        PASSED_SUITES=$((PASSED_SUITES + 1))
        echo ">>> $name: PASSED"
    else
        local rc=$?
        if [ $rc -eq 0 ]; then
            PASSED_SUITES=$((PASSED_SUITES + 1))
            echo ">>> $name: PASSED"
        else
            FAILED_SUITES=$((FAILED_SUITES + 1))
            echo ">>> $name: FAILED (exit code $rc)"
        fi
    fi
}

echo "=== Agentbox Test Suite ==="
echo "Mode: $MODE"
echo "Repo: $REPO_ROOT"
echo ""

# Unit tests (always run)
if [ "$MODE" = "--unit" ] || [ "$MODE" = "--all" ]; then
    echo "--- Unit Tests ---"
    run_test "Preset Contract" "$SCRIPT_DIR/test_preset_contract.sh"
    run_test "Missing Secrets" "$SCRIPT_DIR/test_missing_secrets.sh"
    run_test "Installer Idempotency" "$SCRIPT_DIR/test_installer_idempotency.sh"
fi

# Integration tests (only with --integration or --all)
if [ "$MODE" = "--integration" ] || [ "$MODE" = "--all" ]; then
    echo ""
    echo "--- Integration Tests ---"
    run_test "Egress" "$SCRIPT_DIR/test_egress.sh"
    run_test "Workspace" "$SCRIPT_DIR/test_workspace.sh"
    run_test "Runtime" "$SCRIPT_DIR/test_runtime.sh"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━"
echo "Suites: $TOTAL_SUITES total, $PASSED_SUITES passed, $FAILED_SUITES failed"
echo "━━━━━━━━━━━━━━━━━━━━━━"

[ "$FAILED_SUITES" -eq 0 ]
