$ErrorActionPreference = 'Stop'

# CPU-side follow-up to zortos293/Eglantine build 31.
#
# MarkPartialWrite tracks CPU writes into very large streamed textures. The older implementation
# performs a lower_bound + vector insertion + cache-count update once for every 4-KiB page. MKW can
# touch contiguous runs of these pages, making bookkeeping scale with page count on the CPU thread.
# Build 31 coalesces the run: locate the already-dirty subrange once, update uncached gaps in ranges,
# replace the vector span once, then fill the contiguous page indices with std::iota.
#
# This is deliberately isolated from the donor's broader readback/coherency architecture. It changes
# only bookkeeping for pages MarkPartialWrite has already decided are safe for partial tracking.

function Write-PatchedText([string]$Path, [string]$Text) {
    $normalized = $Text.Replace("`r`n", "`n").TrimEnd("`r", "`n") + "`n"
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText((Resolve-Path $Path).Path, $normalized, $utf8NoBom)
}

$path = 'src/video_core/texture_cache/texture_cache.h'
if (-not (Test-Path $path -PathType Leaf)) {
    throw "Build31 partial-write frontier: missing $path"
}
$text = (Get-Content $path -Raw).Replace("`r`n", "`n")

$newMarker = 'const auto begin_it = std::lower_bound(pages.begin(), pages.end(), first);'
if ($text.Contains($newMarker)) {
    if (-not $text.Contains('std::iota(inserted, inserted + (last - first + 1), first);')) {
        throw 'Build31 partial-write frontier: partial coalesced implementation detected'
    }
    Write-Host '[PRESENT] coalesced texture partial-write page tracking'
    exit 0
}

$old = @'
    auto& pages = image.partial_dirty_pages;
    for (u32 page = first; page <= last; ++page) {
        const auto it = std::lower_bound(pages.begin(), pages.end(), page);
        if (it != pages.end() && *it == page) {
            continue;
        }
        pages.insert(it, page);
        device_memory.UpdatePagesCachedCount((base_page + page) << Core::DEVICE_PAGEBITS,
                                             Core::DEVICE_PAGESIZE, -1);
    }
'@
$old = $old.Replace("`r`n", "`n").TrimEnd("`r", "`n")
if (-not $text.Contains($old)) {
    throw 'Build31 partial-write frontier: MarkPartialWrite per-page anchor changed or feature absent'
}

$new = @'
    auto& pages = image.partial_dirty_pages;
    const auto begin_it = std::lower_bound(pages.begin(), pages.end(), first);
    const auto end_it = std::upper_bound(begin_it, pages.end(), last);
    const auto untrack = [&](u32 run_begin, u32 run_end) {
        if (run_begin < run_end) {
            device_memory.UpdatePagesCachedCount((base_page + run_begin) << Core::DEVICE_PAGEBITS,
                                                 size_t{run_end - run_begin} << Core::DEVICE_PAGEBITS,
                                                 -1);
        }
    };
    u32 run_begin = first;
    for (auto it = begin_it; it != end_it; ++it) {
        untrack(run_begin, *it);
        run_begin = *it + 1;
    }
    untrack(run_begin, last + 1);
    const auto insert_index = pages.erase(begin_it, end_it) - pages.begin();
    const auto inserted = pages.insert(pages.begin() + insert_index, last - first + 1, 0);
    std::iota(inserted, inserted + (last - first + 1), first);
'@
$new = $new.Replace("`r`n", "`n").TrimEnd("`r", "`n")
$text = $text.Replace($old, $new)

if (-not $text.Contains('#include <numeric>')) {
    if (-not $text.Contains('#include <algorithm>')) {
        throw 'Build31 partial-write frontier: no stable include anchor for <numeric>'
    }
    $text = $text.Replace('#include <algorithm>', "#include <algorithm>`n#include <numeric>")
}

Write-PatchedText $path $text

$verify = Get-Content $path -Raw
foreach ($needle in @(
    'const auto begin_it = std::lower_bound(pages.begin(), pages.end(), first);',
    'const auto end_it = std::upper_bound(begin_it, pages.end(), last);',
    'size_t{run_end - run_begin} << Core::DEVICE_PAGEBITS',
    'const auto insert_index = pages.erase(begin_it, end_it) - pages.begin();',
    'std::iota(inserted, inserted + (last - first + 1), first);'
)) {
    if (-not $verify.Contains($needle)) {
        throw "Build31 partial-write frontier: missing post-patch marker: $needle"
    }
}
Write-Host '[APPLIED] coalesced texture partial-write page tracking'
