# Agentbox Threat Model

## Preamble

agentbox is designed for a single developer running AI coding agents on a personal VPS. It is not designed for multi-tenant isolation, regulatory compliance, or adversarial containment. This document describes what agentbox protects against, what it does not, and the residual risks you accept by using it.

---

## Assumptions

1. **Single user**: One developer with root access to the VPS. No multi-user, no multi-tenant.

2. **Maintained host OS**: Ubuntu 22.04 or 24.04, kept up to date with security patches.

3. **Trusted Docker daemon**: Rootful Docker. The Docker daemon runs as root and is trusted.

4. **User-controlled allowlist**: The user decides which domains agents can reach via `egress/allowlist.base.txt`.

5. **API keys on disk**: API keys are stored in `.env` and passed as container environment variables.

6. **Untrusted agent code**: The agent may run arbitrary code. The code is not trusted. The preset definition (Dockerfile, entrypoint) IS trusted.

7. **Attacker model**: "The AI agent runs code that might be malicious, careless, or confused." Not: "A sophisticated attacker is targeting this specific system."

---

## Trust Boundaries

```
┌──────────────────────────────────────────┐
│  Host OS (root, full control)            │
│                                          │
│    ┌─ SSH (key-only, port 2222) ─┐       │
│    │                             │       │
│    ▼                             │       │
│  ┌──────────────┐                │       │
│  │  Sandbox      │ ◄─ Boundary 1 │       │
│  │  Container    │                       │
│  └──────┬───────┘                       │
│         │ port 3128 only                 │
│  ┌──────▼───────┐  ◄─ Boundary 2        │
│  │  Egress       │                       │
│  │  Proxy        │                       │
│  └──────┬───────┘                       │
│         │ allowlisted domains only       │
│  ───────▼─────────── ◄─ Boundary 3      │
│      Internet                            │
└──────────────────────────────────────────┘
```

**Boundary 1: Host ↔ Container.** Docker process isolation with namespace separation, cgroup limits, seccomp, and dropped capabilities. SSH is the only sanctioned crossing point. No Docker socket mounted inside. No host directories exposed beyond the `/workspace` named volume and the SSH public key (read-only bind mount).

**Boundary 2: Container ↔ Proxy.** Internal Docker network (`proxy-net`, 172.30.1.0/24). Only TCP port 3128 is useful. The sandbox can send HTTP/HTTPS proxy requests. Cannot reach other ports or services.

**Boundary 3: Proxy ↔ Internet.** Squid forward proxy with domain allowlist. Only CONNECT tunnels to allowlisted domains pass. All other traffic denied. No MITM -- traffic content is not inspected. Squid reads the SNI hostname from the TLS ClientHello but does not decrypt the payload.

---

## In-Scope Threats and Mitigations

| Threat | Mitigation | Residual Risk |
|--------|-----------|---------------|
| **Network exfiltration** | Deny-by-default egress. All traffic forced through Squid proxy with domain allowlist. iptables DOCKER-USER rules block direct external connections as belt-and-suspenders. | Any allowlisted domain is an exfiltration path. If you allowlist github.com and the agent has a GitHub token, it can push your code to a public repo. |
| **Container escape** | cap_drop ALL, no-new-privileges, no Docker socket, no SYS_ADMIN, no SYS_PTRACE. Minimal attack surface. | Docker escape 0-days exist. CVE-2024-21626 (Leaky Vessels) was a recent example. This is namespace isolation, not a hypervisor boundary. |
| **Resource exhaustion** | CPU limit (2 cores), memory limit (4GB hard, no swap), PID limit (512), tmpfs /tmp with 512MB size cap. | Disk I/O not rate-limited. /workspace volume has no size cap. A runaway agent could fill the disk. |
| **Host filesystem access** | Container only mounts: /workspace (named volume), SSH public key (read-only bind). No host directories exposed. | /workspace is fully accessible to the agent. Don't put secrets there. |
| **Privilege escalation** | no-new-privileges prevents setuid. All capabilities dropped. Agent user has passwordless sudo inside the container (needed for apt install), but this is contained by the dropped capabilities at the container level. | sudo inside the container gives root inside the namespace, but the namespace has no capabilities. A kernel vulnerability could still escalate. |
| **SSH brute force** | Key-only authentication. Password auth disabled. Challenge-response disabled. Port forwarding disabled. | SSH key stored at /opt/agentbox/id_agentbox on host disk. Host compromise = key compromise. |
| **Proxy bypass** | iptables DOCKER-USER rules drop traffic from sandbox subnet (172.30.0.0/24) to non-proxy destinations. Fixed subnets prevent IP drift. | Rules can be flushed by iptables-persistent failure. `sandctl doctor` checks for this. |
| **Credential theft** | API keys are in container environment by design (agent needs them). No additional credentials mounted. | Agent code CAN read API keys. This is inherent -- the agent needs them to call LLM APIs. Rotate keys regularly. Use minimal scopes. |
| **Persistent malware** | Container is rebuildable (`sandctl restart` rebuilds from Dockerfile). | /workspace is a persistent volume. Malware written to /workspace survives container restarts. Inspect /workspace if you suspect compromise. |
| **DNS-based exfiltration** | DNS resolves through the Squid proxy (CONNECT tunnel includes DNS). No direct DNS from sandbox. | DNS-over-HTTPS to an allowlisted domain could tunnel arbitrary data. This is a fundamental limitation of domain-level filtering. |
| **IPv6 bypass** | ip6tables DROP rule in DOCKER-USER chain. Explicit IPv6 posture. | If ip6tables rules are flushed, IPv6 traffic could bypass the proxy. |

---

## Out-of-Scope Threats

These are threats we explicitly chose not to address. This is not a gap -- it is a design boundary.

- **Host OS compromise**: If someone has root on the host, everything is compromised. This is a single-user system on a VPS you control. agentbox does not protect against a rootkit on the host or a compromised SSH daemon.

- **Docker daemon CVEs**: We run rootful Docker and trust the daemon. A Docker daemon vulnerability could allow escape regardless of container hardening. Keep Docker updated.

- **Physical access**: Cloud VPS. Not applicable. If someone has physical access to the hardware, all bets are off.

- **Multi-tenant isolation**: This is explicitly single-user. There is no tenant boundary, no user separation, no RBAC. If you need to run untrusted workloads from multiple users on the same host, agentbox is the wrong tool.

- **DLP (Data Loss Prevention)**: We filter by domain, not by content. If a domain is allowlisted, all traffic to it flows freely. We cannot detect or prevent sensitive data from being sent to an allowlisted API endpoint. Content inspection would require MITM (ssl_bump), which breaks TLS guarantees and adds significant complexity.

- **Supply chain attacks on presets**: Agent presets install tools from public registries (npm, pip, curl). We don't verify package signatures or checksums beyond what HTTPS provides. A compromised package in a public registry could inject malicious code into the container image.

- **Kernel exploits**: Docker containers share the host kernel. A kernel exploit from inside the container breaks all isolation. This is the fundamental limitation of container-based (vs. VM-based) isolation.

- **Side-channel attacks**: No protection against Spectre/Meltdown-class attacks. Not relevant for the threat model (single-user, not multi-tenant).

---

## Explicit Warnings

**The allowlist is your security boundary.** Every domain you add is a potential exfiltration path. Be deliberate. If you add `*.github.com` and the agent has access to GitHub credentials, it can create repos, push code, or read your private repositories. The minimum viable allowlist is just the LLM provider API endpoints.

**API keys are accessible to the agent by design.** The agent needs API keys to call LLM providers. Any code the agent runs can read these keys from the environment. There is no way to give the agent API access without also giving any code it runs the same access. Use API keys with minimal scopes. Rotate them regularly. Set spending limits at the provider.

**This is not a security product.** agentbox provides reasonable defaults for a single developer running AI agents on a personal VPS. If you need actual containment -- multi-tenant isolation, regulatory compliance, adversarial resistance -- use Firecracker, gVisor, or a dedicated sandbox platform like Daytona or OpenSandbox.

---

## Recommendations

1. Keep the egress allowlist minimal. Start with only the LLM provider API endpoints.
2. Rotate API keys regularly. Set spending limits at the provider.
3. Keep Docker and the host OS updated. `apt update && apt upgrade` and `docker --version`.
4. Review /workspace contents periodically. Look for unexpected files or scripts.
5. Don't store secrets in /workspace. The agent has full access.
6. Run `sandctl doctor` regularly to verify configuration integrity.
7. Monitor egress proxy logs: `sandctl logs egress-proxy` shows all proxy requests.
8. After a suspicious agent session, rebuild the container: `sandctl restart` rebuilds from Dockerfile.
9. Consider separate VPS instances for different security contexts (e.g., one for code generation, another for data analysis).

---

## Comparison with Stronger Isolation

| Property | agentbox (Docker) | Firecracker | gVisor |
|----------|-------------------|-------------|--------|
| Isolation level | Namespace + cgroup | VM (KVM) | Syscall interception |
| Kernel shared | Yes | No (guest kernel) | Partially (sentry) |
| Escape difficulty | Moderate | High | High |
| Performance overhead | Minimal | Low | Moderate |
| Complexity | Low | High (needs KVM) | Medium |
| Use case fit | Single-user dev | Multi-tenant prod | Multi-tenant prod |

agentbox chose Docker because it's the simplest thing that works for the threat model (single user, untrusted-but-not-adversarial code). If your threat model requires stronger isolation, upgrade to Firecracker or gVisor -- but understand the complexity cost.
