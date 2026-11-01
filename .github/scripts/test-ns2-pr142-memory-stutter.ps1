$ErrorActionPreference = 'Stop'

function Require-Text([string]$Path, [string]$Needle, [string]$Name) {
    if (-not (Test-Path $Path -PathType Leaf)) { throw "PR142 regression: missing required file $Path" }
    $text = Get-Content $Path -Raw
    if (-not $text.Contains($Needle)) { throw "PR142 regression: $Name missing from $Path" }
    Write-Host "[PASS] $Name"
}

# Keep representative gameplay profiling lightweight. PR #134's deep DMA correlation walks every
# 4-KiB page touched by native MME DMA, translates each page, and inserts it into a process-global
# unordered_set which the buffer-download path later consults. That is useful for a targeted
# readback investigation, but it is too invasive for normal frame-time profiling and is a poor fit
# for the split GPU/readback paths used by this branch. Keep the timing zones/counters behind
# EDEN_NX2_GPU_PROFILE and make page-history correlation a separate explicit opt-in.
$profilePath = 'src/video_core/nx2_profile.h'
$macroPath = 'src/video_core/macro.cpp'
$bufferPath = 'src/video_core/buffer_cache/buffer_cache.h'

foreach ($path in @($profilePath, $macroPath, $bufferPath)) {
    if (-not (Test-Path $path -PathType Leaf)) {
        throw "NX2 profiler hardening: missing required file $path"
    }
}

$profile = Get-Content $profilePath -Raw
if (-not $profile.Contains('EDEN_NX2_GPU_PROFILE_PAGES')) {
    $oldProfile = @'
inline const bool g_enabled = std::getenv("EDEN_NX2_GPU_PROFILE") != nullptr;

inline bool Enabled() {
    return g_enabled;
}
'@
    $newProfile = @'
inline const bool g_enabled = std::getenv("EDEN_NX2_GPU_PROFILE") != nullptr;
// Per-page MME DMA history is intentionally separate from normal gameplay profiling. It performs
// address translation and hash-set insertion for every 4-KiB page and should only be enabled for a
// focused readback investigation.
inline const bool g_track_dma_pages =
    std::getenv("EDEN_NX2_GPU_PROFILE_PAGES") != nullptr;

inline bool Enabled() {
    return g_enabled;
}

inline bool TrackDmaPages() {
    return g_enabled && g_track_dma_pages;
}
'@
    if (-not $profile.Contains($oldProfile)) {
        throw 'NX2 profiler hardening: enable anchor changed in nx2_profile.h'
    }
    $profile = $profile.Replace($oldProfile, $newProfile)
    Set-Content $profilePath $profile -Encoding UTF8
}

$macro = Get-Content $macroPath -Raw
if (-not $macro.Contains('Nx2Profile::TrackDmaPages()')) {
    $oldMacro = @'
        if (VideoCommon::Nx2Profile::Enabled()) {
            VideoCommon::Nx2Profile::Add(VideoCommon::Nx2Profile::Counter::DmaReadBytes, read_bytes);
            for (GPUVAddr page = source & ~GPUVAddr{0xfff}; page < source + read_bytes;
                 page += 0x1000) {
                if (const auto device = memory.GpuToCpuAddress(page)) {
                    VideoCommon::Nx2Profile::DmaReadPages().insert(*device >> 12);
                }
            }
        }
'@
    $newMacro = @'
        if (VideoCommon::Nx2Profile::Enabled()) {
            VideoCommon::Nx2Profile::Add(VideoCommon::Nx2Profile::Counter::DmaReadBytes, read_bytes);
        }
        if (VideoCommon::Nx2Profile::TrackDmaPages()) {
            for (GPUVAddr page = source & ~GPUVAddr{0xfff}; page < source + read_bytes;
                 page += 0x1000) {
                if (const auto device = memory.GpuToCpuAddress(page)) {
                    VideoCommon::Nx2Profile::DmaReadPages().insert(*device >> 12);
                }
            }
        }
'@
    if (-not $macro.Contains($oldMacro)) {
        throw 'NX2 profiler hardening: native MME DMA page-history anchor changed in macro.cpp'
    }
    $macro = $macro.Replace($oldMacro, $newMacro)
    Set-Content $macroPath $macro -Encoding UTF8
}

$buffer = Get-Content $bufferPath -Raw
if (-not $buffer.Contains('Nx2Profile::TrackDmaPages()')) {
    $oldBuffer = @'
                if (Nx2Profile::Enabled()) {
                    const auto& pages = Nx2Profile::DmaReadPages();
'@
    $newBuffer = @'
                if (Nx2Profile::TrackDmaPages()) {
                    const auto& pages = Nx2Profile::DmaReadPages();
'@
    if (-not $buffer.Contains($oldBuffer)) {
        throw 'NX2 profiler hardening: buffer-download page-history anchor changed in buffer_cache.h'
    }
    $buffer = $buffer.Replace($oldBuffer, $newBuffer)
    Set-Content $bufferPath $buffer -Encoding UTF8
}

Require-Text $profilePath 'EDEN_NX2_GPU_PROFILE_PAGES' 'profiler DMA-page history opt-in'
Require-Text $profilePath 'inline bool TrackDmaPages()' 'profiler DMA-page history gate'
Require-Text $macroPath 'Nx2Profile::TrackDmaPages()' 'MME DMA page-history gate'
Require-Text $bufferPath 'Nx2Profile::TrackDmaPages()' 'buffer-download page-history gate'

# Host-RAM / zero-fill tracking.
Require-Text 'src/core/device_memory.h' 'bool used_by_kernel{};' 'device-memory session reuse flag'
Require-Text 'src/core/hle/kernel/k_memory_manager.cpp' 'void KMemoryManager::FillAllocatedPages(' 'selective allocated-page fill implementation'
Require-Text 'src/core/hle/kernel/k_memory_manager.cpp' 'manager.TakeFreedRuns' 'freed-page run clearing'
Require-Text 'src/core/hle/kernel/k_memory_manager.cpp' 'm_page_reference_counts.resize(size / PageSize);' 'per-manager reference-count sizing'
Require-Text 'src/core/hle/kernel/k_memory_manager.h' 'std::unique_ptr<std::atomic<u64>[]> m_freed_pages;' 'atomic freed-page bitmap'
Require-Text 'src/core/hle/kernel/k_memory_manager.h' 'void MarkAllFreed()' 'cross-session freed-page reset'
Require-Text 'src/core/hle/kernel/k_page_table_base.cpp' 'system.Kernel().MemoryManager().FillAllocatedPages' 'page-table selective fill routing'
Require-Text 'src/core/hle/service/nx2_gsv.h' 'kernel_core.MemoryManager().FillAllocatedPages' 'NX2 sparse selective fill routing'

# VRAM budget/stale texture retirement.
Require-Text 'src/video_core/texture_cache/texture_cache_base.h' 'STALE_IMAGE_FRAMES = 3 * 60 * 60' 'three-minute stale-image threshold'
Require-Text 'src/video_core/texture_cache/texture_cache_base.h' 'STALE_DELETES_PER_FRAME = 8' 'bounded stale-image deletion rate'
Require-Text 'src/video_core/texture_cache/texture_cache.h' 'stale_deletes = STALE_DELETES_PER_FRAME' 'incremental stale-image collector'
Require-Text 'src/video_core/texture_cache/texture_cache.h' 'True(image.flags & ImageFlagBits::IsDecoding)' 'stale collector decode-lifetime guard'
Require-Text 'src/video_core/texture_cache/texture_cache.h' 'IsDownloadable(image)' 'stale collector GPU-written-image guard'
Require-Text 'src/video_core/vulkan_common/vulkan_device.cpp' 'main_statistics.blockBytes - main_statistics.allocationBytes' 'VMA reserved-block slack budget accounting'

# Vulkan shader-module lifetime.
Require-Text 'src/video_core/renderer_vulkan/vk_compute_pipeline.cpp' 'Only needed to create the pipeline.' 'compute shader-module release'
Require-Text 'src/video_core/renderer_vulkan/vk_compute_pipeline.cpp' 'spv_module = {};' 'compute SPIR-V module reset'
Require-Text 'src/video_core/renderer_vulkan/vk_graphics_pipeline.cpp' 'modules are only needed to create the pipeline' 'graphics shader-module release'
Require-Text 'src/video_core/renderer_vulkan/vk_graphics_pipeline.cpp' 'spv_modules = {};' 'graphics SPIR-V module reset'

# Our 20 GiB ASTC policy must survive. PR #142's separate force-BC3 commit intentionally stays out.
$vkTexturePath = 'src/video_core/renderer_vulkan/vk_texture_cache.cpp'
$vkTexture = Get-Content $vkTexturePath -Raw
if (-not $vkTexture.Contains('UseBc3ForSwitch2OnSmallCards')) {
    throw 'PR142 regression: existing Switch 2 VRAM-threshold ASTC helper disappeared'
}
if ($vkTexture.Contains('void UseBc3ForSwitch2(const Device& device)')) {
    throw 'PR142 regression: force-BC3-on-every-card donor policy was accidentally imported'
}
Write-Host '[PASS] existing threshold-based ASTC policy preserved'

git diff --check
if ($LASTEXITCODE -ne 0) {
    throw 'NX2 profiler hardening introduced diff errors'
}

Write-Host '[PASS] NX2 gameplay profiler keeps per-page DMA history opt-in'
Write-Host 'Targeted PR #142 RAM/stutter regression validation passed.'
