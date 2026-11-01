$ErrorActionPreference = 'Stop'

# The span-cache hardening depends on PR157, so apply it after the complete integration stack has
# been assembled (this regression script runs after apply-eglantine-late-stability). Keeping the
# layer outside the donor patch makes the bisect boundary explicit.
$frontierHardening = Join-Path $PSScriptRoot '..\frontier\apply-pushbuffer-mapgen-hardening.ps1'
if (-not (Test-Path $frontierHardening -PathType Leaf)) {
    throw "Safe donor regression: missing frontier hardening layer $frontierHardening"
}
& $frontierHardening

# zortos293/Eglantine build 31 contains a small group of CPU/JIT/cache hot-path changes that are
# independent of its newer readback subsystem. Apply only that guarded subset after the proven
# donor stack so the fast baseline validates the exact source that the compiler will see.
$build31Frontier = Join-Path $PSScriptRoot '..\frontier\apply-zortos-build31-perf.ps1'
if (-not (Test-Path $build31Frontier -PathType Leaf)) {
    throw "Safe donor regression: missing Zortos build31 frontier layer $build31Frontier"
}
& $build31Frontier

# Keep the texture partial-write frontier as a guarded architecture check. Zortos 11a110898 still
# uses the old per-page MarkPartialWrite loop, while the integrated NS2 texture cache currently has
# no MarkPartialWrite/partial_dirty_pages path. The frontier therefore validates/preserves whatever
# architecture is actually present rather than forcing a speculative cross-architecture rewrite.
$partialWriteFrontier = Join-Path $PSScriptRoot '..\frontier\apply-zortos-build31-partial-write.ps1'
if (-not (Test-Path $partialWriteFrontier -PathType Leaf)) {
    throw "Safe donor regression: missing Zortos build31 partial-write layer $partialWriteFrontier"
}
& $partialWriteFrontier

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

$hasPartialFunction = $textureText.Contains('void TextureCache<P>::MarkPartialWrite')
$hasPartialPages = $textureText.Contains('image.partial_dirty_pages')
$hasCoalescedLookup = $textureText.Contains('const auto begin_it = std::lower_bound(pages.begin(), pages.end(), first);')
$hasCoalescedFill = $textureText.Contains('std::iota(inserted, inserted + (last - first + 1), first);')
$hasCoalescedRange = $textureText.Contains('size_t{run_end - run_begin} << Core::DEVICE_PAGEBITS')
$coalescedCount = @($hasCoalescedLookup, $hasCoalescedFill, $hasCoalescedRange).Where({ $_ }).Count
if ($coalescedCount -gt 0 -and $coalescedCount -lt 3) {
    throw 'Safe donor regression: incomplete coalesced texture partial-write implementation detected'
}
if ($coalescedCount -eq 3) {
    Write-Host '[PASS] coalesced texture partial-write tracking is complete'
} elseif ($hasPartialFunction -and $hasPartialPages) {
    Write-Host '[PASS] donor/current per-page texture partial-write path is preserved'
} elseif ($hasPartialFunction -xor $hasPartialPages) {
    throw 'Safe donor regression: inconsistent texture partial-write feature markers detected'
} else {
    Write-Host '[PASS] texture partial-write frontier is inapplicable to the integrated texture-cache architecture'
}

# PR163: coalesce all BufferCache downloads belonging to one MemoryManager::FlushRegion into one
# host-GPU wait, and clip each touched buffer's tracker query to that buffer before clearing ranges.
$bufferCache = 'src/video_core/buffer_cache/buffer_cache.h'
$bufferBase = 'src/video_core/buffer_cache/buffer_cache_base.h'
$memoryManager = 'src/video_core/memory_manager.cpp'
$memoryManagerHeader = 'src/video_core/memory_manager.h'
$rasterizerInterface = 'src/video_core/rasterizer_interface.h'
$vkRasterizer = 'src/video_core/renderer_vulkan/vk_rasterizer.cpp'
$vkRasterizerHeader = 'src/video_core/renderer_vulkan/vk_rasterizer.h'
$dmaPusher = 'src/video_core/dma_pusher.cpp'
$dmaPusherHeader = 'src/video_core/dma_pusher.h'

Require-Text $bufferBase 'void BeginDownloadBatch();' 'buffer download batch public entry'
Require-Text $bufferBase 'void FinishDownloadBatch();' 'buffer download batch completion helper'
Require-Text $bufferBase 'u32 download_batch_depth{0};' 'nested buffer download batch depth'
Require-Text $bufferCache 'void BufferCache<P>::BeginDownloadBatch()' 'buffer download batch lock begin'
Require-Text $bufferCache 'void BufferCache<P>::EndDownloadBatch()' 'buffer download batch lock end'
Require-Text $bufferCache 'void BufferCache<P>::FinishDownloadBatch()' 'coalesced buffer batch finish'
Require-Text $bufferCache 'const DAddr range_begin = (std::max)(buffer_begin, device_addr);' 'buffer flush lower-bound clipping'
Require-Text $bufferCache '(std::min)(static_cast<DAddr>(buffer_begin + buffer.SizeBytes()), device_addr + size);' 'buffer flush upper-bound clipping'
Require-Text $bufferCache 'runtime.DownloadStagingBuffer(total_size_bytes, true);' 'deferred staging for batched buffer downloads'
Require-Text $bufferCache 'runtime.FreeDeferredStagingBuffer(download.staging);' 'deferred staging release after batch wait'
Require-Text $memoryManager 'const bool is_buffer_only = which == VideoCommon::CacheType::BufferCache;' 'buffer-only FlushRegion batch gate'
Require-Text $memoryManager 'batched->BeginFlushBatch();' 'MemoryManager begins one buffer flush batch'
Require-Text $memoryManager 'batched->EndFlushBatch();' 'RAII buffer flush batch completion'
Require-Text $rasterizerInterface 'virtual void BeginFlushBatch() {}' 'rasterizer flush-batch interface'
Require-Text $vkRasterizerHeader 'void BeginFlushBatch() override;' 'Vulkan flush-batch override'
Require-Text $vkRasterizer 'buffer_cache.BeginDownloadBatch();' 'Vulkan forwards flush-batch begin'
Require-Text $vkRasterizer 'buffer_cache.EndDownloadBatch();' 'Vulkan forwards flush-batch end'

$bufferText = Get-Content $bufferCache -Raw
$downloadStart = $bufferText.IndexOf('void BufferCache<P>::DownloadBufferMemory(Buffer& buffer, DAddr device_addr, u64 size)')
if ($downloadStart -lt 0) { throw 'Safe donor regression: DownloadBufferMemory range overload not found' }
$downloadEnd = $bufferText.IndexOf("`ntemplate <class P>", $downloadStart + 20)
if ($downloadEnd -lt 0) { throw 'Safe donor regression: DownloadBufferMemory function end not found' }
$downloadSection = $bufferText.Substring($downloadStart, $downloadEnd - $downloadStart)
$clipPos = $downloadSection.IndexOf('const DAddr range_begin = (std::max)(buffer_begin, device_addr);')
$trackerPos = $downloadSection.IndexOf('memory_tracker.ForEachDownloadRangeAndClear(')
if ($clipPos -lt 0 -or $trackerPos -lt 0 -or $clipPos -gt $trackerPos) {
    throw 'Safe donor regression: buffer range is no longer clipped before memory tracker clearing'
}

$finishStart = $bufferText.IndexOf('void BufferCache<P>::FinishDownloadBatch()')
$finishEnd = $bufferText.IndexOf("`ntemplate <class P>", $finishStart + 20)
if ($finishStart -lt 0 -or $finishEnd -lt 0) { throw 'Safe donor regression: could not isolate FinishDownloadBatch' }
$finishSection = $bufferText.Substring($finishStart, $finishEnd - $finishStart)
$finishCount = ([regex]::Matches($finishSection, [regex]::Escape('runtime.Finish();'))).Count
if ($finishCount -ne 1) {
    throw "Safe donor regression: FinishDownloadBatch must contain exactly one GPU Finish, found $finishCount"
}
if (-not $finishSection.Contains('downloads.swap(batched_downloads);')) {
    throw 'Safe donor regression: batch queue is not detached before the GPU wait/writeback'
}
Require-Text $bufferCache 'void BufferCache<P>::DownloadBuffersMemory(std::span<const BufferId> buffer_ids)' 'existing garbage-collector buffer batching'
Write-Host '[PASS] PR163 coalesced buffer FlushRegion downloads and clipped tracker ranges'

# PR160: a shader set already known rejected can never produce a graphics pipeline. The fast bail
# must happen before draw work/cache synchronization, while dirty shader registers must still take
# the normal refresh path so a newly changed program gets another chance to compile.
$shaderCache = 'src/video_core/shader_cache.cpp'
$shaderCacheHeader = 'src/video_core/shader_cache.h'
Require-Text $shaderCacheHeader 'bool AreShadersValid() const noexcept;' 'rejected-shader fast validity query'
Require-Text $shaderCache 'if (!maxwell3d->dirty.flags[VideoCommon::Dirty::Shaders])' 'dirty-shader bypass protection'
Require-Text $shaderCache 'return last_shaders_valid;' 'remembered shader validity result'
Require-Text $vkRasterizer 'if (!pipeline_cache.AreShadersValid())' 'rejected draw early bailout'
Require-Text $vkRasterizer 'Counter::SkippedDraws' 'early-bailout profiling counter'

$vkText = Get-Content $vkRasterizer -Raw
$prepareStart = $vkText.IndexOf('void RasterizerVulkan::PrepareDraw(bool is_indexed, Func&& draw_func)')
if ($prepareStart -lt 0) { throw 'Safe donor regression: RasterizerVulkan::PrepareDraw not found' }
$prepareEnd = $vkText.IndexOf("`n}", $prepareStart)
if ($prepareEnd -lt 0) { throw 'Safe donor regression: PrepareDraw function end not found' }
$prepare = $vkText.Substring($prepareStart, $prepareEnd - $prepareStart)
$bailPos = $prepare.IndexOf('if (!pipeline_cache.AreShadersValid())')
$flushWorkPos = $prepare.IndexOf('Profile::Zone::FlushWork')
$flushCachingPos = $prepare.IndexOf('gpu_memory->FlushCaching()')
$lockPos = $prepare.IndexOf('std::lock(buffer_cache.mutex, texture_cache.mutex)')
if ($bailPos -lt 0 -or $flushWorkPos -lt 0 -or $flushCachingPos -lt 0 -or $lockPos -lt 0 -or
    -not ($bailPos -lt $flushWorkPos -and $bailPos -lt $flushCachingPos -and $bailPos -lt $lockPos)) {
    throw 'Safe donor regression: rejected-shader bailout is no longer ahead of flush/cache-lock work'
}
Write-Host '[PASS] PR160 rejected shaders bail before draw synchronization work'

# PR162: identical small uniform payloads may reuse the same stream allocation only while its
# scheduler tick is still current. A new runtime resets all remembered refs; OpenGL stays on the
# original path; and EDEN_NX2_UBOREUSE=0 is an explicit rollback/debug switch.
$uboReuse = 'src/video_core/buffer_cache/uniform_stream_reuse.h'
$vkBufferCache = 'src/video_core/renderer_vulkan/vk_buffer_cache.h'
Require-Text $uboReuse 'EDEN_NX2_UBOREUSE' 'UBO stream reuse rollback switch'
Require-Text $uboReuse 'static constexpr u32 MaxBytes = 4096;' 'small-UBO reuse size ceiling'
Require-Text $uboReuse 'slot.size == size && std::memcmp(slot.bytes.data(), scratch, size) == 0' 'byte-identical UBO requirement'
Require-Text $uboReuse 'same_bytes && slot.tick == runtime.CurrentTick()' 'same-command-buffer tick requirement'
Require-Text $uboReuse 'runtime.RebindStreamUniform(slot.ref, size);' 'stream allocation rebind on reuse hit'
Require-Text $bufferCache 'VideoCommon::ResetUniformStreamReuse<Runtime>();' 'UBO reuse reset for new runtime'
Require-Text $bufferCache 'if constexpr (!IS_OPENGL && VideoCommon::StreamUniformReusable<Runtime>)' 'Vulkan-only UBO reuse gate'
Require-Text $bufferCache 'VideoCommon::BindSmallUniformReusing(' 'small uniform reuse integration'
Require-Text $vkBufferCache 'struct StreamUniformRef' 'Vulkan stream-uniform allocation reference'
Require-Text $vkBufferCache 'LastStreamUniformRef() const noexcept' 'latest stream uniform reference accessor'
Require-Text $vkBufferCache 'void RebindStreamUniform(const StreamUniformRef& ref, u32 size)' 'descriptor rebind without stream copy'
Require-Text $vkBufferCache 'StreamUniformRef last_stream_uniform{};' 'stored latest Vulkan stream reference'
Write-Host '[PASS] PR162 uniform stream reuse is byte/tick bounded and reset-safe'

# Our #157 hardening: the raw host pointer cache must never survive a GMMU mapping epoch. Map,
# sparse-map and unmap keep the generation odd while mutating and even when stable; DmaPusher only
# reuses an old pointer in the same stable generation and only caches a new span when the generation
# is unchanged across address translation.
Require-Text $memoryManagerHeader 'u64 MappingGeneration() const noexcept' 'GMMU mapping generation reader'
Require-Text $memoryManagerHeader 'std::atomic<u64> mapping_generation{0};' 'GMMU mapping epoch storage'
Require-Text $memoryManager 'class MappingGenerationWrite' 'RAII GMMU mapping write epoch'
Require-Text $memoryManager 'generation.fetch_add(1, std::memory_order_acq_rel);' 'odd epoch at mapping mutation begin'
Require-Text $memoryManager 'generation.fetch_add(1, std::memory_order_release);' 'even epoch at mapping mutation end'
Require-Text $dmaPusherHeader 'u64 pb_cached_mapping_generation{~u64{0}};' 'cached pushbuffer mapping epoch'
Require-Text $dmaPusher 'const bool mapping_stable = (mapping_generation & 1) == 0;' 'stable-even mapping requirement'
Require-Text $dmaPusher 'pb_cached_mapping_generation == mapping_generation' 'cached pointer epoch match'
Require-Text $dmaPusher 'const u64 after_translation = memory_manager.MappingGeneration();' 'post-translation epoch check'
Require-Text $dmaPusher 'if (after_translation == mapping_generation)' 'same-epoch span retention'
Require-Text $dmaPusher 'pb_cached_mapping_generation = ~u64{0};' 'mapping epoch cache invalidation'

$dmaText = Get-Content $dmaPusher -Raw
$stablePos = $dmaText.IndexOf('const bool mapping_stable = (mapping_generation & 1) == 0;')
$cacheGenPos = $dmaText.IndexOf('pb_cached_mapping_generation == mapping_generation', $stablePos)
$getSpanPos = $dmaText.IndexOf('memory_manager.GetSpan(dma_state.dma_get, req_bytes)', $cacheGenPos)
$afterPos = $dmaText.IndexOf('const u64 after_translation = memory_manager.MappingGeneration();', $getSpanPos)
$retainPos = $dmaText.IndexOf('pb_cached_mapping_generation = mapping_generation;', $afterPos)
if ($stablePos -lt 0 -or $cacheGenPos -lt 0 -or $getSpanPos -lt 0 -or $afterPos -lt 0 -or $retainPos -lt 0 -or
    -not ($stablePos -lt $cacheGenPos -and $cacheGenPos -lt $getSpanPos -and $getSpanPos -lt $afterPos -and $afterPos -lt $retainPos)) {
    throw 'Safe donor regression: pushbuffer span-cache mapping epoch ordering is incomplete'
}
Write-Host '[PASS] pushbuffer raw-pointer cache is bounded by stable GMMU mapping epochs'

Write-Host 'Safe NX2 donor performance regression validation passed.'