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

Give it a work directory it owns, outside your project tree:

```powershell
New-Item -ItemType Directory -Force -Path C:\actions-runner, D:\ghrunner-work
icacls D:\ghrunner-work /grant "ghrunner:(OI)(CI)F"
icacls C:\actions-runner /grant "ghrunner:(OI)(CI)F"
```

Docker access is needed for the Linux arm64 job:

```powershell
Add-LocalGroupMember -Group "docker-users" -Member "ghrunner"
```

## 2. Download the runner

```powershell
cd C:\actions-runner
$v = "2.336.0"
Invoke-WebRequest -Uri "https://github.com/actions/runner/releases/download/v$v/actions-runner-win-x64-$v.zip" -OutFile runner.zip
Expand-Archive -Path runner.zip -DestinationPath . -Force
Remove-Item runner.zip
```

## 3. Register it

Get a registration token from **Settings → Actions → Runners → New self-hosted
runner** (it is valid for one hour). Then:

```powershell
cd C:\actions-runner
.\config.cmd --url https://github.com/everxyz/OCCT --token <REGISTRATION_TOKEN> --name everxyz-win-01 --labels everxyz-win --work D:\ghrunner-work --runasservice --windowslogonaccount ".\ghrunner" --windowslogonpassword "<PASSWORD>"
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

## 5. Docker for the Linux arm64 job

Docker Desktop must be running when a build starts, and it must be reachable by the
`ghrunner` account. Docker Desktop runs per-user, which is awkward for a service
account. Two options:

- Set Docker Desktop to start on boot and log in once as `ghrunner` so its context
  exists, or
- switch the Linux job to WSL instead of Docker (Ubuntu-22.04 is already installed),
  which avoids the service-account problem but loses arm64 emulation.

Verify emulation works from the runner account:

```powershell
docker run --rm --privileged tonistiigi/binfmt:latest --install arm64
docker run --rm --platform linux/arm64 arm64v8/ubuntu:22.04 uname -m
```

The second command should print `aarch64`.

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

## Notes on the arm64 build

The host CPU is x86_64, so the Linux arm64 build runs under QEMU emulation. Expect
it to be several times slower than a native build — potentially hours for a full
OCCT compile. If this becomes the bottleneck, a native aarch64 machine is the
answer; the workflow needs only a different `runs-on` label for that job.

## Maintenance

```powershell
# status
Get-Service actions.runner.*

# stop accepting jobs
Stop-Service actions.runner.everxyz-OCCT.everxyz-win-01

# deregister (get a removal token from the same settings page)
cd C:\actions-runner; .\config.cmd remove --token <REMOVAL_TOKEN>
```

Disk use grows with each build. `D:\ghrunner-work` holds the checkout, the CMake
build tree and the install tree for both targets; a full OCCT build tree can reach
tens of gigabytes.
