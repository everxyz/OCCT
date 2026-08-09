<#
.SYNOPSIS
    Creates the release for the current tag if absent, then records one artifact's
    Aliyun OSS coordinates in its notes. Uploads no bytes.

.DESCRIPTION
    GitHub does not host the binaries. The bytes of record live in Aliyun OSS as a
    content-addressed blob; a release is the human-facing index over them, carrying
    the bucket, object key, plaintext sha256 and a copy-pasteable retrieval command.

    Why a command and not a link. The bucket is private, has block-public-access on,
    and objects are written with a private ACL, so there is no URL a reader can just
    click. A pre-signed URL would work but expires with the STS session that signed
    it (an hour), which is worse than useless in release notes that outlive it. The
    coordinates never expire, and anyone with read access on the bucket can act on
    them. Making the bucket public is not an option available to this repository: it
    is Utopia's, and it holds Utopia's production assets.

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
    Path to the built artifact. Read for its name and size only; never uploaded.

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
    [string] $Endpoint = ''
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

# The preamble explains, once per release, why there is nothing to click. Kept
# separate from the per-artifact sections so appending never duplicates it.
$preambleMarker = '<!-- everxyz:preamble -->'
$preamble = @(
    $preambleMarker
    '> **Binaries are not hosted on GitHub.** The bytes of record live in Aliyun OSS as'
    '> content-addressed blobs. Each artifact below carries its bucket, object key and'
    '> plaintext `sha256`, plus a command to fetch it.'
    '>'
    '> The bucket is private, so these are coordinates rather than clickable links. You'
    '> need read access on it and either `ossutil` or the `aliyun` CLI configured.'
) -join "`n"

if (-not (Get-ReleaseByTag)) {
    Write-Host "Creating release $tag"
    # everxyz-dev-* tags are pre-releases; everxyz-release-* are full releases.
    $body = @{
        tag_name               = $tag
        name                   = $tag
        prerelease             = $tag.StartsWith('everxyz-dev-')
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
$lines.Add("- size: $sizeMb MB")
$lines.Add("- sha256 (plaintext, before gzip transport encoding): ``$Sha256``")

if ($ObjectKey -and $Bucket) {
    $regionNote = if ($Region) { " (``$Region``)" } else { '' }
    $lines.Add("- bucket: ``$Bucket``$regionNote")
    $lines.Add("- object key: ``$ObjectKey``")
    $lines.Add('')
    $lines.Add('Fetch it:')
    $lines.Add('')
    $lines.Add('```bash')
    # One line, no backslash continuations: this is meant to be copy-pasted, and a
    # wrapped line breaks when pasted into PowerShell.
    $endpointArg = if ($Endpoint) { " --endpoint $Endpoint" } else { '' }
    $lines.Add("ossutil cp oss://$Bucket/$ObjectKey ./$assetName$endpointArg")
    $lines.Add('```')
    $lines.Add('')
    $lines.Add('Stored gzip-encoded, so decode before verifying: the `sha256` above')
    $lines.Add('covers the plaintext archive.')
} else {
    $lines.Add('')
    $lines.Add('> Not yet published to OSS: Aliyun RAM federation is not configured for')
    $lines.Add('> this repository. See `.github/RUNNER-SETUP.md` section 7.')
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
