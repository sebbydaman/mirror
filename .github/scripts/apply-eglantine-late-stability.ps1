$ErrorActionPreference = 'Stop'

# Small late-Eglantine stability batch, generated and git-apply --checked against the exact
# captured integrated source after PokeDinner 2.0, read traps, sparse/VRAM fixes and handheld mode:
#   * AMD/NX2: undefined U1/U32 shader registers read as zero instead of driver-dependent OpUndef.
#     EDEN_NX2_UNDEF_ZERO=0 restores OpUndef for diagnosis.
#   * Game-list worker/content-provider lifetime: defer worker destruction when nested event loops
#     can still be executing it, and do not rebuild content providers underneath a running game.

function Apply-FrontierPerformanceBatch {
    # This payload is generated against the exact fully-integrated #227 source after the donor and
    # PR142 layers. It intentionally combines the compatible high-value frontier changes in one
    # compile: PR137 batched image readbacks, PR157 DMA span fast-path, PR134 granular profiling,
    # PR146 Generic31W, and PR109 macro/pushbuffer safety.
    $frontierMarkers = @(
        @{ Path = 'src/shader_recompiler/frontend/ir/attribute.h'; Text = 'attribute <= Attribute::Generic31W' },
        @{ Path = 'src/video_core/texture_cache/texture_cache.h'; Text = 'constexpr size_t MaxBatchBytes = 64_MiB;' },
        @{ Path = 'src/video_core/dma_pusher.h'; Text = 'GPUVAddr pb_cached_gpu_addr{0};' },
        @{ Path = 'src/video_core/dma_pusher.h'; Text = 'u32 skip_words;' },
        @{ Path = 'src/video_core/engines/maxwell_3d.cpp'; Text = 'Rejecting out-of-range macro bind' },
        @{ Path = 'src/video_core/nx2_profile.h'; Text = 'DmaFetch' },
        @{ Path = 'src/video_core/nx2_profile.h'; Text = 'CacheLockWait' },
        @{ Path = 'src/video_core/renderer_vulkan/vk_pipeline_cache.cpp'; Text = 'Counter::PipelineMisses' }
    )

    $frontierPresent = 0
    foreach ($marker in $frontierMarkers) {
        if ((Get-Content $marker.Path -Raw).Contains($marker.Text)) { ++$frontierPresent }
    }
    if ($frontierPresent -eq $frontierMarkers.Count) {
        Write-Host 'NS2 frontier performance/profiling batch is already present.'
        return
    }
    if ($frontierPresent -ne 0) {
        throw "Partial NS2 frontier performance state detected ($frontierPresent/$($frontierMarkers.Count) markers); refusing mixed apply"
    }

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

    $patchPath = Join-Path $env:RUNNER_TEMP 'ns2-frontier-performance.patch'
    [IO.File]::WriteAllBytes($patchPath, $patchBytes)
    git apply --check --whitespace=error-all $patchPath
    if ($LASTEXITCODE -ne 0) { throw 'NS2 frontier performance patch no longer applies cleanly to the fully integrated source' }
    git apply --whitespace=error-all $patchPath
    if ($LASTEXITCODE -ne 0) { throw 'Failed to apply NS2 frontier performance patch' }
    git diff --check
    if ($LASTEXITCODE -ne 0) { throw 'NS2 frontier performance patch introduced whitespace/diff errors' }

    foreach ($marker in $frontierMarkers) {
        if (-not (Get-Content $marker.Path -Raw).Contains($marker.Text)) {
            throw "NS2 frontier performance validation failed: missing '$($marker.Text)' in $($marker.Path)"
        }
    }
    Write-Host 'Applied NS2 frontier performance batch: batched readbacks + DMA span cache + granular profiling + Generic31W + parser safety.'
}

$markers = @(
    @{ Path = 'src/shader_recompiler/backend/spirv/emit_spirv_undefined.cpp'; Text = 'bool UndefIsZero()' },
    @{ Path = 'src/shader_recompiler/backend/spirv/emit_spirv_undefined.cpp'; Text = 'EDEN_NX2_UNDEF_ZERO' },
    @{ Path = 'src/qt_common/game_list/model.cpp'; Text = 'void GameListModel::StopWorker()' },
    @{ Path = 'src/qt_common/game_list/model.cpp'; Text = 'Emulation is running, deferring game list reload.' },
    @{ Path = 'src/qt_common/game_list/worker.cpp'; Text = 'void GameListWorker::Stop()' },
    @{ Path = 'src/qt_common/game_list/worker.cpp'; Text = 'while (model->current_worker.get() == this)' }
)

$present = 0
foreach ($marker in $markers) {
    if ((Get-Content $marker.Path -Raw).Contains($marker.Text)) { ++$present }
}
if ($present -eq $markers.Count) {
    Write-Host 'Late NS2 stability batch is already present.'
    & "$PSScriptRoot\apply-ns2-donor-20261101.ps1"
    & "$PSScriptRoot\apply-ns2-donor-safe-perf.ps1"
    & "$PSScriptRoot\prep-pr142-integrated.ps1"
    & "$PSScriptRoot\apply-eglantine-pr142-memory-stutter.ps1"
    Apply-FrontierPerformanceBatch
    exit 0
}
if ($present -ne 0) {
    throw "Partial late-NS2 stability state detected ($present/$($markers.Count) markers); refusing mixed apply"
}

$payload = Join-Path $PSScriptRoot '..\patches\ns2-late-stability.patch.gz.b64'
if (-not (Test-Path $payload)) { throw "Missing late NS2 stability patch payload: $payload" }

$encoded = (Get-Content $payload -Raw) -replace '\s', ''
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

$patchPath = Join-Path $env:RUNNER_TEMP 'ns2-late-stability.patch'
[IO.File]::WriteAllBytes($patchPath, $patchBytes)

# Refuse to mutate the tree if our exact-source assumptions changed.
git apply --check --whitespace=error-all $patchPath
if ($LASTEXITCODE -ne 0) { throw 'Late NS2 stability patch no longer applies cleanly to the integrated source' }

git apply --whitespace=error-all $patchPath
if ($LASTEXITCODE -ne 0) { throw 'Failed to apply late NS2 stability patch' }

git diff --check
if ($LASTEXITCODE -ne 0) { throw 'Late NS2 stability patch introduced whitespace/diff errors' }

foreach ($marker in $markers) {
    if (-not (Get-Content $marker.Path -Raw).Contains($marker.Text)) {
        throw "Late NS2 stability validation failed: missing '$($marker.Text)' in $($marker.Path)"
    }
}

# Semantic guards beyond marker presence.
$undef = Get-Content 'src/shader_recompiler/backend/spirv/emit_spirv_undefined.cpp' -Raw
if (-not ($undef.Contains('return UndefIsZero() ? ctx.false_value : ctx.OpUndef(ctx.U1);') -and
          $undef.Contains('return UndefIsZero() ? ctx.u32_zero_value : ctx.OpUndef(ctx.U32[1]);'))) {
    throw 'AMD/NX2 undefined-register zeroing is incomplete'
}
$model = Get-Content 'src/qt_common/game_list/model.cpp' -Raw
if (-not ($model.Contains('if (QtCommon::system->IsPoweredOn())') -and
          $model.Contains('current_worker.release()->deleteLater();'))) {
    throw 'Game-list content-provider/worker lifetime protection is incomplete'
}
$worker = Get-Content 'src/qt_common/game_list/worker.cpp' -Raw
if (-not ($worker.Contains('stop_requested.exchange(true)') -and
          $worker.Contains('while (model->current_worker.get() == this)'))) {
    throw 'Game-list worker nested-event lifetime protection is incomplete'
}

Write-Host 'Applied late NS2 stability batch: AMD undefined-register zeroing + safe game-list/content-provider lifetime.'

# Apply the newer targeted donor layers only after the stable PokeDinner/Eglantine stack exists.
& "$PSScriptRoot\apply-ns2-donor-20261101.ps1"
& "$PSScriptRoot\apply-ns2-donor-safe-perf.ps1"
& "$PSScriptRoot\prep-pr142-integrated.ps1"
& "$PSScriptRoot\apply-eglantine-pr142-memory-stutter.ps1"
Apply-FrontierPerformanceBatch
