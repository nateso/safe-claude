# Safe Claude

Run Claude Code inside an isolated Docker container with access to only one folder on your machine. Claude can only read and write files within that folder — nothing else on your host machine is accessible.

**Why use this?** Claude Code is a powerful autonomous agent that can read, write, and delete files. Running it directly on your machine gives it access to your home directory, credentials, and other sensitive data. This project eliminates that risk by sandboxing Claude inside a container where only a single folder you choose is ever visible.

## Requirements

- Docker installed on your host machine
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
- **Create** a new container for that folder if one doesn't exist yet
- **Start** the container if it exists but is stopped
- **Drop you into a claude session** inside the container with `/workspace` pointing to your folder


## How containers are managed

Each folder gets its own container. The container name is derived deterministically from the folder path (e.g. `safe-claude-myproject-a3f2b1c8`), so running `safe-claude /path/to/your/project` always connects to the same container.

## Ho

---

## Manual Setup

If you prefer to manage Docker manually, here are the individual steps:

### Build the image

```bash
docker build -t safe-claude .
```

### Create the container

```bash
docker run -dit --name your_container_name \
  -v /path/to/your/folder:/workspace \
  safe-claude
```

Replace `/path/to/your/folder` with the local directory you want Claude to work in and `your_container_name` with a name of your choice.

You can list running containers via `docker ps`

If you want to list all containers including stopped containers: `docker ps -a`

### Enter the container

```bash
docker exec -it your_container_name /bin/bash
```

You will notice you are inside the container because your command line path will say something like `root@123456f338bb:/workspace`.

To exit the container, type `exit` or press `Ctrl+D`. The container will stop but can be restarted with `docker start -i your_container_name`.

---

## What's included in the container

- Node.js 20
- Claude Code (`@anthropic-ai/claude-code`)
- Python 3 + Conda (Miniconda)
- R
- Common build tools

## Security model

The container has no access to your home directory, credentials, or other files. Only the folder you explicitly mount is visible to Claude. Within the mounted folder Claude can write/delete/corrupt everything with no restrictions.
