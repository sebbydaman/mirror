$ErrorActionPreference = 'Stop'

# Donor-backed texture-cache CPU optimization from Citron: cache graphics/compute image-view IDs in
# descriptor-indexed vectors rather than hashing a tagged descriptor index for every image view on
# every draw/dispatch. DescriptorTable::Read still rereads and compares guest memory exactly as
# before. Synchronize resizes the appropriate ID vector, and table invalidation forces the next read
# to refresh an entry before it is consumed. Validation builds poison both vectors when views die.

function Write-PatchedText([string]$Path, [string]$Text) {
    $normalized = $Text.Replace("`r`n", "`n").TrimEnd("`r", "`n") + "`n"
    [IO.File]::WriteAllText((Resolve-Path $Path).Path, $normalized, [Text.UTF8Encoding]::new($false))
}

function Replace-Once([string]$Text, [string]$Old, [string]$New, [string]$Name) {
    $Text = $Text.Replace("`r`n", "`n")
    $Old = $Old.Replace("`r`n", "`n")
    $New = $New.Replace("`r`n", "`n")
    $first = $Text.IndexOf($Old, [StringComparison]::Ordinal)
    if ($first -lt 0) { throw "Image-view ID vector cache: missing anchor $Name" }
    if ($Text.IndexOf($Old, $first + $Old.Length, [StringComparison]::Ordinal) -ge 0) {
        throw "Image-view ID vector cache: ambiguous anchor $Name"
    }
    return $Text.Substring(0, $first) + $New + $Text.Substring($first + $Old.Length)
}

$basePath = 'src/video_core/texture_cache/texture_cache_base.h'
$cachePath = 'src/video_core/texture_cache/texture_cache.h'
foreach ($path in @($basePath, $cachePath)) {
    if (-not (Test-Path $path -PathType Leaf)) { throw "Image-view ID vector cache: missing $path" }
}

$base = (Get-Content $basePath -Raw).Replace("`r`n", "`n")
if (-not $base.Contains('std::vector<ImageViewId> graphics_image_view_ids;')) {
    $base = Replace-Once $base `
        '    ::Common::unordered_map<u32, ImageViewId> image_view_ids;' `
        "    std::vector<ImageViewId> graphics_image_view_ids;`n    std::vector<ImageViewId> compute_image_view_ids;" `
        'channel image-view ID cache storage'
    Write-PatchedText $basePath $base
    Write-Host '[APPLIED] indexed graphics/compute image-view ID cache storage'
} else {
    Write-Host '[PRESENT] indexed graphics/compute image-view ID cache storage'
}

$cache = (Get-Content $cachePath -Raw).Replace("`r`n", "`n")
if ($cache.Contains('channel_state->image_view_ids.find(map_index)')) {
    $oldVisit = @'
template <class P>
ImageViewId TextureCache<P>::VisitImageView(u32 index, bool compute) {
    auto& table = compute ? channel_state->compute_image_table : channel_state->graphics_image_table;
    if (index > table.current_limit) {
        LOG_DEBUG(HW_GPU, "Invalid image view index={}", index);
        return NULL_IMAGE_VIEW_ID;
    }
    auto const map_index = index | (compute ? Common::SlotId::TAGGED_VALUE : 0);
    // Is new (on the tegra engine side)?
    auto const [descriptor, is_new] = table.Read(*gpu_memory, index);
    if (is_new) {
        if (IsValidEntry(*gpu_memory, descriptor)) {
            // Is new (registered view) on the texture cache side?
            const auto [pair, is_new_tc] = channel_state->image_views.try_emplace(descriptor);
            if (is_new_tc)
                pair->second = CreateImageView(descriptor);
            PrepareImageView(pair->second, false, false);
            channel_state->image_view_ids.insert_or_assign(map_index, pair->second);
            return pair->second;
        }
        channel_state->image_view_ids.insert_or_assign(map_index, NULL_IMAGE_VIEW_ID);
        return NULL_IMAGE_VIEW_ID;
    }
    auto const it = channel_state->image_view_ids.find(map_index);
    if (it->second != NULL_IMAGE_VIEW_ID)
        PrepareImageView(it->second, false, false);
    return it->second;
}
'@
    $newVisit = @'
template <class P>
ImageViewId TextureCache<P>::VisitImageView(u32 index, bool compute) {
    auto& table = compute ? channel_state->compute_image_table : channel_state->graphics_image_table;
    auto& ids = compute ? channel_state->compute_image_view_ids : channel_state->graphics_image_view_ids;
    if (index > table.current_limit) {
        LOG_DEBUG(HW_GPU, "Invalid image view index={}", index);
        return NULL_IMAGE_VIEW_ID;
    }
    // Is new (on the tegra engine side)? Descriptor memory is still read every time.
    auto const [descriptor, is_new] = table.Read(*gpu_memory, index);
    ImageViewId& id = ids[index];
    if (is_new) {
        if (IsValidEntry(*gpu_memory, descriptor)) {
            // Is new (registered view) on the texture cache side?
            const auto [pair, is_new_tc] = channel_state->image_views.try_emplace(descriptor);
            if (is_new_tc)
                pair->second = CreateImageView(descriptor);
            id = pair->second;
        } else {
            id = NULL_IMAGE_VIEW_ID;
        }
    }
    if (id != NULL_IMAGE_VIEW_ID)
        PrepareImageView(id, false, false);
    return id;
}
'@
    $cache = Replace-Once $cache $oldVisit.TrimEnd("`r", "`n") $newVisit.TrimEnd("`r", "`n") `
        'VisitImageView direct indexed cache'
}

if (-not $cache.Contains('compute_image_view_ids.resize(tic_limit + 1, CORRUPT_ID);')) {
    $oldCompute = @'
        if (channel_state->compute_image_table.Synchronize(kepler_compute->regs.tic.Address(), tic_limit))
            bindings_changed = true;
'@
    $newCompute = @'
        if (channel_state->compute_image_table.Synchronize(kepler_compute->regs.tic.Address(), tic_limit)) {
            channel_state->compute_image_view_ids.resize(tic_limit + 1, CORRUPT_ID);
            bindings_changed = true;
        }
'@
    $cache = Replace-Once $cache $oldCompute.TrimEnd("`r", "`n") $newCompute.TrimEnd("`r", "`n") `
        'compute image table synchronization'
}

if (-not $cache.Contains('graphics_image_view_ids.resize(tic_limit + 1, CORRUPT_ID);')) {
    $oldGraphics = @'
        if (channel_state->graphics_image_table.Synchronize(maxwell3d->regs.tex_header.Address(), tic_limit))
            bindings_changed = true;
'@
    $newGraphics = @'
        if (channel_state->graphics_image_table.Synchronize(maxwell3d->regs.tex_header.Address(), tic_limit)) {
            channel_state->graphics_image_view_ids.resize(tic_limit + 1, CORRUPT_ID);
            bindings_changed = true;
        }
'@
    $cache = Replace-Once $cache $oldGraphics.TrimEnd("`r", "`n") $newGraphics.TrimEnd("`r", "`n") `
        'graphics image table synchronization'
}

$oldValidation = @'
        if constexpr (ENABLE_VALIDATION)
            for (auto& e : channel_info.image_view_ids)
                e.second = CORRUPT_ID;
        channel_info.graphics_image_table.Invalidate();
        channel_info.compute_image_table.Invalidate();
'@
$newValidation = @'
        if constexpr (ENABLE_VALIDATION) {
            std::ranges::fill(channel_info.graphics_image_view_ids, CORRUPT_ID);
            std::ranges::fill(channel_info.compute_image_view_ids, CORRUPT_ID);
        }
        channel_info.graphics_image_table.Invalidate();
        channel_info.compute_image_table.Invalidate();
'@
# Earlier frontier helpers normalize integrated source to LF; normalize these multi-line Windows
# here-strings as well so both validation-only invalidation sites are rewritten reliably.
$oldValidation = $oldValidation.Replace("`r`n", "`n").TrimEnd("`r", "`n")
$newValidation = $newValidation.Replace("`r`n", "`n").TrimEnd("`r", "`n")
$validationCount = ([regex]::Matches($cache, [regex]::Escape($oldValidation))).Count
if ($validationCount -gt 0) {
    $cache = $cache.Replace($oldValidation, $newValidation)
}

Write-PatchedText $cachePath $cache

$baseFinal = Get-Content $basePath -Raw
$cacheFinal = Get-Content $cachePath -Raw
foreach ($needle in @(
    'std::vector<ImageViewId> graphics_image_view_ids;',
    'std::vector<ImageViewId> compute_image_view_ids;'
)) {
    if (-not $baseFinal.Contains($needle)) {
        throw "Image-view ID vector cache validation failed: base missing $needle"
    }
}
foreach ($needle in @(
    'auto& ids = compute ? channel_state->compute_image_view_ids : channel_state->graphics_image_view_ids;',
    'ImageViewId& id = ids[index];',
    'compute_image_view_ids.resize(tic_limit + 1, CORRUPT_ID);',
    'graphics_image_view_ids.resize(tic_limit + 1, CORRUPT_ID);',
    'std::ranges::fill(channel_info.graphics_image_view_ids, CORRUPT_ID);',
    'std::ranges::fill(channel_info.compute_image_view_ids, CORRUPT_ID);'
)) {
    if (-not $cacheFinal.Contains($needle)) {
        throw "Image-view ID vector cache validation failed: cache missing $needle"
    }
}
foreach ($forbidden in @(
    'channel_state->image_view_ids.find(map_index)',
    'channel_state->image_view_ids.insert_or_assign(map_index',
    '::Common::unordered_map<u32, ImageViewId> image_view_ids;',
    'for (auto& e : channel_info.image_view_ids)'
)) {
    if ($baseFinal.Contains($forbidden) -or $cacheFinal.Contains($forbidden)) {
        throw "Image-view ID vector cache validation failed: old hash path remains: $forbidden"
    }
}

& git diff --check
if ($LASTEXITCODE -ne 0) { throw 'Image-view ID vector cache introduced diff/whitespace errors' }
Write-Host 'Image-view ID vector cache validated: descriptor reads/preparation unchanged; tagged hash lookup removed.'
