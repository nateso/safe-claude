FROM node:20-slim

# install system dependencies
# 1. Core utilities (it etc)
# 2. C/C++ build toolchain (needed to compile R/Python native packages)
# 3. SSL / HTTP (libcurl used by R to download packages)
# 4. XML (used by many R packages)
# 5. Font / graphics stack (R packages: systemfonts, textshaping, ragg)
# 6. R base
# 7. Python3 + venv

RUN apt-get update && apt-get install -y \
    git curl wget ca-certificates gnupg \
    build-essential \
    libcurl4-openssl-dev libssl-dev \
    libxml2-dev \
    libfontconfig1-dev libharfbuzz-dev libfribidi-dev \
    libfreetype6-dev libpng-dev libtiff5-dev libjpeg-dev \
    r-base \
    python3 python3-pip python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Create a venv and add it to PATH so python/pip always resolve to it
RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# set the working directory
WORKDIR /workspace

# Run as the built-in non-root 'node' user (UID 1000).
# Required because Claude Code refuses --dangerously-skip-permissions as root,
# and it also stops Claude from leaving root-owned files in the mounted folder.
RUN mkdir -p /home/node/.claude && chown -R node:node /home/node
ENV HOME=/home/node
# Anthropic's native installer puts claude in ~/.local/bin, so add it to PATH.
ENV PATH="/home/node/.local/bin:$PATH"
USER node

# Install Claude Code with Anthropic's native installer (NOT `npm install -g`).
# It installs into the node user's home (~/.local), which stays writable at
# runtime, so Claude's built-in auto-updater works. A global npm install would
# land in a root-owned prefix that the non-root user cannot update, causing
# "Auto-update failed: no write permission to npm prefix".
RUN curl -fsSL https://claude.ai/install.sh | bash

# Stamp the source commit into the image so 'safe-claude list' can report which
# version a sandbox runs. Deliberately the last instruction: a new version must
# not invalidate the cache for the expensive layers above it.
ARG SAFE_CLAUDE_VERSION=unknown
LABEL org.opencontainers.image.revision="$SAFE_CLAUDE_VERSION"

CMD ["bash"]