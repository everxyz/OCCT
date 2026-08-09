# Self-hosted runner setup (everxyz-win)

The `everxyz Build` workflow targets a runner labelled `everxyz-win`. These are the
steps to turn this Windows machine into that runner.

## Before you start: the security tradeoff

`everxyz/OCCT` is public. GitHub warns against self-hosted runners on public
repositories because anyone can fork the repo, point a workflow at
`runs-on: self-hosted`, and open a pull request that executes their code on this
machine. Unlike GitHub-hosted runners, this box is not destroyed after each job.

The mitigations already in place:

- `everxyz-release.yml` triggers only on `push` of a tag and on `workflow_dispatch`.
  Neither can be triggered by a fork's pull request.
- Every upstream OCCT job carries `if: github.repository == 'Open-Cascade-SAS/OCCT'`,
  so none of them run here.
- The label is `everxyz-win`, not the generic `self-hosted`.

Still do this in the repo settings:

1. **Settings → Actions → General → Fork pull request workflows**: require approval
   for all outside collaborators.
2. **Settings → Actions → Runners**: after registering, restrict the runner so it
   cannot be used by pull requests.

## 1. Create a dedicated local account

Do not run the service as your daily user. The runner would inherit access to
everything on `D:\` including credentials.

Run as Administrator in PowerShell:

```powershell
$pw = Read-Host -AsSecureString "Password for the runner account"
New-LocalUser -Name "ghrunner" -Password $pw -PasswordNeverExpires -AccountNeverExpires
Add-LocalGroupMember -Group "Users" -Member "ghrunner"
```

Give it a work directory it owns, outside your project tree. Both the runner and its
work tree live on `F:` — it has the most free space (672 GB of 1.3 TB), and a full
OCCT build tree plus install tree for two targets can reach tens of gigabytes:

```powershell
New-Item -ItemType Directory -Force -Path F:\actions-runner, F:\ghrunner-work
icacls F:\actions-runner /grant "ghrunner:(OI)(CI)F" /T
icacls F:\ghrunner-work /grant "ghrunner:(OI)(CI)F" /T
```

Docker access is needed for the Linux amd64 job. Group membership alone is not enough
here — see [section 5](#5-docker-for-the-linux-amd64-job) for the two separate reasons
`ghrunner` cannot use the installed Docker CLI, and what the job does instead:

```powershell
Add-LocalGroupMember -Group "docker-users" -Member "ghrunner"
```

## 2. Download the runner

```powershell
cd F:\actions-runner
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
cd F:\actions-runner
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
still does all the work. `F:\actions-runner` already grants `Users` read+execute, so
the copy inherits usable ACLs. If `DOCKER_CLI` is missing the job falls back to
whatever `docker` is on PATH, so this stays correct on a host with intact ACLs.

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

Debug builds use the `everxyz-dev-` prefix and are published as pre-releases:

```bash
git tag everxyz-dev-1.0.0 && git push origin everxyz-dev-1.0.0
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
queue rather than overlap. Measured on a `everxyz-dev-*` (Debug) tag, back when the
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
cd F:\actions-runner; .\config.cmd remove --token <REMOVAL_TOKEN>
```

Disk use grows with each build. `F:\ghrunner-work` holds the checkout, the CMake
build tree and the install tree for both targets; a full OCCT build tree can reach
tens of gigabytes. Check headroom with:

```powershell
Get-PSDrive F | Select-Object Used, Free
```

The workflow does not clean up between runs beyond `rm -rf` on its own source and
install directories, so reclaim space by deleting stale job directories under
`F:\ghrunner-work` when the runner is idle.

The Linux job's disk use lands somewhere else: Docker image layers and build cache
live in the Docker Desktop WSL2 VM, whose virtual disk on this machine is redirected
to `D:\WSLData\Docker` (via a symlink from
`C:\Users\sxd\AppData\Local\Docker\wsl`), so it consumes D: rather than F:. Reclaim
that space separately:

```powershell
docker system prune -a --volumes
```
