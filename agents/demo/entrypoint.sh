#!/bin/bash
set -euo pipefail

# --- SSH Key Setup ---
if [ -f /run/secrets/authorized_keys ]; then
    cp /run/secrets/authorized_keys /home/agent/.ssh/authorized_keys
elif [ -n "${AUTHORIZED_KEYS:-}" ]; then
    echo "$AUTHORIZED_KEYS" > /home/agent/.ssh/authorized_keys
fi
if [ -f /home/agent/.ssh/authorized_keys ]; then
    chmod 600 /home/agent/.ssh/authorized_keys
    chown agent:agent /home/agent/.ssh/authorized_keys
fi

# --- Proxy Environment (propagate to agent user shell) ---
if [ -n "${HTTP_PROXY:-}" ]; then
    {
        echo "export HTTP_PROXY='${HTTP_PROXY}'"
        echo "export HTTPS_PROXY='${HTTPS_PROXY:-$HTTP_PROXY}'"
        echo "export http_proxy='${HTTP_PROXY}'"
        echo "export https_proxy='${HTTPS_PROXY:-$HTTP_PROXY}'"
        echo "export NO_PROXY='localhost,127.0.0.1'"
        echo "export no_proxy='localhost,127.0.0.1'"
    } >> /home/agent/.bashrc
fi

# --- API Key Passthrough ---
for var in ANTHROPIC_API_KEY OPENAI_API_KEY; do
    if [ -n "${!var:-}" ]; then
        echo "export ${var}='${!var}'" >> /home/agent/.bashrc
    fi
done

# --- Agentbox State Dir ---
mkdir -p /workspace/.agentbox/demo
chown -R agent:agent /workspace/.agentbox

# --- SSH Host Keys ---
ssh-keygen -A 2>/dev/null

# --- Start SSHD ---
exec /usr/sbin/sshd -D -e
