# Safe Claude

Run Claude Code inside an isolated Docker container with access to only one folder on your machine. Claude can only read and write files within that folder — nothing else on your host machine is accessible.

**Why use this?** Claude Code is a powerful autonomous agent that can read, write, and delete files. Running it directly on your machine gives it access to your home directory, credentials, and other sensitive data. This project eliminates that risk by sandboxing Claude inside a container where only a single folder you choose is ever visible.

## Requirements

- Docker installed on your host machine
- An Anthropic Pro / Max account

## Usage

### 1. Open Docker on your machine

Just open the application as you would open any application.


### 2. Build the image

```bash
docker build -t safe-claude .
```
This takes a few minutes if you build the image for the first time.

### 3. Create the container

```bash
docker run -dit --name your_container_name \
  --restart unless-stopped \
  -v /path/to/your/folder:/workspace \
  safe-claude
```
Replace `/path/to/your/folder` with the local directory you want Claude to work in and `your_container_name` with a name of your choice.

The `--restart unless-stopped` flag ensures the container restarts automatically after a machine reboot. If you stop the container manually (e.g. with `docker stop`), it will stay stopped until you explicitly start it again.

You can list running containers via ```docker ps```

If you want to list all containers including stopped containers: ```docker ps -a```

### 4. Enter the container

```bash
docker exec -it your_container_name /bin/bash
```

You will notice you are inside the container because your command line path will say something like `root@123456f338bb:/workspace`.

To exit the container, type `exit` or press `Ctrl+D`. The container will stop but can be restarted with the same `docker start -i your_container_name` command.

### 5. Start Claude Code

Inside the container:

```bash
claude
```

This will give you a link for a browser-based OAuth flow to authenticate with your Anthropic account. Note: everytime you create a new container, you will have to authenticate within the container.

## What's included in the container

- Node.js 20
- Claude Code (`@anthropic-ai/claude-code`)
- Python 3 + Conda (Miniconda)
- R
- Common build tools

## Security model

The container has no access to your home directory, credentials, or other files. Only the folder you explicitly mount is visible to Claude. Within the mounted folder Claude can write/delete/corrupt everything with no restrictions.
