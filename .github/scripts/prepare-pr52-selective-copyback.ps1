$ErrorActionPreference = 'Stop'

# Build167 already carries the later command-coherency design: GPU-written page history, per-entry
# submission snapshots, suspension generations, copied command-list reads, and a fallback drain /
# flush path. That is newer than the old PR28/PR52 QueueDownload adaptation below. Preserve it.
$nativeBuffer = 'src/video_core/buffer_cache/buffer_cache.h'
$nativeDmaHeader = 'src/video_core/dma_pusher.h'
$nativeDma = 'src/video_core/dma_pusher.cpp'
if ((Test-Path $nativeBuffer -PathType Leaf) -and
    (Test-Path $nativeDmaHeader -PathType Leaf) -and
    (Test-Path $nativeDma -PathType Leaf)) {
    $nativeBufferText = Get-Content $nativeBuffer -Raw
    $nativeDmaHeaderText = Get-Content $nativeDmaHeader -Raw
    $nativeDmaText = Get-Content $nativeDma -Raw
    $nativeComplete = $nativeBufferText.Contains('Tegra::Nx2MarkGpuWritten(device_addr, size);') -and
                      $nativeBufferText.Contains('Nx2NoteListWrite(buffer_id, device_addr, size);') -and
                      $nativeDmaHeaderText.Contains('bool IsGpuWrittenCommands(GPUVAddr address, size_t size);') -and
                      $nativeDmaHeaderText.Contains('bool ReadGpuWrittenCommands(GPUVAddr address, u32 count);') -and
                      $nativeDmaHeaderText.Contains('void FlushGpuWrittenCommands(GPUVAddr address, size_t size);') -and
                      $nativeDmaText.Contains('command_list.snapshot_suspensions') -and
                      $nativeDmaText.Contains('!IsGpuWrittenCommands(dma_state.dma_get,') -and
                      $nativeDmaText.Contains('ReadGpuWrittenCommands(dma_state.dma_get, static_cast<u32>(header.size))') -and
                      $nativeDmaText.Contains('FlushGpuWrittenCommands(dma_state.dma_get, size_t{header.size} * sizeof(u32));')
    if ($nativeComplete) {
        Write-Host '[PRESENT] build167 native PR28/PR52 command coherency and submission snapshots'
        return
    }
}

# PokeDinner 2.0 replaces the old inline async-download block in MarkWrittenBuffer with
# QueueDownload(device_addr, size). PR52's command-page history should layer on top of that
# selective copyback policy, not replace it. This preparer also adapts PR28/PR52 to the current
# DmaPusher shape and reuses PokeDinner's existing GPU-written-command coherency helper.

# -----------------------------------------------------------------------------
# Buffer-cache write history on top of selective QueueDownload().
# -----------------------------------------------------------------------------
$path = 'src/video_core/buffer_cache/buffer_cache.h'
$text = (Get-Content $path -Raw).Replace("`r`n", "`n")
$marker = 'Tegra::Nx2MarkGpuWritten(device_addr, size);'
if (-not $text.Contains($marker)) {
    $functionMarker = 'void BufferCache<P>::MarkWrittenBuffer('
    $start = $text.IndexOf($functionMarker)
    if ($start -lt 0) { throw 'Could not locate MarkWrittenBuffer for PR52 selective-copyback preparation' }
    $next = $text.IndexOf("`ntemplate <class P>", $start + $functionMarker.Length)
    if ($next -lt 0) { throw 'Could not locate end of MarkWrittenBuffer for PR52 preparation' }
    $body = $text.Substring($start, $next - $start)
    $queue = '    QueueDownload(device_addr, size);'
    if (-not $body.Contains($queue)) {
        throw 'PokeDinner selective QueueDownload call missing from MarkWrittenBuffer'
    }
    $replacement = @'
    QueueDownload(device_addr, size);
    if (Tegra::g_nx2_ampere.load(std::memory_order_relaxed)) {
        Tegra::Nx2MarkGpuWritten(device_addr, size);
    }
'@
    $body = $body.Replace($queue, $replacement.TrimEnd("`r", "`n"))
    $text = $text.Substring(0, $start) + $body + $text.Substring($next)
    Set-Content -Path $path -Value $text -Encoding utf8 -NoNewline
    Write-Host 'Prepared PR52 GPU-written page tracking on top of PokeDinner selective copyback.'
} else {
    Write-Host 'PR52 shader/copy write marker already present.'
}

# -----------------------------------------------------------------------------
# Reuse PokeDinner 2.0's FlushGpuWrittenCommands instead of defining a second helper.
# PR28 needs one extra fact from it: whether the command page has GPU-write history. Return true
# whenever such a page is found, even if it has already been copied back and is currently clean;
# an older CPU submission snapshot must never override newer GPU-generated command words.
# -----------------------------------------------------------------------------
$dmaHeaderPath = 'src/video_core/dma_pusher.h'
$dmaHeader = (Get-Content $dmaHeaderPath -Raw).Replace("`r`n", "`n")
$boolDecl = '    [[nodiscard]] bool FlushGpuWrittenCommands(GPUVAddr address, size_t size);'
$declName = 'FlushGpuWrittenCommands('
$declAt = $dmaHeader.IndexOf($declName)
if ($declAt -ge 0) {
    $lineStart = $dmaHeader.LastIndexOf("`n", $declAt)
    $lineStart = if ($lineStart -lt 0) { 0 } else { $lineStart + 1 }
    $lineEnd = $dmaHeader.IndexOf("`n", $declAt)
    if ($lineEnd -lt 0) { $lineEnd = $dmaHeader.Length }
    $declLine = $dmaHeader.Substring($lineStart, $lineEnd - $lineStart)
    if (-not $declLine.Contains(';')) {
        throw "Unexpected FlushGpuWrittenCommands header occurrence: $declLine"
    }
    if (-not $declLine.Contains('bool FlushGpuWrittenCommands')) {
        $dmaHeader = $dmaHeader.Substring(0, $lineStart) + $boolDecl + $dmaHeader.Substring($lineEnd)
        Write-Host 'Promoted existing PokeDinner command coherency declaration to bool.'
    } else {
        Write-Host 'PokeDinner command coherency declaration already reports GPU-write history.'
    }
} else {
    # Some intermediate PokeDinner/Eglantine shapes carry the cpp helper but not its declaration.
    # Insert it next to the other public DmaPusher diagnostics rather than failing an exact anchor.
    $recordAt = $dmaHeader.IndexOf('void RecordParsedEntry(')
    if ($recordAt -lt 0) { throw 'Could not locate RecordParsedEntry declaration for PR52 helper insertion' }
    $recordEnd = $dmaHeader.IndexOf(';', $recordAt)
    if ($recordEnd -lt 0) { throw 'Could not locate end of RecordParsedEntry declaration' }
    $insertAt = $recordEnd + 1
    $dmaHeader = $dmaHeader.Substring(0, $insertAt) + "`n" + $boolDecl + $dmaHeader.Substring($insertAt)
    Write-Host 'Inserted missing PokeDinner command coherency declaration beside RecordParsedEntry.'
}
Set-Content -Path $dmaHeaderPath -Value $dmaHeader -Encoding utf8 -NoNewline

$dmaPath = 'src/video_core/dma_pusher.cpp'
$dma = (Get-Content $dmaPath -Raw).Replace("`r`n", "`n")
if ($dma.Contains('void DmaPusher::FlushGpuWrittenCommands(')) {
    $helperStart = $dma.IndexOf('void DmaPusher::FlushGpuWrittenCommands(')
    $helperEnd = $dma.IndexOf("`nvoid DmaPusher::ReportUnboundSubchannel()", $helperStart)
    if ($helperEnd -lt 0) { throw 'Could not locate end of PokeDinner FlushGpuWrittenCommands helper' }
    $helper = @'
bool DmaPusher::FlushGpuWrittenCommands(GPUVAddr address, size_t size) {
    // PokeDinner coherency path plus PR28 snapshot arbitration. A page-history hit means current
    // command memory wins over an older submission snapshot, regardless of current dirty state.
    if (!Tegra::g_nx2_ampere.load(std::memory_order_relaxed) || size == 0) {
        return false;
    }
    bool written = false;
    for (GPUVAddr page = address & ~GPUVAddr{0xfff}; page < address + size; page += 0x1000) {
        if (const auto device = memory_manager.GpuToCpuAddress(page);
            device && Tegra::Nx2IsGpuWritten(*device)) {
            written = true;
            break;
        }
    }
    if (!written) {
        return false;
    }
    // The caches belong to the split's back thread. Drain a pending producer before checking
    // whether the current GPU-written command bytes still need to be copied to guest memory.
    VideoCommon::GpuSplit::Get().Drain();
    if (memory_manager.IsMemoryDirty(address, size, VideoCommon::CacheType::BufferCache)) {
        memory_manager.FlushRegion(address, size, VideoCommon::CacheType::BufferCache);
    }
    return true;
}
'@
    $dma = $dma.Substring(0, $helperStart) + $helper.TrimEnd("`r", "`n") + "`n" + $dma.Substring($helperEnd + 1)
} elseif (-not $dma.Contains('bool DmaPusher::FlushGpuWrittenCommands(')) {
    throw 'Could not locate PokeDinner FlushGpuWrittenCommands implementation'
}

# Current Step() intentionally re-reads a resumed entry after a semaphore acquire. Preserve that:
# use a submission snapshot only on the first pass and only for pages that have never been marked
# GPU-written. GPU-written or resumed entries continue through the existing safe/unsafe wrappers.
# Locate the read policy by function boundaries instead of matching comments/formatting exactly.
if (-not $dma.Contains('const bool gpu_written = FlushGpuWrittenCommands')) {
    $stepStart = $dma.IndexOf('bool DmaPusher::Step() {')
    if ($stepStart -lt 0) { throw 'Could not locate DmaPusher::Step for PR28/PR52 preparation' }

    $readStart = $dma.IndexOf('        const bool use_safe =', $stepStart)
    if ($readStart -lt 0) {
        throw 'Could not locate DmaPusher use_safe command-read policy for PR28/PR52 preparation'
    }
    $readEnd = $dma.IndexOf('        if (puller.HasPendingAcquire()) {', $readStart)
    if ($readEnd -lt 0) {
        throw 'Could not locate end of DmaPusher command-read policy for PR28/PR52 preparation'
    }

    $currentRead = $dma.Substring($readStart, $readEnd - $readStart)
    if (-not $currentRead.Contains('GpuGuestMemory<Tegra::CommandHeader') -or
        -not $currentRead.Contains('GuestMemoryFlags::SafeRead') -or
        -not $currentRead.Contains('GuestMemoryFlags::UnsafeRead')) {
        throw 'Unexpected DmaPusher command-read policy: safe/unsafe GpuGuestMemory paths are missing'
    }

    $newRead = @'
        const bool gpu_written = FlushGpuWrittenCommands(
            dma_state.dma_get, size_t{header.size} * sizeof(CommandHeader));
        const bool has_snapshot =
            command_resume_offset == 0 && !gpu_written &&
            dma_pushbuffer_subindex < command_list.submitted_offsets.size() &&
            command_list.submitted_offsets[dma_pushbuffer_subindex] + header.size <=
                command_list.submitted_words.size();
        const bool use_safe = !VideoCommon::GpuSplit::Get().Active() &&
                              (Settings::IsDMALevelDefault() ? Settings::IsGPULevelHigh() : Settings::IsDMALevelSafe());
        if (has_snapshot) {
            const std::span<const CommandHeader> submitted{command_list.submitted_words};
            const auto commands = submitted.subspan(
                command_list.submitted_offsets[dma_pushbuffer_subindex], header.size);
            RecordParsedEntry(header, commands);
            command_resume_offset += ProcessCommands(commands, 0);
        } else if (use_safe) {
            Tegra::Memory::GpuGuestMemory<Tegra::CommandHeader, Tegra::Memory::GuestMemoryFlags::SafeRead>headers(memory_manager, dma_state.dma_get, header.size, &command_headers);
            const std::span<const CommandHeader> commands{headers.data(), headers.size()};
            RecordParsedEntry(header, commands);
            command_resume_offset +=
                ProcessCommands(commands.subspan(command_resume_offset), command_resume_offset);
        } else {
            Tegra::Memory::GpuGuestMemory<Tegra::CommandHeader, Tegra::Memory::GuestMemoryFlags::UnsafeRead>headers(memory_manager, dma_state.dma_get, header.size, &command_headers);
            const std::span<const CommandHeader> commands{headers.data(), headers.size()};
            RecordParsedEntry(header, commands);
            command_resume_offset +=
                ProcessCommands(commands.subspan(command_resume_offset), command_resume_offset);
        }
'@
    $dma = $dma.Substring(0, $readStart) + $newRead.TrimEnd("`r", "`n") + "`n" + $dma.Substring($readEnd)
}

# Keep this preparation strict enough to catch accidental partial application before the legacy
# compatibility script runs. The header snapshot fields themselves are still added by that script.
foreach ($needle in @(
    'bool DmaPusher::FlushGpuWrittenCommands(',
    'return true;',
    'const bool gpu_written = FlushGpuWrittenCommands',
    'command_list.submitted_offsets',
    'command_list.submitted_words',
    'GuestMemoryFlags::SafeRead',
    'GuestMemoryFlags::UnsafeRead'
)) {
    if (-not $dma.Contains($needle)) { throw "PR28/PR52 preparation regression: missing $needle" }
}
Set-Content -Path $dmaPath -Value $dma -Encoding utf8 -NoNewline
Write-Host 'Prepared PR28/PR52 snapshot-vs-current command fetch using PokeDinner command coherency.'
