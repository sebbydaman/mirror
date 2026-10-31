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
if (-not $dma.Contains('const bool gpu_written = FlushGpuWrittenCommands')) {
    $old = @'
        // A resumed entry is read again: the words after the acquire may be new by now.
        // A safe read flushes the caches, which belong to the split's back thread while it runs
        // (the split only starts with unsafe reads; the settings can change mid-game).
        const bool use_safe = !VideoCommon::GpuSplit::Get().Active() &&
                              (Settings::IsDMALevelDefault() ? Settings::IsGPULevelHigh() : Settings::IsDMALevelSafe());
        if (use_safe) {
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
    $new = @'
        // A resumed entry is read again: the words after the acquire may be new by now.
        // Prefer the CPU-visible submission snapshot only for first-pass entries that have never
        // been GPU-written. GPU-written pages are drained/flushed and read from current memory.
        const bool gpu_written =
            FlushGpuWrittenCommands(dma_state.dma_get, header.size * sizeof(CommandHeader));
        const bool has_snapshot =
            command_resume_offset == 0 && !gpu_written &&
            dma_pushbuffer_subindex < command_list.submitted_offsets.size() &&
            command_list.submitted_offsets[dma_pushbuffer_subindex] + header.size <=
                command_list.submitted_words.size();
        const bool use_safe = !VideoCommon::GpuSplit::Get().Active() &&
                              (Settings::IsDMALevelDefault() ? Settings::IsGPULevelHigh() : Settings::IsDMALevelSafe());
        if (has_snapshot) {
            const std::span<const CommandHeader> commands{command_list.submitted_words};
            const auto entry = commands.subspan(command_list.submitted_offsets[dma_pushbuffer_subindex],
                                                header.size);
            RecordParsedEntry(header, entry);
            command_resume_offset += ProcessCommands(entry, 0);
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
    $oldText = $old.TrimEnd("`r", "`n")
    if (-not $dma.Contains($oldText)) {
        throw 'Could not locate current GpuGuestMemory command fetch block for PR28/PR52 preparation'
    }
    $dma = $dma.Replace($oldText, $new.TrimEnd("`r", "`n"))
}
Set-Content -Path $dmaPath -Value $dma -Encoding utf8 -NoNewline
Write-Host 'Prepared PR28/PR52 snapshot-vs-current command fetch for current DmaPusher.'
