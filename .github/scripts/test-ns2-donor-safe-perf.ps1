$ErrorActionPreference = 'Stop'

function Require-Text([string]$Path, [string]$Needle, [string]$Name) {
    if (-not (Test-Path $Path -PathType Leaf)) {
        throw "Safe donor regression: missing required file $Path"
    }
    $text = Get-Content $Path -Raw
    if (-not $text.Contains($Needle)) {
        throw "Safe donor regression: $Name missing from $Path"
    }
    Write-Host "[PASS] $Name"
}

$ctrlGpu = 'src/core/hle/service/nvdrv/devices/nvhost_ctrl_gpu.cpp'
$split = 'src/video_core/gpu_split.h'
$texture = 'src/video_core/texture_cache/texture_cache.h'

Require-Text $ctrlGpu 'gc.flags |= 0xfULL << 40;' 'NX2 GPU class-family flags'
Require-Text $split 'alignas(128) std::atomic<u64> published{};' '128-byte published split atomic alignment'
Require-Text $split 'alignas(128) std::atomic<u64> consumed{};' '128-byte consumed split atomic alignment'
Require-Text $split 'alignas(128) std::atomic<bool> back_waiting{};' '128-byte back-waiting split atomic alignment'

$textureText = Get-Content $texture -Raw
if ($textureText.Contains('if (static u64 frames{}; ++frames % 600 == 0) {') -and
    -not $textureText.Contains('EDEN_NX2_TC_LOG')) {
    throw 'Safe donor regression: periodic texture-cache sorting still runs unconditionally'
}
if ($textureText.Contains('EDEN_NX2_TC_LOG')) {
    Write-Host '[PASS] texture-cache diagnostic sorting is opt-in'
} else {
    Write-Host '[PASS] no periodic texture-cache diagnostic sorting block requires gating'
}

Write-Host 'Safe NX2 donor performance regression validation passed.'
