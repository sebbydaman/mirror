$ErrorActionPreference = 'Stop'

function Require-Text([string]$Path, [string]$Needle, [string]$Name) {
    if (-not (Test-Path $Path -PathType Leaf)) { throw "PR142 regression: missing required file $Path" }
    $text = Get-Content $Path -Raw
    if (-not $text.Contains($Needle)) { throw "PR142 regression: $Name missing from $Path" }
    Write-Host "[PASS] $Name"
}

function Write-PatchedText([string]$Path, [string]$Text) {
    $normalized = $Text.Replace("`r`n", "`n").TrimEnd("`r", "`n") + "`n"
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText((Resolve-Path $Path).Path, $normalized, $utf8NoBom)
}

# Keep representative gameplay profiling lightweight. The donor PR #134 profiler's deep DMA
# correlation translates every 4-KiB page touched by native MME DMA and stores it in a process-global
# set. That is useful for targeted readback work but too invasive for normal frame-time profiling.
$profilePath = 'src/video_core/nx2_profile.h'
$macroPath = 'src/video_core/macro.cpp'
$bufferPath = 'src/video_core/buffer_cache/buffer_cache.h'
$textureProfilePath = 'src/video_core/texture_cache/texture_cache.h'
foreach ($path in @($profilePath, $macroPath, $bufferPath, $textureProfilePath)) {
    if (-not (Test-Path $path -PathType Leaf)) { throw "NX2 profiler hardening: missing $path" }
}

# Earlier frontier adapters intentionally normalize generated source to LF. Normalize both the
# current profiler and these multi-line here-string anchors so profiler counter additions cannot
# make the page-history hardening fail only because the Windows checkout uses CRLF.
$profile = (Get-Content $profilePath -Raw).Replace("`r`n", "`n")
if (-not $profile.Contains('EDEN_NX2_GPU_PROFILE_PAGES')) {
    $oldProfile = @'
inline const bool g_enabled = std::getenv("EDEN_NX2_GPU_PROFILE") != nullptr;

inline bool Enabled() {
    return g_enabled;
}
'@
    $newProfile = @'
inline const bool g_enabled = std::getenv("EDEN_NX2_GPU_PROFILE") != nullptr;
// Per-page MME DMA history is intentionally separate from normal gameplay profiling. Treat an
// explicit 0 as disabled so the profile launcher can document the switch without enabling it.
inline const bool g_track_dma_pages = [] {
    const char* value = std::getenv("EDEN_NX2_GPU_PROFILE_PAGES");
    return value != nullptr && value[0] != '0';
}();

inline bool Enabled() {
    return g_enabled;
}

inline bool TrackDmaPages() {
    return g_enabled && g_track_dma_pages;
}
'@
    $oldProfile = $oldProfile.Replace("`r`n", "`n").TrimEnd("`r", "`n")
    $newProfile = $newProfile.Replace("`r`n", "`n").TrimEnd("`r", "`n")
    if (-not $profile.Contains($oldProfile)) {
        throw 'NX2 profiler hardening: enable anchor changed in nx2_profile.h'
    }
    Write-PatchedText $profilePath ($profile.Replace($oldProfile, $newProfile))
} else {
    # Older captures of this hardening treated any present value, including "0", as enabled.
    $profile = (Get-Content $profilePath -Raw).Replace("`r`n", "`n")
    $oldPages = @'
inline const bool g_track_dma_pages =
    std::getenv("EDEN_NX2_GPU_PROFILE_PAGES") != nullptr;
'@
    $oldPages = $oldPages.Replace("`r`n", "`n").TrimEnd("`r", "`n")
    if ($profile.Contains($oldPages)) {
        $newPages = @'
inline const bool g_track_dma_pages = [] {
    const char* value = std::getenv("EDEN_NX2_GPU_PROFILE_PAGES");
    return value != nullptr && value[0] != '0';
}();
'@
        Write-PatchedText $profilePath ($profile.Replace(
            $oldPages, $newPages.Replace("`r`n", "`n").TrimEnd("`r", "`n")))
    }
}

# The packaged profile launcher sets EDEN_NX2_TC_LOG=0. Presence-only parsing made that turn the
# expensive periodic texture-cache inventory/sort on. Keep the debug switch available, but make 0
# actually mean off so profiling does not manufacture its own CPU load.
$textureProfile = (Get-Content $textureProfilePath -Raw).Replace("`r`n", "`n")
$oldTcFlag = 'static const bool log_tc = std::getenv("EDEN_NX2_TC_LOG") != nullptr;'
if ($textureProfile.Contains($oldTcFlag)) {
    $newTcFlag = @'
static const bool log_tc = [] {
        const char* value = std::getenv("EDEN_NX2_TC_LOG");
        return value != nullptr && value[0] != '0';
    }();
'@
    Write-PatchedText $textureProfilePath ($textureProfile.Replace(
        $oldTcFlag, $newTcFlag.Replace("`r`n", "`n").TrimEnd("`r", "`n")))
}

$macro = Get-Content $macroPath -Raw
if (-not $macro.Contains('Nx2Profile::TrackDmaPages()')) {
    $insertToken = 'VideoCommon::Nx2Profile::DmaReadPages().insert(*device >> 12);'
    $insertIndex = $macro.IndexOf($insertToken)
    if ($insertIndex -lt 0) { throw 'NX2 profiler hardening: DmaReadPages insertion disappeared' }
    $enabledToken = 'if (VideoCommon::Nx2Profile::Enabled()) {'
    $enabledIndex = $macro.LastIndexOf($enabledToken, $insertIndex)
    $addToken = 'VideoCommon::Nx2Profile::Add(VideoCommon::Nx2Profile::Counter::DmaReadBytes, read_bytes);'
    $addIndex = if ($enabledIndex -ge 0) { $macro.IndexOf($addToken, $enabledIndex) } else { -1 }
    $forToken = 'for (GPUVAddr page = source & ~GPUVAddr{0xfff};'
    $forIndex = if ($addIndex -ge 0) { $macro.IndexOf($forToken, $addIndex) } else { -1 }
    if ($enabledIndex -lt 0 -or $addIndex -lt 0 -or $forIndex -lt 0 -or
        $addIndex -gt $insertIndex -or $forIndex -gt $insertIndex) {
        throw 'NX2 profiler hardening: native MME DMA profiling structure changed'
    }
    $forLineStart = $macro.LastIndexOf("`n", $forIndex)
    if ($forLineStart -lt 0) { $forLineStart = 0 } else { ++$forLineStart }
    $forIndent = $macro.Substring($forLineStart, $forIndex - $forLineStart)
    if ($forIndent -match '[^ \t]') { throw 'NX2 profiler hardening: loop indentation changed' }
    $outerIndent = $forIndent.Substring(0, [Math]::Max(0, $forIndent.Length - 4))
    $gate = $outerIndent + "}`n" + $outerIndent + "if (VideoCommon::Nx2Profile::TrackDmaPages()) {`n"
    Write-PatchedText $macroPath ($macro.Insert($forLineStart, $gate))
}

$buffer = Get-Content $bufferPath -Raw
if (-not $buffer.Contains('Nx2Profile::TrackDmaPages()')) {
    $pageToken = 'const auto& pages = Nx2Profile::DmaReadPages();'
    $pageIndex = $buffer.IndexOf($pageToken)
    $enabledToken = 'if (Nx2Profile::Enabled()) {'
    $gateIndex = if ($pageIndex -ge 0) { $buffer.LastIndexOf($enabledToken, $pageIndex) } else { -1 }
    if ($pageIndex -lt 0 -or $gateIndex -lt 0) {
        throw 'NX2 profiler hardening: buffer-download page-history gate changed'
    }
    $buffer = $buffer.Remove($gateIndex, $enabledToken.Length).Insert(
        $gateIndex, 'if (Nx2Profile::TrackDmaPages()) {')
    Write-PatchedText $bufferPath $buffer
}

Require-Text $profilePath 'EDEN_NX2_GPU_PROFILE_PAGES' 'profiler DMA-page history opt-in'
Require-Text $profilePath 'const char* value = std::getenv("EDEN_NX2_GPU_PROFILE_PAGES");' 'profiler page-history zero-value parsing'
Require-Text $profilePath "return value != nullptr && value[0] != '0';" 'profiler zero-valued debug switch disable path'
Require-Text $profilePath 'inline bool TrackDmaPages()' 'profiler DMA-page history gate'
Require-Text $macroPath 'Nx2Profile::TrackDmaPages()' 'MME DMA page-history gate'
Require-Text $bufferPath 'Nx2Profile::TrackDmaPages()' 'buffer-download page-history gate'
Require-Text $textureProfilePath 'const char* value = std::getenv("EDEN_NX2_TC_LOG");' 'texture-cache log zero-value parsing'

# Wael3rd/Eglantine-MKW post-release fix 5fdcbff: guest subgroup width is observable only when a
# compute shader actually uses warp/subgroup operations. Keep SIMD32 for those shaders, but avoid
# unnecessarily constraining ordinary compute kernels. Use structural anchors so LF/CRLF or harmless
# formatting differences cannot break the integration again.
$vkComputePath = 'src/video_core/renderer_vulkan/vk_compute_pipeline.cpp'
if (-not (Test-Path $vkComputePath -PathType Leaf)) {
    throw 'MKW subgroup optimization: Vulkan compute pipeline source is missing'
}
$vkCompute = Get-Content $vkComputePath -Raw
if (-not $vkCompute.Contains('const bool uses_warp_ops =')) {
    $subgroupToken = '.requiredSubgroupSize = GuestWarpSize,'
    $subgroupIndex = $vkCompute.IndexOf($subgroupToken)
    if ($subgroupIndex -lt 0) {
        throw 'MKW subgroup optimization: required subgroup-size field disappeared'
    }
    $structClose = $vkCompute.IndexOf('};', $subgroupIndex)
    if ($structClose -lt 0 -or $structClose - $subgroupIndex -gt 256) {
        throw 'MKW subgroup optimization: subgroup-size structure changed unexpectedly'
    }
    $afterStruct = $structClose + 2
    $insert = @'

        // Only subgroup/warp operations can observe the guest warp width. Avoid constraining
        // ordinary compute kernels to SIMD32 when the driver can choose a better native width.
        const bool uses_warp_ops = info.uses_subgroup_vote || info.uses_subgroup_invocation_id ||
                                   info.uses_subgroup_shuffles || info.uses_subgroup_mask ||
                                   info.uses_quad_shuffles || info.uses_fswzadd;
'@
    $vkCompute = $vkCompute.Insert($afterStruct, $insert)

    $oldExpression = 'device.IsExtSubgroupSizeControlSupported() ? &subgroup_size_ci : nullptr'
    $expressionIndex = $vkCompute.IndexOf($oldExpression, $afterStruct)
    if ($expressionIndex -lt 0) {
        throw 'MKW subgroup optimization: compute subgroup pNext expression changed'
    }
    $newExpression = 'device.IsExtSubgroupSizeControlSupported() && uses_warp_ops ? &subgroup_size_ci : nullptr'
    $vkCompute = $vkCompute.Remove($expressionIndex, $oldExpression.Length).Insert(
        $expressionIndex, $newExpression)
    Write-PatchedText $vkComputePath $vkCompute
}
Require-Text $vkComputePath 'const bool uses_warp_ops =' 'MKW compute subgroup usage gate'
Require-Text $vkComputePath 'device.IsExtSubgroupSizeControlSupported() && uses_warp_ops' 'conditional guest subgroup-size request'

$required = @(
    @('src/core/device_memory.h', 'bool used_by_kernel{};', 'device-memory session reuse flag'),
    @('src/core/hle/kernel/k_memory_manager.cpp', 'void KMemoryManager::FillAllocatedPages(', 'selective allocated-page fill implementation'),
    @('src/core/hle/kernel/k_memory_manager.cpp', 'manager.TakeFreedRuns', 'freed-page run clearing'),
    @('src/core/hle/kernel/k_memory_manager.cpp', 'm_page_reference_counts.resize(size / PageSize);', 'per-manager reference-count sizing'),
    @('src/core/hle/kernel/k_memory_manager.h', 'std::unique_ptr<std::atomic<u64>[]> m_freed_pages;', 'atomic freed-page bitmap'),
    @('src/core/hle/kernel/k_memory_manager.h', 'void MarkAllFreed()', 'cross-session freed-page reset'),
    @('src/core/hle/kernel/k_page_table_base.cpp', 'system.Kernel().MemoryManager().FillAllocatedPages', 'page-table selective fill routing'),
    @('src/core/hle/service/nx2_gsv.h', 'kernel_core.MemoryManager().FillAllocatedPages', 'NX2 sparse selective fill routing'),
    @('src/video_core/texture_cache/texture_cache_base.h', 'STALE_IMAGE_FRAMES = 3 * 60 * 60', 'three-minute stale-image threshold'),
    @('src/video_core/texture_cache/texture_cache_base.h', 'STALE_DELETES_PER_FRAME = 8', 'bounded stale-image deletion rate'),
    @('src/video_core/texture_cache/texture_cache.h', 'stale_deletes = STALE_DELETES_PER_FRAME', 'incremental stale-image collector'),
    @('src/video_core/texture_cache/texture_cache.h', 'True(image.flags & ImageFlagBits::IsDecoding)', 'stale collector decode-lifetime guard'),
    @('src/video_core/texture_cache/texture_cache.h', 'IsDownloadable(image)', 'stale collector GPU-written-image guard'),
    @('src/video_core/vulkan_common/vulkan_device.cpp', 'main_statistics.blockBytes - main_statistics.allocationBytes', 'VMA reserved-block slack budget accounting'),
    @('src/video_core/renderer_vulkan/vk_compute_pipeline.cpp', 'Only needed to create the pipeline.', 'compute shader-module release'),
    @('src/video_core/renderer_vulkan/vk_compute_pipeline.cpp', 'spv_module = {};', 'compute SPIR-V module reset'),
    @('src/video_core/renderer_vulkan/vk_graphics_pipeline.cpp', 'modules are only needed to create the pipeline', 'graphics shader-module release'),
    @('src/video_core/renderer_vulkan/vk_graphics_pipeline.cpp', 'spv_modules = {};', 'graphics SPIR-V module reset')
)
foreach ($entry in $required) { Require-Text $entry[0] $entry[1] $entry[2] }

# Preserve our 20 GiB ASTC policy; the donor's force-BC3-on-every-card policy intentionally stays out.
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
if ($LASTEXITCODE -ne 0) { throw 'NX2 profiler/MKW subgroup hardening introduced diff errors' }

Write-Host '[PASS] NX2 gameplay profiler keeps per-page DMA history opt-in'
Write-Host '[PASS] profiler launcher zero-valued debug switches are actually disabled'
Write-Host '[PASS] MKW non-warp compute pipelines can use the driver-native subgroup size'
Write-Host 'Targeted PR #142 RAM/stutter regression validation passed.'
