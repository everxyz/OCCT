<#
.SYNOPSIS
    Creates the release for the current tag if absent, attaches one artifact to it,
    and records that artifact's retrieval paths in the notes.

.DESCRIPTION
    The archive is attached as a release asset, because that is the only retrieval
    path GitHub serves over a plain URL a browser can follow. The alternatives do not
    give you a link:

      - GHCR speaks the OCI token handshake. An anonymous manifest GET is 401 even
        for a public image, so there is no URL to put in the notes; 'docker pull'
        performs the handshake for you, and reading the package with the API needs
        read:packages on the token.
      - The Aliyun OSS bucket is private with block-public-access on and private
        object ACLs, so retrieval needs an Aliyun identity. A pre-signed URL would
        be clickable but expires with the STS session that signed it (an hour, 12
        with MaxSessionDuration raised), which is worse than useless in notes that
        outlive it.

    So the notes carry, per artifact: a download link to the attached asset, the
    GHCR reference for scripted use, and the OSS coordinates once that bucket
    exists. All three describe the same bytes under the same sha256.

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

.PARAMETER ObjectKey
    OSS object key, from the publish-oss step. When empty the artifact is recorded as
    not yet published, so a tag pushed before the Aliyun side is provisioned still
    produces an honest release rather than a pointer to nothing.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string] $Asset,

    [string] $Bucket = '',
    [string] $ObjectKey = '',
    [string] $Sha256 = '',
    [string] $Region = '',
    [string] $Endpoint = '',

    # GHCR reference carrying the same artifact, e.g.
    # ghcr.io/everxyz/occt:8.0.1-windows-x64-release. Recorded as a retrieval path
    # in its own right: while OSS is unprovisioned this is the only one that works,
    # and it is authenticated by the same GitHub identity that grants access to
    # this repository, so anyone who can read the repository can fetch it.
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
$preambleLines.Add('> **The archives are attached below.** Use the download link in an artifact')
$preambleLines.Add('> section, or the Assets list at the foot of this page. This repository is')
$preambleLines.Add('> private, so a browser needs a GitHub session on it: an unauthenticated')
$preambleLines.Add('> request gets 404, not 403.')
$preambleLines.Add('>')
$preambleLines.Add('> Each artifact also names a `ghcr.io` package holding the same bytes, for a')
$preambleLines.Add('> script or a Dockerfile that has no browser session. That path needs')
$preambleLines.Add('> `read:packages` on the token; the attached asset does not.')
$preambleLines.Add('>')
$preambleLines.Add('> Aliyun OSS is the intended store of record. Where an artifact lists a bucket')
$preambleLines.Add('> and object key, that blob is content-addressed and immutable; the bucket is')
$preambleLines.Add('> private, so those are coordinates rather than links and need `ossutil` or the')
$preambleLines.Add('> `aliyun` CLI.')

# LGPL-2.1 section 4 lets an object-code distributor satisfy the source obligation
# by offering equivalent access to the source from the same place. This fork changes
# nothing under src/, so upstream's own tarball for the same tag IS the corresponding
# source, and pointing at it discharges the obligation without publishing anything
# from this private repository. If a patch to src/ ever lands, that stops being true
# and section 2(a) starts to apply: the modified source has to be offered too.
if ($UpstreamTag) {
    $preambleLines.Add('>')
    $preambleLines.Add("> Built from unmodified upstream OCCT ``$UpstreamTag`` as shared libraries, under")
    $preambleLines.Add('> LGPL-2.1 with the Open CASCADE exception. Corresponding source:')
    $preambleLines.Add("> https://github.com/Open-Cascade-SAS/OCCT/archive/refs/tags/$UpstreamTag.tar.gz")
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
$lines.Add("### ``$assetName``")
$lines.Add('')
# The asset is attached above, so its URL is deterministic and needs no lookup:
# /releases/download/<tag>/<name>. This is the only retrieval path that is a plain
# URL a browser can follow -- GHCR needs the OCI token handshake, and the OSS bucket
# needs an Aliyun identity.
$lines.Add("**[Download](https://github.com/$repo/releases/download/$tag/$assetName)** ($sizeMb MB)")
$lines.Add('')
# The gzip caveat applies only to the OSS blob, which is re-encoded in transport.
# The GHCR package carries the archive as-is, so claiming a transport encoding that
# is not there would send a reader looking for a layer to strip.
if ($ObjectKey -and $Bucket) {
    $lines.Add("- sha256 (plaintext, before gzip transport encoding): ``$Sha256``")
} else {
    $lines.Add("- sha256: ``$Sha256``")
}

if ($GhcrReference) {
    $lines.Add("- package: ``$GhcrReference``")
}
if ($ObjectKey -and $Bucket) {
    $regionNote = if ($Region) { " (``$Region``)" } else { '' }
    $lines.Add("- bucket: ``$Bucket``$regionNote")
    $lines.Add("- object key: ``$ObjectKey``")
}

# The package is the scripted path: same bytes, reachable from a Dockerfile or a CI
# step without a browser session, at the cost of needing read:packages on the token.
if ($GhcrReference) {
    $lines.Add('')
    $lines.Add('Or pull the package:')
    $lines.Add('')
    $lines.Add('```bash')
    # One command per line, no backslash continuations: these are meant to be
    # copy-pasted, and a wrapped line breaks when pasted into PowerShell.
    $lines.Add('gh auth token | docker login ghcr.io -u "$(gh api user --jq .login)" --password-stdin')
    $lines.Add("docker create --name occt-fetch $GhcrReference /x > /dev/null")
    $lines.Add("docker cp occt-fetch:/$assetName ./$assetName")
    $lines.Add('docker rm occt-fetch > /dev/null')
    $lines.Add('```')
    $lines.Add('')
    # 'FROM scratch' has no entrypoint, so 'docker create' needs a command argument
    # to accept the image at all. It is never executed -- the container is only ever
    # a filesystem to copy out of -- so '/x' not existing is harmless.
    $lines.Add('The image is `FROM scratch` and holds only the archive plus a')
    $lines.Add('`catalog.json`. The `/x` argument is never run; `docker create` just')
    $lines.Add('requires one.')
}

if ($ObjectKey -and $Bucket) {
    $lines.Add('')
    $lines.Add('Or from Aliyun OSS:')
    $lines.Add('')
    $lines.Add('```bash')
    $endpointArg = if ($Endpoint) { " --endpoint $Endpoint" } else { '' }
    $lines.Add("ossutil cp oss://$Bucket/$ObjectKey ./$assetName$endpointArg")
    $lines.Add('```')
    $lines.Add('')
    $lines.Add('That blob is stored gzip-encoded, so decode it before verifying: the')
    $lines.Add('`sha256` above covers the plaintext archive.')
} else {
    $lines.Add('')
    $lines.Add('> Not published to Aliyun OSS: the bucket and its RAM role are not')
    $lines.Add('> provisioned yet, so this run had nowhere to put the blob. The attached')
    $lines.Add('> asset and the GHCR package above carry the same bytes and the same')
    $lines.Add('> `sha256`.')
}

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
