FROM node:20-slim

# install system dependencies
# 1. Core utilities (it etc)
# 2. C/C++ build toolchain (needed to compile R/Python native packages)
# 3. SSL / HTTP (libcurl used by R to download packages)
# 4. XML (used by many R packages)
# 5. Font / graphics stack (R packages: systemfonts, textshaping, ragg)
# 6. R base

RUN apt-get update && apt-get install -y \
    git curl wget ca-certificates gnupg \
    build-essential \
    libcurl4-openssl-dev libssl-dev \
    libxml2-dev \
    libfontconfig1-dev libharfbuzz-dev libfribidi-dev \
    libfreetype6-dev libpng-dev libtiff5-dev libjpeg-dev \
    r-base \
    && rm -rf /var/lib/apt/lists/*

# Quietly (-q) install conda (ARCH ensures it works on windows, linux and mac)
# This also installes python and pip
RUN ARCH=$(uname -m) && \
    wget -q -O /miniconda.sh "https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-${ARCH}.sh" \
    && bash /miniconda.sh -b -p /opt/conda \
    && rm /miniconda.sh \
    && /opt/conda/bin/conda clean -afy

# add the conda binary to PATH so that we can use conda and python from the command line
ENV PATH="/opt/conda/bin:$PATH"

# install claude-code
RUN npm install -g @anthropic-ai/claude-code
# or as an alterative, this should also work
#RUN curl -fsSL https://claude.ai/install.sh | bash

# set the working directory
WORKDIR /workspace

CMD ["bash"]