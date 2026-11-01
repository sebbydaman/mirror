$ErrorActionPreference = 'Stop'

$path = 'src/core/hle/kernel/k_memory_manager.cpp'
$text = (Get-Content $path -Raw) -replace "`r`n", "`n"

# 1) Cross-session reset: insert by function boundary, not by an exact formatting block.
$resetMarker = 'std::exchange(m_system.DeviceMemory().used_by_kernel, true)'
if (-not $text.Contains($resetMarker)) {
    $start = $text.IndexOf('void KMemoryManager::Initialize(', [StringComparison]::Ordinal)
    if ($start -lt 0) { throw 'Could not locate KMemoryManager::Initialize for PR142 reset adapter' }
    $next = $text.IndexOf('Result KMemoryManager::InitializeOptimizedMemory(', $start, [StringComparison]::Ordinal)
    if ($next -lt 0) { throw 'Could not locate function after KMemoryManager::Initialize for PR142 reset adapter' }

    # The final closing brace before InitializeOptimizedMemory is Initialize()'s own function boundary.
    $close = $text.LastIndexOf('}', $next - 1)
    if ($close -le $start) { throw 'Could not locate KMemoryManager::Initialize closing brace' }

    $insert = @'
    // The host backing outlives emulation sessions: after an earlier one, no page is known zero.
    if (std::exchange(m_system.DeviceMemory().used_by_kernel, true)) {
        for (size_t i = 0; i < m_num_managers; ++i) {
            m_managers[i].MarkAllFreed();
        }
    }
'@

    $prefix = $text.Substring(0, $close).TrimEnd("`n")
    $suffix = $text.Substring($close)
    $text = $prefix + "`n`n" + $insert.TrimEnd("`r", "`n") + "`n" + $suffix
    Write-Host '[ADAPTED] PR142 KMemoryManager cross-session reset at Initialize() function boundary'
} else {
    Write-Host '[PRESENT] PR142 KMemoryManager cross-session reset'
}

# 2) AllocateForProcess: the integrated Eglantine tree still clears backing memory here, but the
# surrounding formatting/control-flow has drifted from the donor. Replace only the one backing-clear
# call inside this function. The main PR142 adapter later supplies FillAllocatedPages itself.
$allocMarker = 'this->FillAllocatedPages(block.GetAddress(), block.GetNumPages(), fill_pattern);'
if (-not $text.Contains($allocMarker)) {
    $allocStart = $text.IndexOf('Result KMemoryManager::AllocateForProcess(', [StringComparison]::Ordinal)
    if ($allocStart -lt 0) { throw 'Could not locate KMemoryManager::AllocateForProcess for PR142 adapter' }

    $allocReturn = $text.IndexOf('    R_SUCCEED();', $allocStart, [StringComparison]::Ordinal)
    if ($allocReturn -lt 0) { throw 'Could not locate AllocateForProcess return boundary for PR142 adapter' }

    $clearNeedle = 'm_system.DeviceMemory().buffer.ClearBackingRegion('
    $clearStart = $text.IndexOf($clearNeedle, $allocStart, [StringComparison]::Ordinal)
    if ($clearStart -lt 0 -or $clearStart -gt $allocReturn) {
        throw 'Could not locate AllocateForProcess backing clear for PR142 adapter'
    }

    # Require exactly one such call in AllocateForProcess so we never rewrite an unrelated clear.
    $secondClear = $text.IndexOf($clearNeedle, $clearStart + $clearNeedle.Length, [StringComparison]::Ordinal)
    if ($secondClear -ge 0 -and $secondClear -lt $allocReturn) {
        throw 'AllocateForProcess contains multiple backing clears; refusing ambiguous PR142 rewrite'
    }

    $callEnd = $text.IndexOf(');', $clearStart, [StringComparison]::Ordinal)
    if ($callEnd -lt 0 -or $callEnd -gt $allocReturn) {
        throw 'Could not locate end of AllocateForProcess backing clear call'
    }
    $callEnd += 2

    $lineStart = $text.LastIndexOf("`n", $clearStart)
    if ($lineStart -lt 0) { $lineStart = 0 } else { ++$lineStart }
    $indent = $text.Substring($lineStart, $clearStart - $lineStart)
    if ($indent.Trim().Length -ne 0) { throw 'Unexpected non-whitespace before AllocateForProcess backing clear' }

    $replacement = $indent + $allocMarker
    $text = $text.Substring(0, $lineStart) + $replacement + $text.Substring($callEnd)
    Write-Host '[ADAPTED] PR142 AllocateForProcess selective-fill routing by semantic call boundary'
} else {
    Write-Host '[PRESENT] PR142 AllocateForProcess selective-fill routing'
}

# 3) Impl::Initialize page metadata: locate the resize statement inside the function rather than
# matching the donor's old two-line GetIntendedMemorySize expression. Switch 2 has several managers;
# sizing every manager for all guest DRAM wastes a large amount of host RAM.
$resizeMarker = 'm_page_reference_counts.resize(size / PageSize);'
$freedPagesMarker = 'm_freed_pages ='
if (-not $text.Contains($resizeMarker)) {
    $implStart = $text.IndexOf('size_t KMemoryManager::Impl::Initialize(', [StringComparison]::Ordinal)
    if ($implStart -lt 0) { throw 'Could not locate KMemoryManager::Impl::Initialize for PR142 metadata adapter' }

    $resizeNeedle = 'm_page_reference_counts.resize('
    $resizeStart = $text.IndexOf($resizeNeedle, $implStart, [StringComparison]::Ordinal)
    if ($resizeStart -lt 0) { throw 'Could not locate page-reference-count resize inside Impl::Initialize' }

    # Refuse to touch a later function if this source shape changes unexpectedly.
    $heapInit = $text.IndexOf('m_heap.Initialize(', $implStart, [StringComparison]::Ordinal)
    if ($heapInit -lt 0 -or $resizeStart -gt $heapInit) {
        throw 'Page-reference-count resize is outside the expected Impl::Initialize setup region'
    }

    $resizeEnd = $text.IndexOf(');', $resizeStart, [StringComparison]::Ordinal)
    if ($resizeEnd -lt 0 -or $resizeEnd -gt $heapInit) {
        throw 'Could not locate end of page-reference-count resize statement'
    }
    $resizeEnd += 2

    $lineStart = $text.LastIndexOf("`n", $resizeStart)
    if ($lineStart -lt 0) { $lineStart = 0 } else { ++$lineStart }
    $indent = $text.Substring($lineStart, $resizeStart - $lineStart)
    if ($indent.Trim().Length -ne 0) { throw 'Unexpected non-whitespace before page-reference-count resize' }

    $replacement = @(
        $indent + 'm_page_reference_counts.resize(size / PageSize);',
        $indent + 'm_freed_pages =',
        $indent + '    std::make_unique<std::atomic<u64>[]>(Common::DivCeil(size / PageSize, size_t{64}));'
    ) -join "`n"

    $text = $text.Substring(0, $lineStart) + $replacement + $text.Substring($resizeEnd)
    Write-Host '[ADAPTED] PR142 per-manager page metadata sizing by Impl::Initialize semantic anchor'
} elseif (-not $text.Contains($freedPagesMarker)) {
    throw 'PR142 page-reference resize is present but freed-page bitmap allocation is missing'
} else {
    Write-Host '[PRESENT] PR142 per-manager page metadata sizing'
}

# 4) Optimized allocation: preserve the integrated ClearBackingRegion implementation, but only zero
# pages known to have been freed. Never-used host backing is already zero and should stay uncommitted.
$takeFreedMarker = 'this->TakeFreed(offset) || fill_pattern != 0'
if (-not $text.Contains($takeFreedMarker)) {
    $optStart = $text.IndexOf('bool KMemoryManager::Impl::ProcessOptimizedAllocation(', [StringComparison]::Ordinal)
    if ($optStart -lt 0) { throw 'Could not locate ProcessOptimizedAllocation for PR142 adapter' }

    $clearNeedle = 'device_memory.buffer.ClearBackingRegion('
    $clearStart = $text.IndexOf($clearNeedle, $optStart, [StringComparison]::Ordinal)
    if ($clearStart -lt 0) { throw 'Could not locate optimized-allocation backing clear' }

    $callEnd = $text.IndexOf(');', $clearStart, [StringComparison]::Ordinal)
    if ($callEnd -lt 0) { throw 'Could not locate end of optimized-allocation backing clear call' }
    $callEnd += 2

    $lineStart = $text.LastIndexOf("`n", $clearStart)
    if ($lineStart -lt 0) { $lineStart = 0 } else { ++$lineStart }
    $indent = $text.Substring($lineStart, $clearStart - $lineStart)
    if ($indent.Trim().Length -ne 0) { throw 'Unexpected non-whitespace before optimized-allocation backing clear' }

    $originalCall = $text.Substring($lineStart, $callEnd - $lineStart)
    $indentedCall = (($originalCall -split "`n") | ForEach-Object { '    ' + $_ }) -join "`n"
    $replacement = $indent + 'if (this->TakeFreed(offset) || fill_pattern != 0) {' + "`n" +
                   $indentedCall + "`n" + $indent + '}'

    $text = $text.Substring(0, $lineStart) + $replacement + $text.Substring($callEnd)
    Write-Host '[ADAPTED] PR142 optimized-allocation freed-page clear guard by semantic call boundary'
} else {
    Write-Host '[PRESENT] PR142 optimized-allocation freed-page clear guard'
}

[IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false))
$check = Get-Content $path -Raw
foreach ($marker in @($resetMarker, $allocMarker, $resizeMarker, $freedPagesMarker, $takeFreedMarker)) {
    if (-not $check.Contains($marker)) { throw "PR142 KMemoryManager marker missing after semantic preparation: $marker" }
}

Write-Host 'Prepared PR142 KMemoryManager semantic adapters.'

# 5) VMA block slack: our integrated VRAM accounting already differs from the donor around this
# function, so patch only the missing semantic. VMA reserves blocks larger than live allocations;
# those empty bytes still consume the driver's budget even though AllocatedUsage omits them.
$vmaPath = 'src/video_core/vulkan_common/vulkan_device.cpp'
$vmaMarker = 'main_statistics.blockBytes - main_statistics.allocationBytes'
$vmaText = (Get-Content $vmaPath -Raw) -replace "`r`n", "`n"
if (-not $vmaText.Contains($vmaMarker)) {
    $budgetStart = $vmaText.IndexOf('u64 Device::GetDeviceMemoryBudget() const {', [StringComparison]::Ordinal)
    if ($budgetStart -lt 0) { throw 'Could not locate Device::GetDeviceMemoryBudget for PR142 VMA adapter' }

    # The next function boundary keeps all matching/insertion confined to GetDeviceMemoryBudget().
    $budgetEnd = $vmaText.IndexOf("`nu64 Device::", $budgetStart + 1, [StringComparison]::Ordinal)
    if ($budgetEnd -lt 0) {
        $budgetEnd = $vmaText.IndexOf("`nbool Device::", $budgetStart + 1, [StringComparison]::Ordinal)
    }
    if ($budgetEnd -lt 0) { throw 'Could not locate function after GetDeviceMemoryBudget for PR142 VMA adapter' }

    $heapLoop = $vmaText.IndexOf('    for (const size_t heap : valid_heap_memory) {', $budgetStart, [StringComparison]::Ordinal)
    if ($heapLoop -lt 0 -or $heapLoop -gt $budgetEnd) {
        throw 'Could not locate valid-heap loop inside GetDeviceMemoryBudget for PR142 VMA adapter'
    }

    # Sanity-check the integrated function still computes its main-heap budget before this point.
    $mainHeapUse = $vmaText.IndexOf('heap_budgets[main_heap]', $budgetStart, [StringComparison]::Ordinal)
    if ($mainHeapUse -lt 0 -or $mainHeapUse -gt $heapLoop) {
        throw 'GetDeviceMemoryBudget no longer references main-heap VMA statistics before heap aggregation'
    }

    $vmaInsert = @'
    // VMA block slack counts against the driver budget even though live allocation usage omits it.
    // Subtract only the main heap's reserved-but-empty bytes before adding secondary-heap usage.
    const VmaStatistics& main_statistics = heap_budgets[main_heap].statistics;
    result -= (std::min)(result, main_statistics.blockBytes - main_statistics.allocationBytes);
'@
    $vmaText = $vmaText.Substring(0, $heapLoop) + $vmaInsert.TrimEnd("`r", "`n") + "`n" +
               $vmaText.Substring($heapLoop)
    [IO.File]::WriteAllText($vmaPath, $vmaText, [Text.UTF8Encoding]::new($false))
    Write-Host '[ADAPTED] PR142 VMA block-slack budget accounting at GetDeviceMemoryBudget heap boundary'
} else {
    Write-Host '[PRESENT] PR142 VMA block-slack budget accounting'
}

if (-not (Get-Content $vmaPath -Raw).Contains($vmaMarker)) {
    throw 'PR142 VMA block-slack marker missing after semantic preparation'
}

Write-Host 'Prepared PR142 KMemoryManager + VMA semantic adapters.'
