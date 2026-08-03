<#
.SYNOPSIS
    Enter (or create) a safe-claude Docker container for a given folder, and
    manage the safe-claude tool itself.

.DESCRIPTION
    safe-claude.ps1 <path_to_folder> [claude-args...]   Enter/create a sandbox
    safe-claude.ps1 update [-y] [--force]               Update tool + image to latest main
    safe-claude.ps1 list                                Show every sandbox and its state
    safe-claude.ps1 rebuild <path_to_folder> [-y]       Move a sandbox onto the new image
    safe-claude.ps1 --version                           Print the installed version

    Entering a folder resolves it to an absolute path, derives a stable
    container name, creates the container if needed (with a persistent volume
    for Claude's login/history), starts it, and drops you into Claude Code.

    Run install.ps1 first to build the 'safe-claude' Docker image.

.PARAMETER FolderPath
    Path to the folder you want Claude to work in, OR a subcommand
    ('update', 'rebuild', '--version').
#>

param(
    [Parameter(Position = 0)]
    [string]$FolderPath,

    # Declared explicitly rather than being fished out of $ClaudeArgs. The binder
    # reads a token like '-y' as a parameter name first; on PowerShell 7 an
    # unmatched one does fall through to the ValueFromRemainingArguments
    # parameter, but that is incidental, and the .bat wrapper invokes Windows
    # PowerShell 5.1. Declaring these removes the ambiguity. The subcommands
    # still accept '-y'/'--yes'/'--force' as plain strings, so both routes work.
    #
    # Trade-off: '-y' and '-Force' are now consumed by this script and no longer
    # forwarded to 'claude'. Claude Code has no such flags, so nothing is lost.
    [Alias('y')]
    [switch]$Yes,

    [switch]$Force,

    # Likewise for the version/help flags, which were previously matched against
    # $FolderPath and therefore never fired: PowerShell binds '--version' to a
    # parameter rather than passing it positionally, and swallows '-v' as a
    # prefix of the common -Verbose parameter. An explicit alias reclaims '-v'.
    [Alias('v')]
    [switch]$Version,

    [Alias('h')]
    [switch]$Help,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ClaudeArgs
)

$IMAGE_NAME   = "safe-claude"
$REPO_URL     = if ($env:SAFE_CLAUDE_REPO) { $env:SAFE_CLAUDE_REPO } else { "https://github.com/nateso/safe-claude.git" }
$VERSION_FILE = Join-Path $env:LOCALAPPDATA "safe-claude\version"

# ── helpers ──────────────────────────────────────────────────────────────────

function Write-Info    { param([string]$m) Write-Host "[safe-claude] $m" }
function Write-Success { param([string]$m) Write-Host "[safe-claude] OK  $m" -ForegroundColor Green }
function Write-Warn    { param([string]$m) Write-Host "[safe-claude] !   $m" -ForegroundColor Yellow }
function Write-Err     { param([string]$m) Write-Host "Error: $m" -ForegroundColor Red; exit 1 }

function Show-Usage {
    Write-Host "Usage:"
    Write-Host "  safe-claude <path_to_folder> [claude-args...]   Enter/create a sandbox for a folder"
    Write-Host "  safe-claude update [-y] [--force]               Update the tool + image to latest main"
    Write-Host "  safe-claude list                                Show every sandbox and its state"
    Write-Host "  safe-claude rebuild <path_to_folder> [-y]       Move an existing sandbox onto the new image"
    Write-Host "  safe-claude --version                           Print the installed version"
    Write-Host ""
    Write-Host "  Extra arguments are forwarded to 'claude', e.g.:"
    Write-Host "    safe-claude C:\project --dangerously-skip-permissions"
    Write-Host ""
    Write-Host "  'update --force' also rebuilds the image with the Docker layer cache"
    Write-Host "  disabled, forcing a fresh Claude Code install into it."
    Write-Host ""
    Write-Host "  Run install.ps1 first to build the '$IMAGE_NAME' Docker image."
}

function Confirm-Action {
    param([string]$Prompt)
    $reply = Read-Host "$Prompt [y/N]"
    return ($reply -match '^[Yy]$')
}

# Normalize a path before it is used for naming: full path, no trailing
# separator, lowercased. Windows paths are case-insensitive and PowerShell's
# tab-completion appends a trailing '\', so without this the same folder can
# hash to several different container names -- meaning several sandboxes for one
# project, and a 'rebuild C:\proj\' that reports no sandbox exists.
function Get-NormalizedPath {
    param([string]$Path)
    $full = (Get-Item -LiteralPath $Path -ErrorAction Stop).FullName
    # Keep the separator on a bare drive root ('C:\'); strip it everywhere else.
    if ($full.Length -gt 3) { $full = $full.TrimEnd('\', '/') }
    return $full.ToLowerInvariant()
}

# Derive a stable container name from a folder path.
# -Legacy reproduces the pre-normalization naming, so a sandbox created by an
# older version can still be located (see Resolve-ContainerName).
function Get-ContainerName {
    param([string]$AbsPath, [switch]$Legacy)
    $key = if ($Legacy) { $AbsPath } else { Get-NormalizedPath -Path $AbsPath }
    $base = (Split-Path -Leaf $key).ToLower() -replace '[^a-z0-9_-]', '-'
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($key)
    $hashBytes = [System.Security.Cryptography.MD5]::Create().ComputeHash($bytes)
    $hash = ([System.BitConverter]::ToString($hashBytes) -replace '-', '').ToLower().Substring(0, 8)
    return "safe-claude-$base-$hash"
}

# Return the container name to use for a folder, adopting a sandbox created by
# an older version that hashed the un-normalized path. Without this, the
# normalization above would silently orphan every existing Windows sandbox.
# Requires Docker, so call it after Require-Docker.
function Resolve-ContainerName {
    param([string]$AbsPath)

    $name = Get-ContainerName -AbsPath $AbsPath
    $null = docker container inspect $name 2>&1
    if ($LASTEXITCODE -eq 0) { return $name }

    $legacy = Get-ContainerName -AbsPath $AbsPath -Legacy
    if ($legacy -eq $name) { return $name }

    $null = docker container inspect $legacy 2>&1
    if ($LASTEXITCODE -ne 0) { return $name }

    Write-Info "Found sandbox '$legacy' from an older version; renaming it to '$name'."
    docker rename $legacy $name 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "Could not rename it - continuing under the existing name."
        return $legacy
    }
    # Its '<old-name>-claude' volume keeps its original name and stays mounted.
    # Nothing recomputes that name: 'rebuild' reads the container's actual mounts.
    Write-Success "Sandbox renamed to '$name'."
    return $name
}

function Get-VolumeName { param([string]$ContainerName) return "$ContainerName-claude" }

# Source commit stamped into the current image by the Dockerfile LABEL.
# Returns "unknown" for images built without the build-arg.
function Get-ImageVersion {
    $v = docker image inspect $IMAGE_NAME `
            --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $v -or $v.Trim() -in @("", "<no value>")) { return "unknown" }
    return $v.Trim()
}

# Docker renders an unset label as "<no value>".
function Get-LabelOr {
    param([string]$Value, [string]$Fallback)
    if (-not $Value -or $Value -eq "<no value>") { return $Fallback }
    return $Value
}

# Every sandbox container (singular noun per PowerShell convention).
# The anchored regex avoids matching a user container
# that merely contains the string, and the transient "-seed" helper a crashed
# rebuild can leave behind is skipped.
function Get-SandboxName {
    $names = docker ps -a --filter 'name=^safe-claude-' --format '{{.Names}}'
    if ($LASTEXITCODE -ne 0 -or -not $names) { return @() }
    return @($names | Where-Object { $_ -and $_ -notlike '*-seed' })
}

function Require-Docker {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Err "Docker is not installed or not on PATH."
    }
    $null = docker info 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Docker daemon is not running. Please start Docker Desktop and try again."
    }
}

function Require-Image {
    $null = docker image inspect $IMAGE_NAME 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Err "'$IMAGE_NAME' Docker image not found. Run install.ps1 (or 'safe-claude update') to build it first."
    }
}

# ── version tracking ──────────────────────────────────────────────────────────

function Read-Version {
    if (Test-Path $VERSION_FILE) { return (Get-Content -Path $VERSION_FILE -TotalCount 1) }
    return $null
}

function Write-VersionFile {
    param([string]$Sha)
    $dir = Split-Path -Parent $VERSION_FILE
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Set-Content -Path $VERSION_FILE -Value $Sha
}

function Show-Version {
    $sha = Read-Version
    if (-not $sha) { $sha = "unknown" }
    Write-Host "safe-claude $sha"
}

# ── update ────────────────────────────────────────────────────────────────────

function Invoke-Update {
    param([string[]]$UpdateArgs, [bool]$BoundYes, [bool]$BoundForce)

    $assumeYes = $BoundYes; $force = $BoundForce
    foreach ($a in $UpdateArgs) {
        switch ($a) {
            '-y'      { $assumeYes = $true }
            '--yes'   { $assumeYes = $true }
            '--force' { $force = $true }
            default   { Write-Err "Unknown option for 'update': $a (usage: safe-claude update [-y] [--force])" }
        }
    }

    $self = $PSCommandPath   # the installed safe-claude.ps1 currently running

    Write-Host "safe-claude update"
    Write-Host "  Updates the 'safe-claude' command and rebuilds the '$IMAGE_NAME' image"
    Write-Host "  from the latest 'main' ($REPO_URL)."
    Write-Host "  Existing sandboxes are left untouched."
    Write-Host "  Command file: $self"
    Write-Host ""
    if (-not $assumeYes) {
        if (-not (Confirm-Action "Proceed?")) { Write-Host "Update cancelled."; return }
    }

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Err "git is required for 'update' but was not found on PATH."
    }
    Require-Docker

    $tmp = Join-Path $env:TEMP ("safe-claude-update-" + [System.Guid]::NewGuid().ToString('N'))
    try {
        Write-Info "Fetching latest from $REPO_URL (branch main)..."
        git clone --depth 1 --branch main $REPO_URL $tmp 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Err "Failed to clone $REPO_URL. Check your network and git installation." }

        $newSha = (git -C $tmp rev-parse HEAD).Trim()
        $storedSha = Read-Version
        if ((-not $force) -and $storedSha -and ($storedSha -eq $newSha)) {
            Write-Success "Already up to date ($($newSha.Substring(0,8)))."
            return
        }

        # Replace the installed script (PowerShell reads it into memory at start,
        # so the file is not locked; Move-Item -Force replaces it atomically).
        Write-Info "Updating command at $self..."
        $tmpDest = "$self.tmp"
        Copy-Item -Path (Join-Path $tmp "safe-claude.ps1") -Destination $tmpDest -Force
        Move-Item -Path $tmpDest -Destination $self -Force
        Write-Success "Command updated."

        # --pull refreshes the base image. Docker keys its layer cache on
        # instruction text, and this Dockerfile has no COPY, so an unchanged
        # Dockerfile would otherwise rebuild to a byte-identical image --
        # including a stale Claude Code install layer. '--force' therefore also
        # means "do not trust the cache".
        $buildArgs = @('--pull', '--build-arg', "SAFE_CLAUDE_VERSION=$newSha")
        if ($force) {
            $buildArgs += '--no-cache'
            Write-Info "Rebuilding Docker image '$IMAGE_NAME' from scratch (--force: cache disabled)..."
        } else {
            Write-Info "Rebuilding Docker image '$IMAGE_NAME' (this may take a few minutes)..."
        }
        docker build @buildArgs -t $IMAGE_NAME $tmp
        if ($LASTEXITCODE -ne 0) { Write-Err "Docker build failed. See output above." }
        Write-Success "Image '$IMAGE_NAME' rebuilt."

        Write-VersionFile $newSha
        Write-Success "Updated to $($newSha.Substring(0,8))."

        $sandboxes = docker ps -a --filter name=safe-claude- --format '  {{.Names}} ({{.Status}})'
        if ($sandboxes) {
            Write-Host ""
            Write-Warn "Existing sandboxes still run the previous image:"
            Write-Host $sandboxes
            Write-Host ""
            Write-Host "  They keep working as-is. To move one onto the new image"
            Write-Host "  (Claude login/history preserved), run:"
            Write-Host "      safe-claude rebuild <path>"
        }
    }
    finally {
        if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    }
}

# ── list ──────────────────────────────────────────────────────────────────────

function Invoke-List {
    param([string[]]$ListArgs)

    if ($ListArgs) { Write-Err "'list' takes no arguments (got: $($ListArgs[0]))" }

    Require-Docker

    $names = Get-SandboxName
    if (-not $names) {
        Write-Info "No sandboxes yet. Create one with:  safe-claude <path_to_folder>"
        return
    }

    $currentId = docker image inspect $IMAGE_NAME --format '{{.Id}}' 2>$null
    if ($LASTEXITCODE -ne 0) { $currentId = $null } else { $currentId = $currentId.Trim() }
    if (-not $currentId) {
        Write-Warn "The '$IMAGE_NAME' image is not built, so sandboxes cannot be compared against it."
    }

    # One inspect call for every sandbox, rather than one per sandbox.
    $tmpl = '{{.Name}}|{{.State.Status}}|{{.Image}}|{{index .Config.Labels "safe-claude.path"}}|' +
            '{{index .Config.Labels "safe-claude.version"}}|' +
            '{{range .Mounts}}{{if eq .Destination "/workspace"}}{{.Source}}{{end}}{{end}}|' +
            '{{range .Mounts}}{{if eq .Destination "/home/node/.claude"}}{{.Name}}{{end}}{{end}}'
    $raw = docker inspect --format $tmpl @names 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { Write-Err "Could not inspect the sandbox containers." }

    $rows = @(); $suggest = @(); $stale = 0; $noVolume = 0
    foreach ($line in @($raw)) {
        if (-not $line) { continue }
        $f = $line -split '\|'
        if ($f.Count -lt 7) { continue }
        $status, $img, $lPath, $lVer, $mSrc, $vol = $f[1], $f[2], $f[3], $f[4], $f[5], $f[6]

        $path = Get-LabelOr -Value $lPath -Fallback $mSrc
        if (-not $path) { $path = '(unknown)' }

        if (-not $currentId)        { $image = 'unknown' }   # nothing to compare against
        elseif ($img -eq $currentId){ $image = 'current' }
        else                        { $image = 'outdated'; $stale++ }
        $ver = Get-LabelOr -Value $lVer -Fallback ''
        if ($ver) { $image = "$image ($($ver.Substring(0, [Math]::Min(8, $ver.Length))))" }

        $vol = Get-LabelOr -Value $vol -Fallback ''
        if ($vol) { $claude = 'volume' } else { $claude = 'in-image'; $noVolume++ }

        $note = ''
        if ($path -ne '(unknown)' -and -not (Test-Path -LiteralPath $path)) { $note = '  (folder missing)' }

        # Only suggest a rebuild we could actually run: it needs the image present.
        if ($currentId -and $path -ne '(unknown)' -and ($image -like 'outdated*' -or $claude -eq 'in-image')) {
            $suggest += $path
        }

        $rows += [pscustomobject]@{
            Folder = Split-Path -Leaf $path
            Status = $status
            Image  = $image
            Claude = $claude
            Path   = "$path$note"
        }
    }

    if (-not $rows) { Write-Err "Could not read any sandbox details." }
    $rows = @($rows | Sort-Object Folder)
    $w = ($rows.Folder + 'FOLDER' | Measure-Object -Property Length -Maximum).Maximum

    Write-Host ""
    Write-Host ("{0,-$w}  {1,-8}  {2,-20}  {3,-9}  {4}" -f 'FOLDER', 'STATUS', 'IMAGE', '.claude', 'PATH')
    foreach ($r in $rows) {
        Write-Host ("{0,-$w}  {1,-8}  {2,-20}  {3,-9}  {4}" -f $r.Folder, $r.Status, $r.Image, $r.Claude, $r.Path)
    }

    Write-Host ""
    $summary = "$($rows.Count) sandbox" + $(if ($rows.Count -eq 1) { '.' } else { 'es.' })
    if ($stale)    { $summary += "  $stale on an older image." }
    if ($noVolume) { $summary += "  $noVolume without a persistent .claude volume." }
    Write-Host $summary

    if ($suggest) {
        Write-Host ""
        Write-Host "  Move a sandbox onto the current image (login/history preserved):"
        foreach ($p in ($suggest | Sort-Object -Unique)) { Write-Host "      safe-claude rebuild $p" }
    }
}

# ── rebuild (opt-in per-sandbox migration onto the new image) ─────────────────

function Invoke-Rebuild {
    param([string[]]$RebuildArgs, [bool]$BoundYes)

    $assumeYes = $BoundYes; $pathArg = $null
    foreach ($a in $RebuildArgs) {
        if     ($a -eq '-y' -or $a -eq '--yes') { $assumeYes = $true }
        elseif ($a -like '-*')                  { Write-Err "Unknown option for 'rebuild': $a" }
        elseif ($pathArg)                       { Write-Err "'rebuild' takes a single folder; unexpected extra argument: $a" }
        else                                     { $pathArg = $a }
    }
    if (-not $pathArg) { Write-Err "Usage: safe-claude rebuild <path_to_folder> [-y]" }

    Require-Docker
    Require-Image

    try { $abs = (Resolve-Path -Path $pathArg -ErrorAction Stop).Path }
    catch { Write-Err "Path does not exist: $pathArg" }
    if (-not (Test-Path -Path $abs -PathType Container)) { Write-Err "Not a directory: $pathArg" }

    $container = Resolve-ContainerName -AbsPath $abs
    $volume    = Get-VolumeName -ContainerName $container

    $null = docker container inspect $container 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Err "No sandbox exists for $abs (container '$container'). Nothing to rebuild." }

    Write-Host "safe-claude rebuild"
    Write-Host "  Sandbox: $container"
    Write-Host "  Folder:  $abs  (your files here are NOT touched)"
    Write-Host ""
    Write-Host "  This recreates the sandbox on the current '$IMAGE_NAME' image."
    Write-Host "  Claude login/history is preserved via a Docker volume."
    Write-Host "  System packages installed inside the container (apt/pip) are NOT carried over"
    Write-Host "  (a backup image of the old container is made so you can recover them)."
    Write-Host ""
    if (-not $assumeYes) {
        if (-not (Confirm-Action "Rebuild this sandbox?")) { Write-Host "Rebuild cancelled."; return }
    }

    # Is /home/node/.claude already backed by a named volume?
    $usesVolume = (docker inspect --format '{{range .Mounts}}{{if eq .Destination "/home/node/.claude"}}{{.Name}}{{end}}{{end}}' $container)
    if ($usesVolume) { $usesVolume = $usesVolume.Trim() }

    $tmp = Join-Path $env:TEMP ("safe-claude-rebuild-" + [System.Guid]::NewGuid().ToString('N'))
    try {
        if (-not $usesVolume) {
            Write-Info "Migrating Claude login/history into volume '$volume'..."
            $claudeTmp = Join-Path $tmp "claude"
            New-Item -ItemType Directory -Path $claudeTmp -Force | Out-Null
            docker cp "${container}:/home/node/.claude/." $claudeTmp
            if ($LASTEXITCODE -ne 0) { Write-Err "Failed to copy /home/node/.claude out of the container." }
            docker volume create $volume | Out-Null
            # Seed the volume via a helper container that has it mounted. We only
            # bind-mount a named volume (never a host path), so this is portable.
            $helper = "$container-seed"
            docker rm -f $helper 2>&1 | Out-Null
            docker run -d --name $helper -v "${volume}:/dest" $IMAGE_NAME tail -f /dev/null | Out-Null
            docker cp "$claudeTmp/." "${helper}:/dest/"
            if ($LASTEXITCODE -ne 0) { docker rm -f $helper 2>&1 | Out-Null; Write-Err "Failed to seed volume '$volume'." }
            # 1000:1000 is the image's built-in 'node' user, which is who Claude
            # runs as inside the container on Docker Desktop.
            docker exec -u 0 $helper sh -c 'chown -R 1000:1000 /dest' | Out-Null
            docker rm -f $helper | Out-Null
            Write-Success "Volume '$volume' seeded from the old container."
        } else {
            Write-Info "Sandbox already uses volume '$usesVolume'; login/history will persist automatically."
            $volume = $usesVolume
        }

        $ts = Get-Date -Format "yyyyMMdd-HHmmss"
        $base = (Split-Path -Leaf $abs).ToLower() -replace '[^a-z0-9_-]', '-'
        $backup = "safe-claude-backup-$base-$ts"
        Write-Info "Creating safety backup image '$backup'..."
        docker commit $container $backup | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Warn "Could not create backup image (continuing anyway)." }

        Write-Info "Removing old container and recreating on the new image..."
        docker rm -f $container | Out-Null
        docker run -dit --name $container --label "safe-claude.path=$abs" --label "safe-claude.version=$(Get-ImageVersion)" -v "${abs}:/workspace" -v "${volume}:/home/node/.claude" $IMAGE_NAME | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Err "Failed to recreate container. Your files are safe in $abs; backup image: $backup." }

        Write-Success "Sandbox rebuilt on the '$IMAGE_NAME' image."
        Write-Host "  Backup of the previous container: image '$backup'"
        Write-Host "  Inspect it with:     docker run --rm -it $backup bash"
        Write-Host "  Remove it when done: docker rmi $backup"
        Write-Host ""
        Write-Host "  Enter the refreshed sandbox with:  safe-claude $pathArg"
    }
    finally {
        if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    }
}

# ── command dispatch ──────────────────────────────────────────────────────────

# Where a '--version' / '--help' token ends up depends on the PowerShell version:
# it may bind to the switch parameters declared above (PowerShell 7), arrive as
# $FolderPath (Windows PowerShell 5.1), or land in $ClaudeArgs. All three are
# accepted below. Do not "simplify" this to whichever branch your shell happens
# to take -- handling only the $ClaudeArgs/switch route silently broke
# 'safe-claude --version' on 5.1, which is the shell the .bat wrapper runs.
$versionTokens = @('--version', '-v', 'version')
$helpTokens    = @('--help', '-h', 'help')
$subcommands   = @('update', 'rebuild', 'list')

$requested = @()
if ($FolderPath) { $requested += $FolderPath }
if ($ClaudeArgs) { $requested += $ClaudeArgs }

$namedAFolder = $FolderPath -and
                ($versionTokens -notcontains $FolderPath) -and
                ($helpTokens    -notcontains $FolderPath) -and
                ($subcommands   -notcontains $FolderPath)

if ($namedAFolder) {
    # A folder was named, so '--help' / '--version' were meant for claude, not
    # for us. Hand them back rather than swallowing them. The Where-Object is
    # load-bearing: @($null) is a one-element array holding $null, which would
    # otherwise pass an empty argument through to claude.
    if ($Help)    { $ClaudeArgs = @(@($ClaudeArgs) | Where-Object { $_ }) + '--help' }
    if ($Version) { $ClaudeArgs = @(@($ClaudeArgs) | Where-Object { $_ }) + '--version' }
} else {
    if ($Version -or ($requested | Where-Object { $versionTokens -contains $_ })) { Show-Version; exit 0 }
    if ($Help    -or ($requested | Where-Object { $helpTokens    -contains $_ })) { Show-Usage;   exit 0 }
}

switch ($FolderPath) {
    'update'  { Invoke-Update  -UpdateArgs  $ClaudeArgs -BoundYes $Yes -BoundForce $Force; exit 0 }
    'list'    { Invoke-List    -ListArgs    $ClaudeArgs; exit 0 }
    'rebuild' { Invoke-Rebuild -RebuildArgs $ClaudeArgs -BoundYes $Yes; exit 0 }
}

# ── argument validation ───────────────────────────────────────────────────────

if (-not $FolderPath) {
    Show-Usage
    exit 1
}

try {
    $AbsPath = (Resolve-Path -Path $FolderPath -ErrorAction Stop).Path
} catch {
    Write-Err "Path does not exist: $FolderPath"
}

if (-not (Test-Path -Path $AbsPath -PathType Container)) {
    Write-Err "Not a directory: $FolderPath"
}

# ── pre-flight checks ─────────────────────────────────────────────────────────

Require-Docker
Require-Image

# ── container lifecycle ───────────────────────────────────────────────────────

# Resolved only now: adopting a sandbox from an older version needs Docker.
$ContainerName = Resolve-ContainerName -AbsPath $AbsPath

$null = docker container inspect $ContainerName 2>&1
if ($LASTEXITCODE -ne 0) {
    # A per-sandbox named volume backs /home/node/.claude so Claude's login and
    # session history survive container recreation (e.g. 'safe-claude rebuild').
    Write-Info "No container found for this folder. Creating '$ContainerName'..."
    docker run -dit `
        --name $ContainerName `
        --label "safe-claude.path=$AbsPath" `
        --label "safe-claude.version=$(Get-ImageVersion)" `
        -v "${AbsPath}:/workspace" `
        -v "${ContainerName}-claude:/home/node/.claude" `
        $IMAGE_NAME | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Failed to create container."
    }
    Write-Info "Container created."
} else {
    $Status = docker container inspect --format '{{.State.Status}}' $ContainerName
    if ($Status -ne "running") {
        Write-Info "Starting container '$ContainerName'..."
        docker start $ContainerName | Out-Null
    }
}

# ── enter the container ───────────────────────────────────────────────────────

Write-Info "Entering container '$ContainerName' (folder: $AbsPath)..."

if ($ClaudeArgs -contains "--dangerously-skip-permissions") {
    Write-Host "  WARNING: Claude will read/modify/delete and run commands in $AbsPath" -ForegroundColor Yellow
    Write-Host "  WITHOUT asking. Make sure you trust and have backed up this folder." -ForegroundColor Yellow
}

Write-Info "Type 'exit' or press Ctrl+D to leave the container."
Write-Host ""
docker exec -it $ContainerName claude @ClaudeArgs
