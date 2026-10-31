$ErrorActionPreference = 'Stop'

# Post-#71 generalized compatibility batch. Keep this self-contained and guarded so one long CI
# build can validate several proven fixes together without weakening unknown/task-mesh handling.

function Read-Lf([string]$Path) {
    if (-not (Test-Path $Path)) { throw "Missing required source file: $Path" }
    return (Get-Content $Path -Raw).Replace("`r`n", "`n")
}
function Write-Utf8([string]$Path, [string]$Text) {
    Set-Content -Path $Path -Value $Text -Encoding utf8 -NoNewline
}
function Replace-Once([string]$Text, [string]$Old, [string]$New, [string]$Label) {
    $at = $Text.IndexOf($Old)
    if ($at -lt 0) { throw "Could not locate $Label" }
    if ($Text.IndexOf($Old, $at + $Old.Length) -ge 0) { throw "Ambiguous anchor for $Label" }
    return $Text.Substring(0, $at) + $New + $Text.Substring($at + $Old.Length)
}
function Insert-Before([string]$Text, [string]$Anchor, [string]$Block, [string]$Marker, [string]$Label) {
    if ($Text.Contains($Marker)) { return $Text }
    $at = $Text.IndexOf($Anchor)
    if ($at -lt 0) { throw "Could not locate $Label insertion point" }
    return $Text.Substring(0, $at) + $Block.TrimEnd("`n") + "`n" + $Text.Substring($at)
}
function Insert-After([string]$Text, [string]$Anchor, [string]$Block, [string]$Marker, [string]$Label) {
    if ($Text.Contains($Marker)) { return $Text }
    $at = $Text.IndexOf($Anchor)
    if ($at -lt 0) { throw "Could not locate $Label insertion point" }
    $at += $Anchor.Length
    return $Text.Substring(0, $at) + "`n" + $Block.TrimEnd("`n") + $Text.Substring($at)
}

# ----- PR #51: deferred instancing must be committed before unrelated state mutates. -----
$drawPath = 'src/video_core/engines/draw_manager.cpp'
$draw = Read-Lf $drawPath
$drawBlock = @'
bool Maxwell3D::DrawManager::IsInstanceLoopMethod(u32 method) noexcept {
    switch (method) {
    case MAXWELL3D_REG_INDEX(draw.begin):
    case MAXWELL3D_REG_INDEX(draw.end):
    case MAXWELL3D_REG_INDEX(vertex_buffer.first):
    case MAXWELL3D_REG_INDEX(vertex_buffer.count):
    case MAXWELL3D_REG_INDEX(index_buffer.first):
    case MAXWELL3D_REG_INDEX(index_buffer.count):
    case MAXWELL3D_REG_INDEX(index_buffer32_first):
    case MAXWELL3D_REG_INDEX(index_buffer16_first):
    case MAXWELL3D_REG_INDEX(index_buffer8_first):
    case MAXWELL3D_REG_INDEX(index_buffer32_subsequent):
    case MAXWELL3D_REG_INDEX(index_buffer16_subsequent):
    case MAXWELL3D_REG_INDEX(index_buffer8_subsequent):
    case MAXWELL3D_REG_INDEX(draw_inline_index):
    case MAXWELL3D_REG_INDEX(inline_index_2x16.count):
    case MAXWELL3D_REG_INDEX(inline_index_2x16.even):
    case MAXWELL3D_REG_INDEX(inline_index_4x8.count):
    case MAXWELL3D_REG_INDEX(inline_index_4x8.index0):
    case MAXWELL3D_REG_INDEX(vertex_array_instance_first):
    case MAXWELL3D_REG_INDEX(vertex_array_instance_subsequent):
        return true;
    default:
        return false;
    }
}

'@
$draw = Insert-Before $draw 'void Maxwell3D::DrawManager::DrawArray(' $drawBlock 'bool Maxwell3D::DrawManager::IsInstanceLoopMethod' 'PR51 classifier'
Write-Utf8 $drawPath $draw

$maxwellHeaderPath = 'src/video_core/engines/maxwell_3d.h'
$maxwellHeader = Read-Lf $maxwellHeaderPath
if (-not $maxwellHeader.Contains('bool HasDeferredDraw() const noexcept')) {
    $old = '        void DrawDeferred(Maxwell3D& maxwell3d);'
    $new = @'
        void DrawDeferred(Maxwell3D& maxwell3d);
        [[nodiscard]] bool HasDeferredDraw() const noexcept {
            return draw_state.draw_mode == DrawMode::Instance && draw_state.instance_count != 0;
        }
        [[nodiscard]] static bool IsInstanceLoopMethod(u32 method) noexcept;
'@
    $new = $new.TrimEnd("`n")
    $maxwellHeader = Replace-Once $maxwellHeader $old $new 'PR51 DrawManager declarations'
}
Write-Utf8 $maxwellHeaderPath $maxwellHeader

$maxwellPath = 'src/video_core/engines/maxwell_3d.cpp'
$maxwell = Read-Lf $maxwellPath
if (-not $maxwell.Contains('draw_manager.HasDeferredDraw() && !DrawManager::IsInstanceLoopMethod(method)')) {
    $oldDirty = @'
void Maxwell3D::ProcessDirtyRegisters(u32 method, u32 argument) {
    regs.reg_array[method] = argument;
'@
    $newDirty = @'
void Maxwell3D::ProcessDirtyRegisters(u32 method, u32 argument) {
    if (draw_manager.HasDeferredDraw() && !DrawManager::IsInstanceLoopMethod(method)) [[unlikely]] {
        draw_manager.DrawDeferred(*this);
    }
    regs.reg_array[method] = argument;
'@
    $maxwell = Replace-Once $maxwell $oldDirty $newDirty 'PR51 ProcessDirtyRegisters guard'

    $oldMulti = @'
    if (method >= MacroRegistersStart) {
        ProcessMacro(system, method, base_start, amount, amount == methods_pending);
        return;
    }
    switch (method) {
'@
    $newMulti = @'
    if (method >= MacroRegistersStart) {
        ProcessMacro(system, method, base_start, amount, amount == methods_pending);
        return;
    }
    if (draw_manager.HasDeferredDraw() && !DrawManager::IsInstanceLoopMethod(method)) [[unlikely]] {
        draw_manager.DrawDeferred(*this);
    }
    switch (method) {
'@
    $maxwell = Replace-Once $maxwell $oldMulti $newMulti 'PR51 CallMultiMethod guard'
}
Write-Utf8 $maxwellPath $maxwell
Write-Host 'Applied PR #51 deferred-instancing state correctness.'

# ----- Combined PR #52 + #28: GPU-generated commands plus submission snapshots. -----
$nx2Path = 'src/video_core/nx2.h'
$nx2 = Read-Lf $nx2Path
if (-not $nx2.Contains('Nx2WrittenPageBits')) {
    $gpuWritten = @'

// Device pages ever written through the GPU buffer cache. The bit is a conservative hint; the
// DMA pusher drains queued producers and checks current dirtiness before bypassing a CPU snapshot.
inline constexpr u64 Nx2WrittenPageBits = 12;
inline std::array<std::atomic<u64>, (u64{1} << (36 - Nx2WrittenPageBits)) / 64>
    g_nx2_gpu_written_pages{};

inline void Nx2MarkGpuWritten(u64 device_address, u64 size) {
    if (size == 0) return;
    const u64 last = std::min<u64>((device_address + size - 1) >> Nx2WrittenPageBits,
                                   g_nx2_gpu_written_pages.size() * 64 - 1);
    for (u64 page = device_address >> Nx2WrittenPageBits; page <= last; ++page) {
        auto& word = g_nx2_gpu_written_pages[page / 64];
        const u64 bit = u64{1} << (page % 64);
        if ((word.load(std::memory_order_relaxed) & bit) == 0) {
            word.fetch_or(bit, std::memory_order_relaxed);
        }
    }
}
inline void Nx2ClearGpuWrittenPages() {
    for (auto& word : g_nx2_gpu_written_pages) word.store(0, std::memory_order_relaxed);
}
[[nodiscard]] inline bool Nx2IsGpuWritten(u64 device_address) {
    const u64 page = device_address >> Nx2WrittenPageBits;
    if (page >= g_nx2_gpu_written_pages.size() * 64) return false;
    return (g_nx2_gpu_written_pages[page / 64].load(std::memory_order_relaxed) >> (page % 64)) & 1;
}
'@
    $nx2 = Insert-After $nx2 'inline std::atomic<bool> g_nx2_ampere{false};' $gpuWritten 'Nx2WrittenPageBits' 'GPU-written page tracker'
}
Write-Utf8 $nx2Path $nx2

$nvdrvPath = 'src/core/hle/service/nvdrv/nvdrv.cpp'
$nvdrv = Read-Lf $nvdrvPath
if (-not $nvdrv.Contains('Tegra::Nx2ClearGpuWrittenPages();')) {
    $nvdrv = Replace-Once $nvdrv '    Tegra::Nx2ClearSemaphoreRegions();' "    Tegra::Nx2ClearSemaphoreRegions();`n    Tegra::Nx2ClearGpuWrittenPages();" 'GPU-written page session reset'
}
Write-Utf8 $nvdrvPath $nvdrv

$bufferPath = 'src/video_core/buffer_cache/buffer_cache.h'
$buffer = Read-Lf $bufferPath
if (-not $buffer.Contains('#include "video_core/nx2.h"')) {
    $incOld = '#include "video_core/host1x/gpu_device_memory_manager.h"'
    $incNew = "#include `"video_core/host1x/gpu_device_memory_manager.h`"`n#include `"video_core/nx2.h`""
    $buffer = Replace-Once $buffer $incOld $incNew 'buffer-cache NX2 include'
}
if (-not $buffer.Contains('Tegra::Nx2MarkGpuWritten(pair.first, pair.second);')) {
    $old = @'
    for (const auto& pair : tmp_intervals) {
        gpu_modified_ranges.Add(pair.first, pair.second);
    }
'@
    $new = @'
    for (const auto& pair : tmp_intervals) {
        gpu_modified_ranges.Add(pair.first, pair.second);
        if (Tegra::g_nx2_ampere.load(std::memory_order_relaxed)) {
            Tegra::Nx2MarkGpuWritten(pair.first, pair.second);
        }
    }
'@
    $buffer = Replace-Once $buffer $old $new 'PR52 DMA write tracking'
}
if (-not $buffer.Contains('Tegra::Nx2MarkGpuWritten(device_addr, size);')) {
    # Legacy Eglantine queued async downloads inline. PokeDinner 2.0 replaced that block with
    # QueueDownload(device_addr, size) so GPU-written buffers are copied back only when useful.
    # Layer the PR52 page-history marker after whichever download policy the current source uses.
    $legacyOld = @'
    if (AsyncBufferDownloads()) {
        uncommitted_gpu_modified_ranges.Add(device_addr, size);
    }
}

template <class P>
BufferId BufferCache<P>::FindBuffer
'@
    $legacyNew = @'
    if (AsyncBufferDownloads()) {
        uncommitted_gpu_modified_ranges.Add(device_addr, size);
    }
    if (Tegra::g_nx2_ampere.load(std::memory_order_relaxed)) {
        Tegra::Nx2MarkGpuWritten(device_addr, size);
    }
}

template <class P>
BufferId BufferCache<P>::FindBuffer
'@
    $selectiveOld = @'
    QueueDownload(device_addr, size);
}

template <class P>
BufferId BufferCache<P>::FindBuffer
'@
    $selectiveNew = @'
    QueueDownload(device_addr, size);
    if (Tegra::g_nx2_ampere.load(std::memory_order_relaxed)) {
        Tegra::Nx2MarkGpuWritten(device_addr, size);
    }
}

template <class P>
BufferId BufferCache<P>::FindBuffer
'@
    if ($buffer.Contains($legacyOld.TrimEnd("`n"))) {
        $buffer = Replace-Once $buffer $legacyOld.TrimEnd("`n") $legacyNew.TrimEnd("`n") 'PR52 legacy shader/copy write tracking'
    } elseif ($buffer.Contains($selectiveOld.TrimEnd("`n"))) {
        $buffer = Replace-Once $buffer $selectiveOld.TrimEnd("`n") $selectiveNew.TrimEnd("`n") 'PR52 selective-copyback shader/copy write tracking'
    } else {
        throw 'Could not locate PR52 shader/copy write tracking anchor in either legacy or selective-copyback form'
    }
}
Write-Utf8 $bufferPath $buffer

$dmaHeaderPath = 'src/video_core/dma_pusher.h'
$dmaHeader = Read-Lf $dmaHeaderPath
if (-not $dmaHeader.Contains('std::vector<CommandHeader> submitted_words;')) {
    $old = @'
    /// EDEN_NX2_PB_CHECK: hash of each entry's words when it was submitted.
    std::vector<u64> submit_hashes;
'@
    $new = @'
    /// EDEN_NX2_PB_CHECK: hash of each entry's words when it was submitted.
    std::vector<u64> submit_hashes;
    /// CPU-visible words at submission time. A newer GPU-written copy takes precedence.
    std::vector<CommandHeader> submitted_words;
    std::vector<u32> submitted_offsets;
'@
    $dmaHeader = Replace-Once $dmaHeader $old $new 'PR28 CommandList snapshot fields'
}
if (-not $dmaHeader.Contains('bool FlushGpuWrittenCommands(GPUVAddr address, size_t size);')) {
    $old = '    void RecordParsedEntry(const CommandListHeader& header, std::span<const CommandHeader> commands);'
    $new = @'
    void RecordParsedEntry(const CommandListHeader& header, std::span<const CommandHeader> commands);
    [[nodiscard]] bool FlushGpuWrittenCommands(GPUVAddr address, size_t size);
'@
    $new = $new.TrimEnd("`n")
    $dmaHeader = Replace-Once $dmaHeader $old $new 'command-coherency helper declaration'
}
Write-Utf8 $dmaHeaderPath $dmaHeader

$submitPath = 'src/core/hle/service/nvdrv/devices/nvhost_gpu.cpp'
$submit = Read-Lf $submitPath
if (-not $submit.Contains('#include "video_core/memory_manager.h"')) {
    $incOld = '#include "video_core/host1x/host1x.h"'
    $incNew = "#include `"video_core/host1x/host1x.h`"`n#include `"video_core/memory_manager.h`""
    $submit = Replace-Once $submit $incOld $incNew 'snapshot memory-manager include'
}
if (-not $submit.Contains('EDEN_NX2_PB_SNAPSHOT')) {
    $old = @'
        if (check) {
            std::vector<u32> words;
            for (const auto& entry : entries.command_lists) {
                words.resize(entry.size);
                system.ApplicationMemory().ReadBlock(entry.addr.Value(), words.data(),
                                                     words.size() * sizeof(u32));
                entries.submit_hashes.push_back(Tegra::HashPushbufferWords(words));
            }
        }
'@
    $new = @'
        if (check) {
            std::vector<u32> words;
            for (const auto& entry : entries.command_lists) {
                words.resize(entry.size);
                system.ApplicationMemory().ReadBlock(entry.addr.Value(), words.data(),
                                                     words.size() * sizeof(u32));
                entries.submit_hashes.push_back(Tegra::HashPushbufferWords(words));
            }
        }
        static const bool snapshot = [] {
            const char* value = std::getenv("EDEN_NX2_PB_SNAPSHOT");
            return value == nullptr || value[0] != '0';
        }();
        if (snapshot && channel_state->memory_manager) {
            size_t words = 0;
            for (const auto& entry : entries.command_lists) words += entry.size;
            entries.submitted_words.resize(words);
            entries.submitted_offsets.reserve(entries.command_lists.size());
            size_t offset = 0;
            for (const auto& entry : entries.command_lists) {
                entries.submitted_offsets.push_back(static_cast<u32>(offset));
                channel_state->memory_manager->ReadBlockUnsafe(
                    entry.addr, entries.submitted_words.data() + offset, entry.size * sizeof(u32));
                offset += entry.size;
            }
        }
'@
    $submit = Replace-Once $submit $old $new 'PR28 submission snapshot capture'
}
Write-Utf8 $submitPath $submit

$dmaPath = 'src/video_core/dma_pusher.cpp'
$dma = Read-Lf $dmaPath
if (-not $dma.Contains('bool DmaPusher::FlushGpuWrittenCommands(')) {
    $helper = @'
bool DmaPusher::FlushGpuWrittenCommands(GPUVAddr address, size_t size) {
    if (!g_nx2_ampere.load(std::memory_order_relaxed) || size == 0) return false;
    bool potentially_written = false;
    for (GPUVAddr page = address & ~GPUVAddr{0xfff}; page < address + size; page += 0x1000) {
        if (const auto device = memory_manager.GpuToCpuAddress(page);
            device && Nx2IsGpuWritten(*device)) {
            potentially_written = true;
            break;
        }
    }
    if (!potentially_written) return false;
    VideoCommon::GpuSplit::Get().Drain();
    if (!memory_manager.IsMemoryDirty(address, size, VideoCommon::CacheType::BufferCache)) return false;
    memory_manager.FlushRegion(address, size, VideoCommon::CacheType::BufferCache);
    return true;
}

'@
    $dma = Insert-Before $dma 'void DmaPusher::Push(CommandList&& command_list) {' $helper 'bool DmaPusher::FlushGpuWrittenCommands(' 'GPU-written command coherency helper'
}

$legacyFetch = @'
        const bool gpu_written = FlushGpuWrittenCommands(address, size);
        std::span<const CommandHeader> commands;
        if (!gpu_written && index < command_list.submitted_offsets.size() &&
            command_list.submitted_offsets[index] + header.size <= command_list.submitted_words.size()) {
            commands = std::span<const CommandHeader>{command_list.submitted_words}.subspan(
                command_list.submitted_offsets[index], header.size);
        } else {
            const auto* ptr = memory_manager.GetPointer<const CommandHeader>(address, size);
            if (ptr == nullptr) [[unlikely]] {
                LOG_ERROR(HW_GPU, "Command list at {:#x} ({} words) is not CPU-mapped", address,
                          header.size);
                continue;
            }
            commands = std::span<const CommandHeader>{ptr, header.size};
        }
'@
if (-not $dma.Contains('const bool gpu_written = FlushGpuWrittenCommands')) {
    $old = @'
        const auto* ptr = memory_manager.GetPointer<const CommandHeader>(address, size);
        if (ptr == nullptr) [[unlikely]] {
            LOG_ERROR(HW_GPU, "Command list at {:#x} ({} words) is not CPU-mapped", address,
                      header.size);
            continue;
        }
        const std::span<const CommandHeader> commands{ptr, header.size};
'@
    $dma = Replace-Once $dma $old $legacyFetch.TrimEnd("`n") 'GPU-written command-list fetch policy'
}
Write-Utf8 $dmaPath $dma

Write-Host 'Applied PR #52 GPU-written command coherency + PR #28 submission snapshots.'

git diff -- src/video_core/nx2.h src/core/hle/service/nvdrv/nvdrv.cpp src/video_core/buffer_cache/buffer_cache.h src/video_core/dma_pusher.h src/core/hle/service/nvdrv/devices/nvhost_gpu.cpp src/video_core/dma_pusher.cpp
