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
# not guaranteed to be present on a clean Windows install.
$redistRoot = Join-Path $vs "VC\Redist\MSVC"
if (Test-Path $redistRoot) {
    Get-ChildItem $redistRoot -Filter *.dll -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        $key = $_.Name.ToLowerInvariant()
        if (-not $workspaceDlls.ContainsKey($key)) { $workspaceDlls[$key] = $_.FullName }
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
$queue.Enqueue($exe)
$manifest = [System.Collections.Generic.List[string]]::new()

while ($queue.Count -gt 0) {
    $binary = $queue.Dequeue()
    if (-not $visited.Add($binary)) { continue }
    foreach ($dll in (Get-Imports $binary)) {
        $systemPath = Join-Path $env:WINDIR "System32\$dll"
        if ($dll -like 'api-ms-win-*' -or (Test-Path $systemPath)) {
            $manifest.Add("SYSTEM  $dll")
            continue
        }

        $dest = Join-Path $bin $dll
        if (Test-Path $dest) {
            $manifest.Add("BUNDLED $dll (already present)")
            $queue.Enqueue($dest)
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
        $queue.Enqueue($dest)
    }
}

# If a dynamically linked Qt build is ever used, let windeployqt add the correct platform/plugins.
$windeploy = Get-Command windeployqt -ErrorAction SilentlyContinue
if ($windeploy) {
    $imports = Get-Imports $exe
    if ($imports | Where-Object { $_ -match '^Qt6.*\.dll$' }) {
        & $windeploy.Source --release --no-translations $exe
        if ($LASTEXITCODE -ne 0) { throw "Portable packaging: windeployqt failed" }
        $manifest.Add('QT      windeployqt deployment completed')
    }
}

$manifestPath = Join-Path $bin "RUNTIME_DEPENDENCIES.txt"
@(
    "Portable runtime dependency audit"
    "Generated from dumpbin /dependents; non-system dependencies are bundled recursively."
    ""
) + ($manifest | Sort-Object -Unique) | Set-Content $manifestPath -Encoding UTF8

Write-Host "Portable dependency packaging complete. Copied $($copied.Count) DLL(s)."
Get-ChildItem $bin | Select-Object Name, Length | Format-Table -AutoSize
