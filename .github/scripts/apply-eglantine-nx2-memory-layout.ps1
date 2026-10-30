$ErrorActionPreference = "Stop"

function Replace-Exact([string]$Path, [string]$Old, [string]$New, [string]$Description) {
    if (-not (Test-Path $Path)) { throw "Missing required file: $Path" }
    $text = Get-Content $Path -Raw
    if ($text.Contains($New)) {
        Write-Host "Already applied: $Description"
        return
    }
    if (-not $text.Contains($Old)) {
        throw "Could not locate anchor for $Description in $Path"
    }
    $text = $text.Replace($Old, $New)
    Set-Content -Path $Path -Value $text -Encoding utf8 -NoNewline
    Write-Host "Applied: $Description"
}

# Port the general 39-bit memory-layout behavior from the Bananza-playable Eden-NS2 tree.
# Switch 1 layouts remain at their historical 8 GiB heap minimum. A 12 GiB Switch 2 guest
# receives a 12 GiB heap region, allowing nninitStartup to request its observed 9.527 GiB heap
# without weakening the page-table/resource-limit checks.

$addressHeader = "src/core/hle/kernel/k_address_space_info.h"
Replace-Exact $addressHeader `
    '    static std::size_t GetAddressSpaceSize(std::size_t width, Type type);' `
    "    static std::size_t GetAddressSpaceSize(std::size_t width, Type type,`n                                               std::size_t physical_memory_size = 0);" `
    "physical-memory-aware address-space sizing declaration"

$addressCpp = "src/core/hle/kernel/k_address_space_info.cpp"
$addressText = Get-Content $addressCpp -Raw
if (-not $addressText.Contains('#include <algorithm>')) {
    $addressText = $addressText.Replace('#include <array>', "#include <algorithm>`n#include <array>")
}
if (-not $addressText.Contains('#include "common/alignment.h"')) {
    $addressText = $addressText.Replace('#include "common/assert.h"', "#include `"common/alignment.h`"`n#include `"common/assert.h`"")
}
$oldSizeFunction = @'
std::size_t KAddressSpaceInfo::GetAddressSpaceSize(size_t width, KAddressSpaceInfo::Type type) {
    return GetAddressSpaceInfo(width, type).size;
}
'@
$newSizeFunction = @'
std::size_t KAddressSpaceInfo::GetAddressSpaceSize(size_t width, KAddressSpaceInfo::Type type,
                                                  size_t physical_memory_size) {
    if (width == 39 && (type == Type::Heap || type == Type::Alias)) {
        const size_t heap_size = std::clamp(
            Common::AlignUp(std::min(physical_memory_size, size_t{32_GiB}), size_t{1_GiB}),
            size_t{8_GiB}, size_t{32_GiB});
        return type == Type::Heap ? heap_size : std::min(heap_size * 8, size_t{128_GiB});
    }
    return GetAddressSpaceInfo(width, type).size;
}
'@
if (-not $addressText.Contains($newSizeFunction.Trim())) {
    if (-not $addressText.Contains($oldSizeFunction.Trim())) {
        throw "Could not locate KAddressSpaceInfo::GetAddressSpaceSize implementation"
    }
    $addressText = $addressText.Replace($oldSizeFunction.Trim(), $newSizeFunction.Trim())
}
Set-Content -Path $addressCpp -Value $addressText -Encoding utf8 -NoNewline
Write-Host "Applied: dynamic 39-bit heap/alias region sizing"

$pageTable = "src/core/hle/kernel/k_page_table_base.cpp"
$oldHelper = @'
    auto GetSpaceSize = [&](KAddressSpaceInfo::Type type) {
        return KAddressSpaceInfo::GetAddressSpaceSize(m_address_space_width, type);
    };
'@
$newHelper = @'
    auto GetSpaceSize = [&](KAddressSpaceInfo::Type type) {
        return KAddressSpaceInfo::GetAddressSpaceSize(
            m_address_space_width, type, KSystemControl::Init::GetIntendedMemorySize());
    };
'@
Replace-Exact $pageTable $oldHelper.TrimEnd() $newHelper.TrimEnd() "page-table sizing from intended guest memory"

$svcPath = "src/core/hle/kernel/svc/svc_physical_memory.cpp"
$svcText = Get-Content $svcPath -Raw
if (-not $svcText.Contains('#include <algorithm>')) {
    $includeAnchor = '#include <cstdlib>'
    if (-not $svcText.Contains($includeAnchor)) { throw "Could not locate svc include insertion point" }
    $svcText = $svcText.Replace($includeAnchor, "#include <algorithm>`n#include <cstdlib>")
}
$oldSvcBody = @'
    // Validate size.
    R_UNLESS(Common::IsAligned(size, HeapSizeAlignment), ResultInvalidSize);
    R_UNLESS(size < MainMemorySizeMax, ResultInvalidSize);

    // Set the heap size.
    KProcessAddress address{};
    R_TRY(GetCurrentProcess(system.Kernel())
              .GetPageTable()
              .SetHeapSize(std::addressof(address), size));
'@
$newSvcBody = @'
    auto& process = GetCurrentProcess(system.Kernel());

    // Validate size against the actual process heap region. Switch 1 remains capped by the
    // historical 8 GiB MainMemorySizeMax; 12 GiB Switch 2 layouts expose a 12 GiB heap region.
    R_UNLESS(Common::IsAligned(size, HeapSizeAlignment), ResultInvalidSize);
    R_UNLESS(size < std::max(MainMemorySizeMax, process.GetPageTable().GetHeapRegionSize()),
             ResultInvalidSize);

    // Set the heap size.
    KProcessAddress address{};
    R_TRY(process.GetPageTable().SetHeapSize(std::addressof(address), size));
'@
if (-not $svcText.Contains($newSvcBody.Trim())) {
    if (-not $svcText.Contains($oldSvcBody.Trim())) {
        throw "Could not locate SetHeapSize validation/body anchor"
    }
    $svcText = $svcText.Replace($oldSvcBody.Trim(), $newSvcBody.Trim())
}
Set-Content -Path $svcPath -Value $svcText -Encoding utf8 -NoNewline
Write-Host "Applied: SetHeapSize validation against dynamic heap region"

# Hard validation of the semantics we rely on for the Bananza boot path.
$checks = @(
    @{ Path = $addressHeader; Needle = 'physical_memory_size = 0' },
    @{ Path = $addressCpp; Needle = 'size_t{32_GiB}' },
    @{ Path = $addressCpp; Needle = 'heap_size * 8' },
    @{ Path = $pageTable; Needle = 'KSystemControl::Init::GetIntendedMemorySize()' },
    @{ Path = $svcPath; Needle = 'process.GetPageTable().GetHeapRegionSize()' }
)
foreach ($check in $checks) {
    $text = Get-Content $check.Path -Raw
    if (-not $text.Contains($check.Needle)) {
        throw "NS2 memory layout validation failed: missing '$($check.Needle)' in $($check.Path)"
    }
}
Write-Host "NS2 dynamic memory-layout validation passed."

git diff -- src/core/hle/kernel/k_address_space_info.h `
            src/core/hle/kernel/k_address_space_info.cpp `
            src/core/hle/kernel/k_page_table_base.cpp `
            src/core/hle/kernel/svc/svc_physical_memory.cpp
