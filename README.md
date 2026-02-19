# Safe Claude

Run Claude Code inside an isolated Docker container with access to only one folder on your machine. Claude can only read and write files within that folder — nothing else on your host machine is accessible.

**Why use this?** Claude Code is a powerful autonomous agent that can read, write, and delete files. Running it directly on your machine gives it access to your home directory, credentials, and other sensitive data. This project eliminates that risk by sandboxing Claude inside a container where only a single folder you choose is ever visible.

## Requirements

- Docker installed on your host machine
- An Anthropic Pro / Max account

## Usage

### 1. Open Docker on your machine

```bash
open -a Docker
```

Or just open the application as you would open any application.


### 2. Build the image

```bash
docker build -t safe-claude .
```
This takes a few minutes if you build the image for the first time.

### 3. Run the container

```bash
docker run -it --rm \
  -v /path/to/your/folder:/workspace \
  safe-claude
```

Replace `/path/to/your/folder` with the local directory you want Claude to work in.

This will open the container in the command line. you will notice this because it will say something like ```root@123456f338bb:/workspace``` in your command line path.

### 4. Start Claude Code

Inside the container:

```bash
claude
```

This will give you a link for a browser-based OAuth flow to authenticate with your Anthropic account. Note: authentication does not persist between container restarts — you will need to log in each time.

To exit the container, type `exit` or press `Ctrl+D`.

## What's included in the container

- Node.js 20
- Claude Code (`@anthropic-ai/claude-code`)
- Python 3 + Conda (Miniconda)
- R
- Common build tools

## Security model

The container has no access to your home directory, credentials, or other files. Only the folder you explicitly mount is visible to Claude. Within the mounted folder Claude can write/delete/corrupt everything with no restrictions.
