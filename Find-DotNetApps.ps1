# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Gary Palmer
<#
.SYNOPSIS
Scans a folder for .exe/.dll files and determines .NET runtime usage.

.DESCRIPTION
Uses staged detection:
1) runtimeconfig.json
2) bundled runtime files
3) deps.json
4) single-file heuristics
5) reflection fallback

Designed for PowerShell 5.1+ on standard Windows installs.

.VERSION 1.0

.PARAMETER Path
Root folder to scan. Mandatory.

.PARAMETER IgnoreSubDirs
If specified, do not scan subfolders recursively.

.PARAMETER IncludeNative
If specified, includes native (non-.NET) binaries when scanning.

.PARAMETER OutputFile
If specified, exports results to CSV at this path.

.PARAMETER IncludeSummary
If specified, prints runtime usage summary after scan.

.PARAMETER ShowProgress
If specified, displays a progress bar while scanning files.

.EXAMPLE
.\Find-DotNetApps.ps1 -Path C:\Apps -IgnoreSubDirs -IncludeSummary -ShowProgress -Verbose
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Path,

    [switch]$IgnoreSubDirs,

    [Parameter(Mandatory = $true)]
    [string]$OutputFile,

    [switch]$IncludeSummary,

    [switch]$IncludeNative,

    [switch]$ShowProgress 
)

$DebugPreference = "Continue"
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-IgnoredPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FullPath
    )
    $normalized = $FullPath.ToLowerInvariant()
    return (
        $normalized.StartsWith('c:\windows\') -or
        $normalized -eq 'c:\windows' -or
        $normalized.StartsWith('c:\windows\winsxs\') -or
        $normalized -eq 'c:\windows\winsxs'
    )
}

function Get-FileMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File
    )

    $appName = [System.IO.Path]::GetFileNameWithoutExtension($File.Name)
    $appVersion = 'Unknown'

    try {
        $vi = (Get-Item -LiteralPath $File.FullName -ErrorAction Stop).VersionInfo

        if ($vi -and -not [string]::IsNullOrWhiteSpace($vi.ProductName)) {
            $appName = Repair-Mojibake -Text $vi.ProductName
        }

        if ($vi -and -not [string]::IsNullOrWhiteSpace($vi.ProductVersion)) {
            $appVersion = Repair-Mojibake -Text $vi.ProductVersion
        }
        elseif ($vi -and -not [string]::INullOrWhiteSpace($vi.FileVersion)) {
            $appVersion = Repair-Mojibake -Text $vi.FileVersion
        }
    }
    catch {
        Write-Verbose "Metadata read failed for '$($File.FullName)': $($_.Exception.Message)"
    }

    [pscustomobject]@{
        ApplicationName    = $appName
        ApplicationVersion = $appVersion
    }
}

function Get-TargetFrameworkFromTFM {
    param([string]$Tfm)

    if ([string]::IsNullOrWhiteSpace($Tfm)) { return 'Unknown' }

    $t = $Tfm.Trim().ToLowerInvariant()

    switch -Regex ($t) {
        '^netcoreapp3\.1$' { return 'netcoreapp3.1' }
        '^netstandard2\.0$' { return 'netstandard2.0' }
        '^netstandard2\.1$' { return 'netstandard2.1' }
        '^net[5-9]\.0$' { return $t }
        '^net4(0|5|51|52|6|61|62|7|71|72|8|81)$' {
            # Examples: net40 -> v4.0, net48 -> v4.8, net481 -> v4.8.1
            $suffix = $t.Substring(3)
            if ($suffix.Length -eq 2) { return "v$($suffix[0]).$($suffix[1])" }
            if ($suffix.Length -eq 3) { return "v$($suffix[0]).$($suffix[1]).$($suffix[2])" }
            return 'v4.x'
        }
        '^net(20|30|35)$' {
            $suffix = $t.Substring(3)
            return "v$($suffix[0]).$($suffix[1])"
        }
        default { return $Tfm }
    }
}

function Get-TargetFrameworkFromFrameworkName {
    param([string]$FrameworkName)

    if ([string]::IsNullOrWhiteSpace($FrameworkName)) { return 'Unknown' }

    # .NETFramework,Version=v4.8
    # .NETCoreApp,Version=v8.0
    # .NETStandard,Version=v2.0
    if ($FrameworkName -match '^\s*\.NETFramework,\s*Version=v(?<v>[\d\.]+)\s*$') {
        return "v$($Matches.v)"
    }
    if ($FrameworkName -match '^\s*\.NETCoreApp,\s*Version=v(?<v>[\d\.]+)\s*$') {
        return "net$($Matches.v)"
    }
    if ($FrameworkName -match '^\s*\.NETStandard,\s*Version=v(?<v>[\d\.]+)\s*$') {
        return "netstandard$($Matches.v)"
    }

    return $FrameworkName
}

function Get-BundledRuntimeVersionFromFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DirectoryPath
    )

    $candidates = @('coreclr.dll', 'hostfxr.dll', 'System.Private.CoreLib.dll')
    foreach ($c in $candidates) {
        $fp = Join-Path -Path $DirectoryPath -ChildPath $c
        if (Test-Path -LiteralPath $fp -PathType Leaf) {
            try {
                $ver = (Get-Item -LiteralPath $fp -ErrorAction Stop).VersionInfo.ProductVersion
                if (-not [string]::IsNullOrWhiteSpace($ver)) {
                    return $ver
                }
            }
            catch {
                Write-Verbose "Failed reading runtime version from '$fp': $($_.Exception.Message)"
            }
        }
    }

    return 'Unknown'
}

function Test-BundledRuntimeFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DirectoryPath
    )

    $files = @('coreclr.dll', 'hostfxr.dll', 'hostpolicy.dll', 'System.Private.CoreLib.dll')
    foreach ($f in $files) {
        $fp = Join-Path -Path $DirectoryPath -ChildPath $f
        if (Test-Path -LiteralPath $fp -PathType Leaf) {
            return $true
        }
    }
    return $false
}

function Get-TargetFrameworkFromRuntimeVersion {
    param(
        [AllowNull()]
        [string]$RuntimeVersion
    )

    if ([string]::IsNullOrWhiteSpace($RuntimeVersion)) { return 'Unknown' }

    $raw = $RuntimeVersion.Trim()

    # Fast rejects
    if ($raw -match '^(?i)(n/?a|na|unknown|none|-)$') {
        return 'Unknown'
    }

    # Normalize decimal separators for patterns like:
    # 7,0,523,17405 @Commit: ...
    # 10,0,926,27113 @Commit: ...
    $normalized = $raw -replace ',', '.'

    # Extract first major.minor pair found anywhere in the string
    # e.g. "7.0.523.17405 @Commit..." => major=7 minor=0
    if ($normalized -match '(?<maj>\d+)\.(?<min>\d+)') {
        $maj = [int]$Matches.maj
        $min = [int]$Matches.min

        # .NET Core 3.1
        if ($maj -eq 3 -and $min -eq 1) {
            return 'netcoreapp3.1'
        }

        # .NET 5+ mapping (including future majors)
        if ($maj -ge 5) {
            return "net$maj.0"
        }

        return 'Unknown'
    }

    # Fallback: if only a major is present (rare/noisy)
    if ($normalized -match '(?<maj>\d+)') {
        $maj = [int]$Matches.maj
        if ($maj -ge 5) {
            return "net$maj.0"
        }
    }

    return 'Unknown'
}

function Get-InfoFromRuntimeConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RuntimeConfigPath
    )

    try {
        $raw = Get-Content -LiteralPath $RuntimeConfigPath -Raw -ErrorAction Stop
        $json = $raw | ConvertFrom-Json -ErrorAction Stop

        $tfm = $null
        $fxName = $null
        $fxVersion = $null

        if ($json.runtimeOptions) {
            $tfm = $json.runtimeOptions.tfm
            if ($json.runtimeOptions.framework) {
                $fxName = $json.runtimeOptions.framework.name
                $fxVersion = $json.runtimeOptions.framework.version
            }
        }

        [pscustomobject]@{
            Found            = $true
            TargetFramework  = (Get-TargetFrameworkFromTFM -Tfm $tfm)
            FrameworkName    = $fxName
            FrameworkVersion = $fxVersion
        }
    }
    catch {
        Write-Verbose "runtimeconfig parse failed '$RuntimeConfigPath': $($_.Exception.Message)"
        [pscustomobject]@{
            Found            = $false
            TargetFramework  = 'Unknown'
            FrameworkName    = $null
            FrameworkVersion = $null
        }
    }
}

function Get-InfoFromDepsJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DepsJsonPath
    )

    $runtimeVersion = $null
    $targetFramework = $null

    try {
        $raw = Get-Content -LiteralPath $DepsJsonPath -Raw -ErrorAction Stop
        $json = $raw | ConvertFrom-Json -ErrorAction Stop

        # targets key often like ".NETCoreApp,Version=v8.0/win-x64"
        if ($json.targets) {
            $targetKeys = @($json.targets.PSObject.Properties.Name)
            if ($targetKeys.Count -gt 0) {
                $firstTarget = $targetKeys[0]
                if ($firstTarget -match '\.NETCoreApp,Version=v(?<v>\d+\.\d+)') {
                    $targetFramework = "net$($Matches.v)"
                }
                elseif ($firstTarget -match '\.NETStandard,Version=v(?<v>\d+\.\d+)') {
                    $targetFramework = "netstandard$($Matches.v)"
                }
                elseif ($firstTarget -match '\.NETFramework,Version=v(?<v>[\d\.]+)') {
                    $targetFramework = "v$($Matches.v)"
                }
            }
        }

        $propNames = @()
        if ($json.libraries) {
            $propNames = @($json.libraries.PSObject.Properties.Name)
        }

        foreach ($name in $propNames) {
            if ($name -match '^Microsoft\.NETCore\.App\.Runtime\.[^\/]+\/(?<ver>[\d\.]+)$') {
                $runtimeVersion = $Matches.ver
                break
            }
            if ($name -match '^Microsoft\.WindowsDesktop\.App\.Runtime\.[^\/]+\/(?<ver>[\d\.]+)$') {
                $runtimeVersion = $Matches.ver
                break
            }
        }
    }
    catch {
        Write-Verbose "deps.json parse failed '$DepsJsonPath': $($_.Exception.Message)"
    }

    [pscustomobject]@{
        RuntimeVersion  = if ($runtimeVersion) { $runtimeVersion } else { $null }
        TargetFramework = if ($targetFramework) { $targetFramework } else { $null }
    }
}

function Get-ReflectionTargetFramework {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AssemblyPath
    )

    try {
        # Step 5 fallback: only called when earlier checks fail.
        $an = [Reflection.AssemblyName]::GetAssemblyName($AssemblyPath)
        if (-not $an) {
            return $null
        }

        $asm = [Reflection.Assembly]::ReflectionOnlyLoadFrom($AssemblyPath)

        $cad = [Reflection.CustomAttributeData]::GetCustomAttributes($asm) |
        Where-Object { $_.AttributeType.FullName -eq 'System.Runtime.Versioning.TargetFrameworkAttribute' } |
        Select-Object -First 1

        if ($cad -and $cad.ConstructorArguments.Count -gt 0) {
            $frameworkName = [string]$cad.ConstructorArguments[0].Value
            return (Get-TargetFrameworkFromFrameworkName -FrameworkName $frameworkName)
        }

        return 'Managed (framework unknown)'
    }
    catch {
        Write-Verbose "Reflection failed for '$AssemblyPath': $($_.Exception.Message)"
        return $null
    }
}


function Repair-Mojibake {
    param(
        [AllowNull()]
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $Text
    }

    # Common quick fixes first
    $fixed = $Text `
        -replace 'Â®', '®' `
        -replace 'Â©', '©' `
        -replace 'â„¢', '™' `
        -replace 'â€“', '–' `
        -replace 'â€”', '—' `
        -replace 'â€¦', '…' `
        -replace 'â€˜', "'" `
        -replace 'â€™', "'" `
        -replace 'â€œ', '“' `
        -replace 'â€', '”'

    # If still suspicious, attempt Latin1->UTF8 reinterpretation
    if ($fixed -match '[Ââ]') {
        try {
            $bytes = [System.Text.Encoding]::GetEncoding(28591).GetBytes($fixed) # ISO-8859-1 / Latin1
            $roundTrip = [System.Text.Encoding]::UTF8.GetString($bytes)
            if (-not [string]::IsNullOrWhiteSpace($roundTrip)) {
                $fixed = $roundTrip
            }
        }
        catch {
            # keep existing value
        }
    }

    return $fixed.Trim()
}


function Find-DotNetUsage {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File
    )

    $meta = Get-FileMetadata -File $File
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($File.Name)
    $dir = $File.DirectoryName

    $runtimeConfigPath = Join-Path -Path $dir -ChildPath ($baseName + '.runtimeconfig.json')
    $depsPath = Join-Path -Path $dir -ChildPath ($baseName + '.deps.json')

    $deployment = 'Native'
    $tfm = 'N/A'
    $bundledRuntime = $false
    $bundledRuntimeVersion = 'N/A'
    $method = 'None'

    # STEP 1 - runtimeconfig.json
    $rcInfo = $null
    if (Test-Path -LiteralPath $runtimeConfigPath -PathType Leaf) {
        Write-Verbose "STEP1 runtimeconfig found: $runtimeConfigPath"
        $rcInfo = Get-InfoFromRuntimeConfig -RuntimeConfigPath $runtimeConfigPath
        if ($rcInfo.Found) {
            $tfm = if ($rcInfo.TargetFramework) { $rcInfo.TargetFramework } else { 'Unknown' }

            $hasBundledFiles = Test-BundledRuntimeFiles -DirectoryPath $dir
            if ($hasBundledFiles) {
                $deployment = '.NET Core / .NET 5+ Self-contained'
                $bundledRuntime = $true
                $bundledRuntimeVersion = Get-BundledRuntimeVersionFromFiles -DirectoryPath $dir
                $tfmFromBundled = Get-TargetFrameworkFromRuntimeVersion -RuntimeVersion $bundledRuntimeVersion
                if ($tfmFromBundled -ne 'Unknown') {
                    $tfm = $tfmFromBundled
                }
            }
            else {
                $deployment = '.NET Core / .NET 5+ Framework-dependent'
                $bundledRuntime = $false
                if (-not [string]::IsNullOrWhiteSpace($rcInfo.FrameworkVersion)) {
                    $bundledRuntimeVersion = $rcInfo.FrameworkVersion
                }
                else {
                    $bundledRuntimeVersion = 'N/A'
                }
            }

            $method = 'runtimeconfig.json'
        }
    }

    # STEP 2 - bundled runtime files
    if ($method -eq 'None') {
        $hasBundledFiles = Test-BundledRuntimeFiles -DirectoryPath $dir
        if ($hasBundledFiles) {
            Write-Verbose "STEP2 bundled runtime files found in: $dir"
            $deployment = '.NET Core / .NET 5+ Self-contained'
            $bundledRuntime = $true
            $bundledRuntimeVersion = Get-BundledRuntimeVersionFromFiles -DirectoryPath $dir
            $tfm = Get-TargetFrameworkFromRuntimeVersion -RuntimeVersion $bundledRuntimeVersion
            $method = 'Bundled runtime files'
        }
    }

    # STEP 3 - deps.json
    if ($method -eq 'None' -and (Test-Path -LiteralPath $depsPath -PathType Leaf)) {
        Write-Verbose "STEP3 deps.json found: $depsPath"
        $deps = Get-InfoFromDepsJson -DepsJsonPath $depsPath
        if ($deps.RuntimeVersion -or $deps.TargetFramework) {
            $deployment = '.NET Core / .NET 5+ Framework-dependent'
            $bundledRuntime = $false
            $bundledRuntimeVersion = if ($deps.RuntimeVersion) { $deps.RuntimeVersion } else { 'N/A' }
            $tfm = if ($deps.TargetFramework) { $deps.TargetFramework } else { 'Unknown' }
            $method = 'deps.json'
        }
    }

    # STEP 4 - single-file heuristic
    if ($method -eq 'None' -and $File.Extension -ieq '.exe') {
        # Heuristic: managed-like apphost with no sidecar runtimeconfig/deps and no bundle files.
        # True bundle metadata parsing is not available in PS 5.1 without external tooling.
        try {
            $fs = [System.IO.File]::Open($File.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try {
                $bytesToRead = [Math]::Min(65536, [int]$fs.Length)
                $buffer = New-Object byte[] $bytesToRead
                [void]$fs.Read($buffer, 0, $bytesToRead)
                $sig = [System.Text.Encoding]::ASCII.GetString($buffer)

                if ($sig -match 'DOTNETBUNDLE|hostfxr|System\.Private\.CoreLib') {
                    Write-Verbose "STEP4 single-file heuristic matched: $($File.FullName)"
                    $deployment = 'Self-contained (single-file unknown)'
                    $bundledRuntime = $true
                    $bundledRuntimeVersion = 'Unknown'
                    $tfm = 'Unknown'
                    $method = 'Single-file heuristic'
                }
            }
            finally {
                $fs.Dispose()
            }
        }
        catch {
            Write-Verbose "Single-file heuristic skipped for '$($File.FullName)': $($_.Exception.Message)"
        }
    }

    # STEP 5 - reflection fallback
    if ($method -eq 'None') {
        Write-Verbose "STEP5 reflection fallback: $($File.FullName)"
        $rtfm = Get-ReflectionTargetFramework -AssemblyPath $File.FullName
        if ($rtfm) {
            $tfm = $rtfm
            $method = 'Reflection'

            if ($tfm -match '^v\d') {
                $deployment = '.NET Framework'
                $bundledRuntime = $false
                $bundledRuntimeVersion = 'N/A'
            }
            elseif ($tfm -match '^net(coreapp3\.1|[5-9]\.0)') {
                $deployment = '.NET Core / .NET 5+ Framework-dependent'
                $bundledRuntime = $false
                $bundledRuntimeVersion = 'N/A'
            }
            elseif ($tfm -match '^netstandard') {
                $deployment = '.NET Standard (library)'
                $bundledRuntime = $false
                $bundledRuntimeVersion = 'N/A'
            }
            else {
                $deployment = 'Managed (unknown runtime)'
                $bundledRuntime = $false
                $bundledRuntimeVersion = 'N/A'
            }
        }
        else {
            $deployment = 'Native'
            $tfm = 'N/A'
            $bundledRuntime = $false
            $bundledRuntimeVersion = 'N/A'
            $method = 'None'
        }
    }

    if (-not $IncludeNative -and $deployment -eq 'Native') {
        Write-Verbose "Ignoring native binary: $($File.FullName)"
        return $null
    }


    [pscustomobject]@{
        'Application Name'        = $meta.ApplicationName
        'Application Version'     = $meta.ApplicationVersion
        'Exe Name'                = $File.Name
        'Full Path'               = $File.FullName
        'Deployment'              = $deployment
        'Target Framework'        = $tfm
        'Bundled Runtime'         = $bundledRuntime
        'Bundled Runtime Version' = $bundledRuntimeVersion
        'Detection Method'        = $method
    }
}

function Show-RuntimeSummary {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[object]]$Results
    )

    Write-Host ''
    Write-Host '.NET Runtime Usage Summary'
    Write-Host '--------------------------'

    $groups = @{}

    foreach ($r in $Results) {
        $key = $null

        if ($r.Deployment -eq '.NET Framework' -and $r.'Target Framework' -match '^v') {
            $key = ".NET Framework $($r.'Target Framework'.TrimStart('v'))"
        }
        elseif ($r.'Bundled Runtime Version' -and $r.'Bundled Runtime Version' -ne 'N/A' -and $r.'Bundled Runtime Version' -ne 'Unknown') {
            $maj = ($r.'Bundled Runtime Version' -split '\.')[0]
            if ($maj -match '^\d+$') {
                $key = ".NET $maj Runtime"
            }
        }
        elseif ($r.'Target Framework' -match '^net([5-9])\.0$') {
            $key = ".NET $($Matches[1]) Runtime"
        }
        elseif ($r.'Target Framework' -eq 'netcoreapp3.1') {
            $key = '.NET Core 3.1 Runtime'
        }

        if (-not $key) { continue }

        if (-not $groups.ContainsKey($key)) {
            $groups[$key] = New-Object System.Collections.Generic.List[string]
        }
        $groups[$key].Add($r.'Full Path')
    }

    $sortedKeys = $groups.Keys | Sort-Object
    if (-not $sortedKeys -or $sortedKeys.Count -eq 0) {
        Write-Host 'No .NET runtime usage detected.'
        return
    }

    foreach ($k in $sortedKeys) {
        Write-Host ''
        Write-Host $k
        $apps = $groups[$k] | Sort-Object -Unique
        if ($apps.Count -gt 0) {
            Write-Host 'Applications:'
            foreach ($a in $apps) {
                Write-Host "  $a"
            }
        }
        else {
            Write-Host 'No applications detected'
        }
    }
}

# ====================================================================================================================
# == Main ============================================================================================================
# ====================================================================================================================
try {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Path not found or not a directory: $Path"
    }

    $resolvedRoot = (Resolve-Path -LiteralPath $Path).Path
    if (Test-IgnoredPath -FullPath $resolvedRoot) {
        throw "The specified path is ignored by policy: $resolvedRoot"
    }

    Write-Host "PowerShell bitness: $([IntPtr]::Size * 8)-bit"
    Write-Host "Scanning root: $resolvedRoot"
    Write-Host "Recurse: $(-not $IgnoreSubDirs.IsPresent)"

    $gciParams = @{
        LiteralPath = $resolvedRoot
        File        = $true
        Include     = @('*.exe', '*.dll')
        ErrorAction = 'SilentlyContinue'
        Force       = $false
    }
    if (-not $IgnoreSubDirs) {
        $gciParams['Recurse'] = $true
    }

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $results = New-Object 'System.Collections.Generic.List[object]'

    $files = @(Get-ChildItem @gciParams)
    $totalFiles = $files.Count
    $processed = 0

    foreach ($f in $files) {
        $processed++

        if ($ShowProgress -and $totalFiles -gt 0) {
            $pct = [int](($processed / $totalFiles) * 100)
            Write-Progress -Id 1 `
                -Activity "Scanning .NET applications" `
                -Status ("{0}% ({1}/{2}) - {3}" -f $pct, $processed, $totalFiles, $f.Directory) `
                -PercentComplete $pct
        }

        try {
            if (Test-IgnoredPath -FullPath $f.FullName) {
                Write-Verbose "Skipping ignored path: $($f.FullName)"
                continue
            }

            if (-not $seen.Add($f.FullName)) {
                continue
            }

            $result = Find-DotNetUsage -File $f

            if ($null -ne $result) {
                $results.Add($result) | Out-Null
            }
            
        }
        catch [System.UnauthorizedAccessException] {
            Write-Verbose "Access denied: $($f.FullName)"
            continue
        }
        catch [System.IO.IOException] {
            Write-Verbose "I/O/locked file issue: $($f.FullName) - $($_.Exception.Message)"
            continue
        }
        catch {
            Write-Verbose "Failed processing '$($f.FullName)': $($_.Exception.Message)"
            continue
        }
    }

    if ($ShowProgress) {
        Write-Progress -Id 1 -Activity "Scanning .NET applications" -Completed
    }

    if ($OutputFile) {
        if ($results.Count -gt 0) {
            try {
                $parent = Split-Path -Path $OutputFile -Parent
                if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
                    New-Item -Path $parent -ItemType Directory -Force | Out-Null
                }

                $psMajor = $PSVersionTable.PSVersion.Major
                $encoding = if ($psMajor -ge 7) { 'utf8BOM' } else { 'UTF8' }


                $results |
                Select-Object 'Application Name', 'Application Version', 'Exe Name', 'Full Path', 'Deployment', 'Target Framework', 'Bundled Runtime', 'Bundled Runtime Version', 'Detection Method' |
                Export-Csv -LiteralPath $OutputFile -NoTypeInformation -Encoding $encoding

                Write-Host "Results exported to: $OutputFile"
            }
            catch {
                throw "Failed to write CSV output '$OutputFile': $($_.Exception.Message)"
            }
        }
        else {
            Write-Warning "No results found. CSV was not created: $OutputFile"
        }
    }
    else {
        if ($results.Count -gt 0) {
            $results |
            Select-Object 'Application Name', 'Application Version', 'Exe Name', 'Full Path', 'Deployment', 'Target Framework', 'Bundled Runtime', 'Bundled Runtime Version', 'Detection Method' |
            Format-Table -AutoSize
        }
        else {
            Write-Warning "No results found."
        }
    }

    if ($IncludeSummary) {
        Show-RuntimeSummary -Results $results
    }
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}