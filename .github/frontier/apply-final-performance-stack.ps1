$ErrorActionPreference = 'Stop'

# Final production performance composition for NS2. This wrapper intentionally excludes the pure
# telemetry-only adapters and the experimental contiguous split-ring work. Every included layer has
# already been used by the validated CPU/frame-time frontier or is a narrow runtime safety adapter.

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$scripts = @(
    'apply-zortos-build31-perf.ps1',
    'apply-zortos-build31-partial-write.ps1',
    'apply-post-build31-cpu-frontier.ps1',
    'apply-ns2-legacy-hotpath-cleanup.ps1',
    'apply-ns2-pipeline-worker-budget.ps1',
    'apply-ns2-broken-driver-worker-budget.ps1',
    'apply-dma-increasing-run-fastpath.ps1',
    'apply-dma-increasing-front-cache.ps1',
    'apply-vulkan-descriptor-scratch-reuse.ps1',
    'apply-texture-sampler-id-vector-cache.ps1',
    'apply-texture-image-view-id-vector-cache.ps1',
    'apply-texture-dma-download-state-inheritance.ps1',
    'apply-descriptor-table-span-cache.ps1',
    'apply-memory-manager-range-notify.ps1',
    'apply-pushbuffer-mapgen-hardening.ps1'
)

foreach ($script in $scripts) {
    $path = Join-Path $root $script
    if (-not (Test-Path $path -PathType Leaf)) {
        throw "Final NS2 performance stack: missing $path"
    }
    Write-Host "[FINAL PERF] Applying $script"
    & $path
    if ($LASTEXITCODE -ne 0) {
        throw "Final NS2 performance stack failed in $script"
    }
}

git diff --check
if ($LASTEXITCODE -ne 0) {
    throw 'Final NS2 performance stack introduced diff/whitespace errors'
}

Write-Host '[PASS] Final NS2 performance stack applied cleanly.'
