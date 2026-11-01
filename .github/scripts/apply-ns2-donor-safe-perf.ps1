$ErrorActionPreference = 'Stop'

# Small changes that are independent of the larger DMA/memory experiments. Apply only after the
# integrated PokeDinner/Eglantine source exists so we never replace newer command-coherency logic.

# Fire Emblem: Fortune's Weave and newer SDKs filter class enumeration through GPU-characteristic
# family flags. Report 2D/3D/compute/inline-to-memory families in addition to mapping-modify.
$ctrlGpu = 'src/core/hle/service/nvdrv/devices/nvhost_ctrl_gpu.cpp'
$ctrl = Get-Content $ctrlGpu -Raw
if ($ctrl.Contains('gc.flags |= 0xfULL << 40;')) {
    Write-Host '[PRESENT] NX2 GPU class-family flags'
} else {
    $needle = '    gc.flags |= 1ULL << 34;'
    if (-not $ctrl.Contains($needle)) {
        throw 'NX2 GPU characteristics mapping-modify flag marker is missing'
    }
    $replacement = @'
    gc.flags |= 1ULL << 34;
    // Bits 40..43: 2D, 3D, compute and inline-to-memory class families. Newer NX2 SDKs filter
    // class enumeration through these bits; without them some titles abort during GPU bring-up.
    gc.flags |= 0xfULL << 40;
'@
    $ctrl = $ctrl.Replace($needle, $replacement.TrimEnd("`r", "`n"))
    [IO.File]::WriteAllText((Resolve-Path $ctrlGpu), $ctrl, [Text.UTF8Encoding]::new($false))
    Write-Host '[APPLIED] NX2 GPU class-family flags'
}

# Keep front/back split synchronization variables in separate 128-byte prefetch sectors on x86-64.
$splitHeader = 'src/video_core/gpu_split.h'
if (-not (Test-Path $splitHeader -PathType Leaf)) {
    throw 'GPU split header is missing after PokeDinner integration'
}
$split = Get-Content $splitHeader -Raw
if ($split.Contains('alignas(128) std::atomic<u64> published{};')) {
    Write-Host '[PRESENT] 128-byte GPU split synchronization alignment'
} else {
    foreach ($old in @(
        'alignas(64) std::atomic<u64> published{};',
        'alignas(64) std::atomic<u64> consumed{};',
        'alignas(64) std::atomic<bool> back_waiting{};'
    )) {
        if (-not $split.Contains($old)) {
            throw "GPU split alignment marker changed: $old"
        }
    }
    $split = $split.Replace('alignas(64) std::atomic<u64> published{};',
                            'alignas(128) std::atomic<u64> published{};')
    $split = $split.Replace('alignas(64) std::atomic<u64> consumed{};',
                            'alignas(128) std::atomic<u64> consumed{};')
    $split = $split.Replace('alignas(64) std::atomic<bool> back_waiting{};',
                            'alignas(128) std::atomic<bool> back_waiting{};')
    [IO.File]::WriteAllText((Resolve-Path $splitHeader), $split, [Text.UTF8Encoding]::new($false))
    Write-Host '[APPLIED] 128-byte GPU split synchronization alignment'
}

# The late texture-cache diagnostics allocate/sort the image inventory every 600 frames. Keep the
# diagnostic available, but remove it from normal gameplay unless EDEN_NX2_TC_LOG is requested.
$textureCache = 'src/video_core/texture_cache/texture_cache.h'
$texture = Get-Content $textureCache -Raw
if ($texture.Contains('EDEN_NX2_TC_LOG')) {
    Write-Host '[PRESENT] texture-cache diagnostic sorting gate'
} elseif ($texture.Contains('if (static u64 frames{}; ++frames % 600 == 0) {')) {
    if (-not $texture.Contains('#include <cstdlib>')) {
        if (-not $texture.Contains('#pragma once')) {
            throw 'texture_cache.h has no pragma marker for cstdlib insertion'
        }
        $texture = $texture.Replace('#pragma once', "#pragma once`n`n#include <cstdlib>")
    }
    $tickReplacement = @'
static const bool log_tc = std::getenv("EDEN_NX2_TC_LOG") != nullptr;
    static u64 frames{};
    if (log_tc && ++frames % 600 == 0) {
'@
    $texture = $texture.Replace('if (static u64 frames{}; ++frames % 600 == 0) {',
                                $tickReplacement.TrimEnd("`r", "`n"))
    [IO.File]::WriteAllText((Resolve-Path $textureCache), $texture, [Text.UTF8Encoding]::new($false))
    Write-Host '[APPLIED] texture-cache diagnostic sorting gate'
} else {
    Write-Host '[SKIP] periodic texture-cache sorting block is not present in this integrated source'
}

# Eglantine PR #163: MemoryManager::FlushRegion can split one GPU-to-CPU buffer flush into several
# page pieces and several BufferCache objects. Historically every piece performed its own Vulkan
# Finish/wait, and an unclipped range could also clear a neighbouring buffer's download tracker.
# Apply the six-file adaptation before PR142/frontier layers; it is independent of those changes.
$bufferBatchMarkers = @(
    @{ Path = 'src/video_core/buffer_cache/buffer_cache.h'; Text = 'void BufferCache<P>::BeginDownloadBatch()' },
    @{ Path = 'src/video_core/buffer_cache/buffer_cache.h'; Text = 'void BufferCache<P>::FinishDownloadBatch()' },
    @{ Path = 'src/video_core/buffer_cache/buffer_cache.h'; Text = 'const DAddr range_begin = (std::max)(buffer_begin, device_addr);' },
    @{ Path = 'src/video_core/memory_manager.cpp'; Text = 'const bool is_buffer_only = which == VideoCommon::CacheType::BufferCache;' },
    @{ Path = 'src/video_core/rasterizer_interface.h'; Text = 'virtual void BeginFlushBatch() {}' },
    @{ Path = 'src/video_core/renderer_vulkan/vk_rasterizer.cpp'; Text = 'void RasterizerVulkan::BeginFlushBatch()' }
)
$bufferBatchPresent = 0
foreach ($marker in $bufferBatchMarkers) {
    if ((Get-Content $marker.Path -Raw).Contains($marker.Text)) { ++$bufferBatchPresent }
}
if ($bufferBatchPresent -eq $bufferBatchMarkers.Count) {
    Write-Host '[PRESENT] coalesced buffer FlushRegion downloads + clipped tracker ranges'
} elseif ($bufferBatchPresent -ne 0) {
    throw "Partial PR163 buffer-flush batch state detected ($bufferBatchPresent/$($bufferBatchMarkers.Count)); refusing mixed apply"
} else {
    $encoded = @'
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
XOTal29Nd2/1b8FLm/8DYF+p2XQmAAA=
'@
    $encoded = $encoded -replace '\s', ''
    $compressed = [Convert]::FromBase64String($encoded)
    $input = [IO.MemoryStream]::new($compressed, $false)
    $gzip = [IO.Compression.GZipStream]::new($input, [IO.Compression.CompressionMode]::Decompress)
    $output = [IO.MemoryStream]::new()
    try {
        $gzip.CopyTo($output)
        $patchBytes = $output.ToArray()
    } finally {
        $output.Dispose(); $gzip.Dispose(); $input.Dispose()
    }
    $patchPath = Join-Path $env:RUNNER_TEMP 'ns2-pr163-buffer-flush-batch.patch'
    [IO.File]::WriteAllBytes($patchPath, $patchBytes)
    git apply --check --whitespace=error-all $patchPath
    if ($LASTEXITCODE -ne 0) { throw 'PR163 buffer-flush batch no longer applies cleanly to the integrated source' }
    git apply --whitespace=error-all $patchPath
    if ($LASTEXITCODE -ne 0) { throw 'Failed to apply PR163 buffer-flush batch' }
    foreach ($marker in $bufferBatchMarkers) {
        if (-not (Get-Content $marker.Path -Raw).Contains($marker.Text)) {
            throw "PR163 validation failed: missing '$($marker.Text)' in $($marker.Path)"
        }
    }
    Write-Host '[APPLIED] coalesced buffer FlushRegion downloads + clipped tracker ranges'
}

git diff --check
if ($LASTEXITCODE -ne 0) {
    throw 'Safe donor performance batch introduced whitespace/diff errors'
}

Write-Host 'Applied safe NX2 donor performance batch: GPU family flags + split alignment + optional TC diagnostics + coalesced buffer flushes.'
