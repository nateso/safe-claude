#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# install.sh — Guided installation for safe-claude
#
# 1. Checks prerequisites (Docker)
# 2. Builds the 'safe-claude' Docker image
# 3. Installs the 'safe-claude' script to a directory on your PATH
# ---------------------------------------------------------------------------

IMAGE_NAME="safe-claude"
DEFAULT_INSTALL_DIR="/usr/local/bin"
VERSION_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/safe-claude/version"

# ── helpers ─────────────────────────────────────────────────────────────────

info()    { echo "[safe-claude] $*"; }
success() { echo "[safe-claude] OK $*"; }
warn()    { echo "[safe-claude] ! $*"; }
err()     { echo "[safe-claude] Error: $*" >&2; exit 1; }

# Resolve the directory that contains this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# ── step 2: build the Docker image ──────────────────────────────────────────

echo ""
if docker image inspect "$IMAGE_NAME" &>/dev/null; then
  warn "Docker image '${IMAGE_NAME}' already exists."
  read -rp "         Rebuild it? [y/N] " REBUILD
  REBUILD="${REBUILD:-N}"
else
  REBUILD="y"
fi

if [[ "$REBUILD" =~ ^[Yy]$ ]]; then
  info "Building Docker image '${IMAGE_NAME}' (this may take a few minutes)..."
  docker build -t "$IMAGE_NAME" "$SCRIPT_DIR"
  success "Docker image '${IMAGE_NAME}' built successfully."
else
  info "Skipping image build."
fi

# ── step 3: install the safe-claude script ───────────────────────────────────

echo ""
info "Where should the 'safe-claude' command be installed?"
info "It must be a directory on your PATH."
read -rp "         Install directory [${DEFAULT_INSTALL_DIR}]: " INSTALL_DIR
INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"

# Strip trailing slash
INSTALL_DIR="${INSTALL_DIR%/}"

if [[ ! -d "$INSTALL_DIR" ]]; then
  read -rp "         Directory '${INSTALL_DIR}' does not exist. Create it? [y/N] " CREATE_DIR
  CREATE_DIR="${CREATE_DIR:-N}"
  if [[ "$CREATE_DIR" =~ ^[Yy]$ ]]; then
    mkdir -p "$INSTALL_DIR"
    success "Created directory '${INSTALL_DIR}'."
  else
    err "Installation cancelled."
  fi
fi

DEST="${INSTALL_DIR}/safe-claude"

info "Installing to '${DEST}'..."

# Use sudo only when necessary
if [[ -w "$INSTALL_DIR" ]]; then
  cp "$SCRIPT_DIR/safe-claude" "$DEST"
  chmod +x "$DEST"
else
  info "Directory '${INSTALL_DIR}' requires elevated permissions — running with sudo."
  sudo cp "$SCRIPT_DIR/safe-claude" "$DEST"
  sudo chmod +x "$DEST"
fi

success "'safe-claude' installed to '${DEST}'."

# ── step 3b: record installed version ─────────────────────────────────────────
# Store the source commit SHA so 'safe-claude update' can detect "already up to
# date" and 'safe-claude --version' can report it. Written to the user's config
# dir (never needs sudo).
mkdir -p "$(dirname "$VERSION_FILE")"
if SHA=$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null); then
  printf '%s\n' "$SHA" > "$VERSION_FILE"
  success "Recorded version ${SHA:0:8}."
else
  printf '%s\n' "unknown" > "$VERSION_FILE"
  warn "Not a git checkout — recorded version as 'unknown'."
fi

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
