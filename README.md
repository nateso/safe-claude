# Safe Claude

[![CI](https://github.com/nateso/safe-claude/actions/workflows/ci.yml/badge.svg)](https://github.com/nateso/safe-claude/actions/workflows/ci.yml)

Run Claude Code inside an isolated Docker container with access to only one folder on your machine. Claude can only read and write files within that folder — nothing else on your host machine is accessible.

**Why use this?** Claude Code is a powerful autonomous agent that can read, write, and delete files. Running it directly on your machine gives it access to your home directory, credentials, and other sensitive data. This project eliminates that risk by sandboxing Claude inside a container where only a single folder you choose is ever visible.

**Security Model** The container has no access to your home directory, credentials, or other files. Only the folder you explicitly mount is visible to Claude. Within the mounted folder Claude can write/delete/corrupt everything with no restrictions.


## Requirements

- Docker installed on your host machine
- Git — used to clone this repository, and by `safe-claude update`
- An Anthropic Pro / Max account

---

## Quick Start

### 1. Open Docker on your machine

Just open the application as you would open any application.

### 2. Clone this Repository to your machine

```bash
# this will create a folder safe-claude in your current working directory with all code from this repository
git clone https://github.com/nateso/safe-claude.git

# enter the folder
cd safe-claude
```

### 3. Run the installer

**macOS / Linux:**
```bash
./install.sh
```

**Windows** (PowerShell):
```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```

The installer will:
- Check that Docker is running
- Build the `safe-claude` Docker image (takes a few minutes the first time)
- Install the `safe-claude` command to a directory on your PATH

### 4. Use it
**macOS / Linux:**
```bash
safe-claude /path/to/your/project
```

**Windows:**
```powershell
safe-claude C:\path\to\your\project
```

That's it. The command will:
- **Create** a new container that bind-mounts the specified folder at `/workspace`.
- **Start** the container
- **Drop you into a claude session** inside the container with `/workspace` pointing to your folder.


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

> **Upgrading from an earlier version?** Run `safe-claude update`, then `safe-claude rebuild <path>` once for each sandbox you already have — see [Updating](#updating) below.


## How containers are managed

Each folder gets its own container. The container name is derived deterministically from the folder path (e.g. `safe-claude-myproject-a3f2b1c8`), so running `safe-claude /path/to/your/project` always connects to the same container.

Each container also gets a small per-folder Docker volume (`<container_name>-claude`) mounted at `/home/node/.claude`. This is where Claude Code stores your **login and session history**, so it survives the container being recreated (for example by `safe-claude rebuild`). Your project files are never stored here — they live on your host machine and are only bind-mounted in.

Sandboxes created **before** this version have no such volume: their login and history sit inside the container itself, where recreating it would destroy them. `safe-claude rebuild` migrates them onto a volume — see [Updating](#updating).


## Listing your sandboxes

```bash
safe-claude list
```

```
FOLDER     STATUS    IMAGE                 .claude    PATH
gone       exited    current (a5697472)    volume     /Users/anna/old        (folder missing)
myproject  running   current (a5697472)    volume     /Users/anna/code/myproject
scratch    exited    outdated              in-image   /Users/anna/tmp/scratch
thesis     exited    outdated (4ff9405a)   volume     /Users/anna/docs/thesis

4 sandboxes.  2 on an older image.  1 without a persistent .claude volume.

  Move a sandbox onto the current image (login/history preserved):
      safe-claude rebuild /Users/anna/tmp/scratch
      safe-claude rebuild /Users/anna/docs/thesis
```

- **IMAGE** — `current` if the sandbox runs the image you have now, `outdated` if not. The commit in brackets is the version the sandbox was built on; it reads `unknown` for sandboxes created before version stamping.
- **`.claude`** — `volume` means your Claude login and session history are on a persistent volume and survive recreation. `in-image` means they are inside the container itself and would be lost if it were recreated.
- **(folder missing)** — the host folder has been moved or deleted, so the sandbox has nothing to work on.

Anything needing attention is printed with the exact `rebuild` command to fix it.


## Updating

To upgrade `safe-claude` to the latest version on `main`:

**macOS / Linux:**
```bash
safe-claude update
```

**Windows:**
```powershell
safe-claude update
```

`update` asks for confirmation, then fetches the newest version, replaces the installed `safe-claude` command, and rebuilds the Docker image. It is **non-destructive**: your existing sandboxes are left running exactly as they are.

- `-y` skips the confirmation prompt.
- `--force` reinstalls even when you are already up to date, and rebuilds the image from scratch with the Docker layer cache disabled. Use it when you want to be certain the image picks up a fresh Claude Code install rather than a cached layer.

New sandboxes you create after updating automatically use the new image. **Existing** sandboxes keep running the previous image until you explicitly move them over — run `safe-claude list` to see which ones, then:

```bash
safe-claude rebuild /path/to/your/project      # add -y to skip the confirmation
```

`rebuild` recreates that one sandbox on the new image. Your Claude login and session history are preserved (they live on the `-claude` volume), and your project files are never touched. It also saves a backup image of the old container (`safe-claude-backup-<folder>-<timestamp>`) as a safety net. **Note:** system packages you installed *inside* the container (via `apt`/`pip`) are not carried over automatically — reinstall them, or recover them from the backup image (`docker run --rm -it <backup_image> bash`).

### Migrating a sandbox created before the persistent volume

If a sandbox predates the per-folder `.claude` volume, `rebuild` migrates it for you. Before recreating the container it copies `/home/node/.claude` out of the old one, creates the `<container_name>-claude` volume, and seeds it with that data — so you stay logged in and keep your session history, and from then on the sandbox can be recreated freely without losing either.

This is the one step `safe-claude update` cannot do on your behalf, because it means replacing the container. Run it once per existing sandbox after your first update.

Check your installed version any time with:

```bash
safe-claude --version
```

For the full list of subcommands and flags:

```bash
safe-claude help
```


-----------

## Manual Setup

If you prefer to manage Docker manually, here are the individual steps:

```bash
# build the image
docker build -t safe-claude .

# create the container
# the second -v gives Claude a persistent home for its login/history
docker run -dit --name your_container_name \
  -v /path/to/your/folder:/workspace \
  -v your_container_name-claude:/home/node/.claude \
  safe-claude

# enter the container
docker exec -it your_container_name /bin/bash

# Run claude inside the container
claude
```

Replace `/path/to/your/folder` with the local directory you want Claude to work in and `your_container_name` with a name of your choice.

You will notice you are inside the container because your command line path will say something like `node@123456f338bb:/workspace`.

To exit the container, type `exit` or press `Ctrl+D`.

---

## What's included in the container

- Node.js 20
- Claude Code
- Python 3 + Conda (Miniconda)
- R
- Common build tools
