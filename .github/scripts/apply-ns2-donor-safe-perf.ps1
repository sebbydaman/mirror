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

# PR #160 + #162: once a native shader set is remembered as rejected, skip the expensive draw
# preparation before cache flushes/locks; and reuse byte-identical small Vulkan stream UBOs within
# the same scheduler tick so descriptor payloads can also be reused. Both remain correctness-gated:
# dirty shader state takes the normal path, and UBO reuse never crosses a command-buffer tick.
$drawUboMarkers = @(
    @{ Path = 'src/video_core/shader_cache.h'; Text = 'bool AreShadersValid() const noexcept;' },
    @{ Path = 'src/video_core/renderer_vulkan/vk_rasterizer.cpp'; Text = 'if (!pipeline_cache.AreShadersValid())' },
    @{ Path = 'src/video_core/buffer_cache/uniform_stream_reuse.h'; Text = 'EDEN_NX2_UBOREUSE' },
    @{ Path = 'src/video_core/buffer_cache/buffer_cache.h'; Text = 'VideoCommon::BindSmallUniformReusing(' },
    @{ Path = 'src/video_core/renderer_vulkan/vk_buffer_cache.h'; Text = 'struct StreamUniformRef' }
)
$drawUboPresent = 0
foreach ($marker in $drawUboMarkers) {
    if ((Test-Path $marker.Path -PathType Leaf) -and (Get-Content $marker.Path -Raw).Contains($marker.Text)) {
        ++$drawUboPresent
    }
}
if ($drawUboPresent -eq $drawUboMarkers.Count) {
    Write-Host '[PRESENT] rejected-shader early bailout + per-tick uniform stream reuse'
} elseif ($drawUboPresent -ne 0) {
    throw "Partial PR160/PR162 draw/UBO optimization state detected ($drawUboPresent/$($drawUboMarkers.Count)); refusing mixed apply"
} else {
    $encoded = @'
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
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
    $patchPath = Join-Path $env:RUNNER_TEMP 'ns2-pr160-pr162-draw-ubo.patch'
    [IO.File]::WriteAllBytes($patchPath, $patchBytes)
    git apply --check --whitespace=error-all $patchPath
    if ($LASTEXITCODE -ne 0) { throw 'PR160/PR162 draw/UBO batch no longer applies cleanly after PR163' }
    git apply --whitespace=error-all $patchPath
    if ($LASTEXITCODE -ne 0) { throw 'Failed to apply PR160/PR162 draw/UBO batch' }
    foreach ($marker in $drawUboMarkers) {
        if (-not (Test-Path $marker.Path -PathType Leaf) -or -not (Get-Content $marker.Path -Raw).Contains($marker.Text)) {
            throw "PR160/PR162 validation failed: missing '$($marker.Text)' in $($marker.Path)"
        }
    }
    Write-Host '[APPLIED] rejected-shader early bailout + per-tick uniform stream reuse'
}

git diff --check
if ($LASTEXITCODE -ne 0) {
    throw 'Safe donor performance batch introduced whitespace/diff errors'
}

Write-Host 'Applied safe NX2 donor performance batch: GPU family flags + split alignment + optional TC diagnostics + coalesced buffer flushes + rejected-draw bailout + UBO reuse.'
