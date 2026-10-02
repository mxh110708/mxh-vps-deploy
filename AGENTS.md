# Repository Guidelines

## Project Structure & Module Organization

MXH VPS Deploy is a Windows PowerShell control tool for Debian 12/13 amd64 VPS instances. `Start-VPSDeploy.ps1` dispatches workflows. Modules in `src/` implement deployment, import, maintenance, recovery, and client configuration. `assets/remote/` contains Bash operations; `scripts/` contains Python configuration helpers and asset validators. Public templates are in `templates/client/`, fixed versions in `config/versions.json`, and checked client assets in `vendor/test-cores/`. Tests and fixtures are under `tests/`; Chinese operating guides are under `docs/`.

## Build, Test, and Development Commands

Use PowerShell 7.4+ and Python 3.9+ from the repository root:

```powershell
python -m pip install -r .\requirements-client-merge.txt
pwsh -NoProfile -File .\Start-VPSDeploy.ps1 -Mode ValidateProject
pwsh -NoProfile -File .\tests\Test-AuditFixes.ps1 -ProjectRoot $PWD
pwsh -NoProfile -File .\tests\Test-ClientCompatibility.ps1 -ProjectRoot $PWD
pwsh -NoProfile -File .\scripts\Test-NoSecrets.ps1 -ProjectRoot $PWD
```

`ValidateProject` runs the main regression entry, including available Python/Bash checks; do not run `Run-Tests.ps1` again merely to duplicate it. Compatibility checks use fixed real client cores. Local tests create isolated temporary files and do not authorize production operations. Start the interactive tool with `Start-VPSDeploy.cmd`.

## Coding Style & Naming Conventions

Follow surrounding formatting: four-space PowerShell/Python indentation, strict PowerShell error handling, and LF Bash files. Use existing `Verb-VpsNoun` functions, explicit parameter validation, and professional Chinese prompts. Preserve return/cancel semantics. Keep templates generic; retain legitimate custom configuration and fail closed on ambiguous layouts.

## Testing Guidelines

PowerShell uses assertion scripts named `Test-*.ps1`; Python uses `test_*.py`. Add behavior regressions for failures, cancellation, stale fingerprints, and rollback scope. Check Bash syntax and ShellCheck warnings. No numerical coverage threshold is specified. Simulated systemd and loopback tests do not prove production migration or WAN behavior.

## Commit, Pull Request & Security Guidelines

History contains concise Chinese subjects and `feat:`, `fix:`, or `test:` prefixes. Keep commits scoped. PRs should identify compatibility changes, verification, recovery behavior, and remaining gaps. Never commit `private/`, credentials, instance archives, local defaults, or signing materials. Controller-only recovery must not touch Tunnel; protocol recovery must not overwrite monitoring. Production upgrades, authoritative-config publication, proxy switches, and releases require explicit scope.
