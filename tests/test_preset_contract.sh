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

echo "=== Preset Contract Tests ==="

REQUIRED_FIELDS="PRESET_API_VERSION AGENT_ID BASE_IMAGE DEFAULT_CMD DEFAULT_WORKDIR START_MODE"
BG_FIELDS="START_CMD HEALTHCHECK_CMD LOG_PATH ACCESS_MODE"

for preset_dir in "$REPO_ROOT"/agents/*/; do
    preset_name=$(basename "$preset_dir")
    env_file="$preset_dir/agent.env"

    # Test: agent.env exists
    if [ -f "$env_file" ]; then
        pass "$preset_name: agent.env exists"
    else
        fail "$preset_name: agent.env missing"
        continue
    fi

    # Test: required fields (IN SUBSHELL to avoid variable leaking)
    if (
        source "$env_file"
        for field in $REQUIRED_FIELDS; do
            [ -n "${!field:-}" ] || exit 1
        done
    ); then
        pass "$preset_name: all required fields present"
    else
        fail "$preset_name: missing required fields"
    fi

    # Test: background presets have extra fields (IN SUBSHELL)
    local_start_mode=$(source "$env_file" && echo "$START_MODE")
    if [ "$local_start_mode" = "background" ]; then
        if (
            source "$env_file"
            for field in $BG_FIELDS; do
                [ -n "${!field:-}" ] || exit 1
            done
        ); then
            pass "$preset_name: background fields present"
        else
            fail "$preset_name: missing background fields"
        fi
    fi

    # Test: Dockerfile exists
    if [ -f "$preset_dir/Dockerfile" ]; then
        pass "$preset_name: Dockerfile exists"
    else
        fail "$preset_name: Dockerfile missing"
    fi

    # Test: entrypoint.sh exists and has valid bash syntax
    if [ -f "$preset_dir/entrypoint.sh" ]; then
        if bash -n "$preset_dir/entrypoint.sh" 2>/dev/null; then
            pass "$preset_name: entrypoint.sh valid bash"
        else
            fail "$preset_name: entrypoint.sh syntax error"
        fi
    else
        fail "$preset_name: entrypoint.sh missing"
    fi

    # Test: PRESET_API_VERSION is 1
    local_api_version=$(source "$env_file" && echo "$PRESET_API_VERSION")
    if [ "$local_api_version" = "1" ]; then
        pass "$preset_name: API version is 1"
    else
        fail "$preset_name: unexpected API version: $local_api_version"
    fi
done

summary
