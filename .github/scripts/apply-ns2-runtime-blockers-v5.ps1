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
    # Patch small semantic anchors rather than entire formatted blocks. Earlier scripts can
    # normalize whitespace/line endings without changing these conditions' meaning.
    $usesSparseSignature =
        '[[nodiscard]] bool UsesSparseLayers(const Device& device, const ImageInfo& info, GPUVAddr gpu_addr) {'
    $newUsesSparseSignature = @'
[[nodiscard]] bool UsesSparseLayers(const Device& device, const ImageInfo& info, GPUVAddr gpu_addr) {
    const auto format_type = VideoCore::Surface::GetFormatType(info.format);
    const bool sparse_layer_format =
        format_type == VideoCore::Surface::SurfaceType::ColorTexture ||
        format_type == VideoCore::Surface::SurfaceType::Depth;
'@
    $text = Replace-Once $text $usesSparseSignature $newUsesSparseSignature 'UsesSparseLayers signature'

    $colorOnlyCondition =
        'VideoCore::Surface::GetFormatType(info.format) != VideoCore::Surface::SurfaceType::ColorTexture) {'
    $text = Replace-Once $text $colorOnlyCondition '!sparse_layer_format) {' 'SparseLayers color-only condition'

    # Scope the sparse-requirement edits to InitSparseLayers so identical lambdas elsewhere cannot
    # become accidental anchors.
    $initStart = $text.IndexOf('bool Image::InitSparseLayers() {')
    if ($initStart -lt 0) { throw 'Could not locate InitSparseLayers implementation' }
    $initEnd = $text.IndexOf('std::vector<u32> Image::BindLayers(std::span<const u32> layers) {', $initStart)
    if ($initEnd -lt 0) { throw 'Could not locate end of InitSparseLayers implementation' }
    $init = $text.Substring($initStart, $initEnd - $initStart)

    $requirementsLine = '    const auto requirements = device.GetLogical().GetImageSparseMemoryRequirements(handle);'
    $requirementsWithAspect = $requirementsLine + "`n" +
        '    const VkImageAspectFlags sparse_aspect = ImageAspectMask(info.format);'
    $init = Replace-Once $init $requirementsLine $requirementsWithAspect 'InitSparseLayers requirements line'
    $init = Replace-Once $init 'std::ranges::find_if(requirements, [](const auto& r) {' `
        'std::ranges::find_if(requirements, [sparse_aspect](const auto& r) {' `
        'InitSparseLayers requirement lambda capture'
    $oldAspectPredicate = '        return (r.formatProperties.aspectMask & VK_IMAGE_ASPECT_COLOR_BIT) != 0;'
    $newAspectPredicate =
        '        return (r.formatProperties.flags & VK_SPARSE_IMAGE_FORMAT_METADATA_BIT) == 0 &&' + "`n" +
        '               (r.formatProperties.aspectMask & sparse_aspect) != 0;'
    $init = Replace-Once $init $oldAspectPredicate $newAspectPredicate 'InitSparseLayers aspect predicate'
    $text = $text.Substring(0, $initStart) + $init + $text.Substring($initEnd)

    $bindStart = $text.IndexOf('std::vector<u32> Image::BindLayers(std::span<const u32> layers) {')
    if ($bindStart -lt 0) { throw 'Could not locate BindLayers implementation' }
    $bindEnd = $text.IndexOf('VkImageView Image::StorageImageLayerView', $bindStart)
    if ($bindEnd -lt 0) { throw 'Could not locate end of BindLayers implementation' }
    $bind = $text.Substring($bindStart, $bindEnd - $bindStart)
    $oldAspect = '.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,'
    $newAspect = '.aspectMask = s.sparse.formatProperties.aspectMask,'
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
    'info.resources.layers <= 1 || info.num_samples != 1 ||',
    '!sparse_layer_format) {',
    'const VkImageAspectFlags sparse_aspect = ImageAspectMask(info.format);',
    'std::ranges::find_if(requirements, [sparse_aspect](const auto& r) {',
    'VK_SPARSE_IMAGE_FORMAT_METADATA_BIT',
    '(r.formatProperties.aspectMask & sparse_aspect) != 0;',
    '.aspectMask = s.sparse.formatProperties.aspectMask,',
    'std::vector<u32> Image::BindLayers(std::span<const u32> layers)'
)) {
    if (-not $check.Contains($needle)) { throw "Runtime-v5 sparse-depth regression: missing $needle" }
}

# Keep the generic join guard intact in the texture-cache core. If a GPU-modified image reaches
# this path for some other reason, silently deleting it is still data loss and should stay visible.
$textureCacheCore = Read-Lf 'src/video_core/texture_cache/texture_cache.h'
if (-not $textureCacheCore.Contains('if (True(overlap.flags & ImageFlagBits::GpuModified)) {')) {
    throw 'Runtime-v5 regression: JoinImages GPU-modified data-loss guard disappeared'
}

Write-Host 'Generalized sparse-layer backing to depth arrays; first D16 render-target writes now have resident Vulkan memory.'
