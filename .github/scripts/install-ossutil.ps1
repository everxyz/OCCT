<#
.SYNOPSIS
    Vendors a checksum-pinned ossutil 2.3.0 for publishing artifacts to Aliyun OSS.

.DESCRIPTION
    Windows port of Utopia's scripts/install-ossutil.sh, and deliberately a port
    rather than a reinvention: the OCCT artifact publication follows the same
    contract as Utopia's engineering-asset supply, so it uses the same tool at
    the same pinned version and verifies the same digest.

    The download is pinned by SHA-256. ossutil is fetched over the public CDN,
    so an unverified binary would be an unauthenticated code path straight into
    a job that holds OSS publish credentials.

    Default destination is the runner's tools directory rather than the
    workspace. This runner is non-ephemeral, so a cached binary there survives
    between jobs; the workspace is wiped on every checkout and would re-download
    ossutil on every single run. Falls back to '<cwd>\target\tools' (Utopia's
    layout) when the tools directory is not writable, e.g. on a dev machine.

.OUTPUTS
    The absolute path of the verified ossutil.exe, as the only stdout line.
#>
[CmdletBinding()]
param(
    # Full path of the ossutil.exe to create. Defaults to the runner tools cache.
    [string] $Destination
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$version = '2.3.0'
$package = "ossutil-$version-windows-amd64"

# From Utopia's scripts/install-ossutil.sh (MINGW64/MSYS/CYGWIN x86_64 case).
# Keep these two in step: same upstream artifact, same digest.
$checksum = '98209156987667b39fd12a0c7b940342900daef61a9306ea7f34acf17f287da2'
$url      = "https://gosspublic.alicdn.com/ossutil/v2/$version/$package.zip"

function Resolve-Destination {
    param([string] $Requested)

    if ($Requested) { return $Requested }
    if ($env:OCCT_OSSUTIL_BIN) { return $env:OCCT_OSSUTIL_BIN }

    # Same cache the vendored docker.exe lives in, for the same reason.
    $toolsDir = if ($env:OCCT_TOOLS_DIR) { $env:OCCT_TOOLS_DIR } else { 'F:\actions-runner\tools' }
    if (Test-Path -LiteralPath $toolsDir) {
        # Probe writability rather than assuming it: the runner account has full
        # control here today, but a dev machine running this script may not.
        $probe = Join-Path $toolsDir ".write-probe-$PID"
        try {
            [System.IO.File]::WriteAllText($probe, '')
            Remove-Item -LiteralPath $probe -Force
            return (Join-Path $toolsDir 'ossutil.exe')
        } catch {
            Write-Host "note: $toolsDir is not writable, using the workspace instead"
        }
    }
    return (Join-Path (Get-Location).Path 'target\tools\ossutil.exe')
}

function Get-OssutilVersion {
    param([string] $Exe)

    # 'ossutil version' prints the bare version on success. Any failure here
    # means the cached copy is unusable, which is a cache miss, not an error.
    try {
        $output = & $Exe version 2>&1
        if ($LASTEXITCODE -ne 0) { return $null }
        return ($output | Out-String).Trim()
    } catch {
        return $null
    }
}

$destination = Resolve-Destination -Requested $Destination

# Reuse a cached copy only when it reports the pinned version.
if (Test-Path -LiteralPath $destination) {
    $cached = Get-OssutilVersion -Exe $destination
    if ($cached -and $cached -match [regex]::Escape($version)) {
        Write-Host "ossutil $version already vendored at $destination"
        Write-Output $destination
        exit 0
    }
    Write-Host "replacing unusable or mismatched ossutil at $destination (reported: $cached)"
}

# PowerShell 5.1 negotiates SSLv3/TLS 1.0 by default, which the CDN rejects.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$temporary = Join-Path ([System.IO.Path]::GetTempPath()) "occt-ossutil-$([guid]::NewGuid().ToString('n'))"
New-Item -ItemType Directory -Path $temporary | Out-Null
try {
    $archive = Join-Path $temporary "$package.zip"

    # .NET on Windows PowerShell takes its proxy from WinINET, not from the
    # http_proxy/https_proxy variables the runner sets in its .env. Honour them
    # explicitly so this works the same way the rest of the runner's egress does.
    $webArgs = @{
        Uri             = $url
        OutFile         = $archive
        UseBasicParsing = $true
        TimeoutSec      = 300
    }
    $proxy = if ($env:https_proxy) { $env:https_proxy } else { $env:http_proxy }
    if ($proxy) {
        Write-Host "using proxy $proxy"
        $webArgs['Proxy'] = $proxy
    }

    Write-Host "downloading $url"
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            Invoke-WebRequest @webArgs
            break
        } catch {
            if ($attempt -ge 3) { throw }
            Write-Host "attempt $attempt failed ($($_.Exception.Message)); retrying"
            Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds (2 * $attempt)
        }
    }

    $actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $checksum) {
        throw "ossutil checksum mismatch for ${package}.zip`n  expected $checksum`n  actual   $actual"
    }
    Write-Host "checksum ok ($actual)"

    Expand-Archive -LiteralPath $archive -DestinationPath $temporary -Force

    # Upstream nests the binary inside a directory named after the package.
    $extracted = Join-Path $temporary "$package\ossutil.exe"
    if (-not (Test-Path -LiteralPath $extracted)) {
        $found = Get-ChildItem -LiteralPath $temporary -Recurse -Filter 'ossutil.exe' |
                 Select-Object -First 1
        if (-not $found) { throw "ossutil.exe not found inside ${package}.zip" }
        $extracted = $found.FullName
    }

    $parent = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Copy-Item -LiteralPath $extracted -Destination $destination -Force

    $installed = Get-OssutilVersion -Exe $destination
    if (-not ($installed -and $installed -match [regex]::Escape($version))) {
        throw "vendored ossutil does not report $version (reported: $installed)"
    }
    Write-Host "ossutil $installed vendored at $destination"
    Write-Output $destination
} finally {
    Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
}
