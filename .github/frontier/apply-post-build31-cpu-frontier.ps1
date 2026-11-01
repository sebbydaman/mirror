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

# The donor semaphore-watch diagnostic is declared later in dma_pusher.cpp, while the cached
# Increasing-run adapter consults it inside ProcessCommands. Move the existing definition ahead of
# ProcessCommands rather than weakening/removing the diagnostic guard. This is source-order only:
# there remains exactly one parsed watch value and normal gameplay pays no additional getenv cost.
$dmaPusherPath = 'src/video_core/dma_pusher.cpp'
$dmaText = (Get-Content $dmaPusherPath -Raw).Replace("`r`n", "`n")
$watchPattern = '(?ms)^// EDEN_NX2_SEM_WATCH=<gpu address>:.*?^static const u32 g_semaphore_watch = \[\] \{.*?^\}\(\);\n'
$watchMatch = [regex]::Match($dmaText, $watchPattern)
$guard = 'if (g_semaphore_watch == 0 && run_split_active) {'
$guardIndex = $dmaText.IndexOf($guard, [StringComparison]::Ordinal)
if (-not $watchMatch.Success -or $guardIndex -lt 0) {
    throw 'Post-Build31 CPU frontier: semaphore-watch source-order anchors missing'
}
if ($watchMatch.Index -gt $guardIndex) {
    $watchBlock = $watchMatch.Value.TrimEnd("`r", "`n")
    $dmaText = $dmaText.Remove($watchMatch.Index, $watchMatch.Length)
    $anchor = 'constexpr u32 ComputeInline = 0x6D;'
    $anchorIndex = $dmaText.IndexOf($anchor, [StringComparison]::Ordinal)
    if ($anchorIndex -lt 0) {
        throw 'Post-Build31 CPU frontier: ComputeInline anchor missing for semaphore-watch ordering fix'
    }
    $insertAt = $anchorIndex + $anchor.Length
    $dmaText = $dmaText.Insert($insertAt, "`n`n$watchBlock")
    [IO.File]::WriteAllText((Resolve-Path $dmaPusherPath).Path,
        $dmaText.TrimEnd("`r", "`n") + "`n", [Text.UTF8Encoding]::new($false))
    Write-Host '[APPLIED] moved semaphore-watch declaration ahead of cached Increasing-run dispatch'
} else {
    Write-Host '[PRESENT] semaphore-watch declaration already precedes cached Increasing-run dispatch'
}

$orderedText = (Get-Content $dmaPusherPath -Raw).Replace("`r`n", "`n")
$definitionIndex = $orderedText.IndexOf('static const u32 g_semaphore_watch = [] {', [StringComparison]::Ordinal)
$guardIndex = $orderedText.IndexOf($guard, [StringComparison]::Ordinal)
if ($definitionIndex -lt 0 -or $guardIndex -lt 0 -or $definitionIndex -gt $guardIndex) {
    throw 'Post-Build31 CPU frontier: semaphore-watch declaration still follows cached dispatch use'
}
if (([regex]::Matches($orderedText, 'static const u32 g_semaphore_watch = \[\] \{')).Count -ne 1) {
    throw 'Post-Build31 CPU frontier: expected exactly one semaphore-watch definition'
}

& $descriptorScratch
& $samplerIdVector
& $imageViewIdVector
& $dmaDownloadState

& git diff --check
if ($LASTEXITCODE -ne 0) {
    throw 'Post-Build31 CPU frontier introduced diff/whitespace errors after semaphore-watch ordering fix'
}

Write-Host '[APPLIED] Post-Build31 CPU frontier: range-batched GMMU notifications + opt-in Dynarmic duplicate-compile telemetry + stale reactive-read diagnostic cleanup + opt-in DmaDispatch traffic-shape telemetry + tight pure-Increasing engine-run dispatch + cached split routing + semaphore-watch source-order fix + reusable Vulkan descriptor scratch + direct indexed sampler/image-view IDs + inherited first DMA-download state'
