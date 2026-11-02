$ErrorActionPreference = 'Stop'

# Final production performance composition for NS2. This wrapper intentionally excludes pure
# telemetry-only adapters, the experimental contiguous split-ring work, and the older
# apply-post-build31-cpu-frontier.ps1 meta-wrapper. The useful production patches from that
# meta-wrapper are applied individually below so they are composed exactly once.

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$experiments = Join-Path (Split-Path $root -Parent) 'experiments'
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

$previousSkipPostBuild31 = $env:EDEN_SKIP_POST_BUILD31_FRONTIER
$env:EDEN_SKIP_POST_BUILD31_FRONTIER = '1'

try {
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
        Write-Host "[FINAL PERF] Completed $script"
    }

    # Keep the already-proven in-process memoization: frontend probing should still construct a
    # given loose RomFS only once per Eden process.
    $romfsMemo = Join-Path $experiments 'apply-loose-romfs-memoization.ps1'
    if (-not (Test-Path $romfsMemo -PathType Leaf)) {
        throw "Final NS2 performance stack: missing $romfsMemo"
    }
    Write-Host '[FINAL PERF] Applying loose RomFS memoization'
    & $romfsMemo

    # The Zen4/Clang Windows build regressed the *first* loose-RomFS construction from the older
    # MSVC build's ~1-3 seconds to ~40 seconds for the same Pokopia title. Use a Windows-native,
    # one-pass physical-directory enumerator only for RomFSBuildContext so we keep the final
    # gameplay stack untouched while removing libstdc++ filesystem/status/file_size overhead.
    $romfsWin32 = Join-Path $experiments 'apply-windows-romfs-enumeration-fastpath.ps1'
    if (-not (Test-Path $romfsWin32 -PathType Leaf)) {
        throw "Final NS2 performance stack: missing $romfsWin32"
    }
    Write-Host '[FINAL PERF] Applying Windows loose RomFS enumeration fast path'
    & $romfsWin32

    git diff --check
    if ($LASTEXITCODE -ne 0) {
        throw 'Final NS2 performance stack introduced diff/whitespace errors'
    }

    Write-Host '[PASS] Final NS2 production performance stack applied cleanly exactly once.'
} finally {
    $env:EDEN_SKIP_POST_BUILD31_FRONTIER = $previousSkipPostBuild31
}
