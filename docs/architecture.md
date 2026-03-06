# Agentbox Architecture

## Overview

Agentbox is a sandboxed execution environment for AI coding agents running on a single Ubuntu VPS. It provides three levels of functionality:

- **Level 1 (Sandbox):** A hardened Docker container with deny-by-default egress filtering via a Squid forward proxy. The container drops all capabilities, enforces resource limits, and has no direct internet access.
- **Level 2 (Workspace):** SSH-based file and command operations. No Docker socket mount, no HTTP API, no injected daemon. Just SSH/SFTP wrapping via `sandctl`.
- **Level 3 (Runtime):** Background agent lifecycle management. Start, stop, health check, log tailing, and autostart-on-reboot -- all driven through SSH and PID files.

The control tool is `sandctl`, a single bash script that wraps `docker compose`, `ssh`, and `scp`. There is no server process, no database, no API endpoint. State is a JSON file and a PID file.

---

## System Diagram

```
┌─────────────────────────────────────────────────────────┐
│  Ubuntu VPS (Host)                                      │
│                                                         │
│  sandctl ──SSH──┐         systemd: agentbox.service     │
│                 │                                       │
│  ┌──────────────▼──────────────┐                        │
│  │  Docker Compose             │                        │
│  │                             │                        │
│  │  ┌─────────────┐  proxy-net │  ┌──────────────┐     │
│  │  │   sandbox    │◄─────────►│  │ egress-proxy │     │
│  │  │  (SSH:22)    │  internal │  │ (Squid:3128) │     │
│  │  │  /workspace  │          │  └──────┬───────┘     │
│  │  └─────────────┘          │         │ egress-net   │
│  │    sandbox-net (internal)  │         │ (external)   │
│  └────────────────────────────┘         │              │
│                                         ▼              │
│                                     Internet           │
│                                   (allowlisted only)   │
└─────────────────────────────────────────────────────────┘
```

The host talks to the sandbox exclusively via SSH (port 2222 on the host mapped to port 22 in the container). The sandbox talks to the internet exclusively through the Squid egress proxy. There is no other path.

---

## Network Topology

Three Docker networks, each with a fixed subnet:

- **sandbox-net** (`172.30.0.0/24`, `internal: true`): The sandbox's isolated network. Marked internal, so Docker does not attach it to any bridge with external access. The sandbox sits on this network for intra-container isolation. No traffic from this network can reach the internet.

- **proxy-net** (`172.30.1.0/24`, `internal: true`): Communication channel between the sandbox and the egress proxy. Also internal -- no external access. The sandbox and egress-proxy both attach to this network. The sandbox sends HTTP(S) requests to `egress-proxy:3128` over this network.

- **egress-net** (`172.30.2.0/24`, `internal: false`): The only network with external access. Only the egress-proxy container is attached to it. This is where filtered traffic exits to the internet.

The sandbox is on `sandbox-net` and `proxy-net`. The proxy is on `proxy-net` and `egress-net`. This means the sandbox can talk to the proxy but cannot reach the internet directly. The proxy is the only container that can reach the internet, and it only forwards traffic to allowlisted domains.

Fixed subnets matter. Dynamic IPs would make iptables rules unreliable. With fixed subnets, we can write deterministic firewall rules that reference `172.30.0.0/24` and know exactly what traffic they match.

---

## Egress Data Flow

Here's what happens when the sandbox makes an HTTPS request (e.g., `curl https://api.openai.com/v1/chat`):

1. The sandbox process makes the HTTPS request. The `HTTP_PROXY` and `HTTPS_PROXY` environment variables (set in `compose.yaml`) route it to `egress-proxy:3128`.

2. The HTTP client sends a `CONNECT api.openai.com:443` request to the Squid proxy.

3. Squid receives the `CONNECT` request and extracts the target hostname from the SNI (Server Name Indication) field.

4. Squid checks the hostname against `/etc/squid/allowlist.txt`, which is configured as a `dstdomain` ACL in `squid.conf`:
   ```
   acl allowlist dstdomain "/etc/squid/allowlist.txt"
   http_access allow localnet allowlist
   ```

5. **If allowed:** Squid establishes a TCP tunnel to the target. The TLS handshake happens end-to-end between the sandbox and the destination. Squid sees the SNI hostname but not the request body, URL path, or response content.

6. **If denied:** Squid returns a 403 and drops the connection. The request never leaves the proxy.

7. **No MITM.** Squid does not use `ssl_bump`. It does not inject a CA certificate. It does not decrypt traffic. This means we can filter by domain name but not by URL path, request body, or response content.

The implication: any allowlisted domain is a potential exfiltration path. If you allowlist `github.com` and the agent has a GitHub token, it can push arbitrary data there. This is a deliberate tradeoff -- SNI filtering is simple, transparent, and doesn't break TLS. Content inspection would require MITM, which breaks certificate pinning and adds significant complexity. See the [threat model](threat-model.md) for a full discussion.

---

## SSH Boundary Model

The host communicates with the sandbox container exclusively via SSH. This is the most important architectural decision in agentbox.

- SSH listens on port 22 inside the container, mapped to port `${AGENTBOX_SSH_PORT:-2222}` on the host.
- Authentication is key-only (ed25519). Password authentication is disabled in `sshd_config`. Port forwarding is disabled. X11 forwarding is disabled.
- The SSH public key is mounted into the container as a read-only secret: `/run/secrets/authorized_keys`.
- The SSH private key lives on the host at `/opt/agentbox/id_agentbox`.

`sandctl` wraps SSH for all Level 2 and Level 3 operations:

```bash
# Non-interactive command execution
_ssh() {
    ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -i "$AGENTBOX_DIR/id_agentbox" \
        -p "$AGENTBOX_SSH_PORT" \
        agent@localhost "$@"
}
```

What this buys us:

- **No Docker socket mount.** The sandbox cannot interact with the Docker daemon. It cannot create containers, inspect the host, or escape via the Docker API.
- **No injected daemon.** There's no custom process running inside the container that could be exploited. SSH is battle-tested and well-understood.
- **No HTTP API.** No TLS certificates to manage, no auth tokens, no additional attack surface.
- **SFTP for free.** File transfer works via `scp`/`sftp` over the same SSH connection. No additional protocol needed.

The tradeoff: SSH adds ~50ms of latency per command invocation (key exchange, channel setup). For interactive use this is invisible. For tight automation loops with thousands of small commands, it adds up. At that point you'd want a persistent SSH session or a different protocol. For Level 3 (one long-running agent process), it doesn't matter.

---

## Volume Layout

### Container-side

```
/workspace/                          # Persistent Docker volume (survives container restarts)
/workspace/.agentbox/                # Agentbox state directory
/workspace/.agentbox/runtime.pid     # PID of background agent process
/workspace/.agentbox/<preset>/       # Preset-specific state
/workspace/.agentbox/opencode/       #   e.g., opencode server logs
/workspace/.agentbox/opencode/server.log
```

The `/workspace` volume is a named Docker volume (`agentbox-workspace`). It persists across container restarts and rebuilds. It is the only persistent storage in the sandbox. Everything outside `/workspace` (system packages, config files, etc.) is ephemeral and rebuilt from the Dockerfile.

`/tmp` is a `tmpfs` mount with `noexec`, `nosuid`, and a 512MB size limit. This prevents the agent from using `/tmp` to store or execute large payloads outside the persistent volume.

### Host-side

```
/opt/agentbox/                       # Installation directory
/opt/agentbox/.env                   # Environment config (preset, SSH port, API keys)
/opt/agentbox/id_agentbox            # SSH private key (ed25519)
/opt/agentbox/id_agentbox.pub        # SSH public key
/opt/agentbox/compose.yaml           # Docker Compose definition
/opt/agentbox/egress/                # Squid config and allowlist
/opt/agentbox/egress/squid.conf      # Rendered Squid config
/opt/agentbox/egress/allowlist.txt   # Domain allowlist (user-editable)
/opt/agentbox/agents/                # Preset definitions
/opt/agentbox/state/                 # Host-side state
/opt/agentbox/state/runtime.json     # Autostart intent (survives reboots)
```

---

## Preset System

Each agent preset is a directory under `agents/` containing three files:

- `agent.env` -- Declares the preset contract
- `Dockerfile` -- Builds the sandbox image
- `entrypoint.sh` -- Container entrypoint (SSH + proxy + key setup)

### The agent.env Contract

Every preset defines:

```bash
PRESET_API_VERSION=1          # Contract version
AGENT_ID=opencode             # Unique preset identifier
BASE_IMAGE=ubuntu:24.04       # Base Docker image
DEFAULT_CMD=/bin/bash          # Default command for interactive sessions
DEFAULT_WORKDIR=/workspace     # Working directory
REQUIRED_ENV_VARS=""                   # Vars that must be set in .env (empty = OAuth default)
START_MODE=background          # "background" or "manual"
```

Background presets (`START_MODE=background`) add:

```bash
START_CMD="opencode server --host 127.0.0.1 --port 3000"
HEALTHCHECK_CMD="curl -sf http://127.0.0.1:3000/health"
LOG_PATH=/workspace/.agentbox/opencode/server.log
ACCESS_MODE=ssh
EXPOSE_PORTS=""
```

Manual presets (`START_MODE=manual`) omit the background fields. They're for agents like `codex`, `claude`, and `openclaw` whose CLIs are interactive and don't have a headless server mode.

### Authentication Model

Agentbox uses **ChatGPT OAuth** as the default authentication method for all presets (except `demo`). This is powered by the [`opencode-openai-codex-auth`](https://www.npmjs.com/package/opencode-openai-codex-auth) plugin, which enables ChatGPT Max/Plus subscription-based access to GPT-5.x and Codex models without requiring API keys.

**How it works:**

1. The plugin is installed during the Docker image build (`npm install -g opencode-openai-codex-auth@latest`).
2. On first boot, the user SSHs in and runs `opencode auth login`, which initiates an OAuth flow via `auth.openai.com`.
3. The user copies a URL into their browser, completes the ChatGPT login, and pastes the result back. This works in headless/SSH environments (no browser needed on the server).
4. After authentication, the Codex backend at `chatgpt.com/backend-api` is used for model requests.

**Fallback:** API keys (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`) are still supported. If set in `.env`, they are passed through to the agent environment via the entrypoint. This lets users who prefer direct API access bypass the OAuth flow.

The egress allowlist includes `auth.openai.com` and `chatgpt.com` to support the OAuth flow and Codex backend traffic.

### How compose.yaml Uses Presets

```yaml
sandbox:
  build:
    context: .
    dockerfile: agents/${AGENTBOX_PRESET:-opencode}/Dockerfile
```

The `AGENTBOX_PRESET` variable (set in `.env`) selects which `Dockerfile` to build. Switching presets means changing this variable and rebuilding:

```bash
sandctl agent use opencode   # Updates .env, rebuilds image
sandctl restart              # Restarts with new image
```

---

## Container Hardening

Everything enforced in `compose.yaml`:

```yaml
security_opt:
  - no-new-privileges         # Prevent SUID/SGID escalation
cap_drop:
  - ALL                       # Drop ALL Linux capabilities
cpus: 2                       # CPU limit
mem_limit: 4g                 # Memory limit (hard)
memswap_limit: 4g             # No swap (same as mem_limit)
pids_limit: 512               # Process count limit (prevents fork bombs)
tmpfs:
  - /tmp:size=512m,noexec,nosuid  # Temp dir: size-capped, no exec
restart: unless-stopped        # Auto-restart on crash
```

Notable absences:

- **No NET_RAW capability.** The agent can't use raw sockets or `ping`. This is deliberate -- `ping` isn't needed, and NET_RAW enables ARP spoofing and other network-level attacks.
- **No SYS_ADMIN.** No mounting filesystems, no namespace manipulation.
- **No Docker socket mount.** The sandbox has zero awareness of Docker.
- **No `deploy.resources` syntax.** We use the compose v2 shorthand (`cpus`, `mem_limit`) because it works without Docker Swarm. The `deploy` key requires swarm mode or `--compatibility` flag.

---

## iptables Rules

Belt-and-suspenders defense layered on top of Docker's internal network isolation. These rules live in the `DOCKER-USER` chain, which Docker evaluates before its own rules:

```bash
# Allow established connections (responses to outbound requests)
iptables -I DOCKER-USER 1 -m conntrack --ctstate ESTABLISHED,RELATED \
    -m comment --comment "agentbox-rule" -j RETURN

# Allow sandbox -> proxy on port 3128 (the egress path)
iptables -I DOCKER-USER 2 -s 172.30.0.0/24 -d 172.30.1.0/24 \
    -p tcp --dport 3128 -m comment --comment "agentbox-rule" -j RETURN

# Drop all other traffic from sandbox to external destinations
iptables -I DOCKER-USER 3 -s 172.30.0.0/24 ! -d 172.30.0.0/16 \
    -m comment --comment "agentbox-rule" -j DROP

# IPv6: block all sandbox traffic (defense in depth)
ip6tables -A DOCKER-USER -s 172.30.0.0/24 \
    -m comment --comment "agentbox-rule" -j DROP
```

Why this matters: Docker's `internal: true` network flag prevents external routing at the Docker level. The iptables rules are a second layer in case Docker's network isolation has bugs or is misconfigured. Fixed subnets make these rules deterministic -- we always know `172.30.0.0/24` is the sandbox.

Rules are persisted via `iptables-persistent` / `netfilter-persistent` so they survive host reboots. If persistence fails, the rules are re-applied by `install.sh` on next run. The `sandctl doctor` command checks for their presence.

---

## Systemd Integration

`agentbox.service` is a oneshot systemd unit:

```ini
[Unit]
Description=Agentbox Sandbox Stack
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/agentbox
ExecStart=/usr/bin/docker compose up -d
ExecStartPost=-/opt/agentbox/sandctl _autostart
ExecStop=/usr/bin/docker compose down
ExecReload=/usr/bin/docker compose restart
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
```

Key details:

- **`Type=oneshot` with `RemainAfterExit=yes`:** The service "starts" by running `docker compose up -d` (which returns immediately after containers are started), then stays in the `active` state. This lets `systemctl stop agentbox` trigger the `ExecStop` to tear down the stack.
- **`ExecStartPost=-/opt/agentbox/sandctl _autostart`:** After containers are up, attempt to restore the agent runtime. The `-` prefix means a failure here doesn't fail the unit. The `_autostart` command reads `state/runtime.json`, waits for SSH to become ready (up to 60 seconds), and calls `cmd_run` to restart the background agent.
- **`After=docker.service` + `Requires=docker.service`:** Ensures Docker is running before we try to start containers.

The unit is installed and enabled by `install.sh`:
```bash
cp "$AGENTBOX_DIR/systemd/agentbox.service" /etc/systemd/system/agentbox.service
systemctl daemon-reload
systemctl enable agentbox
```

---

## State Management

State lives in two places, each with different lifecycle:

### 1. Container-side: `/workspace/.agentbox/`

- **Stored in:** The `agentbox-workspace` Docker volume, mounted at `/workspace`.
- **Contents:** PID file (`runtime.pid`), agent logs, preset-specific state.
- **Lifecycle:** Survives container restarts and image rebuilds. Lost only if the Docker volume is explicitly deleted (`docker volume rm agentbox_agentbox-workspace`).
- **Who writes:** The agent process (logs) and `sandctl` via SSH (PID file, directory creation).

### 2. Host-side: `/opt/agentbox/state/`

- **Stored in:** The host filesystem.
- **Contents:** `runtime.json` -- a JSON file recording the autostart intent (which preset to run, whether autostart is enabled, when it was started).
- **Lifecycle:** Survives host reboots. Written by `sandctl run`, deleted by `sandctl stop`.
- **Who reads:** `sandctl _autostart` during boot (called by systemd `ExecStartPost`).

Example `runtime.json`:
```json
{"preset":"opencode","autostart":true,"started":"2025-01-15T10:30:00+00:00"}
```

This two-location design means:
- Container restart → PID file survives (in volume), autostart intent survives (on host). Runtime process is gone but `_autostart` can relaunch it.
- Host reboot → Containers restart via systemd, `_autostart` reads `runtime.json` and relaunches the agent.
- Volume deletion → PID file and logs are lost. Agent needs manual restart. Host-side intent is stale but harmless (agent will be restarted, which is the correct behavior).
