FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive

# System dependencies -- common to ALL presets
RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-server curl wget git sudo jq ripgrep ca-certificates \
    procps net-tools python3 python3-pip \
    && rm -rf /var/lib/apt/lists/*

# SSH hardening -- key-only auth, no password, no port forwarding
RUN mkdir -p /var/run/sshd \
    && sed -i 's/#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config \
    && sed -i 's/#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config \
    && sed -i 's/#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config \
    && sed -i 's/#\?AllowTcpForwarding.*/AllowTcpForwarding no/' /etc/ssh/sshd_config \
    && sed -i 's/#\?X11Forwarding.*/X11Forwarding no/' /etc/ssh/sshd_config \
    && echo 'AllowStreamLocalForwarding no' >> /etc/ssh/sshd_config \
    && echo 'GatewayPorts no' >> /etc/ssh/sshd_config

# Agent user -- sudo for installing packages, but no password
RUN useradd -m -s /bin/bash -G sudo agent \
    && echo 'agent ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers.d/agent \
    && chmod 0440 /etc/sudoers.d/agent \
    && mkdir -p /home/agent/.ssh \
    && chmod 700 /home/agent/.ssh \
    && chown -R agent:agent /home/agent

# Workspace
RUN mkdir -p /workspace && chown agent:agent /workspace

# Install Node.js 20 (needed for opencode and many agents)
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Install opencode via official installer
# Falls back to npm if the curl installer fails
RUN curl -fsSL https://opencode.ai/install | bash \
    || npm install -g opencode \
    || { echo "WARNING: opencode install failed. Install manually after boot: curl -fsSL https://opencode.ai/install | bash"; true; }

# Install ChatGPT OAuth plugin for opencode (enables ChatGPT Max/Plus subscription auth)
RUN npm install -g opencode-openai-codex-auth@latest 2>/dev/null \
    || echo "WARN: opencode-openai-codex-auth install failed -- install manually: npx -y opencode-openai-codex-auth@latest"

# Configure opencode to use ChatGPT OAuth plugin
RUN npx -y opencode-openai-codex-auth@latest 2>/dev/null || true

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
EXPOSE 22
ENTRYPOINT ["/entrypoint.sh"]
