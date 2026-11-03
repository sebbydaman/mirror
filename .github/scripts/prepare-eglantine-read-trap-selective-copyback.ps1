$ErrorActionPreference = 'Stop'

# Build167 already contains the complete read-trap design that this preparation script used to
# synthesize over the older PokeDinner QueueDownload generation: device-memory read traps,
# BufferCache::FlushesOnCpuRead, read-trap lifetime cleanup and Vulkan GetFlushArea integration.
# Keep that newer implementation intact instead of looking for the removed QueueDownload path.
$nativeReadTrapHeader = 'src/core/device_memory_manager.h'
$nativeReadTrapBase = 'src/video_core/buffer_cache/buffer_cache_base.h'
$nativeReadTrapCache = 'src/video_core/buffer_cache/buffer_cache.h'
$nativeReadTrapVk = 'src/video_core/renderer_vulkan/vk_rasterizer.cpp'
if ((Test-Path $nativeReadTrapHeader -PathType Leaf) -and
    (Test-Path $nativeReadTrapBase -PathType Leaf) -and
    (Test-Path $nativeReadTrapCache -PathType Leaf) -and
    (Test-Path $nativeReadTrapVk -PathType Leaf)) {
    $nativeHeaderText = Get-Content $nativeReadTrapHeader -Raw
    $nativeBaseText = Get-Content $nativeReadTrapBase -Raw
    $nativeCacheText = Get-Content $nativeReadTrapCache -Raw
    $nativeVkText = Get-Content $nativeReadTrapVk -Raw
    $nativeComplete = $nativeHeaderText.Contains('void ArmReadTraps(DAddr addr, size_t size);') -and
                      $nativeBaseText.Contains('bool FlushesOnCpuRead() const') -and
                      $nativeCacheText.Contains('read_trapped_ranges.Subtract(slot_buffers[buffer_id].CpuAddr()') -and
                      $nativeCacheText.Contains('ArmReadTraps(new_base_address, size);') -and
                      $nativeVkText.Contains('buffer_cache.FlushesOnCpuRead()')
    if ($nativeComplete) {
        Write-Host '[PRESENT] build167 native first-read trap/selective GPU copyback stack'
        return
    }
}

# Late Eglantine read traps must layer on top of PokeDinner 2.0's selective QueueDownload path.
# Do this before the larger read-trap cherry-pick/merge so the later script can preserve the
# current PokeDinner/PR52 shape instead of relying on exact historical text blocks.
$path = 'src/video_core/buffer_cache/buffer_cache_base.h'
$text = (Get-Content $path -Raw).Replace("`r`n", "`n")

if (-not ($text.Contains('covered < size') -and $text.Contains('ArmReadTraps(addr, size);'))) {
    $functionMarker = '    void QueueDownload(DAddr addr, u64 size) {'
    $start = $text.IndexOf($functionMarker)
    if ($start -lt 0) {
        throw 'Could not locate BufferCache::QueueDownload for read-trap preparation'
    }
    $end = $text.IndexOf("`n    // Async Buffers", $start)
    if ($end -lt 0) {
        throw 'Could not locate end of BufferCache::QueueDownload for read-trap preparation'
    }
    $body = $text.Substring($start, $end - $start)

    # Keep the existing AsyncBufferDownloads() fast path untouched. Replace only the selective
    # cpu_read_ranges callback. Regex is intentionally whitespace-tolerant so PokeDinner/PR52
    # formatting or comments can change without breaking the integration gate.
    # PowerShell single-quoted strings preserve backslashes, so regex escapes are written once.
    $pattern = 'cpu_read_ranges\.ForEachInRange\(addr\s*,\s*size\s*,\s*\[this\]\s*\(DAddr\s+start\s*,\s*DAddr\s+end\)\s*\{\s*uncommitted_gpu_modified_ranges\.Add\(start\s*,\s*end\s*-\s*start\);\s*\}\);'
    $pattern = $pattern.Replace('\\', '\')
    $match = [regex]::Match($body, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $match.Success) {
        throw 'Could not locate selective cpu_read_ranges callback inside QueueDownload'
    }

    $replacement = @'
u64 covered = 0;
        cpu_read_ranges.ForEachInRange(addr, size, [this, &covered](DAddr start, DAddr end) {
            uncommitted_gpu_modified_ranges.Add(start, end - start);
            covered += end - start;
        });
        // A guest fastmem read can bypass RasterizerVulkan::GetFlushArea. Trap only pages that
        // have not yet been observed as CPU-read; after the first trap, selective fence copyback
        // keeps those ranges current without restoring blanket GPU-write downloads.
        if (covered < size) {
            ArmReadTraps(addr, size);
        }
'@
    $replacement = '        ' + $replacement.TrimEnd("`r", "`n")
    $body = $body.Substring(0, $match.Index) + $replacement + $body.Substring($match.Index + $match.Length)
    $text = $text.Substring(0, $start) + $body + $text.Substring($end)

    if (-not $body.Contains('covered < size') -or -not $body.Contains('ArmReadTraps(addr, size);')) {
        throw 'Read-trap QueueDownload preparation did not produce expected markers'
    }
    Set-Content -Path $path -Value $text -Encoding utf8 -NoNewline
    Write-Host 'Prepared PokeDinner selective QueueDownload for Eglantine first-read traps.'
} else {
    Write-Host 'Selective QueueDownload is already prepared for Eglantine read traps.'
}

# The late-Eglantine cherry-pick conflicts with the newer PokeDinner buffer cache, so the larger
# merge restores this file to its checkpoint before adding read-trap lifetime cleanup. Seed the
# cleanup structurally here: anchoring to DeleteBuffer itself survives runtime-hook formatting,
# optional callbacks, and other donor changes. The member is declared later in the same integration
# pass before anything is compiled.
$bufferCachePath = 'src/video_core/buffer_cache/buffer_cache.h'
$bufferText = (Get-Content $bufferCachePath -Raw).Replace("`r`n", "`n")
$cleanupMarker = 'read_trapped_ranges.Subtract(slot_buffers[buffer_id].CpuAddr()'
if (-not $bufferText.Contains($cleanupMarker)) {
    $deleteMarker = 'void BufferCache<P>::DeleteBuffer(BufferId buffer_id, bool do_not_mark) {'
    $deleteStart = $bufferText.IndexOf($deleteMarker)
    if ($deleteStart -lt 0) {
        throw 'Could not locate BufferCache::DeleteBuffer for read-trap cleanup preparation'
    }
    $insertAt = $deleteStart + $deleteMarker.Length
    $cleanup = "`n    read_trapped_ranges.Subtract(slot_buffers[buffer_id].CpuAddr(),`n" +
               '                                 slot_buffers[buffer_id].SizeBytes());'
    $bufferText = $bufferText.Insert($insertAt, $cleanup)
    if (-not $bufferText.Contains($cleanupMarker)) {
        throw 'Read-trap DeleteBuffer cleanup preparation did not produce expected marker'
    }
    Set-Content -Path $bufferCachePath -Value $bufferText -Encoding utf8 -NoNewline
    Write-Host 'Prepared BufferCache::DeleteBuffer read-trap lifetime cleanup with structural anchor.'
} else {
    Write-Host 'BufferCache::DeleteBuffer read-trap cleanup is already prepared.'
}

# Seed the Vulkan CPU-read flush by function structure rather than by the donor's exact historical
# texture block. The read-trap merge restores vk_rasterizer.cpp to this checkpoint, so this survives
# that restore; FlushesOnCpuRead() is declared later in the same merge before compilation.
$vkRasterizerPath = 'src/video_core/renderer_vulkan/vk_rasterizer.cpp'
$vkText = (Get-Content $vkRasterizerPath -Raw).Replace("`r`n", "`n")
if (-not $vkText.Contains('buffer_cache.FlushesOnCpuRead()')) {
    $flushFunction = 'VideoCore::RasterizerDownloadArea RasterizerVulkan::GetFlushArea(DAddr addr, u64 size) {'
    $flushStart = $vkText.IndexOf($flushFunction)
    if ($flushStart -lt 0) {
        throw 'Could not locate RasterizerVulkan::GetFlushArea for read-trap preparation'
    }
    $newAreaMarker = '    VideoCore::RasterizerDownloadArea new_area{'
    $insertAt = $vkText.IndexOf($newAreaMarker, $flushStart)
    if ($insertAt -lt 0) {
        throw 'Could not locate post-texture insertion point inside RasterizerVulkan::GetFlushArea'
    }
    $bufferFlush = @'
    if (buffer_cache.FlushesOnCpuRead()) {
        std::scoped_lock lock{buffer_cache.mutex};
        auto area = buffer_cache.GetFlushArea(addr, size);
        if (area) {
            return *area;
        }
    }
'@
    $vkText = $vkText.Insert($insertAt, $bufferFlush.TrimEnd("`r", "`n") + "`n")
    if (-not $vkText.Contains('buffer_cache.FlushesOnCpuRead()')) {
        throw 'Vulkan read-trap flush preparation did not produce expected marker'
    }
    Set-Content -Path $vkRasterizerPath -Value $vkText -Encoding utf8 -NoNewline
    Write-Host 'Prepared RasterizerVulkan::GetFlushArea buffer readback with structural anchor.'
} else {
    Write-Host 'RasterizerVulkan CPU-read buffer flush is already prepared.'
}
