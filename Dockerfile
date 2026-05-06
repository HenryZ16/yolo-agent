FROM ubuntu:24.04

LABEL maintainer="agentic-coding-yolo"
LABEL description="Docker image for running Claude Code and Kimi Code"

ENV DEBIAN_FRONTEND=noninteractive
ENV WORKSPACE=/workspace

# Install base tools, build essentials, and dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    vim \
    nano \
    jq \
    gosu \
    build-essential \
    gcc \
    make \
    pkg-config \
    libssl-dev \
    python3 \
    python3-pip \
    python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 20.x (required for Claude Code)
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

ARG CLAUDE_CODE_VERSION=latest
ARG CACHE_BUST=0
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# Install Kimi Code CLI via pip
RUN pip3 install --break-system-packages kimi-code

# Create developer user (use high UID to avoid conflicts with host)
RUN useradd -u 9999 -m -s /bin/bash developer \
    && mkdir -p /workspace /opt/yolo-config \
    && chown -R developer:developer /workspace

# Copy YOLO configs into the image
COPY --chown=developer:developer config/claude-yolo.json /opt/yolo-config/claude-yolo.json
COPY --chown=developer:developer config/kimi-yolo.toml /opt/yolo-config/kimi-yolo.toml
COPY --chown=developer:developer entrypoint.sh /opt/yolo-config/entrypoint.sh
RUN chmod +x /opt/yolo-config/entrypoint.sh

WORKDIR /workspace

# Default to non-interactive for YOLO mode
ENV TERM=xterm-256color
ENV FORCE_COLOR=1

ENTRYPOINT ["/opt/yolo-config/entrypoint.sh"]
