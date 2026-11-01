$ErrorActionPreference = 'Stop'

# Remove bring-up diagnostics that still execute in normal gameplay after their original decision
# logic moved elsewhere. These are deliberately tiny semantic-preserving cleanups: no cache,
# synchronization, readback or ordering behavior is changed.

function Write-PatchedText([string]$Path, [string]$Text) {
    $normalized = $Text.TrimEnd("`r", "`n") + "`n"
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText((Resolve-Path $Path).Path, $normalized, $utf8NoBom)
}

$gpuPath = 'src/video_core/gpu.cpp'
if (-not (Test-Path $gpuPath -PathType Leaf)) {
    throw "NX2 legacy hotpath cleanup: missing $gpuPath"
}

$text = (Get-Content $gpuPath -Raw).Replace("`r`n", "`n")
$newMarker = 'Reactive readback performs no unconditional diagnostic bookkeeping.'
if (-not $text.Contains($newMarker)) {
    $old = @'
        // A guest CPU read of GPU-written memory (reactive flushing): count them, they decide
        // whether buffer data must be copied back at every fence (EDEN_NX2_BUFFER_DOWNLOADS).
        if (static std::atomic<u64> reads{}; (reads.fetch_add(1, std::memory_order_relaxed) & 63) == 0) {
            LOG_INFO(HW_GPU, "CPU read of GPU-written memory [{:#x}, {:#x}) ({} so far)",
                     raster_area.start_address, raster_area.end_address,
                     reads.load(std::memory_order_relaxed));
        }
'@
    $old = $old.TrimEnd("`r", "`n")
    $new = @'
        // Reactive readback performs no unconditional diagnostic bookkeeping. The old bring-up
        // counter did an atomic operation on every CPU read of GPU-written memory and emitted an
        // INFO log every 64 reads even in normal gameplay, while no runtime policy consumed it.
'@
    $new = $new.TrimEnd("`r", "`n")

    if ($text.Contains($old)) {
        $text = $text.Replace($old, $new)
    } else {
        # Later donor/frontier layers can reflow comments or LOG_INFO arguments without changing the
        # diagnostic itself. Isolate OnCPURead and remove only the proven atomic/log block there;
        # never use a repository-wide regex that could touch synchronization or unrelated counters.
        $onCpuReadStart = $text.IndexOf('VideoCore::RasterizerDownloadArea OnCPURead(DAddr addr, u64 size)')
        $onCpuReadEnd = if ($onCpuReadStart -ge 0) {
            $text.IndexOf('    /// Notify rasterizer that any caches of the specified region should be invalidated', $onCpuReadStart)
        } else {
            -1
        }
        if ($onCpuReadStart -lt 0 -or $onCpuReadEnd -lt 0) {
            throw 'NX2 legacy hotpath cleanup: could not isolate OnCPURead for guarded diagnostic cleanup'
        }

        $section = $text.Substring($onCpuReadStart, $onCpuReadEnd - $onCpuReadStart)
        $diagnosticPattern = '(?ms)^[ \t]*if\s*\(\s*static\s+std::atomic<u64>\s+reads\{\}\s*;\s*\(reads\.fetch_add\(\s*1\s*,\s*std::memory_order_relaxed\s*\)\s*&\s*63\s*\)\s*==\s*0\s*\)\s*\{\s*.*?^[ \t]*\}\s*'
        $matches = [regex]::Matches($section, $diagnosticPattern)
        if ($matches.Count -ne 1) {
            if ($text.Contains('CPU read of GPU-written memory') -or $text.Contains('reads.fetch_add')) {
                throw "NX2 legacy hotpath cleanup: reactive-read diagnostic changed shape; guarded match count=$($matches.Count)"
            }
            throw 'NX2 legacy hotpath cleanup: expected reactive-read diagnostic is unavailable'
        }

        $block = $matches[0].Value
        if (-not $block.Contains('LOG_INFO(HW_GPU') -or
            -not $block.Contains('CPU read of GPU-written memory') -or
            -not $block.Contains('reads.load(')) {
            throw 'NX2 legacy hotpath cleanup: guarded match was not the proven reactive-read diagnostic'
        }

        $section = $section.Remove($matches[0].Index, $matches[0].Length).Insert($matches[0].Index, $new + "`n")
        $text = $text.Substring(0, $onCpuReadStart) + $section + $text.Substring($onCpuReadEnd)
    }

    Write-PatchedText $gpuPath $text
    Write-Host '[REMOVED] unconditional reactive-read atomic/log diagnostic'
} else {
    Write-Host '[PRESENT] reactive-read hotpath diagnostic cleanup'
}

$final = Get-Content $gpuPath -Raw
foreach ($legacy in @(
    'CPU read of GPU-written memory [{:#x}, {:#x}) ({} so far)',
    'reads.fetch_add(1, std::memory_order_relaxed)'
)) {
    if ($final.Contains($legacy)) {
        throw "NX2 legacy hotpath cleanup validation failed: stale diagnostic remains: $legacy"
    }
}
foreach ($required in @(
    'auto raster_area = renderer->ReadRasterizer()->GetFlushArea(addr, size);',
    'raster_area.preemtive = true;',
    'renderer->ReadRasterizer()->FlushRegion(raster_area.start_address, raster_area.end_address - raster_area.start_address);',
    'WaitForSyncOperation(fence);'
)) {
    if (-not $final.Contains($required)) {
        throw "NX2 legacy hotpath cleanup validation failed: reactive-read synchronization changed: $required"
    }
}

& git diff --check
if ($LASTEXITCODE -ne 0) {
    throw 'NX2 legacy hotpath cleanup introduced diff/whitespace errors'
}

Write-Host 'NX2 legacy hotpath cleanup passed: synchronization preserved, unconditional diagnostic overhead removed.'
