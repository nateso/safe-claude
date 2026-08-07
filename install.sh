#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# install.sh — Guided installation for safe-claude
#
# 1. Checks prerequisites (Docker)
# 2. Pulls the pinned 'safe-claude' Docker image from GHCR
# 3. Installs the 'safe-claude' script to a directory on your PATH
#
# Usage: ./install.sh [--install-dir <path>]
# ---------------------------------------------------------------------------

# Stamped by CI at release time.
VERSION="@VERSION@"
IMAGE_NAME="@IMAGE_DIGEST@"      # ghcr.io/nateso/safe-claude@sha256:...
REPO="nateso/safe-claude"

DEFAULT_INSTALL_DIR="/usr/local/bin"

# ── helpers ─────────────────────────────────────────────────────────────────

info()    { echo "[safe-claude] $*"; }
success() { echo "[safe-claude] OK $*"; }
warn()    { echo "[safe-claude] ! $*"; }
err()     { echo "[safe-claude] Error: $*" >&2; exit 1; }

# Unstamped copy (run from a repo checkout, not a release) -> dev fallback.
DEV_MODE=0
if [[ "$VERSION" == @*@ ]]; then
  DEV_MODE=1
  VERSION="dev"
  IMAGE_NAME="ghcr.io/${REPO}:latest"
fi

# ── options ─────────────────────────────────────────────────────────────────

INSTALL_DIR="${INSTALL_DIR:-}"
ASSUME_YES="${ASSUME_YES:-0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-dir)   INSTALL_DIR="${2:-}"; [[ -n "$INSTALL_DIR" ]] || err "--install-dir needs a path"; shift 2 ;;
    --install-dir=*) INSTALL_DIR="${1#*=}"; shift ;;
    -y|--yes)        ASSUME_YES=1; shift ;;
    -h|--help)
      echo "Usage: ./install.sh [--install-dir <path>] [--yes]"
      echo ""
      echo "  --install-dir <path>  Where to put the 'safe-claude' command."
      echo "                        Default: ${DEFAULT_INSTALL_DIR}"
      echo "  -y, --yes             Do not prompt before reinstalling over an"
      echo "                        existing copy. Same as ASSUME_YES=1."
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
echo "  safe-claude installer (${VERSION})"
echo "==========================================="
echo ""

info "Checking prerequisites..."

command -v docker &>/dev/null \
  || err "Docker is not installed. Please install Docker from https://www.docker.com and re-run this script."

if ! docker info &>/dev/null; then
  err "Docker daemon is not running. Please start Docker and re-run this script."
fi
success "Docker is available and running."

# check whether in DEV mode
[[ "$DEV_MODE" -eq 1 ]] && warn "Unstamped development copy -- using ':latest' and the repo checkout."


# --- Check existing installation of safe-claude -----------------------------
# --- Check existing installation of safe-claude -----------------------------
EXISTING="$(command -v safe-claude 2>/dev/null || true)"
if [[ -n "$EXISTING" ]]; then
  EXISTING_VERSION="$("$EXISTING" --version 2>/dev/null || echo "unknown")"
  echo ""
  warn "safe-claude is already installed at ${EXISTING} (version: ${EXISTING_VERSION})"

  if [[ "$EXISTING" != "${INSTALL_DIR}/safe-claude" && "$USING_DEFAULT" -eq 1 ]]; then
    info "Reinstalling over the existing location."
    INSTALL_DIR="$(dirname "$EXISTING")"
  fi

  if [[ "$ASSUME_YES" -ne 1 ]]; then
    if [[ -r /dev/tty ]]; then
      read -r -p "[safe-claude] Reinstall ${VERSION} to '${INSTALL_DIR}'? [y/N] " REPLY < /dev/tty
      [[ "$REPLY" =~ ^[Yy]$ ]] || { info "Aborted -- nothing was changed."; exit 0; }
    else
      info "No terminal available -- proceeding with reinstall."
    fi
  fi
fi


# ── step 2: pull the Docker image ───────────────────────────────────────────

echo ""
if [[ "$DEV_MODE" -eq 0 ]] && docker image inspect "$IMAGE_NAME" &>/dev/null; then
  # A digest reference is immutable: present locally == correct. Nothing to check.
  success "Image for ${VERSION} is already present locally."
else
  info "Pulling safe-claude image for ${VERSION} (this may take a few minutes)..."
  if docker pull "$IMAGE_NAME"; then
    success "Image pulled successfully."
    # Digest pulls show up as <none> in 'docker images'; give it a readable tag.
    [[ "$DEV_MODE" -eq 0 ]] && docker tag "$IMAGE_NAME" "ghcr.io/${REPO}:${VERSION}"
  else
    err "Could not pull the image. Check your internet connection, and that
             the 'safe-claude' package on GHCR is public."
  fi
fi

# ── step 3: install the safe-claude script ──────────────────────────────────
# The script is a release asset from the same release as this installer.

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

# mktemp gives an unpredictable, user-owned path -- a fixed /tmp name would let
# another local user pre-create the file and swap its content before it is
# moved into the install dir.
TMP_SCRIPT="$(mktemp)"
STAGED="${INSTALL_DIR}/.safe-claude.tmp.$$"
trap 'rm -f "$TMP_SCRIPT"; rm -f "$STAGED" 2>/dev/null || sudo rm -f "$STAGED" 2>/dev/null || true' EXIT

if [[ "$DEV_MODE" -eq 1 ]]; then
  # Dev: use the copy sitting next to this installer in the checkout.
  SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [[ -f "$SRC_DIR/safe-claude" ]] || err "Dev mode: no 'safe-claude' next to install.sh."
  cp "$SRC_DIR/safe-claude" "$TMP_SCRIPT"
else
  info "Downloading the safe-claude script (${VERSION})..."
  curl -fsSL -o "$TMP_SCRIPT" \
    "https://github.com/${REPO}/releases/download/${VERSION}/safe-claude" \
    || err "Could not download the safe-claude script for ${VERSION}."
fi

# Sanity checks: non-empty, looks like a bash script, parses.
[[ -s "$TMP_SCRIPT" ]] || err "Downloaded script is empty."
head -c 100 "$TMP_SCRIPT" | grep -q '^#!' || err "Downloaded file is not a script."
bash -n "$TMP_SCRIPT" || err "Downloaded script fails a syntax check."

# Stage next to the destination, then rename: same filesystem, atomic, and it
# never truncates $DEST in place -- which may be the very script running us
# when invoked via 'safe-claude update'.
if [[ -w "$INSTALL_DIR" ]]; then
  install -m 755 "$TMP_SCRIPT" "$STAGED" && mv -f "$STAGED" "$DEST"
else
  info "Directory '${INSTALL_DIR}' requires elevated permissions — running with sudo."
  sudo install -m 755 "$TMP_SCRIPT" "$STAGED" && sudo mv -f "$STAGED" "$DEST"
fi

success "'safe-claude' ${VERSION} installed to '${DEST}'."

# ── step 4: verify ───────────────────────────────────────────────────────────

echo ""
FOUND="$(command -v safe-claude 2>/dev/null || true)"
if [[ "$FOUND" == "$DEST" ]]; then
  success "Installation verified — 'safe-claude' is on your PATH."
elif [[ -n "$FOUND" ]]; then
  warn "Another copy at '${FOUND}' shadows the one just installed to '${DEST}'."
  warn "Remove it, or re-run with:  --install-dir $(dirname "$FOUND")"
else
  warn "'${INSTALL_DIR}' does not appear to be on your PATH."
  warn "Add the following line to your shell config (~/.zshrc or ~/.bashrc):"
  warn ""
  warn "    export PATH=\"${INSTALL_DIR}:\$PATH\""
  warn ""
  warn "Then restart your terminal or run:  source ~/.zshrc"
fi

# ── done ─────────────────────────────────────────────────────────────────────