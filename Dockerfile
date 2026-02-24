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

# install claude-code
RUN npm install -g @anthropic-ai/claude-code
# or as an alterative, this should also work
#RUN curl -fsSL https://claude.ai/install.sh | bash

# set the working directory
WORKDIR /workspace

CMD ["bash"]