$ErrorActionPreference = 'Stop'

# Final production performance composition for NS2. This wrapper intentionally excludes pure
# telemetry-only adapters, the experimental contiguous split-ring work, and the older
# apply-post-build31-cpu-frontier.ps1 meta-wrapper. The useful production patches from that
# meta-wrapper are applied individually below so they are composed exactly once.

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$scripts = @(
    'apply-zortos-build31-perf.ps1',
    'apply-zortos-build31-partial-write.ps1',
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
    try {
        & $path
    } catch {
        throw "Final NS2 performance stack failed in ${script}: $($_.Exception.Message)"
    }

    # Do not inspect $LASTEXITCODE here. A PowerShell child script may invoke native tools
    # internally and leave a stale non-zero value even when the script itself completed
    # successfully. With ErrorActionPreference=Stop, real PowerShell failures propagate via
    # exceptions; native commands that matter are validated inside each patch script.
    Write-Host "[FINAL PERF] Completed $script"
}

git diff --check
if ($LASTEXITCODE -ne 0) {
    throw 'Final NS2 performance stack introduced diff/whitespace errors'
}

Write-Host '[PASS] Final NS2 production performance stack applied cleanly exactly once.'
