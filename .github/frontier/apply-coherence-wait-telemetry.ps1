$ErrorActionPreference = 'Stop'

$path = 'src/video_core/gpu.cpp'
if (-not (Test-Path $path -PathType Leaf)) {
    throw "NX2 coherence telemetry: missing $path"
}

# Some donor patches leave mixed line endings in this file. Normalize all CR bytes first so the
# structural anchors below stay deterministic in capture, normal and PGO workflows.
$text = (Get-Content $path -Raw).Replace("`r", "")
if ($text.Contains('NX2 coherence:')) {
    Write-Host '[PRESENT] NX2 coherence wait telemetry already installed'
    exit 0
}

$includeAnchor = '#include <condition_variable>'
if (-not $text.Contains($includeAnchor)) {
    throw 'NX2 coherence telemetry: include anchor missing'
}
$text = $text.Replace($includeAnchor, "#include <condition_variable>`n#include <cstdlib>")

$loggingAnchor = '#include "common/assert.h"'
if (-not $text.Contains($loggingAnchor)) {
    throw 'NX2 coherence telemetry: logging include anchor missing'
}
$text = $text.Replace($loggingAnchor, $loggingAnchor + "`n" + '#include "common/logging.h"')

$profileHelpers = @'

struct Nx2CoherenceProfile {
    std::atomic<u64> window_start_ns{};
    std::atomic<u64> lookup_ns{};
    std::atomic<u64> reactive_ns{};
    std::atomic<u64> wait_ns{};
    std::atomic<u64> cpu_reads{};
    std::atomic<u64> preemptive_reads{};
    std::atomic<u64> reactive_syncs{};
    std::atomic<u64> frames{};
};

Nx2CoherenceProfile g_nx2_coherence_profile;

[[nodiscard]] bool Nx2CoherenceProfileEnabled() {
    static const bool enabled = std::getenv("EDEN_NX2_GPU_PROFILE") != nullptr;
    return enabled;
}

[[nodiscard]] u64 Nx2CoherenceNowNs() {
    return static_cast<u64>(std::chrono::duration_cast<std::chrono::nanoseconds>(
                                std::chrono::steady_clock::now().time_since_epoch())
                                .count());
}

void Nx2CoherenceEnsureWindow(u64 now_ns) {
    u64 expected = 0;
    g_nx2_coherence_profile.window_start_ns.compare_exchange_strong(
        expected, now_ns, std::memory_order_relaxed, std::memory_order_relaxed);
}

void Nx2CoherenceReportFrame() {
    if (!Nx2CoherenceProfileEnabled()) {
        return;
    }

    const u64 now_ns = Nx2CoherenceNowNs();
    Nx2CoherenceEnsureWindow(now_ns);
    g_nx2_coherence_profile.frames.fetch_add(1, std::memory_order_relaxed);

    u64 window_start = g_nx2_coherence_profile.window_start_ns.load(std::memory_order_relaxed);
    constexpr u64 ReportWindowNs = 10'000'000'000ULL;
    if (now_ns - window_start < ReportWindowNs ||
        !g_nx2_coherence_profile.window_start_ns.compare_exchange_strong(
            window_start, now_ns, std::memory_order_relaxed, std::memory_order_relaxed)) {
        return;
    }

    const u64 window_ns = now_ns - window_start;
    const u64 frames = g_nx2_coherence_profile.frames.exchange(0, std::memory_order_relaxed);
    const u64 lookup_ns = g_nx2_coherence_profile.lookup_ns.exchange(0, std::memory_order_relaxed);
    const u64 reactive_ns = g_nx2_coherence_profile.reactive_ns.exchange(0, std::memory_order_relaxed);
    const u64 wait_ns = g_nx2_coherence_profile.wait_ns.exchange(0, std::memory_order_relaxed);
    const u64 cpu_reads = g_nx2_coherence_profile.cpu_reads.exchange(0, std::memory_order_relaxed);
    const u64 preemptive_reads =
        g_nx2_coherence_profile.preemptive_reads.exchange(0, std::memory_order_relaxed);
    const u64 reactive_syncs =
        g_nx2_coherence_profile.reactive_syncs.exchange(0, std::memory_order_relaxed);

    if (frames == 0 || window_ns == 0) {
        return;
    }

    const double frame_scale = 1.0 / (1'000'000.0 * static_cast<double>(frames));
    const double second_scale = 1'000'000'000.0 / static_cast<double>(window_ns);
    const double fps = static_cast<double>(frames) * second_scale;
    LOG_INFO(HW_GPU,
             "NX2 coherence: {:.1f} FPS | lookup {:.3f} ms/frame | reactive {:.3f} ms/frame "
             "(wait {:.3f}) | CPU reads {:.0f}/s | reactive syncs {:.0f}/s | preemptive {:.0f}/s",
             fps, static_cast<double>(lookup_ns) * frame_scale,
             static_cast<double>(reactive_ns) * frame_scale,
             static_cast<double>(wait_ns) * frame_scale,
             static_cast<double>(cpu_reads) * second_scale,
             static_cast<double>(reactive_syncs) * second_scale,
             static_cast<double>(preemptive_reads) * second_scale);
}
'@

$namespaceClose = '} // Anonymous namespace'
if (([regex]::Matches($text, [regex]::Escape($namespaceClose))).Count -ne 1) {
    throw 'NX2 coherence telemetry: anonymous-namespace boundary missing or ambiguous'
}
$text = $text.Replace($namespaceClose, $profileHelpers + "`n" + $namespaceClose)

$frameStatement = '        system.GetPerfStats().EndGameFrame();'
if (([regex]::Matches($text, [regex]::Escape($frameStatement))).Count -ne 1) {
    throw 'NX2 coherence telemetry: frame-end statement missing or ambiguous'
}
$text = $text.Replace($frameStatement, $frameStatement + "`n        Nx2CoherenceReportFrame();")

$readStartMarker = '    VideoCore::RasterizerDownloadArea OnCPURead(DAddr addr, u64 size) {'
$readEndMarker = '    /// Notify rasterizer that any caches of the specified region should be invalidated'
$readStart = $text.IndexOf($readStartMarker, [StringComparison]::Ordinal)
$readEnd = $text.IndexOf($readEndMarker, $readStart, [StringComparison]::Ordinal)
if ($readStart -lt 0 -or $readEnd -lt 0 -or $readEnd -le $readStart) {
    throw 'NX2 coherence telemetry: OnCPURead structural boundaries missing'
}
$readBlock = $text.Substring($readStart, $readEnd - $readStart)

$readBlock = $readBlock.Replace(
    $readStartMarker,
    $readStartMarker + "`n        const bool profile = Nx2CoherenceProfileEnabled();`n" +
    "        u64 lookup_start_ns = 0;`n        if (profile) {`n" +
    "            lookup_start_ns = Nx2CoherenceNowNs();`n" +
    "            Nx2CoherenceEnsureWindow(lookup_start_ns);`n" +
    "            g_nx2_coherence_profile.cpu_reads.fetch_add(1, std::memory_order_relaxed);`n" +
    "        }`n")

$lookupLine = '        auto raster_area = renderer->ReadRasterizer()->GetFlushArea(addr, size);'
if (-not $readBlock.Contains($lookupLine)) {
    throw 'NX2 coherence telemetry: GetFlushArea line missing'
}
$readBlock = $readBlock.Replace(
    $lookupLine,
    $lookupLine + "`n        if (profile) {`n" +
    "            g_nx2_coherence_profile.lookup_ns.fetch_add(Nx2CoherenceNowNs() - lookup_start_ns,`n" +
    "                                                         std::memory_order_relaxed);`n        }")

$preemptiveBlock = "        if (raster_area.preemtive) {`n            return raster_area;`n        }"
if (-not $readBlock.Contains($preemptiveBlock)) {
    throw 'NX2 coherence telemetry: preemptive-read block missing'
}
$readBlock = $readBlock.Replace(
    $preemptiveBlock,
    "        if (raster_area.preemtive) {`n            if (profile) {`n" +
    "                g_nx2_coherence_profile.preemptive_reads.fetch_add(1,`n" +
    "                                                                   std::memory_order_relaxed);`n" +
    "            }`n            return raster_area;`n        }")

$fenceNeedle = 'const u64 fence = RequestSyncOperation([this, &raster_area]() {'
if (([regex]::Matches($readBlock, [regex]::Escape($fenceNeedle))).Count -ne 1) {
    throw 'NX2 coherence telemetry: reactive fence anchor missing or ambiguous'
}
$readBlock = $readBlock.Replace(
    $fenceNeedle,
    "        const u64 reactive_start_ns = profile ? Nx2CoherenceNowNs() : 0;`n" +
    '        const u64 fence = RequestSyncOperation([this, &raster_area]() {')

$tickLine = '        gpu_thread.TickGPU(is_async);'
if (([regex]::Matches($readBlock, [regex]::Escape($tickLine))).Count -ne 1) {
    throw 'NX2 coherence telemetry: TickGPU anchor missing or ambiguous'
}
$readBlock = $readBlock.Replace(
    $tickLine,
    $tickLine + "`n        const u64 wait_start_ns = profile ? Nx2CoherenceNowNs() : 0;")

$waitLine = '        WaitForSyncOperation(fence);'
if (([regex]::Matches($readBlock, [regex]::Escape($waitLine))).Count -ne 1) {
    throw 'NX2 coherence telemetry: reactive wait anchor missing or ambiguous'
}
$readBlock = $readBlock.Replace(
    $waitLine,
    $waitLine + "`n        if (profile) {`n            const u64 complete_ns = Nx2CoherenceNowNs();`n" +
    "            g_nx2_coherence_profile.wait_ns.fetch_add(complete_ns - wait_start_ns,`n" +
    "                                                       std::memory_order_relaxed);`n" +
    "            g_nx2_coherence_profile.reactive_ns.fetch_add(complete_ns - reactive_start_ns,`n" +
    "                                                           std::memory_order_relaxed);`n" +
    "            g_nx2_coherence_profile.reactive_syncs.fetch_add(1, std::memory_order_relaxed);`n" +
    "        }")

$text = $text.Substring(0, $readStart) + $readBlock + $text.Substring($readEnd)

[IO.File]::WriteAllText((Resolve-Path $path).Path, $text.TrimEnd("`r", "`n") + "`n",
    [Text.UTF8Encoding]::new($false))

& git diff --check
if ($LASTEXITCODE -ne 0) {
    throw 'NX2 coherence telemetry introduced diff/whitespace errors'
}

$verify = Get-Content $path -Raw
foreach ($needle in @('NX2 coherence:', 'lookup_ns', 'reactive_ns', 'wait_ns',
                      'Nx2CoherenceReportFrame();', 'EDEN_NX2_GPU_PROFILE')) {
    if (-not $verify.Contains($needle)) {
        throw "NX2 coherence telemetry verification failed: missing $needle"
    }
}

Write-Host '[APPLIED] opt-in per-frame CPU/GPU coherence lookup, reactive-sync and wait-time telemetry'
