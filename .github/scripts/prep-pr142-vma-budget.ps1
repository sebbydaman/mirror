$ErrorActionPreference = 'Stop'

# PR #142's VMA budget hunk was authored against an older GetDeviceMemoryBudget layout. The
# integrated NS2 tree already carries newer main-heap/heap-limit accounting, so prepare the same
# semantic change before the donor script runs: VMA block slack is reserved by the driver and must
# reduce the effective image budget even though it is not included in allocationBytes.
$path = 'src/video_core/vulkan_common/vulkan_device.cpp'
$marker = 'main_statistics.blockBytes - main_statistics.allocationBytes'

if (-not (Test-Path $path -PathType Leaf)) {
    throw "PR142 VMA target is missing: $path"
}

$text = (Get-Content $path -Raw) -replace "`r`n", "`n"
if ($text.Contains($marker)) {
    Write-Host '[PRESENT] PR142 VMA block-slack budget accounting'
    exit 0
}

$functionStart = $text.IndexOf('u64 Device::GetDeviceMemoryBudget() const {', [StringComparison]::Ordinal)
if ($functionStart -lt 0) {
    throw 'Could not locate Device::GetDeviceMemoryBudget for PR142 VMA adapter'
}
$nextFunction = $text.IndexOf('void Device::CollectPhysicalMemoryInfo()', $functionStart, [StringComparison]::Ordinal)
if ($nextFunction -lt 0) {
    throw 'Could not locate end boundary of Device::GetDeviceMemoryBudget for PR142 VMA adapter'
}
$functionText = $text.Substring($functionStart, $nextFunction - $functionStart)

# The later Eglantine budget path already gathers VMA heap budgets. Do not silently manufacture a
# different accounting model if that prerequisite ever disappears.
foreach ($required in @(
    'std::array<VmaBudget, VK_MAX_MEMORY_HEAPS> heap_budgets{};',
    'vmaGetHeapBudgets(allocator, heap_budgets.data());',
    'budget.heapBudget[main_heap]',
    'heap_size_limit',
    'for (const size_t heap : valid_heap_memory)'
)) {
    if (-not $functionText.Contains($required)) {
        throw "Integrated GetDeviceMemoryBudget prerequisite changed; missing '$required'"
    }
}

$loopNeedle = '    for (const size_t heap : valid_heap_memory) {'
$loopOffset = $functionText.IndexOf($loopNeedle, [StringComparison]::Ordinal)
if ($loopOffset -lt 0) {
    throw 'Could not locate secondary-heap loop inside Device::GetDeviceMemoryBudget'
}
$insertAt = $functionStart + $loopOffset

$slackAccounting = @'
    // VMA's reported heap usage omits unused bytes inside already-reserved allocation blocks.
    // Those bytes still consume the driver's budget, so keep them below the collector ceiling.
    const VmaStatistics& main_statistics = heap_budgets[main_heap].statistics;
    result -= (std::min)(result, main_statistics.blockBytes - main_statistics.allocationBytes);
'@
$slackAccounting += "`n"

$text = $text.Substring(0, $insertAt) + $slackAccounting + $text.Substring($insertAt)
[IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false))

$check = (Get-Content $path -Raw) -replace "`r`n", "`n"
$checkStart = $check.IndexOf('u64 Device::GetDeviceMemoryBudget() const {', [StringComparison]::Ordinal)
$checkEnd = $check.IndexOf('void Device::CollectPhysicalMemoryInfo()', $checkStart, [StringComparison]::Ordinal)
if ($checkStart -lt 0 -or $checkEnd -lt 0) {
    throw 'PR142 VMA adapter lost GetDeviceMemoryBudget boundaries after insertion'
}
$checkFunction = $check.Substring($checkStart, $checkEnd - $checkStart)
if (-not $checkFunction.Contains($marker)) {
    throw 'PR142 VMA block-slack marker is missing from GetDeviceMemoryBudget after insertion'
}
if (($checkFunction.Split($marker).Count - 1) -ne 1) {
    throw 'PR142 VMA block-slack accounting was inserted more than once'
}

git diff --check -- $path
if ($LASTEXITCODE -ne 0) {
    throw 'PR142 VMA semantic adapter introduced whitespace/diff errors'
}

Write-Host '[ADAPTED] PR142 VMA block-slack budget accounting onto integrated GetDeviceMemoryBudget'
