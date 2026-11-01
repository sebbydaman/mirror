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

# Preserve the older collector optimization: garbage-collector buffer evictions already use their
# own one-wait DownloadBuffersMemory path and must not regress while adding FlushRegion batching.
Require-Text $bufferCache 'void BufferCache<P>::DownloadBuffersMemory(std::span<const BufferId> buffer_ids)' 'existing garbage-collector buffer batching'

Write-Host '[PASS] PR163 coalesced buffer FlushRegion downloads and clipped tracker ranges'
Write-Host 'Safe NX2 donor performance regression validation passed.'
