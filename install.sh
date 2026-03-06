#!/usr/bin/env bash
set -euo pipefail

# --- Configuration ---
AGENTBOX_DIR="${AGENTBOX_DIR:-/opt/agentbox}"
AGENTBOX_PRESET="${AGENTBOX_PRESET:-opencode}"
AGENTBOX_SSH_PORT="${AGENTBOX_SSH_PORT:-2222}"

# --- Cloud Provider Notes ---
# AWS: Works on Ubuntu 22.04/24.04 AMIs. Ensure security group allows
#   inbound on port 22 (host SSH) and AGENTBOX_SSH_PORT (sandbox SSH).
#   No additional AWS-specific configuration needed.
#
# Hetzner: Works on standard Ubuntu images. No special configuration.
#   Both dedicated and cloud (CX/CPX) instances are supported.
#
# Other providers: Any Ubuntu 22.04/24.04 VPS with root access works.
#   Minimum recommended: 2 CPU, 4GB RAM, 20GB disk.

# Directory where this script lives (the repo checkout)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo "[agentbox] $(date '+%H:%M:%S') $*"; }

check_root() {
    [ "$(id -u)" -eq 0 ] || { log "ERROR: must run as root"; exit 1; }
}

check_os() {
    if [ ! -f /etc/os-release ]; then
        log "ERROR: /etc/os-release not found. Is this Ubuntu?"
        exit 1
    fi

    # shellcheck disable=SC1091
    . /etc/os-release

    if [ "$ID" != "ubuntu" ]; then
        log "ERROR: Unsupported OS: $ID. Only Ubuntu 22.04 and 24.04 are supported."
        exit 1
    fi

    if [ "$VERSION_ID" != "22.04" ] && [ "$VERSION_ID" != "24.04" ]; then
        log "ERROR: Unsupported Ubuntu version: $VERSION_ID. Only 22.04 and 24.04 are supported."
        exit 1
    fi

    log "OS check passed: Ubuntu $VERSION_ID"
}

install_docker() {
    if command -v docker &>/dev/null && docker compose version &>/dev/null; then
        log "Docker already installed ($(docker --version))"
        return 0
    fi

    log "Installing Docker via official apt repository..."

    # Install prerequisites
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg

    # Add Docker GPG key
    install -m 0755 -d /etc/apt/keyrings
    if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
    fi

    # Add Docker apt repository
    # shellcheck disable=SC1091
    . /etc/os-release
    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
        ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list

    # Install Docker packages
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin

    # Enable and start
    systemctl enable docker
    systemctl start docker

    # Verify
    docker compose version
    log "Docker installed successfully."
}

install_iptables_persistent() {
    if dpkg -l iptables-persistent &>/dev/null; then
        log "iptables-persistent already installed"
        return 0
    fi

    log "Installing iptables-persistent..."
    # Pre-seed debconf to avoid interactive prompts
    echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
    echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
    apt-get install -y -qq iptables-persistent
    log "iptables-persistent installed."
}

copy_repo_files() {
    mkdir -p "$AGENTBOX_DIR"

    # If we're already running from AGENTBOX_DIR, skip the copy
    if [ "$SCRIPT_DIR" = "$AGENTBOX_DIR" ]; then
        log "Already running from $AGENTBOX_DIR, skipping copy."
        return 0
    fi

    log "Copying repo files to $AGENTBOX_DIR..."
    # Use rsync if available (preserves everything, handles deletions of old files)
    # Fall back to cp -a for each component
    if command -v rsync &>/dev/null; then
        rsync -a --exclude='.git' --exclude='.env' --exclude='id_agentbox*' \
              --exclude='egress/squid.conf' --exclude='egress/allowlist.txt' \
              --exclude='state/' \
              "$SCRIPT_DIR/" "$AGENTBOX_DIR/"
    else
        # Core files
        cp -a "$SCRIPT_DIR/compose.yaml" "$AGENTBOX_DIR/"
        cp -a "$SCRIPT_DIR/install.sh" "$AGENTBOX_DIR/"
        cp -a "$SCRIPT_DIR/egress" "$AGENTBOX_DIR/"
        cp -a "$SCRIPT_DIR/systemd" "$AGENTBOX_DIR/"
        cp -a "$SCRIPT_DIR/agents" "$AGENTBOX_DIR/"

        # sandctl
        [ -f "$SCRIPT_DIR/sandctl" ] && cp -a "$SCRIPT_DIR/sandctl" "$AGENTBOX_DIR/"

        # Tests and scripts
        [ -d "$SCRIPT_DIR/tests" ] && cp -a "$SCRIPT_DIR/tests" "$AGENTBOX_DIR/"
        [ -d "$SCRIPT_DIR/scripts" ] && cp -a "$SCRIPT_DIR/scripts" "$AGENTBOX_DIR/"
        [ -d "$SCRIPT_DIR/docs" ] && cp -a "$SCRIPT_DIR/docs" "$AGENTBOX_DIR/"

        # Other top-level files
        for f in .env.example LICENSE README.md SKILL.md; do
            [ -f "$SCRIPT_DIR/$f" ] && cp -a "$SCRIPT_DIR/$f" "$AGENTBOX_DIR/" || true
        done
    fi

    log "Files copied to $AGENTBOX_DIR."
}

generate_ssh_keys() {
    if [ -f "$AGENTBOX_DIR/id_agentbox" ]; then
        log "SSH keys already exist at $AGENTBOX_DIR/id_agentbox"
        return 0
    fi

    log "Generating ed25519 SSH keypair..."
    ssh-keygen -t ed25519 -f "$AGENTBOX_DIR/id_agentbox" -N "" -C "agentbox"
    chmod 600 "$AGENTBOX_DIR/id_agentbox"
    chmod 644 "$AGENTBOX_DIR/id_agentbox.pub"
    log "SSH keys generated."
}

write_env_file() {
    local preset_env="$AGENTBOX_DIR/agents/$AGENTBOX_PRESET/agent.env"

    if [ ! -f "$preset_env" ]; then
        log "ERROR: Preset '$AGENTBOX_PRESET' not found at $preset_env"
        log "Available presets:"
        ls -1 "$AGENTBOX_DIR/agents/" 2>/dev/null || true
        exit 1
    fi

    # Source the preset's agent.env to get REQUIRED_ENV_VARS and other settings
    # shellcheck disable=SC1090
    . "$preset_env"

    # Validate required env vars
    if [ -n "${REQUIRED_ENV_VARS:-}" ]; then
        for var in $REQUIRED_ENV_VARS; do
            if [ -z "${!var:-}" ]; then
                log "ERROR: Required environment variable $var is not set."
                log "Run with: sudo $var=<value> ./install.sh"
                exit 1
            fi
        done
    fi

    # Back up existing .env if present
    if [ -f "$AGENTBOX_DIR/.env" ]; then
        local backup="$AGENTBOX_DIR/.env.backup.$(date '+%Y%m%d%H%M%S')"
        cp "$AGENTBOX_DIR/.env" "$backup"
        log "Backed up existing .env to $backup"
    fi

    # Write .env file
    log "Writing .env file..."
    {
        echo "# Agentbox environment -- generated by install.sh on $(date)"
        echo "AGENTBOX_PRESET=$AGENTBOX_PRESET"
        echo "AGENTBOX_SSH_PORT=$AGENTBOX_SSH_PORT"
        echo "AGENTBOX_DIR=$AGENTBOX_DIR"
        # Write required env vars from the environment
        if [ -n "${REQUIRED_ENV_VARS:-}" ]; then
            for var in $REQUIRED_ENV_VARS; do
                echo "$var=${!var}"
            done
        fi
    } > "$AGENTBOX_DIR/.env"
    chmod 600 "$AGENTBOX_DIR/.env"

    log ".env written to $AGENTBOX_DIR/.env"
}

render_squid_config() {
    # Copy allowlist base if user hasn't created a custom one yet
    if [ ! -f "$AGENTBOX_DIR/egress/allowlist.txt" ]; then
        log "Creating egress/allowlist.txt from base template..."
        cp "$AGENTBOX_DIR/egress/allowlist.base.txt" "$AGENTBOX_DIR/egress/allowlist.txt"
    else
        log "egress/allowlist.txt already exists, leaving as-is."
    fi

    # Always re-render squid.conf from template (template may have changed)
    log "Rendering egress/squid.conf from template..."
    sed \
        -e 's/{{CACHE_MEM}}/256/g' \
        -e 's/{{MAX_OBJ_SIZE}}/64/g' \
        "$AGENTBOX_DIR/egress/squid.conf.template" > "$AGENTBOX_DIR/egress/squid.conf"

    log "Squid configuration rendered."
}

setup_iptables() {
    log "Configuring iptables rules for sandbox network isolation..."

    local SANDBOX_NET="172.30.0.0/24"
    local PROXY_NET="172.30.1.0/24"
    local DOCKER_RANGE="172.30.0.0/16"

    # Ensure DOCKER-USER chain exists (Docker creates it, but handle edge case)
    iptables -N DOCKER-USER 2>/dev/null || true

    # Rule 1: Allow established/related connections
    iptables -C DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment "agentbox-rule" -j RETURN 2>/dev/null \
        || iptables -I DOCKER-USER 1 -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment "agentbox-rule" -j RETURN

    # Rule 2: Allow sandbox -> proxy on port 3128
    iptables -C DOCKER-USER -s "$SANDBOX_NET" -d "$PROXY_NET" -p tcp --dport 3128 -m comment --comment "agentbox-rule" -j RETURN 2>/dev/null \
        || iptables -I DOCKER-USER 2 -s "$SANDBOX_NET" -d "$PROXY_NET" -p tcp --dport 3128 -m comment --comment "agentbox-rule" -j RETURN

    # Rule 3: Drop all other sandbox external traffic
    iptables -C DOCKER-USER -s "$SANDBOX_NET" ! -d "$DOCKER_RANGE" -m comment --comment "agentbox-rule" -j DROP 2>/dev/null \
        || iptables -I DOCKER-USER 3 -s "$SANDBOX_NET" ! -d "$DOCKER_RANGE" -m comment --comment "agentbox-rule" -j DROP

    # Rule 4: Return for everything else (catch-all at end)
    iptables -C DOCKER-USER -m comment --comment "agentbox-rule" -j RETURN 2>/dev/null \
        || iptables -A DOCKER-USER -m comment --comment "agentbox-rule" -j RETURN

    # IPv6: drop ALL container IPv6 traffic in DOCKER-USER (defense in depth)
    # We use a blanket DROP for any traffic hitting DOCKER-USER over IPv6, since
    # agentbox uses IPv4-only Docker networks. Cannot use IPv4 subnets in ip6tables.
    ip6tables -N DOCKER-USER 2>/dev/null || true
    ip6tables -C DOCKER-USER -m comment --comment "agentbox-rule" -j DROP 2>/dev/null \
        || ip6tables -A DOCKER-USER -m comment --comment "agentbox-rule" -j DROP

    # Persist rules
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save
    elif [ -d /etc/iptables ]; then
        iptables-save > /etc/iptables/rules.v4
        ip6tables-save > /etc/iptables/rules.v6
    fi

    log "iptables rules configured."
}

install_sandctl() {
    if [ ! -f "$AGENTBOX_DIR/sandctl" ]; then
        log "WARNING: sandctl not found at $AGENTBOX_DIR/sandctl -- skipping symlink."
        return 0
    fi

    chmod +x "$AGENTBOX_DIR/sandctl"
    ln -sf "$AGENTBOX_DIR/sandctl" /usr/local/bin/sandctl
    log "sandctl installed to /usr/local/bin/sandctl"
}

install_systemd_unit() {
    log "Installing systemd unit..."
    cp "$AGENTBOX_DIR/systemd/agentbox.service" /etc/systemd/system/agentbox.service
    systemctl daemon-reload
    systemctl enable agentbox
    log "Systemd unit installed and enabled."
}

build_and_start() {
    log "Building and starting agentbox stack..."
    cd "$AGENTBOX_DIR"
    docker compose build
    docker compose up -d

    log "Waiting for SSH..."
    for i in $(seq 1 30); do
        if ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no -i "$AGENTBOX_DIR/id_agentbox" -p "$AGENTBOX_SSH_PORT" agent@localhost "echo ok" &>/dev/null; then
            log "SSH is ready."
            return 0
        fi
        sleep 2
    done
    log "WARNING: SSH did not become ready within 60s. Check: sandctl doctor"
}

print_summary() {
    cat <<EOF

=== Agentbox installed successfully ===

  SSH into sandbox:    ssh -i ${AGENTBOX_DIR}/id_agentbox -p ${AGENTBOX_SSH_PORT} agent@localhost
  Or use sandctl:      sandctl ssh
  Check status:        sandctl status
  View logs:           sandctl logs
  Run health check:    sandctl doctor

  Active preset:       ${AGENTBOX_PRESET}
  Workspace volume:    /workspace (persistent)

  To start the agent runtime:
    sandctl run

  Edit egress allowlist:
    vim ${AGENTBOX_DIR}/egress/allowlist.txt
    sandctl egress reload

EOF
}

main() {
    log "=== Agentbox Installer ==="
    check_root
    check_os
    install_docker
    install_iptables_persistent
    copy_repo_files
    cd "$AGENTBOX_DIR"
    generate_ssh_keys
    write_env_file
    render_squid_config
    setup_iptables
    install_sandctl
    install_systemd_unit
    build_and_start
    print_summary
}
main "$@"
