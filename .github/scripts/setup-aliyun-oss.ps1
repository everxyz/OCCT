<#
.SYNOPSIS
    Provisions the Aliyun side of the OCCT artifact publication: bucket, OIDC
    provider, RAM role and policy, plus the two GitHub repository variables.

.DESCRIPTION
    Run this ONCE, interactively, from your own account -- not from CI. It creates
    resources in your Aliyun account, which is why the build jobs cannot do it:
    they only ever hold a short-lived credential scoped to PutObject on one prefix.

    Idempotent. Every step checks for the resource first, so a re-run after a
    partial failure reports 'exists' and moves on rather than erroring.

    What it creates:

      1. RAM OIDC provider trusting GitHub's issuer   (fingerprint-pinned)
      2. RAM policy: oss:GetObject + oss:PutObject on blobs/gzip/sha256/* only
      3. RAM role with a trust policy scoped to THIS repository
      4. Repository variables OCCT_OSS_ROLE_ARN / OCCT_OSS_OIDC_PROVIDER_ARN

    What it does NOT create: the bucket. Artifacts land in Utopia's tracked SDK
    supply bucket, which already exists and holds Utopia's production assets.
    This script verifies it and reports any divergence from the tracked
    bucket_contract, but applies nothing -- reconfiguring a bucket this
    repository does not own would be a cloud mutation outside its remit.

    Because the bucket is shared, the RAM role is deliberately NOT shared: this
    repository gets its own, never Utopia's UtopiaSdkSupplyPublish. See
    .github/oss-artifacts.json for the full reasoning.

    Authentication: 'aliyun configure --mode OAuth' (browser login), the same
    human path Utopia uses. No static AccessKey is created or stored.

.PARAMETER SubjectPatterns
    Which GitHub refs may assume the role, matched against the OIDC token's 'sub'
    claim. Defaults to tags only, because that is what publishes. This is the
    security boundary: 'oidc:aud' alone would let ANY GitHub repository assume the
    role, so 'sub' must be constrained to this one.

.PARAMETER WhatIf
    Print the plan, touch nothing.

.EXAMPLE
    .\setup-aliyun-oss.ps1 -WhatIf

.EXAMPLE
    # tags plus manual runs from master
    .\setup-aliyun-oss.ps1 -SubjectPatterns @(
        'repo:everxyz/OCCT:ref:refs/tags/*',
        'repo:everxyz/OCCT:ref:refs/heads/master')
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $Repository = 'everxyz/OCCT',

    # Defaults come from .github/oss-artifacts.json when omitted.
    [string] $Bucket,
    [string] $Region,

    [string] $OidcProviderName = 'github-actions',
    [string] $RoleName = 'OcctArtifactsPublish',
    [string] $PolicyName = 'OcctArtifactsPublish',

    [string[]] $SubjectPatterns = @('repo:everxyz/OCCT:ref:refs/tags/*'),

    # Skip writing the two GitHub repository variables.
    [switch] $SkipGitHubVariables
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Step { param([string] $m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok   { param([string] $m) Write-Host "    OK: $m" -ForegroundColor Green }
function Write-Skip { param([string] $m) Write-Host "    exists: $m" -ForegroundColor DarkGray }
function Write-Warn { param([string] $m) Write-Host "    warning: $m" -ForegroundColor Yellow }

function Get-Prop {
    # Absent-property reads throw under Set-StrictMode -Version Latest.
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if (-not $p) { return $null }
    return $p.Value
}

# ------------------------------------------------------------------ tools ----

Write-Step 'Locating tools'

function Resolve-Tool {
    param([string] $Name, [string[]] $Candidates)
    $onPath = (Get-Command $Name -ErrorAction SilentlyContinue)
    if ($onPath) { return $onPath.Source }
    foreach ($c in $Candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    return $null
}

$aliyun = Resolve-Tool -Name 'aliyun' -Candidates @(
    "$env:USERPROFILE\scoop\shims\aliyun.exe",
    'C:\Program Files\aliyun-cli\aliyun.exe')
if (-not $aliyun) {
    throw 'aliyun CLI not found. Install it: https://www.alibabacloud.com/help/en/cli'
}
Write-Ok "aliyun: $aliyun"

$gh = $null
if (-not $SkipGitHubVariables) {
    $gh = Resolve-Tool -Name 'gh' -Candidates @('C:\Program Files\GitHub CLI\gh.exe')
    if (-not $gh) {
        Write-Warn 'gh CLI not found; will print the variables to set by hand'
    } else {
        Write-Ok "gh: $gh"
    }
}

# --------------------------------------------------------------- contract ----

$contractPath = Join-Path (Split-Path -Parent $PSCommandPath) '..\oss-artifacts.json'
$contract = Get-Content -LiteralPath $contractPath -Raw | ConvertFrom-Json

if (-not $Bucket) { $Bucket = $contract.bucket.name }
if (-not $Region) { $Region = $contract.region }
$keyPrefix  = $contract.object_key_prefix
$issuerUrl  = $contract.credentials.oidc_issuer
$audience   = $contract.credentials.audience
$storage    = $contract.bucket_contract.storage_class
$redundancy = $contract.bucket_contract.redundancy_type

# --------------------------------------------------------------- identity ----

Write-Step 'Aliyun identity'

function Invoke-Aliyun {
    # Returns the parsed JSON plus the raw text, and never throws: callers decide
    # whether a non-zero exit is a failure or an expected "does not exist".
    param([string[]] $Arguments)

    # Every call carries --region: the CLI refuses with "region can't be empty"
    # even for global endpoints like sts and ims when no profile supplies one.
    $withRegion = $Arguments
    if ($Arguments -notcontains '--region') { $withRegion = $Arguments + @('--region', $Region) }

    # Invoked through .NET rather than the call operator. Two PowerShell hazards
    # are avoided at once:
    #   * '2>&1 |' wraps each stderr line in a NativeCommandError record, which
    #     terminates under 'Stop' before the exit code can be read and prints a
    #     stack trace over the CLI's own message under 'Continue'.
    #   * '2>$file' is itself a cmdlet-like operation, so -WhatIf suppresses the
    #     redirect and stderr escapes to the console.
    # The aliyun CLI writes diagnostics to stderr as a matter of course, so this
    # is the normal path and has to be read as data, not as an exception.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $aliyun
    $psi.Arguments = ($withRegion | ForEach-Object {
        # Quote anything containing whitespace; JSON policy documents do not, but
        # descriptions do.
        if ($_ -match '\s') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join ' '
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::Start($psi)
    $out = $process.StandardOutput.ReadToEnd()
    $err = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    $code = $process.ExitCode
    $process.Dispose()
    $raw = ($out + $err)

    # Strip ANSI colour codes so 'Raw' can be pattern-matched reliably.
    $clean = [regex]::Replace($raw, "$([char]27)\[[0-9;]*m", '')

    $json = $null
    if ($clean.Trim().StartsWith('{')) {
        try { $json = $clean | ConvertFrom-Json } catch { $json = $null }
    }
    return [pscustomobject]@{ ExitCode = $code; Raw = $clean; Json = $json }
}

$identity = Invoke-Aliyun @('sts', 'GetCallerIdentity')
if ($identity.ExitCode -ne 0) {
    Write-Host $identity.Raw
    throw @'
Not authenticated to Aliyun. Log in with a browser first:

    aliyun configure --mode OAuth --profile occt-setup

This is the same human OAuth path Utopia uses; it stores no static AccessKey.
'@
}

$accountId = Get-Prop $identity.Json 'AccountId'
$identityArn = Get-Prop $identity.Json 'Arn'
if (-not $accountId) { Write-Host $identity.Raw; throw 'Could not determine the Aliyun account id' }
Write-Ok "account $accountId ($identityArn)"

$providerArn = "acs:ram::${accountId}:oidc-provider/$OidcProviderName"
$roleArn     = "acs:ram::${accountId}:role/$($RoleName.ToLowerInvariant())"

# ------------------------------------------------------------ fingerprint ----

Write-Step 'GitHub issuer certificate fingerprint'

# Alibaba pins the issuer's CA fingerprint to stop issuer-URL hijacking. Computed
# from the live chain rather than hardcoded, so this keeps working when Let's
# Encrypt rotates GitHub's intermediate. The ROOT is used: it is the longest-lived
# link, so pinning it survives leaf and intermediate rotation.
$issuerHost = ([uri]$issuerUrl).Host
$fingerprints = @()

$opensslExe = Resolve-Tool -Name 'openssl' -Candidates @(
    'C:\Program Files\Git\mingw64\bin\openssl.exe',
    'C:\Program Files\Git\usr\bin\openssl.exe')
if (-not $opensslExe) {
    Write-Warn 'openssl not found; falling back to .NET chain building'
}

try {
    if ($opensslExe) {
        # openssl writes 'Connecting to <ip>' and the whole session trace to
        # stderr, so it is captured via .NET instead of the call operator: with
        # '2>$null' the redirect is suppressed by -WhatIf, and with '2>&1' each
        # trace line becomes a NativeCommandError that aborts the enclosing try.
        $opensslPsi = New-Object System.Diagnostics.ProcessStartInfo
        $opensslPsi.FileName = $opensslExe
        $opensslPsi.Arguments = "s_client -servername $issuerHost -connect ${issuerHost}:443 -showcerts"
        $opensslPsi.RedirectStandardInput = $true
        $opensslPsi.RedirectStandardOutput = $true
        $opensslPsi.RedirectStandardError = $true
        $opensslPsi.UseShellExecute = $false
        $opensslPsi.CreateNoWindow = $true

        $opensslProcess = [System.Diagnostics.Process]::Start($opensslPsi)
        # s_client waits for input before closing the connection.
        $opensslProcess.StandardInput.Close()
        $chainText = $opensslProcess.StandardOutput.ReadToEnd()
        $null = $opensslProcess.StandardError.ReadToEnd()
        $opensslProcess.WaitForExit()
        $opensslProcess.Dispose()
        $pemMatches = [regex]::Matches($chainText,
            '(?s)-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----')
        if ($pemMatches.Count -gt 0) {
            # Last cert in the chain is the root (or highest intermediate offered).
            $tempPem = Join-Path ([System.IO.Path]::GetTempPath()) "occt-issuer-$PID.pem"
            [System.IO.File]::WriteAllText($tempPem, $pemMatches[$pemMatches.Count - 1].Value)
            # Same stderr reasoning as s_client above.
            function Invoke-Openssl {
                param([string] $ArgumentString)
                $p = New-Object System.Diagnostics.ProcessStartInfo
                $p.FileName = $opensslExe
                $p.Arguments = $ArgumentString
                $p.RedirectStandardOutput = $true
                $p.RedirectStandardError = $true
                $p.UseShellExecute = $false
                $p.CreateNoWindow = $true
                $proc = [System.Diagnostics.Process]::Start($p)
                $stdout = $proc.StandardOutput.ReadToEnd()
                $null = $proc.StandardError.ReadToEnd()
                $proc.WaitForExit()
                $proc.Dispose()
                return $stdout
            }

            try {
                $fpLine = Invoke-Openssl "x509 -in `"$tempPem`" -noout -fingerprint -sha1"
                $subject = (Invoke-Openssl "x509 -in `"$tempPem`" -noout -subject").Trim()
                if ($fpLine -match '=\s*([0-9A-Fa-f:]+)') {
                    $fp = $Matches[1].Replace(':', '').ToLowerInvariant()
                    $fingerprints += $fp
                    Write-Ok "root CA fingerprint $fp"
                    Write-Host "        $subject" -ForegroundColor DarkGray
                }
            } finally { Remove-Item $tempPem -Force -ErrorAction SilentlyContinue }
        }
    }
} catch {
    Write-Warn "fingerprint computation failed: $($_.Exception.Message)"
}

if (-not $fingerprints) {
    throw @"
Could not compute the CA fingerprint for $issuerHost.
Get it from the Aliyun console instead (RAM > OIDC IdP > Get Fingerprint), then
create the provider by hand and re-run with -OidcProviderName pointing at it.
"@
}

# ------------------------------------------------------------------ plan -----

Write-Step 'Plan'
Write-Host "  bucket          $Bucket ($Region, $storage, $redundancy, private)"
Write-Host "  key prefix      $keyPrefix/"
Write-Host "  OIDC provider   $OidcProviderName"
Write-Host "                  issuer $issuerUrl"
Write-Host "                  audience $audience"
Write-Host "  RAM policy      $PolicyName  (oss:GetObject + oss:PutObject, no delete)"
Write-Host "  RAM role        $RoleName"
Write-Host "  trusted subs:"
foreach ($s in $SubjectPatterns) { Write-Host "                  $s" }
Write-Host "  role ARN        $roleArn"
Write-Host "  provider ARN    $providerArn"

if ($WhatIfPreference) {
    Write-Host "`n-WhatIf: nothing was created." -ForegroundColor Yellow
    return
}

# ---------------------------------------------------------------- bucket -----

Write-Step "OSS bucket $Bucket"

# Verified, never created. This bucket is Utopia's tracked SDK supply bucket and
# holds its production assets; creating or reconfiguring a bucket this repository
# does not own would be a cloud mutation outside its remit. If it is missing,
# that is a question for the Utopia side, not something to paper over here.
$bucketProbe = Invoke-Aliyun @('oss', 'stat', "oss://$Bucket")
if ($bucketProbe.ExitCode -eq 0) {
    Write-Ok "$Bucket exists"

    # Report the live properties against the tracked contract. Divergence is
    # surfaced, not corrected.
    foreach ($check in @(
        @{ Label = 'ACL';         Pattern = 'ACL\s*:\s*(\S+)';                     Expected = $contract.bucket_contract.acl },
        @{ Label = 'StorageClass'; Pattern = 'StorageClass\s*:\s*(\S+)';           Expected = $storage },
        @{ Label = 'Redundancy';  Pattern = 'RedundancyType\s*:\s*(\S+)';          Expected = $redundancy })) {
        if ($bucketProbe.Raw -match $check.Pattern) {
            $actual = $Matches[1]
            if ($actual -eq $check.Expected) {
                Write-Host "        $($check.Label) = $actual" -ForegroundColor DarkGray
            } else {
                Write-Warn "$($check.Label) is '$actual', contract expects '$($check.Expected)'"
            }
        }
    }
} else {
    Write-Host $bucketProbe.Raw

    # Two failures look identical at the exit-code level and mean very different
    # things, so read the error OSS actually returned instead of guessing.
    #
    #   404 NoSuchBucket -- genuinely absent; a question for the Utopia side.
    #   403 AccessDenied -- it EXISTS and this identity lacks permission on it.
    #
    # Note the wording trap in the 403 case: OSS says "The bucket you access does
    # not belong to you" (Ec 0003-00000001) for a RAM user with no rights on a
    # bucket in its OWN account. It reads like an ownership statement and is not
    # one. Do not infer a different account from it -- that sends you looking in
    # the wrong place. Ownership can only be settled by an identity that can read
    # the bucket or its RAM configuration.
    if ($bucketProbe.Raw -match 'NoSuchBucket') {
        throw @"
Bucket $Bucket does not exist.

It is declared by the Utopia repository (third_party/engineering-assets.json,
buckets.sdk) but has not been provisioned. This script does not create it: it is
Utopia's bucket, and creating it here would take ownership of something this
repository does not own. That is a question for the Utopia side.
"@
    } else {
        throw @"
Bucket $Bucket is not readable by this identity.

Identity: $identityArn
  (account $accountId)

If OSS said "does not belong to you" above, read that as a permission failure,
not as evidence the bucket is in another account -- OSS returns that wording for
a RAM user with no rights on a bucket in its own account.

A bare RAM user is not how this bucket is meant to be reached. Utopia's own
publishers assume a RAM role (infra/engineering-assets/ram-policies.json:
UtopiaSdkSupplyPublish, reached through the UtopiaEngineeringAssetAssume policy)
and the role carries the OSS rights. So either:

  1. Attach an assume policy to this identity and run under the assumed role, or
  2. Have a privileged identity in the account grant this one oss:GetBucketInfo
     on $Bucket, or
  3. Run this script as an identity that already has those rights.

Provisioning the OIDC provider and role below additionally needs ram:* rights,
which a bare sub-user does not have. The raw OSS error is printed above.
"@
    }
}

# --------------------------------------------------------- OIDC provider -----

Write-Step "RAM OIDC provider $OidcProviderName"

$provider = Invoke-Aliyun @('ims', 'GetOIDCProvider', '--OIDCProviderName', $OidcProviderName)
if ($provider.ExitCode -eq 0) {
    Write-Skip $OidcProviderName
    Write-Host '        (verify its issuer and client IDs match the plan above)' -ForegroundColor DarkGray
} else {
    if ($PSCmdlet.ShouldProcess($OidcProviderName, 'create RAM OIDC provider')) {
        $create = Invoke-Aliyun @(
            'ims', 'CreateOIDCProvider',
            '--OIDCProviderName', $OidcProviderName,
            '--IssuerUrl', $issuerUrl,
            '--ClientIds', $audience,
            '--Fingerprints', ($fingerprints -join ','),
            '--Description', "GitHub Actions OIDC for $Repository")
        if ($create.ExitCode -ne 0) {
            Write-Host $create.Raw
            throw "failed to create OIDC provider $OidcProviderName"
        }
        Write-Ok "created $OidcProviderName"
    }
}

# --------------------------------------------------------------- policy ------

Write-Step "RAM policy $PolicyName"

# Exactly Utopia's fixtures_publish shape: read + write on the content-addressed
# prefix, nothing else. No delete action anywhere, so a compromised CI job cannot
# destroy published artifacts -- only add new immutable ones.
#
# Worth being precise about the residual access, since this bucket is Utopia's and
# holds its production assets. The Resource line is scoped to the bucket and the
# blobs/gzip/sha256/* prefix, but Utopia publishes its own blobs under that same
# content-addressed prefix. So this role can read any object there, and can create
# new ones. What it cannot do:
#   - delete or overwrite anything: no oss:DeleteObject, and the publish path
#     passes --forbid-overwrite, so a PutObject onto an occupied key fails
#   - touch anything outside the prefix (bucket config, other prefixes, the
#     fixtures bucket, any other Aliyun service)
#   - be assumed by anything but this repository's tagged builds (trust policy)
# Read-across is inherent to sharing a content-addressed prefix and is the price
# of the tracked contract's "reuse the tracked bucket" rule. Narrowing it further
# would need a per-repository prefix, which that contract does not provide.
$policyDocument = [ordered]@{
    Version   = '1'
    Statement = @(
        [ordered]@{
            Effect   = 'Allow'
            Action   = @('oss:GetObject', 'oss:PutObject')
            Resource = @("acs:oss:*:*:$Bucket/$keyPrefix/*")
        }
    )
} | ConvertTo-Json -Depth 6 -Compress

$policyProbe = Invoke-Aliyun @(
    'ram', 'GetPolicy', '--PolicyName', $PolicyName, '--PolicyType', 'Custom')
if ($policyProbe.ExitCode -eq 0) {
    Write-Skip $PolicyName
} else {
    if ($PSCmdlet.ShouldProcess($PolicyName, 'create RAM policy')) {
        $create = Invoke-Aliyun @(
            'ram', 'CreatePolicy',
            '--PolicyName', $PolicyName,
            '--PolicyDocument', $policyDocument,
            '--Description', "Publish OCCT artifacts to $Bucket/$keyPrefix/")
        if ($create.ExitCode -ne 0) {
            Write-Host $create.Raw
            throw "failed to create policy $PolicyName"
        }
        Write-Ok "created $PolicyName"
    }
}

# ----------------------------------------------------------------- role ------

Write-Step "RAM role $RoleName"

# The security boundary. 'oidc:iss' and 'oidc:aud' must use StringEquals (Aliyun
# rejects other operators for those two); 'oidc:sub' accepts StringLike, which is
# what allows a wildcard over refs. Without the sub condition ANY GitHub
# repository could assume this role -- the audience is a shared constant.
$trustPolicy = [ordered]@{
    Version   = '1'
    Statement = @(
        [ordered]@{
            Effect    = 'Allow'
            Action    = 'sts:AssumeRole'
            Principal = [ordered]@{ Federated = @($providerArn) }
            Condition = [ordered]@{
                StringEquals = [ordered]@{
                    'oidc:iss' = @($issuerUrl)
                    'oidc:aud' = @($audience)
                }
                StringLike = [ordered]@{
                    'oidc:sub' = @($SubjectPatterns)
                }
            }
        }
    )
} | ConvertTo-Json -Depth 8 -Compress

$roleProbe = Invoke-Aliyun @('ram', 'GetRole', '--RoleName', $RoleName)
if ($roleProbe.ExitCode -eq 0) {
    Write-Skip $RoleName
    Write-Host '        trust policy left as-is; delete the role to change it' -ForegroundColor DarkGray
} else {
    if ($PSCmdlet.ShouldProcess($RoleName, 'create RAM role')) {
        $create = Invoke-Aliyun @(
            'ram', 'CreateRole',
            '--RoleName', $RoleName,
            '--AssumeRolePolicyDocument', $trustPolicy,
            '--MaxSessionDuration', '3600',
            '--Description', "GitHub Actions publisher for $Repository")
        if ($create.ExitCode -ne 0) {
            Write-Host $create.Raw
            throw "failed to create role $RoleName"
        }
        Write-Ok "created $RoleName"
    }
}

if ($PSCmdlet.ShouldProcess("$PolicyName -> $RoleName", 'attach policy to role')) {
    $attach = Invoke-Aliyun @(
        'ram', 'AttachPolicyToRole',
        '--PolicyName', $PolicyName,
        '--PolicyType', 'Custom',
        '--RoleName', $RoleName)
    if ($attach.ExitCode -ne 0) {
        # EntityAlreadyExists on a re-run is success.
        if ($attach.Raw -match 'AlreadyAttach|EntityAlreadyExists') {
            Write-Skip 'policy already attached'
        } else {
            Write-Host $attach.Raw
            throw 'failed to attach the policy to the role'
        }
    } else {
        Write-Ok "attached $PolicyName to $RoleName"
    }
}

# ------------------------------------------------- GitHub repo variables -----

Write-Step 'GitHub repository variables'

if ($SkipGitHubVariables -or -not $gh) {
    Write-Host '  Set these by hand (Settings > Secrets and variables > Actions > Variables):'
    Write-Host "    OCCT_OSS_ROLE_ARN           $roleArn"
    Write-Host "    OCCT_OSS_OIDC_PROVIDER_ARN  $providerArn"
} else {
    foreach ($pair in @(
        @{ Name = 'OCCT_OSS_ROLE_ARN';          Value = $roleArn },
        @{ Name = 'OCCT_OSS_OIDC_PROVIDER_ARN'; Value = $providerArn })) {
        if ($PSCmdlet.ShouldProcess($pair.Name, 'set GitHub repository variable')) {
            # 'gh variable set' both creates and updates, so no existence probe.
            & $gh variable set $pair.Name --repo $Repository --body $pair.Value 2>&1 |
                ForEach-Object { Write-Host "        $_" -ForegroundColor DarkGray }
            if ($LASTEXITCODE -ne 0) {
                Write-Warn "could not set $($pair.Name); set it by hand to: $($pair.Value)"
            } else {
                Write-Ok "$($pair.Name) = $($pair.Value)"
            }
        }
    }
}

# -------------------------------------------------------------- verdict ------

Write-Host "`n--- Done ---" -ForegroundColor Cyan
Write-Host @"
Verify with a publishing run that does not need a tag:

    gh workflow run everxyz-release.yml --repo $Repository \
       -f build_mode=Release -f targets=windows-x64 -f publish=true

If the trusted subjects are tags-only (the default), that manual run comes from a
branch and STS will refuse it with 'NotAuthorized'. Either push a tag, or re-run
this script adding the branch pattern:

    -SubjectPatterns @('repo:$Repository`:ref:refs/tags/*','repo:$Repository`:ref:refs/heads/master')

Nothing here stores a static AccessKey. The role can only PutObject under
$keyPrefix/ in $Bucket, and has no delete permission at all.
"@ -ForegroundColor Gray
