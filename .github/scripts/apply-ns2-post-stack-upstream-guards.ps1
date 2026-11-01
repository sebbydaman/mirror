$ErrorActionPreference = 'Stop'

# Small upstream correctness guard applied only after the full NS2 donor stack is assembled.
# Zortos' post-build31 source tightened the huge-image sparse fallback so we never force an
# unsupported image into unbacked sparse residency. This is a stability/correctness change, not an
# FPS optimization. Keep it late because earlier sparse-depth/frontier patches intentionally touch
# the same texture-cache area.

function Read-Lf([string]$Path) {
    if (-not (Test-Path $Path)) { throw "Missing required source file: $Path" }
    return (Get-Content $Path -Raw).Replace("`r`n", "`n")
}
function Write-Utf8([string]$Path, [string]$Text) {
    Set-Content -Path $Path -Value $Text -Encoding utf8 -NoNewline
}
function Replace-Once([string]$Text, [string]$Old, [string]$New, [string]$Label) {
    $Old = $Old.Replace("`r`n", "`n")
    $New = $New.Replace("`r`n", "`n")
    $at = $Text.IndexOf($Old)
    if ($at -lt 0) { throw "Could not locate $Label" }
    if ($Text.IndexOf($Old, $at + $Old.Length) -ge 0) { throw "Ambiguous anchor for $Label" }
    return $Text.Substring(0, $at) + $New + $Text.Substring($at + $Old.Length)
}

$devicePath = 'src/video_core/vulkan_common/vulkan_device.h'
$device = Read-Lf $devicePath
$newDeviceMarker = 'bool IsSparseResidencyImageSupported(VkImageType type) const {'
if (-not $device.Contains($newDeviceMarker)) {
    $oldDevice = @'
    /// 2D images whose memory can be bound in parts, on the graphics queue.
    bool IsSparseResidencyImage2DSupported() const {
        return IsSparseBindingSupported() && features.features.sparseResidencyImage2D;
    }
'@
    $newDevice = @'
    /// Returns whether sparse residency is available for the requested image type.
    bool IsSparseResidencyImageSupported(VkImageType type) const {
        if (!IsSparseBindingSupported()) {
            return false;
        }
        switch (type) {
        case VK_IMAGE_TYPE_2D:
            return features.features.sparseResidencyImage2D;
        case VK_IMAGE_TYPE_3D:
            return features.features.sparseResidencyImage3D;
        default:
            return false;
        }
    }
'@
    $device = Replace-Once $device $oldDevice $newDevice 'generic sparse-residency capability helper'
    Write-Utf8 $devicePath $device
}

$texturePath = 'src/video_core/renderer_vulkan/vk_texture_cache.cpp'
$texture = Read-Lf $texturePath
$newTextureMarker = 'device.IsSparseResidencyImageSupported(VK_IMAGE_TYPE_2D)'
if (-not $texture.Contains($newTextureMarker)) {
    $texture = Replace-Once $texture `
        'device.IsSparseResidencyImage2DSupported()' `
        $newTextureMarker `
        'sparse-layer residency capability query'
    Write-Utf8 $texturePath $texture
}

$allocatorPath = 'src/video_core/vulkan_common/vulkan_memory_allocator.cpp'
$allocator = Read-Lf $allocatorPath
$newHugeMarker = 'device.IsSparseResidencyImageSupported(ci.imageType);'
if (-not $allocator.Contains($newHugeMarker)) {
    $allocator = Replace-Once $allocator `
        '    const bool huge = texels > (u64{1} << 28);' `
        "    const bool huge = texels > (u64{1} << 28) && ci.samples == VK_SAMPLE_COUNT_1_BIT &&`n                      device.IsSparseResidencyImageSupported(ci.imageType);" `
        'huge-image sparse-residency capability guard'
    Write-Utf8 $allocatorPath $allocator
}

$deviceCheck = Read-Lf $devicePath
$textureCheck = Read-Lf $texturePath
$allocatorCheck = Read-Lf $allocatorPath
foreach ($needle in @(
    'bool IsSparseResidencyImageSupported(VkImageType type) const {',
    'case VK_IMAGE_TYPE_2D:',
    'return features.features.sparseResidencyImage2D;',
    'case VK_IMAGE_TYPE_3D:',
    'return features.features.sparseResidencyImage3D;'
)) {
    if (-not $deviceCheck.Contains($needle)) { throw "Post-stack sparse guard regression: missing $needle" }
}
if ($deviceCheck.Contains('IsSparseResidencyImage2DSupported()')) {
    throw 'Post-stack sparse guard regression: obsolete 2D-only device helper survived'
}
if (-not $textureCheck.Contains($newTextureMarker)) {
    throw 'Post-stack sparse guard regression: texture cache still uses the obsolete 2D-only helper'
}
foreach ($needle in @(
    'texels > (u64{1} << 28) && ci.samples == VK_SAMPLE_COUNT_1_BIT &&',
    'device.IsSparseResidencyImageSupported(ci.imageType);'
)) {
    if (-not $allocatorCheck.Contains($needle)) { throw "Post-stack sparse guard regression: missing $needle" }
}

Write-Host 'Applied post-stack sparse-residency capability guard for huge Vulkan images.'
git diff -- $devicePath $texturePath $allocatorPath
