$ErrorActionPreference = 'Stop'

$source = Join-Path (Get-Location) 'build\bin'
$destination = Join-Path (Get-Location) 'dist\Eden-NS2-Pokopia-Windows'

if (-not (Test-Path $source -PathType Container)) {
    throw "Windows runtime source directory was not produced: $source"
}

$guiCandidates = @('eglantine.exe', 'eden.exe', 'yuzu.exe')
$gui = $null
foreach ($candidate in $guiCandidates) {
    $candidatePath = Join-Path $source $candidate
    if (Test-Path $candidatePath -PathType Leaf) { $gui = $candidatePath; break }
}
if (-not $gui) {
    $produced = (Get-ChildItem $source -Filter '*.exe' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name) -join ', '
    throw "No Eden GUI executable found in build/bin. Produced executables: $produced"
}

if (Test-Path $destination) { Remove-Item $destination -Recurse -Force }
New-Item -ItemType Directory -Path $destination -Force | Out-Null

# Preserve the complete CMake runtime tree first. This captures anything Eden already deployed,
# including Qt plugins/resources and bundled runtime data, before we fill portable-runtime gaps.
Copy-Item -Path (Join-Path $source '*') -Destination $destination -Recurse -Force

$packagedGui = Join-Path $destination (Split-Path $gui -Leaf)
if (-not (Test-Path $packagedGui -PathType Leaf)) { throw "Packaged GUI executable disappeared: $packagedGui" }
foreach ($note in 'POKOPIA_CONFIG.txt', 'NX2_PERFORMANCE_NOTES.txt') {
    if (-not (Test-Path (Join-Path $destination $note) -PathType Leaf)) { throw "Required NS2 runtime note/config was not packaged: $note" }
}

function Find-RuntimeDependency([string]$name) {
    $roots = @((Join-Path (Get-Location) 'build'), (Join-Path (Get-Location) '.cache'))
    foreach ($root in $roots) {
        if (Test-Path $root -PathType Container) {
            $hit = Get-ChildItem $root -Recurse -Filter $name -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) { return $hit.FullName }
        }
    }
    foreach ($dir in ($env:PATH -split ';')) {
        if (-not [string]::IsNullOrWhiteSpace($dir)) {
            $candidate = Join-Path $dir $name
            if (Test-Path $candidate -PathType Leaf) { return $candidate }
        }
    }
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere -PathType Leaf) {
        $vs = & $vswhere -latest -products * -property installationPath
        if ($vs) {
            $redist = Join-Path $vs 'VC\Redist\MSVC'
            if (Test-Path $redist -PathType Container) {
                $hit = Get-ChildItem $redist -Recurse -Filter $name -File -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($hit) { return $hit.FullName }
            }
        }
    }
    return $null
}

function Stage-Dependency([string]$name, [bool]$required) {
    $already = Get-ChildItem $destination -Recurse -Filter $name -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($already) { return $true }
    $dependency = Find-RuntimeDependency $name
    if ($dependency) {
        Copy-Item $dependency (Join-Path $destination $name) -Force
        Write-Host "Staged runtime dependency: $name from $dependency"
        return $true
    }
    if ($required) { throw "Portable Windows runtime is missing required dependency: $name" }
    Write-Host "Optional runtime dependency not found: $name"
    return $false
}

# Direct imports observed in the consolidated GUI are mandatory on a clean Windows machine.
$portableImports = @(
    'icuuc.dll', 'MSVCP140.dll', 'MSVCP140_ATOMIC_WAIT.dll', 'MSVCP140_CODECVT_IDS.dll',
    'MSVCP140_1.dll', 'VCRUNTIME140.dll', 'VCRUNTIME140_1.dll'
)
foreach ($name in $portableImports) { [void](Stage-Dependency $name $true) }

# Known-working PokeDinner/Eglantine portable packages also carry the DirectX shader compiler
# family. Stage these whenever the build/SDK image provides them. They are optional here because
# not every Eden configuration imports them, but packaging them avoids driver/system dependence
# for runtime shader paths that load them dynamically.
foreach ($name in @('dxcompiler.dll', 'dxil.dll', 'd3dcompiler_47.dll')) {
    [void](Stage-Dependency $name $false)
}

# If Qt is dynamically linked, require the Windows platform plugin. Prefer windeployqt so the
# package gets the exact Qt DLL/plugin graph for this executable instead of copying a stale list.
$qtDlls = @(Get-ChildItem $destination -Filter 'Qt6*.dll' -File -ErrorAction SilentlyContinue)
if ($qtDlls.Count -gt 0) {
    $platformPlugin = @(
        (Join-Path $destination 'plugins\platforms\qwindows.dll'),
        (Join-Path $destination 'platforms\qwindows.dll')
    ) | Where-Object { Test-Path $_ -PathType Leaf } | Select-Object -First 1

    if (-not $platformPlugin) {
        $windeployqt = Get-Command windeployqt.exe -ErrorAction SilentlyContinue
        if (-not $windeployqt) {
            $windeployqt = Get-ChildItem (Join-Path (Get-Location) 'build') -Recurse -Filter windeployqt.exe -File -ErrorAction SilentlyContinue | Select-Object -First 1
        }
        if ($windeployqt) {
            $deployExe = if ($windeployqt.Source) { $windeployqt.Source } else { $windeployqt.FullName }
            & $deployExe --no-translations --compiler-runtime $packagedGui
            if ($LASTEXITCODE -ne 0) { throw 'windeployqt failed while strengthening portable runtime.' }
        }
    }

    $platformPlugin = @(
        (Join-Path $destination 'plugins\platforms\qwindows.dll'),
        (Join-Path $destination 'platforms\qwindows.dll')
    ) | Where-Object { Test-Path $_ -PathType Leaf } | Select-Object -First 1
    if (-not $platformPlugin) { throw 'Qt6 DLLs are present but qwindows.dll is missing; the portable package would not launch.' }
}

$dlls = @(Get-ChildItem $destination -Filter '*.dll' -File -Recurse -ErrorAction SilentlyContinue)
if ($qtDlls.Count -gt 0 -and $dlls.Count -lt 5) { throw "Dynamic Qt runtime appears incomplete: only $($dlls.Count) DLL(s) were packaged." }

# Explicitly report useful companion executables rather than requiring them: the current CI builds
# the GUI target only, while known-working distributions may additionally build CLI/room targets.
foreach ($companion in @('eden-cli.exe', 'eden-room.exe')) {
    if (Test-Path (Join-Path $destination $companion) -PathType Leaf) { Write-Host "Packaged companion executable: $companion" }
    else { Write-Host "Companion executable not produced by this build: $companion" }
}

$manifestPath = Join-Path $destination 'RUNTIME_MANIFEST.txt'
$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("Packaged from automation commit: $env:GITHUB_SHA")
$lines.Add("GUI executable: $(Split-Path $packagedGui -Leaf)")
$lines.Add("Runtime DLL count: $($dlls.Count)")
$lines.Add('')
$lines.Add('Files:')
Get-ChildItem $destination -File -Recurse | Where-Object { $_.FullName -ne $manifestPath } | Sort-Object FullName | ForEach-Object {
    $relative = [IO.Path]::GetRelativePath($destination, $_.FullName)
    $lines.Add("$relative`t$($_.Length)")
}
$lines | Set-Content -Path $manifestPath -Encoding UTF8

Write-Host "Portable NS2 runtime staged at $destination"
Write-Host "GUI: $(Split-Path $packagedGui -Leaf)"
Write-Host "DLLs: $($dlls.Count)"
Write-Host "Files: $((Get-ChildItem $destination -File -Recurse).Count)"
