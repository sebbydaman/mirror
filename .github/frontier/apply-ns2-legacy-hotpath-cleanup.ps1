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
    if (-not $text.Contains($old)) {
        if ($text.Contains('CPU read of GPU-written memory') -or $text.Contains('reads.fetch_add')) {
            throw 'NX2 legacy hotpath cleanup: reactive-read diagnostic changed shape; refusing partial cleanup'
        }
        throw 'NX2 legacy hotpath cleanup: expected reactive-read diagnostic is unavailable'
    }
    $text = $text.Replace($old, $new)
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