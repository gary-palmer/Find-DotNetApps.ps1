# Changelog

All notable changes to this project are documented in this file.

The format is inspired by [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-08-07

### Added
- Initial public release of `Find-DotNetApps.ps1`.
- Folder scanning for `.exe` and `.dll` binaries.
- Optional recursive scanning (default behavior) with `-IgnoreSubDirs` to disable recursion.
- Optional native binary inclusion with `-IncludeNative`.
- Optional progress display with `-ShowProgress`.
- Optional runtime usage summary with `-IncludeSummary`.
- CSV export via `-OutputFile`.

### Detection
- Staged runtime detection pipeline:
  1. `*.runtimeconfig.json`
  2. bundled runtime file checks
  3. `*.deps.json`
  4. single-file self-contained heuristic
  5. reflection fallback for managed assemblies
- Bundled runtime file detection:
  - `coreclr.dll`
  - `hostfxr.dll`
  - `hostpolicy.dll`
  - `System.Private.CoreLib.dll`
- Bundled runtime version extraction from file version metadata.
- Target framework inference from:
  - TFM (`runtimeconfig.json`)
  - framework name attributes
  - deps targets/libraries
  - bundled runtime major version mapping (including noisy values with commit suffixes).

### Compatibility
- PowerShell 5.1+ compatible implementation.
- Cross-version CSV encoding handling:
  - PowerShell 5.1: `UTF8`
  - PowerShell 7+: `utf8BOM`

### Reliability
- Graceful handling for:
  - access denied
  - locked files / I/O errors
  - invalid files and parse failures
- Duplicate file processing prevention.
- Ignored OS paths:
  - `C:\Windows`
  - `C:\Windows\WinSxS`

### Metadata
- Application metadata extraction from `VersionInfo`:
  - ProductName (fallback to filename)
  - ProductVersion/FileVersion (fallback to `Unknown`)
- Mojibake repair function for malformed product/version strings.

### Licensing
- Added MIT licensing metadata and SPDX identifier support.
