# Contributing to Safe Claude


## Development

Running the scripts from a checkout works: they detect the absence of a release stamp, fall back to `ghcr.io/nateso/safe-claude:latest`, and the installer takes the `safe-claude` script from next to itself instead of downloading a release asset.

```bash
# build the image locally
docker build -t ghcr.io/nateso/safe-claude:latest .

# install the checked-out scripts
./install.sh --install-dir "$HOME/.local/bin"
```

### Releases

Releases are cut by pushing a tag. `v0.1.0` builds and pushes the multi-arch image, stamps the version and image digest into the four scripts, and attaches them to a GitHub release. A tag with a suffix (`v0.1.0-beta.1`) is published as a prerelease and does not move `:latest`.

### CI

CI checks both scripts on every push: `bash -n` and ShellCheck for the bash side, the PowerShell parser and PSScriptAnalyzer for the Windows side, plus a CLI contract suite that runs the same argument cases against `safe-claude` and `safe-claude.ps1` under both Windows PowerShell 5.1 and PowerShell 7.


## What's in the container

- Node.js 22
- Claude Code via Anthropic's native installer (`~/.local/bin`), so its built-in auto-updater works
- Python 3 in a virtualenv at `/opt/venv` (`python` and `pip` resolve there)
- R
- Common build tools (needed to compile R and Python native packages)

`CLAUDE_CONFIG_DIR` points at `/home/node/.claude` so Claude's account state (`.claude.json`) lands on the persistent volume. Without this, recreating a container drops you back into onboarding.


---


## Detailed reference

Everything below is reference material for users who need more than the README covers.


### Installer options

Default install locations:

| | Default location | PATH |
|---|---|---|
| macOS / Linux | `/usr/local/bin` | already on PATH |
| Windows | `%LOCALAPPDATA%\Programs\safe-claude` | added to user PATH |

On Windows the installer also writes a `safe-claude.bat` wrapper so the command works from both CMD and PowerShell.

To install somewhere else, set `INSTALL_DIR` before running the installer:

```bash
INSTALL_DIR="$HOME/.local/bin" bash -c "$(curl -fsSL https://github.com/nateso/safe-claude/releases/latest/download/install.sh)"
```
```powershell
$env:INSTALL_DIR = "$HOME\bin"; irm https://github.com/nateso/safe-claude/releases/latest/download/install.ps1 | iex
```

If you downloaded the installer to a file, use the flag instead: `--install-dir <path>` (bash) or `-InstallDir <path>` (PowerShell). Both also accept `-y` / `-Yes` to skip the reinstall prompt.


### How containers are managed

Each folder gets its own sandbox, named deterministically from the folder path (e.g. `safe-claude-myproject-a3f2b1c8`), so the same folder always reconnects to the same sandbox.

Each sandbox gets a Docker volume (`<container_name>-claude`) mounted at `/home/node/.claude` for login and session history. This survives sandbox recreation (e.g. via `migrate`). Project files are never stored here — they live on your host and are only bind-mounted in.

Sandboxes created before volumes existed store login and history inside the container itself. Recreating them would lose that data. `migrate` warns you when this is the case.


### Updating

```bash
safe-claude update
```

Looks up the newest release. If you're already on it, stops. Otherwise downloads the installer, which pulls the new image and replaces the `safe-claude` command in place.

New sandboxes automatically use the new image. Existing sandboxes keep their previous image until recreated, so `update` finishes by listing the ones that are behind and offering to migrate them all at once. You can also do them one at a time:

```bash
safe-claude migrate /path/to/your/project
```

`migrate` recreates the sandbox on the current image. Project files are never touched. Login and session history carry over via the volume. The old container is only deleted once the new one is up; if creation fails, the old one is restored.

> **Note:** system packages installed inside the container (`apt` / `pip` / `install.packages`) are not carried over. Reinstall them in the new sandbox.


### Removing a sandbox

```bash
safe-claude remove /path/to/your/project
```

Removes the container, then asks separately whether to delete its `.claude` volume (login, history, settings). Project files on the host are never touched.


### Manual Docker setup

```bash
# pull the image
docker pull ghcr.io/nateso/safe-claude:latest

# create the container (second -v persists login/history)
docker run -dit --name your_container_name \
  -v /path/to/your/folder:/workspace \
  -v your_container_name-claude:/home/node/.claude \
  ghcr.io/nateso/safe-claude:latest

# enter the container
docker exec -it your_container_name /bin/bash

# run Claude
claude
```

To pin a specific release: `ghcr.io/nateso/safe-claude:v0.1.0`.

To install system packages in a running container: `docker exec -u root -it <container_name> bash`.
