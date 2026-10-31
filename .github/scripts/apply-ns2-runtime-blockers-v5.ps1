$ErrorActionPreference = 'Stop'

# Post-SURED runtime correctness: preserve the first GPU write into Switch 2 sparse depth arrays.
# The 01effa sparse path already backs large color arrays per layer, but depth arrays were excluded
# and therefore fell through to UnwrittenSparse. That leaves their host VkImage unbacked: the first
# render marks the image GpuModified even though Vulkan had nowhere to store the write, then the
# later replacement reaches JoinImages' data-loss guard. Generalize the existing sparse-layer path
# to ordinary depth formats instead of bypassing that guard or dropping the modified image.
function Read-Lf([string]$Path) {
    if (-not (Test-Path $Path)) { throw "Missing required source file: $Path" }
    return (Get-Content $Path -Raw).Replace("`r`n", "`n")
}
function Write-Utf8([string]$Path, [string]$Text) {
    Set-Content -Path $Path -Value $Text -Encoding utf8 -NoNewline
}
function Replace-Once([string]$Text, [string]$Old, [string]$New, [string]$Label) {
    $at = $Text.IndexOf($Old)
    if ($at -lt 0) { throw "Could not locate $Label" }
    if ($Text.IndexOf($Old, $at + $Old.Length) -ge 0) { throw "Ambiguous anchor for $Label" }
    return $Text.Substring(0, $at) + $New + $Text.Substring($at + $Old.Length)
}

$path = 'src/video_core/renderer_vulkan/vk_texture_cache.cpp'
$text = Read-Lf $path
$eligibilityMarker = 'const bool sparse_layer_format ='

if (-not $text.Contains($eligibilityMarker)) {
    $oldEligibility = @'
    if (!device.IsSparseResidencyImage2DSupported() || info.type != ImageType::e2D ||
        info.resources.layers <= 1 || info.num_samples != 1 ||
        VideoCore::Surface::GetFormatType(info.format) != VideoCore::Surface::SurfaceType::ColorTexture) {
        return false;
    }
'@
    $newEligibility = @'
    const auto format_type = VideoCore::Surface::GetFormatType(info.format);
    const bool sparse_layer_format =
        format_type == VideoCore::Surface::SurfaceType::ColorTexture ||
        format_type == VideoCore::Surface::SurfaceType::Depth;
    if (!device.IsSparseResidencyImage2DSupported() || info.type != ImageType::e2D ||
        info.resources.layers <= 1 || info.num_samples != 1 || !sparse_layer_format) {
        return false;
    }
'@
    $text = Replace-Once $text $oldEligibility $newEligibility 'SparseLayers format eligibility'

    $oldRequirements = @'
    const auto requirements = device.GetLogical().GetImageSparseMemoryRequirements(handle);
    const auto it = std::ranges::find_if(requirements, [](const auto& r) {
        return (r.formatProperties.aspectMask & VK_IMAGE_ASPECT_COLOR_BIT) != 0;
    });
'@
    $newRequirements = @'
    const auto requirements = device.GetLogical().GetImageSparseMemoryRequirements(handle);
    const VkImageAspectFlags sparse_aspect = ImageAspectMask(info.format);
    const auto it = std::ranges::find_if(requirements, [sparse_aspect](const auto& r) {
        return (r.formatProperties.flags & VK_SPARSE_IMAGE_FORMAT_METADATA_BIT) == 0 &&
               (r.formatProperties.aspectMask & sparse_aspect) != 0;
    });
'@
    $text = Replace-Once $text $oldRequirements $newRequirements 'SparseLayers aspect requirement'

    $bindStart = $text.IndexOf('std::vector<u32> Image::BindLayers(std::span<const u32> layers) {')
    if ($bindStart -lt 0) { throw 'Could not locate BindLayers implementation' }
    $bindEnd = $text.IndexOf('VkImageView Image::StorageImageLayerView', $bindStart)
    if ($bindEnd -lt 0) { throw 'Could not locate end of BindLayers implementation' }
    $bind = $text.Substring($bindStart, $bindEnd - $bindStart)
    $oldAspect = '                    .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,'
    $newAspect = '                    .aspectMask = s.sparse.formatProperties.aspectMask,'
    if (-not $bind.Contains($oldAspect)) { throw 'Could not locate hard-coded sparse color aspect' }
    if ($bind.IndexOf($oldAspect) -ne $bind.LastIndexOf($oldAspect)) {
        throw 'Ambiguous hard-coded sparse color aspect in BindLayers'
    }
    $bind = $bind.Replace($oldAspect, $newAspect)
    $text = $text.Substring(0, $bindStart) + $bind + $text.Substring($bindEnd)

    Write-Utf8 $path $text
}

$check = Read-Lf $path
foreach ($needle in @(
    'const bool sparse_layer_format =',
    'format_type == VideoCore::Surface::SurfaceType::ColorTexture ||',
    'format_type == VideoCore::Surface::SurfaceType::Depth;',
    'const VkImageAspectFlags sparse_aspect = ImageAspectMask(info.format);',
    'VK_SPARSE_IMAGE_FORMAT_METADATA_BIT',
    '.aspectMask = s.sparse.formatProperties.aspectMask,'
    'std::vector<u32> Image::BindLayers(std::span<const u32> layers)'
)) {
    if (-not $check.Contains($needle)) { throw "Runtime-v5 sparse-depth regression: missing $needle" }
}

# Keep the join guard intact. If a GPU-modified image reaches this path for some other reason,
# silently deleting it is still data loss and should remain visible during development.
if (-not $check.Contains('UNIMPLEMENTED();')) {
    throw 'Runtime-v5 regression: texture-cache unimplemented/data-loss guards unexpectedly disappeared'
}

Write-Host 'Generalized sparse-layer backing to depth arrays; first D16 render-target writes now have resident Vulkan memory.'
