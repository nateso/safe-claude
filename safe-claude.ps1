<#
.SYNOPSIS
    Enter (or create) a safe-claude Docker container for a given folder, and
    manage the safe-claude tool itself.

.DESCRIPTION
    safe-claude.ps1 <path_to_folder> [claude-args...]   Enter/create a sandbox
    safe-claude.ps1 update                              Update tool + image to latest release
    safe-claude.ps1 list                                Show every sandbox and its state
    safe-claude.ps1 migrate <path_to_folder>            Move a sandbox onto the new image
    safe-claude.ps1 remove <path_to_folder>             Remove a sandbox (keeps your files)
    safe-claude.ps1 --version                           Print the installed version

    Entering a folder resolves it to an absolute path, derives a stable
    container name, creates the container if needed (with a persistent volume
    for Claude's login/history), starts it, and drops you into Claude Code.

    Run install.ps1 first to pull the 'safe-claude' Docker image.

.PARAMETER FolderPath
    Path to the folder you want Claude to work in, OR a subcommand
    ('update', 'list', 'migrate', 'remove', '--version').
#>

param(
    [Parameter(Position = 0)]
    [string]$FolderPath,

    # Declared explicitly rather than being fished out of $ClaudeArgs: PowerShell
    # matches these against parameter names first, so without a declaration
    # '--version' binds to nothing useful and '-v' is swallowed as a prefix of
    # the common -Verbose parameter. An explicit alias reclaims '-v'.
    [Alias('v')]
    [switch]$Version,

    [Alias('h')]
    [switch]$Help,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ClaudeArgs
)

# Stamped by CI at release time.
$VERSION    = '@VERSION@'
$IMAGE_NAME = '@IMAGE_DIGEST@'      # ghcr.io/nateso/safe-claude@sha256:...
$REPO       = 'nateso/safe-claude'

if ($VERSION -like '@*@') {
    $VERSION    = 'dev'
    $IMAGE_NAME = "ghcr.io/${REPO}:latest"
}

# ── helpers ──────────────────────────────────────────────────────────────────

function Write-Info    { param([string]$m) Write-Host "[safe-claude] $m" }
function Write-Success { param([string]$m) Write-Host "[safe-claude] OK  $m" -ForegroundColor Green }
function Write-Warn    { param([string]$m) Write-Host "[safe-claude] !   $m" -ForegroundColor Yellow }
function Write-Err     { param([string]$m) Write-Host "Error: $m" -ForegroundColor Red; exit 1 }

function Show-Usage {
    Write-Host "Usage:"
    Write-Host "  safe-claude <path_to_folder> [claude-args...]   Enter/create a sandbox for a folder"
    Write-Host "  safe-claude update                              Update the tool + image to the latest release"
    Write-Host "  safe-claude list                                Show every sandbox and its state"
    Write-Host "  safe-claude migrate <path_to_folder>            Move an existing sandbox onto the new image"
    Write-Host "  safe-claude remove <path_to_folder>             Remove a sandbox (keeps your files)"
    Write-Host "  safe-claude --version                           Print the installed version"
    Write-Host ""
    Write-Host "  Entering a folder creates its container if it does not exist yet and"
    Write-Host "  launches Claude Code. Any extra arguments are forwarded to 'claude', e.g.:"
    Write-Host ""
    Write-Host "    safe-claude C:\project --dangerously-skip-permissions"
    Write-Host ""
    Write-Host ""
    Write-Host "  First install the safe-claude command via: "
    Write-Host "      irm https://raw.githubusercontent.com/$REPO/main/install.ps1 | iex"
}

# Ask a yes/no question; returns $true for yes. Default is No.
function Confirm-Action {
    param([string]$Prompt)
    $reply = Read-Host "$Prompt [y/N]"
    return ($reply -match '^[Yy]$')
}

# Normalize a path before it is used for naming: full path, no trailing
# separator, lowercased. Windows paths are case-insensitive and PowerShell's
# tab-completion appends a trailing '\', so without this the same folder can
# hash to several different container names -- meaning several sandboxes for one
# project, and a 'migrate C:\proj\' that reports no sandbox exists.
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
    # Nothing recomputes that name: 'migrate' and 'remove' read the container's
    # actual mounts.
    Write-Success "Sandbox renamed to '$name'."
    return $name
}

function Get-VolumeName { param([string]$ContainerName) return "$ContainerName-claude" }

# Version tag stamped into the current image by the Dockerfile's LABEL.
# Returns "unknown" for images built without the build-arg.
function Get-ImageVersion {
    $img = Invoke-DockerInspect -Names @($IMAGE_NAME) -Image
    if (-not $img) { return "unknown" }
    $v = Get-LabelValue -Labels $img[0].Config.Labels -Name 'org.opencontainers.image.revision'
    if (-not $v) { return "unknown" }
    return $v.Trim()
}

# Docker renders an unset label as "<no value>".
function Get-LabelOr {
    param([string]$Value, [string]$Fallback)
    if (-not $Value -or $Value -eq "<no value>") { return $Fallback }
    return $Value
}

# Read one label off a parsed 'docker inspect' object, tolerating a container or
# image that carries no labels at all.
function Get-LabelValue {
    param($Labels, [string]$Name)
    if (-not $Labels) { return '' }
    $prop = $Labels.PSObject.Properties[$Name]
    if (-not $prop) { return '' }
    return [string]$prop.Value
}

# Run 'docker inspect' and hand back parsed objects.
#
# Deliberately NOT using --format: PowerShell mangles a native-command argument
# containing embedded double quotes when it builds the Windows command line, so
# a Go template like {{index .Config.Labels "x"}} reaches docker malformed and
# the call fails. Unix is unaffected, which is why this only ever broke on
# Windows. JSON needs no quoting in the argument and ConvertFrom-Json is built in.
function Invoke-DockerInspect {
    param([string[]]$Names, [switch]$Image)

    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return @() }
    $json = if ($Image) { docker image inspect @Names 2>$null } else { docker inspect @Names 2>$null }
    if ($LASTEXITCODE -ne 0 -or -not $json) { return @() }
    try { return @($json | ConvertFrom-Json) } catch { return @() }
}

# The mount backing a destination inside the container, or $null.
function Get-MountAt {
    param($Container, [string]$Destination)
    return ($Container.Mounts | Where-Object { $_.Destination -eq $Destination } | Select-Object -First 1)
}

# Name of the volume mounted at /home/node/.claude in a container, or ''.
function Get-ClaudeVolumeOf {
    param([string]$ContainerName)
    $info = Invoke-DockerInspect -Names @($ContainerName)
    if (-not $info) { return '' }
    $name = (Get-MountAt -Container $info[0] -Destination '/home/node/.claude').Name
    if (-not $name) { return '' }
    return [string]$name
}

# Every sandbox container (singular noun per PowerShell convention).
# The anchored regex avoids matching a user container that merely contains the
# string. Two helpers are skipped: the "-seed" container a crashed migration from
# an older version can leave behind, and the "-old" container that 'migrate'
# renames the old sandbox to while it works.
function Get-SandboxName {
    $names = docker ps -a --filter 'name=^safe-claude-' --format '{{.Names}}'
    if ($LASTEXITCODE -ne 0 -or -not $names) { return @() }
    return @($names | Where-Object {
        $_ -and $_ -notlike '*-seed' -and $_ -notlike '*-old'
    })
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
        Write-Err "'$IMAGE_NAME' Docker image not found. Run install.ps1 (or 'safe-claude update') to pull it first."
    }
}

# ── version ───────────────────────────────────────────────────────────────────

function Show-Version {
    Write-Host "safe-claude $(Get-ImageVersion)"
}

# ── update ────────────────────────────────────────────────────────────────────

# The PowerShell that is running us, so child processes stay on the same edition.
function Get-PowerShellPath {
    $exe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
    $path = Join-Path $PSHOME $exe
    if (Test-Path -LiteralPath $path) { return $path }
    return 'powershell.exe'
}

# Tag of the newest release, read off the redirect that /releases/latest serves.
function Get-LatestRelease {
    try {
        $resp = Invoke-WebRequest -Uri "https://github.com/$REPO/releases/latest" `
            -UseBasicParsing -MaximumRedirection 5 -ErrorAction Stop
        # Windows PowerShell exposes the final URL as ResponseUri; PowerShell 7
        # hands back an HttpResponseMessage instead.
        $final = [string]$resp.BaseResponse.ResponseUri
        if (-not $final) { $final = [string]$resp.BaseResponse.RequestMessage.RequestUri }
        if ($final -match '/tag/(.+)$') { return $Matches[1] }
    } catch {
        Write-Verbose "Could not follow the /releases/latest redirect: $_"
    }
    # Fall back to the API when the redirect could not be read.
    try {
        $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$REPO/releases/latest" `
            -UseBasicParsing -ErrorAction Stop
        if ($rel.tag_name) { return [string]$rel.tag_name }
    } catch {
        Write-Verbose "Could not query the releases API: $_"
    }
    return $null
}

function Invoke-Update {
    param([string[]]$UpdateArgs)

    # Reject stray arguments rather than silently ignoring them: 'update' takes
    # none, and a typo'd flag must not fall through into a live self-install.
    foreach ($a in @($UpdateArgs)) {
        if (-not $a) { continue }
        if ($a -like '-*') { Write-Err "Unknown option for 'update': $a" }
        Write-Err "'update' takes no arguments (got: $a)"
    }

    Write-Host "safe-claude update"
    Write-Host "  Fetches the latest release and reinstalls the command + image."
    Write-Host "  Existing sandboxes are left untouched."
    Write-Host ""

    Require-Docker

    $latest = Get-LatestRelease
    if (-not $latest) { Write-Err "Could not determine the latest release. Check your connection." }

    if ($VERSION -eq $latest) {
        Write-Success "Already up to date ($VERSION)."
        return
    }
    Write-Info "Updating $VERSION -> $latest..."

    $self  = $PSCommandPath   # the installed safe-claude.ps1 currently running
    $psExe = Get-PowerShellPath

    $installer = Join-Path $env:TEMP ('safe-claude-install-' + [System.Guid]::NewGuid().ToString('N') + '.ps1')
    try {
        try {
            Invoke-WebRequest -Uri "https://github.com/$REPO/releases/download/$latest/install.ps1" `
                -OutFile $installer -UseBasicParsing -ErrorAction Stop
        } catch {
            Write-Err "Could not download the installer for ${latest}: $_"
        }
        if (-not (Test-Path -LiteralPath $installer) -or (Get-Item -LiteralPath $installer).Length -eq 0) {
            Write-Err "Downloaded installer is empty."
        }

        # Reinstall the command to the directory in which it currently lives.
        # ASSUME_YES rather than -Yes: this has to drive whichever installer the
        # target release happens to ship, and the -Yes switch only exists from
        # this release onward. An installer that predates it ignores the variable
        # and prompts; one that predates *both* would abort on the unknown flag.
        $env:ASSUME_YES = '1'
        try {
            & $psExe -NoProfile -ExecutionPolicy Bypass -File $installer -InstallDir (Split-Path -Parent $self)
        } finally {
            Remove-Item Env:\ASSUME_YES -ErrorAction SilentlyContinue
        }
        if ($LASTEXITCODE -ne 0) { Write-Err "Installation of $latest failed." }
    }
    finally {
        Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
    }

    # The installer tagged the new image as :<latest>; use that to find stale sandboxes.
    $newImage = Invoke-DockerInspect -Names @("ghcr.io/${REPO}:$latest") -Image
    if (-not $newImage) {
        Write-Warn "Could not identify the new image; skipping sandbox check."
        return
    }
    $newId = $newImage[0].Id

    $names = Get-SandboxName
    if (-not $names) { return }

    $stalePaths = @()
    foreach ($c in (Invoke-DockerInspect -Names $names)) {
        if (-not $c) { continue }
        $path = Get-LabelOr -Value (Get-LabelValue -Labels $c.Config.Labels -Name 'safe-claude.path') -Fallback ''
        if ($c.Image -ne $newId -and $path) { $stalePaths += $path }
    }

    if ($stalePaths) {
        Write-Host ""
        Write-Warn "$($stalePaths.Count) sandbox(es) still run an older image."
        if (Confirm-Action "Migrate all of them to the new image now?") {
            foreach ($p in $stalePaths) {
                Write-Host ""
                # 'migrate' either succeeds or rolls the sandbox back; a declined
                # confirmation also exits non-zero. Keep going through the rest.
                & $psExe -NoProfile -ExecutionPolicy Bypass -File $self migrate $p
                if ($LASTEXITCODE -ne 0) {
                    Write-Warn "Migration of '$p' did not complete -- see the output above."
                }
            }
        } else {
            Write-Host "  You can migrate them individually later with:"
            Write-Host "      safe-claude migrate <path_to_folder>"
        }
    }
    Write-Host ""
    Write-Success "Restart your shell or re-run 'safe-claude' to use $latest."
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

    $imageInfo = Invoke-DockerInspect -Names @($IMAGE_NAME) -Image
    $currentId = if ($imageInfo) { $imageInfo[0].Id } else { $null }
    $currentVer = ''
    if (-not $currentId) {
        Write-Warn "The '$IMAGE_NAME' image is not pulled, so sandboxes cannot be compared against it."
    } else {
        $currentVer = Get-LabelValue -Labels $imageInfo[0].Config.Labels -Name 'org.opencontainers.image.revision'
        if ($currentVer -eq 'unknown') { $currentVer = '' }
    }

    # One inspect call for every sandbox, rather than one per sandbox.
    $containers = Invoke-DockerInspect -Names $names
    if (-not $containers) { Write-Err "Could not inspect the sandbox containers." }

    $rows = @(); $suggest = @(); $stale = 0
    foreach ($c in $containers) {
        if (-not $c) { continue }
        $status = $c.State.Status
        $img    = $c.Image
        $lPath  = Get-LabelValue -Labels $c.Config.Labels -Name 'safe-claude.path'
        $lVer   = Get-LabelValue -Labels $c.Config.Labels -Name 'safe-claude.version'
        $mSrc   = (Get-MountAt -Container $c -Destination '/workspace').Source

        $path = Get-LabelOr -Value $lPath -Fallback $mSrc
        if (-not $path) { $path = '(unknown)' }

        if (-not $currentId)         { $image = 'unknown' }   # nothing to compare against
        elseif ($img -eq $currentId) { $image = 'current' }
        else                         { $image = 'outdated'; $stale++ }
        $ver = Get-LabelOr -Value $lVer -Fallback ''
        if ($ver -eq 'unknown') { $ver = '' }
        # A sandbox running the current image is, by definition, that image's
        # version -- so fill it in for containers created before version stamping.
        if (-not $ver -and $currentId -and $img -eq $currentId) { $ver = $currentVer }
        if ($ver) { $image = "$image ($ver)" }

        $note = ''
        if ($path -ne '(unknown)' -and -not (Test-Path -LiteralPath $path)) { $note = '  (folder missing)' }

        # Only suggest a migrate we could actually run: it needs the image present.
        if ($currentId -and $path -ne '(unknown)' -and $image -like 'outdated*') {
            $suggest += $path
        }

        $rows += [pscustomobject]@{
            Folder = Split-Path -Leaf $path
            Status = $status
            Image  = $image
            Path   = "$path$note"
        }
    }

    if (-not $rows) { Write-Err "Could not read any sandbox details." }
    $rows = @($rows | Sort-Object Folder)
    # @(...) on both sides: with a single row $rows.Folder is a scalar, and '+'
    # would concatenate the strings instead of building a list.
    $w = (@($rows.Folder) + @('FOLDER') | Measure-Object -Property Length -Maximum).Maximum

    Write-Host ""
    Write-Host ("{0,-$w}  {1,-8}  {2,-20}  {3}" -f 'FOLDER', 'STATUS', 'IMAGE', 'PATH')
    foreach ($r in $rows) {
        Write-Host ("{0,-$w}  {1,-8}  {2,-20}  {3}" -f $r.Folder, $r.Status, $r.Image, $r.Path)
    }

    Write-Host ""
    $summary = "$($rows.Count) sandbox" + $(if ($rows.Count -eq 1) { '.' } else { 'es.' })
    if ($stale) { $summary += "  $stale on an older image." }
    Write-Host $summary

    if ($currentId -and -not $currentVer) {
        Write-Host ""
        Write-Host "  The image carries no version stamp. Update with:"
        Write-Host "      safe-claude update"
    }

    if ($suggest) {
        Write-Host ""
        Write-Host "  Move a sandbox onto the current image:"
        foreach ($p in ($suggest | Sort-Object -Unique)) { Write-Host "      safe-claude migrate $p" }
    }
}

# ── migrate (opt-in for each container) ───────────────────────────────────────
# Recreates the sandbox on the current image. A sandbox whose config lives on a
# named volume keeps its login and history (the volume is remounted). A sandbox
# from before config volumes existed kept its config inside the container, and
# that is discarded with it -- the user is asked first.

function Invoke-Migrate {
    param([string[]]$MigrateArgs)

    $pathArg = $null
    foreach ($a in @($MigrateArgs)) {
        if (-not $a)             { continue }
        if ($a -like '-*')       { Write-Err "Unknown option for 'migrate': $a" }
        elseif ($pathArg)        { Write-Err "'migrate' takes a single folder; unexpected extra argument: $a" }
        else                     { $pathArg = $a }
    }
    if (-not $pathArg) { Write-Err "Usage: safe-claude migrate <path_to_folder>" }

    Require-Docker
    Require-Image

    try { $abs = (Resolve-Path -LiteralPath $pathArg -ErrorAction Stop).Path }
    catch { Write-Err "Path does not exist: $pathArg" }
    if (-not (Test-Path -LiteralPath $abs -PathType Container)) { Write-Err "Not a directory: $pathArg" }

    $container = Resolve-ContainerName -AbsPath $abs

    $null = docker container inspect $container 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Err "No sandbox exists for $abs. Nothing to migrate." }

    # Reuse the volume the old container mounted at .claude, if it had one --
    # login and history come across with it.
    $hadVolume = Get-ClaudeVolumeOf -ContainerName $container
    $volume = if ($hadVolume) { $hadVolume } else { Get-VolumeName -ContainerName $container }

    if (-not $hadVolume) {
        Write-Warn "This sandbox predates config volumes: its Claude login and history"
        Write-Warn "live inside the container and are discarded with it."
        if (-not (Confirm-Action "Migrate anyway (Claude will ask you to log in again)?")) {
            Write-Info "Migration cancelled. Your sandbox is unchanged."
            exit 1
        }
    }

    # Rename rather than remove, so the old container can be put back if the
    # new one fails to start. It is deleted once the new one is up.
    $old = "$container-old"
    docker rm -f $old 2>&1 | Out-Null
    docker rename $container $old 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Err "Could not rename the old container. Nothing was changed." }

    Write-Info "Creating the new container on the current image..."
    docker run -dit `
        --name $container `
        --label "safe-claude.path=$abs" `
        --label "safe-claude.version=$(Get-ImageVersion)" `
        -v "${abs}:/workspace" `
        -v "${volume}:/home/node/.claude" `
        $IMAGE_NAME | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "Could not create the new container -- putting the old one back."
        docker rename $old $container 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "Could not rename it back. Restore it with:  docker rename $old $container"
        }
        Write-Err "Migration aborted. Your sandbox is unchanged."
    }

    docker rm -f $old 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "Could not remove the old container. Remove it with:  docker rm -f $old"
    }

    if ($hadVolume) {
        Write-Info "Config stays on volume '$volume' -- your login and history came across."
    }
    Write-Success "Sandbox migrated. Enter it with:  safe-claude $pathArg"
}

# ── remove (opt-in for each container) ────────────────────────────────────────

function Invoke-Remove {
    param([string[]]$RemoveArgs)

    $pathArg = $null
    foreach ($a in @($RemoveArgs)) {
        if (-not $a)       { continue }
        if ($a -like '-*') { Write-Err "Unknown option for 'remove': $a" }
        elseif ($pathArg)  { Write-Err "'remove' takes a single folder; unexpected extra argument: $a" }
        else               { $pathArg = $a }
    }
    if (-not $pathArg) { Write-Err "Usage: safe-claude remove <path_to_folder>" }

    Require-Docker

    try { $abs = (Resolve-Path -LiteralPath $pathArg -ErrorAction Stop).Path }
    catch { Write-Err "Path does not exist: $pathArg" }

    $container = Resolve-ContainerName -AbsPath $abs

    $null = docker container inspect $container 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Err "No sandbox exists for $abs. Nothing to remove." }

    # Read the volume off the container before it goes: a migrated sandbox may
    # carry a volume named after an earlier container name.
    $volume = Get-ClaudeVolumeOf -ContainerName $container
    if (-not $volume) { $volume = Get-VolumeName -ContainerName $container }

    Write-Info "Removing container '$container'..."
    docker rm -f $container | Out-Null
    Write-Success "Sandbox removed."
    Write-Host "  Your project files in $abs are untouched."

    $null = docker volume inspect $volume 2>&1
    if ($LASTEXITCODE -eq 0) {
        if (Confirm-Action "Also delete the '$volume' volume (credentials, history, settings)?") {
            docker volume rm $volume | Out-Null
            Write-Success "Claude config removed."
        } else {
            Write-Info "Kept volume '$volume'."
            Write-Host "  List volumes:    docker volume ls"
            Write-Host "  Remove it later: docker volume rm $volume"
        }
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
$subcommands   = @('update', 'list', 'migrate', 'remove', 'rm')

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
    'update'  { Invoke-Update  -UpdateArgs  $ClaudeArgs; exit 0 }
    'list'    { Invoke-List    -ListArgs    $ClaudeArgs; exit 0 }
    'migrate' { Invoke-Migrate -MigrateArgs $ClaudeArgs; exit 0 }
    'remove'  { Invoke-Remove  -RemoveArgs  $ClaudeArgs; exit 0 }
    'rm'      { Invoke-Remove  -RemoveArgs  $ClaudeArgs; exit 0 }
}

# ── argument validation ───────────────────────────────────────────────────────

if (-not $FolderPath) {
    Show-Usage
    exit 1
}

try {
    $AbsPath = (Resolve-Path -LiteralPath $FolderPath -ErrorAction Stop).Path
} catch {
    Write-Err "Path does not exist: $FolderPath"
}

if (-not (Test-Path -LiteralPath $AbsPath -PathType Container)) {
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
    # session history survive container recreation (e.g. 'safe-claude migrate').
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
# Claude Code refuses --dangerously-skip-permissions as root, so it runs as the
# image's non-root 'node' user. Docker Desktop maps bind-mount ownership for us,
# so unlike native Linux there is no host UID to match here.
docker exec -it -u node -e HOME=/home/node $ContainerName claude @ClaudeArgs