$ErrorActionPreference = 'Stop'

# Citron 84cdb4c: when JoinImages replaces/absorbs an overlapping image, inherit whether that memory
# has already paid TextureCache::DmaImageId's first-download synchronization. Without this, a title
# that remaps the same render target to a new GPU address can recreate an image with
# dma_downloaded=false and force a full GPU sync again on its next DMA download. This adapter ports
# only the proven state inheritance; it does not import Citron's separate DMA remap-path rewrite.

function Write-PatchedText([string]$Path, [string]$Text) {
    $normalized = $Text.Replace("`r`n", "`n").TrimEnd("`r", "`n") + "`n"
    [IO.File]::WriteAllText((Resolve-Path $Path).Path, $normalized, [Text.UTF8Encoding]::new($false))
}

function Replace-Once([string]$Text, [string]$Old, [string]$New, [string]$Name) {
    $Text = $Text.Replace("`r`n", "`n")
    $Old = $Old.Replace("`r`n", "`n")
    $New = $New.Replace("`r`n", "`n")
    $first = $Text.IndexOf($Old, [StringComparison]::Ordinal)
    if ($first -lt 0) { throw "DMA download-state inheritance: missing anchor $Name" }
    if ($Text.IndexOf($Old, $first + $Old.Length, [StringComparison]::Ordinal) -ge 0) {
        throw "DMA download-state inheritance: ambiguous anchor $Name"
    }
    return $Text.Substring(0, $first) + $New + $Text.Substring($first + $Old.Length)
}

$path = 'src/video_core/texture_cache/texture_cache.h'
if (-not (Test-Path $path -PathType Leaf)) {
    throw "DMA download-state inheritance: missing $path"
}
$text = (Get-Content $path -Raw).Replace("`r`n", "`n")
$marker = 'new_info.dma_downloaded |= overlap.info.dma_downloaded;'
if (([regex]::Matches($text, [regex]::Escape($marker))).Count -lt 2) {
    $oldResolved = @'
            gpu_addr = solution->gpu_addr;
            cpu_addr = solution->cpu_addr;
            new_info.resources = solution->resources;
            join_overlap_ids.push_back(overlap_id);
'@
    $newResolved = @'
            gpu_addr = solution->gpu_addr;
            cpu_addr = solution->cpu_addr;
            new_info.resources = solution->resources;
            // The replacement image owns the same memory. Preserve whether that memory has already
            // paid the first DMA-download synchronization instead of forcing another full drain.
            new_info.dma_downloaded |= overlap.info.dma_downloaded;
            join_overlap_ids.push_back(overlap_id);
'@
    $text = Replace-Once $text $oldResolved.TrimEnd("`r", "`n") $newResolved.TrimEnd("`r", "`n") `
        'resolved overlap inheritance'

    $oldExact = @'
            if (overlap.gpu_addr == gpu_addr && overlap.guest_size_bytes == size_bytes) {
                join_ignore_textures.insert(overlap_id);
            }
'@
    $newExact = @'
            if (overlap.gpu_addr == gpu_addr && overlap.guest_size_bytes == size_bytes) {
                join_ignore_textures.insert(overlap_id);
                new_info.dma_downloaded |= overlap.info.dma_downloaded;
            }
'@
    $text = Replace-Once $text $oldExact.TrimEnd("`r", "`n") $newExact.TrimEnd("`r", "`n") `
        'exact sparse overlap inheritance'
    Write-PatchedText $path $text
    Write-Host '[APPLIED] inherited first DMA-download state across image overlap replacement'
} else {
    Write-Host '[PRESENT] inherited first DMA-download state across image overlap replacement'
}

$final = Get-Content $path -Raw
$count = ([regex]::Matches($final, [regex]::Escape($marker))).Count
if ($count -ne 2) {
    throw "DMA download-state inheritance validation failed: expected exactly 2 inheritance sites, found $count"
}
foreach ($needle in @(
    'if (!is_upload && !image.info.dma_downloaded)',
    'image.info.dma_downloaded = true;'
)) {
    if (-not $final.Contains($needle)) {
        throw "DMA download-state inheritance validation failed: first-download synchronization marker missing: $needle"
    }
}

& git diff --check
if ($LASTEXITCODE -ne 0) { throw 'DMA download-state inheritance introduced diff/whitespace errors' }
Write-Host 'DMA download-state inheritance validated: first-download synchronization remains, paid-state survives overlap replacement.'
