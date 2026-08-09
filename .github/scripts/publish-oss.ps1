<#
.SYNOPSIS
    Publishes one built artifact to Aliyun OSS as an immutable content-addressed
    blob, following Utopia's engineering-asset publication contract.

.DESCRIPTION
    Port of the publishAssets() path in Utopia's scripts/engineering-assets.mjs,
    reduced to the single-asset case a build job needs. The contract it implements
    is in .github/oss-artifacts.json; the properties that matter here are:

      * object key is 'blobs/gzip/sha256/<sha256-of-plaintext>' -- content
        addressed, so republishing an identical artifact is a no-op and a digest
        is enough to locate a blob.
      * the blob is gzip-encoded in transport, recorded as metadata
        'transport-encoding=gzip'; the 'sha256' metadata covers the PLAINTEXT.
      * uploads use --forbid-overwrite. Objects are immutable. A digest that is
        already present is verified, never replaced.
      * the publish role carries oss:GetObject and oss:PutObject only. There is
        no delete action anywhere in this path.

    Credentials come from GitHub OIDC federated into RAM via
    sts:AssumeRoleWithOIDC -- the closest analogue to Utopia's ACK RRSA path, and
    for the same reason: the workload proves its identity with a short-lived
    token and receives short-lived credentials. No static AccessKey exists in
    this repository. The STS triple is passed to ossutil through the environment
    only (OSS_ACCESS_KEY_ID / OSS_ACCESS_KEY_SECRET / OSS_SESSION_TOKEN, all
    three verified to be read by ossutil 2.3.0), never in argv and never written
    to a config file, so it cannot leak through a process list, a log, or a file
    left behind on a non-ephemeral runner.

    When the RAM side has not been provisioned yet (no role ARN configured), the
    script reports what is missing and exits 0. A half-configured deployment
    should not turn a good build red.

.OUTPUTS
    Writes 'oss_object_key' and 'oss_sha256' to $GITHUB_OUTPUT when running under
    Actions, and prints the object key as the only stdout line.
#>
[CmdletBinding()]
param(
    # The built artifact to publish, e.g. occt-0.0.1-linux-amd64-release.tar.gz.
    [Parameter(Mandatory = $true)]
    [string] $Archive,

    # Recorded in the run summary and the GHCR catalog, not in the object key:
    # the key is content-addressed and must stay a pure function of the bytes.
    [string] $Platform = '',
    [string] $Mode = '',
    [string] $Version = '',

    # 'regional' (default) or 'internal'. Internal is the in-VPC endpoint and is
    # unreachable from this runner; it exists so an ECS-hosted runner can switch
    # without a code change, exactly like Utopia's endpointFlags(network).
    [ValidateSet('regional', 'internal')]
    [string] $Network = 'regional'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# PowerShell 5.1 negotiates SSLv3/TLS 1.0 by default; both endpoints refuse it.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Get-Prop {
    # Reads a property that may be absent. Under Set-StrictMode -Version Latest a
    # plain $obj.missing throws PropertyNotFoundException, which would turn every
    # unexpected API response into a misleading error.
    param($Object, [string] $Name)

    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if (-not $property) { return $null }
    return $property.Value
}

function Get-WebProxyArgs {
    # .NET on Windows PowerShell takes its proxy from WinINET rather than from the
    # http_proxy/https_proxy variables the runner sets in its .env, so pass them on.
    $proxy = if ($env:https_proxy) { $env:https_proxy } else { $env:http_proxy }
    if ($proxy) { return @{ Proxy = $proxy } }
    return @{}
}

# ---------------------------------------------------------------- contract ----

$scriptDir = Split-Path -Parent $PSCommandPath
$contractPath = Join-Path $scriptDir '..\oss-artifacts.json'
if (-not (Test-Path -LiteralPath $contractPath)) {
    throw "publication contract not found at $contractPath"
}
$contract = Get-Content -LiteralPath $contractPath -Raw | ConvertFrom-Json

# Repository variables win over the checked-in contract so the bucket, region or
# role can be repointed without a commit.
$bucket   = if ($env:OCCT_OSS_BUCKET) { $env:OCCT_OSS_BUCKET } else { $contract.bucket.name }
$region   = if ($env:OCCT_OSS_REGION) { $env:OCCT_OSS_REGION } else { $contract.region }
$endpoint = if ($env:OCCT_OSS_ENDPOINT) {
    $env:OCCT_OSS_ENDPOINT
} elseif ($Network -eq 'internal') {
    $contract.internal_endpoint
} else {
    $contract.regional_endpoint
}
$stsEndpoint = if ($env:OCCT_OSS_STS_ENDPOINT) { $env:OCCT_OSS_STS_ENDPOINT } else { $contract.sts_endpoint }
$keyPrefix   = $contract.object_key_prefix

if ($contract.transport_encoding -ne 'gzip') {
    throw "unsupported transport encoding '$($contract.transport_encoding)'"
}

$roleArn     = $env:OCCT_OSS_ROLE_ARN
$providerArn = $env:OCCT_OSS_OIDC_PROVIDER_ARN

if (-not ($roleArn -and $providerArn)) {
    # Not an error: the Aliyun side is provisioned by hand, and this lets the
    # publish step ship before the RAM role exists.
    Write-Host '::notice::Skipping OSS publication: Aliyun RAM federation is not configured.'
    Write-Host ''
    Write-Host 'To enable it, set these repository variables (Settings > Secrets and variables > Actions > Variables):'
    Write-Host '  OCCT_OSS_ROLE_ARN           acs:ram::<account-id>:role/occtartifactspublish'
    Write-Host '  OCCT_OSS_OIDC_PROVIDER_ARN  acs:ram::<account-id>:oidc-provider/github-actions'
    Write-Host ''
    Write-Host 'Both are ARNs, not secrets. See .github/RUNNER-SETUP.md for the RAM setup.'
    exit 0
}

if (-not (Test-Path -LiteralPath $Archive)) { throw "artifact not found: $Archive" }
$archiveItem = Get-Item -LiteralPath $Archive

# ------------------------------------------------------------ OIDC -> STS ----

# Actions only injects these two when the job requests 'id-token: write'.
if (-not ($env:ACTIONS_ID_TOKEN_REQUEST_URL -and $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN)) {
    throw @'
No GitHub OIDC token endpoint in the environment.
The job needs 'permissions: id-token: write' for federated Aliyun access.
'@
}

$audience = $contract.credentials.audience
Write-Host "requesting GitHub OIDC token (audience: $audience)"

# Splatted from a variable: '@(Get-WebProxyArgs)' would be an array literal in
# argument position, i.e. a stray positional argument, not a splat.
$proxyArgs = Get-WebProxyArgs

$tokenUri = "$($env:ACTIONS_ID_TOKEN_REQUEST_URL)&audience=$([uri]::EscapeDataString($audience))"
$oidcResponse = Invoke-RestMethod -Uri $tokenUri -UseBasicParsing @proxyArgs `
    -Headers @{ Authorization = "Bearer $($env:ACTIONS_ID_TOKEN_REQUEST_TOKEN)" }
$oidcToken = Get-Prop $oidcResponse 'value'
if (-not $oidcToken) { throw 'GitHub returned no OIDC token value' }

# RoleSessionName is constrained to [a-zA-Z0-9.@-_]{2,64}; the repository name
# contains a '/', so it has to be sanitised rather than passed through.
$sessionName = "occt-$($env:GITHUB_RUN_ID)" -replace '[^a-zA-Z0-9.@\-_]', '-'
if ($sessionName.Length -gt 64) { $sessionName = $sessionName.Substring(0, 64) }

Write-Host "assuming $roleArn via sts:AssumeRoleWithOIDC"

# AssumeRoleWithOIDC is an unsigned STS action: the OIDC token IS the proof of
# identity, which is exactly why this needs no static AccessKey to bootstrap.
# Sent as a POST form because the JWT is far too long for a query string.
$stsBody = @{
    Action           = 'AssumeRoleWithOIDC'
    Format           = 'JSON'
    Version          = '2015-04-01'
    Timestamp        = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    RoleArn          = $roleArn
    OIDCProviderArn  = $providerArn
    OIDCToken        = $oidcToken
    RoleSessionName  = $sessionName
    DurationSeconds  = "$($contract.credentials.session_duration_seconds)"
}

try {
    $sts = Invoke-RestMethod -Uri $stsEndpoint -Method Post -Body $stsBody `
        -UseBasicParsing @proxyArgs
} catch {
    # The STS error body names the actual cause (trust policy mismatch, wrong
    # audience, unknown provider). Surface it: the status line alone is useless.
    $detail = ''
    $response = Get-Prop $_.Exception 'Response'
    if ($response) {
        try {
            $reader = New-Object System.IO.StreamReader($response.GetResponseStream())
            $detail = $reader.ReadToEnd()
            $reader.Close()
        } catch { }
    }
    if ($detail) { Write-Host "::error::STS rejected the assume-role request: $detail" }
    throw "sts:AssumeRoleWithOIDC failed: $($_.Exception.Message)"
}

$credentials = Get-Prop $sts 'Credentials'
$accessKeyId = Get-Prop $credentials 'AccessKeyId'
$accessKeySecret = Get-Prop $credentials 'AccessKeySecret'
$securityToken = Get-Prop $credentials 'SecurityToken'
if (-not ($accessKeyId -and $accessKeySecret -and $securityToken)) {
    throw 'STS response did not contain a complete credential triple'
}
Write-Host "got STS credentials, expiring $(Get-Prop $credentials 'Expiration')"

# --------------------------------------------------------------- ossutil ----

$ossutil = & (Join-Path $scriptDir 'install-ossutil.ps1') | Select-Object -Last 1
if (-not ($ossutil -and (Test-Path -LiteralPath $ossutil))) {
    throw "install-ossutil.ps1 did not produce a usable binary (got: $ossutil)"
}

$digest = (Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash.ToLowerInvariant()
$objectKey = "$keyPrefix/$digest"
$sizeMb = [math]::Round($archiveItem.Length / 1MB, 1)

Write-Host ''
Write-Host "artifact   $($archiveItem.Name) ($sizeMb MB)"
Write-Host "sha256     $digest"
Write-Host "bucket     $bucket ($region)"
Write-Host "object     $objectKey"
Write-Host ''

# Common flags. No --profile and no --ignore-env-var: unlike Utopia, which reads
# a profile out of ~/.ossutilconfig, credentials here arrive through the
# environment, and --ignore-env-var would discard exactly those variables.
$commonArgs = @('--endpoint', $endpoint, '--region', $region, '--mode', 'StsToken')

function Invoke-Ossutil {
    param([string[]] $Arguments)

    # Set for this process so the child inherits them; cleared in finally below.
    $env:OSS_ACCESS_KEY_ID = $accessKeyId
    $env:OSS_ACCESS_KEY_SECRET = $accessKeySecret
    $env:OSS_SESSION_TOKEN = $securityToken

    $output = & $ossutil @Arguments 2>&1 | Out-String
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}

$temporary = Join-Path ([System.IO.Path]::GetTempPath()) "occt-oss-$([guid]::NewGuid().ToString('n'))"
New-Item -ItemType Directory -Path $temporary | Out-Null

try {
    # ---- preflight: is this digest already published? --------------------
    $head = Invoke-Ossutil (@('api', 'head-object', '--bucket', $bucket, '--key', $objectKey) + $commonArgs)

    $alreadyPresent = $head.ExitCode -eq 0
    if (-not $alreadyPresent) {
        # 404/NoSuchKey is the expected miss. Anything else -- 403 from a wrong
        # role, a nonexistent bucket, a network failure -- must not be mistaken
        # for "absent", or the upload below would report a misleading error.
        if ($head.Output -notmatch 'NoSuchKey|404') {
            Write-Host $head.Output
            throw "OSS preflight failed for $objectKey (exit $($head.ExitCode))"
        }
    }

    if ($alreadyPresent) {
        # Content-addressed, so identical bytes are already there by definition.
        # Verify the recorded digest anyway: it is the one cheap check that
        # catches a key written by something that did not honour the contract.
        if ($head.Output -match 'sha256[^0-9a-f]{0,4}([0-9a-f]{64})') {
            $remoteDigest = $Matches[1].ToLowerInvariant()
            if ($remoteDigest -ne $digest) {
                throw "object $objectKey records sha256 $remoteDigest, expected $digest"
            }
            Write-Host 'already published; remote sha256 metadata matches'
        } else {
            Write-Host '::warning::already published, but no sha256 metadata found on the object'
        }
    } else {
        # ---- encode then upload ------------------------------------------
        # gzip even though the artifact is already a .tar.gz. The transport
        # encoding is part of the contract and the key prefix asserts it
        # ('blobs/gzip/sha256'), so a reader can decode without probing. The
        # second pass costs a few seconds and ~0.1% size.
        $encoded = Join-Path $temporary 'blob.gz'
        Write-Host 'gzip-encoding for transport'
        # Not named $input: that is a PowerShell automatic variable (the pipeline
        # enumerator), and assigning it inside a script is a trap waiting to fire.
        $plainStream = [System.IO.File]::OpenRead($Archive)
        try {
            $gzStream = [System.IO.File]::Create($encoded)
            try {
                $gzip = New-Object System.IO.Compression.GZipStream(
                    $gzStream, [System.IO.Compression.CompressionMode]::Compress)
                try { $plainStream.CopyTo($gzip) } finally { $gzip.Dispose() }
            } finally { $gzStream.Dispose() }
        } finally { $plainStream.Dispose() }

        $encodedMb = [math]::Round((Get-Item -LiteralPath $encoded).Length / 1MB, 1)
        Write-Host "encoded $sizeMb MB -> $encodedMb MB, uploading"

        # --forbid-overwrite is the immutability guarantee. --body takes a file
        # URL. The digest and the transport encoding go on as user metadata so a
        # consumer can verify without trusting the key.
        $put = Invoke-Ossutil (@(
            'api', 'put-object',
            '--bucket', $bucket,
            '--key', $objectKey,
            '--body', ([uri]([System.IO.Path]::GetFullPath($encoded))).AbsoluteUri,
            '--forbid-overwrite',
            '--metadata', "sha256=$digest",
            '--metadata', "transport-encoding=$($contract.transport_encoding)",
            '--object-acl', $contract.bucket_contract.acl,
            '--storage-class', $contract.bucket_contract.storage_class
        ) + $commonArgs)

        if ($put.ExitCode -ne 0) {
            # FileAlreadyExists means a concurrent job published the same digest
            # first. Both uploaded identical bytes, so this is success.
            if ($put.Output -match 'FileAlreadyExists|409') {
                Write-Host 'a concurrent publication won the race; treating as published'
            } else {
                Write-Host $put.Output
                throw "OSS publication failed for $objectKey (exit $($put.ExitCode))"
            }
        } else {
            Write-Host "published $objectKey"
        }
    }

    # ---- report ----------------------------------------------------------
    if ($env:GITHUB_OUTPUT) {
        # oss_bucket is emitted so the GHCR step can label the coordinates without
        # re-resolving the contract and the OCCT_OSS_* overrides for itself.
        # region and endpoint are emitted for the release notes, whose retrieval
        # command needs them: the bucket is private, so a reader has to authenticate
        # against a named region rather than fetch a public URL.
        @(
            "oss_bucket=$bucket"
            "oss_object_key=$objectKey"
            "oss_sha256=$digest"
            "oss_region=$region"
            "oss_endpoint=$endpoint"
        ) | Add-Content -LiteralPath $env:GITHUB_OUTPUT
    }
    if ($env:GITHUB_STEP_SUMMARY) {
        @(
            "### OSS: $($archiveItem.Name)"
            ''
            "- bucket: ``$bucket`` (``$region``)"
            "- object: ``$objectKey``"
            "- sha256 (plaintext): ``$digest``"
            "- size: $sizeMb MB, gzip transport encoding"
            "- platform/mode: $Platform / $Mode"
        ) | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY
    }

    Write-Output $objectKey
} finally {
    # Do not leave credentials in the environment of a non-ephemeral runner.
    Remove-Item Env:OSS_ACCESS_KEY_ID -ErrorAction SilentlyContinue
    Remove-Item Env:OSS_ACCESS_KEY_SECRET -ErrorAction SilentlyContinue
    Remove-Item Env:OSS_SESSION_TOKEN -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
}
