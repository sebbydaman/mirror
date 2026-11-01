$ErrorActionPreference = 'Stop'

# Djihads80/Eglantine f9fc1e10: PageTableOp/BigPageTableOp used to notify the rasterizer once for
# every changed GPU page. Each notification scans the texture and buffer caches; Mario Kart World's
# 1.45 GiB sparse-region mapping produced roughly 370,000 scans. Coalesce contiguous changed pages
# into one ModifyGPUMemory notification per run. Apply this only after the existing PR157/Build31
# mapping-generation frontier so their checked patch contexts stay untouched.

function Replace-ExactlyOnce {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Old,
        [Parameter(Mandatory = $true)][string]$New,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $first = $Text.IndexOf($Old, [StringComparison]::Ordinal)
    if ($first -lt 0) { throw "Memory-manager range batching: missing anchor $Name" }
    $second = $Text.IndexOf($Old, $first + $Old.Length, [StringComparison]::Ordinal)
    if ($second -ge 0) { throw "Memory-manager range batching: ambiguous anchor $Name" }
    return $Text.Substring(0, $first) + $New + $Text.Substring($first + $Old.Length)
}

function Normalize-Block([string]$Text) {
    return $Text.Replace("`r`n", "`n").TrimEnd("`r", "`n")
}

$path = 'src/video_core/memory_manager.cpp'
if (-not (Test-Path $path -PathType Leaf)) {
    throw "Memory-manager range batching: missing $path"
}

$text = (Get-Content $path -Raw).Replace("`r`n", "`n")
$directPage = 'rasterizer->ModifyGPUMemory(unique_identifier, current_gpu_addr, page_size);'
$directBig = 'rasterizer->ModifyGPUMemory(unique_identifier, current_gpu_addr, big_page_size);'
$hasPageBatch = $text.Contains('modified_size += page_size;')
$hasBigBatch = $text.Contains('modified_size += big_page_size;')
$hasBatchLambda = ([regex]::Matches($text, [regex]::Escape('const auto flush_modified = [&]'))).Count -ge 2

if ($hasPageBatch -or $hasBigBatch -or $hasBatchLambda) {
    if (-not ($hasPageBatch -and $hasBigBatch -and $hasBatchLambda)) {
        throw 'Memory-manager range batching: partial existing implementation detected'
    }
    if ($text.Contains($directPage) -or $text.Contains($directBig)) {
        throw 'Memory-manager range batching: batched and per-page notification paths coexist'
    }
    Write-Host '[PRESENT] GPU page-table cache notifications are already coalesced by changed range'
    exit 0
}

if (-not $text.Contains($directPage) -or -not $text.Contains($directBig)) {
    throw 'Memory-manager range batching: page-table notification semantics changed; refusing a blind rewrite'
}

$pagePrefixOld = Normalize-Block @'
    if (entry_type == EntryType::Mapped) {
        page_table.ReserveRange(gpu_addr, size);
    }
    for (u64 offset{}; offset < size; offset += page_size) {
'@
$pagePrefixNew = Normalize-Block @'
    if (entry_type == EntryType::Mapped) {
        page_table.ReserveRange(gpu_addr, size);
    }
    // The caches hear about each run of pages whose entry changed in one call, not page by page
    // (a 1.45 GB Switch 2 region made ~370,000 texture cache scans).
    GPUVAddr modified_start{};
    u64 modified_size{};
    const auto flush_modified = [&] {
        if (modified_size != 0) {
            rasterizer->ModifyGPUMemory(unique_identifier, modified_start, modified_size);
            modified_size = 0;
        }
    };
    for (u64 offset{}; offset < size; offset += page_size) {
'@
$text = Replace-ExactlyOnce $text $pagePrefixOld $pagePrefixNew 'PageTableOp accumulator insertion'

$pageNotifyOld = Normalize-Block @'
        if (current_entry_type != entry_type) {
            rasterizer->ModifyGPUMemory(unique_identifier, current_gpu_addr, page_size);
        }
'@
$pageNotifyNew = Normalize-Block @'
        if (current_entry_type != entry_type) {
            if (modified_size == 0) {
                modified_start = current_gpu_addr;
            }
            modified_size += page_size;
        } else {
            flush_modified();
        }
'@
$text = Replace-ExactlyOnce $text $pageNotifyOld $pageNotifyNew 'PageTableOp changed-run accumulation'

$pageTailOld = Normalize-Block @'
        remaining_size -= page_size;
    }
    kind_map.Map(gpu_addr, gpu_addr + size, kind);
'@
$pageTailNew = Normalize-Block @'
        remaining_size -= page_size;
    }
    flush_modified();
    kind_map.Map(gpu_addr, gpu_addr + size, kind);
'@
$text = Replace-ExactlyOnce $text $pageTailOld $pageTailNew 'PageTableOp final range flush'

$bigPrefixOld = Normalize-Block @'
    [[maybe_unused]] u64 remaining_size{size};
    for (u64 offset{}; offset < size; offset += big_page_size) {
'@
$bigPrefixNew = Normalize-Block @'
    [[maybe_unused]] u64 remaining_size{size};
    GPUVAddr modified_start{};
    u64 modified_size{};
    const auto flush_modified = [&] {
        if (modified_size != 0) {
            rasterizer->ModifyGPUMemory(unique_identifier, modified_start, modified_size);
            modified_size = 0;
        }
    };
    for (u64 offset{}; offset < size; offset += big_page_size) {
'@
$text = Replace-ExactlyOnce $text $bigPrefixOld $bigPrefixNew 'BigPageTableOp accumulator insertion'

$bigNotifyOld = Normalize-Block @'
        if (current_entry_type != entry_type) {
            rasterizer->ModifyGPUMemory(unique_identifier, current_gpu_addr, big_page_size);
        }
'@
$bigNotifyNew = Normalize-Block @'
        if (current_entry_type != entry_type) {
            if (modified_size == 0) {
                modified_start = current_gpu_addr;
            }
            modified_size += big_page_size;
        } else {
            flush_modified();
        }
'@
$text = Replace-ExactlyOnce $text $bigNotifyOld $bigNotifyNew 'BigPageTableOp changed-run accumulation'

$bigTailOld = Normalize-Block @'
        remaining_size -= big_page_size;
    }
    {
        std::unique_lock<std::mutex> lock(guard);
'@
$bigTailNew = Normalize-Block @'
        remaining_size -= big_page_size;
    }
    flush_modified();
    {
        std::unique_lock<std::mutex> lock(guard);
'@
$text = Replace-ExactlyOnce $text $bigTailOld $bigTailNew 'BigPageTableOp final range flush'

$normalized = $text.TrimEnd("`r", "`n") + "`n"
[IO.File]::WriteAllText((Resolve-Path $path).Path, $normalized, [Text.UTF8Encoding]::new($false))

$final = Get-Content $path -Raw
foreach ($required in @(
    'modified_size += page_size;',
    'modified_size += big_page_size;',
    'rasterizer->ModifyGPUMemory(unique_identifier, modified_start, modified_size);',
    'a 1.45 GB Switch 2 region made ~370,000 texture cache scans'
)) {
    if (-not $final.Contains($required)) {
        throw "Memory-manager range batching validation failed: missing $required"
    }
}
if ($final.Contains($directPage) -or $final.Contains($directBig)) {
    throw 'Memory-manager range batching validation failed: per-page cache notifications survived'
}

git diff --check
if ($LASTEXITCODE -ne 0) {
    throw 'Memory-manager range batching introduced diff/whitespace errors'
}

Write-Host '[APPLIED] Coalesced GPU page-table cache notifications by changed range (MKW sparse-map CPU path)'
