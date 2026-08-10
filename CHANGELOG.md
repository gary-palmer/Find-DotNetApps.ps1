# Changelog

All notable changes to this project are documented in this file.

The format is inspired by [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.1] - 2026-08-10
Bug fix. 

- Fix issue with parameter validation introduced in v1.1.
- Improve the parameter examples in the comment help section.


## [1.1.0] - 2026-08-10

Bug fixes, parameter improvements, and help expansion.

- Fix typo: IsNullOrWhiteSpace mistyped as INullOrWhiteSpace in Get-FileMetadata.  
- Rename Test-IgnoredPath to Test-IsIgnoredPath.  
- Make -OutputFile optional; it was incorrectly marked Mandatory.  
- Add ValidateScript input validation to -Path and -OutputFile.  
- Expand comment-based help with .PARAMETER, .NOTES, and .LINK sections.  
- Add author, version history, and license metadata to script header.  
- Ensure reasonable line lengths are adhered to.


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