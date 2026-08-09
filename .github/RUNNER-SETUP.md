# Self-hosted runner setup (everxyz-win)

The `everxyz Build` workflow targets a runner labelled `everxyz-win`. These are the
steps to turn this Windows machine into that runner.

## Before you start: the security tradeoff

GitHub warns against self-hosted runners on **public** repositories: anyone can fork the
repo, point a workflow at `runs-on: self-hosted`, and open a pull request that executes
their code on this machine. Unlike GitHub-hosted runners, this box is not destroyed
after each job.

`everxyz/OCCT` is **private**, which removes that entire class of risk at its source —
a repository nobody outside the org can fork cannot receive a fork pull request. (The
fork-PR approval API now returns `422 Fork PR approval is not allowed for private
repositories` for exactly this reason.) If this repo is ever made public again, revisit
this section first: the defences below stop being redundant and become the only line.

Defence in depth, still in place:

- `everxyz-release.yml` triggers only on `push` of a tag and on `workflow_dispatch`.
  Neither can be triggered by a pull request.
- Every upstream OCCT job carries `if: github.repository == 'Open-Cascade-SAS/OCCT'`,
  so none of them run here.
- The label is `everxyz-win`, not the generic `self-hosted`.
- `default_workflow_permissions` is `read` and `can_approve_pull_request_reviews` is
  `false`, so a workflow that declares no `permissions:` block gets a read-only token.
  The two workflows that need to write declare `contents: write` explicitly.
- The runner runs as `ghrunner`, which has no access to `sxd`'s SSH keys, `gh`
  credentials or `.gitconfig`, and no write access to `D:\everxyz-CQ` (so it cannot
  plant a git hook that would later run as you).

What remains, and is inherent to a non-ephemeral self-hosted runner:

- Docker's TCP endpoint on `127.0.0.1:2375` is unauthenticated and grants
  root-equivalent control to any local process (see section 5).
- Build trees and Docker layers persist between jobs; one job can read what a previous
  one left behind.

## 1. Create a dedicated local account

Do not run the service as your daily user. The runner would inherit access to
everything on `D:\` including credentials.

Run as Administrator in PowerShell:

```powershell
$pw = Read-Host -AsSecureString "Password for the runner account"
New-LocalUser -Name "ghrunner" -Password $pw -PasswordNeverExpires -AccountNeverExpires
Add-LocalGroupMember -Group "Users" -Member "ghrunner"
```

Give it a work directory it owns, outside your project tree. The **work tree** lives on
`F:` because it has the most free space (663 GB of 1.3 TB) and a full OCCT build plus
install tree for two targets reaches tens of gigabytes.

> **This machine's actual layout.** The runner as installed here lives in
> `C:\actions-runner`, not `F:\actions-runner`, while its work folder *is*
> `F:\ghrunner-work` (see `workFolder` in `C:\actions-runner\.runner`). The paths below
> use `C:\actions-runner` to match reality. `install-runner.ps1` still defaults to
> `F:\actions-runner`; pass `-RunnerDir` if you want to reproduce this layout exactly.
> Only the work folder needs the space — the runner binaries are about 300 MB.

```powershell
New-Item -ItemType Directory -Force -Path C:\actions-runner, F:\ghrunner-work
icacls C:\actions-runner /grant "ghrunner:(OI)(CI)F" /T
icacls F:\ghrunner-work  /grant "ghrunner:(OI)(CI)F" /T
```

Granting `ghrunner` access is not sufficient — you must also **remove** the broad
grants both drive roots hand down. `C:\actions-runner\.credentials_rsaparams` is the
RSA key the runner authenticates to GitHub with: anyone who can copy it can impersonate
this runner, collect jobs and read their secrets. Both `C:\` and `D:\` pass down
`Authenticated Users: Modify` here, which left that key readable by *every* local
account, `Guest` included (verified by reading it from an unprivileged session):

```powershell
icacls C:\actions-runner /inheritance:d
icacls C:\actions-runner /remove:g "NT AUTHORITY\Authenticated Users" /remove:g "BUILTIN\Users" /T /C
```

Two details that cost time here. `/inheritance:d` *copies* the inherited entries into
explicit ones before detaching, so the removal has to come afterwards or it appears to
do nothing. And removal must name the account: the `/remove:g "*S-1-5-11"` SID form is
accepted, reports `Successfully processed 0 files`, and silently changes nothing.

Confirm afterwards that only `ghrunner`, SYSTEM and Administrators remain:

```powershell
(Get-Acl C:\actions-runner).Access | Format-Table IdentityReference, FileSystemRights
```

`install-runner.ps1` performs all of this, including the verification.

Docker access is needed for the Linux amd64 job. Group membership alone is not enough
here — see [section 5](#5-docker-for-the-linux-amd64-job) for the two separate reasons
`ghrunner` cannot use the installed Docker CLI, and what the job does instead:

```powershell
Add-LocalGroupMember -Group "docker-users" -Member "ghrunner"
```

## 2. Download the runner

```powershell
cd C:\actions-runner
$v = "2.336.0"
Invoke-WebRequest -Uri "https://github.com/actions/runner/releases/download/v$v/actions-runner-win-x64-$v.zip" -OutFile runner.zip
if ((Get-FileHash runner.zip -Algorithm SHA256).Hash.ToLower() -ne "d59123a43003e357b0805b5d0f611d0bd2f65ab67d51bd070dd4e7a0f685c162") { throw "SHA256 mismatch" }
Expand-Archive -Path runner.zip -DestinationPath . -Force
Remove-Item runner.zip
```

## 3. Register it

Get a registration token from **Settings → Actions → Runners → New self-hosted
runner** (it is valid for one hour). Then:

```powershell
cd C:\actions-runner
.\config.cmd --url https://github.com/everxyz/OCCT --token <REGISTRATION_TOKEN> --name everxyz-win-01 --labels everxyz-win --work F:\ghrunner-work --runasservice --windowslogonaccount ".\ghrunner" --windowslogonpassword "<PASSWORD>" --unattended
```

The `--labels everxyz-win` value is what the workflow matches on. The service is
named `actions.runner.everxyz-OCCT.everxyz-win-01`.

```powershell
Get-Service actions.runner.* | Format-Table Name, Status
```

## 4. Install build tools

The workflow calls `cmake` and `git` directly and does not install toolchains, so
they must be on the runner account's PATH.

Visual Studio 2022 Professional is already present. Confirm the C++ workload and
CMake are installed:

```powershell
& "C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
```

If that prints nothing, add "Desktop development with C++" via the Visual Studio
Installer.

CMake was not on PATH when this was written. Install it machine-wide so the service
account sees it:

```powershell
winget install --id Kitware.CMake --scope machine --accept-package-agreements
```

Restart the runner service after any PATH change, otherwise it keeps the old
environment:

```powershell
Restart-Service actions.runner.everxyz-OCCT.everxyz-win-01
```

### What the build actually contains

The artifact is a **headless CAD kernel**, not a full OCCT install: STEP/IGES
import, BRep construction and mesh generation, with no visualization. 27 toolkits
instead of the ~150 a default build produces.

Rather than switch modules on and let each drag in everything beside it, every
`BUILD_MODULE_*` is off and the capability toolkits are named explicitly:

```
-D BUILD_ADDITIONAL_TOOLKITS="TKDESTEP;TKDEIGES;TKXCAF;TKMesh;TKFillet;TKOffset"
```

CMake then resolves the dependency closure, and the closure decides the rest. The
first four match the set Utopia locks for its own OCCT build
(`third_party/sdk-supply/occt-source-lock.json`). `TKFillet` and `TKOffset` are
added because `BRepFilletAPI` and `BRepOffsetAPI` — fillet, chamfer, sweep, loft,
thick solid — are part of BRep construction and are not reachable from the
reader/mesh set alone.

`TKOpenGl` is not in the closure, so `CAN_USE_OPENGL` goes false and the GL and
GLES backends drop out on their own. `USE_OPENGL=OFF` is still passed to state the
intent rather than rely on that inference. On Linux `USE_XLIB=OFF` is also needed:
unlike Windows it defaults to ON.

Two toolkits look out of place and belong there. `TKV3d` and `TKService` are
link-level dependencies of `TKXCAF`, which carries STEP assembly structure, colours
and names. Neither contains GL code and neither needs a display.

One consequence for the Linux container: it installs only `build-essential` and
`cmake`. No `libx11-dev`, `libgl1-mesa-dev`, `tcl-dev` or `tk-dev` — nothing in the
closure links against them, which also cuts container setup time.

## 5. Docker for the Linux amd64 job

The Linux build runs in an `ubuntu:22.04` container. The host is x86_64 and the
target is amd64, so this is a native build with no emulation involved.

### Why the named pipe does not work

Docker Desktop talks over the named pipe `dockerDesktopLinuxEngine`, which is created
by its GUI process and belongs to **that user's session**. A runner running as
`ghrunner` is in a different session and cannot open it, even though `ghrunner` is a
member of `docker-users` — that group only governs the legacy `docker_engine` pipe.
Signing in as `ghrunner` and starting a second Docker Desktop does not help either,
since both instances would fight over the same WSL2 backend.

Switching the job to WSL runs into the same wall for a different reason: WSL distros
are registered per-user under `HKCU`, and `Ubuntu-22.04` belongs to `sxd` with its
files under `C:\Users\sxd\AppData\Local\...`, which `ghrunner` cannot read.

### What the workflow uses instead

The TCP endpoint, which is not tied to a session. The job sets
`DOCKER_HOST=tcp://localhost:2375`, so Docker Desktop needs:

**Settings → General → "Expose daemon on tcp://localhost:2375 without TLS"** — enabled.

Be aware of the tradeoff: 2375 is plaintext and unauthenticated. It binds only to
`127.0.0.1` and `[::1]` (verified, with no inbound firewall rule opening it), so it is
not reachable from the network — but any local process can use it to control Docker,
which is equivalent to root on this machine.

Docker Desktop also has to be **running** when a build starts. `AutoStart` is enabled
(equivalent to "Start Docker Desktop when you sign in"), so it returns after a reboot —
but only once **`sxd` signs in**, because that setting lives in that user's profile and
the GUI runs in their session. A reboot that sits at the login screen leaves the daemon
down and Linux builds failing, so sign in before tagging a release. The job fails with
an explicit message if the daemon is unreachable rather than emitting a confusing
`docker run` error.

### Why the job does not use the CLI on PATH

Reaching the daemon is only half of it — the runner also has to be able to *launch*
the client. On this host every executable under
`C:\Program Files\Docker\Docker\resources\bin` (10 files) and `...\cli-plugins`
(15 files) has had its inherited `BUILTIN\Users` read+execute entry stripped and its
owner reset to `sxd`. `ghrunner` is only in `Users`, so it has no rights at all on
those files and `docker.exe` fails to start with `Access is denied` before any
connection is attempted. The ACLs also list a `CodexSandboxUsers` group, so some
sandboxing tool rewrote them; Docker's installer does not produce this.

The job therefore runs a copy the runner account can execute, via `DOCKER_CLI`:

```
F:\actions-runner\tools\docker.exe
```

The Docker CLI is a self-contained Go binary with no external DLL dependencies, so a
plain file copy behaves identically — it is only a REST client for the daemon, which
still does all the work. What matters is that `ghrunner` can execute the copy; the
directory it sits in must grant that account read+execute. If `DOCKER_CLI` is missing
the job falls back to whatever `docker` is on PATH, so this stays correct on a host
whose Docker ACLs are intact.

Note this path is `F:\actions-runner\tools`, which is *not* the runner install
directory (`C:\actions-runner`) — it is a separate directory that exists only to hold
this copy, so the ACL hardening in section 1 does not apply to it.

Recreate the copy after a Docker Desktop upgrade, to keep client and daemon in step:

```powershell
Copy-Item "C:\Program Files\Docker\Docker\resources\bin\docker.exe" `
          "F:\actions-runner\tools\docker.exe" -Force
```

The alternative is restoring the stripped ACLs (`icacls "C:\Program Files\Docker" /reset /T`
from an elevated prompt). That needs admin rights, edits a shared system location,
and gets undone by whatever rewrote them, so the copy is the lower-risk option.

Verify the endpoint:

```powershell
$env:DOCKER_HOST = "tcp://localhost:2375"
F:\actions-runner\tools\docker.exe run --rm --platform linux/amd64 ubuntu:22.04 uname -m
```

Expected output: `x86_64`.

## 6. Test it

Trigger a manual run first, limited to one target, before pushing a real tag:

**Actions → everxyz Build → Run workflow**, mode `Release`, targets `windows-x64`.

Then a real tag:

```bash
git tag everxyz-release-1.0.0 && git push origin everxyz-release-1.0.0
```

Debug builds use the `everxyz-debug-` prefix and are published as pre-releases:

```bash
git tag everxyz-debug-1.0.0 && git push origin everxyz-debug-1.0.0
```

## Build performance

Both targets build natively on this host — no emulation, since host and target are
both x86_64.

The host has 14 cores / 20 threads and 31.7 GB of RAM.

The Windows job uses `--parallel` and gets all 20 threads. The Linux job passes
`-j$(nproc)`, but it runs inside Docker Desktop's WSL2 VM, which is capped by
`C:\Users\sxd\.wslconfig`:

```ini
[wsl2]
processors=12
memory=16GB
```

So the Linux build sees 12 threads, leaving 8 for the Windows side and interactive use.
Changing these values affects **all** WSL distros and Docker Desktop, not just this
build, and only takes effect after the VM is restarted:

```powershell
wsl --shutdown
```

Memory was deliberately left at 16 GB. Twelve parallel `g++` processes on a Debug build
are memory-hungry, so if the Linux job starts dying with OOM kills or `cc1plus: out of
memory`, raise `memory` before lowering `processors` — but the host only has 31.7 GB
total and Docker's VM is not the only thing using it.

Confirm what the container actually sees:

```powershell
F:\actions-runner\tools\docker.exe run --rm --platform linux/amd64 ubuntu:22.04 nproc
```

The two jobs are independent, but a single runner takes one job at a time, so they
queue rather than overlap. Measured on a Debug tag, back when the
Linux side still had 8 threads: Windows 11 min, Linux 23 min, about 34 min wall clock
for the pair. Release builds are quicker. Registering a second runner on this machine
would let them overlap, but both would then compete for the same cores.

## Maintenance

```powershell
# status
Get-Service actions.runner.*

# stop accepting jobs
Stop-Service actions.runner.everxyz-OCCT.everxyz-win-01

# deregister (get a removal token from the same settings page)
cd C:\actions-runner; .\config.cmd remove --token <REMOVAL_TOKEN>
```

### Disk use

The runner is not ephemeral and nothing is cleaned between jobs, so build trees
persist. Measured after several runs, this pipeline's footprint is modest:

| Path | Size | What it is |
| --- | --- | --- |
| `F:\ghrunner-work\OCCT\OCCT\build-win` | 5.5 GB | MSVC build tree (also the incremental cache) |
| `...\install-win` + `...\install-linux` | 1.5 GB | staged install trees |
| `...\*.tar.gz` | varies | packaged artifacts, one per run and target |

```powershell
Get-PSDrive F | Select-Object Used, Free
```

Deleting `build-win` reclaims the most, at the cost of the incremental cache — the next
Windows build then recompiles from scratch. Do it when the runner is idle:

```powershell
Remove-Item F:\ghrunner-work\OCCT\OCCT\build-win, `
            F:\ghrunner-work\OCCT\OCCT\install-win, `
            F:\ghrunner-work\OCCT\OCCT\install-linux, `
            F:\ghrunner-work\OCCT\OCCT\*.tar.gz -Recurse -Force
```

The Linux job's storage lands elsewhere: Docker image layers and build cache live in the
Docker Desktop WSL2 VM, whose virtual disk is redirected to `D:\WSLData\Docker` (via a
junction from `C:\Users\sxd\AppData\Local\Docker\wsl`), so it consumes `D:`, not `F:`.

**Check what else is on this host before pruning Docker.** This machine holds 98 images
across unrelated projects, and `docker_data.vhdx` has reached 275 GB almost entirely
because of them — this pipeline pulls exactly one image (`ubuntu:22.04`, 119 MB) and
runs its container with `--rm`, so it leaves nothing behind. `docker system prune -a
--volumes` would delete all of that unrelated work. Prefer the narrow commands:

```powershell
docker image prune -f      # dangling layers only
```

Also note `docker_data.vhdx` is sparse and never shrinks on its own: its size is a
high-water mark, not live data. Compacting it needs `wsl --shutdown` plus
`Optimize-VHD`, which risks the whole Docker data disk if interrupted — not worth doing
while `D:` still has hundreds of gigabytes free.

## 7. Artifact publication (Aliyun OSS + GitHub Packages)

**Nothing is attached to a release.** The bytes live in a GHCR package and, once the
Aliyun side is provisioned, in an OSS blob as well. The release notes are an index
over both.

| Destination | Role | What lands there |
| --- | --- | --- |
| GitHub Packages (GHCR) | retrieval | an OCI image carrying the archive, plus a `catalog.json` of the OSS coordinates |
| Aliyun OSS | system of record | the archive as an immutable content-addressed blob — **not provisioned yet** |
| GitHub Releases | human-facing index | notes carrying `sha256`, the GHCR reference, the OSS coordinates when present, and fetch commands — **no attached files** |

OSS and GHCR run on a tag or on a manual run with **publish** ticked. The release
notes are written on a tag only, because a manual run has no tag to attach them to.

**The OSS leg is currently a no-op.** `publish-oss.ps1` exits 0 with a notice when
`OCCT_OSS_ROLE_ARN` and `OCCT_OSS_OIDC_PROVIDER_ARN` are unset, so a tag build
succeeds without Aliyun. Until the bucket and role exist, GHCR is the only place the
bytes land, and the release notes say so per artifact instead of pointing at a blob
that is not there.

Two consequences worth stating plainly, since they change how you consume a build:

- There is nothing to click on the Releases page. Retrieval is `docker pull` (GitHub
  credentials) or `ossutil` (Aliyun credentials), not a browser download. The OSS
  bucket is private with block-public-access on, so a URL would either not work or
  expire within the hour (see [Why coordinates, not links](#why-coordinates-not-links)).
- GHCR read access is GitHub read access. The package authenticates against the same
  identity that grants access to this repository, so anyone who can read the repo can
  fetch the artifacts with no second credential to issue.

This mirrors the `cad test` fixture publication in `D:\everxyz-CQ\code\Utopia`, and
deliberately reuses its contract rather than inventing a parallel one — same
`ossutil` 2.3.0 pinned by the same SHA-256, same `blobs/gzip/sha256/<digest>` key
layout, same gzip transport encoding, same immutability rules. A consumer that can
restore a Utopia engineering asset can restore an OCCT artifact with the same code.

The contract lives in [`oss-artifacts.json`](oss-artifacts.json).

**The bucket is shared with Utopia; the RAM role is not.** Artifacts land in
`everxyz-utopia-sdk-supply-cn-shenzhen`, the bucket Utopia already tracks as
`buckets.sdk`. That is not a convenience — Utopia's `maintain-engineering-assets`
contract requires reusing the tracked provider, bucket and rights context rather
than proposing new ones. Sharing it is safe because keys are content-addressed: an
object key is a pure function of the bytes, so an OCCT artifact cannot collide with
another asset's key, and `--forbid-overwrite` turns a digest collision into a loud
failure instead of a silent clobber.

The RAM role is deliberately separate. Handing an OCCT build job Utopia's
`UtopiaSdkSupplyPublish` identity would widen its blast radius well past this
repository, and Utopia's own contract requires read, publish and cleanup roles stay
separate. OCCT gets its own role with the same narrow policy shape.

One consequence to be aware of: because both repositories publish under the same
`blobs/gzip/sha256/` prefix, this role can *read* any blob there. It cannot delete
or overwrite anything, cannot reach outside the prefix, and cannot be assumed by
anything but this repository's tagged builds. Read-across is inherent to sharing a
content-addressed prefix; narrowing it would need a per-repository prefix, which the
tracked contract does not provide.

### Why coordinates, not links

A release records `bucket`, `object key` and `sha256` plus an `ossutil cp` line,
rather than a download URL. Three options were considered:

| Form | Why not |
| --- | --- |
| Public URL | The bucket is `private` with `block_public_access: true` and objects get a private ACL. It is Utopia's bucket holding Utopia's production assets, so opening it up is not this repository's call. |
| Pre-signed URL | Works, but is signed by the job's STS credential and dies with it — an hour. Release notes outlive that, so the link would rot into a 403. |
| Coordinates + command | Never expire, and anyone with read access on the bucket can act on them. |

To make the notes carry a permanent clickable link, Utopia would need to expose an
anonymously-readable prefix (or a separate bucket) for OCCT artifacts. That is a
decision for the Utopia side, not something this repository can provision.

### Why the object key is a digest, not a filename

The key is `blobs/gzip/sha256/<sha256-of-the-plaintext-archive>`. Uploads pass
`--forbid-overwrite`, so objects are immutable and re-running a build that produces
identical bytes is a verified no-op instead of a rewrite. The publish role holds
`oss:GetObject` and `oss:PutObject` only — there is no delete action anywhere in
this path, matching Utopia's `fixtures_publish` policy.

The `sha256` recorded in object metadata covers the **plaintext** archive, not the
gzip-encoded body that is transferred. `.tar.gz` content gets gzipped a second time
for transport; that costs about 0.1% in size and keeps the key prefix's promise
(`blobs/gzip/...`) true, so a reader knows to decode without probing.

### Credentials: no static AccessKey

Utopia has two credential paths and neither transfers to a CI runner: `aliyun-cli`
OAuth is interactive, and ACK RRSA needs a Kubernetes service account. This uses the
third form of the same idea — **GitHub OIDC federated into RAM** via
`sts:AssumeRoleWithOIDC`. The job proves its identity with a short-lived token and
receives short-lived STS credentials. Nothing static is stored in this repository;
there are no repository secrets for Aliyun at all.

The STS triple reaches `ossutil` through `OSS_ACCESS_KEY_ID`,
`OSS_ACCESS_KEY_SECRET` and `OSS_SESSION_TOKEN` in the environment, never in argv
and never in a config file. That matters more here than on a hosted runner: this box
is not ephemeral, so a credential written to `~/.ossutilconfig` would outlive the
job, and one passed as an argument would be visible to any local process list. Only
`OSS_SESSION_TOKEN` makes `ossutil` send the `x-oss-security-token` header, so all
three are required — an AK/SK pair alone gets a `403 InvalidAccessKeyId` from STS
credentials.

### Aliyun setup (one-off)

[`scripts/setup-aliyun-oss.ps1`](scripts/setup-aliyun-oss.ps1) does all of this and
is idempotent. Authenticate first — no static AccessKey is created or stored:

```bash
aliyun configure --mode OAuth
```

Then preview, and apply:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File .github/scripts/setup-aliyun-oss.ps1 -WhatIf
```

The steps it performs, if you would rather do them by hand in the console. It
touches your Aliyun account, not this machine.

1. **Nothing to create for the bucket.** `everxyz-utopia-sdk-supply-cn-shenzhen`
   already exists and belongs to Utopia. The script verifies it and reports any
   divergence from `bucket_contract`, but applies nothing: reconfiguring a bucket
   this repository does not own is outside its remit.

2. **Create an OIDC provider** in RAM pointing at GitHub:

   - issuer URL `https://token.actions.githubusercontent.com`
   - client ID (audience) `sts.aliyuncs.com`

3. **Create the publish role**, e.g. `OcctArtifactsPublish`, with a trust policy
   that accepts only this repository. Scope it on `sub` — an audience check alone
   would let *any* GitHub repository assume the role:

   ```json
   {
     "Version": "1",
     "Statement": [{
       "Effect": "Allow",
       "Action": "sts:AssumeRoleWithOIDC",
       "Principal": { "Federated": ["acs:ram::<account-id>:oidc-provider/github-actions"] },
       "Condition": {
         "StringEquals": {
           "oidc:aud": ["sts.aliyuncs.com"],
           "oidc:iss": ["https://token.actions.githubusercontent.com"]
         },
         "StringLike": {
           "oidc:sub": ["repo:everxyz/OCCT:ref:refs/tags/*"]
         }
       }
     }]
   }
   ```

   Attach a policy carrying exactly `oss:GetObject` and `oss:PutObject` on
   `acs:oss:*:*:everxyz-utopia-sdk-supply-cn-shenzhen/blobs/gzip/sha256/*`.
   No delete action, and nothing outside that prefix.

   The `oidc:sub` pattern above only matches tag pushes. Manual runs with
   **publish** ticked come from a branch and will be refused; add
   `repo:everxyz/OCCT:ref:refs/heads/master` if you want those to work too.

4. **Set two repository variables** — Settings → Secrets and variables → Actions →
   **Variables** (not Secrets; these are ARNs, which name a role but do not grant
   it — the trust policy decides that):

   | Variable | Value |
   | --- | --- |
   | `OCCT_OSS_ROLE_ARN` | `acs:ram::<account-id>:role/occtartifactspublish` |
   | `OCCT_OSS_OIDC_PROVIDER_ARN` | `acs:ram::<account-id>:oidc-provider/github-actions` |

   Optional: `OCCT_OSS_BUCKET` and `OCCT_OSS_REGION` override the contract without
   a commit.

Until those variables exist the OSS step **skips with a notice and the build still
passes**, so this can ship before the Aliyun side is provisioned. The GitHub
Packages step does not depend on them and works immediately.

### GitHub Packages, and the storage caveat

GitHub Packages has no generic file registry — the formats are OCI, npm, NuGet,
Maven and RubyGems — so the archive is wrapped in a `FROM scratch` OCI image. That
needs no new tooling, since the runner already has a working Docker CLI and daemon
for the Linux build; ORAS would have been another binary to vendor and pin.

One package, `ghcr.io/everxyz/occt`, tagged `<version>-<platform>-<mode>`:

```bash
docker pull ghcr.io/everxyz/occt:1.0.0-linux-amd64-release
```

`org.opencontainers.image.source` is what attaches the package to this repository
rather than leaving it orphaned at the org level. The OSS coordinates travel as
`com.everxyz.occt.oss.*` labels and as a `/catalog.json` inside the image, so a
consumer can resolve the blob from either.

**The image carries the archive.** `docker pull` yields the binaries, because GHCR is
currently the only retrieval path that works — an index-only image would point at an
OSS blob that has not been published. Extract them with:

```bash
docker create --name occt-fetch ghcr.io/everxyz/occt:<tag> /x
docker cp occt-fetch:/<archive>.tar.gz .
docker rm occt-fetch
```

The image is `FROM scratch`, so it has no entrypoint and `docker create` insists on a
command argument. `/x` is never executed — the container only ever serves as a
filesystem to copy out of.

The cost is the account's Packages quota, which nothing expires on its own (a Debug
pair runs ~199 MB Windows + ~265 MB Linux per tag). Once OSS publication works, set
repository variable `OCCT_GHCR_INDEX_ONLY` to `true` to go back to a pointer-only
image holding just `catalog.json`. Old versions can be deleted from the Packages UI,
or:

```bash
gh api --method DELETE /orgs/everxyz/packages/container/occt/versions/<version-id>
```

### Verifying it

A manual run exercises OSS and GHCR without cutting a tag:

**Actions → everxyz Build → Run workflow**, targets `windows-x64`, **publish** ✔.

It will not write release notes — those need a tag, since there is no release to
attach them to otherwise. To exercise the whole path including the notes, push a tag:

```bash
git tag everxyz-release-0.0.2 && git push origin everxyz-release-0.0.2
```

The vendored `ossutil` can be installed and checked on its own:

```powershell
powershell -File .github\scripts\install-ossutil.ps1
```

And the GHCR image can be built and inspected without pushing, which needs no
`write:packages` token:

```powershell
.github\scripts\publish-ghcr.ps1 -Archive <some>.tar.gz -Platform linux-amd64 -Mode Release -Version 0.0.0 -DryRun
```
