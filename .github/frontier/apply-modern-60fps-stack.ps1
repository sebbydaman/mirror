$ErrorActionPreference = 'Stop'

# Modern-only NS2 performance composition for the dedicated 60 FPS / low-frametime candidate.
# Keep the newest production hot-path improvements exactly once and intentionally leave out:
#   - the broken-driver-only pipeline worker exception (compatibility-specific)
#   - loose RomFS memoization (startup/filesystem optimization, not sustained frame time)
#   - telemetry-only adapters, experimental split-ring work, and superseded meta-wrappers

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$scripts = @(
    'apply-zortos-build31-perf.ps1',
    'apply-zortos-build31-partial-write.ps1',
    'apply-ns2-legacy-hotpath-cleanup.ps1',
    'apply-ns2-pipeline-worker-budget.ps1',
    'apply-dma-increasing-run-fastpath.ps1',
    'apply-dma-increasing-front-cache.ps1',
    'apply-modern-dma-telemetry-decouple.ps1',
    'apply-vulkan-descriptor-scratch-reuse.ps1',
    'apply-texture-sampler-id-vector-cache.ps1',
    'apply-texture-image-view-id-vector-cache.ps1',
    'apply-texture-dma-download-state-inheritance.ps1',
    'apply-descriptor-table-span-cache.ps1',
    'apply-memory-manager-range-notify.ps1',
    'apply-pushbuffer-mapgen-hardening.ps1'
)

$previousSkipPostBuild31 = $env:EDEN_SKIP_POST_BUILD31_FRONTIER
$env:EDEN_SKIP_POST_BUILD31_FRONTIER = '1'

try {
    foreach ($script in $scripts) {
        $path = Join-Path $root $script
        if (-not (Test-Path $path -PathType Leaf)) {
            throw "Modern60 stack: missing $path"
        }

        Write-Host "[MODERN60] Applying $script"
        try {
            & $path
        } catch {
            throw "Modern60 stack failed in ${script}: $($_.Exception.Message)"
        }
        Write-Host "[MODERN60] Completed $script"
    }

    git diff --check
    if ($LASTEXITCODE -ne 0) {
        throw 'Modern60 stack introduced diff/whitespace errors'
    }

    Write-Host '[PASS] Modern60 sustained-frametime stack applied cleanly exactly once.'
} finally {
    $env:EDEN_SKIP_POST_BUILD31_FRONTIER = $previousSkipPostBuild31
}
