param(
    [switch]$Strict
)

$ErrorActionPreference = 'Stop'

$source = Join-Path (Get-Location) 'build\bin'
if (-not (Test-Path $source -PathType Container)) {
    throw "Windows runtime source directory was not produced: $source"
}

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

foreach ($note in 'POKOPIA_CONFIG.txt', 'NX2_PERFORMANCE_NOTES.txt') {
    if (-not (Test-Path (Join-Path $source $note) -PathType Leaf)) {
        throw "Required NS2 runtime note/config is missing before checkpoint upload: $note"
    }
}

# Keep the packaged controls synchronized with the frontier stack without duplicating text when a
# checkpoint is staged more than once. Normal users leave all controls unset; these are targeted
# diagnosis/rollback switches for the new optimizations.
$performanceNotes = Join-Path $source 'NX2_PERFORMANCE_NOTES.txt'
$notesText = Get-Content $performanceNotes -Raw
$frontierMarker = 'Frontier profiling / rollback controls'
if (-not $notesText.Contains($frontierMarker)) {
    @'

Frontier profiling / rollback controls
======================================
EDEN_NX2_UBOREUSE=0
  Disable same-tick, byte-identical small uniform-buffer stream reuse. Default is enabled on Vulkan.

EDEN_NX2_GPU_PROFILE=1
  Enable granular GPU-thread profiling: DMA fetch/dispatch, channel switching, deferred split calls,
  geometry/vertex/uniform setup, cache-lock waits, rejected draws and pipeline misses.

EDEN_NX2_TC_LOG=1
  Re-enable the periodic texture-cache inventory/sort diagnostic. It stays off during normal play.

The DMA pushbuffer span fast-path is guarded by GMMU mapping epochs and preserves submitted-command
snapshot / GPU-written-command coherency ordering. There is no user switch because stale mappings
fall back automatically to the existing guest-memory path.
'@ | Add-Content -Path $performanceNotes -Encoding UTF8
}

# A one-click diagnostics launcher is useful for the new profiler and does not change normal launch
# behavior. It writes the emulator's stderr beside the executable while leaving regular logs intact.
$guiName = Split-Path $gui -Leaf
$profileLauncher = Join-Path $source 'run-nx2-gpu-profile.cmd'
@"
@echo off
setlocal
set EDEN_NX2_GPU_PROFILE=1
set EDEN_NX2_TC_LOG=1
echo NX2 granular GPU profiling enabled.
echo Close Eden normally when the representative gameplay section is complete.
"%~dp0$guiName" %* 2^> "%~dp0NX2_GPU_PROFILE.stderr.log"
echo Diagnostic stderr: %~dp0NX2_GPU_PROFILE.stderr.log
endlocal
"@ | Set-Content -Path $profileLauncher -Encoding ASCII

function Find-RuntimeDependency([string]$name) {
    $roots = @(
        (Join-Path (Get-Location) 'build'),
        (Join-Path (Get-Location) '.cache')
    )
    foreach ($root in $roots) {
        if (Test-Path $root -PathType Container) {
            $hit = Get-ChildItem $root -Recurse -Filter $name -File -ErrorAction SilentlyContinue |
                Where-Object { $_.DirectoryName -ne $source } |
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

# Make the checkpoint self-contained enough that a later packaging-only job does not need the
# original CMake object tree. Missing files are warnings by default: the expensive compile remains
# a successful reusable checkpoint, while the independent package job performs strict validation.
$portableImports = @(
    'icuuc.dll',
    'MSVCP140.dll',
    'MSVCP140_ATOMIC_WAIT.dll',
    'MSVCP140_CODECVT_IDS.dll',
    'MSVCP140_1.dll',
    'VCRUNTIME140.dll',
    'VCRUNTIME140_1.dll'
)
$missing = [System.Collections.Generic.List[string]]::new()
foreach ($name in $portableImports) {
    $existing = Get-ChildItem $source -Recurse -Filter $name -File -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($existing) { continue }

    $dependency = Find-RuntimeDependency $name
    if ($dependency) {
        Copy-Item $dependency (Join-Path $source $name) -Force
        Write-Host "Checkpoint staged runtime dependency: $name from $dependency"
    } else {
        $missing.Add($name)
        Write-Warning "Checkpoint could not stage runtime dependency: $name"
    }
}

$manifest = Join-Path $source 'COMPILED_CHECKPOINT.txt'
@(
    "Automation commit: $env:GITHUB_SHA",
    "GUI executable: $(Split-Path $gui -Leaf)",
    "Checkpoint created: $([DateTime]::UtcNow.ToString('o'))",
    "Missing staged runtime imports: $(if ($missing.Count) { $missing -join ', ' } else { 'none' })"
) | Set-Content -Path $manifest -Encoding UTF8

if ($Strict -and $missing.Count -gt 0) {
    throw "Checkpoint is missing runtime dependency/dependencies: $($missing -join ', ')"
}

Write-Host "Reusable compiled checkpoint prepared at $source"
Write-Host "Files: $((Get-ChildItem $source -File -Recurse).Count)"
if ($missing.Count -gt 0) {
    Write-Warning "Compile checkpoint was preserved despite missing packaging imports; package job will validate strictly."
}
