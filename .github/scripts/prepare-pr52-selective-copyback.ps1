$ErrorActionPreference = 'Stop'

# PokeDinner 2.0 replaces the old inline async-download block in MarkWrittenBuffer with
# QueueDownload(device_addr, size). PR52's command-page history should layer on top of that
# selective copyback policy, not replace it. This preparer also adapts PR28/PR52 to the current
# DmaPusher shape, where Push() is inline in the header and Step() reads through GpuGuestMemory.

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
# DmaPusher command coherency. Current Eglantine/PokeDinner has Push() inline in dma_pusher.h,
# so place the helper before DispatchCalls() instead of looking for a non-existent cpp Push().
# A page that has ever been GPU-written always prefers current command memory over the submission
# snapshot; if it is still dirty, drain the split and copy it back first.
# -----------------------------------------------------------------------------
$dmaPath = 'src/video_core/dma_pusher.cpp'
$dma = (Get-Content $dmaPath -Raw).Replace("`r`n", "`n")
if (-not $dma.Contains('bool DmaPusher::FlushGpuWrittenCommands(')) {
    $anchor = 'void DmaPusher::DispatchCalls() {'
    $at = $dma.IndexOf($anchor)
    if ($at -lt 0) { throw 'Could not locate DispatchCalls for PR52 command coherency helper' }
    $helper = @'
bool DmaPusher::FlushGpuWrittenCommands(GPUVAddr address, size_t size) {
    if (!g_nx2_ampere.load(std::memory_order_relaxed) || size == 0) {
        return false;
    }
    bool potentially_written = false;
    for (GPUVAddr page = address & ~GPUVAddr{0xfff}; page < address + size; page += 0x1000) {
        if (const auto device = memory_manager.GpuToCpuAddress(page);
            device && Nx2IsGpuWritten(*device)) {
            potentially_written = true;
            break;
        }
    }
    if (!potentially_written) {
        return false;
    }
    VideoCommon::GpuSplit::Get().Drain();
    if (memory_manager.IsMemoryDirty(address, size, VideoCommon::CacheType::BufferCache)) {
        memory_manager.FlushRegion(address, size, VideoCommon::CacheType::BufferCache);
    }
    return true;
}

'@
    $dma = $dma.Substring(0, $at) + $helper.TrimEnd("`r", "`n") + "`n`n" + $dma.Substring($at)
}

# Current Step() intentionally re-reads a resumed entry after a semaphore acquire. Preserve that:
# use a submission snapshot only on the first pass and only for pages that have never been marked
# GPU-written. GPU-written or resumed entries continue through the existing safe/unsafe wrappers.
# Locate the read policy by function boundaries instead of matching comments/formatting exactly;
# PokeDinner has changed this block several times (PBFLUSH, split-thread comments, extra flushes).
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
    'const bool gpu_written = FlushGpuWrittenCommands',
    'command_list.submitted_offsets',
    'command_list.submitted_words',
    'GuestMemoryFlags::SafeRead',
    'GuestMemoryFlags::UnsafeRead'
)) {
    if (-not $dma.Contains($needle)) { throw "PR28/PR52 preparation regression: missing $needle" }
}
Set-Content -Path $dmaPath -Value $dma -Encoding utf8 -NoNewline
Write-Host 'Prepared PR28/PR52 snapshot-vs-current command fetch for current DmaPusher.'
