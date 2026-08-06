#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# install.sh — Guided installation for safe-claude
#
# 1. Checks prerequisites (Docker)
# 2. Pull the 'safe-claude' Docker image from the GHCR
# 3. Installs the 'safe-claude' script to a directory on your PATH
#
# Usage: ./install.sh [--install-dir <path>]
# ---------------------------------------------------------------------------

IMAGE_NAME="ghcr.io/nateso/safe-claude:latest"
DEFAULT_INSTALL_DIR="/usr/local/bin"

# ── helpers ─────────────────────────────────────────────────────────────────

info()    { echo "[safe-claude] $*"; }
success() { echo "[safe-claude] OK $*"; }
warn()    { echo "[safe-claude] ! $*"; }
err()     { echo "[safe-claude] Error: $*" >&2; exit 1; }

# ── options ─────────────────────────────────────────────────────────────────

INSTALL_DIR="${INSTALL_DIR:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-dir)   INSTALL_DIR="${2:-}"; [[ -n "$INSTALL_DIR" ]] || err "--install-dir needs a path"; shift 2 ;;
    --install-dir=*) INSTALL_DIR="${1#*=}"; shift ;;
    -h|--help)
      echo "Usage: ./install.sh [--install-dir <path>]"
      echo ""
      echo "  --install-dir <path>  Where to put the 'safe-claude' command."
      echo "                        Default: ${DEFAULT_INSTALL_DIR}"
      exit 0
      ;;
    *) err "Unknown option: $1 (try --help)" ;;
  esac
done

USING_DEFAULT=0
if [[ -z "$INSTALL_DIR" ]]; then
  INSTALL_DIR="$DEFAULT_INSTALL_DIR"
  USING_DEFAULT=1
fi
INSTALL_DIR="${INSTALL_DIR%/}"

# ── step 1: prerequisites ───────────────────────────────────────────────────

echo ""
echo "==========================================="
echo "  safe-claude installer"
echo "==========================================="
echo ""

info "Checking prerequisites..."

command -v docker &>/dev/null \
  || err "Docker is not installed. Please install Docker from https://www.docker.com and re-run this script."

if ! docker info &>/dev/null; then
  err "Docker daemon is not running. Please start Docker and re-run this script."
fi

success "Docker is available and running."

# ── step 2: pull the Docker image ───────────────────────────────────────────
echo ""
if docker image inspect "$IMAGE_NAME" &>/dev/null; then
  # Compare the current id with the latest ID on the ghcr
  OLD_ID=$(docker image inspect "$IMAGE_NAME" --format '{{.Id}}')
  info "Checking for updates..."
  if docker pull -q "$IMAGE_NAME" >/dev/null 2>&1; then
    NEW_ID=$(docker image inspect "$IMAGE_NAME" --format '{{.Id}}')
    if [[ "$OLD_ID" == "$NEW_ID" ]]; then
      success "Image is up to date."
    else
      success "You were running an outdated version of the image. Updated to new version."
    fi
  else
    warn "Could not check for updates -- check your internet connection."
    warn "Continuing with the existing local image."
  fi
else
  info "Pulling safe-claude image from remote (this may take a few minutes)..."
  if docker pull "$IMAGE_NAME"; then
    success "Image pulled successfully."
  else
    err "Could not pull the image. Check your internet connection."
  fi
fi

# ── step 3: install the safe-claude script ───────────────────────────────────
# the safe-claude script is shipped inside the docker image

echo ""
info "Installing the 'safe-claude' command to:"
echo "               ${INSTALL_DIR}"
if [[ "$USING_DEFAULT" -eq 1 ]]; then
  echo "             (to put it somewhere else, re-run with:  --install-dir <path>)"
fi

if [[ ! -d "$INSTALL_DIR" ]]; then
  mkdir -p "$INSTALL_DIR" 2>/dev/null \
    || sudo mkdir -p "$INSTALL_DIR" \
    || err "Could not create '${INSTALL_DIR}'."
  success "Created directory '${INSTALL_DIR}'."
fi

DEST="${INSTALL_DIR}/safe-claude"

info "Extracting the safe-claude script from the image..."
CONTAINER_ID=$(docker create "$IMAGE_NAME") \
  || err "Could not create a temporary container from '${IMAGE_NAME}'."

# Ensure the temporary container is always cleaned up.
trap "docker rm '$CONTAINER_ID' >/dev/null 2>&1" EXIT

# Use sudo only when necessary
if [[ -w "$INSTALL_DIR" ]]; then
  docker cp "$CONTAINER_ID:/opt/safe-claude/safe-claude" "$DEST" \
    || err "Could not extract the safe-claude script from the image."
  chmod +x "$DEST"
else
  info "Directory '${INSTALL_DIR}' requires elevated permissions — running with sudo."
  docker cp "$CONTAINER_ID:/opt/safe-claude/safe-claude" "/tmp/safe-claude" \
    || err "Could not extract the safe-claude script from the image."
  sudo mv "/tmp/safe-claude" "$DEST"
  sudo chmod +x "$DEST"
fi

success "'safe-claude' installed to '${DEST}'."

# ── step 4: verify ───────────────────────────────────────────────────────────

echo ""
if command -v safe-claude &>/dev/null; then
  success "Installation verified — 'safe-claude' is on your PATH."
else
  warn "'${INSTALL_DIR}' does not appear to be on your PATH."
  warn "Add the following line to your shell config (~/.zshrc or ~/.bashrc):"
  warn ""
  warn "    export PATH=\"${INSTALL_DIR}:\$PATH\""
  warn ""
  warn "Then restart your terminal or run:  source ~/.zshrc"
fi

# ── done ─────────────────────────────────────────────────────────────────────

echo ""
echo "==========================================="
echo "  All done!"
echo "==========================================="
echo ""
echo "  Usage:"
echo ""
echo "    safe-claude /path/to/your/project"
echo ""
echo "  This will create a sandboxed Docker container for that folder"
echo "  (if one doesn't exist yet) and launch Claude Code."
echo ""
echo "  Add --dangerously-skip-permissions to run Claude without prompts:"
echo ""
echo "    safe-claude /path/to/your/project --dangerously-skip-permissions"
echo ""
