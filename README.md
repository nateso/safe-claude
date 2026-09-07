# Safe Claude

[![CI](https://github.com/nateso/safe-claude/actions/workflows/ci.yml/badge.svg)](https://github.com/nateso/safe-claude/actions/workflows/ci.yml)

Run Claude Code inside an isolated Docker container with access to only one folder on your machine.

**Why use this?** Claude Code is an agent that can read, write, and delete files. Running it directly on your machine gives it access to your home directory, credentials, and everything else. Safe Claude sandboxes it so only the folder you choose is visible — nothing else on your host is accessible.

## Requirements

- Docker installed and running
- An Anthropic Pro / Max account

---

## Install
**macOS / Linux:**
```bash
curl -fsSL https://github.com/nateso/safe-claude/releases/latest/download/install.sh | bash
```

**Windows** (PowerShell):
```powershell
irm https://github.com/nateso/safe-claude/releases/latest/download/install.ps1 | iex
```

The installer will:
- Check that Docker is installed and running
- Pull the `safe-claude` image for that release from GitHub Container Registry (`ghcr.io/nateso/safe-claude`)
- Install the `safe-claude` command


## Usage
**macOS / Linux:**
```bash
safe-claude /path/to/your/project
```

**Windows:**
```powershell
safe-claude C:\path\to\your\project
```

This creates an isolated container, mounts your folder, and drops you into a Claude session. Run it again to reconnect to the same sandbox.


To let Claude run without confirmation prompts:
> **Warning:** Claude can then modify and delete anything inside the mounted folder without asking. Only use this on a folder you trust and have backed up.

**macOS / Linux:**
```bash
safe-claude /path/to/your/project --dangerously-skip-permissions
```

**Windows:**
```powershell
safe-claude C:\path\to\your\project --dangerously-skip-permissions
```

## Commands

| Command | What it does |
|---|---|
| `safe-claude <path_to_folder> [claude-args...]` |  Enter/create a sandbox for a folder|
| `safe-claude update` | Update safe-claude to latest release |
| `safe-claude list` | Show all sandboxes |
| `safe-claude remove <path>` | Remove a sandbox (keeps your files) |
| `safe-claude migrate <path>` | migrate existing sandbox to latest release |
| `safe-claude help` | Show all subcommands |
| `safe-claude --version` | Print the installed version |



