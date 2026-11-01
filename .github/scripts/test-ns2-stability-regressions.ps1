$ErrorActionPreference = 'Stop'

function Require-Text([string]$Path, [string]$Needle, [string]$Name) {
    if (-not (Test-Path $Path)) { throw "NS2 stability regression: missing required file $Path" }
    $text = Get-Content $Path -Raw
    if (-not $text.Contains($Needle)) { throw "NS2 stability regression: $Name missing from $Path" }
    Write-Host "[PASS] $Name"
}

$undef = 'src/shader_recompiler/backend/spirv/emit_spirv_undefined.cpp'
$model = 'src/qt_common/game_list/model.cpp'
$modelHeader = 'src/qt_common/game_list/model.h'
$worker = 'src/qt_common/game_list/worker.cpp'
$workerHeader = 'src/qt_common/game_list/worker.h'

# AMD/NX2 undefined shader registers. Some fragment paths exit before writing colour; leaving U1/U32
# as OpUndef makes the result driver-dependent and produced green/blue garbage on AMD.
Require-Text $undef 'bool UndefIsZero()' 'NX2 undefined-register policy helper'
Require-Text $undef 'EDEN_NX2_UNDEF_ZERO' 'undefined-register rollback switch'
Require-Text $undef 'return UndefIsZero() ? ctx.false_value : ctx.OpUndef(ctx.U1);' 'zero-initialized undefined U1'
Require-Text $undef 'return UndefIsZero() ? ctx.u32_zero_value : ctx.OpUndef(ctx.U32[1]);' 'zero-initialized undefined U32'

# Do not destroy a game-list worker while a nested Qt event loop can still be executing its
# ProcessEvents stack frame, and do not recreate content providers underneath a running title.
Require-Text $modelHeader 'void StopWorker();' 'game-list deferred worker stop declaration'
Require-Text $model 'void GameListModel::StopWorker()' 'game-list deferred worker stop implementation'
Require-Text $model 'current_worker.release()->deleteLater();' 'Qt deferred worker destruction'
Require-Text $model 'if (QtCommon::system->IsPoweredOn())' 'running-game repopulate guard'
Require-Text $model 'Emulation is running, deferring game list reload.' 'running-game content-provider preservation'
Require-Text $workerHeader 'void Stop();' 'game-list worker synchronous stop API'
Require-Text $worker 'stop_requested.exchange(true)' 'idempotent game-list worker shutdown'
Require-Text $worker 'while (model->current_worker.get() == this)' 'nested-event worker replacement guard'

# Reject the old unsafe shapes if a later donor merge accidentally resurrects them. Search for the
# actual controller call rather than the word CreateFactories, because the explanatory comment above
# the guard intentionally mentions that function name too.
$modelText = Get-Content $model -Raw
$repopulateStart = $modelText.IndexOf('void GameListModel::Repopulate()')
if ($repopulateStart -lt 0) { throw 'NS2 stability regression: GameListModel::Repopulate not found' }
$repopulateEnd = $modelText.IndexOf("`n}", $repopulateStart)
if ($repopulateEnd -lt 0) { throw 'NS2 stability regression: end of GameListModel::Repopulate not found' }
$repopulate = $modelText.Substring($repopulateStart, $repopulateEnd - $repopulateStart)
$guard = $repopulate.IndexOf('if (QtCommon::system->IsPoweredOn())')
$factories = $repopulate.IndexOf('GetFileSystemController().CreateFactories')
if ($guard -lt 0 -or $factories -lt 0 -or $guard -gt $factories) {
    throw 'NS2 stability regression: content-provider recreation is no longer guarded while emulation runs'
}

Write-Host 'Late NS2 stability regression validation passed.'

# Validate the newer targeted donor layers chained after this stability stack.
& "$PSScriptRoot\test-ns2-donor-20261101.ps1"
& "$PSScriptRoot\test-ns2-donor-safe-perf.ps1"
& "$PSScriptRoot\test-ns2-pr142-memory-stutter.ps1"

# Frontier performance/profiling batch. These guards validate the final semantic shape rather than
# only checking donor commit names; several paths are intentionally adapted around our newer
# submitted-command snapshot and GPU-written-page coherency layers.
$attribute = 'src/shader_recompiler/frontend/ir/attribute.h'
$textureCache = 'src/video_core/texture_cache/texture_cache.h'
$dmaCpp = 'src/video_core/dma_pusher.cpp'
$dmaHeader = 'src/video_core/dma_pusher.h'
$maxwell = 'src/video_core/engines/maxwell_3d.cpp'
$profile = 'src/video_core/nx2_profile.h'
$pipelineCache = 'src/video_core/renderer_vulkan/vk_pipeline_cache.cpp'
$rasterizer = 'src/video_core/renderer_vulkan/vk_rasterizer.cpp'
$shaderCache = 'src/video_core/shader_cache.cpp'
$gpuSplit = 'src/video_core/gpu_split.cpp'
$bufferCache = 'src/video_core/buffer_cache/buffer_cache.h'
$graphicsPipeline = 'src/video_core/renderer_vulkan/vk_graphics_pipeline.cpp'
$scheduler = 'src/video_core/control/scheduler.cpp'

Require-Text $attribute 'attribute <= Attribute::Generic31W' 'Generic31 full XYZW shader attribute range'
$attributeText = Get-Content $attribute -Raw
if ($attributeText.Contains('attribute <= Attribute::Generic31X;')) {
    throw 'NS2 frontier regression: old Generic31X upper bound returned'
}

Require-Text $textureCache 'constexpr size_t MaxBatchBytes = 64_MiB;' 'bounded batched image readback'
Require-Text $textureCache 'boost::container::small_vector<Pending, 16> pending;' 'batched image download queue'
Require-Text $textureCache 'NativeDrawDiagnostics()' 'cached native-draw diagnostics switch'
$textureText = Get-Content $textureCache -Raw
$downloadStart = $textureText.IndexOf('void TextureCache<P>::DownloadMemory(')
$downloadEnd = $textureText.IndexOf('std::optional<VideoCore::RasterizerDownloadArea>', $downloadStart)
if ($downloadStart -lt 0 -or $downloadEnd -lt 0) { throw 'NS2 frontier regression: could not isolate TextureCache::DownloadMemory' }
$downloadSection = $textureText.Substring($downloadStart, $downloadEnd - $downloadStart)
$finishCount = ([regex]::Matches($downloadSection, [regex]::Escape('runtime.Finish();'))).Count
if ($finishCount -ne 1) {
    throw "NS2 frontier regression: batched DownloadMemory should have exactly one Finish site, found $finishCount"
}

Require-Text $dmaHeader 'GPUVAddr pb_cached_gpu_addr{0};' 'pushbuffer span-cache address'
Require-Text $dmaHeader 'const CommandHeader* pb_cached_ptr{nullptr};' 'pushbuffer span-cache host pointer'
Require-Text $dmaHeader 'u32 skip_words;' 'invalid command-block discard state'
Require-Text $dmaCpp 'memory_manager.GetSpan(dma_state.dma_get, req_bytes)' 'O(1) contiguous pushbuffer span fast-path'
Require-Text $dmaCpp 'dma_state.method += static_cast<u32>(!dma_state.non_incrementing);' 'branchless DMA method increment'
Require-Text $dmaCpp 'curr_method < non_puller_methods && puller.HasPendingAcquire()' 'semaphore polling short-circuit'
Require-Text $dmaCpp 'dma_state.skip_words = remaining;' 'illegal host-method block discard'
Require-Text $dmaCpp 'pb_cached_ptr = nullptr;' 'safe pushbuffer span cache invalidation'

# Snapshot/coherency must remain ahead of the new live-memory fast path: GPU-written command pages
# are flushed first, submitted snapshots are preferred when valid, and only then may live memory be
# served from the span cache.
$dmaText = Get-Content $dmaCpp -Raw
$flushPos = $dmaText.IndexOf('FlushGpuWrittenCommands(')
$snapshotPos = $dmaText.IndexOf('const bool has_snapshot', $flushPos)
$snapshotBranch = $dmaText.IndexOf('if (has_snapshot)', $snapshotPos)
$spanPos = $dmaText.IndexOf('memory_manager.GetSpan(dma_state.dma_get, req_bytes)', $snapshotBranch)
if ($flushPos -lt 0 -or $snapshotPos -lt 0 -or $snapshotBranch -lt 0 -or $spanPos -lt 0 -or
    -not ($flushPos -lt $snapshotPos -and $snapshotPos -lt $snapshotBranch -and $snapshotBranch -lt $spanPos)) {
    throw 'NS2 frontier regression: DMA span fast-path no longer preserves GPU-written flush -> snapshot -> live-memory ordering'
}

Require-Text $maxwell 'Rejecting out-of-range macro bind' 'bounded MME macro position writes'
Require-Text 'src/video_core/macro_turing_jit.h' 'offsetof(State, fail_pc)' 'MME JIT failing-PC capture'
Require-Text 'src/video_core/macro.cpp' 'pc={:#x}' 'MME JIT failing-PC diagnostic'

foreach ($zone in @('DmaFetch', 'DmaDispatch', 'ChannelSwitch', 'SplitCall', 'BindGeometry', 'UpdateVertex', 'UpdateUniform', 'CacheLockWait')) {
    Require-Text $profile $zone "granular GPU profiler zone $zone"
}
Require-Text $profile 'SkippedDraws' 'rejected-draw profiler counter'
Require-Text $profile 'PipelineMisses' 'pipeline-miss profiler counter'
Require-Text $pipelineCache 'Counter::PipelineMisses' 'Vulkan pipeline-miss accounting'
Require-Text $shaderCache 'Counter::SkippedDraws' 'rejected native draw accounting'
Require-Text $rasterizer 'Profile::Zone::CacheLockWait' 'buffer/texture cache lock-wait timing'
Require-Text $gpuSplit 'Nx2Profile::Zone::SplitCall' 'split back-thread deferred-call timing'
Require-Text $bufferCache 'Nx2Profile::Zone::UpdateVertex' 'vertex-buffer resolution timing'
Require-Text $bufferCache 'Nx2Profile::Zone::UpdateUniform' 'uniform-buffer resolution timing'
Require-Text $graphicsPipeline 'Profile::Zone::BindGeometry' 'host geometry bind timing'
Require-Text $scheduler 'Nx2Profile::Zone::ChannelSwitch' 'channel-switch timing'

Write-Host 'NS2 frontier performance/profiling regression validation passed.'

# Finally reject superseded runtime shapes and dormant automation generations. Keeping this last
# means the positive regression tests explain any missing modern feature before the legacy audit
# checks for an old form that may have replaced it.
& "$PSScriptRoot\audit-ns2-legacy-dead-code.ps1"
