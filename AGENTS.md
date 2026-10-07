# Repository Guidelines

## Project Structure & Module Organization

MXH VPS Deploy is a Windows PowerShell control tool for Debian 12/13 amd64 VPS instances. `Start-VPSDeploy.ps1` dispatches workflows. Modules in `src/` implement deployment, import, maintenance, recovery, and client configuration. `assets/remote/` contains Bash operations; `scripts/` contains Python configuration helpers and asset validators. Public templates are in `templates/client/`, fixed versions in `config/versions.json`, and checked client assets in `vendor/test-cores/`. Tests and fixtures are under `tests/`; Chinese operating guides are under `docs/`.

`Start-VPSDeploy.Gui.ps1`, `assets/gui/`, and `src/gui/` implement the WPF desktop shell, input broker and SSH askpass bridge. `VpsDeploy.GuiData.psm1` defines app-local private data; `VpsDeploy.Update.psm1` verifies and applies app updates. Desktop navigation is organized around forms, selected instances, client schemes and task outcomes; do not introduce CLI menu-number input or a legacy archive import UI.

`src/desktop/` builds the native GUI EXE and independent update/guard helpers. `assets/installer/` defines the Windows installer and optional keep/remove-data uninstall. The application bundles fixed, verified private runtimes without changing global PATH or installing services. Installer updates must preserve private/local files and reject managed edits or unmanaged collisions; full uninstall may remove only the explicitly selected app directory and must reject links.

## Build, Test, and Development Commands

Use PowerShell 7.4+ and Python 3.9+ from the repository root:

```powershell
python -m pip install -r .\requirements-client-merge.txt
pwsh -NoProfile -File .\Start-VPSDeploy.ps1 -Mode ValidateProject
pwsh -NoProfile -File .\tests\Test-AuditFixes.ps1 -ProjectRoot $PWD
pwsh -NoProfile -File .\tests\Test-ClientCompatibility.ps1 -ProjectRoot $PWD
pwsh -NoProfile -File .\scripts\Test-NoSecrets.ps1 -ProjectRoot $PWD
```

`ValidateProject` runs the main regression entry, including GUI/update and available Python/Bash checks; do not run `Run-Tests.ps1` again merely to duplicate it. GUI checks need Windows STA and temporary current-user named pipes; restricted sandboxes may block the local credential bridge. Compatibility checks use fixed real client cores. Local tests create isolated temporary files and do not authorize production operations. `Start-VPSDeploy.cmd` opens the desktop shell; `Start-VPSDeploy.Cli.cmd` retains CLI navigation.

Build a local preview with `scripts/New-VpsReleasePackage.ps1 -Destination <output> -Development`. Formal packaging requires a clean main tree and stable application metadata with the new version; package creation does not authorize pushing or releasing. Keep update ownership limited to the manifest; never reset Git history or overwrite private/local/unmanaged files.

`tests/Test-DesktopInstaller.ps1` performs real install/update/uninstall tests using QA installers with no shortcuts or uninstall registry entries, under an isolated project fixture. CI runs this once in the Windows Python 3.13/runner job; do not duplicate all package tests across the matrix. Verify installers with native EXE startup and actual lifecycle behavior, not only file extensions or script parsing. Never deploy a QA installer as a release.

## Coding Style & Naming Conventions

Follow surrounding formatting: four-space PowerShell/Python indentation, strict PowerShell error handling, and LF Bash files. Use existing `Verb-VpsNoun` functions, explicit parameter validation, and professional Chinese prompts. Preserve return/cancel semantics. Keep templates generic; retain legitimate custom configuration and fail closed on ambiguous layouts.

## Testing Guidelines

PowerShell uses assertion scripts named `Test-*.ps1`; Python uses `test_*.py`. Add behavior regressions for failures, cancellation, stale fingerprints, and rollback scope. Check Bash syntax and ShellCheck warnings. No numerical coverage threshold is specified. Simulated systemd and loopback tests do not prove production migration or WAN behavior.

## Commit, Pull Request & Security Guidelines

History contains concise Chinese subjects and `feat:`, `fix:`, or `test:` prefixes. Keep commits scoped. PRs should identify compatibility changes, verification, recovery behavior, and remaining gaps. Never commit `private/`, credentials, instance archives, local defaults, or signing materials. Controller-only recovery must not touch Tunnel; protocol recovery must not overwrite monitoring. Production upgrades, authoritative-config publication, proxy switches, and releases require explicit scope.
