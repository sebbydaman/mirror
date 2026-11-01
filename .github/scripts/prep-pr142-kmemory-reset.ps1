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

[IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false))
$check = Get-Content $path -Raw
if (-not $check.Contains($resetMarker)) { throw 'PR142 KMemoryManager reset marker missing after semantic insertion' }
if (-not $check.Contains($allocMarker)) { throw 'PR142 AllocateForProcess fill-routing marker missing after semantic insertion' }

Write-Host 'Prepared PR142 KMemoryManager semantic adapters.'
