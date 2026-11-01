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
  Enable lightweight granular GPU-thread profiling: DMA fetch/dispatch, channel switching, deferred
  split calls, geometry/vertex/uniform setup, cache-lock waits, rejected draws and pipeline misses.

EDEN_NX2_GPU_PROFILE_PAGES=1
  Opt in to the expensive per-4-KiB MME DMA page-history/readback correlation diagnostic. Leave this
  unset during representative gameplay profiling; it performs address translation and set lookups
  on hot paths and is intended only for a focused readback investigation.

EDEN_NX2_TC_LOG=1
  Re-enable the periodic texture-cache inventory/sort diagnostic. It stays off during normal play
  and during the standard gameplay profiler run.

The DMA pushbuffer span fast-path is guarded by GMMU mapping epochs and preserves submitted-command
snapshot / GPU-written-command coherency ordering. There is no user switch because stale mappings
fall back automatically to the existing guest-memory path.

Use run-nx2-gpu-profile.cmd for a representative gameplay section, then run:
  powershell -ExecutionPolicy Bypass -File analyze-nx2-profile.ps1
The analyzer ranks hot zones, exports NX2_GPU_PROFILE_summary.csv, and prints targeted follow-up hints.
'@ | Add-Content -Path $performanceNotes -Encoding UTF8
}

# A one-click diagnostics launcher is useful for the new profiler and does not change normal launch
# behavior. Keep expensive texture-cache and per-page DMA diagnostics explicitly disabled here so
# representative profiling measures the game rather than the diagnostics themselves.
$guiName = Split-Path $gui -Leaf
$profileLauncher = Join-Path $source 'run-nx2-gpu-profile.cmd'
@"
@echo off
setlocal
set EDEN_NX2_GPU_PROFILE=1
set EDEN_NX2_GPU_PROFILE_PAGES=0
set EDEN_NX2_TC_LOG=0
echo NX2 lightweight GPU profiling enabled.
echo Close Eden normally when the representative gameplay section is complete.
"%~dp0$guiName" %* 2^> "%~dp0NX2_GPU_PROFILE.stderr.log"
echo Diagnostic stderr: %~dp0NX2_GPU_PROFILE.stderr.log
echo Analyze with: powershell -ExecutionPolicy Bypass -File "%~dp0analyze-nx2-profile.ps1"
endlocal
"@ | Set-Content -Path $profileLauncher -Encoding ASCII

# Turn the profiler's 10-second samples into a compact ranked report. This is intentionally a
# standalone PowerShell file in the portable runtime: users can analyze a run without Python or
# modifying emulator settings. It parses the exact Nx2Profile::Report format from the built source.
$profileAnalyzer = Join-Path $source 'analyze-nx2-profile.ps1'
@'
param(
    [string]$LogPath = (Join-Path $PSScriptRoot 'NX2_GPU_PROFILE.stderr.log')
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $LogPath -PathType Leaf)) {
    throw "NX2 profiler log not found: $LogPath"
}

$zones = [System.Collections.Generic.List[object]]::new()
$counters = [System.Collections.Generic.List[object]]::new()

foreach ($line in Get-Content $LogPath) {
    $report = [regex]::Match($line, '(?<thread>[^|\r\n]+?) per second:(?<body>.*)$')
    if (-not $report.Success) { continue }
    $thread = $report.Groups['thread'].Value.Trim()
    $body = $report.Groups['body'].Value

    foreach ($match in [regex]::Matches($body, '\|\s*([^|]+?)\s+([0-9]+(?:\.[0-9]+)?) ms \(([0-9]+(?:\.[0-9]+)?)/s\)')) {
        $zones.Add([pscustomobject]@{
            Thread = $thread
            Zone = $match.Groups[1].Value.Trim()
            MsPerSecond = [double]$match.Groups[2].Value
            CallsPerSecond = [double]$match.Groups[3].Value
        })
    }

    $download = [regex]::Match($body, 'buffer downloads ([0-9.]+) KiB in ([0-9.]+) copies \(([0-9.]+) KiB on pages MME DMA reads\) \| MME DMA reads ([0-9.]+) KiB')
    $writes = [regex]::Match($body, '3D register writes ([0-9.]+) \(([0-9.]+) same value\)')
    $acquires = [regex]::Match($body, 'acquires ([0-9.]+) \(([0-9.]+) waited\)')
    $skipped = [regex]::Match($body, 'draws skipped \(rejected program\) ([0-9.]+)')
    $misses = [regex]::Match($body, 'pipeline cache misses ([0-9.]+)')
    $counters.Add([pscustomobject]@{
        Thread = $thread
        DownloadKiBPerSecond = if ($download.Success) { [double]$download.Groups[1].Value } else { 0.0 }
        DownloadCopiesPerSecond = if ($download.Success) { [double]$download.Groups[2].Value } else { 0.0 }
        DownloadKiBOnDmaPagesPerSecond = if ($download.Success) { [double]$download.Groups[3].Value } else { 0.0 }
        MmeDmaReadKiBPerSecond = if ($download.Success) { [double]$download.Groups[4].Value } else { 0.0 }
        RegisterWritesPerSecond = if ($writes.Success) { [double]$writes.Groups[1].Value } else { 0.0 }
        SameValueWritesPerSecond = if ($writes.Success) { [double]$writes.Groups[2].Value } else { 0.0 }
        AcquireChecksPerSecond = if ($acquires.Success) { [double]$acquires.Groups[1].Value } else { 0.0 }
        AcquireWaitsPerSecond = if ($acquires.Success) { [double]$acquires.Groups[2].Value } else { 0.0 }
        SkippedDrawsPerSecond = if ($skipped.Success) { [double]$skipped.Groups[1].Value } else { 0.0 }
        PipelineMissesPerSecond = if ($misses.Success) { [double]$misses.Groups[1].Value } else { 0.0 }
    })
}

if ($zones.Count -eq 0) {
    throw 'No NX2 GPU profiler samples were found. Launch with run-nx2-gpu-profile.cmd and play for at least 10 seconds.'
}

$summary = foreach ($group in ($zones | Group-Object Thread, Zone)) {
    $sample = $group.Group[0]
    $ms = $group.Group | Measure-Object MsPerSecond -Average -Maximum
    $calls = $group.Group | Measure-Object CallsPerSecond -Average -Maximum
    [pscustomobject]@{
        Thread = $sample.Thread
        Zone = $sample.Zone
        Samples = $group.Count
        AvgMsPerSecond = [math]::Round($ms.Average, 2)
        MaxMsPerSecond = [math]::Round($ms.Maximum, 2)
        AvgCallsPerSecond = [math]::Round($calls.Average, 1)
        MaxCallsPerSecond = [math]::Round($calls.Maximum, 1)
    }
}
$summary = @($summary | Sort-Object AvgMsPerSecond -Descending)
$csv = Join-Path $PSScriptRoot 'NX2_GPU_PROFILE_summary.csv'
$summary | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8

Write-Host ''
Write-Host 'NX2 profiler - hottest zones' -ForegroundColor Cyan
$summary | Select-Object -First 20 | Format-Table -AutoSize

$counterSummary = [pscustomobject]@{
    Samples = $counters.Count
    AvgDownloadMiBPerSecond = [math]::Round((($counters | Measure-Object DownloadKiBPerSecond -Average).Average / 1024.0), 2)
    MaxDownloadMiBPerSecond = [math]::Round((($counters | Measure-Object DownloadKiBPerSecond -Maximum).Maximum / 1024.0), 2)
    AvgDownloadCopiesPerSecond = [math]::Round(($counters | Measure-Object DownloadCopiesPerSecond -Average).Average, 1)
    AvgSkippedDrawsPerSecond = [math]::Round(($counters | Measure-Object SkippedDrawsPerSecond -Average).Average, 1)
    MaxSkippedDrawsPerSecond = [math]::Round(($counters | Measure-Object SkippedDrawsPerSecond -Maximum).Maximum, 1)
    AvgPipelineMissesPerSecond = [math]::Round(($counters | Measure-Object PipelineMissesPerSecond -Average).Average, 1)
    MaxPipelineMissesPerSecond = [math]::Round(($counters | Measure-Object PipelineMissesPerSecond -Maximum).Maximum, 1)
}
Write-Host 'Aggregate counters' -ForegroundColor Cyan
$counterSummary | Format-List

function AvgZone([string]$name) {
    $rows = @($summary | Where-Object Zone -eq $name)
    if ($rows.Count -eq 0) { return 0.0 }
    return [double](($rows | Measure-Object AvgMsPerSecond -Average).Average)
}

$hints = [System.Collections.Generic.List[string]]::new()
if ((AvgZone 'dma fetch') -gt 20) { $hints.Add('DMA fetch is still hot: investigate GMMU/span-cache misses and command-memory locality.') }
if ((AvgZone 'dma dispatch') -gt 20) { $hints.Add('DMA dispatch is hot: structural pushbuffer/method-sequence caching is a strong next experiment.') }
if ((AvgZone 'update uniform buffers') -gt 20) { $hints.Add('Uniform setup is hot: inspect UBO reuse hit rate and descriptor payload reuse.') }
if ((AvgZone 'cache lock wait') -gt 10) { $hints.Add('Cache lock contention is material: shorten critical sections or move readback work out of draw locks.') }
if ((AvgZone 'split drain') -gt 20) { $hints.Add('GPU front thread frequently drains for the back thread: optimize deferred/back-thread work or rebalance split policy.') }
if ((AvgZone 'split wait') -gt 400) { $hints.Add('Back thread is often idle: the front/CPU side may be the limiter rather than GPU back-thread execution.') }
if ($counterSummary.AvgDownloadMiBPerSecond -gt 20) { $hints.Add('GPU-to-CPU readback bandwidth remains high: profile which buffers/images trigger synchronization.') }
if ($counterSummary.AvgSkippedDrawsPerSecond -gt 50) { $hints.Add('Many rejected draws remain: shader compatibility/lowering may improve both correctness and wasted draw overhead.') }
if ($counterSummary.AvgPipelineMissesPerSecond -gt 20) { $hints.Add('Pipeline creation is active during gameplay: expand persistent cache/prewarm coverage.') }

Write-Host 'Suggested next targets' -ForegroundColor Cyan
if ($hints.Count -eq 0) {
    Write-Host 'No single configured threshold dominates. Compare the top zones and frame-time trace for the tested scene.'
} else {
    foreach ($hint in $hints) { Write-Host " - $hint" }
}
Write-Host "CSV report: $csv"
'@ | Set-Content -Path $profileAnalyzer -Encoding UTF8

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
