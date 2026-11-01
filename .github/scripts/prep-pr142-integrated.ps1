$ErrorActionPreference = 'Stop'

# Semantic pre-adapter for the targeted Eglantine PR #142 subset. The donor was written against an
# older source shape; this script ports the same semantics onto our proven post-PokeDinner/Eglantine
# integrated tree without replacing newer memory, VRAM-budget, PipelineStats or shader-reuse logic.

$kmPath = 'src/core/hle/kernel/k_memory_manager.cpp'
$km = (Get-Content $kmPath -Raw) -replace "`r`n", "`n"

# 1) Cross-session freed-page state.
$resetMarker = 'std::exchange(m_system.DeviceMemory().used_by_kernel, true)'
if (-not $km.Contains($resetMarker)) {
    $start = $km.IndexOf('void KMemoryManager::Initialize(', [StringComparison]::Ordinal)
    if ($start -lt 0) { throw 'Could not locate KMemoryManager::Initialize for PR142 reset adapter' }
    $next = $km.IndexOf('Result KMemoryManager::InitializeOptimizedMemory(', $start, [StringComparison]::Ordinal)
    if ($next -lt 0) { throw 'Could not locate function after KMemoryManager::Initialize for PR142 reset adapter' }
    $close = $km.LastIndexOf('}', $next - 1)
    if ($close -le $start) { throw 'Could not locate KMemoryManager::Initialize closing brace' }

    $insert = @'
    // The host backing outlives emulation sessions: after an earlier one, no page is known zero.
    if (std::exchange(m_system.DeviceMemory().used_by_kernel, true)) {
        for (size_t i = 0; i < m_num_managers; ++i) {
            m_managers[i].MarkAllFreed();
        }
    }
'@
    $prefix = $km.Substring(0, $close).TrimEnd("`n")
    $suffix = $km.Substring($close)
    $km = $prefix + "`n`n" + $insert.TrimEnd("`r", "`n") + "`n" + $suffix
    Write-Host '[ADAPTED] PR142 KMemoryManager cross-session reset'
} else {
    Write-Host '[PRESENT] PR142 KMemoryManager cross-session reset'
}

# 2) AllocateForProcess selective zero-fill routing.
$allocMarker = 'this->FillAllocatedPages(block.GetAddress(), block.GetNumPages(), fill_pattern);'
if (-not $km.Contains($allocMarker)) {
    $allocStart = $km.IndexOf('Result KMemoryManager::AllocateForProcess(', [StringComparison]::Ordinal)
    if ($allocStart -lt 0) { throw 'Could not locate KMemoryManager::AllocateForProcess' }
    $allocReturn = $km.IndexOf('    R_SUCCEED();', $allocStart, [StringComparison]::Ordinal)
    if ($allocReturn -lt 0) { throw 'Could not locate AllocateForProcess return boundary' }

    $clearNeedle = 'm_system.DeviceMemory().buffer.ClearBackingRegion('
    $clearStart = $km.IndexOf($clearNeedle, $allocStart, [StringComparison]::Ordinal)
    if ($clearStart -lt 0 -or $clearStart -gt $allocReturn) {
        throw 'Could not locate AllocateForProcess backing clear'
    }
    $secondClear = $km.IndexOf($clearNeedle, $clearStart + $clearNeedle.Length, [StringComparison]::Ordinal)
    if ($secondClear -ge 0 -and $secondClear -lt $allocReturn) {
        throw 'AllocateForProcess contains multiple backing clears; refusing ambiguous rewrite'
    }
    $callEnd = $km.IndexOf(');', $clearStart, [StringComparison]::Ordinal)
    if ($callEnd -lt 0 -or $callEnd -gt $allocReturn) { throw 'Could not locate backing-clear call end' }
    $callEnd += 2
    $lineStart = $km.LastIndexOf("`n", $clearStart)
    if ($lineStart -lt 0) { $lineStart = 0 } else { ++$lineStart }
    $indent = $km.Substring($lineStart, $clearStart - $lineStart)
    if ($indent.Trim().Length -ne 0) { throw 'Unexpected text before AllocateForProcess backing clear' }
    $km = $km.Substring(0, $lineStart) + $indent + $allocMarker + $km.Substring($callEnd)
    Write-Host '[ADAPTED] PR142 AllocateForProcess selective-fill routing'
} else {
    Write-Host '[PRESENT] PR142 AllocateForProcess selective-fill routing'
}

# 3) Per-manager page-reference/freed-page metadata sizing.
$resizeMarker = 'm_page_reference_counts.resize(size / PageSize);'
$freedPagesMarker = 'm_freed_pages ='
if (-not $km.Contains($resizeMarker)) {
    $implStart = $km.IndexOf('size_t KMemoryManager::Impl::Initialize(', [StringComparison]::Ordinal)
    if ($implStart -lt 0) { throw 'Could not locate KMemoryManager::Impl::Initialize' }
    $resizeNeedle = 'm_page_reference_counts.resize('
    $resizeStart = $km.IndexOf($resizeNeedle, $implStart, [StringComparison]::Ordinal)
    if ($resizeStart -lt 0) { throw 'Could not locate page-reference-count resize' }
    $heapInit = $km.IndexOf('m_heap.Initialize(', $implStart, [StringComparison]::Ordinal)
    if ($heapInit -lt 0 -or $resizeStart -gt $heapInit) {
        throw 'Page-reference-count resize is outside expected Impl::Initialize setup region'
    }
    $resizeEnd = $km.IndexOf(');', $resizeStart, [StringComparison]::Ordinal)
    if ($resizeEnd -lt 0 -or $resizeEnd -gt $heapInit) { throw 'Could not locate resize statement end' }
    $resizeEnd += 2
    $lineStart = $km.LastIndexOf("`n", $resizeStart)
    if ($lineStart -lt 0) { $lineStart = 0 } else { ++$lineStart }
    $indent = $km.Substring($lineStart, $resizeStart - $lineStart)
    if ($indent.Trim().Length -ne 0) { throw 'Unexpected text before page-reference-count resize' }
    $replacement = @(
        $indent + 'm_page_reference_counts.resize(size / PageSize);',
        $indent + 'm_freed_pages =',
        $indent + '    std::make_unique<std::atomic<u64>[]>(Common::DivCeil(size / PageSize, size_t{64}));'
    ) -join "`n"
    $km = $km.Substring(0, $lineStart) + $replacement + $km.Substring($resizeEnd)
    Write-Host '[ADAPTED] PR142 per-manager page metadata sizing'
} elseif (-not $km.Contains($freedPagesMarker)) {
    throw 'PR142 page-reference resize is present but freed-page bitmap allocation is missing'
} else {
    Write-Host '[PRESENT] PR142 per-manager page metadata sizing'
}

# 4) Optimized allocator: preserve ClearBackingRegion but skip zeroing never-used backing pages.
$takeFreedMarker = 'this->TakeFreed(offset) || fill_pattern != 0'
if (-not $km.Contains($takeFreedMarker)) {
    $optStart = $km.IndexOf('bool KMemoryManager::Impl::ProcessOptimizedAllocation(', [StringComparison]::Ordinal)
    if ($optStart -lt 0) { throw 'Could not locate ProcessOptimizedAllocation' }
    $clearNeedle = 'device_memory.buffer.ClearBackingRegion('
    $clearStart = $km.IndexOf($clearNeedle, $optStart, [StringComparison]::Ordinal)
    if ($clearStart -lt 0) { throw 'Could not locate optimized-allocation backing clear' }
    $callEnd = $km.IndexOf(');', $clearStart, [StringComparison]::Ordinal)
    if ($callEnd -lt 0) { throw 'Could not locate optimized-allocation backing-clear end' }
    $callEnd += 2
    $lineStart = $km.LastIndexOf("`n", $clearStart)
    if ($lineStart -lt 0) { $lineStart = 0 } else { ++$lineStart }
    $indent = $km.Substring($lineStart, $clearStart - $lineStart)
    if ($indent.Trim().Length -ne 0) { throw 'Unexpected text before optimized backing clear' }
    $originalCall = $km.Substring($lineStart, $callEnd - $lineStart)
    $indentedCall = (($originalCall -split "`n") | ForEach-Object { '    ' + $_ }) -join "`n"
    $replacement = $indent + 'if (this->TakeFreed(offset) || fill_pattern != 0) {' + "`n" +
                   $indentedCall + "`n" + $indent + '}'
    $km = $km.Substring(0, $lineStart) + $replacement + $km.Substring($callEnd)
    Write-Host '[ADAPTED] PR142 optimized-allocation freed-page clear guard'
} else {
    Write-Host '[PRESENT] PR142 optimized-allocation freed-page clear guard'
}

[IO.File]::WriteAllText($kmPath, $km, [Text.UTF8Encoding]::new($false))
$kmCheck = Get-Content $kmPath -Raw
foreach ($marker in @($resetMarker, $allocMarker, $resizeMarker, $freedPagesMarker, $takeFreedMarker)) {
    if (-not $kmCheck.Contains($marker)) { throw "PR142 KMemoryManager marker missing: $marker" }
}

# 5) VMA block slack. The proven tree's next function is CollectPhysicalMemoryInfo(), so use that
# exact function boundary rather than guessing the next return type.
$vmaPath = 'src/video_core/vulkan_common/vulkan_device.cpp'
$vmaMarker = 'main_statistics.blockBytes - main_statistics.allocationBytes'
$vma = (Get-Content $vmaPath -Raw) -replace "`r`n", "`n"
if (-not $vma.Contains($vmaMarker)) {
    $budgetStart = $vma.IndexOf('u64 Device::GetDeviceMemoryBudget() const {', [StringComparison]::Ordinal)
    if ($budgetStart -lt 0) { throw 'Could not locate Device::GetDeviceMemoryBudget' }
    $budgetEnd = $vma.IndexOf('void Device::CollectPhysicalMemoryInfo()', $budgetStart, [StringComparison]::Ordinal)
    if ($budgetEnd -lt 0) { throw 'Could not locate CollectPhysicalMemoryInfo after GetDeviceMemoryBudget' }
    $heapLoop = $vma.IndexOf('    for (const size_t heap : valid_heap_memory) {', $budgetStart, [StringComparison]::Ordinal)
    if ($heapLoop -lt 0 -or $heapLoop -gt $budgetEnd) { throw 'Could not locate budget valid-heap loop' }
    $mainHeapUse = $vma.IndexOf('heap_budgets[main_heap]', $budgetStart, [StringComparison]::Ordinal)
    if ($mainHeapUse -lt 0 -or $mainHeapUse -gt $heapLoop) {
        throw 'GetDeviceMemoryBudget no longer references main-heap VMA statistics before aggregation'
    }
    $insert = @'
    // VMA block slack counts against the driver budget even when live allocation usage omits it.
    const VmaStatistics& main_statistics = heap_budgets[main_heap].statistics;
    result -= (std::min)(result, main_statistics.blockBytes - main_statistics.allocationBytes);
'@
    $vma = $vma.Substring(0, $heapLoop) + $insert.TrimEnd("`r", "`n") + "`n" + $vma.Substring($heapLoop)
    [IO.File]::WriteAllText($vmaPath, $vma, [Text.UTF8Encoding]::new($false))
    Write-Host '[ADAPTED] PR142 VMA block-slack budget accounting'
} else {
    Write-Host '[PRESENT] PR142 VMA block-slack budget accounting'
}
if (-not (Get-Content $vmaPath -Raw).Contains($vmaMarker)) { throw 'PR142 VMA marker missing' }

# 6) Compute-pipeline shader-module lifetime. PipelineStats changed the donor's try-block context, but
# Vulkan no longer needs the SPIR-V module once vkCreateComputePipelines returns (or throws).
$computePath = 'src/video_core/renderer_vulkan/vk_compute_pipeline.cpp'
$computeMarker = 'Only needed to create the pipeline.'
$compute = (Get-Content $computePath -Raw) -replace "`r`n", "`n"
if (-not $compute.Contains($computeMarker)) {
    $createLine = '            pipeline = device.GetLogical().CreateComputePipeline(compute_ci, *pipeline_cache);'
    $createPos = $compute.IndexOf($createLine, [StringComparison]::Ordinal)
    if ($createPos -lt 0) { throw 'Could not locate compute Vulkan pipeline creation call' }
    $createEnd = $createPos + $createLine.Length
    $successRelease = "`n            // Only needed to create the pipeline.`n            spv_module = {};"
    $compute = $compute.Substring(0, $createEnd) + $successRelease + $compute.Substring($createEnd)

    $catchLine = '        } catch (const vk::Exception& exception) {'
    $catchPos = $compute.IndexOf($catchLine, $createEnd, [StringComparison]::Ordinal)
    if ($catchPos -lt 0) { throw 'Could not locate compute pipeline exception handler' }
    $catchEnd = $catchPos + $catchLine.Length
    $compute = $compute.Substring(0, $catchEnd) + "`n            spv_module = {};" + $compute.Substring($catchEnd)
    [IO.File]::WriteAllText($computePath, $compute, [Text.UTF8Encoding]::new($false))
    Write-Host '[ADAPTED] PR142 compute shader-module release over PipelineStats path'
} else {
    Write-Host '[PRESENT] PR142 compute shader-module release'
}
$computeCheck = Get-Content $computePath -Raw
if (-not ($computeCheck.Contains($computeMarker) -and $computeCheck.Contains('spv_module = {};'))) {
    throw 'PR142 compute shader-module release validation failed'
}

# 7) Graphics-pipeline shader-module lifetime. Our integrated tree stores modules in a shared_ptr and
# may build asynchronously. ConfigureFunc only inspects stage presence and returns a function pointer,
# so compute it before queuing work; then the pipeline job can safely release this pipeline's module
# ownership after MakePipeline succeeds or fails without racing the constructor's old dereference.
$graphicsPath = 'src/video_core/renderer_vulkan/vk_graphics_pipeline.cpp'
$graphicsMarker = 'modules are only needed to create the pipeline'
$graphics = (Get-Content $graphicsPath -Raw) -replace "`r`n", "`n"
if (-not $graphics.Contains($graphicsMarker)) {
    $configureLine = '    configure_func = ConfigureFunc(*spv_modules, stage_infos);'
    $configurePos = $graphics.IndexOf($configureLine, [StringComparison]::Ordinal)
    if ($configurePos -lt 0) { throw 'Could not locate graphics ConfigureFunc assignment' }
    $configureLineEnd = $configurePos + $configureLine.Length
    if ($configureLineEnd -lt $graphics.Length -and $graphics[$configureLineEnd] -eq "`n") { ++$configureLineEnd }
    $graphics = $graphics.Remove($configurePos, $configureLineEnd - $configurePos)

    $workerAnchor = '    const bool on_parallel_worker{worker_thread != nullptr};'
    $workerPos = $graphics.IndexOf($workerAnchor, [StringComparison]::Ordinal)
    if ($workerPos -lt 0) { throw 'Could not locate graphics worker anchor' }
    $earlyConfigure = $configureLine + "`n`n"
    $graphics = $graphics.Insert($workerPos, $earlyConfigure)

    $makeLine = '            MakePipeline(render_pass);'
    $makePos = $graphics.IndexOf($makeLine, $workerPos, [StringComparison]::Ordinal)
    if ($makePos -lt 0) { throw 'Could not locate graphics MakePipeline call' }
    $makeEnd = $makePos + $makeLine.Length
    $graphics = $graphics.Insert($makeEnd,
        "`n            // SPIR-V modules are only needed to create the pipeline.`n            spv_modules = {};")

    $catchLine = '        } catch (const vk::Exception& exception) {'
    $catchPos = $graphics.IndexOf($catchLine, $makeEnd, [StringComparison]::Ordinal)
    if ($catchPos -lt 0) { throw 'Could not locate graphics pipeline exception handler' }
    $catchEnd = $catchPos + $catchLine.Length
    $graphics = $graphics.Insert($catchEnd, "`n            spv_modules = {};")

    [IO.File]::WriteAllText($graphicsPath, $graphics, [Text.UTF8Encoding]::new($false))
    Write-Host '[ADAPTED] PR142 graphics shader-module release over shared-module async path'
} else {
    Write-Host '[PRESENT] PR142 graphics shader-module release'
}
$graphicsCheck = Get-Content $graphicsPath -Raw
if (-not ($graphicsCheck.Contains($graphicsMarker) -and $graphicsCheck.Contains('spv_modules = {};'))) {
    throw 'PR142 graphics shader-module release validation failed'
}
$constructorStart = $graphicsCheck.IndexOf('GraphicsPipeline::GraphicsPipeline(', [StringComparison]::Ordinal)
$workerStart = $graphicsCheck.IndexOf('const bool on_parallel_worker{worker_thread != nullptr};', $constructorStart, [StringComparison]::Ordinal)
$configureStart = $graphicsCheck.IndexOf('configure_func = ConfigureFunc(*spv_modules, stage_infos);', $constructorStart, [StringComparison]::Ordinal)
if ($constructorStart -lt 0 -or $workerStart -lt 0 -or $configureStart -lt 0 -or $configureStart -gt $workerStart) {
    throw 'PR142 graphics module release is unsafe: ConfigureFunc must be computed before async work starts'
}

git diff --check
if ($LASTEXITCODE -ne 0) { throw 'PR142 integrated pre-adapter introduced whitespace/diff errors' }

Write-Host 'Prepared integrated PR142 KMemoryManager + VMA + shader-module lifetime semantics.'
