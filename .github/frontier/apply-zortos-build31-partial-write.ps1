$ErrorActionPreference = 'Stop'

# Validation-only guard for the texture partial-write frontier.
#
# zortos293/Eglantine commit 11a110898fcfe16a5b9aee98c4346265825c3178 ("Small
# optimizations based on latest profiling data") still retains the per-page MarkPartialWrite loop.
# The fully integrated NS2 tree carries a different texture/readback architecture and currently has
# no MarkPartialWrite/partial_dirty_pages path at all. Do not force an unverified rewrite into that
# architecture. If the old path exists, preserve it; if it is absent, this frontier is inapplicable.
#
# This guard is the final Build31 hook in test-ns2-donor-safe-perf.ps1, so successful paths hand off
# to the post-Build31 CPU frontier only after the mapping-generation and Build31 patches are stable.

function Invoke-PostBuild31CpuFrontier {
    $postFrontier = Join-Path $PSScriptRoot 'apply-post-build31-cpu-frontier.ps1'
    if (-not (Test-Path $postFrontier -PathType Leaf)) {
        throw "Build31 partial-write frontier: missing post-Build31 CPU frontier $postFrontier"
    }
    & $postFrontier
}

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
    Invoke-PostBuild31CpuFrontier
    exit 0
}

$functionMarker = 'void TextureCache<P>::MarkPartialWrite'
$pagesMarker = 'image.partial_dirty_pages'
$hasFunction = $text.Contains($functionMarker)
$hasPages = $text.Contains($pagesMarker)

if ($hasFunction -and $hasPages) {
    Write-Host '[SKIP] coalesced texture partial-write tracking is not donor-backed by zortos 11a110898; preserving integrated MarkPartialWrite semantics'
    Invoke-PostBuild31CpuFrontier
    exit 0
}

if ($hasFunction -xor $hasPages) {
    throw 'Build31 partial-write frontier: inconsistent partial-write feature markers detected'
}

Write-Host '[INAPPLICABLE] integrated texture cache has no MarkPartialWrite/partial_dirty_pages path; skipping speculative optimization'
Invoke-PostBuild31CpuFrontier
exit 0
