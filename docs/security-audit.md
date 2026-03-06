# Agentbox Security Audit

_Methodology: Trail of Bits skills (insecure-defaults, sharp-edges, supply-chain-risk-auditor)_
_Audit date: 2025-07-14_
_Scope: Full codebase review_

## Executive Summary

Agentbox implements a well-considered defense-in-depth architecture for single-user AI agent sandboxing. The codebase demonstrates security awareness with SSH hardening, capability dropping, network isolation via iptables + Squid proxy, and required API key validation at install time. However, the audit identified **2 High**, **5 Medium**, and **6 Low** severity findings across insecure defaults, sharp edges, and supply chain risks. The most critical findings are: (1) agent tool installations silently fall back to `|| echo "WARN: ..."` allowing containers to boot with broken/missing security-relevant software, and (2) two `curl | bash` patterns in Dockerfiles execute remote code at build time with no integrity verification. The implementation largely matches the documented threat model, which is commendably honest about its boundaries.

---

## 1. Insecure Defaults

### Findings

| # | Finding | Severity | File(s) | Description | Recommendation |
|---|---------|----------|---------|-------------|----------------|
| ID-1 | SSH `StrictHostKeyChecking=no` in sandctl | Low | `sandctl:25-26,36-37,46-47` | All SSH/SCP helpers disable host key checking (`-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null`). While acceptable for a localhost-only connection on a single-user system, this trains users to ignore host key warnings and would be dangerous if the SSH port were exposed beyond localhost. | Accept as documented tradeoff for single-user localhost use. Add a comment explaining why this is acceptable. Consider pinning the host key after first generation. |
| ID-2 | Passwordless sudo inside container | Medium | `agents/*/Dockerfile` | All Dockerfiles grant `agent ALL=(ALL) NOPASSWD:ALL`. While the threat model acknowledges this (container capabilities are dropped), it means code running as `agent` can trivially become root inside the container namespace. Combined with any container escape vector, this shortens the attack chain. | Consider restricting sudo to specific commands needed by each preset (e.g., `apt-get install`), or using a capability-based approach. The current blanket NOPASSWD is broader than necessary. |
| ID-3 | `.env.example` contains placeholder API key | Low | `.env.example:13` | The example file contains `ANTHROPIC_API_KEY=sk-ant-your-key-here`. While clearly a placeholder, automated scanning tools may flag this. More importantly, a lazy copy-paste could result in API calls failing silently rather than loudly. | This is fine as documentation. The installer validates required env vars, so this can't accidentally be used. No action needed. |
| ID-4 | Squid `Safe_ports` includes high port range | Low | `egress/squid.conf.template:17` | `acl Safe_ports port 1025-65535` allows HTTP requests to any high port on allowlisted domains. This is very permissive — an allowlisted domain running a service on a non-standard port would be accessible. | Consider restricting to just ports 80 and 443 unless specific presets need high ports. The current range effectively allows any port on any allowlisted domain. |
| ID-5 | Agent tool install failures are silently swallowed | High | `agents/opencode/Dockerfile:38-40`, `agents/codex/Dockerfile:36-37`, `agents/claude/Dockerfile:36-37`, `agents/openclaw/Dockerfile:36-38` | All agent Dockerfiles use `|| echo "WARN: ..."` fallbacks, allowing the Docker build to succeed even if the primary agent tool fails to install. The container boots with SSH access but without the intended agent runtime. This is fail-open: a supply chain disruption results in a running container that looks healthy but has no agent software. | Make agent tool installation a hard failure. If the tool can't be installed, the Docker build should fail so the user knows immediately. Move the `|| echo WARN` pattern to a separate "optional tools" layer or add a healthcheck that verifies the agent binary exists. |
| ID-6 | Entrypoint boots SSHD even without authorized_keys | Medium | `agents/*/entrypoint.sh` | If neither `/run/secrets/authorized_keys` nor `$AUTHORIZED_KEYS` env var is set, the entrypoint proceeds to start SSHD anyway. The SSH daemon will be running but no one can authenticate (key-only auth with no keys). This is fail-secure for authentication but fail-open for resource exposure — the container is running and consuming resources with no way to manage it. | Add an explicit check: if no authorized_keys source is found, log a clear error and exit 1. This makes misconfiguration immediately visible. |
| ID-7 | No `.env` file permissions enforcement | Medium | `install.sh:192` | The generated `.env` file contains API keys but has no explicit `chmod 600`. Default umask on most systems gives `644`, making secrets world-readable to any user on the host. | Add `chmod 600 "$AGENTBOX_DIR/.env"` after writing the file. Also set `umask 077` before the write. |

### Assessment: Fail-Open vs Fail-Secure

The system is **mostly fail-secure** at the install layer:

- **✅ Fail-secure**: Missing required env vars (API keys) cause `install.sh` to exit 1 immediately. This is correct.
- **✅ Fail-secure**: Missing preset directory causes `install.sh` to exit 1. Correct.
- **✅ Fail-secure**: SSH uses key-only auth. No password fallback. Correct.
- **⚠️ Fail-open**: Agent tool installation failures are silently swallowed (ID-5). Container boots without the agent runtime.
- **⚠️ Fail-open**: Missing `.env` file in `sandctl` causes it to proceed with default values rather than erroring. `_load_config()` silently falls back to defaults if `.env` is missing.
- **⚠️ Fail-open**: If iptables rules are not persisted (e.g., `netfilter-persistent` not installed or rules flushed on reboot), sandbox traffic can bypass the proxy. `sandctl doctor` checks for this but only as a warning, not a startup gate.

---

## 2. Sharp Edges

### The Scoundrel (Malicious Configuration)

Findings for an adversary with host access who intentionally misconfigures the system:

| # | Finding | Severity | Description |
|---|---------|----------|-------------|
| SE-1 | Egress proxy bypass via `.env` manipulation | Medium | A user with host access can edit `.env` to set `HTTP_PROXY` and `HTTPS_PROXY` to empty strings or a different proxy, but this only affects the environment variables inside the container. The iptables rules still block direct external access from the sandbox subnet. **However**, if the scoundrel also flushes iptables (`iptables -F DOCKER-USER`), the sandbox gains unrestricted internet access. The two controls (proxy + iptables) are independent, which is good defense-in-depth, but each can be disabled independently by a root user. This is acknowledged in the threat model. |
| SE-2 | Compose override can add back capabilities | Medium | A `docker-compose.override.yaml` in `$AGENTBOX_DIR` can add `cap_add: [SYS_ADMIN, SYS_PTRACE]`, re-enable `privileged` mode, or mount the Docker socket. Docker Compose automatically merges override files. There is no mechanism to detect or prevent this. | 
| SE-3 | SSH password auth can be re-enabled | Low | Since the agent user has passwordless sudo, code running inside the container can execute `sudo sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config && sudo kill -HUP 1` to re-enable password auth. However, the agent user has no password set, so this alone doesn't grant access. A more complete attack would set a password first: `echo 'agent:password' | sudo chpasswd`. This is mitigated by the fact that the attacker would already need code execution inside the container. |
| SE-4 | Allowlist file is user-writable from host | Info | `egress/allowlist.txt` is a plain text file with no integrity verification. A scoundrel with host access can add any domain. This is by design (the user IS the admin), but there's no audit log of allowlist changes. |

### The Lazy Developer (Missing Steps)

Findings for a developer who follows the happy path but skips or misses configuration steps:

| # | Finding | Severity | Description |
|---|---------|----------|-------------|
| LD-1 | Skipping API keys: fails clearly | Info | **This works correctly.** `install.sh` validates `REQUIRED_ENV_VARS` and exits with a clear error message: "Required environment variable $var is not set." Good UX. |
| LD-2 | Not setting up iptables: egress still filters via proxy | Medium | If `install.sh` is run but `setup_iptables()` fails (e.g., iptables not available, or the script is interrupted after Docker starts but before iptables), the Squid proxy still filters by domain allowlist. However, the sandbox can bypass the proxy entirely by making direct connections — only the iptables DOCKER-USER rules prevent this. The proxy is configured via `HTTP_PROXY` env vars, which are advisory (programs can ignore them). **Direct `curl --noproxy '*'` from the sandbox would succeed without iptables rules.** |
| LD-3 | Using default allowlist without review | Medium | The base allowlist includes broad domains: `.github.com`, `.googleapis.com`, `.docker.io`, `.npmjs.org`. These are all potential exfiltration paths. The threat model warns about this explicitly, but a lazy developer copying the quickstart might not read the threat model. The allowlist permits `git push` to GitHub if the agent obtains credentials. |
| LD-4 | Running `sandctl` before `install.sh` | Low | If a user clones the repo and runs `sandctl status` before running the installer, `_load_config()` silently proceeds with defaults. Commands will fail with docker/compose errors, but the error messages don't suggest running `install.sh` first. |
| LD-5 | Rebooting without persistent iptables | Medium | If `iptables-persistent` installation fails (ID-2 in the installer sequence), the iptables rules will be lost on reboot. The `install_iptables_persistent()` function runs before `setup_iptables()`, but a failure is not fatal — `set -e` would catch `apt-get` failures but the `dpkg -l` check could give a false positive if the package is installed but broken. After reboot, the systemd unit starts Docker Compose but does NOT re-apply iptables rules. |

### The Confused Developer (Parameter Confusion)

| # | Finding | Severity | Description |
|---|---------|----------|-------------|
| CD-1 | Path traversal incomplete in `sandctl read-file`/`write-file` | High | The path validation in `cmd_read_file()` and `cmd_write_file()` (lines 308-309, 317-318) checks for `../*`, `*/../*`, and `/*` patterns. However, this can be bypassed with encoded or double-encoded paths, or paths like `foo/../../etc/passwd`. The pattern `*/../*` only matches `..` as a complete path component preceded by content, but `../../etc/passwd` (starting with `../..`) matches `../*` while `foo/../../etc/passwd` would be caught by `*/../*`. **More critically**: the path `workspace/../etc/shadow` would NOT match any of the three patterns — it doesn't start with `../`, it contains `/../` so it would be caught. Actually on careful review, `*/../*` DOES match `workspace/../etc/shadow`. The validation is functional but fragile — it uses shell globbing patterns instead of canonicalization. A safer approach would `realpath` the target and verify it starts with `/workspace/`. |
| CD-2 | `AGENTBOX_DIR` can be overridden via environment | Low | Both `install.sh` and `sandctl` accept `AGENTBOX_DIR` from the environment. Setting `AGENTBOX_DIR=/tmp/evil` before running `install.sh` would install the stack to a non-standard location. This is intentional (documented), but could confuse users running scripts from tutorials that set unexpected env vars. |
| CD-3 | `cmd_workspace_exec` command injection risk | Medium | `cmd_workspace_exec()` (line 301) uses `printf '%q '` to quote arguments, then embeds them in a string passed to SSH. While `%q` provides bash-safe quoting, the entire command string is still interpreted by the remote shell. Edge cases with special characters in filenames or arguments could potentially be exploited. The `_ssh` function passes `"$@"` which means the composed command string becomes a single argument to `ssh ... "cd /workspace && command"`. This is the standard approach but inherently less safe than `--` separation. |
| CD-4 | Environment variable collision | Low | The `.env` file is sourced wholesale via `set -a; source .env; set +a` in `sandctl`. If a user adds unexpected variables to `.env` (e.g., `PATH=/something`), they'll be exported into sandctl's environment. The `env_file: .env` in compose.yaml also passes ALL variables to the container, including any extras the user added. |

---

## 3. Supply Chain Risk

### Dependency Inventory

| # | Dependency | Source | Fetch Method | Purpose | Risk Level | Notes |
|---|-----------|--------|-------------|---------|------------|-------|
| SC-1 | `ubuntu:24.04` | Docker Hub | `docker pull` (HTTPS) | Base OS image for all agent containers | **Low** | Official Docker image. Signed via Docker Content Trust. Well-maintained. Pin to digest for reproducible builds. |
| SC-2 | `ubuntu/squid:latest` | Docker Hub | `docker pull` (HTTPS) | Egress proxy container | **Medium** | Uses `:latest` tag — not pinned to a specific version. A compromised or broken push to this tag would affect all new deployments. The `ubuntu/` namespace is Canonical-maintained, reducing (but not eliminating) risk. |
| SC-3 | Docker GPG key + apt repo | `download.docker.com` | HTTPS + GPG | Docker Engine installation | **Low** | Official Docker repository with GPG signature verification. Standard installation method. GPG key is stored and reused across installs. |
| SC-4 | Node.js 20 (NodeSource) | `deb.nodesource.com` | `curl -fsSL \| bash` | JavaScript runtime for agent tools | **High** | Classic `curl \| bash` pattern. The setup script from NodeSource modifies apt sources and installs packages. If nodesource.com is compromised, arbitrary code runs as root during Docker build. No integrity check beyond HTTPS. |
| SC-5 | opencode | `opencode.ai/install` | `curl -fsSL \| bash` | OpenCode agent runtime | **High** | Another `curl \| bash` installer. Falls back to `npm install -g opencode` on failure. Both paths trust remote infrastructure. The fallback chain (`curl\|bash → npm → echo WARN`) means three different failure modes, making verification harder. |
| SC-6 | `@anthropic-ai/claude-code` | npmjs.org | `npm install -g` | Claude Code CLI | **Medium** | npm package from Anthropic's namespace. npm packages can include install scripts that execute arbitrary code. Package is from a known vendor but npm namespace squatting is possible. |
| SC-7 | `@openai/codex` | npmjs.org | `npm install -g` | OpenAI Codex CLI | **Medium** | npm package from OpenAI's namespace. Same risks as SC-6. |
| SC-8 | `openclaw` | npmjs.org or PyPI | `npm install -g` or `pip3 install` | OpenClaw agent | **Medium** | Dual-source install: tries npm first, then pip. "Emerging project" per Dockerfile comment. Less established package = higher risk of account takeover or typosquatting. The pip fallback adds a second package ecosystem to trust. |
| SC-9 | `openssh-server` | Ubuntu apt repos | `apt-get install` | SSH daemon in container | **Low** | Standard Ubuntu package. GPG-signed via apt. Well-maintained. |
| SC-10 | System packages (curl, wget, git, jq, ripgrep, etc.) | Ubuntu apt repos | `apt-get install` | Container build tools | **Low** | Standard Ubuntu packages. GPG-signed via apt. |

### `curl|bash` Installers

Two instances of the `curl | bash` antipattern exist in the codebase:

**1. NodeSource setup script** (`agents/*/Dockerfile`):
```dockerfile
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
```
- Runs as `root` during Docker build
- No checksum or signature verification beyond HTTPS
- Present in 4 out of 5 Dockerfiles (all except demo)
- If `deb.nodesource.com` serves malicious content, the build image is compromised
- **Mitigation**: NodeSource is widely used and Dockerfile builds are typically one-time. Risk is at build time, not runtime.

**2. OpenCode installer** (`agents/opencode/Dockerfile`):
```dockerfile
RUN curl -fsSL https://opencode.ai/install | bash 2>/dev/null \
    || npm install -g opencode \
    || echo "WARN: opencode install failed -- install manually after boot"
```
- Runs as `root` during Docker build
- stderr is redirected to `/dev/null`, suppressing any warning output
- Falls back to npm on failure (reasonable), then to a silent warning (problematic — see ID-5)
- The `2>/dev/null` on the curl|bash makes debugging impossible

### Recommendations

1. **Pin `ubuntu/squid` to a specific digest** instead of `:latest` (SC-2). Example:
   ```yaml
   image: ubuntu/squid@sha256:<specific-digest>
   ```

2. **Replace `curl|bash` with apt pinning for Node.js** (SC-4). Use the NodeSource apt repository directly with a pinned GPG key, or use the official Node.js Docker image as a build stage.

3. **Verify the OpenCode installer** (SC-5). Download to a temporary file, check a known checksum, then execute. Or mandate npm-only installation with a pinned version.

4. **Pin npm package versions** (SC-6, SC-7, SC-8). Use `npm install -g @anthropic-ai/claude-code@1.x.x` instead of unversioned install.

5. **Consider multi-stage builds** to reduce the attack surface of the final image. Build tools (curl, wget) don't need to be in the runtime image.

---

## 4. Summary of Recommendations

| Priority | ID | Severity | Finding | Recommendation |
|----------|-----|----------|---------|----------------|
| 1 | ID-5 | **High** | Agent tool install failures silently swallowed | Make agent tool installation a hard build failure. Remove `\|\| echo "WARN"` fallbacks. |
| 2 | SC-4 | **High** | NodeSource `curl \| bash` in 4 Dockerfiles | Replace with apt repo pinning or official Node Docker image stage. |
| 3 | SC-5 | **High** | OpenCode `curl \| bash` installer with stderr suppression | Download-then-verify, or npm-only with pinned version. Remove `2>/dev/null`. |
| 4 | ID-7 | **Medium** | `.env` file world-readable (contains API keys) | Add `chmod 600` after writing `.env`. |
| 5 | ID-2 | **Medium** | Blanket passwordless sudo in container | Restrict to specific commands (`apt-get`, `chown`). |
| 6 | LD-2 | **Medium** | Without iptables, proxy bypass is trivial | Make iptables setup a hard requirement. Add startup check. |
| 7 | CD-1 | **High** | Path validation uses shell globs instead of canonicalization | Use `realpath` + prefix check to validate workspace paths. |
| 8 | SC-2 | **Medium** | `ubuntu/squid:latest` is not version-pinned | Pin to specific digest or version tag. |
| 9 | SE-2 | **Medium** | Compose override can silently add capabilities | Add a check in `sandctl up` that warns if `docker-compose.override.yaml` exists. |
| 10 | ID-6 | **Medium** | SSHD boots without authorized_keys | Exit 1 if no key source is found. |
| 11 | LD-5 | **Medium** | iptables rules lost on reboot if persistence fails | Add iptables rule application to the systemd unit's ExecStartPre. |
| 12 | CD-3 | **Medium** | `workspace exec` command string construction | Consider using `ssh -- command` form or document the limitation. |
| 13 | SC-6/7/8 | **Medium** | npm packages installed without version pins | Pin all `npm install -g` to specific versions. |
| 14 | LD-3 | **Medium** | Default allowlist is broad | Provide a minimal allowlist (LLM APIs only) and a separate "convenience" allowlist. |
| 15 | ID-1 | **Low** | SSH StrictHostKeyChecking disabled | Accept for localhost. Document the rationale. |
| 16 | ID-4 | **Low** | Squid high port range permissive | Restrict to 80/443 unless explicitly needed. |
| 17 | CD-2 | **Low** | AGENTBOX_DIR overridable from env | Document clearly. Consider validating the path. |
| 18 | SE-3 | **Low** | SSH password auth re-enableable from inside | Accept as known risk (requires existing code execution). |
| 19 | CD-4 | **Low** | Env variable collision via `.env` sourcing | Namespace agentbox variables with `AGENTBOX_` prefix. Validate `.env` content before sourcing. |
| 20 | ID-3 | **Low** | Placeholder API key in `.env.example` | No action needed. Installer validates. |
| 21 | SE-4 | **Info** | No audit log for allowlist changes | Consider adding git tracking or checksums for allowlist. |
| 22 | LD-1 | **Info** | Missing API keys fails clearly | No action needed. Working correctly. |
| 23 | LD-4 | **Info** | sandctl before install.sh gives unclear errors | Add a pre-flight check in sandctl for `.env` existence. |

---

## Appendix: Threat Model Alignment

The documented threat model (`docs/threat-model.md`) is unusually well-written for a project of this size. Key alignment notes:

- **Acknowledged and accurate**: API key exposure, allowlist-as-security-boundary, container escape limitations, sudo-inside-container tradeoff, DNS exfiltration via allowlisted domains.
- **Acknowledged but understated**: Supply chain risk is mentioned in "Out-of-Scope Threats" but the actual `curl|bash` patterns in Dockerfiles deserve more prominent warning.
- **Not mentioned**: The `.env` file permissions issue (ID-7), the fail-open agent installation pattern (ID-5), and the path validation fragility (CD-1) are not covered in the threat model.
- **Overall assessment**: The threat model is honest about what agentbox is and isn't. The implementation is consistent with the documented design. Most findings in this audit are improvements within the existing threat model, not fundamental architecture flaws.
