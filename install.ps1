<#
.SYNOPSIS
    Guided installation for safe-claude on Windows.

.DESCRIPTION
    1. Checks prerequisites (Docker Desktop)
    2. Pulls the pinned 'safe-claude' Docker image from GHCR
    3. Installs safe-claude.ps1 and a safe-claude.bat wrapper to a directory on
       your PATH (and adds that directory to PATH)

    Usage:
        powershell -ExecutionPolicy Bypass -File install.ps1 [-InstallDir <path>] [-Yes]

.PARAMETER InstallDir
    Where to put the 'safe-claude' command. Defaults to a per-user location that
    needs no administrator rights. Can also be set via the INSTALL_DIR
    environment variable.

.PARAMETER Yes
    Do not prompt before reinstalling over an existing copy. Same as setting the
    ASSUME_YES environment variable to 1, which is how 'safe-claude update'
    drives this installer.

.NOTES
    If PowerShell blocks this script due to execution policy, run:
        Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
    Or launch the installer with:
        powershell -ExecutionPolicy Bypass -File install.ps1
#>

param(
    [string]$InstallDir,

    [Alias('y')]
    [switch]$Yes
)

# Stamped by CI at release time.
$VERSION    = '@VERSION@'
$IMAGE_NAME = '@IMAGE_DIGEST@'      # ghcr.io/nateso/safe-claude@sha256:...
$REPO       = 'nateso/safe-claude'

$DEFAULT_DIR = Join-Path $env:LOCALAPPDATA 'Programs\safe-claude'

# ── helpers ───────────────────────────────────────────────────────────────────

function Write-Info    { param([string]$m) Write-Host "[safe-claude] $m" }
function Write-Success { param([string]$m) Write-Host "[safe-claude] OK  $m" -ForegroundColor Green }
function Write-Warn    { param([string]$m) Write-Host "[safe-claude] !   $m" -ForegroundColor Yellow }
function Write-Err     { param([string]$m) Write-Host "[safe-claude] Error: $m" -ForegroundColor Red; exit 1 }

# Windows PowerShell 5.1 still defaults to TLS 1.0, which github.com refuses.
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {
    Write-Verbose "Could not raise the TLS version: $_"
}

# Unstamped copy (run from a repo checkout, not a release) -> dev fallback.
$DevMode = $false
if ($VERSION -like '@*@') {
    $DevMode    = $true
    $VERSION    = 'dev'
    $IMAGE_NAME = "ghcr.io/${REPO}:latest"
}

# Empty when the installer was piped into PowerShell ('irm ... | iex') rather
# than run from a file.
$ScriptDir = $PSScriptRoot

# ── options ───────────────────────────────────────────────────────────────────

if ([string]::IsNullOrWhiteSpace($InstallDir)) { $InstallDir = $env:INSTALL_DIR }
$assumeYes = $Yes.IsPresent -or ($env:ASSUME_YES -eq '1')

# PowerShell variable names are case-insensitive, so the working variable must
# NOT be called $installDir: that is the -InstallDir parameter, and assigning
# the default to it would discard the caller's choice.
$usingDefault = [string]::IsNullOrWhiteSpace($InstallDir)
if ($usingDefault) { $targetDir = $DEFAULT_DIR } else { $targetDir = $InstallDir }
$targetDir = $targetDir.TrimEnd('\').TrimEnd('/')

# ── step 1: prerequisites ─────────────────────────────────────────────────────

Write-Host ""
Write-Host "==========================================="
Write-Host "  safe-claude installer ($VERSION)"
Write-Host "==========================================="
Write-Host ""

Write-Info "Checking prerequisites..."

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Err "Docker is not installed or not on PATH.`n  Install Docker Desktop from https://www.docker.com and re-run this script."
}

$null = docker info 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Err "Docker daemon is not running. Please start Docker Desktop and re-run this script."
}

Write-Success "Docker is available and running."

if ($DevMode) { Write-Warn "Unstamped development copy -- using ':latest' and the repo checkout." }

# --- Check existing installation of safe-claude -------------------------------

$existing = Get-Command safe-claude -ErrorAction SilentlyContinue
if ($existing) {
    $existingPath = $existing.Source
    $existingVersion = 'unknown'
    try {
        $reported = (& $existingPath --version 2>$null | Out-String).Trim()
        if ($reported) { $existingVersion = $reported }
    } catch {
        Write-Verbose "Could not read the installed version: $_"
    }

    Write-Host ""
    Write-Warn "safe-claude is already installed at $existingPath (version: $existingVersion)"

    $existingDir = (Split-Path -Parent $existingPath).TrimEnd('\')
    if ($usingDefault -and $existingDir -ne $targetDir) {
        Write-Info "Reinstalling over the existing location."
        $targetDir = $existingDir
    }

    if (-not $assumeYes) {
        if (-not [Console]::IsInputRedirected) {
            $reply = Read-Host "[safe-claude] Reinstall $VERSION to '$targetDir'? [y/N]"
            if ($reply -notmatch '^[Yy]$') {
                Write-Info "Aborted -- nothing was changed."
                exit 0
            }
        } else {
            Write-Info "No terminal available -- proceeding with reinstall."
        }
    }
}

# ── step 2: pull the Docker image ─────────────────────────────────────────────

Write-Host ""
$imagePresent = $false
if (-not $DevMode) {
    $null = docker image inspect $IMAGE_NAME 2>&1
    # A digest reference is immutable: present locally == correct. Nothing to check.
    $imagePresent = ($LASTEXITCODE -eq 0)
}

if ($imagePresent) {
    Write-Success "Image for $VERSION is already present locally."
} else {
    Write-Info "Pulling safe-claude image for $VERSION (this may take a few minutes)..."
    docker pull $IMAGE_NAME
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Could not pull the image. Check your internet connection, and that`n         the 'safe-claude' package on GHCR is public."
    }
    Write-Success "Image pulled successfully."
    # Digest pulls show up as <none> in 'docker images'; give it a readable tag.
    if (-not $DevMode) { docker tag $IMAGE_NAME "ghcr.io/${REPO}:$VERSION" | Out-Null }
}

# ── step 3: install the safe-claude command ───────────────────────────────────
# The script is a release asset from the same release as this installer.

Write-Host ""
Write-Info "Installing the 'safe-claude' command to:"
Write-Host "               $targetDir"
if ($usingDefault) {
    Write-Host "             (to put it somewhere else, re-run with:  -InstallDir <path>)"
}

if (-not (Test-Path -LiteralPath $targetDir)) {
    try {
        New-Item -ItemType Directory -Path $targetDir -Force -ErrorAction Stop | Out-Null
    } catch {
        Write-Err "Could not create '$targetDir': $_"
    }
    Write-Success "Created directory '$targetDir'."
}

$destPs1 = Join-Path $targetDir 'safe-claude.ps1'
$destBat = Join-Path $targetDir 'safe-claude.bat'

# A GUID-named file in the user's TEMP: a fixed name would let anything else on
# the machine pre-create it and swap its content before it is moved into place.
$tmpScript = Join-Path $env:TEMP ('safe-claude-' + [System.Guid]::NewGuid().ToString('N') + '.ps1')
$staged    = Join-Path $targetDir (".safe-claude.ps1.tmp.$PID")

try {
    if ($DevMode) {
        # Dev: use the copy sitting next to this installer in the checkout.
        $localCopy = if ($ScriptDir) { Join-Path $ScriptDir 'safe-claude.ps1' } else { $null }
        if (-not ($localCopy -and (Test-Path -LiteralPath $localCopy))) {
            Write-Err "Dev mode: no 'safe-claude.ps1' next to install.ps1."
        }
        Copy-Item -LiteralPath $localCopy -Destination $tmpScript -Force
    } else {
        Write-Info "Downloading the safe-claude script ($VERSION)..."
        try {
            Invoke-WebRequest -Uri "https://github.com/$REPO/releases/download/$VERSION/safe-claude.ps1" `
                -OutFile $tmpScript -UseBasicParsing -ErrorAction Stop
        } catch {
            Write-Err "Could not download the safe-claude script for $VERSION."
        }
    }

    # Sanity checks: non-empty, looks like the right script, parses.
    if (-not (Test-Path -LiteralPath $tmpScript) -or (Get-Item -LiteralPath $tmpScript).Length -eq 0) {
        Write-Err "Downloaded script is empty."
    }
    if ((Get-Content -LiteralPath $tmpScript -Raw) -notmatch 'safe-claude') {
        Write-Err "Downloaded file is not the safe-claude script."
    }
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile(
        (Resolve-Path -LiteralPath $tmpScript).Path, [ref]$null, [ref]$parseErrors)
    if ($parseErrors) {
        Write-Err "Downloaded script fails a syntax check: $($parseErrors[0].Message)"
    }

    # Stage next to the destination, then rename: same directory, and it never
    # truncates $destPs1 in place -- which may be the very script running us when
    # invoked via 'safe-claude update'.
    Copy-Item -LiteralPath $tmpScript -Destination $staged -Force
    Move-Item -LiteralPath $staged -Destination $destPs1 -Force
} finally {
    Remove-Item -LiteralPath $tmpScript -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $staged    -Force -ErrorAction SilentlyContinue
}

# .bat wrapper so 'safe-claude' works from CMD and PowerShell without typing .ps1
@"
@echo off
powershell.exe -ExecutionPolicy Bypass -File "%~dp0safe-claude.ps1" %*
"@ | Set-Content -Path $destBat -Encoding ASCII

Write-Success "'safe-claude' $VERSION installed to '$destPs1'."

# ── step 3b: add to PATH ──────────────────────────────────────────────────────
# Windows-only step: the bash installer's default dir is already on PATH.

$currentPath = [System.Environment]::GetEnvironmentVariable("PATH", "User")
if ($currentPath -notlike "*$targetDir*") {
    [System.Environment]::SetEnvironmentVariable("PATH", "$currentPath;$targetDir", "User")
    Write-Success "Added '$targetDir' to your user PATH."
    Write-Warn "Restart your terminal for the PATH change to take effect."
} else {
    Write-Info "'$targetDir' is already on your PATH."
}

# ── step 4: verify ────────────────────────────────────────────────────────────

Write-Host ""
$found = Get-Command safe-claude -ErrorAction SilentlyContinue
if ($found -and ((Split-Path -Parent $found.Source).TrimEnd('\') -eq $targetDir)) {
    Write-Success "Installation verified -- 'safe-claude' is on your PATH."
} elseif ($found) {
    Write-Warn "Another copy at '$($found.Source)' shadows the one just installed to '$destPs1'."
    Write-Warn "Remove it, or re-run with:  -InstallDir $(Split-Path -Parent $found.Source)"
} else {
    # A fresh PATH entry only reaches new terminals, so Get-Command can miss it
    # in this session even though the install succeeded.
    $refreshedPath = [System.Environment]::GetEnvironmentVariable("PATH", "User")
    if ($refreshedPath -like "*$targetDir*") {
        Write-Success "Installation verified -- restart your terminal, then 'safe-claude' will be on your PATH."
    } else {
        Write-Warn "'$targetDir' does not appear to be on your PATH."
        Write-Warn "Add it under:  Settings > System > About > Advanced system settings > Environment Variables"
    }
}

# ── done ──────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "==========================================="
Write-Host "  All done!"
Write-Host "==========================================="
Write-Host ""
Write-Host "  Restart your terminal, then use:"
Write-Host ""
Write-Host "    safe-claude C:\path\to\your\project"
Write-Host ""
Write-Host "  This will create a sandboxed Docker container for that folder"
Write-Host "  (if one doesn't exist yet) and launch Claude Code."
Write-Host ""
Write-Host ""
