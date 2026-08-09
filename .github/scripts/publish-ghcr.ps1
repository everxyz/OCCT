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

# Self-contained by default: 'docker pull' yields the binaries. GHCR is currently
# the only retrieval path that works -- the OSS bucket and its RAM role are not
# provisioned yet, so publish-oss.ps1 skips and there is nothing to point at. An
# index-only image would then reference a blob that does not exist.
#
# This does mean GitHub stores the bytes, which is the thing the release notes
# deliberately stopped doing by attaching release assets. The distinction that
# makes it acceptable: a GHCR package is authenticated by the same GitHub identity
# that grants access to this private repository, so the audience is unchanged, and
# it can be deleted without rewriting release history. Cost is the account's
# Packages quota (a Debug pair is ~199 MB Windows + ~265 MB Linux).
#
# Set OCCT_GHCR_INDEX_ONLY=true once OSS publication works, to go back to a
# pointer-only carrier image.
$indexOnly = $false
if ($env:OCCT_GHCR_INDEX_ONLY) {
    $indexOnly = $env:OCCT_GHCR_INDEX_ONLY -notin @('false', '0', 'no')
}

Write-Host ''
Write-Host "package    $image"
Write-Host "tag        $tag"
Write-Host "artifact   $($archiveItem.Name) ($([math]::Round($archiveItem.Length / 1MB, 1)) MB)"
Write-Host "contents   $(if ($indexOnly) { 'catalog only, a pointer at the OSS blob (OCCT_GHCR_INDEX_ONLY=true)' } else { 'catalog + archive' })"
Write-Host ''

# ---------------------------------------------------------------- staging ----

# Inside the workspace, not %TEMP%: the build context is sent to the daemon, and
# staging on the workspace volume lets the archive be hardlinked instead of
# copied. The workspace is on F: and %TEMP% is on C:, so a cross-volume hardlink
# would fail.
$staging = Join-Path (Get-Location).Path "ghcr-staging-$([guid]::NewGuid().ToString('n').Substring(0, 8))"
New-Item -ItemType Directory -Path $staging | Out-Null

# Declared before the try so the matching finally can always read it. Under
# Set-StrictMode -Version Latest, referencing an unassigned variable throws, which
# would mask the real error if the script failed before the login block.
$dockerConfigDir = $null

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

    # No 'docker login' at all. The auth entry is written straight into a private
    # DOCKER_CONFIG, which is the only thing a successful login would have done.
    #
    # Two failed approaches are worth recording, because both look correct:
    #
    #   1. '$env:GITHUB_TOKEN | & $docker login --password-stdin'. Piping a string
    #      to a native executable in Windows PowerShell 5.1 encodes it with
    #      $OutputEncoding, prepending a UTF-8 BOM and appending CRLF. docker reads
    #      "\xef\xbb\xbf<token>\r\n" as the password and ghcr.io answers
    #      'denied: denied'.
    #
    #   2. ProcessStartInfo with RedirectStandardInput, writing the exact token
    #      bytes to BaseStream. This fixes the encoding -- a byte-dumping child
    #      confirms it receives the 40 token bytes and nothing else -- and ghcr.io
    #      STILL answers 'denied: denied'. The same token through a real shell pipe
    #      succeeds on the same daemon in the same second, so it is not the token,
    #      not the scopes and not the registry. docker's --password-stdin does not
    #      accept a .NET redirected pipe as its password source and falls back to an
    #      empty password.
    #
    # Routing it through 'cmd /c type <file> | docker login' does work, but that
    # means a plaintext token in a file under %TEMP%, whose inherited ACLs on this
    # host grant several non-owner SIDs Modify. Writing the config directly avoids
    # the token touching argv, a shared-ACL file, or the interactive user's
    # ~/.docker/config.json -- which matters because that config has
    # 'credsStore: desktop', a helper bound to the interactive session that a
    # service account cannot reach.
    #
    # Verified against the live registry: 'docker manifest inspect' on an absent tag
    # returns 'manifest unknown' rather than 'denied', i.e. authentication passed.
    if (-not $DryRun) {
        Write-Host "authenticating to ghcr.io as $($env:GITHUB_ACTOR)"

        # In the workspace, not %TEMP%: same volume as the build context, and the
        # ACL below is set explicitly rather than inherited either way.
        $dockerConfigDir = Join-Path (Get-Location).Path `
            ("docker-cfg-" + [guid]::NewGuid().ToString('n').Substring(0, 8))
        New-Item -ItemType Directory -Path $dockerConfigDir | Out-Null

        # Owner-only, inheritance disabled and NOT copied, so the parent's ACEs do
        # not carry over. The file holds a bearer credential for the whole job.
        $acl = New-Object System.Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true, $false)
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            [System.Security.Principal.WindowsIdentity]::GetCurrent().User,
            'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        (Get-Item -LiteralPath $dockerConfigDir).SetAccessControl($acl)

        # Registry basic auth: base64("<user>:<token>"). GITHUB_ACTOR is a GitHub
        # login so it cannot contain a colon, but ghcr.io ignores the username for
        # token auth regardless.
        $actor = ($env:GITHUB_ACTOR -replace ':', '')
        $basic = [System.Convert]::ToBase64String(
            [System.Text.Encoding]::ASCII.GetBytes("${actor}:$($env:GITHUB_TOKEN)"))
        $dockerConfig = @{ auths = @{ 'ghcr.io' = @{ auth = $basic } } } |
            ConvertTo-Json -Depth 5
        [System.IO.File]::WriteAllText(
            (Join-Path $dockerConfigDir 'config.json'), $dockerConfig,
            (New-Object System.Text.UTF8Encoding($false)))

        # Scoped to the child docker processes below; cleared in the finally.
        $env:DOCKER_CONFIG = $dockerConfigDir
    }

    # --provenance is a BuildKit flag, and BuildKit may not be reachable here. buildx
    # lives at 'C:\Program Files\Docker\cli-plugins\docker-buildx.exe', which on this
    # host has the same stripped ACL as docker.exe itself: no 'BUILTIN\Users' entry,
    # so the runner account gets "Access is denied" trying to exec it. The CLI then
    # falls back to the legacy builder, which rejects '--provenance' as an unknown
    # flag and fails the build.
    #
    # The flag is only needed when BuildKit is in use, because only BuildKit adds the
    # provenance attestation it suppresses. The legacy builder never does, so
    # omitting it there changes nothing about the resulting manifest.
    #
    # Ask 'docker build' what IT accepts, not whether the buildx plugin exists. Those
    # differ: with DOCKER_BUILDKIT=0 the plugin is installed and 'buildx version'
    # succeeds, yet 'build' still routes to the legacy builder and rejects the flag.
    # --help lists '--provenance' exactly when the flag is accepted.
    #
    # Deliberately not vendoring buildx next to docker.exe the way DOCKER_CLI does:
    # it is a 67 MB binary and this carrier image needs nothing BuildKit offers.
    # Not '2>&1 | Out-String': the legacy builder prints a deprecation notice to
    # stderr, and merging a native program's stderr into the pipeline under
    # $ErrorActionPreference = 'Stop' raises a terminating NativeCommandError. So the
    # probe for the legacy builder would itself fail on the legacy builder. Capturing
    # stderr separately keeps it out of the pipeline.
    $helpOut = [System.IO.Path]::GetTempFileName()
    $helpErr = [System.IO.Path]::GetTempFileName()
    try {
        Start-Process -FilePath $docker -ArgumentList @('build', '--help') `
            -NoNewWindow -Wait -RedirectStandardOutput $helpOut -RedirectStandardError $helpErr
        $buildHelp = (Get-Content -LiteralPath $helpOut -Raw -ErrorAction SilentlyContinue)
    } finally {
        Remove-Item -LiteralPath $helpOut, $helpErr -Force -ErrorAction SilentlyContinue
    }
    $haveProvenance = ($buildHelp -match '--provenance')
    Write-Host "builder    $(if ($haveProvenance) { 'BuildKit' } else { 'legacy' })"

    try {
        # --platform linux/amd64 is not a claim about the artifact: this is a
        # carrier image, and a Linux daemon cannot build a windows/amd64 scratch
        # image. The artifact's real platform is in the tag and in the
        # com.everxyz.occt.platform label.
        $buildArgs = @('build', '--platform', 'linux/amd64')
        if ($haveProvenance) {
            # Without this, buildx turns a single manifest into a manifest list with
            # an extra attestation manifest. Harmless, but it makes the Packages
            # entry show a phantom second platform.
            $buildArgs += '--provenance=false'
        }
        $buildArgs += @('-t', $reference, $staging)

        Write-Host "building $reference"
        & $docker @buildArgs
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
        #
        # '2>&1 | Out-Null' is not enough on its own: when the build itself failed
        # there is no image to remove, and docker's stderr becomes a PowerShell
        # NativeCommandError whose noise buries the actual build error above it.
        # Suppressing it here keeps the real failure legible.
        try {
            & $docker @('image', 'rm', '-f', $reference) 2>&1 | Out-Null
        } catch { }
    }
} finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    # No 'docker logout': the credential never entered the runner account's
    # ~/.docker/config.json, only the private directory below. Deleting it is the
    # logout, and it must happen even if the build threw -- this runner is not
    # ephemeral, so a leftover config.json would outlive the job.
    if ($dockerConfigDir) {
        $env:DOCKER_CONFIG = $null
        Remove-Item -LiteralPath $dockerConfigDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
