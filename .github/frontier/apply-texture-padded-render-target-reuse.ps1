$ErrorActionPreference = 'Stop'

# Conservative port of Citron 8a598630: a block-linear image can have a smaller logical width/height
# while its aligned GOB backing already covers a larger render target. Reuse that compatible image
# instead of deleting/recreating it. FindSubresource(..., RelaxedOptions::Size) still proves format,
# type, samples, layers, address/base and block-linear aligned-size compatibility. For this NS2 tree
# we additionally exclude Remapped and Unbacked images so sparse/unbacked Switch 2 semantics stay on
# the existing FindOrInsertImage path.

function Write-PatchedText([string]$Path, [string]$Text) {
    $normalized = $Text.Replace("`r`n", "`n").TrimEnd("`r", "`n") + "`n"
    [IO.File]::WriteAllText((Resolve-Path $Path).Path, $normalized, [Text.UTF8Encoding]::new($false))
}

function Replace-Once([string]$Text, [string]$Old, [string]$New, [string]$Name) {
    $Text = $Text.Replace("`r`n", "`n")
    $Old = $Old.Replace("`r`n", "`n")
    $New = $New.Replace("`r`n", "`n")
    $first = $Text.IndexOf($Old, [StringComparison]::Ordinal)
    if ($first -lt 0) { throw "Padded render-target reuse: missing anchor $Name" }
    if ($Text.IndexOf($Old, $first + $Old.Length, [StringComparison]::Ordinal) -ge 0) {
        throw "Padded render-target reuse: ambiguous anchor $Name"
    }
    return $Text.Substring(0, $first) + $New + $Text.Substring($first + $Old.Length)
}

$basePath = 'src/video_core/texture_cache/texture_cache_base.h'
$cachePath = 'src/video_core/texture_cache/texture_cache.h'
foreach ($path in @($basePath, $cachePath)) {
    if (-not (Test-Path $path -PathType Leaf)) { throw "Padded render-target reuse: missing $path" }
}

$base = (Get-Content $basePath -Raw).Replace("`r`n", "`n")
if (-not $base.Contains('ImageId FindPaddedRenderTarget(const ImageInfo& info, GPUVAddr gpu_addr);')) {
    $oldDecl = @'
    /// Find or create a view for a render target with the given image parameters
    [[nodiscard]] ImageViewId FindRenderTargetView(const ImageInfo& info, GPUVAddr gpu_addr);

    /// Iterates over all the images in a region calling func
'@
    $newDecl = @'
    /// Find or create a view for a render target with the given image parameters
    [[nodiscard]] ImageViewId FindRenderTargetView(const ImageInfo& info, GPUVAddr gpu_addr);

    /// Find a block-linear image whose aligned backing already covers a padded render target.
    [[nodiscard]] ImageId FindPaddedRenderTarget(const ImageInfo& info, GPUVAddr gpu_addr);

    /// Iterates over all the images in a region calling func
'@
    $base = Replace-Once $base $oldDecl.TrimEnd("`r", "`n") $newDecl.TrimEnd("`r", "`n") `
        'padded render-target declaration'
    Write-PatchedText $basePath $base
}

$cache = (Get-Content $cachePath -Raw).Replace("`r`n", "`n")
if (-not $cache.Contains('ImageId TextureCache<P>::FindPaddedRenderTarget(')) {
    $anchor = 'template <class P>`nImageViewId TextureCache<P>::FindRenderTargetView(const ImageInfo& info, GPUVAddr gpu_addr) {'
    $anchor = $anchor.Replace('`n', "`n")
    $idx = $cache.IndexOf($anchor, [StringComparison]::Ordinal)
    if ($idx -lt 0) { throw 'Padded render-target reuse: FindRenderTargetView insertion anchor missing' }
    $function = @'
template <class P>
ImageId TextureCache<P>::FindPaddedRenderTarget(const ImageInfo& info, GPUVAddr gpu_addr) {
    if (info.type == ImageType::Linear) {
        return ImageId{};
    }
    const std::optional<DAddr> cpu_addr =
        ImageCpuAddress(gpu_addr, CalculateGuestSizeInBytes(info));
    if (!cpu_addr) {
        return ImageId{};
    }
    const bool broken_views = runtime.HasBrokenTextureViewFormats();
    const bool native_bgr = runtime.HasNativeBgr();
    ImageId result{};
    const auto lambda = [&](ImageId id, ImageBase& image) {
        if (True(image.flags & (ImageFlagBits::Remapped | ImageFlagBits::Unbacked)) ||
            image.info.type == ImageType::Linear || image.info.format != info.format) {
            return;
        }
        const auto base =
            FindSubresource(info, image, gpu_addr, RelaxedOptions::Size, broken_views, native_bgr);
        if (!base) {
            return;
        }
        const u32 width = std::max(1U, image.info.size.width >> base->level);
        const u32 height = std::max(1U, image.info.size.height >> base->level);
        // FindSubresource already proved the aligned block-linear backing matches. Reuse only when
        // the requested RT is logically larger in at least one dimension but still fits that same
        // padded backing; exact-size matches stay on the normal fast lookup path.
        if (width > info.size.width || height > info.size.height ||
            (width == info.size.width && height == info.size.height)) {
            return;
        }
        if (!result || image.modification_tick > slot_images[result].modification_tick) {
            result = id;
        }
    };
    ForEachImageInRegion(*cpu_addr, CalculateGuestSizeInBytes(info), lambda);
    return result;
}

'@
    $cache = $cache.Insert($idx, $function.Replace("`r`n", "`n"))
}

if (-not $cache.Contains('ImageId image_id = FindPaddedRenderTarget(info, gpu_addr);')) {
    $oldFind = @'
template <class P>
ImageViewId TextureCache<P>::FindRenderTargetView(const ImageInfo& info, GPUVAddr gpu_addr) {
    ImageId image_id{};
    bool delete_state = has_deleted_images;
    do {
        has_deleted_images = false;
        image_id = FindOrInsertImage(info, gpu_addr);
        delete_state |= has_deleted_images;
    } while (has_deleted_images);
    has_deleted_images = delete_state;
'@
    $newFind = @'
template <class P>
ImageViewId TextureCache<P>::FindRenderTargetView(const ImageInfo& info, GPUVAddr gpu_addr) {
    ImageId image_id = FindPaddedRenderTarget(info, gpu_addr);
    bool delete_state = has_deleted_images;
    if (!image_id) {
        do {
            has_deleted_images = false;
            image_id = FindOrInsertImage(info, gpu_addr);
            delete_state |= has_deleted_images;
        } while (has_deleted_images);
    }
    has_deleted_images = delete_state;
'@
    $cache = Replace-Once $cache $oldFind.TrimEnd("`r", "`n") $newFind.TrimEnd("`r", "`n") `
        'render-target padded reuse integration'
}
Write-PatchedText $cachePath $cache

$baseFinal = Get-Content $basePath -Raw
$cacheFinal = Get-Content $cachePath -Raw
foreach ($needle in @(
    'ImageId FindPaddedRenderTarget(const ImageInfo& info, GPUVAddr gpu_addr);'
)) {
    if (-not $baseFinal.Contains($needle)) { throw "Padded render-target reuse validation failed: $needle" }
}
foreach ($needle in @(
    'ImageId TextureCache<P>::FindPaddedRenderTarget(',
    'ImageCpuAddress(gpu_addr, CalculateGuestSizeInBytes(info))',
    'ImageFlagBits::Remapped | ImageFlagBits::Unbacked',
    'FindSubresource(info, image, gpu_addr, RelaxedOptions::Size',
    'ImageId image_id = FindPaddedRenderTarget(info, gpu_addr);',
    'if (!image_id) {'
)) {
    if (-not $cacheFinal.Contains($needle)) { throw "Padded render-target reuse validation failed: $needle" }
}

& git diff --check
if ($LASTEXITCODE -ne 0) { throw 'Padded render-target reuse introduced diff/whitespace errors' }
Write-Host 'Padded render-target reuse validated: aligned backing only; remapped/unbacked NS2 images excluded.'
