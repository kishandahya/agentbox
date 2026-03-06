# So You Want to Build Your Own Sandbox

## The Problem

AI agents need to run code. That's the whole point — you give them a task, they write code, they 
execute it, they iterate. But running arbitrary code from a language model on your machine is, to 
put it mildly, a terrible idea. You need a sandbox.

The word "sandbox" is overloaded to the point of uselessness. It can mean a Docker container with 
some flags set, a microVM fleet behind an API gateway, or anything in between. When someone says 
"we built a sandbox for AI agents," you have no idea what they actually built until you read the 
code.

This article defines four levels of sandbox architecture, explains the design decisions we made in 
agentbox, and lays out the path from where we stopped to where a production platform would need to 
go. We stopped at Level 3. Here's why.

## Level 1: The Container

Everything starts with Docker. You pull an image, you run it, you mount a volume for persistence. 
Congratulations, you have isolation in the same way that a screen door is a wall — technically 
present, trivially defeated.

The real work in Level 1 is hardening. The compose.yaml in agentbox drops every Linux capability, 
limits resources, and locks down the filesystem:

```yaml
cap_drop: [ALL]
cap_add: [CHOWN, DAC_OVERRIDE, FOWNER, SETUID, SETGID, SYS_CHROOT, AUDIT_WRITE, KILL]
cpus: 2
mem_limit: 4g
pids_limit: 512
security_opt: [no-new-privileges]
tmpfs: ["/tmp:size=512m,noexec,nosuid"]
```

`cap_drop: [ALL]` removes every Linux capability, then `cap_add` restores the minimum set that sshd 
actually needs to function: SETUID/SETGID for privilege dropping after auth, DAC_OVERRIDE and CHOWN 
for the entrypoint to set up SSH keys, SYS_CHROOT for sshd internals, AUDIT_WRITE for login records, 
and KILL for process signaling. Critically absent: no `NET_RAW` (no raw sockets, no ping, no ARP 
spoofing), no `SYS_ADMIN` (no mounting filesystems), no `NET_ADMIN` (no network configuration). 
`no-new-privileges` prevents setuid binaries from escalating. `pids_limit: 512` stops fork bombs. 
The `tmpfs` mount for `/tmp` is `noexec` and `nosuid`, so even if an agent writes a binary there, it 
can't execute it directly.

Why rootful Docker over rootless? Rootless Docker has real networking limitations — you lose the 
ability to create proper bridge networks with fixed subnets, which we need for egress control. 
Volume permissions become a maze of UID mapping. Debugging with `nsenter` or `docker exec` becomes 
harder. Rootful Docker with a properly hardened container is a well-understood, well-documented 
security boundary. The tradeoff is that the Docker daemon runs as root on the host. We accept that 
tradeoff because this is a single-user, single-host system and the daemon is not exposed to the 
network.

Why not Firecracker? Firecracker gives you a real VM boundary with a separate kernel, which is 
genuinely stronger isolation. But it requires KVM, which means bare metal or nested virtualization. 
It adds boot time, memory overhead, and operational complexity. For a single-user sandbox running 
on a developer's machine or a dedicated cloud instance, it's overkill. If you're building a 
multi-tenant platform, revisit this decision.

Why not gVisor? gVisor interposes on syscalls, which is elegant in theory. In practice, syscall 
compatibility is incomplete, debugging is harder (strace doesn't work the way you expect), and the 
performance overhead on filesystem-heavy workloads — which is exactly what coding agents produce 
— is noticeable. Docker with dropped capabilities gives us 90% of the isolation benefit with 10% 
of the debugging pain.

## Egress Control

The hardest problem in Level 1 is network filtering. An agent that can reach the internet can 
exfiltrate your code, download malware, or mine cryptocurrency. You need to control what it can 
talk to.

There are three approaches, and two of them are traps.

**Approach 1: iptables per-domain.** You resolve `registry.npmjs.org` to an IP, write an iptables 
rule allowing that IP, and block everything else. This fails immediately. DNS resolves to multiple 
IPs. Those IPs change. CDNs rotate addresses. You end up playing whack-a-mole with IP ranges, or 
you allow entire CIDR blocks and your "filtering" becomes theater. Worse, HTTPS traffic is 
encrypted — iptables can't see the SNI header, so you can't distinguish `good-api.example.com` 
from `evil-c2.example.com` when they share an IP.

**Approach 2: Transparent proxy with MITM.** You intercept all traffic, terminate TLS, inspect it, 
and re-encrypt with your own CA. This actually works for filtering, but it requires injecting a CA 
certificate into the container, which breaks certificate pinning (npm, pip, and curl all have 
opinions about this), and it means your proxy has access to all plaintext traffic. If the proxy is 
compromised, everything is compromised.

**Approach 3: Forward proxy with CONNECT tunneling.** The container's HTTP traffic goes through a 
proxy. For HTTPS, the client sends a `CONNECT` request with the hostname in plaintext, the proxy 
checks it against an allowlist, and if approved, opens a raw TCP tunnel to the destination. The 
proxy never sees the encrypted payload. This is boring and correct.

We use Squid. The network topology is Docker networks with fixed subnets: one for the sandbox (not 
marked internal, because Docker cannot publish host ports into containers on purely internal 
networks), one internal network connecting sandbox to proxy, and one external network for the proxy. 
The sandbox can only reach the proxy. The proxy can reach the internet. iptables rules in the 
`DOCKER-USER` chain are the real enforcement layer at the host level:

```bash
# Allow established connections (responses to outbound requests)
iptables -I DOCKER-USER 1 -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
# Allow sandbox -> proxy on port 3128 (the egress path)
iptables -I DOCKER-USER 2 -s 172.30.0.0/24 -d 172.30.1.0/24 -p tcp --dport 3128 -j RETURN
# Drop all other traffic from sandbox to external destinations
iptables -I DOCKER-USER 3 -s 172.30.0.0/24 ! -d 172.30.0.0/16 -j DROP
```

The Squid configuration is a simple domain allowlist. Adding a new allowed domain is a one-line 
change. The limitation is real: this is domain-level filtering only. Any allowlisted domain is a 
potential exfiltration path. If you allow `api.github.com`, an agent can push code there. If you 
allow `pypi.org`, an agent can publish a package with your secrets embedded. Perfect egress control 
requires content inspection, which puts you back in MITM territory. We chose the pragmatic middle 
ground: limit the blast radius, accept that a sufficiently motivated agent can still exfiltrate 
through allowed domains.

## Level 2: The Workspace

A sandbox you can't get files into or out of is useless. You need to copy code in, run commands, 
and extract results. There are four ways to do this.

**Docker exec** works but requires mounting the Docker socket into whatever tool is driving the 
sandbox. That socket is root-equivalent access to the host. Non-starter for any threat model that 
takes container escape seriously.

**A custom daemon** inside the container that exposes an HTTP API over a Unix socket or TCP port 
gives you fine-grained control, but it's another component to build, secure, audit, and maintain. 
It increases attack surface inside the container.

**An HTTP API on the host** that proxies commands into the container adds auth, TLS, and API design 
to your problem space. Now you're building a web service, not a sandbox.

**SSH and SFTP** are boring, correct, and already there. The container runs an SSH server. You 
connect with a key. `scp` handles file transfer. `ssh` handles command execution. The protocol is 
battle-tested, the auth model is well-understood, and every programming language has an SSH client 
library.

The `sandctl` workspace commands — `sandctl cp`, `sandctl exec`, `sandctl shell` — are thin 
wrappers around SSH. There's no cleverness. `sandctl cp` calls `scp`. `sandctl exec` calls `ssh` 
with the command as an argument. `sandctl shell` calls `ssh` with a TTY allocated. This is Level 2: 
you can interact with the sandbox programmatically.

## Level 3: The Runtime

Agents don't run a single command and exit. They run in the background for hours. They need to 
survive network disconnects. You need to check if they're alive, tail their logs, restart them when 
they crash, and bring them back after a host reboot.

The model in agentbox is deliberately simple. An agent starts via SSH with `nohup`, writing its PID 
to a file on the persistent volume. Health checks connect over SSH and check the PID. Logs go to a 
file on the persistent volume and are tailed over SSH. The host maintains a `runtime.json` state 
file that records which agents should be running — their "autostart intent." A systemd 
`ExecStartPost` hook reads this file after the sandbox container starts and relaunches agents that 
were running before the reboot.

Take opencode as the concrete example. `sandctl agent start opencode` SSHs into the container, runs 
opencode in the background with `nohup`, writes the PID, and records the intent in `runtime.json`. 
`sandctl agent status opencode` SSHs in, checks the PID, reports alive or dead. `sandctl agent logs 
opencode` tails the log file over SSH. If the host reboots, systemd starts the sandbox container, 
the `ExecStartPost` script reads `runtime.json`, and re-launches opencode.

Not every agent fits this model. Codex, Claude Code, and OpenClaw are configured for manual mode 
— their CLIs are interactive, expecting a TTY and human input. You can't background them 
meaningfully. For these, `sandctl shell` drops you into an SSH session where you run them 
interactively. The runtime model only applies to agents that can run headless.

This is Level 3: sandbox, workspace interaction, and managed agent lifecycle on a single host.

## Level 4: The Platform (and Why We Stopped)

Level 4 is everything that makes a sandbox into a product: multiple sandboxes, multiple users, 
API-driven lifecycle, database-backed state, snapshots, web terminals, scheduling, billing.

This is where existing Level 4 systems live:

- [OpenSandbox](https://github.com/nichochar/open-sandbox) is an open-source sandbox platform that 
provides lifecycle APIs and execution abstractions — it manages the full 
create/start/stop/destroy cycle with a proper API server and handles the orchestration that 
agentbox deliberately avoids.
- [Daytona](https://daytona.io) provides development environment management with workspace 
lifecycle and multi-provider support, letting you run sandboxes across different infrastructure 
backends with a consistent interface.

Both are Level 4 systems. They solve real problems that appear the moment you have more than one 
user or more than one sandbox. agentbox intentionally stops at Level 3 because it's a single-host, 
single-user tool. Adding multi-tenancy, persistent state, and an API server would triple the 
codebase and change the operational model from "run install.sh" to "deploy and operate a service." 
That's a different project with different constraints.

## From Level 3 to Level 4

If you do want to make the jump, here's the concrete path, roughly in order of priority.

First, replace `sandctl` with a real API server. The bash script works for a single user running 
commands by hand, but programmatic access needs an HTTP API with proper error handling, request 
validation, and structured responses. Go or Rust — pick based on your team. The API server runs 
on the host and talks to sandboxes over SSH, preserving the existing boundary.

Second, build a container pool. Pre-build images with common toolchains. Keep warm containers ready 
for instant starts. This turns sandbox creation from "pull image and configure" (30+ seconds) to 
"assign from pool" (sub-second).

Third, replace `runtime.json` and PID files with a real database. SQLite for single-node, Postgres 
for multi-node. Store sandbox state, agent state, configuration, and audit logs.

Fourth, add an auth layer. API keys for programmatic access, OAuth for human users. Every sandbox 
operation needs to be scoped to an authenticated identity.

Fifth, add a web terminal. xterm.js over WebSocket, proxied through the API server to the sandbox's 
SSH server. This lets users interact with sandboxes from a browser without local SSH configuration.

Sixth, implement snapshot and restore. Commit the container filesystem, tag it, store it. This 
enables checkpointing agent work, sharing sandbox state, and disaster recovery.

The key architectural advice: keep SSH as the boundary between host and sandbox. Don't replace it 
with a custom protocol or Docker exec. SSH gives you auth, encryption, multiplexing, and file 
transfer for free. Build everything above it.

## Lessons from First Deploy

We deployed agentbox on a Hetzner CPX22 (2 vCPU, 4GB RAM, 80GB disk, Ubuntu 24.04). Three bugs 
surfaced that are worth discussing because they represent the kind of thing that only shows up on a 
real host.

**Bug 1: `cap_drop: [ALL]` breaks sshd.** The original compose.yaml dropped every Linux capability. 
This is correct in principle -- you want the smallest possible set -- but sshd needs SETUID and 
SETGID to drop privileges after authentication, DAC_OVERRIDE and CHOWN for the entrypoint to write 
to agent-owned directories, and SYS_CHROOT for internal sshd operations. Without these, the 
entrypoint crashed on the first `cp` command (copying the authorized_keys file into the agent's home 
directory). The fix: `cap_drop: [ALL]` followed by `cap_add` with exactly the eight capabilities 
sshd requires. The lesson: do not guess which capabilities you need. Run the container, watch it 
fail, and add capabilities one at a time until it works. Then stop.

**Bug 2: Squid cannot write to `/dev/stdout` in the ubuntu/squid image.** The squid.conf template 
originally used `access_log stdio:/dev/stdout` for Docker-native log collection. This works in many 
Squid setups, but the `ubuntu/squid` image drops privileges to the `proxy` user, and `/dev/stdout` is 
owned by root. Squid hit a fatal error on startup. The fix: log to `/var/log/squid/access.log` 
(the image creates this directory with correct permissions for the `proxy` user) and mount a named 
volume for log persistence. The lesson: if you use a third-party Docker image, check what user it 
runs as and whether your config is compatible with that user's permissions.

**Bug 3: Docker cannot publish ports into containers on `internal: true` networks.** The original 
design put the sandbox on two internal networks (`sandbox-net` and `proxy-net`). The intent was 
belt-and-suspenders: iptables blocks direct egress, and `internal: true` provides a second layer. 
The problem: Docker's port publishing (`ports: "2222:22"`) works by creating a proxy process on the 
host that forwards traffic into the container. This proxy needs a routable path to the container, 
which internal networks do not provide. `docker port agentbox-sandbox` returned nothing. SSH 
connections to port 2222 were refused. The fix: remove `internal: true` from `sandbox-net` and rely 
on iptables DOCKER-USER rules as the primary enforcement layer. `proxy-net` remains internal because 
neither container needs host port access on that network. The lesson: `internal: true` and host port 
publishing are mutually exclusive. If you need both isolation and published ports, use iptables.

These bugs are subtle and do not surface in `docker compose config` validation, unit tests, or even 
`docker compose up -d` (which succeeds silently). They only appear when you try to actually use the 
running system. This is why integration testing on a real host matters, and why a smoke test 
(`scripts/smoke-test.sh`) that actually SSHes into the sandbox is more valuable than any amount of 
YAML linting.

## Decision Summary

| Decision | Chose | Over | Why |
|----------|-------|------|-----|
| Control surface | Bash script | Go binary | Minimal deps, inspectable |
| Container boundary | SSH | Docker exec | No socket mount needed |
| Egress | Squid proxy | iptables per-domain | Domain-level HTTPS filtering |
| Isolation | rootful Docker | rootless/Firecracker/gVisor | Simpler, documented tradeoff |
| Process model | SSH nohup | Container process manager | No extra components |
| State | JSON + PID files | Database | Simplest for one runtime |

Every row in that table is a decision we'd revisit at Level 4. That's the point. Level 3 optimizes 
for simplicity and inspectability on a single host. Level 4 optimizes for scale and automation 
across a fleet. Know which one you're building before you start.
