<#
.SYNOPSIS
    Creates the release for the current tag if absent, attaches one artifact to it,
    and records that artifact's retrieval paths in the notes.

.DESCRIPTION
    The archive is attached as a release asset, because that is the only retrieval
    path GitHub serves over a plain URL a browser can follow. GHCR speaks the OCI
    token handshake, so an anonymous manifest GET is 401 and there is no link to
    publish; the Aliyun OSS bucket is private, so retrieval there needs an Aliyun
    identity.

    The notes stay deliberately short: per artifact, a download link and a sha256.
    A release page exists to get someone a file, so how the CI reached its
    credentials, which bucket the blob also sits in, and which token scope the
    package needs are all operator detail that belongs in .github/RUNNER-SETUP.md.
    The one non-obvious line kept in the preamble is the LGPL corresponding-source
    pointer, which is a distribution obligation rather than a convenience.

    Each build job calls this once for its own artifact. Both jobs target the same
    release, so the body is edited incrementally: this script appends its own section
    and leaves any other job's section alone.

    Uses the REST API directly rather than an action, because this repository's
    Actions policy allows only everxyz-owned actions.

    Written for Windows PowerShell 5.1, the only PowerShell on the self-hosted
    runner. Uses Invoke-RestMethod rather than curl plus a JSON parser so the job
    has no dependency on python or a Unix shell.

    Requires GH_TOKEN, GITHUB_REPOSITORY and GITHUB_REF_NAME in the environment.

.PARAMETER Asset
    Path to the built artifact. Attached to the release, and read for its name, size
    and (when the OSS step skipped) its sha256.

.PARAMETER Sha256
    Digest of the plaintext archive, from the publish-oss step. Recomputed here when
    that step skipped, so the notes always carry a verifiable digest.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string] $Asset,

    # Human-readable build name for the section heading, e.g. 'Windows x64 (Release)'.
    # Falls back to the filename.
    [string] $Label = '',

    # Only $Sha256 reaches the notes. The rest are accepted because the workflow has
    # them to hand and a future change may want them, but the notes no longer print
    # bucket, object key, region or endpoint: they are operator detail, and a reader
    # who needs them can find them in .github/RUNNER-SETUP.md.
    [string] $Sha256 = '',
    [string] $Bucket = '',
    [string] $ObjectKey = '',
    [string] $Region = '',
    [string] $Endpoint = '',
    [string] $GhcrReference = '',

    # Upstream tag the libraries were built from, e.g. V8_0_1. Drives the LGPL
    # corresponding-source link: OCCT is LGPL-2.1 with the Open CASCADE exception,
    # and distributing the binaries obliges us to say where the matching source is.
    # This fork modifies nothing under src/, so upstream's tarball IS that source.
    [string] $UpstreamTag = ''
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

$assetItem = Get-Item -LiteralPath $Asset
$assetName = $assetItem.Name
$sizeMb    = [math]::Round($assetItem.Length / 1MB, 1)

# Recomputed only when the OSS step skipped, so the notes always carry a verifiable
# digest even when there is no object to point at yet.
if (-not $Sha256) {
    $Sha256 = (Get-FileHash -LiteralPath $Asset -Algorithm SHA256).Hash.ToLowerInvariant()
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

# The preamble states, once per release, where the bytes are and under what licence
# they are distributed. Kept separate from the per-artifact sections so appending
# never duplicates it.
$preambleMarker = '<!-- everxyz:preamble -->'
$preambleLines = [System.Collections.Generic.List[string]]::new()
$preambleLines.Add($preambleMarker)
# LGPL-2.1 section 4 lets an object-code distributor satisfy the source obligation by
# offering equivalent access to the source. This fork changes nothing under src/, so
# upstream's own tarball for the same tag IS the corresponding source, and pointing at
# it discharges the obligation without publishing anything from this private
# repository. If a patch to src/ ever lands, section 2(a) starts to apply instead: the
# modified source has to be offered too. That is why this line is not decoration.
if ($UpstreamTag) {
    $preambleLines.Add("Built from unmodified upstream OCCT ``$UpstreamTag``, shared libraries, no")
    $preambleLines.Add('visualization. LGPL-2.1 with the Open CASCADE exception;')
    $preambleLines.Add("[corresponding source](https://github.com/Open-Cascade-SAS/OCCT/archive/refs/tags/$UpstreamTag.tar.gz).")
} else {
    $preambleLines.Add('Shared libraries, no visualization. LGPL-2.1 with the Open CASCADE exception.')
}
$preamble = ($preambleLines -join "`n")

if (-not (Get-ReleaseByTag)) {
    Write-Host "Creating release $tag"
    # everxyz-debug-* tags are pre-releases; everxyz-release-* are full releases.
    $body = @{
        tag_name               = $tag
        name                   = $tag
        prerelease             = $tag.StartsWith('everxyz-debug-')
        body                   = $preamble
        generate_release_notes = $false
    } | ConvertTo-Json -Compress

    try {
        Invoke-RestMethod -Uri "$api/releases" -Headers $headers -Method Post `
                          -Body $body -ContentType 'application/json' | Out-Null
    } catch {
        # The windows-x64 and linux-amd64 jobs both target the same tag, so they race
        # to create the release. The loser gets 422 (already_exists), which is fine:
        # the re-read below picks up whichever one won.
        if ((Get-HttpStatus $_) -ne 422) { throw }
        Write-Host "Release $tag was created concurrently"
    }
}

# --- record this artifact ----------------------------------------------------

# A stable marker per artifact makes re-runs idempotent: a second run for the same
# artifact replaces its section instead of appending a duplicate.
$marker  = "<!-- everxyz:artifact:$assetName -->"
$endMark = "<!-- /everxyz:artifact:$assetName -->"

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add($marker)
# Platform and mode, not the filename: the filename is already the link text, and
# 'Windows x64' reads faster than 'occt-8.0.1-windows-x64-release.tar.gz' when you are
# scanning for the build you want.
$heading = if ($Label) { $Label } else { $assetName }
$lines.Add("### $heading")
$lines.Add('')
# The asset is attached above, so its URL is deterministic and needs no lookup:
# /releases/download/<tag>/<name>. This is the only retrieval path that is a plain URL
# a browser can follow -- GHCR needs the OCI token handshake, and the OSS bucket needs
# an Aliyun identity. Everything else about those two paths belongs in RUNNER-SETUP.md,
# not on a page whose job is to get someone a file.
$lines.Add("[``$assetName``](https://github.com/$repo/releases/download/$tag/$assetName) &nbsp;&nbsp; $sizeMb MB")
$lines.Add('')
$lines.Add('```')
$lines.Add("sha256  $Sha256")
$lines.Add('```')

$lines.Add($endMark)
$section = ($lines -join "`n")

# Re-read immediately before the edit rather than reusing the copy from the create
# branch above: the other job may have recorded its own section in between, and
# writing a stale body would silently drop it.
$release = Get-ReleaseByTag
if (-not $release) { throw "Release $tag could not be read" }
$releaseId = $release.PSObject.Properties['id'].Value
if (-not $releaseId) { throw "Could not resolve a release id for $tag" }

# --- attach the asset --------------------------------------------------------
# Attached again, reversing the coordinates-only change. That change assumed some
# other store would serve the bytes over a URL, and none does: GHCR speaks the OCI
# token handshake, so an anonymous manifest GET is 401 and there is no link to put
# in the notes, and the OSS bucket is unprovisioned. The two together left a reader
# with no path from the release page to a file. A release asset is the only thing
# GitHub serves over a plain URL a browser can follow.
#
# Uploaded before the notes are written, so the link in them never points at an
# asset that is not there yet.
#
# Re-runs replace rather than duplicate: POST with a name that already exists gets
# 422 already_exists, so any previous copy is deleted first. Same convergence rule
# as the marker replacement below.
$existingAssets = @()
$assetsResponse = Invoke-RestMethod -Uri "$api/releases/$releaseId/assets?per_page=100" `
                                    -Headers $headers -Method Get
if ($assetsResponse) { $existingAssets = @($assetsResponse) }

foreach ($candidate in $existingAssets) {
    # PSObject.Properties rather than $candidate.name: Set-StrictMode -Version
    # Latest throws on a property that is absent rather than returning $null.
    $nameProp = $candidate.PSObject.Properties['name']
    if (-not $nameProp -or $nameProp.Value -ne $assetName) { continue }
    Write-Host "Replacing the existing asset $assetName"
    $victimId = $candidate.PSObject.Properties['id'].Value
    Invoke-RestMethod -Uri "$api/releases/assets/$victimId" `
                      -Headers $headers -Method Delete | Out-Null
}

Write-Host "Uploading $assetName ($sizeMb MB)"
# -InFile streams from disk. Reading the bytes into a variable first would hold a
# few hundred MB in memory, and a Debug archive is ~240 MB.
$uploadUri = "https://uploads.github.com/repos/$repo/releases/$releaseId/assets?name=$assetName"
Invoke-RestMethod -Uri $uploadUri -Headers $headers -Method Post `
                  -InFile $Asset -ContentType 'application/gzip' | Out-Null
Write-Host "Uploaded $assetName"

$currentBody = ''
$bodyProperty = $release.PSObject.Properties['body']
if ($bodyProperty -and $bodyProperty.Value) { $currentBody = $bodyProperty.Value }

if ($currentBody -notlike "*$preambleMarker*") {
    $currentBody = if ($currentBody) { "$preamble`n`n$currentBody" } else { $preamble }
}

if ($currentBody -like "*$marker*") {
    Write-Host "Replacing the existing section for $assetName"
    # Non-greedy so two artifact sections in one body do not collapse into one match.
    $pattern = "(?s)" + [regex]::Escape($marker) + ".*?" + [regex]::Escape($endMark)
    # A scriptblock replacement, so a '$1' or '$&' inside a digest or key is inserted
    # literally instead of being read as a capture-group reference.
    $newBody = [regex]::Replace($currentBody, $pattern, { $section })
} else {
    Write-Host "Recording $assetName"
    $newBody = "$currentBody`n`n$section"
}

$patch = @{ body = $newBody } | ConvertTo-Json -Compress
Invoke-RestMethod -Uri "$api/releases/$releaseId" -Headers $headers -Method Patch `
                  -Body $patch -ContentType 'application/json' | Out-Null

if ($ObjectKey) {
    Write-Host "Recorded $assetName in release $tag (oss://$Bucket/$ObjectKey)"
} else {
    Write-Host "Recorded $assetName in release $tag (not published to OSS)"
}
