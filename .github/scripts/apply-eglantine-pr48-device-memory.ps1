$ErrorActionPreference = "Stop"

# Port Eglantine PR #48: reset/cut device-page continuity metadata when mappings
# are replaced or removed. This prevents WalkBlock from carrying stale physical
# continuity across remapped/unmapped pages and reading the wrong host memory.
$incPath = "src/core/device_memory_manager.inc"
$hdrPath = "src/core/device_memory_manager.h"

$inc = Get-Content $incPath -Raw
$hdr = Get-Content $hdrPath -Raw

if (-not $hdr.Contains('void CutContinuityAt(size_t page);')) {
    $needle = '    void InnerGatherDeviceAddresses(Common::ScratchBuffer<u32>& buffer, PAddr address);'
    if (-not $hdr.Contains($needle)) { throw "PR48: device_memory_manager.h insertion point not found" }
    $hdr = $hdr.Replace($needle, "    void CutContinuityAt(size_t page);`r`n`r`n$needle")
}

if (-not $inc.Contains('CutContinuityAt(start_page_d);')) {
    $mapNeedle = '    tracked_entries.CommitRegion(start_page_d, start_page_d + num_pages);'
    $mapIndex = $inc.IndexOf($mapNeedle)
    if ($mapIndex -lt 0) { throw "PR48: Map CommitRegion marker not found" }
    $mapInsert = $mapNeedle + "`r`n    CutContinuityAt(start_page_d);"
    $inc = $inc.Remove($mapIndex, $mapNeedle.Length).Insert($mapIndex, $mapInsert)

    $loopNeedle = '        const VAddr new_vaddress = virtual_address + i * Memory::YUZU_PAGESIZE;'
    $loopIndex = $inc.IndexOf($loopNeedle, $mapIndex)
    if ($loopIndex -lt 0) { throw "PR48: Map loop marker not found" }
    $loopInsert = $loopNeedle + "`r`n        // A stale run from an earlier mapping must not survive this remap.`r`n        tracked_entries.GetUnchecked(start_page_d + i).continuity_tracker = 0;"
    $inc = $inc.Remove($loopIndex, $loopNeedle.Length).Insert($loopIndex, $loopInsert)

    $unmapMarker = 'void DeviceMemoryManager<Traits>::Unmap(DAddr address, size_t size) {'
    $unmapIndex = $inc.IndexOf($unmapMarker)
    if ($unmapIndex -lt 0) { throw "PR48: Unmap function not found" }
    $unmapCommit = $inc.IndexOf($mapNeedle, $unmapIndex)
    if ($unmapCommit -lt 0) { throw "PR48: Unmap CommitRegion marker not found" }
    $inc = $inc.Remove($unmapCommit, $mapNeedle.Length).Insert($unmapCommit, $mapNeedle + "`r`n    CutContinuityAt(start_page_d);")

    $unmapZero = '        entry.cpu_backing_address = 0;'
    $unmapZeroIndex = $inc.IndexOf($unmapZero, $unmapIndex)
    if ($unmapZeroIndex -lt 0) { throw "PR48: Unmap entry reset marker not found" }
    $inc = $inc.Remove($unmapZeroIndex, $unmapZero.Length).Insert($unmapZeroIndex, $unmapZero + "`r`n        entry.continuity_tracker = 0;")
}

if (-not $inc.Contains('void DeviceMemoryManager<Traits>::CutContinuityAt(size_t page)')) {
    # Anchor on the function token rather than newline spelling so this works
    # whether Git checks the source out as LF or CRLF on Windows runners.
    $functionNeedle = 'void DeviceMemoryManager<Traits>::TrackContinuityImpl'
    $functionIndex = $inc.IndexOf($functionNeedle)
    if ($functionIndex -lt 0) { throw "PR48: TrackContinuityImpl function not found" }
    $trackIndex = $inc.LastIndexOf('template <typename Traits>', $functionIndex)
    if ($trackIndex -lt 0) { throw "PR48: TrackContinuityImpl template anchor not found" }
    $block = @'
template <typename Traits>
void DeviceMemoryManager<Traits>::CutContinuityAt(size_t page) {
    // Runs counted from pages before `page` must end before a range that is
    // being remapped or unmapped. TrackContinuityImpl stores a countdown.
    for (size_t index = page; index-- > 0;) {
        const size_t last_count = page - 1 - index;
        if (tracked_entries[index].continuity_tracker <= last_count) {
            break;
        }
        tracked_entries.GetUnchecked(index).continuity_tracker = static_cast<u32>(last_count);
    }
}

'@
    $inc = $inc.Insert($trackIndex, $block)
}

Set-Content -Path $hdrPath -Value $hdr -Encoding utf8 -NoNewline
Set-Content -Path $incPath -Value $inc -Encoding utf8 -NoNewline

# Regression guards: the effective source must contain every semantic part of PR #48.
$hdrCheck = Get-Content $hdrPath -Raw
$incCheck = Get-Content $incPath -Raw
if (-not $hdrCheck.Contains('void CutContinuityAt(size_t page);')) { throw "PR48 regression: declaration missing" }
if (($incCheck.Split('CutContinuityAt(start_page_d);').Count - 1) -lt 2) { throw "PR48 regression: Map/Unmap continuity cuts missing" }
if (-not $incCheck.Contains('entry.continuity_tracker = 0;')) { throw "PR48 regression: Unmap continuity reset missing" }
if (-not $incCheck.Contains('void DeviceMemoryManager<Traits>::CutContinuityAt(size_t page)')) { throw "PR48 regression: helper implementation missing" }

Write-Host "Applied generalized device-memory continuity fix from Eglantine PR #48."
git diff -- $hdrPath $incPath
