<#
.SYNOPSIS
    Installs the everxyz-win self-hosted GitHub Actions runner on this machine.

.DESCRIPTION
    Creates a dedicated low-privilege local account, lays out the runner and work
    directories on F:, downloads and verifies the runner, registers it as a Windows
    service under that account, and installs a machine-wide CMake.

    Idempotent: steps that are already done are detected and skipped, so the script
    can be re-run after fixing a failure.

.PARAMETER Token
    Runner registration token from
    https://github.com/everxyz/OCCT/settings/actions/runners/new?arch=x64&os=win
    Valid for one hour.

.PARAMETER RunnerPassword
    Password for the local ghrunner account. Prompted for securely if omitted.
    On first run this sets the password; on re-runs it must match the existing one.

.EXAMPLE
    .\install-runner.ps1 -Token ABCDEF...

.NOTES
    Must run in an elevated PowerShell session.
    Security: everxyz/OCCT is public. See RUNNER-SETUP.md for why that matters and
    which repository settings to tighten afterwards.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Token,

    [securestring] $RunnerPassword,

    [string] $RepoUrl      = 'https://github.com/everxyz/OCCT',
    [string] $RunnerName   = 'everxyz-win-01',
    [string] $RunnerLabel  = 'everxyz-win',
    [string] $AccountName  = 'ghrunner',
    [string] $RunnerDir    = 'F:\actions-runner',
    [string] $WorkDir      = 'F:\ghrunner-work',
    [string] $RunnerVersion = '2.336.0',
    [string] $RunnerSha256 = 'd59123a43003e357b0805b5d0f611d0bd2f65ab67d51bd070dd4e7a0f685c162',

    [switch] $SkipCMake
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Step { param([string] $Message) Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string] $Message) Write-Host "    OK: $Message" -ForegroundColor Green }
function Write-Skip { param([string] $Message) Write-Host "    skip: $Message" -ForegroundColor DarkGray }
function Write-Warn { param([string] $Message) Write-Host "    warning: $Message" -ForegroundColor Yellow }

# --- preflight ---------------------------------------------------------------
Write-Step 'Preflight checks'

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    throw 'This script must run in an elevated PowerShell session (Run as Administrator).'
}
Write-Ok 'running elevated'

$targetDrive = (Split-Path -Qualifier $RunnerDir).TrimEnd(':')
if (-not (Test-Path "${targetDrive}:\")) {
    throw "Drive ${targetDrive}: not found. Pass -RunnerDir/-WorkDir pointing at a drive that exists."
}
$freeGb = [math]::Round((Get-PSDrive $targetDrive).Free / 1GB, 1)
if ($freeGb -lt 60) {
    Write-Warn "only $freeGb GB free on ${targetDrive}: — a full OCCT build for both targets may not fit"
} else {
    Write-Ok "${targetDrive}: has $freeGb GB free"
}

# --- account -----------------------------------------------------------------
Write-Step "Local account '$AccountName'"

$account = Get-LocalUser -Name $AccountName -ErrorAction SilentlyContinue
if ($account) {
    Write-Skip "account exists"
    if (-not $RunnerPassword) {
        $RunnerPassword = Read-Host -AsSecureString "Existing password for $AccountName"
    }
} else {
    if (-not $RunnerPassword) {
        $RunnerPassword  = Read-Host -AsSecureString "New password for $AccountName"
        $confirmPassword = Read-Host -AsSecureString "Confirm password"
        $a = [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
                [Runtime.InteropServices.Marshal]::SecureStringToBSTR($RunnerPassword))
        $b = [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
                [Runtime.InteropServices.Marshal]::SecureStringToBSTR($confirmPassword))
        if ($a -ne $b) { throw 'Passwords do not match.' }
    }
    New-LocalUser -Name $AccountName -Password $RunnerPassword `
                  -PasswordNeverExpires -AccountNeverExpires `
                  -UserMayNotChangePassword `
                  -Description 'GitHub Actions runner service account' | Out-Null
    Write-Ok 'account created'
}

foreach ($group in @('Users', 'docker-users')) {
    if (-not (Get-LocalGroup -Name $group -ErrorAction SilentlyContinue)) {
        Write-Warn "group '$group' does not exist — skipping (install Docker Desktop for the Linux job)"
        continue
    }
    $already = Get-LocalGroupMember -Group $group -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -like "*\$AccountName" }
    if ($already) {
        Write-Skip "already in $group"
    } else {
        Add-LocalGroupMember -Group $group -Member $AccountName
        Write-Ok "added to $group"
    }
}

# --- directories -------------------------------------------------------------
Write-Step 'Directories and permissions'

foreach ($dir in @($RunnerDir, $WorkDir)) {
    if (Test-Path $dir) { Write-Skip "$dir exists" }
    else { New-Item -ItemType Directory -Force -Path $dir | Out-Null; Write-Ok "created $dir" }

    # /T applies to existing children; (OI)(CI) makes it inherit to new ones.
    $null = icacls $dir /grant "${AccountName}:(OI)(CI)F" /T /Q
    if ($LASTEXITCODE -ne 0) { throw "icacls failed on $dir" }
    Write-Ok "granted $AccountName full control of $dir"
}

# --- download ----------------------------------------------------------------
Write-Step "Runner v$RunnerVersion"

if (Test-Path (Join-Path $RunnerDir 'config.cmd')) {
    Write-Skip 'runner already extracted'
} else {
    $zip = Join-Path $env:TEMP "actions-runner-win-x64-$RunnerVersion.zip"
    $url = "https://github.com/actions/runner/releases/download/v$RunnerVersion/actions-runner-win-x64-$RunnerVersion.zip"

    if (-not (Test-Path $zip)) {
        Write-Host "    downloading (~103 MB)..."
        # Progress rendering makes Invoke-WebRequest dramatically slower.
        $prev = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
        try   { Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing }
        finally { $ProgressPreference = $prev }
    } else {
        Write-Skip 'zip already downloaded'
    }

    $actual = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $RunnerSha256.ToLower()) {
        Remove-Item $zip -Force
        throw "SHA256 mismatch. Expected $RunnerSha256, got $actual. Deleted the download."
    }
    Write-Ok 'SHA256 verified'

    Expand-Archive -Path $zip -DestinationPath $RunnerDir -Force
    Remove-Item $zip -Force
    Write-Ok "extracted to $RunnerDir"
}

# --- register ----------------------------------------------------------------
Write-Step 'Register runner service'

$existingService = Get-Service -Name 'actions.runner.*' -ErrorAction SilentlyContinue
if ($existingService) {
    Write-Skip "service already registered: $($existingService.Name -join ', ')"
    Write-Host '    To re-register, first run:' -ForegroundColor DarkGray
    Write-Host "      cd $RunnerDir; .\config.cmd remove --token <REMOVAL_TOKEN>" -ForegroundColor DarkGray
} else {
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
                [Runtime.InteropServices.Marshal]::SecureStringToBSTR($RunnerPassword))

    Push-Location $RunnerDir
    try {
        # config.cmd is a batch script; call it via cmd so arguments pass verbatim.
        & cmd.exe /c config.cmd `
            --url $RepoUrl `
            --token $Token `
            --name $RunnerName `
            --labels $RunnerLabel `
            --work $WorkDir `
            --runasservice `
            --windowslogonaccount ".\$AccountName" `
            --windowslogonpassword $plain `
            --unattended `
            --replace
        if ($LASTEXITCODE -ne 0) {
            throw "config.cmd failed with exit code $LASTEXITCODE. A stale or expired token is the usual cause — generate a fresh one."
        }
    } finally {
        Pop-Location
        $plain = $null
        [GC]::Collect()
    }
    Write-Ok "registered as '$RunnerName' with label '$RunnerLabel'"
}

# --- cmake -------------------------------------------------------------------
Write-Step 'Machine-wide CMake'

if ($SkipCMake) {
    Write-Skip '-SkipCMake specified'
} else {
    $cmakeOnPath = Get-Command cmake.exe -ErrorAction SilentlyContinue
    if ($cmakeOnPath) {
        Write-Skip "cmake already on PATH: $($cmakeOnPath.Source)"
    } elseif (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        Write-Warn 'winget not available — install CMake manually and ensure it is on the machine PATH'
    } else {
        # The runner service only sees machine-scoped PATH entries, so --scope machine
        # matters here; a user-scoped install would be invisible to it.
        & winget.exe install --id Kitware.CMake --scope machine `
            --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "winget exited $LASTEXITCODE — verify CMake manually"
        } else {
            Write-Ok 'CMake installed machine-wide'
        }
    }
}

# --- restart so the service picks up PATH changes ----------------------------
Write-Step 'Start service'

$service = Get-Service -Name 'actions.runner.*' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $service) {
    Write-Warn 'no runner service found — registration may have failed'
} else {
    Restart-Service -Name $service.Name
    Start-Sleep -Seconds 3
    $service.Refresh()
    if ($service.Status -eq 'Running') { Write-Ok "$($service.Name) is running" }
    else { Write-Warn "$($service.Name) is $($service.Status)" }
}

# --- summary -----------------------------------------------------------------
Write-Host "`n--- Remaining manual steps ---" -ForegroundColor Cyan
Write-Host @"
1. Docker (needed only by the Linux amd64 job)
   Docker Desktop runs per-user, so the service account needs its own context.
   Enable "Start Docker Desktop when you sign in", then sign in once as
   $AccountName. Verify from that account:
       docker run --rm --platform linux/amd64 ubuntu:22.04 uname -m
   Expected output: x86_64

2. Tighten repository settings (everxyz/OCCT is public)
   Settings -> Actions -> General -> Fork pull request workflows:
   require approval for outside collaborators.

3. Test the pipeline
   Actions -> everxyz Build -> Run workflow
   mode: Release, targets: windows-x64   (this path does not need Docker)

   Then a real tag:
       git tag everxyz-release-1.0.0 && git push origin everxyz-release-1.0.0
"@ -ForegroundColor Gray
