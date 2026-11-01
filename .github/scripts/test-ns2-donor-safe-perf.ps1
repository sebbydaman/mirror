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

# PR163: coalesce all BufferCache downloads belonging to one MemoryManager::FlushRegion into one
# host-GPU wait, and clip each touched buffer's tracker query to that buffer before clearing ranges.
$bufferCache = 'src/video_core/buffer_cache/buffer_cache.h'
$bufferBase = 'src/video_core/buffer_cache/buffer_cache_base.h'
$memoryManager = 'src/video_core/memory_manager.cpp'
$rasterizerInterface = 'src/video_core/rasterizer_interface.h'
$vkRasterizer = 'src/video_core/renderer_vulkan/vk_rasterizer.cpp'
$vkRasterizerHeader = 'src/video_core/renderer_vulkan/vk_rasterizer.h'

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

Write-Host 'Safe NX2 donor performance regression validation passed.'
