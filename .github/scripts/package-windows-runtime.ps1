param(
    [string]$BinDir = "build/bin"
)

$ErrorActionPreference = "Stop"

$bin = Resolve-Path $BinDir
$exe = Join-Path $bin "eglantine.exe"
if (-not (Test-Path $exe)) { throw "Portable packaging: missing $exe" }

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw "Portable packaging: Visual Studio C++ toolchain not found" }
$devcmd = Join-Path $vs "Common7\Tools\VsDevCmd.bat"

# Build a one-time index of candidate DLLs produced/downloaded during the build.
$workspaceDlls = @{}
Get-ChildItem $env:GITHUB_WORKSPACE -Filter *.dll -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
    $key = $_.Name.ToLowerInvariant()
    if (-not $workspaceDlls.ContainsKey($key)) { $workspaceDlls[$key] = $_.FullName }
}

# Add MSVC redistributable DLLs as candidates. These are imported by our MSVC build and are
# not guaranteed to be present on a clean Windows install. Prefer the matching toolchain redist
# over incidental copies elsewhere in the workspace.
$redistRoot = Join-Path $vs "VC\Redist\MSVC"
if (Test-Path $redistRoot) {
    Get-ChildItem $redistRoot -Filter *.dll -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        $key = $_.Name.ToLowerInvariant()
        if ($key -like 'msvcp*.dll' -or $key -like 'vcruntime*.dll') {
            $workspaceDlls[$key] = $_.FullName
        } elseif (-not $workspaceDlls.ContainsKey($key)) {
            $workspaceDlls[$key] = $_.FullName
        }
    }
}

# PATH is a final source for dependency DLLs installed on the runner (for example ICU).
foreach ($dir in ($env:PATH -split ';')) {
    if (-not $dir -or -not (Test-Path $dir)) { continue }
    Get-ChildItem $dir -Filter *.dll -File -ErrorAction SilentlyContinue | ForEach-Object {
        $key = $_.Name.ToLowerInvariant()
        if (-not $workspaceDlls.ContainsKey($key)) { $workspaceDlls[$key] = $_.FullName }
    }
}

function Get-Imports([string]$Path) {
    $escaped = $Path.Replace('"', '""')
    $output = cmd /c "`"$devcmd`" -arch=x64 -host_arch=x64 >nul && dumpbin /nologo /dependents `"$escaped`"" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Portable packaging: dumpbin failed for $Path" }
    return @($output | ForEach-Object {
        if ($_ -match '^\s+([^\s]+\.dll)\s*$') { $matches[1] }
    } | Where-Object { $_ } | Sort-Object -Unique)
}

$copied = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$visited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$queue = [System.Collections.Generic.Queue[string]]::new()
$manifest = [System.Collections.Generic.List[string]]::new()

function Queue-Binary([string]$Path) {
    if (Test-Path $Path) { $queue.Enqueue((Resolve-Path $Path).Path) }
}

function Resolve-QueuedDependencies {
    while ($queue.Count -gt 0) {
        $binary = $queue.Dequeue()
        if (-not $visited.Add($binary)) { continue }
        foreach ($dll in (Get-Imports $binary)) {
            $systemPath = Join-Path $env:WINDIR "System32\$dll"
            $isMsvcRuntime = $dll -like 'MSVCP*.dll' -or $dll -like 'VCRUNTIME*.dll'
            if (-not $isMsvcRuntime -and ($dll -like 'api-ms-win-*' -or (Test-Path $systemPath))) {
                $manifest.Add("SYSTEM  $dll")
                continue
            }

            $dest = Join-Path $bin $dll
            if (Test-Path $dest) {
                $manifest.Add("BUNDLED $dll (already present)")
                Queue-Binary $dest
                continue
            }

            $key = $dll.ToLowerInvariant()
            if (-not $workspaceDlls.ContainsKey($key)) {
                throw "Portable packaging: unresolved non-system dependency $dll required by $binary"
            }

            $source = $workspaceDlls[$key]
            Copy-Item $source $dest -Force
            $copied.Add($dll) | Out-Null
            $manifest.Add("BUNDLED $dll <= $source")
            Write-Host "Bundled runtime dependency: $dll"
            Queue-Binary $dest
        }
    }
}

# First audit the executable itself and recursively bundle its direct runtime dependencies.
$exeImports = Get-Imports $exe
Queue-Binary $exe
Resolve-QueuedDependencies

# Bundled Qt is static on the MSVC build, so it does not require the large plugin-folder layout
# seen in dynamically deployed Qt packages. If a future build imports Qt6 DLLs, require the matching
# windeployqt and then recursively audit every DLL/plugin it adds as well.
$dynamicQtImports = @($exeImports | Where-Object { $_ -match '^Qt6.*\.dll$' })
if ($dynamicQtImports.Count -gt 0) {
    $manifest.Add('QT      dynamic Qt detected')
    $windeploy = Get-Command windeployqt -ErrorAction SilentlyContinue
    if (-not $windeploy) {
        throw "Portable packaging: dynamic Qt imports detected but windeployqt is unavailable"
    }
    & $windeploy.Source --release --no-translations $exe
    if ($LASTEXITCODE -ne 0) { throw "Portable packaging: windeployqt failed" }
    $manifest.Add('QT      windeployqt deployment completed')

    # windeployqt may add platforms/, styles/, imageformats/, tls/, etc. Audit the DLLs inside those
    # folders too so plugin dependencies cannot be silently omitted.
    Get-ChildItem $bin -Filter *.dll -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        Queue-Binary $_.FullName
    }
    Resolve-QueuedDependencies
} else {
    $manifest.Add('QT      no Qt6 DLL imports; bundled/static Qt layout does not require deployment folders')
}

# Verify every packaged non-system binary is internally resolvable after deployment.
Get-ChildItem $bin -Include *.exe,*.dll -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
    foreach ($dll in (Get-Imports $_.FullName)) {
        $systemPath = Join-Path $env:WINDIR "System32\$dll"
        $isMsvcRuntime = $dll -like 'MSVCP*.dll' -or $dll -like 'VCRUNTIME*.dll'
        $local = Get-ChildItem $bin -Filter $dll -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($isMsvcRuntime -and -not $local) {
            throw "Portable packaging verification: MSVC runtime $dll not bundled for $($_.Name)"
        }
        if (-not $local -and -not ($dll -like 'api-ms-win-*') -and -not (Test-Path $systemPath)) {
            throw "Portable packaging verification: unresolved dependency $dll required by $($_.FullName)"
        }
    }
}

$manifestPath = Join-Path $bin "RUNTIME_DEPENDENCIES.txt"
@(
    "Portable runtime dependency audit"
    "Generated from dumpbin /dependents; non-system dependencies are bundled recursively."
    ""
) + ($manifest | Sort-Object -Unique) | Set-Content $manifestPath -Encoding UTF8

# Record the complete relative package tree. This lets us compare our static layout with parent
# releases that may have many Qt plugin folders without assuming that a higher folder count is better.
$layoutPath = Join-Path $bin "PACKAGE_LAYOUT.txt"
$binPath = $bin.Path.TrimEnd('\')
@(
    "Eden NS2 Pokopia portable package layout"
    "Files and folders are listed relative to build/bin."
    ""
) + (Get-ChildItem $bin -Recurse -Force | ForEach-Object {
    $relative = $_.FullName.Substring($binPath.Length).TrimStart('\')
    if ($_.PSIsContainer) { "DIR   $relative\" } else { "FILE  $relative  $($_.Length) bytes" }
} | Sort-Object) | Set-Content $layoutPath -Encoding UTF8

Write-Host "Portable dependency packaging complete. Copied $($copied.Count) DLL(s)."
Write-Host "Qt mode: $(if ($dynamicQtImports.Count -gt 0) { 'dynamic/deployed' } else { 'bundled/static' })"
Get-ChildItem $bin | Select-Object Name, Length | Format-Table -AutoSize
