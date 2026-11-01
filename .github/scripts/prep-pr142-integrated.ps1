$ErrorActionPreference = 'Stop'

# Semantic pre-adapter for the targeted Eglantine PR #142 subset.
# The donor was written against an older source shape; port the same semantics onto the proven
# post-PokeDinner/Eglantine tree without replacing newer memory, VRAM, PipelineStats or shader-reuse
# logic. Every edit is confined to a known function and validated with a marker afterwards.

function Require-Marker([string]$Path, [string]$Marker, [string]$Name) {
    if (-not (Test-Path $Path -PathType Leaf)) { throw "PR142 prep: missing $Path" }
    if (-not (Get-Content $Path -Raw).Contains($Marker)) {
        throw "PR142 prep: $Name marker missing from $Path"
    }
}

# -----------------------------------------------------------------------------
# KMemoryManager: selective zero-fill / freed-page host-RAM tracking
# -----------------------------------------------------------------------------
$kmPath = 'src/core/hle/kernel/k_memory_manager.cpp'
$km = (Get-Content $kmPath -Raw) -replace "`r`n", "`n"

# 1) Cross-session reset. Device backing outlives an emulation session, so after the first session
# every page must be considered potentially dirty/freed until proven otherwise.
$resetMarker = 'std::exchange(m_system.DeviceMemory().used_by_kernel, true)'
if (-not $km.Contains($resetMarker)) {
    $start = $km.IndexOf('void KMemoryManager::Initialize(', [StringComparison]::Ordinal)
    $next = $km.IndexOf('Result KMemoryManager::InitializeOptimizedMemory(', $start, [StringComparison]::Ordinal)
    if ($start -lt 0 -or $next -lt 0) { throw 'PR142 prep: KMemoryManager::Initialize boundary not found' }
    $close = $km.LastIndexOf('}', $next - 1)
    if ($close -le $start) { throw 'PR142 prep: KMemoryManager::Initialize closing brace not found' }
    $insert = @'
    // The host backing outlives emulation sessions: after an earlier one, no page is known zero.
    if (std::exchange(m_system.DeviceMemory().used_by_kernel, true)) {
        for (size_t i = 0; i < m_num_managers; ++i) {
            m_managers[i].MarkAllFreed();
        }
    }
'@
    $km = $km.Substring(0, $close).TrimEnd("`n") + "`n`n" +
          $insert.TrimEnd("`r", "`n") + "`n" + $km.Substring($close)
    Write-Host '[ADAPTED] PR142 KMemoryManager cross-session reset'
} else {
    Write-Host '[PRESENT] PR142 KMemoryManager cross-session reset'
}

# 2) AllocateForProcess. Replace only the one direct backing clear inside this function; the donor
# layer supplies FillAllocatedPages(), which knows whether a zero write is actually necessary.
$allocMarker = 'this->FillAllocatedPages(block.GetAddress(), block.GetNumPages(), fill_pattern);'
if (-not $km.Contains($allocMarker)) {
    $start = $km.IndexOf('Result KMemoryManager::AllocateForProcess(', [StringComparison]::Ordinal)
    $end = $km.IndexOf('    R_SUCCEED();', $start, [StringComparison]::Ordinal)
    if ($start -lt 0 -or $end -lt 0) { throw 'PR142 prep: AllocateForProcess boundary not found' }
    $needle = 'm_system.DeviceMemory().buffer.ClearBackingRegion('
    $call = $km.IndexOf($needle, $start, [StringComparison]::Ordinal)
    if ($call -lt 0 -or $call -gt $end) { throw 'PR142 prep: AllocateForProcess backing clear not found' }
    $again = $km.IndexOf($needle, $call + $needle.Length, [StringComparison]::Ordinal)
    if ($again -ge 0 -and $again -lt $end) { throw 'PR142 prep: ambiguous AllocateForProcess backing clears' }
    $callEnd = $km.IndexOf(');', $call, [StringComparison]::Ordinal)
    if ($callEnd -lt 0 -or $callEnd -gt $end) { throw 'PR142 prep: AllocateForProcess call end not found' }
    $callEnd += 2
    $lineStart = $km.LastIndexOf("`n", $call)
    if ($lineStart -lt 0) { $lineStart = 0 } else { ++$lineStart }
    $indent = $km.Substring($lineStart, $call - $lineStart)
    if ($indent.Trim().Length -ne 0) { throw 'PR142 prep: unexpected AllocateForProcess line prefix' }
    $km = $km.Substring(0, $lineStart) + $indent + $allocMarker + $km.Substring($callEnd)
    Write-Host '[ADAPTED] PR142 AllocateForProcess selective-fill routing'
} else {
    Write-Host '[PRESENT] PR142 AllocateForProcess selective-fill routing'
}

# 3) Per-manager metadata. The older donor sized every manager's reference counts to all guest DRAM;
# Switch 2 has several managers, so size each one only to its own region and allocate its freed bitmap.
$resizeMarker = 'm_page_reference_counts.resize(size / PageSize);'
$freedMarker = 'm_freed_pages ='
if (-not $km.Contains($resizeMarker)) {
    $start = $km.IndexOf('size_t KMemoryManager::Impl::Initialize(', [StringComparison]::Ordinal)
    $heap = $km.IndexOf('m_heap.Initialize(', $start, [StringComparison]::Ordinal)
    $resize = $km.IndexOf('m_page_reference_counts.resize(', $start, [StringComparison]::Ordinal)
    if ($start -lt 0 -or $heap -lt 0 -or $resize -lt 0 -or $resize -gt $heap) {
        throw 'PR142 prep: Impl::Initialize page metadata anchor not found'
    }
    $resizeEnd = $km.IndexOf(');', $resize, [StringComparison]::Ordinal)
    if ($resizeEnd -lt 0 -or $resizeEnd -gt $heap) { throw 'PR142 prep: page metadata resize end not found' }
    $resizeEnd += 2
    $lineStart = $km.LastIndexOf("`n", $resize)
    if ($lineStart -lt 0) { $lineStart = 0 } else { ++$lineStart }
    $indent = $km.Substring($lineStart, $resize - $lineStart)
    if ($indent.Trim().Length -ne 0) { throw 'PR142 prep: unexpected page metadata line prefix' }
    $replacement = @(
        $indent + 'm_page_reference_counts.resize(size / PageSize);',
        $indent + 'm_freed_pages =',
        $indent + '    std::make_unique<std::atomic<u64>[]>(Common::DivCeil(size / PageSize, size_t{64}));'
    ) -join "`n"
    $km = $km.Substring(0, $lineStart) + $replacement + $km.Substring($resizeEnd)
    Write-Host '[ADAPTED] PR142 per-manager page metadata sizing'
} elseif (-not $km.Contains($freedMarker)) {
    throw 'PR142 prep: per-manager resize exists but freed-page bitmap allocation is missing'
} else {
    Write-Host '[PRESENT] PR142 per-manager page metadata sizing'
}

# 4) Optimized allocation. Preserve the newer ClearBackingRegion path, but only zero a page when it
# was previously freed; never-used backing is already zero and should stay uncommitted in host RAM.
$takeFreedMarker = 'this->TakeFreed(offset) || fill_pattern != 0'
if (-not $km.Contains($takeFreedMarker)) {
    $start = $km.IndexOf('bool KMemoryManager::Impl::ProcessOptimizedAllocation(', [StringComparison]::Ordinal)
    if ($start -lt 0) { throw 'PR142 prep: ProcessOptimizedAllocation not found' }
    $needle = 'device_memory.buffer.ClearBackingRegion('
    $call = $km.IndexOf($needle, $start, [StringComparison]::Ordinal)
    if ($call -lt 0) { throw 'PR142 prep: optimized allocation backing clear not found' }
    $callEnd = $km.IndexOf(');', $call, [StringComparison]::Ordinal)
    if ($callEnd -lt 0) { throw 'PR142 prep: optimized backing clear call end not found' }
    $callEnd += 2
    $lineStart = $km.LastIndexOf("`n", $call)
    if ($lineStart -lt 0) { $lineStart = 0 } else { ++$lineStart }
    $indent = $km.Substring($lineStart, $call - $lineStart)
    if ($indent.Trim().Length -ne 0) { throw 'PR142 prep: unexpected optimized clear line prefix' }
    $original = $km.Substring($lineStart, $callEnd - $lineStart)
    $nested = (($original -split "`n") | ForEach-Object { '    ' + $_ }) -join "`n"
    $replacement = $indent + 'if (this->TakeFreed(offset) || fill_pattern != 0) {' + "`n" +
                   $nested + "`n" + $indent + '}'
    $km = $km.Substring(0, $lineStart) + $replacement + $km.Substring($callEnd)
    Write-Host '[ADAPTED] PR142 optimized-allocation freed-page clear guard'
} else {
    Write-Host '[PRESENT] PR142 optimized-allocation freed-page clear guard'
}

[IO.File]::WriteAllText($kmPath, $km, [Text.UTF8Encoding]::new($false))
foreach ($marker in @($resetMarker, $allocMarker, $resizeMarker, $freedMarker, $takeFreedMarker)) {
    Require-Marker $kmPath $marker 'KMemoryManager semantic adapter'
}

# -----------------------------------------------------------------------------
# Vulkan VMA budget: count reserved-but-empty VMA block bytes against usable VRAM
# -----------------------------------------------------------------------------
$vmaPath = 'src/video_core/vulkan_common/vulkan_device.cpp'
$vmaMarker = 'main_statistics.blockBytes - main_statistics.allocationBytes'
$vma = (Get-Content $vmaPath -Raw) -replace "`r`n", "`n"
if (-not $vma.Contains($vmaMarker)) {
    $start = $vma.IndexOf('u64 Device::GetDeviceMemoryBudget() const {', [StringComparison]::Ordinal)
    $end = $vma.IndexOf('void Device::CollectPhysicalMemoryInfo()', $start, [StringComparison]::Ordinal)
    $loop = $vma.IndexOf('    for (const size_t heap : valid_heap_memory) {', $start, [StringComparison]::Ordinal)
    if ($start -lt 0 -or $end -lt 0 -or $loop -lt 0 -or $loop -gt $end) {
        throw 'PR142 prep: GetDeviceMemoryBudget function/heap-loop boundary not found'
    }

    # IMPORTANT: the proven #208 function uses budget.heapBudget[main_heap]. The donor addition below
    # introduces heap_budgets[main_heap] for the first time, so do not require that donor symbol yet.
    $mainBudget = $vma.IndexOf('budget.heapBudget[main_heap]', $start, [StringComparison]::Ordinal)
    if ($mainBudget -lt 0 -or $mainBudget -gt $loop) {
        throw 'PR142 prep: GetDeviceMemoryBudget main-heap budget computation moved unexpectedly'
    }

    $insert = @'
    // VMA block slack counts against the driver budget even when live allocation usage omits it.
    const VmaStatistics& main_statistics = heap_budgets[main_heap].statistics;
    result -= (std::min)(result, main_statistics.blockBytes - main_statistics.allocationBytes);
'@
    $vma = $vma.Substring(0, $loop) + $insert.TrimEnd("`r", "`n") + "`n" + $vma.Substring($loop)
    [IO.File]::WriteAllText($vmaPath, $vma, [Text.UTF8Encoding]::new($false))
    Write-Host '[ADAPTED] PR142 VMA block-slack budget accounting'
} else {
    Write-Host '[PRESENT] PR142 VMA block-slack budget accounting'
}
Require-Marker $vmaPath $vmaMarker 'VMA block-slack accounting'

# -----------------------------------------------------------------------------
# Vulkan shader-module lifetime
# -----------------------------------------------------------------------------
# Compute: PipelineStats changed donor context, but the SPIR-V module is no longer needed after
# vkCreateComputePipelines returns. Release it on both success and exception paths.
$computePath = 'src/video_core/renderer_vulkan/vk_compute_pipeline.cpp'
$computeMarker = 'Only needed to create the pipeline.'
$compute = (Get-Content $computePath -Raw) -replace "`r`n", "`n"
if (-not $compute.Contains($computeMarker)) {
    $createLine = '            pipeline = device.GetLogical().CreateComputePipeline(compute_ci, *pipeline_cache);'
    $create = $compute.IndexOf($createLine, [StringComparison]::Ordinal)
    if ($create -lt 0) { throw 'PR142 prep: compute pipeline creation call not found' }
    $createEnd = $create + $createLine.Length
    $compute = $compute.Insert($createEnd,
        "`n            // Only needed to create the pipeline.`n            spv_module = {};")
    $catchLine = '        } catch (const vk::Exception& exception) {'
    $catch = $compute.IndexOf($catchLine, $createEnd, [StringComparison]::Ordinal)
    if ($catch -lt 0) { throw 'PR142 prep: compute pipeline exception handler not found' }
    $catchEnd = $catch + $catchLine.Length
    $compute = $compute.Insert($catchEnd, "`n            spv_module = {};")
    [IO.File]::WriteAllText($computePath, $compute, [Text.UTF8Encoding]::new($false))
    Write-Host '[ADAPTED] PR142 compute shader-module release over PipelineStats path'
} else {
    Write-Host '[PRESENT] PR142 compute shader-module release'
}
Require-Marker $computePath $computeMarker 'compute shader-module release'
Require-Marker $computePath 'spv_module = {};' 'compute shader-module reset'

# Graphics: modules are shared and pipeline creation may run asynchronously. Compute ConfigureFunc
# before queuing async work, then release this pipeline's module ownership after MakePipeline succeeds
# or throws. This preserves shader reuse while avoiding a late constructor dereference race.
$graphicsPath = 'src/video_core/renderer_vulkan/vk_graphics_pipeline.cpp'
$graphicsMarker = 'modules are only needed to create the pipeline'
$graphics = (Get-Content $graphicsPath -Raw) -replace "`r`n", "`n"
if (-not $graphics.Contains($graphicsMarker)) {
    $configureLine = '    configure_func = ConfigureFunc(*spv_modules, stage_infos);'
    $configure = $graphics.IndexOf($configureLine, [StringComparison]::Ordinal)
    if ($configure -lt 0) { throw 'PR142 prep: graphics ConfigureFunc assignment not found' }
    $configureEnd = $configure + $configureLine.Length
    if ($configureEnd -lt $graphics.Length -and $graphics[$configureEnd] -eq "`n") { ++$configureEnd }
    $graphics = $graphics.Remove($configure, $configureEnd - $configure)

    $workerLine = '    const bool on_parallel_worker{worker_thread != nullptr};'
    $worker = $graphics.IndexOf($workerLine, [StringComparison]::Ordinal)
    if ($worker -lt 0) { throw 'PR142 prep: graphics worker anchor not found' }
    $graphics = $graphics.Insert($worker, $configureLine + "`n`n")

    $makeLine = '            MakePipeline(render_pass);'
    $make = $graphics.IndexOf($makeLine, $worker, [StringComparison]::Ordinal)
    if ($make -lt 0) { throw 'PR142 prep: graphics MakePipeline call not found' }
    $makeEnd = $make + $makeLine.Length
    $graphics = $graphics.Insert($makeEnd,
        "`n            // SPIR-V modules are only needed to create the pipeline.`n            spv_modules = {};")

    $catchLine = '        } catch (const vk::Exception& exception) {'
    $catch = $graphics.IndexOf($catchLine, $makeEnd, [StringComparison]::Ordinal)
    if ($catch -lt 0) { throw 'PR142 prep: graphics pipeline exception handler not found' }
    $catchEnd = $catch + $catchLine.Length
    $graphics = $graphics.Insert($catchEnd, "`n            spv_modules = {};")

    [IO.File]::WriteAllText($graphicsPath, $graphics, [Text.UTF8Encoding]::new($false))
    Write-Host '[ADAPTED] PR142 graphics shader-module release over shared-module async path'
} else {
    Write-Host '[PRESENT] PR142 graphics shader-module release'
}
Require-Marker $graphicsPath $graphicsMarker 'graphics shader-module release'
Require-Marker $graphicsPath 'spv_modules = {};' 'graphics shader-module reset'

$graphicsCheck = Get-Content $graphicsPath -Raw
$ctor = $graphicsCheck.IndexOf('GraphicsPipeline::GraphicsPipeline(', [StringComparison]::Ordinal)
$worker = $graphicsCheck.IndexOf('const bool on_parallel_worker{worker_thread != nullptr};', $ctor, [StringComparison]::Ordinal)
$configure = $graphicsCheck.IndexOf('configure_func = ConfigureFunc(*spv_modules, stage_infos);', $ctor, [StringComparison]::Ordinal)
if ($ctor -lt 0 -or $worker -lt 0 -or $configure -lt 0 -or $configure -gt $worker) {
    throw 'PR142 prep: graphics ConfigureFunc must be computed before asynchronous work starts'
}

git diff --check
if ($LASTEXITCODE -ne 0) { throw 'PR142 integrated pre-adapter introduced whitespace/diff errors' }

Write-Host 'Prepared integrated PR142 KMemoryManager + VMA + shader-module lifetime semantics.'