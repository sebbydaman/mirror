$ErrorActionPreference = "Stop"

# Bananza reaches this surface after the startup/menu path: native F2I to byte/short
# destinations and compute shaders that bind storage-buffer slots above 15.
# Port the exact generic semantics from the Bananza-capable Eden-NS2 path without
# weakening shader validation or suppressing binding errors.

# -----------------------------------------------------------------------------
# Ampere native F2I: 8-bit / 16-bit destination modes
# -----------------------------------------------------------------------------
$amperePath = "src/shader_recompiler/frontend/ampere/lower_to_maxwell.h"
$ampereText = Get-Content $amperePath -Raw
$startNeedle = '        case 0x305: case 0xb05: case 0xd05: { // F2I NTZ, register/constant-buffer/uniform source'
$endNeedle = '        case 0xb6f:'
$start = $ampereText.IndexOf($startNeedle)
if ($start -lt 0) { throw "Could not locate native F2I lowering block" }
$end = $ampereText.IndexOf($endNeedle, $start)
if ($end -lt 0) { throw "Could not locate end of native F2I lowering block" }
$section = $ampereText.Substring($start, $end - $start)

if (-not $section.Contains('const bool byte = (mode & ~0x100U) == 0x0021e000;')) {
    $nearest = '            const bool nearest = (mode & ~0x10100U) == 0x00203000;'
    if (-not $section.Contains($nearest)) { throw "Could not locate F2I mode classification" }
    $section = $section.Replace(
        $nearest,
        $nearest + "`n" +
        '            // Destination size 0/1: truncate to 8/16-bit integer.' + "`n" +
        '            const bool byte = (mode & ~0x100U) == 0x0021e000;' + "`n" +
        '            const bool short_word = (mode & ~0x100U) == 0x0021e800;')

    $oldReject = '            if ((!half && !small && !floor && !nearest && (mode & ~0x100U) != 0x0021f000) ||'
    $newReject = '            if ((!half && !small && !floor && !nearest && !byte && !short_word && (mode & ~0x100U) != 0x0021f000) ||'
    if (-not $section.Contains($oldReject)) { throw "Could not locate F2I rejection guard" }
    $section = $section.Replace($oldReject, $newReject)

    $oldClamp = '                if (!small) {'
    $newClamp = '                if (!small && !byte && !short_word) {'
    if (-not $section.Contains($oldClamp)) { throw "Could not locate unsigned F2I clamp guard" }
    $section = $section.Replace($oldClamp, $newClamp)

    $oldWidth = '            emit(base(0x5cb0000000000000ULL) | (u64{small ? 1U : 2U} << 8) | (u64{2} << 10) |'
    $newWidth = '            emit(base(0x5cb0000000000000ULL) | (u64{byte ? 0U : small || short_word ? 1U : 2U} << 8) | (u64{2} << 10) |'
    if (-not $section.Contains($oldWidth)) { throw "Could not locate F2I destination-width encoding" }
    $section = $section.Replace($oldWidth, $newWidth)

    $oldUnsignedTail = '            if (!is_signed && !small) {'
    $newUnsignedTail = '            if (!is_signed && !small && !byte && !short_word) {'
    if (-not $section.Contains($oldUnsignedTail)) { throw "Could not locate unsigned F2I saturation tail" }
    $section = $section.Replace($oldUnsignedTail, $newUnsignedTail)

    $ampereText = $ampereText.Substring(0, $start) + $section + $ampereText.Substring($end)
    Set-Content -Path $amperePath -Value $ampereText -Encoding utf8 -NoNewline
    Write-Host "Added native F2I 8/16-bit destination lowering."
}

# -----------------------------------------------------------------------------
# Native compute storage buffers: indices 0..31
# -----------------------------------------------------------------------------
$bufferBasePath = "src/video_core/buffer_cache/buffer_cache_base.h"
$bufferBaseText = Get-Content $bufferBasePath -Raw
$oldCount = 'constexpr u32 NUM_STORAGE_BUFFERS = 16;'
$newCount = "// Native Switch 2 compute shaders bind more than 16 global-memory ranges; masks are u32.`nconstexpr u32 NUM_STORAGE_BUFFERS = 32;"
if ($bufferBaseText.Contains($oldCount)) {
    $bufferBaseText = $bufferBaseText.Replace($oldCount, $newCount)
    Set-Content -Path $bufferBasePath -Value $bufferBaseText -Encoding utf8 -NoNewline
    Write-Host "Expanded native compute storage-buffer capacity from 16 to 32."
} elseif (-not $bufferBaseText.Contains('constexpr u32 NUM_STORAGE_BUFFERS = 32;')) {
    throw "Unexpected storage-buffer capacity; refusing to patch blindly"
}

# -----------------------------------------------------------------------------
# Regression guards for the exact Bananza failure captured after Normal Mode.
# -----------------------------------------------------------------------------
$ampereCheck = Get-Content $amperePath -Raw
$bufferCheck = Get-Content $bufferBasePath -Raw
foreach ($needle in @(
    'const bool byte = (mode & ~0x100U) == 0x0021e000;',
    'const bool short_word = (mode & ~0x100U) == 0x0021e800;',
    'byte ? 0U : small || short_word ? 1U : 2U'
)) {
    if (-not $ampereCheck.Contains($needle)) { throw "Bananza post-menu regression: missing $needle" }
}
if (-not $bufferCheck.Contains('constexpr u32 NUM_STORAGE_BUFFERS = 32;')) {
    throw "Bananza post-menu regression: 32 storage buffers not enabled"
}

Write-Host "Bananza post-menu GPU patch applied and validated."

# The next gameplay phase can keep running with HUD/audio/input while world draws are skipped.
# Apply the exact shader forms captured in that blue-screen log after the byte/short F2I patch,
# because the follow-up extends this same F2I block.
$blueScreenScript = Join-Path $PSScriptRoot "apply-bananza-blue-screen-gpu.ps1"
& $blueScreenScript

# Generalized GPU/device-memory mapping correctness from Eglantine PR #48.
# This is relevant to the unmapped Device ReadBlock seen at Bananza's movement transition.
$deviceMemoryScript = Join-Path $PSScriptRoot "apply-eglantine-pr48-device-memory.ps1"
& $deviceMemoryScript

# Normalize one exact 01effa formatting anchor used by the larger combined patch.
$batchAnchorScript = Join-Path $PSScriptRoot "prepare-ns2-big-batch-anchors.ps1"
& $batchAnchorScript

# PokeDinner 2.0 uses selective QueueDownload() in MarkWrittenBuffer. Seed PR52's GPU-written
# page-history marker on that current source shape before the legacy combined patch runs; the
# combined patch then adds the tracker declarations/session reset/snapshot machinery and skips its
# obsolete inline-download anchor without undoing selective copyback.
$pr52PrepareScript = Join-Path $PSScriptRoot "prepare-pr52-selective-copyback.ps1"
& $pr52PrepareScript

# Post-#71 generalized batch: PR51 deferred instancing, combined PR52+PR28 command coherency,
# Bananza 0x224/0x234 semantics, and the newer Vulkan image-view safety fix.
$generalCompatScript = Join-Path $PSScriptRoot "apply-ns2-general-compat-batch-v2.ps1"
& $generalCompatScript

# Post-#73 runtime evidence: correct task/mesh indexed payloads, scalar TXQ destinations,
# SR29/SR17 special-register reads and RET link semantics before compiling the next build.
$runtimeV3Script = Join-Path $PSScriptRoot "apply-ns2-runtime-blockers-v3.ps1"
& $runtimeV3Script

# -----------------------------------------------------------------------------
# Late Eglantine GPU -> CPU read traps, merged with PokeDinner selective copyback
# -----------------------------------------------------------------------------
# Eglantine 8b4c42c fixes a blind spot in selective fence copyback: a guest fastmem read can bypass
# RasterizerVulkan::GetFlushArea entirely, so the emulator never learns that a GPU-written page is
# CPU-read. Arm only GPU-written cached pages so their first read faults through the rasterizer;
# after that PokeDinner's cpu_read_ranges/QueueDownload path keeps just those pages current.
$readTrapCommit = '8b4c42ccee5c304a8498e811e3079e254297d049'
$deviceMemoryHeader = 'src/core/device_memory_manager.h'
$deviceMemoryIncPath = 'src/core/device_memory_manager.inc'
$coreMemoryPath = 'src/core/memory.cpp'
$coreMemoryHeader = 'src/core/memory.h'
$bufferCachePath = 'src/video_core/buffer_cache/buffer_cache.h'
$vkRasterizerPath = 'src/video_core/renderer_vulkan/vk_rasterizer.cpp'
$readTrapMarker = 'void ArmReadTraps(DAddr addr, size_t size);'

if (-not (Get-Content $deviceMemoryHeader -Raw).Contains($readTrapMarker)) {
    git add -A
    if (git status --porcelain) {
        git -c user.name='Eden NS2 CI' -c user.email='actions@github.com' commit -m 'CI checkpoint before Eglantine read traps' --no-verify
        if ($LASTEXITCODE -ne 0) { throw 'Could not checkpoint before Eglantine read-trap merge' }
    }
    $checkpoint = (git rev-parse HEAD).Trim()

    $remote = 'eglantine-read-traps'
    if (-not (git remote | Select-String -SimpleMatch $remote)) {
        git remote add $remote 'https://github.com/Djihads80/Eglantine.git'
    }
    git fetch --no-tags --depth=64 $remote $readTrapCommit
    if ($LASTEXITCODE -ne 0) { throw 'Could not fetch Eglantine read-trap commit' }

    git cherry-pick --no-commit $readTrapCommit
    $pickExit = $LASTEXITCODE
    $conflicts = @(git diff --name-only --diff-filter=U)
    $manualFiles = @($bufferCachePath, $bufferBasePath, $vkRasterizerPath)
    if ($pickExit -ne 0) {
        $unexpected = @($conflicts | Where-Object { $_ -notin $manualFiles })
        if ($unexpected.Count -gt 0 -or $conflicts.Count -eq 0) {
            git cherry-pick --abort 2>$null
            throw "Unexpected Eglantine read-trap conflict surface: $($conflicts -join ', ')"
        }
    }

    foreach ($path in $manualFiles) {
        git checkout $checkpoint -- $path
        if ($LASTEXITCODE -ne 0) { throw "Could not restore $path for selective read-trap merge" }
    }

    $baseText = (Get-Content $bufferBasePath -Raw).Replace("`r`n", "`n")
    $flushDecl = '    std::optional<VideoCore::RasterizerDownloadArea> GetFlushArea(DAddr device_addr, u64 size);'
    if (-not $baseText.Contains('bool FlushesOnCpuRead() const')) {
        if (-not $baseText.Contains($flushDecl)) { throw 'Could not locate BufferCache GetFlushArea declaration' }
        $baseText = $baseText.Replace(
            $flushDecl,
            $flushDecl + "`n`n" +
            '    /// Native Switch 2 disables blanket fence downloads, so a trapped guest read must' + "`n" +
            '    /// ask the buffer cache for the current GPU-written contents.' + "`n" +
            '    bool FlushesOnCpuRead() const {' + "`n" +
            '        return !AsyncBufferDownloads();' + "`n" +
            '    }')
    }

    if (-not $baseText.Contains('Common::RangeSet<DAddr> read_trapped_ranges;')) {
        $gpuRanges = '    Common::RangeSet<DAddr> gpu_modified_ranges;'
        if (-not $baseText.Contains($gpuRanges)) { throw 'Could not locate GPU-modified range set' }
        $trapBlock = @'
    /// GPU-written pages not yet known to be CPU-read. Their first guest read is forced through
    /// the rasterizer; NoteCpuRead then promotes the range into selective fence copyback.
    void ArmReadTraps(DAddr device_addr, u64 size) {
        const DAddr begin = Common::AlignDown(device_addr, Core::DEVICE_PAGESIZE);
        const DAddr end = Common::AlignUp(device_addr + size, Core::DEVICE_PAGESIZE);
        u64 armed_bytes = 0;
        read_trapped_ranges.ForEachInRange(begin, end - begin, [&](DAddr lower, DAddr upper) {
            armed_bytes += upper - lower;
        });
        if (armed_bytes == end - begin) {
            return;
        }
        read_trapped_ranges.Add(begin, end - begin);
        device_memory.ArmReadTraps(begin, end - begin);
    }

    Common::RangeSet<DAddr> read_trapped_ranges;
'@
        $baseText = $baseText.Replace($gpuRanges, $trapBlock.TrimEnd() + "`n" + $gpuRanges)
    }

    $oldQueue = @'
        cpu_read_ranges.ForEachInRange(addr, size, [this](DAddr start, DAddr end) {
            uncommitted_gpu_modified_ranges.Add(start, end - start);
        });
'@
    $newQueue = @'
        u64 covered = 0;
        cpu_read_ranges.ForEachInRange(addr, size, [this, &covered](DAddr start, DAddr end) {
            uncommitted_gpu_modified_ranges.Add(start, end - start);
            covered += end - start;
        });
        // Fastmem reads do not naturally call GetFlushArea. Until a range has been observed as
        // CPU-read, trap its first read so NoteCpuRead sees it and this selective path takes over.
        if (covered < size) {
            ArmReadTraps(addr, size);
        }
'@
    if (-not $baseText.Contains('covered < size')) {
        if (-not $baseText.Contains($oldQueue.TrimEnd())) { throw 'Could not locate PokeDinner QueueDownload selective-copyback block' }
        $baseText = $baseText.Replace($oldQueue.TrimEnd(), $newQueue.TrimEnd())
    }
    Set-Content -Path $bufferBasePath -Value $baseText -Encoding utf8 -NoNewline

    $bufferText = (Get-Content $bufferCachePath -Raw).Replace("`r`n", "`n")
    if (-not $bufferText.Contains('read_trapped_ranges.Subtract(slot_buffers[buffer_id].CpuAddr()')) {
        $deleteNeedle = @'
    if constexpr (requires { runtime.OnBufferDeleted(slot_buffers[buffer_id]); }) {
        runtime.OnBufferDeleted(slot_buffers[buffer_id]);
    }
'@
        if (-not $bufferText.Contains($deleteNeedle.TrimEnd())) { throw 'Could not locate BufferCache DeleteBuffer runtime hook' }
        $deleteReplacement = $deleteNeedle.TrimEnd() + "`n" +
            '    read_trapped_ranges.Subtract(slot_buffers[buffer_id].CpuAddr(),' + "`n" +
            '                                 slot_buffers[buffer_id].SizeBytes());'
        $bufferText = $bufferText.Replace($deleteNeedle.TrimEnd(), $deleteReplacement)
        Set-Content -Path $bufferCachePath -Value $bufferText -Encoding utf8 -NoNewline
    }

    $vkText = (Get-Content $vkRasterizerPath -Raw).Replace("`r`n", "`n")
    if (-not $vkText.Contains('buffer_cache.FlushesOnCpuRead()')) {
        $textureBlock = @'
    {
        std::scoped_lock lock{texture_cache.mutex};
        auto area = texture_cache.GetFlushArea(addr, size);
        if (area) {
            return *area;
        }
    }
'@
        if (-not $vkText.Contains($textureBlock.TrimEnd())) { throw 'Could not locate Vulkan texture GetFlushArea block' }
        $bufferFlush = @'
    if (buffer_cache.FlushesOnCpuRead()) {
        std::scoped_lock lock{buffer_cache.mutex};
        auto area = buffer_cache.GetFlushArea(addr, size);
        if (area) {
            return *area;
        }
    }
'@
        $vkText = $vkText.Replace($textureBlock.TrimEnd(), $textureBlock.TrimEnd() + "`n" + $bufferFlush.TrimEnd())
        Set-Content -Path $vkRasterizerPath -Value $vkText -Encoding utf8 -NoNewline
    }

    git add -A
    git -c user.name='Eden NS2 CI' -c user.email='actions@github.com' commit -m 'Integrate Eglantine read traps with selective copyback' --no-verify
    if ($LASTEXITCODE -ne 0) {
        git cherry-pick --abort 2>$null
        throw 'Could not finalize Eglantine read-trap merge'
    }
    git cherry-pick --quit 2>$null
    Write-Host 'Integrated Eglantine GPU-read traps without replacing PokeDinner selective copyback.'
}

# Prefer build167's native GPU read-trap + preflush tracking when present.
# Its memory_tracker.IsRegionPreflushable gate supersedes PokeDinner's older
# cpu_read_ranges / QueueDownload range accounting; never graft both models.
$baseText = (Get-Content $bufferBasePath -Raw).Replace("`r`n", "`n")
$nativeReadTrapCopyback = $baseText.Contains('memory_tracker.IsRegionPreflushable(device_addr, size)') -and
    $baseText.Contains('void ArmReadTraps(DAddr device_addr, u64 size)') -and
    $baseText.Contains('read_trapped_ranges.Add(begin, end - begin);')
if ($nativeReadTrapCopyback) {
    Write-Host '[PASS] build167 native read-trap / preflush copyback; preserving newer implementation.'
} elseif (-not $baseText.Contains('covered < size')) {
    throw 'Neither build167 native preflush read traps nor legacy selective copyback are available'
}

$deviceMemoryCheck = Get-Content $deviceMemoryHeader -Raw
$deviceMemoryIncCheck = Get-Content $deviceMemoryIncPath -Raw
$coreMemoryCheck = Get-Content $coreMemoryPath -Raw
$bufferBaseCheck = Get-Content $bufferBasePath -Raw
$bufferCacheCheck = Get-Content $bufferCachePath -Raw
$vkCheck = Get-Content $vkRasterizerPath -Raw
$ampereCheck = Get-Content $amperePath -Raw
foreach ($pair in @(
    @($deviceMemoryCheck, 'void ArmReadTraps(DAddr addr, size_t size);', 'Eglantine device-memory read traps'),
    @($coreMemoryCheck, 'EDEN_NX2_READ_TRAPS', 'read-trap debug fallback'),
    @($bufferBaseCheck, 'Common::RangeSet<DAddr> read_trapped_ranges;', 'read-trap buffer range tracking'),
    @($bufferBaseCheck, 'void ArmReadTraps(DAddr device_addr, u64 size)', 'GPU read-trap buffer tracking'),
    @($vkCheck, 'buffer_cache.FlushesOnCpuRead()', 'immediate trapped CPU-read buffer flush'),
    @($deviceMemoryIncCheck, 'tracked_entries.GetUnchecked(start_page_d + i).continuity_tracker = 0;', 'build167 stale unmapped-page continuity reset'),
    @($deviceMemoryIncCheck, 'tracked_entries.GetUnchecked(start_page_d + i).compressed_physical_ptr = 0;', 'build167 unmapped-page physical pointer reset'),
    @($ampereCheck, '~0x040000ffU', 'Raiders signed-LOD gradient texture lowering'),
    @($ampereCheck, 'insn.Bits(76, 2) == 2', 'Raiders/Welcome Tour TLD4 .PTP lowering')
)) {
    if (-not $pair[0].Contains($pair[1])) { throw "Combined NS2 regression: missing $($pair[2])" }
    Write-Host "[PASS] $($pair[2])"
}
if (-not $nativeReadTrapCopyback -and -not $bufferCacheCheck.Contains('read_trapped_ranges.Subtract(slot_buffers[buffer_id].CpuAddr()')) {
    throw 'Combined NS2 regression: read-trap history is not cleared with deleted buffers'
}
Write-Host '[PASS] read-trap buffer lifetime cleanup'

git diff -- src/shader_recompiler/frontend/ampere/lower_to_maxwell.h `
            src/shader_recompiler/frontend/maxwell/translate/impl/load_store_attribute.cpp `
            src/video_core/buffer_cache/buffer_cache_base.h `
            src/core/device_memory_manager.h `
            src/core/device_memory_manager.inc `
            src/core/memory.cpp `
            src/core/memory.h `
            src/video_core/host1x/gpu_device_memory_manager.cpp `
            src/video_core/engines/draw_manager.cpp `
            src/video_core/engines/maxwell_3d.cpp `
            src/video_core/engines/maxwell_3d.h `
            src/video_core/nx2.h `
            src/video_core/buffer_cache/buffer_cache.h `
            src/video_core/dma_pusher.cpp `
            src/video_core/dma_pusher.h `
            src/core/hle/service/nvdrv/nvdrv.cpp `
            src/core/hle/service/nvdrv/devices/nvhost_gpu.cpp `
            src/video_core/renderer_vulkan/vk_rasterizer.cpp `
            src/video_core/renderer_vulkan/vk_texture_cache.cpp
