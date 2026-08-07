# Find-DotNetApps.ps1

Scan a folder for `.exe` and `.dll` files and identify which .NET runtimes they use (installed vs bundled), so you can determine whether older runtimes are still required.

> Compatible with **Windows PowerShell 5.1+** (and PowerShell 7+).

---

## Features

- Scans binaries in a target folder (optionally recursive).
- Detects:
  - .NET Framework apps
  - .NET Core / .NET 5+ framework-dependent apps
  - .NET Core / .NET 5+ self-contained apps
  - probable single-file self-contained apps
  - native binaries (optional inclusion)
- Uses staged detection for performance:
  1. `*.runtimeconfig.json`
  2. bundled runtime files (`coreclr.dll`, `hostfxr.dll`, `hostpolicy.dll`, `System.Private.CoreLib.dll`)
  3. `*.deps.json`
  4. single-file heuristic
  5. reflection fallback
- Handles problematic files gracefully:
  - access denied
  - locked files
  - invalid binaries
- Ignores Windows OS locations if encountered:
  - `C:\Windows`
  - `C:\Windows\WinSxS`
- Optional progress bar
- Optional runtime usage summary
- CSV export support

---

## Requirements

- Windows PowerShell **5.1** or later
- No .NET SDK required
- No Visual Studio required
- No third-party PowerShell modules required

---

## Script Parameters

### Mandatory

- `-Path <string>`  
  Root folder to scan.

- `-OutputFile <string>`  
  CSV path for results.

### Optional

- `-IgnoreSubDirs`  
  If specified, scans only the specified folder (no recursion).

- `-IncludeSummary`  
  Outputs a runtime usage summary after scanning.

- `-IncludeNative`  
  Includes native (non-.NET) binaries in results.

- `-ShowProgress`  
  Displays a progress bar during scanning.

---

## Usage Examples

### Recursive scan of Program Files (x86) and export CSV

```powershell
.\Find-DotNetApps.ps1 `
  -Path "C:\Program Files (x86)" `
  -OutputFile "C:\Temp\dotnet-runtime-usage-x86.csv" `
  -ShowProgress `
  -Verbose
```

### Scan only top-level directory (no recursion)

```powershell
.\Find-DotNetApps.ps1 `
  -Path "C:\Apps" `
  -IgnoreSubDirs `
  -OutputFile "C:\Temp\dotnet-runtime-usage.csv"
```

### Include native binaries + summary

```powershell
.\Find-DotNetApps.ps1 `
  -Path "C:\Apps" `
  -OutputFile "C:\Temp\all-binaries.csv" `
  -IncludeNative `
  -IncludeSummary
```

---

## Output Columns

| Column | Description |
|---|---|
| Application Name | Product name from file metadata (or filename fallback) |
| Application Version | ProductVersion/FileVersion (or `Unknown`) |
| Exe Name | File name |
| Full Path | Full file path |
| Deployment | Runtime classification |
| Target Framework | Detected target framework (e.g., `v4.8`, `net8.0`) |
| Bundled Runtime | `True`/`False` |
| Bundled Runtime Version | Bundled runtime version when detectable |
| Detection Method | Which detection stage produced the result |

---

## Detection Notes

### Bundled runtime to target framework mapping

When runtime is bundled and version contains extra metadata (for example commit suffixes), the script normalizes values and maps major version to TFM:

- `6.x.x` → `net6.0`
- `7.x.x` → `net7.0`
- `8.x.x` → `net8.0`
- `9.x.x` → `net9.0`
- `10.x.x` → `net10.0` (future-safe mapping)

Example noisy runtime input handled:

- `7,0,523,17405 @Commit: ...`
- `10,0,926,27113 @Commit: ...`

### .NET Framework apps

`.NET Framework` apps are detected from managed metadata/reflection and reported as:

- `v2.0`, `v3.0`, `v3.5`
- `v4.0` ... `v4.8`, `v4.8.1`

---

## Runtime Usage Summary

With `-IncludeSummary`, a grouped summary is printed after scan, for example:

- `.NET Framework 4.8`
- `.NET 6 Runtime`
- `.NET 8 Runtime`

Including which applications were detected for each.

---

## Troubleshooting

### `utf8BOM` encoding error on export (PowerShell 5.1)

Windows PowerShell 5.1 does not accept `utf8BOM` as an explicit encoding name.  
The script handles this by using:

- PowerShell 7+: `utf8BOM`
- PowerShell 5.1: `UTF8`

### Mojibake in ProductName (e.g., `MicrosoftÂ® .NET`)

Some binaries expose malformed version-resource text through APIs.  
The script includes a mojibake repair step to normalize common cases.

### No results from `C:\Program Files (x86)`

- Run in **64-bit** PowerShell.
- Use `-Verbose` and/or `-ShowProgress`.
- Confirm permissions.
- Confirm recursion behavior (`-IgnoreSubDirs` disables recursion).

---

## License

This project is licensed under the MIT License.

SPDX identifier used in script header:

```text
SPDX-License-Identifier: MIT
```
