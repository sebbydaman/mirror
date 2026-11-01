$ErrorActionPreference = 'Stop'

function Require-Text([string]$Path, [string]$Needle, [string]$Name) {
    if (-not (Test-Path $Path -PathType Leaf)) { throw "PR142 regression: missing required file $Path" }
    $text = Get-Content $Path -Raw
    if (-not $text.Contains($Needle)) { throw "PR142 regression: $Name missing from $Path" }
    Write-Host "[PASS] $Name"
}

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

Write-Host 'Targeted PR #142 RAM/stutter regression validation passed.'
