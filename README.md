# agentbox

Minimal self-hosted sandbox for running AI coding agents on one cheap Ubuntu VPS.

## What This Is

One VPS. One hardened Docker container. SSH access. A persistent workspace. Egress restricted through a domain-allowlist proxy. A single control script. That's it.

agentbox gives you a safe-enough sandbox to run AI coding agents -- OpenCode, Codex CLI, Claude Code, OpenClaw -- without building infrastructure. No web dashboard. No control plane. No Kubernetes. No daemon inside the container. Just SSH, Docker Compose, and a bash script called `sandctl`.

The system implements three levels:
1. **Level 1 (Sandbox)**: A hardened Docker container with key-only SSH, dropped capabilities, resource limits, and all egress forced through a Squid proxy with a domain allowlist.
2. **Level 2 (Workspace)**: File operations and command execution over the SSH boundary. No API. No injected daemon.
3. **Level 3 (Runtime)**: Start a background agent, inspect its status, tail logs, restart it, recover it after a reboot. One runtime at a time. Host-driven over SSH.

## What This Is Not

- Not a multi-tenant platform
- Not a Kubernetes operator
- Not a web IDE or dashboard
- Not a replacement for [Daytona](https://daytona.io) or [OpenSandbox](https://github.com/nichochar/open-sandbox) at scale
- Not DLP-grade containment or breakout-hardened isolation

Those are Level 4. This is Level 3. See [docs/so-you-want-to-build-your-own-sandbox.md](docs/so-you-want-to-build-your-own-sandbox.md) for the full framing.

## Quick Start

### Prerequisites

- Ubuntu 22.04 or 24.04 VPS (2+ CPU, 4GB+ RAM recommended)
- Root access
- Works on AWS, Hetzner, DigitalOcean, or any VPS provider

### Install

```bash
git clone https://github.com/kishandahya/agentbox.git
cd agentbox
sudo AGENTBOX_PRESET=opencode ./install.sh
```

No API keys required -- agentbox uses ChatGPT OAuth by default (via the `opencode-openai-codex-auth` plugin). API keys are supported as an optional fallback.

The installer:
- Checks for Ubuntu 22.04/24.04
- Installs Docker if needed (official apt repo, not snap)
- Generates an ed25519 SSH keypair
- Renders the Squid proxy config
- Sets up iptables egress rules
- Builds and starts the stack
- Symlinks `sandctl` to `/usr/local/bin`

### First-time Auth Setup

After install, complete the one-time ChatGPT OAuth login:

```bash
sandctl ssh                    # SSH into the sandbox
opencode auth login            # Prints a URL -- copy it
# Open the URL in your browser, complete the OAuth flow
# Paste the result back into the terminal
exit                           # Return to host
sandctl run                    # Start the agent
```

This uses your ChatGPT Max/Plus subscription. Models available include `gpt-5.2`, `gpt-5.2-codex`, `gpt-5.1-codex-max`, `gpt-5.1-codex`, `gpt-5.1-codex-mini`, and `gpt-5.1`. For headless/SSH environments, the plugin supports a manual URL paste mode (no browser needed on the server).

### Run the OpenCode Agent

```bash
sandctl run                    # Start OpenCode server in background
sandctl ps                     # Check runtime status
sandctl runtime logs -f        # Tail runtime logs
sandctl ssh                    # SSH into the sandbox
sandctl stop                   # Stop the runtime
```

### Workspace Commands

```bash
sandctl write-file hello.py <<< 'print("hello from the sandbox")'
sandctl read-file hello.py
sandctl workspace exec -- python3 hello.py
sandctl upload local_file.txt
sandctl download remote_file.txt ./local_copy.txt
sandctl list-files
```

### Sandbox Management

```bash
sandctl status                 # Show container status
sandctl logs                   # View container logs
sandctl agent list             # List available presets
sandctl agent use claude       # Switch to Claude preset
sandctl restart                # Rebuild and restart
sandctl egress reload          # Reload proxy allowlist after editing
sandctl doctor                 # Run health checks
sandctl doctor --fix           # Attempt automatic fixes
```

## Architecture

```
┌─────────────────────────────────────────────────┐
│  Ubuntu VPS (Host)                              │
│                                                 │
│  ┌───────────┐    ┌──────────────┐              │
│  │  sandbox   │───>│ egress-proxy │───> Internet │
│  │  (SSH:2222)│    │ (Squid:3128) │              │
│  │  /workspace│    │  allowlist   │              │
│  └───────────┘    └──────────────┘              │
│       │                                         │
│  sandctl (host)                                 │
│  systemd unit                                   │
└─────────────────────────────────────────────────┘
```

- The sandbox container has **zero direct internet access**
- All egress goes through the Squid proxy, filtered by domain allowlist
- The host communicates with the sandbox exclusively over SSH
- See [docs/architecture.md](docs/architecture.md) for full details

## Security Model

What's enforced:
- Dropped ALL capabilities, then add back only the minimum (CHOWN, DAC_OVERRIDE, FOWNER, SETUID, SETGID, SYS_CHROOT, AUDIT_WRITE, KILL -- required for sshd). No NET_RAW, no SYS_ADMIN, no NET_ADMIN.
- `no-new-privileges` security option
- CPU (2 cores), memory (4GB), PID (512) limits
- Restricted tmpfs for /tmp (noexec, nosuid, 512MB)
- Key-only SSH with password auth and port forwarding disabled
- No Docker socket mounted inside the container
- Deny-by-default egress through Squid proxy with domain allowlist
- Fixed Docker subnets with iptables DOCKER-USER rules
- IPv6 blocked from sandbox

What's NOT enforced:
- This is not breakout-hardening. A Docker escape 0-day breaks everything.
- Any allowlisted domain is an exfiltration path if you give the agent credentials or sensitive data.
- This is safe enough for a single developer running risky code. It is not multi-tenant isolation.

See [docs/threat-model.md](docs/threat-model.md) for the full threat model.

## Agent Presets

| Preset   | Mode       | Description                      | Required Keys                  |
|----------|------------|----------------------------------|--------------------------------|
| opencode | background | OpenCode headless server         | none (ChatGPT OAuth default)   |
| codex    | manual     | OpenAI Codex CLI via SSH         | none (ChatGPT OAuth default)   |
| claude   | manual     | Claude Code CLI via SSH          | none (ANTHROPIC_API_KEY if used with Anthropic API) |
| openclaw | manual     | OpenClaw via SSH                 | none (ChatGPT OAuth default)   |
| demo     | background | Deterministic test agent (no API keys) | none                   |

**Background** presets support `sandctl run/stop/ps` for managed lifecycle.
**Manual** presets are SSH-first: use `sandctl ssh` and run the agent interactively.

### Adding Your Own Preset

Create `agents/<name>/` with:
- `agent.env` -- preset contract (see any existing preset for the format)
- `Dockerfile` -- builds the sandbox image with your agent installed
- `entrypoint.sh` -- handles SSH setup, proxy config, API key passthrough

Then: `sandctl agent use <name> && sandctl restart`

## Editing the Egress Allowlist

```bash
vim /opt/agentbox/egress/allowlist.txt   # Add/remove domains
sandctl egress reload                     # Apply changes (no restart needed)
```

One domain per line. Leading dot matches subdomains:
```
.openai.com
.anthropic.com
.github.com
```

## Cloud Provider Notes

**AWS**: Works on Ubuntu 22.04/24.04 AMIs. Ensure your security group allows inbound on port 22 (host SSH) and 2222 (sandbox SSH, or whatever AGENTBOX_SSH_PORT you set). No AWS-specific configuration needed.

**Hetzner**: Works on standard Ubuntu images. Both dedicated and cloud (CX/CPX) instances work. No special configuration.

**Other**: Any Ubuntu 22.04/24.04 VPS with root access works. Minimum recommended: 2 CPU, 4GB RAM, 20GB disk.

## Testing

```bash
# Unit tests (no Docker needed)
bash tests/run_all.sh --unit

# Integration tests (requires running stack)
bash tests/run_all.sh --integration

# All tests
bash tests/run_all.sh --all
```

## Extending to Level 4

This repo stops at Level 3 intentionally. Level 4 is the platform layer: lifecycle APIs, container pools, multi-user auth, snapshots, warm pools, web terminals. That's where [Daytona](https://daytona.io) and [OpenSandbox](https://github.com/nichochar/open-sandbox) live.

The path from Level 3 to Level 4:
1. Replace `sandctl` bash script with an API server (Go or Rust)
2. Add container pooling (pre-built images, warm starts)
3. Add user authentication and authorization
4. Add a database for state management (replace runtime.json)
5. Add snapshot/restore for workspaces
6. Add a web terminal frontend

See [docs/so-you-want-to-build-your-own-sandbox.md](docs/so-you-want-to-build-your-own-sandbox.md) for the full design article.

## Command Reference

### Level 1 (Sandbox)
| Command | Description |
|---------|-------------|
| `sandctl up` | Start the sandbox stack |
| `sandctl down` | Stop the sandbox stack |
| `sandctl restart` | Restart (rebuild) the stack |
| `sandctl status` | Show container status |
| `sandctl logs [--tail N]` | View container logs |
| `sandctl ssh [cmd]` | SSH into sandbox |
| `sandctl agent list` | List available presets |
| `sandctl agent use <name>` | Switch preset |
| `sandctl egress reload` | Reload proxy config |
| `sandctl doctor [--fix]` | Health check |

### Level 2 (Workspace)
| Command | Description |
|---------|-------------|
| `sandctl workspace exec -- <cmd>` | Execute command in /workspace |
| `sandctl read-file <path>` | Read file to stdout |
| `sandctl write-file <path>` | Write stdin to file |
| `sandctl list-files [depth]` | List workspace files |
| `sandctl upload <local> [remote]` | Upload file |
| `sandctl download <remote> [local]` | Download file |

### Level 3 (Runtime)
| Command | Description |
|---------|-------------|
| `sandctl run` | Start background agent |
| `sandctl stop` | Stop background agent |
| `sandctl ps` | Show runtime status |
| `sandctl runtime logs [-f]` | View agent logs |
| `sandctl runtime restart` | Restart agent |

## License

MIT
