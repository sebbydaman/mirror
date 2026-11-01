$ErrorActionPreference = 'Stop'

# Donor-backed Vulkan CPU allocation reduction. Citron/Nextendo retain these descriptor scratch
# vectors per thread so large descriptor sets do not allocate/free heap storage on every draw or
# compute dispatch. The vectors are cleared every call, so descriptor contents and all existing
# synchronization/readback semantics remain unchanged; only capacity is reused.

function Write-PatchedText([string]$Path, [string]$Text) {
    $normalized = $Text.Replace("`r`n", "`n").TrimEnd("`r", "`n") + "`n"
    [IO.File]::WriteAllText((Resolve-Path $Path).Path, $normalized, [Text.UTF8Encoding]::new($false))
}

function Replace-Once([string]$Text, [string]$Old, [string]$New, [string]$Name) {
    $Text = $Text.Replace("`r`n", "`n")
    $Old = $Old.Replace("`r`n", "`n")
    $New = $New.Replace("`r`n", "`n")
    $first = $Text.IndexOf($Old, [StringComparison]::Ordinal)
    if ($first -lt 0) { throw "Vulkan descriptor scratch reuse: missing anchor $Name" }
    if ($Text.IndexOf($Old, $first + $Old.Length, [StringComparison]::Ordinal) -ge 0) {
        throw "Vulkan descriptor scratch reuse: ambiguous anchor $Name"
    }
    return $Text.Substring(0, $first) + $New + $Text.Substring($first + $Old.Length)
}

$graphicsPath = 'src/video_core/renderer_vulkan/vk_graphics_pipeline.cpp'
$computePath = 'src/video_core/renderer_vulkan/vk_compute_pipeline.cpp'
foreach ($path in @($graphicsPath, $computePath)) {
    if (-not (Test-Path $path -PathType Leaf)) {
        throw "Vulkan descriptor scratch reuse: missing $path"
    }
}

$graphics = (Get-Content $graphicsPath -Raw).Replace("`r`n", "`n")
if (-not $graphics.Contains('thread_local boost::container::small_vector<VideoCommon::ImageViewInOut, 64> views;')) {
    $oldGraphics = @'
    boost::container::small_vector<VideoCommon::ImageViewInOut, 64> views;
    boost::container::small_vector<VideoCommon::SamplerId, 64> samplers;
    views.reserve(num_image_elements);
    samplers.reserve(num_textures);
'@
    $newGraphics = @'
    // Retain descriptor scratch capacity on this render thread. clear() destroys the previous
    // logical contents while keeping any heap allocation needed by >64-entry Switch 2 pipelines.
    thread_local boost::container::small_vector<VideoCommon::ImageViewInOut, 64> views;
    thread_local boost::container::small_vector<VideoCommon::SamplerId, 64> samplers;
    views.clear();
    samplers.clear();
    views.reserve(num_image_elements);
    samplers.reserve(num_textures);
'@
    $graphics = Replace-Once $graphics $oldGraphics.TrimEnd("`r", "`n") `
        $newGraphics.TrimEnd("`r", "`n") 'graphics descriptor scratch vectors'
    Write-PatchedText $graphicsPath $graphics
    Write-Host '[APPLIED] thread-local reusable Vulkan graphics descriptor scratch'
} else {
    Write-Host '[PRESENT] thread-local reusable Vulkan graphics descriptor scratch'
}

$compute = (Get-Content $computePath -Raw).Replace("`r`n", "`n")
if (-not $compute.Contains('thread_local boost::container::small_vector<VideoCommon::ImageViewInOut, 64> views;')) {
    $oldCompute = @'
    boost::container::small_vector<VideoCommon::ImageViewInOut, 64> views;
    boost::container::small_vector<VideoCommon::SamplerId, 64> samplers;
'@
    $newCompute = @'
    // Same scratch-capacity reuse as graphics; logical contents are rebuilt every dispatch.
    thread_local boost::container::small_vector<VideoCommon::ImageViewInOut, 64> views;
    thread_local boost::container::small_vector<VideoCommon::SamplerId, 64> samplers;
    views.clear();
    samplers.clear();
'@
    $compute = Replace-Once $compute $oldCompute.TrimEnd("`r", "`n") `
        $newCompute.TrimEnd("`r", "`n") 'compute descriptor scratch vectors'
    Write-PatchedText $computePath $compute
    Write-Host '[APPLIED] thread-local reusable Vulkan compute descriptor scratch'
} else {
    Write-Host '[PRESENT] thread-local reusable Vulkan compute descriptor scratch'
}

foreach ($path in @($graphicsPath, $computePath)) {
    $text = Get-Content $path -Raw
    foreach ($needle in @(
        'thread_local boost::container::small_vector<VideoCommon::ImageViewInOut, 64> views;',
        'thread_local boost::container::small_vector<VideoCommon::SamplerId, 64> samplers;',
        'views.clear();',
        'samplers.clear();'
    )) {
        if (-not $text.Contains($needle)) {
            throw "Vulkan descriptor scratch reuse validation failed: '$needle' missing from $path"
        }
    }
}

& git diff --check
if ($LASTEXITCODE -ne 0) {
    throw 'Vulkan descriptor scratch reuse introduced diff/whitespace errors'
}

Write-Host 'Vulkan descriptor scratch reuse validated: per-call contents rebuilt, retained capacity only.'
