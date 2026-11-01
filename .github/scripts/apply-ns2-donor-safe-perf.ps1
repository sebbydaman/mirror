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
    $texture = $texture.Replace(
        'if (static u64 frames{}; ++frames % 600 == 0) {',
        "static const bool log_tc = std::getenv(\"EDEN_NX2_TC_LOG\") != nullptr;`n    static u64 frames{};`n    if (log_tc && ++frames % 600 == 0) {")
    [IO.File]::WriteAllText((Resolve-Path $textureCache), $texture, [Text.UTF8Encoding]::new($false))
    Write-Host '[APPLIED] texture-cache diagnostic sorting gate'
} else {
    Write-Host '[SKIP] periodic texture-cache sorting block is not present in this integrated source'
}

git diff --check
if ($LASTEXITCODE -ne 0) {
    throw 'Safe donor performance batch introduced whitespace/diff errors'
}

Write-Host 'Applied safe NX2 donor micro-batch: GPU family flags + split alignment + optional TC diagnostics.'
