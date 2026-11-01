$ErrorActionPreference = 'Stop'

# Final CPU-side frontier after the proven PR157 mapping-generation and Build31 patches. Keeping
# these adapters here prevents them from changing the exact source contexts consumed by the older
# compressed patches while still making the normal, PGO and capture paths build the same source.
$rangeNotify = Join-Path $PSScriptRoot 'apply-memory-manager-range-notify.ps1'
$jitTelemetry = Join-Path $PSScriptRoot 'apply-cpu-jit-telemetry.ps1'
$legacyCleanup = Join-Path $PSScriptRoot 'apply-ns2-legacy-hotpath-cleanup.ps1'
$dispatchTelemetry = Join-Path $PSScriptRoot 'apply-dma-dispatch-telemetry.ps1'
$increasingRunFastPath = Join-Path $PSScriptRoot 'apply-dma-increasing-run-fastpath.ps1'

foreach ($path in @($rangeNotify, $jitTelemetry, $legacyCleanup, $dispatchTelemetry,
                    $increasingRunFastPath)) {
    if (-not (Test-Path $path -PathType Leaf)) {
        throw "Post-Build31 CPU frontier: missing $path"
    }
}

& $rangeNotify
& $jitTelemetry
& $legacyCleanup
& $dispatchTelemetry
& $increasingRunFastPath

Write-Host '[APPLIED] Post-Build31 CPU frontier: range-batched GMMU notifications + opt-in Dynarmic duplicate-compile telemetry + stale reactive-read diagnostic cleanup + opt-in DmaDispatch traffic-shape telemetry + tight pure-Increasing engine-run dispatch'
