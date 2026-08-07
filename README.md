# Safe Claude

[![CI](https://github.com/nateso/safe-claude/actions/workflows/ci.yml/badge.svg)](https://github.com/nateso/safe-claude/actions/workflows/ci.yml)

Run Claude Code inside an isolated Docker container with access to only one folder on your machine. Claude can only read and write files within that folder — nothing else on your host machine is accessible.

**Why use this?** Claude Code is a powerful autonomous agent that can read, write, and delete files. Running it directly on your machine gives it access to your home directory, credentials, and other sensitive data. This project eliminates that risk by sandboxing Claude inside a container where only a single folder you choose is ever visible.

**Security Model** The container has no access to your home directory, credentials, or other files. Only the folder you explicitly mount is visible to Claude. Within the mounted folder Claude can write/delete/corrupt everything with no restrictions.


## Requirements

- Docker installed and running on your host machine
- An Anthropic Pro / Max account

---

## Quick Start

### 1. Start Docker on your machine

### 2. Download and run the installer

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
- Install the `safe-claude` command from the same release and put it on your PATH

Both installers take the release they belong to with them: the command, the image, and the installer always come from one and the same release, so an installed copy is a known-good set rather than whatever happens to be on `main` today.

Where the command is installed:

| | Default location | PATH |
|---|---|---|
| macOS / Linux | `/usr/local/bin` | already on PATH |
| Windows | `%LOCALAPPDATA%\Programs\safe-claude` | added to your user PATH (needs no admin rights) |

On Windows the installer also writes a `safe-claude.bat` wrapper, so `safe-claude` works from both CMD and PowerShell without typing `.ps1`.

To install somewhere else, set `INSTALL_DIR` before running the installer — it works for the piped one-liners above:

```bash
INSTALL_DIR="$HOME/.local/bin" bash -c "$(curl -fsSL https://github.com/nateso/safe-claude/releases/latest/download/install.sh)"
```
```powershell
$env:INSTALL_DIR = "$HOME\bin"; irm https://github.com/nateso/safe-claude/releases/latest/download/install.ps1 | iex
```

If you have downloaded the installer to a file instead, the same thing is a flag: `--install-dir <path>` (bash) or `-InstallDir <path>` (PowerShell). Both also take `-y` / `-Yes` to skip the "reinstall over the existing copy?" prompt.

### 3. Use it

**macOS / Linux:**
```bash
safe-claude /path/to/your/project
```

**Windows:**
```powershell
safe-claude C:\path\to\your\project
```

That's it. The command will:
- **Create** a new container that bind-mounts the specified folder at `/workspace` (only the first time for a given folder)
- **Start** the container
- **Drop you into a Claude session** inside the container with `/workspace` pointing to your folder

### Skipping permission prompts

By default Claude asks before each file edit or command. To let it run autonomously, append `--dangerously-skip-permissions` (any extra arguments are forwarded to `claude`):

**macOS / Linux:**
```bash
safe-claude /path/to/your/project --dangerously-skip-permissions
```

**Windows:**
```powershell
safe-claude C:\path\to\your\project --dangerously-skip-permissions
```

> **Warning:** In this mode Claude can read, modify, delete, and run any command inside the mounted folder **without asking**. The container still cannot see anything outside that folder, but everything *inside* it is fair game — only use it on a folder you trust and have backed up.

Claude always runs as a non-root user (required — Claude Code refuses `--dangerously-skip-permissions` when running as root). On Linux it runs as *your* host user, so files it creates in the folder are owned by you rather than root or an unrelated container user; on macOS/Windows, Docker Desktop handles ownership. To install system packages, open a separate root shell: `docker exec -u root -it <container_name> bash`.

> **Upgrading from an earlier version?** Run `safe-claude update`. It offers to move your existing sandboxes onto the new image for you — see [Updating](#updating) below.


## Commands

```
safe-claude <path_to_folder> [claude-args...]   Enter/create a sandbox for a folder
safe-claude update                              Update the tool + image to the latest release
safe-claude list                                Show every sandbox and its state
safe-claude migrate <path_to_folder>            Move an existing sandbox onto the new image
safe-claude remove <path_to_folder>             Remove a sandbox (keeps your files)
safe-claude --version                           Print the installed version
safe-claude help                                Show every subcommand
```

`remove` also answers to `rm`; `--version` to `-v`; `help` to `--help` and `-h`.


## How containers are managed

Each folder gets its own sandbox. The sandbox name is derived deterministically from the folder path (e.g. `safe-claude-myproject-a3f2b1c8`), so running `safe-claude /path/to/your/project` always connects to the same sandbox.

Each sandbox also gets a small per-folder Docker volume (`<container_name>-claude`) mounted at `/home/node/.claude`. This is where Claude Code stores your **login and session history**, so it survives the sandbox being recreated (for example by `safe-claude migrate`). Your project files are never stored here — they live on your host machine and are only bind-mounted in.

Sandboxes created **before** volumes existed have no such volume: their login and history sit inside the container itself, where recreating it would destroy them. `migrate` tells you when this is the case and asks before going ahead.


## Listing your sandboxes

```bash
safe-claude list
```

```
FOLDER     STATUS    IMAGE                 PATH
gone       exited    outdated (v0.1.0)     /Users/anna/old  (folder missing)
myproject  running   current (v0.2.0)      /Users/anna/code/myproject
thesis     exited    outdated (v0.1.0)     /Users/anna/docs/thesis

3 sandboxes.  2 on an older image.

  Move a sandbox onto the current image:
      safe-claude migrate /Users/anna/docs/thesis
      safe-claude migrate /Users/anna/old
```

- **IMAGE** — `current` if the sandbox runs the image you have now, `outdated` if not. The version in brackets is the release it runs, and is omitted when the image carries no version stamp (update to get one).
- **(folder missing)** — the host folder has been moved or deleted, so the sandbox has nothing to work on.

Anything needing attention is printed with the exact `migrate` command to fix it.


## Updating

To upgrade `safe-claude` to the latest release:

```bash
safe-claude update
```

`update` takes no arguments. It looks up the newest release, and if you are already on it, says so and stops. Otherwise it downloads that release's installer, which pulls the new image and replaces the installed `safe-claude` command in the directory it currently lives in.

New sandboxes you create after updating automatically use the new image. **Existing** sandboxes keep running the previous image until they are recreated, so `update` finishes by listing the ones that are behind and offering to migrate them all in one go. Decline, and you can do them one at a time later:

```bash
safe-claude migrate /path/to/your/project
```

`migrate` recreates that one sandbox on the current image. Your project files are never touched, and your Claude login and session history come across with it — they live on the sandbox's volume, which is remounted onto the new container. The old container is only deleted once the new one is up; if creation fails, the old one is put back and nothing is lost.

**Note:** system packages you installed *inside* the container (via `apt` / `pip` / `install.packages`) are **not** carried over — the container itself is replaced. Reinstall them in the new sandbox.


## Removing a sandbox

```bash
safe-claude remove /path/to/your/project
```

This removes the container and then asks separately whether to delete its `.claude` volume (login, history, settings). Your project files on the host are never touched.


## Checking your version

```bash
safe-claude --version      # the release you have installed
safe-claude help           # every subcommand
```

The version is read from the stamp the release build put into the Docker image, so it tells you which image `safe-claude` is actually going to run.


-----------

## Manual Setup

If you prefer to manage Docker manually, here are the individual steps:

```bash
# pull the image
docker pull ghcr.io/nateso/safe-claude:latest

# create the container
# the second -v gives Claude a persistent home for its login/history
docker run -dit --name your_container_name \
  -v /path/to/your/folder:/workspace \
  -v your_container_name-claude:/home/node/.claude \
  ghcr.io/nateso/safe-claude:latest

# enter the container
docker exec -it your_container_name /bin/bash

# Run claude inside the container
claude
```

Replace `/path/to/your/folder` with the local directory you want Claude to work in and `your_container_name` with a name of your choice.

You will notice you are inside the container because your command line path will say something like `node@123456f338bb:/workspace`.

To exit the container, type `exit` or press `Ctrl+D`.

To pin a specific release instead of `:latest`, use its tag: `ghcr.io/nateso/safe-claude:v0.1.0`.

---

## What's included in the container

- Node.js 22
- Claude Code, installed with Anthropic's native installer into `~/.local/bin` so its built-in auto-updater keeps working
- Python 3, in a virtualenv at `/opt/venv` that `python` and `pip` resolve to
- R
- Common build tools (needed to compile R and Python native packages)

`CLAUDE_CONFIG_DIR` points at `/home/node/.claude` so that Claude's account state (`.claude.json`) lands on the persistent volume together with the rest of its config — without it, recreating a container would drop you back into onboarding.

---

## Development

Running the scripts straight from a checkout works: they detect that they carry no release stamp, fall back to `ghcr.io/nateso/safe-claude:latest`, and the installer takes the `safe-claude` script from next to itself instead of downloading a release asset.

```bash
# build the image locally
docker build -t ghcr.io/nateso/safe-claude:latest .

# install the checked-out scripts
./install.sh --install-dir "$HOME/.local/bin"
```

Releases are cut by pushing a tag. `v0.1.0` builds and pushes the multi-arch image, stamps the version and image digest into the four scripts, and attaches them to a GitHub release; a tag with a suffix (`v0.1.0-beta.1`) is published as a prerelease and does not move `:latest`.

CI checks both scripts on every push: `bash -n` and ShellCheck for the bash side, the PowerShell parser and PSScriptAnalyzer for the Windows side, plus a CLI contract suite that runs the same set of argument cases against `safe-claude` and against `safe-claude.ps1` under both Windows PowerShell 5.1 and PowerShell 7.
