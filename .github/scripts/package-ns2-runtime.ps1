$ErrorActionPreference = 'Stop'

$source = Join-Path (Get-Location) 'build\bin'
$destination = Join-Path (Get-Location) 'dist\Eden-NS2-Pokopia-Windows'

if (-not (Test-Path $source -PathType Container)) {
    throw "Windows runtime source directory was not produced: $source"
}

# Eden/Eglantine revisions have used several product executable names while the CMake target
# remained `yuzu`. Package by what was actually produced, but insist on a GUI executable.
$guiCandidates = @('eglantine.exe', 'eden.exe', 'yuzu.exe')
$gui = $null
foreach ($candidate in $guiCandidates) {
    $candidatePath = Join-Path $source $candidate
    if (Test-Path $candidatePath -PathType Leaf) {
        $gui = $candidatePath
        break
    }
}
if (-not $gui) {
    $produced = (Get-ChildItem $source -Filter '*.exe' -File -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty Name) -join ', '
    throw "No Eden GUI executable found in build/bin. Produced executables: $produced"
}

if (Test-Path $destination) {
    Remove-Item $destination -Recurse -Force
}
New-Item -ItemType Directory -Path $destination -Force | Out-Null

# Copy the complete CMake runtime tree. This deliberately includes Qt DLLs/plugins deployed by
# Eden's POST_BUILD windeployqt hook, bundled-FFmpeg output, resources, translations that the build
# elected to keep, and any future runtime dependency rather than maintaining a brittle DLL list.
Copy-Item -Path (Join-Path $source '*') -Destination $destination -Recurse -Force

$packagedGui = Join-Path $destination (Split-Path $gui -Leaf)
if (-not (Test-Path $packagedGui -PathType Leaf)) {
    throw "Packaged GUI executable disappeared: $packagedGui"
}

foreach ($note in 'POKOPIA_CONFIG.txt', 'NX2_PERFORMANCE_NOTES.txt') {
    if (-not (Test-Path (Join-Path $destination $note) -PathType Leaf)) {
        throw "Required NS2 runtime note/config was not packaged: $note"
    }
}

# The MSVC build can be mostly static while still importing ICU and the Visual C++ runtime. The
# previous package accepted zero DLLs and therefore produced an archive that could compile cleanly
# yet fail to launch on a clean Windows machine. Stage the directly imported non-system runtime
# dependencies when they are available in the build/dependency tree or Visual Studio redist tree.
function Find-RuntimeDependency([string]$name) {
    $roots = @(
        (Join-Path (Get-Location) 'build'),
        (Join-Path (Get-Location) '.cache')
    )
    foreach ($root in $roots) {
        if (Test-Path $root -PathType Container) {
            $hit = Get-ChildItem $root -Recurse -Filter $name -File -ErrorAction SilentlyContinue |
                Select-Object -First 1
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
                $hit = Get-ChildItem $redist -Recurse -Filter $name -File -ErrorAction SilentlyContinue |
                    Select-Object -First 1
                if ($hit) { return $hit.FullName }
            }
        }
    }
    return $null
}

$portableImports = @(
    'icuuc.dll',
    'MSVCP140.dll',
    'MSVCP140_ATOMIC_WAIT.dll',
    'MSVCP140_CODECVT_IDS.dll',
    'MSVCP140_1.dll',
    'VCRUNTIME140.dll',
    'VCRUNTIME140_1.dll'
)
$missingPortableImports = [System.Collections.Generic.List[string]]::new()
foreach ($name in $portableImports) {
    $already = Get-ChildItem $destination -Recurse -Filter $name -File -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($already) { continue }
    $dependency = Find-RuntimeDependency $name
    if ($dependency) {
        Copy-Item $dependency (Join-Path $destination $name) -Force
        Write-Host "Staged runtime dependency: $name from $dependency"
    } else {
        $missingPortableImports.Add($name)
    }
}
if ($missingPortableImports.Count -gt 0) {
    throw "Portable Windows runtime is missing imported dependency/dependencies: $($missingPortableImports -join ', ')"
}

# If this is a dynamically-linked Qt build, the Windows platform plugin is mandatory. Accept the
# two layouts windeployqt has used in Eden-family builds: plugins/platforms and platforms.
$qtDlls = @(Get-ChildItem $destination -Filter 'Qt6*.dll' -File -ErrorAction SilentlyContinue)
if ($qtDlls.Count -gt 0) {
    $platformPlugin = @(
        (Join-Path $destination 'plugins\platforms\qwindows.dll'),
        (Join-Path $destination 'platforms\qwindows.dll')
    ) | Where-Object { Test-Path $_ -PathType Leaf } | Select-Object -First 1
    if (-not $platformPlugin) {
        throw 'Qt6 DLLs are present but qwindows.dll is missing; the portable package would not launch.'
    }
}

$dlls = @(Get-ChildItem $destination -Filter '*.dll' -File -Recurse -ErrorAction SilentlyContinue)
if ($qtDlls.Count -gt 0 -and $dlls.Count -lt 5) {
    throw "Dynamic Qt runtime appears incomplete: only $($dlls.Count) DLL(s) were packaged."
}

# Record the exact portable layout so runtime reports can be compared against known-working
# Eglantine/PokeDinner packages without guessing which DLL/plugin/resource was present.
$manifestPath = Join-Path $destination 'RUNTIME_MANIFEST.txt'
$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("Packaged from automation commit: $env:GITHUB_SHA")
$lines.Add("GUI executable: $(Split-Path $packagedGui -Leaf)")
$lines.Add("Runtime DLL count: $($dlls.Count)")
$lines.Add('')
$lines.Add('Files:')
Get-ChildItem $destination -File -Recurse |
    Where-Object { $_.FullName -ne $manifestPath } |
    Sort-Object FullName |
    ForEach-Object {
        $relative = [IO.Path]::GetRelativePath($destination, $_.FullName)
        $lines.Add("$relative`t$($_.Length)")
    }
$lines | Set-Content -Path $manifestPath -Encoding UTF8

Write-Host "Portable NS2 runtime staged at $destination"
Write-Host "GUI: $(Split-Path $packagedGui -Leaf)"
Write-Host "DLLs: $($dlls.Count)"
Write-Host "Files: $((Get-ChildItem $destination -File -Recurse).Count)"