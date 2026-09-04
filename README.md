# PSTools-InstallerWulf

Windows PowerShell Tools installer and manager for a centralized `C:\PS` environment.

The repository does **not** redistribute Microsoft PsTools or third-party executable archives. Managed tools are downloaded at install/update time from their original publisher or upstream release source.

## What it does

- installs or refreshes Microsoft Sysinternals PsTools directly from Microsoft
- creates and maintains a centralized `C:\PS` tool structure
- detects already installed managed tools
- provides a selectable add/remove tool workflow
- downloads the latest matching Windows release assets from upstream projects
- keeps standalone commands and generated shims in `C:\PS\binaries`
- synchronizes the machine PATH with actual command directories under `C:\PS`
- removes stale managed `C:\PS` PATH entries after tools are removed
- checks existing WindowsApps ACLs and skips permission changes when the required rights are already present

## Runtime structure

```text
C:\PS\
├─ Microsoft.Sysinternals.PsTools\   Microsoft PsTools
├─ binaries\                         standalone EXE files and command shims
├─ tools\                            isolated Python virtual environments
│  └─ tdl-CompanionWulf\             isolated CompanionWulf environment
├─ apps\                             managed portable GUI applications
├─ WULF\                             installer infrastructure and state
├─ aria2\                            extracted command package
├─ doggo\                            extracted command package
├─ bandwhich\                        extracted command package
└─ mprocs\                           extracted command package
```

`C:\PS\binaries` is always maintained as a machine PATH entry. `C:\PS\WULF`, `C:\PS\tools`, and `C:\PS\apps` are intentionally excluded from automatic PATH discovery. Other directories are added only when they directly contain `.exe`, `.cmd`, `.bat`, or `.com` commands.

## Managed catalog

The current selectable catalog includes:

- yt-dlp
- tdl
- tdl-CompanionWulf
- qscreen / qscn
- you-get
- spotDL
- aria2
- gallery-dl
- scdl
- jq
- ripgrep / rg
- fd
- fzf
- bat
- doggo
- bandwhich
- mprocs from `pvolok/dekit`
- Parabolic portable
- MediaDownloader portable

On a fresh installation, yt-dlp, tdl, and you-get are selected by default. Python-based tools require an available Python 3 installation and are isolated in their own virtual environments; only small command shims are placed in `C:\PS\binaries`.

`tdl-CompanionWulf` is installed from its own upstream source archive into an isolated virtual environment. It reuses the separately managed `tdl.exe` from `C:\PS\binaries` instead of bundling or redistributing a second tdl binary. Its SQLite queue database is stored in the user's local application-data area. Keep `tdl` selected when using CompanionWulf.

Portable single-command packages such as jq, rg, fd, fzf and bat are reduced to their executable command during installation and placed directly in `C:\PS\binaries`.

## Usage

Run:

```bat
PSToolsWulfInstaller.bat
```

Validate the manifest, Microsoft source, upstream GitHub release rules, and local prerequisites without changing `C:\PS`, ACLs, or the machine PATH:

```bat
PSToolsWulfInstaller.bat -Validate
```

For automated validation without waiting for input:

```bat
PSToolsWulfInstaller.bat -Validate -NoPause
```

Administrator elevation is requested only for the installation/management workflow when required. Validation does not request elevation. In the tool selection screen use the arrow keys to navigate, `SPACE` to toggle a tool, and `ENTER` to apply the desired state.

The installer treats the selection as desired state: selected tools are installed or refreshed from upstream, deselected managed tools are removed, and PATH is synchronized afterward.

## Upstream download strategy

Microsoft PsTools is downloaded from the official Sysinternals download endpoint:

```text
https://download.sysinternals.com/files/PSTools.zip
```

GitHub-hosted tools are resolved through each project's latest release metadata and matched against a Windows-specific asset rule stored in `WULF/tools.json`. This avoids pinning the installer to a stale release URL while keeping downloads on the original project source. When GitHub supplies a `sha256:` digest for a release asset, the downloaded file is verified before it is installed or extracted.

Python-based tools are installed from their Python package distribution or an explicitly configured upstream source archive into dedicated virtual environments.

## Candidates intentionally not included in the command catalog

Some requested projects are Windows-capable but do not yet fit the same portable command workflow without additional dependency or package-format handling:

- **MEGAcmd**: Windows-capable, but the provided GitHub repository does not publish GitHub release assets; it needs a separate official-installer integration.
- **tgdl (Kikks/tgdl)**: no current GitHub release asset suitable for the automatic Windows release workflow was identified.
- **RipMe**: cross-platform and Windows-capable, but distributed as a Java `.jar`; a Java runtime and a managed launcher need to be handled explicitly before adding it.
- **signal-cli**: upstream explicitly supports Windows and bundles the Windows native library, but the JVM distribution currently requires a Java runtime. Java/runtime detection, `.tar.gz` extraction and launcher handling should be added before enabling it in the catalog.
- **cobalt**: primarily a self-hosted service/API rather than a portable Windows command utility.
- **vysheng/tg**: not a suitable current native Windows package for this installer model.
- **curl**: modern Windows 10/11 systems already ship a system-managed curl; replacing the OS copy from this installer would create unnecessary precedence/version ambiguity.
- **GNU Wget** from the provided GNU repository: upstream source is available, but there is no equivalent current official native Windows release asset to consume like the other managed tools.

## Repository policy

Third-party binaries and archives should not be committed to this repository merely for convenience. Add new tools by extending `WULF/tools.json` and, when necessary, the installer handler for the package format. Prefer original publisher URLs and upstream release APIs.
