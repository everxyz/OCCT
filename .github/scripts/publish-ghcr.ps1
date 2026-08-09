<#
.SYNOPSIS
    Publishes one built artifact to GitHub Packages (GHCR) as an OCI image, so the
    release shows up under the repository's Packages tab and indexes the OSS blob.

.DESCRIPTION
    GitHub Packages has no generic file registry. The supported formats are OCI
    (GHCR), npm, NuGet, Maven and RubyGems, so a .tar.gz can only appear there by
    being wrapped. This wraps it in a 'FROM scratch' OCI image, which needs no
    extra tooling: the runner already has a working docker CLI and daemon for the
    Linux build, whereas ORAS would be another unvendored binary to pin.

    Aliyun OSS remains the system of record -- it holds the content-addressed
    blob. The GHCR entry is the discoverable index over it: every OSS coordinate
    (bucket, object key, plaintext digest) is recorded in OCI labels, and
    'org.opencontainers.image.source' is what makes GitHub attach the package to
    this repository instead of leaving it orphaned at the org level.

    One package, many tags: ghcr.io/<owner>/occt:<version>-<platform>-<mode>.

    Storage note. By default the archive is baked into the image, so the package
    is self-contained and 'docker pull' actually yields the binaries. For a
    private repository that consumes the account's Packages storage quota, and a
    Debug pair is heavy (~199 MB Windows + ~265 MB Linux). Set
    OCCT_GHCR_INDEX_ONLY=true to push a few-KB pointer image instead, which keeps
    the package visible and the OSS coordinates discoverable while storing only
    the catalog.

.OUTPUTS
    Writes 'ghcr_ref' to $GITHUB_OUTPUT and prints the pushed reference.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Archive,

    [string] $Platform = '',
    [string] $Mode = '',
    [string] $Version = '',

    # OSS coordinates for the same artifact, recorded as labels. Empty when the
    # OSS leg was skipped; the package is still published, just without them.
    [string] $OssBucket = '',
    [string] $OssObjectKey = '',
    [string] $Sha256 = '',

    # Build and show the image without logging in or pushing. Useful to validate
    # the manifest locally, and the only way to exercise this script with a token
    # that lacks write:packages.
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Test-Path -LiteralPath $Archive)) { throw "artifact not found: $Archive" }
$archiveItem = Get-Item -LiteralPath $Archive

# Normally passed in from the OSS step, which computes it as the content address.
# Recomputed here when that step skipped (RAM federation not provisioned yet), so
# the package always carries a verifiable digest rather than an empty label.
if (-not $Sha256) {
    Write-Host 'no digest passed in; computing sha256'
    $Sha256 = (Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash.ToLowerInvariant()
}

if (-not ($DryRun -or $env:GITHUB_TOKEN)) {
    throw @'
No GITHUB_TOKEN in the environment.
The job needs 'permissions: packages: write' and must pass secrets.GITHUB_TOKEN,
because this repository's default workflow permissions are read-only.
'@
}

# ------------------------------------------------------------- docker CLI ----

# Same escape hatch as the Linux build step: every exe under 'C:\Program Files\
# Docker' had its inherited 'BUILTIN\Users' read+execute entry stripped on this
# host, so the runner account cannot launch the installed CLI. See the comment
# on DOCKER_CLI in everxyz-release.yml.
$docker = $env:DOCKER_CLI
if (-not ($docker -and (Test-Path -LiteralPath $docker))) {
    $onPath = (Get-Command docker -ErrorAction SilentlyContinue)
    if (-not $onPath) {
        throw 'No docker CLI found (DOCKER_CLI unset or missing, none on PATH).'
    }
    $docker = $onPath.Source
}
Write-Host "docker CLI: $docker"

& $docker version --format 'daemon {{.Server.Version}}' | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Cannot reach the Docker daemon on $($env:DOCKER_HOST). Is Docker Desktop running?"
}

# ------------------------------------------------------------------- refs ----

# OCI references are lowercase-only; the repository is 'everxyz/OCCT'.
$repository = $env:GITHUB_REPOSITORY.ToLowerInvariant()
$owner = $repository.Split('/')[0]
$image = "ghcr.io/$owner/occt"

# Tags are [A-Za-z0-9_][A-Za-z0-9._-]{0,127}. Versions like '0.0.1-rc1' and
# 'manual-<sha8>' already comply, but a hand-pushed tag might not.
$tagParts = @($Version, $Platform, $Mode) | Where-Object { $_ }
# Lowercased to match the release asset filenames, which build the same triple
# with $env:MODE.ToLower(). OCI tags do permit uppercase, so this is consistency
# rather than validity: 'occt-0.0.1-linux-amd64-release.tar.gz' should not sit
# beside a ':0.0.1-linux-amd64-Release' tag.
$tag = (($tagParts -join '-') -replace '[^A-Za-z0-9._-]', '-').ToLowerInvariant()
if (-not $tag) { $tag = 'latest' }
if ($tag.Length -gt 128) { $tag = $tag.Substring(0, 128) }
$reference = "${image}:${tag}"

$indexOnly = $env:OCCT_GHCR_INDEX_ONLY -in @('true', '1', 'yes')

Write-Host ''
Write-Host "package    $image"
Write-Host "tag        $tag"
Write-Host "artifact   $($archiveItem.Name) ($([math]::Round($archiveItem.Length / 1MB, 1)) MB)"
Write-Host "contents   $(if ($indexOnly) { 'catalog only (OCCT_GHCR_INDEX_ONLY)' } else { 'catalog + archive' })"
Write-Host ''

# ---------------------------------------------------------------- staging ----

# Inside the workspace, not %TEMP%: the build context is sent to the daemon, and
# staging on the workspace volume lets the archive be hardlinked instead of
# copied. The workspace is on F: and %TEMP% is on C:, so a cross-volume hardlink
# would fail.
$staging = Join-Path (Get-Location).Path "ghcr-staging-$([guid]::NewGuid().ToString('n').Substring(0, 8))"
New-Item -ItemType Directory -Path $staging | Out-Null

try {
    # The catalog is the machine-readable OSS pointer. It ships inside the image
    # as well as in the labels, so a consumer that has pulled the image can
    # resolve the blob without calling the GitHub API.
    $catalog = [ordered]@{
        schema_version    = 'everxyz-occt-artifact-catalog.v1'
        artifact          = $archiveItem.Name
        version           = $Version
        platform          = $Platform
        mode              = $Mode
        sha256            = $Sha256
        size_bytes        = $archiveItem.Length
        transport_encoding = 'gzip'
        oss               = [ordered]@{
            provider   = 'aliyun-oss'
            bucket     = $OssBucket
            object_key = $OssObjectKey
        }
        source = [ordered]@{
            repository = $env:GITHUB_REPOSITORY
            revision   = $env:GITHUB_SHA
            ref        = $env:GITHUB_REF_NAME
            run_id     = $env:GITHUB_RUN_ID
        }
        created = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    $catalogPath = Join-Path $staging 'catalog.json'
    ($catalog | ConvertTo-Json -Depth 6) |
        Set-Content -LiteralPath $catalogPath -Encoding UTF8

    $dockerfileLines = [System.Collections.Generic.List[string]]::new()
    $dockerfileLines.Add('# Generated by .github/scripts/publish-ghcr.ps1. Not checked in.')
    $dockerfileLines.Add('FROM scratch')
    $dockerfileLines.Add('COPY catalog.json /catalog.json')

    if (-not $indexOnly) {
        $staged = Join-Path $staging $archiveItem.Name
        try {
            New-Item -ItemType HardLink -Path $staged -Target $archiveItem.FullName -ErrorAction Stop | Out-Null
        } catch {
            # Different volume, or a filesystem without hardlinks.
            Copy-Item -LiteralPath $archiveItem.FullName -Destination $staged
        }
        $dockerfileLines.Add("COPY $($archiveItem.Name) /$($archiveItem.Name)")
    }

    # OCI annotation keys. 'source' is the one GitHub reads to attach the package
    # to this repository; the com.everxyz.* keys carry the OSS coordinates.
    $labels = [ordered]@{
        'org.opencontainers.image.source'      = "https://github.com/$($env:GITHUB_REPOSITORY)"
        'org.opencontainers.image.revision'    = "$($env:GITHUB_SHA)"
        'org.opencontainers.image.version'     = $Version
        'org.opencontainers.image.created'     = $catalog.created
        'org.opencontainers.image.title'       = "everxyz OCCT $Platform $Mode"
        'org.opencontainers.image.description' = "OCCT $Version build for $Platform ($Mode). Bytes of record live in Aliyun OSS; see the com.everxyz.occt.oss.* labels."
        'org.opencontainers.image.licenses'    = 'LGPL-2.1-only'
        'com.everxyz.occt.platform'            = $Platform
        'com.everxyz.occt.mode'                = $Mode
        'com.everxyz.occt.artifact'            = $archiveItem.Name
        'com.everxyz.occt.sha256'              = $Sha256
        'com.everxyz.occt.oss.provider'        = 'aliyun-oss'
        'com.everxyz.occt.oss.bucket'          = $OssBucket
        'com.everxyz.occt.oss.object-key'      = $OssObjectKey
        'com.everxyz.occt.contents'            = if ($indexOnly) { 'catalog' } else { 'catalog+archive' }
    }
    foreach ($key in $labels.Keys) {
        $value = $labels[$key]
        if ($null -eq $value) { $value = '' }
        # Escape backslashes and quotes so a Windows path or a quoted string in a
        # description cannot terminate the LABEL value early.
        $escaped = $value.ToString().Replace('\', '\\').Replace('"', '\"')
        $dockerfileLines.Add("LABEL `"$key`"=`"$escaped`"")
    }

    # LF endings: the daemon parses the Dockerfile on Linux.
    [System.IO.File]::WriteAllText(
        (Join-Path $staging 'Dockerfile'),
        ($dockerfileLines -join "`n") + "`n",
        (New-Object System.Text.UTF8Encoding($false)))

    # ------------------------------------------------------------- login ----

    # --password-stdin so the token never reaches argv, where it would be visible
    # to any process list on this shared, non-ephemeral runner.
    if (-not $DryRun) {
        Write-Host "logging in to ghcr.io as $($env:GITHUB_ACTOR)"

        # NOT '$env:GITHUB_TOKEN | & $docker login --password-stdin'. Piping a
        # string to a native executable in Windows PowerShell 5.1 encodes it with
        # $OutputEncoding, which prepends a UTF-8 BOM and appends CRLF: docker
        # then reads "\xef\xbb\xbf<token>\r\n" as the password and ghcr.io answers
        # 'denied: denied'. Verified by piping to a byte-dumping process.
        #
        # So the token is written to the child's stdin as exact bytes. Still not
        # argv: this runner is shared and non-ephemeral, and a token there would
        # be readable from any local process list.
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $docker
        # A single Arguments string, not ArgumentList: the latter only exists on
        # .NET Core, and this is Windows PowerShell 5.1 on .NET Framework 4.x.
        # GITHUB_ACTOR is a GitHub login (no spaces or quotes), but it is the one
        # interpolated value here, so it is quoted rather than trusted.
        $actor = ($env:GITHUB_ACTOR -replace '"', '')
        $startInfo.Arguments = "login ghcr.io --username `"$actor`" --password-stdin"
        $startInfo.RedirectStandardInput = $true
        $startInfo.UseShellExecute = $false

        $loginProcess = [System.Diagnostics.Process]::Start($startInfo)
        try {
            $stdin = $loginProcess.StandardInput
            # No BOM, no trailing newline: docker trims, but the BOM is the bug.
            $bytes = [System.Text.Encoding]::ASCII.GetBytes($env:GITHUB_TOKEN)
            $stdin.BaseStream.Write($bytes, 0, $bytes.Length)
            $stdin.BaseStream.Flush()
            $stdin.Close()
            $loginProcess.WaitForExit()
            if ($loginProcess.ExitCode -ne 0) {
                throw "docker login ghcr.io failed ($($loginProcess.ExitCode))"
            }
        } finally {
            $loginProcess.Dispose()
        }
    }

    try {
        # --platform linux/amd64 is not a claim about the artifact: this is a
        # carrier image, and a Linux daemon cannot build a windows/amd64 scratch
        # image. The artifact's real platform is in the tag and in the
        # com.everxyz.occt.platform label.
        # --provenance=false because Docker Desktop's buildx default would add a
        # provenance attestation, turning a single manifest into a manifest list
        # with an extra attestation manifest. Harmless but noise for a carrier
        # image, and it makes the Packages entry show a phantom second platform.
        Write-Host "building $reference"
        & $docker @('build', '--platform', 'linux/amd64', '--provenance=false',
                    '-t', $reference, $staging)
        if ($LASTEXITCODE -ne 0) { throw "docker build failed ($LASTEXITCODE)" }

        if ($DryRun) {
            Write-Host ''
            Write-Host 'dry run: built locally, not pushed. Labels on the image:'
            # 'json .Config.Labels' rather than a range template: a Go template
            # containing {{"\n"}} reaches docker with the backslash mangled by
            # PowerShell's native-argument handling and fails to parse.
            & $docker @('inspect', '--format', '{{json .Config.Labels}}', $reference)
            $size = (& $docker @('inspect', '--format', '{{.Size}}', $reference) | Out-String).Trim()
            Write-Host "image size: $([math]::Round([int64]$size / 1MB, 2)) MB"
            Write-Output $reference
            return
        }

        Write-Host "pushing $reference"
        & $docker @('push', $reference)
        if ($LASTEXITCODE -ne 0) { throw "docker push failed ($LASTEXITCODE)" }

        $digest = (& $docker @('inspect', '--format', '{{index .RepoDigests 0}}', $reference) 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $digest) { $digest = '(digest unavailable)' }

        Write-Host ''
        Write-Host "published $reference"
        Write-Host "digest    $digest"

        if ($env:GITHUB_OUTPUT) {
            "ghcr_ref=$reference" | Add-Content -LiteralPath $env:GITHUB_OUTPUT
        }
        if ($env:GITHUB_STEP_SUMMARY) {
            @(
                "### GitHub Packages: $tag"
                ''
                "- package: ``$image``"
                "- reference: ``$reference``"
                "- digest: ``$digest``"
                "- contents: $(if ($indexOnly) { 'catalog.json only' } else { "catalog.json + $($archiveItem.Name)" })"
                "- pull: ``docker pull $reference``"
            ) | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY
        }

        Write-Output $reference
    } finally {
        # Drop the local tag so the non-ephemeral runner does not accumulate a
        # 265 MB image per build. The registry copy is what matters.
        & $docker @('image', 'rm', '-f', $reference) 2>&1 | Out-Null
        # And drop the stored credential, which docker login writes to the
        # runner account's config.json.
        & $docker @('logout', 'ghcr.io') 2>&1 | Out-Null
    }
} finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}
