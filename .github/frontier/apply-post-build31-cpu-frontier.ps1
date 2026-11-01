$ErrorActionPreference = 'Stop'

# Final CPU-side frontier after the proven PR157 mapping-generation and Build31 patches. Keeping
# these adapters here prevents them from changing the exact source contexts consumed by the older
# compressed patches while still making the normal, PGO and capture paths build the same source.
$rangeNotify = Join-Path $PSScriptRoot 'apply-memory-manager-range-notify.ps1'
$jitTelemetry = Join-Path $PSScriptRoot 'apply-cpu-jit-telemetry.ps1'
$legacyCleanup = Join-Path $PSScriptRoot 'apply-ns2-legacy-hotpath-cleanup.ps1'
$dispatchTelemetry = Join-Path $PSScriptRoot 'apply-dma-dispatch-telemetry.ps1'
$increasingRunFastPath = Join-Path $PSScriptRoot 'apply-dma-increasing-run-fastpath.ps1'
$increasingFrontCache = Join-Path $PSScriptRoot 'apply-dma-increasing-front-cache.ps1'
$descriptorScratch = Join-Path $PSScriptRoot 'apply-vulkan-descriptor-scratch-reuse.ps1'
$samplerIdVector = Join-Path $PSScriptRoot 'apply-texture-sampler-id-vector-cache.ps1'
$imageViewIdVector = Join-Path $PSScriptRoot 'apply-texture-image-view-id-vector-cache.ps1'
$dmaDownloadState = Join-Path $PSScriptRoot 'apply-texture-dma-download-state-inheritance.ps1'

foreach ($path in @($rangeNotify, $jitTelemetry, $legacyCleanup, $dispatchTelemetry,
                    $increasingRunFastPath, $increasingFrontCache, $descriptorScratch,
                    $samplerIdVector, $imageViewIdVector, $dmaDownloadState)) {
    if (-not (Test-Path $path -PathType Leaf)) {
        throw "Post-Build31 CPU frontier: missing $path"
    }
}

& $rangeNotify
& $jitTelemetry
& $legacyCleanup
& $dispatchTelemetry
& $increasingRunFastPath
& $increasingFrontCache
& $descriptorScratch
& $samplerIdVector
& $imageViewIdVector
& $dmaDownloadState

Write-Host '[APPLIED] Post-Build31 CPU frontier: range-batched GMMU notifications + opt-in Dynarmic duplicate-compile telemetry + stale reactive-read diagnostic cleanup + opt-in DmaDispatch traffic-shape telemetry + tight pure-Increasing engine-run dispatch + cached split routing + reusable Vulkan descriptor scratch + direct indexed sampler/image-view IDs + inherited first DMA-download state'
