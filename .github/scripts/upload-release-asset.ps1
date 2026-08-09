<#
.SYNOPSIS
    Creates the release for the current tag if absent, then uploads one asset to it.

.DESCRIPTION
    Uses the REST API directly rather than an action, because this repository's
    Actions policy allows only everxyz-owned actions.

    Written for Windows PowerShell 5.1, the only PowerShell on the self-hosted
    runner. Uses Invoke-RestMethod rather than curl plus a JSON parser so the job
    has no dependency on python or a Unix shell.

    Requires GH_TOKEN, GITHUB_REPOSITORY and GITHUB_REF_NAME in the environment.

.PARAMETER Asset
    Path to the file to attach to the release.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string] $Asset
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# PowerShell 5.1 may still default to TLS 1.0, which api.github.com rejects.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not (Test-Path -LiteralPath $Asset)) { throw "No such file: $Asset" }
foreach ($name in 'GH_TOKEN', 'GITHUB_REPOSITORY', 'GITHUB_REF_NAME') {
    if (-not (Get-Item "env:$name" -ErrorAction SilentlyContinue).Value) {
        throw "$name is required"
    }
}

$repo    = $env:GITHUB_REPOSITORY
$tag     = $env:GITHUB_REF_NAME
$api     = "https://api.github.com/repos/$repo"
$headers = @{
    Authorization          = "Bearer $env:GH_TOKEN"
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent'           = 'everxyz-release-workflow'
}

# --- find or create the release ---------------------------------------------
# Reads the status via PSObject.Properties: under Set-StrictMode -Version Latest,
# '$_.Exception.Response' throws PropertyNotFoundException when the failure is not an
# HTTP one (TLS, DNS, a proxy resetting the connection), which would hide the real
# cause behind a misleading error.
function Get-HttpStatus($errorRecord) {
    $response = $errorRecord.Exception.PSObject.Properties['Response']
    if (-not $response -or -not $response.Value) { return $null }
    return [int] $response.Value.StatusCode
}

function Get-ReleaseByTag {
    try {
        return Invoke-RestMethod -Uri "$api/releases/tags/$tag" -Headers $headers -Method Get
    } catch {
        if ((Get-HttpStatus $_) -ne 404) { throw }
        return $null
    }
}

$release = Get-ReleaseByTag

if (-not $release) {
    Write-Host "Creating release $tag"
    # everxyz-dev-* tags are pre-releases; everxyz-release-* are full releases.
    $body = @{
        tag_name               = $tag
        name                   = $tag
        prerelease             = $tag.StartsWith('everxyz-dev-')
        generate_release_notes = $true
    } | ConvertTo-Json -Compress

    try {
        $release = Invoke-RestMethod -Uri "$api/releases" -Headers $headers -Method Post `
                                     -Body $body -ContentType 'application/json'
    } catch {
        # The windows-x64 and linux-amd64 jobs both upload to the same tag, so they
        # race to create the release. The loser gets 422 (already_exists); re-read
        # instead of failing the build.
        if ((Get-HttpStatus $_) -ne 422) { throw }
        Write-Host "Release $tag was created concurrently; re-reading it"
        $release = Get-ReleaseByTag
        if (-not $release) { throw "Release $tag reported as existing but could not be read" }
    }
}

# Probed via PSObject.Properties rather than '-not $release.id': under
# Set-StrictMode -Version Latest, reading an absent property throws
# PropertyNotFoundException, which would replace this message with a cryptic one.
$releaseId = $release.PSObject.Properties['id'].Value
if (-not $releaseId) { throw "Could not resolve a release id for $tag" }

# --- replace any existing asset of the same name (makes re-runs idempotent) ---
$assetName = Split-Path -Leaf $Asset
$existing  = Invoke-RestMethod -Uri "$api/releases/$releaseId/assets?per_page=100" `
                               -Headers $headers -Method Get
$stale = @($existing) | Where-Object { $_.name -eq $assetName } | Select-Object -First 1
if ($stale) {
    Write-Host "Replacing existing asset $assetName"
    Invoke-RestMethod -Uri "$api/releases/assets/$($stale.id)" -Headers $headers -Method Delete | Out-Null
}

# --- upload ------------------------------------------------------------------
$sizeMb = [math]::Round((Get-Item -LiteralPath $Asset).Length / 1MB, 1)
Write-Host "Uploading $assetName ($sizeMb MB)"

$uploadUri = "https://uploads.github.com/repos/$repo/releases/$releaseId/assets?name=$assetName"
Invoke-RestMethod -Uri $uploadUri -Headers $headers -Method Post `
                  -InFile $Asset -ContentType 'application/gzip' | Out-Null

Write-Host "Uploaded $assetName to release $tag"
