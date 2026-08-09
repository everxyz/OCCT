<#
.SYNOPSIS
    Removes the everxyz-win self-hosted runner installed by install-runner.ps1.

.DESCRIPTION
    Deregisters the runner from GitHub, removes its Windows service, and optionally
    deletes the local account and the runner/work directories.

    Deregistration needs a removal token from
    https://github.com/everxyz/OCCT/settings/actions/runners
    (open the runner, choose Remove, and copy the token from the command shown).

    Without -Token the service is stopped and removed locally but the runner stays
    listed in the repository as offline; clean that up from the settings page.

.PARAMETER Token
    Removal token. Strongly preferred, so GitHub stops listing the runner.

.PARAMETER RemoveAccount
    Also delete the local ghrunner account.

.PARAMETER RemoveDirectories
    Also delete F:\actions-runner and F:\ghrunner-work, including any build output.

.EXAMPLE
    .\uninstall-runner.ps1 -Token ABCDEF...

.EXAMPLE
    .\uninstall-runner.ps1 -Token ABCDEF... -RemoveAccount -RemoveDirectories
#>
[CmdletBinding()]
param(
    [string] $Token,
    [string] $AccountName = 'ghrunner',
    [string] $RunnerDir   = 'F:\actions-runner',
    [string] $WorkDir     = 'F:\ghrunner-work',
    [switch] $RemoveAccount,
    [switch] $RemoveDirectories
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Step { param([string] $Message) Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string] $Message) Write-Host "    OK: $Message" -ForegroundColor Green }
function Write-Skip { param([string] $Message) Write-Host "    skip: $Message" -ForegroundColor DarkGray }
function Write-Warn { param([string] $Message) Write-Host "    warning: $Message" -ForegroundColor Yellow }

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'This script must run in an elevated PowerShell session.' }

Write-Step 'Stop runner service'
$service = Get-Service -Name 'actions.runner.*' -ErrorAction SilentlyContinue
if ($service) {
    foreach ($s in $service) {
        if ($s.Status -ne 'Stopped') { Stop-Service -Name $s.Name -Force; Write-Ok "stopped $($s.Name)" }
        else { Write-Skip "$($s.Name) already stopped" }
    }
} else {
    Write-Skip 'no runner service found'
}

Write-Step 'Deregister from GitHub'
if (-not (Test-Path (Join-Path $RunnerDir 'config.cmd'))) {
    Write-Skip "no config.cmd in $RunnerDir"
} elseif (-not $Token) {
    Write-Warn 'no -Token given: removing the service locally only.'
    Write-Warn 'The runner will still be listed (offline) in repository settings.'
    Push-Location $RunnerDir
    try { & cmd.exe /c config.cmd remove --local } finally { Pop-Location }
} else {
    Push-Location $RunnerDir
    try {
        & cmd.exe /c config.cmd remove --token $Token
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "config.cmd remove exited $LASTEXITCODE (expired token?). Falling back to local removal."
            & cmd.exe /c config.cmd remove --local
        } else {
            Write-Ok 'deregistered from GitHub'
        }
    } finally { Pop-Location }
}

Write-Step "Local account '$AccountName'"
if (-not $RemoveAccount) {
    Write-Skip 'kept (-RemoveAccount not specified)'
} elseif (Get-LocalUser -Name $AccountName -ErrorAction SilentlyContinue) {
    Remove-LocalUser -Name $AccountName
    Write-Ok "removed $AccountName"
} else {
    Write-Skip 'account does not exist'
}

Write-Step 'Directories'
if (-not $RemoveDirectories) {
    Write-Skip 'kept (-RemoveDirectories not specified)'
    foreach ($dir in @($RunnerDir, $WorkDir)) {
        if (Test-Path $dir) {
            $sizeGb = [math]::Round(
                ((Get-ChildItem $dir -Recurse -File -ErrorAction SilentlyContinue |
                  Measure-Object -Property Length -Sum).Sum / 1GB), 2)
            Write-Host "    $dir still uses $sizeGb GB" -ForegroundColor DarkGray
        }
    }
} else {
    foreach ($dir in @($RunnerDir, $WorkDir)) {
        if (-not (Test-Path $dir)) { Write-Skip "$dir does not exist"; continue }
        try {
            Remove-Item $dir -Recurse -Force -ErrorAction Stop
            Write-Ok "deleted $dir"
        } catch {
            # install-runner.ps1 strips the inherited Users/Authenticated Users
            # entries from these trees, so an account that is neither ghrunner nor
            # an administrator cannot traverse them. Reset the ACL and retry rather
            # than leaving a half-deleted tree behind.
            Write-Warn "direct delete failed ($($_.Exception.GetType().Name)); resetting ACLs and retrying"
            & icacls $dir /reset /T /C /Q 2>&1 | Out-Null
            & icacls $dir /grant 'Administrators:(OI)(CI)F' /T /C /Q 2>&1 | Out-Null
            Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path $dir) { Write-Warn "could not delete $dir" }
            else { Write-Ok "deleted $dir" }
        }
    }
}

Write-Host "`nDone. Docker images and build cache live in the Docker Desktop VM, not in" -ForegroundColor Cyan
Write-Host 'these directories. Reclaim only what this pipeline created:' -ForegroundColor Cyan
Write-Host '    docker image prune -f        # dangling layers only' -ForegroundColor Gray
Write-Host '    docker rmi ubuntu:22.04      # the one image the Linux job pulls' -ForegroundColor Gray
Write-Host ''
Write-Host 'Do NOT run "docker system prune -a --volumes" without checking what else is' -ForegroundColor Yellow
Write-Host 'on this host: it deletes every image, container and volume, including those' -ForegroundColor Yellow
Write-Host 'belonging to unrelated projects.' -ForegroundColor Yellow
