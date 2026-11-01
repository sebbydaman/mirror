$ErrorActionPreference = 'Stop'

# Citron 92960d1f: CommitAsyncFlushesHigh already shares one staging buffer and one pre/post barrier,
# but still records one runtime.CopyBuffer call for every downloaded range. Group consecutive ranges
# belonging to the same BufferId into one CopyBuffer span. Keep all existing per-range NX2 profiling,
# async-download tracking, MarkUsage and normalized-copy bookkeeping unchanged.

function Write-PatchedText([string]$Path, [string]$Text) {
    $normalized = $Text.Replace("`r`n", "`n").TrimEnd("`r", "`n") + "`n"
    [IO.File]::WriteAllText((Resolve-Path $Path).Path, $normalized, [Text.UTF8Encoding]::new($false))
}

function Replace-Once([string]$Text, [string]$Old, [string]$New, [string]$Name) {
    $Text = $Text.Replace("`r`n", "`n")
    $Old = $Old.Replace("`r`n", "`n")
    $New = $New.Replace("`r`n", "`n")
    $first = $Text.IndexOf($Old, [StringComparison]::Ordinal)
    if ($first -lt 0) { throw "Buffer download copy batching: missing anchor $Name" }
    if ($Text.IndexOf($Old, $first + $Old.Length, [StringComparison]::Ordinal) -ge 0) {
        throw "Buffer download copy batching: ambiguous anchor $Name"
    }
    return $Text.Substring(0, $first) + $New + $Text.Substring($first + $Old.Length)
}

$path = 'src/video_core/buffer_cache/buffer_cache.h'
if (-not (Test-Path $path -PathType Leaf)) {
    throw "Buffer download copy batching: missing $path"
}
$text = (Get-Content $path -Raw).Replace("`r`n", "`n")
if (-not $text.Contains('boost::container::small_vector<BufferCopy, 16> download_copy_batch;')) {
    $oldStart = @'
    auto download_staging = runtime.DownloadStagingBuffer(total_size_bytes, true);
    boost::container::small_vector<BufferCopy, 4> normalized_copies;
    runtime.PreCopyBarrier();
    for (auto& [copy, buffer_id] : downloads) {
'@
    $newStart = @'
    auto download_staging = runtime.DownloadStagingBuffer(total_size_bytes, true);
    boost::container::small_vector<BufferCopy, 4> normalized_copies;
    runtime.PreCopyBarrier();
    boost::container::small_vector<BufferCopy, 16> download_copy_batch;
    BufferId download_copy_batch_id{};
    const auto flush_download_copy_batch = [&] {
        if (!download_copy_batch.empty()) {
            runtime.CopyBuffer(download_staging.buffer, slot_buffers[download_copy_batch_id],
                               download_copy_batch, false);
            download_copy_batch.clear();
        }
    };
    for (auto& [copy, buffer_id] : downloads) {
'@
    $text = Replace-Once $text $oldStart.TrimEnd("`r", "`n") $newStart.TrimEnd("`r", "`n") `
        'async download batch setup'

    $oldCopy = @'
        async_downloads.Add(orig_device_addr, copy.size);
        buffer.MarkUsage(copy.src_offset, copy.size);
        runtime.CopyBuffer(download_staging.buffer, buffer, copies, false);
        normalized_copies.push_back(second_copy);
    }
    runtime.PostCopyBarrier();
'@
    $newCopy = @'
        async_downloads.Add(orig_device_addr, copy.size);
        buffer.MarkUsage(copy.src_offset, copy.size);
        if (buffer_id != download_copy_batch_id) {
            flush_download_copy_batch();
            download_copy_batch_id = buffer_id;
        }
        download_copy_batch.push_back(copy);
        normalized_copies.push_back(second_copy);
    }
    flush_download_copy_batch();
    runtime.PostCopyBarrier();
'@
    $text = Replace-Once $text $oldCopy.TrimEnd("`r", "`n") $newCopy.TrimEnd("`r", "`n") `
        'per-range CopyBuffer submission'

    $text = $text.Replace('        const std::array copies{copy};' + "`n", '')
    Write-PatchedText $path $text
    Write-Host '[APPLIED] batched async download CopyBuffer calls per BufferId'
} else {
    Write-Host '[PRESENT] batched async download CopyBuffer calls per BufferId'
}

$final = Get-Content $path -Raw
foreach ($needle in @(
    'boost::container::small_vector<BufferCopy, 16> download_copy_batch;',
    'const auto flush_download_copy_batch = [&]',
    'slot_buffers[download_copy_batch_id]',
    'if (buffer_id != download_copy_batch_id)',
    'download_copy_batch.push_back(copy);',
    'flush_download_copy_batch();',
    'Nx2Profile::TrackDmaPages()',
    'async_downloads.Add(orig_device_addr, copy.size);',
    'buffer.MarkUsage(copy.src_offset, copy.size);',
    'normalized_copies.push_back(second_copy);'
)) {
    if (-not $final.Contains($needle)) {
        throw "Buffer download copy batching validation failed: missing $needle"
    }
}
$functionStart = $final.IndexOf('void BufferCache<P>::CommitAsyncFlushesHigh()')
$functionEnd = $final.IndexOf("`ntemplate <class P>`nvoid BufferCache<P>::CommitAsyncFlushes()", $functionStart)
if ($functionStart -lt 0 -or $functionEnd -lt 0) {
    throw 'Buffer download copy batching validation failed: could not isolate CommitAsyncFlushesHigh'
}
$function = $final.Substring($functionStart, $functionEnd - $functionStart)
if ($function.Contains('const std::array copies{copy};')) {
    throw 'Buffer download copy batching validation failed: old per-range copies array remains'
}

& git diff --check
if ($LASTEXITCODE -ne 0) { throw 'Buffer download copy batching introduced diff/whitespace errors' }
Write-Host 'Buffer download copy batching validated: one CopyBuffer call per consecutive BufferId group; per-range bookkeeping preserved.'
