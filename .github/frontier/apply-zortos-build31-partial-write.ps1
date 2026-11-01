$ErrorActionPreference = 'Stop'

# Validation-only guard for the texture partial-write frontier.
#
# zortos293/Eglantine commit 11a110898fcfe16a5b9aee98c4346265825c3178 ("Small
# optimizations based on latest profiling data") still retains the per-page MarkPartialWrite loop.
# The fully integrated NS2 tree also carries newer read-trap/selective-copyback/coherency work, so
# forcing an unverified coalesced rewrite here would mix architectures and can change cache-count
# semantics. Keep the donor-backed Build31 CPU optimizations, but do not make this speculative
# texture rewrite a build requirement.

$path = 'src/video_core/texture_cache/texture_cache.h'
if (-not (Test-Path $path -PathType Leaf)) {
    throw "Build31 partial-write frontier: missing $path"
}

$text = (Get-Content $path -Raw).Replace("`r`n", "`n")
$newMarker = 'const auto begin_it = std::lower_bound(pages.begin(), pages.end(), first);'
$newIota = 'std::iota(inserted, inserted + (last - first + 1), first);'

if ($text.Contains($newMarker)) {
    if (-not $text.Contains($newIota)) {
        throw 'Build31 partial-write frontier: partial coalesced implementation detected'
    }
    Write-Host '[PRESENT] coalesced texture partial-write page tracking'
    exit 0
}

$functionMarker = 'void TextureCache<P>::MarkPartialWrite'
$pagesMarker = 'image.partial_dirty_pages'
if ($text.Contains($functionMarker) -and $text.Contains($pagesMarker)) {
    Write-Host '[SKIP] coalesced texture partial-write tracking is not donor-backed by zortos 11a110898; preserving integrated MarkPartialWrite semantics'
    exit 0
}

throw 'Build31 partial-write frontier: MarkPartialWrite feature is absent; refusing to guess at texture-cache semantics'
