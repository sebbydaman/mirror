$ErrorActionPreference = 'Stop'

function Require-Text([string]$Path, [string]$Needle, [string]$Name) {
    if (-not (Test-Path $Path -PathType Leaf)) { throw "PR142 regression: missing required file $Path" }
    $text = Get-Content $Path -Raw
    if (-not $text.Contains($Needle)) { throw "PR142 regression: $Name missing from $Path" }
    Write-Host "[PASS] $Name"
}

function Write-PatchedText([string]$Path, [string]$Text) {
    # Get-Content -Raw retains the source's final newline. Set-Content adds another newline when given
    # a scalar string, which made git diff --check report a new blank line at EOF. Normalize to one
    # LF and write without a BOM so the source patch remains semantically and textually clean.
    $normalized = $Text.TrimEnd("`r", "`n") + "`n"
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText((Resolve-Path $Path).Path, $normalized, $utf8NoBom)
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
    Write-PatchedText $profilePath $profile
}

$macro = Get-Content $macroPath -Raw
if (-not $macro.Contains('Nx2Profile::TrackDmaPages()')) {
    # Do not key this patch to whitespace/line-wrapping from one donor revision. Instead locate the
    # actual page-history insertion, prove it belongs to the DmaReadBytes profiling block, then split
    # the expensive page walk into its own TrackDmaPages() gate while leaving the cheap byte counter
    # under the normal profiler gate.
    $insertToken = 'VideoCommon::Nx2Profile::DmaReadPages().insert(*device >> 12);'
    $insertIndex = $macro.IndexOf($insertToken)
    if ($insertIndex -lt 0) {
        throw 'NX2 profiler hardening: DmaReadPages insertion disappeared from macro.cpp'
    }

    $enabledToken = 'if (VideoCommon::Nx2Profile::Enabled()) {'
    $enabledIndex = $macro.LastIndexOf($enabledToken, $insertIndex)
    $addToken = 'VideoCommon::Nx2Profile::Add(VideoCommon::Nx2Profile::Counter::DmaReadBytes, read_bytes);'
    $addIndex = if ($enabledIndex -ge 0) { $macro.IndexOf($addToken, $enabledIndex) } else { -1 }
    $forToken = 'for (GPUVAddr page = source & ~GPUVAddr{0xfff};'
    $forIndex = if ($addIndex -ge 0) { $macro.IndexOf($forToken, $addIndex) } else { -1 }
    if ($enabledIndex -lt 0 -or $addIndex -lt 0 -or $forIndex -lt 0 -or
        $addIndex -gt $insertIndex -or $forIndex -gt $insertIndex) {
        throw 'NX2 profiler hardening: native MME DMA profiling structure changed in macro.cpp'
    }

    $forLineStart = $macro.LastIndexOf("`n", $forIndex)
    if ($forLineStart -lt 0) { $forLineStart = 0 } else { ++$forLineStart }
    $forIndent = $macro.Substring($forLineStart, $forIndex - $forLineStart)
    if ($forIndent -match '[^ \t]') {
        throw 'NX2 profiler hardening: could not determine MME DMA loop indentation'
    }
    $outerIndentLength = [Math]::Max(0, $forIndent.Length - 4)
    $outerIndent = $forIndent.Substring(0, $outerIndentLength)
    $gate = $outerIndent + "}`n" + $outerIndent +
        "if (VideoCommon::Nx2Profile::TrackDmaPages()) {`n"
    $macro = $macro.Insert($forLineStart, $gate)
    Write-PatchedText $macroPath $macro
}

$buffer = Get-Content $bufferPath -Raw
if (-not $buffer.Contains('Nx2Profile::TrackDmaPages()')) {
    # As above, locate the gate that actually owns DmaReadPages() rather than relying on formatting.
    $pageToken = 'const auto& pages = Nx2Profile::DmaReadPages();'
    $pageIndex = $buffer.IndexOf($pageToken)
    $enabledToken = 'if (Nx2Profile::Enabled()) {'
    $gateIndex = if ($pageIndex -ge 0) { $buffer.LastIndexOf($enabledToken, $pageIndex) } else { -1 }
    if ($pageIndex -lt 0 -or $gateIndex -lt 0) {
        throw 'NX2 profiler hardening: buffer-download DmaReadPages profiling structure changed'
    }
    $buffer = $buffer.Remove($gateIndex, $enabledToken.Length).Insert(
        $gateIndex, 'if (Nx2Profile::TrackDmaPages()) {')
    Write-PatchedText $bufferPath $buffer
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
