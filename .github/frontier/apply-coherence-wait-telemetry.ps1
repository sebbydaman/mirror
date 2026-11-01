$ErrorActionPreference = 'Stop'

$path = 'src/video_core/gpu.cpp'
if (-not (Test-Path $path -PathType Leaf)) {
    throw "NX2 coherence telemetry: missing $path"
}

$text = (Get-Content $path -Raw).Replace("`r`n", "`n")
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

$namespaceAnchor = @'
constexpr u64 GpuClockMultiplier(Settings::GpuClock clock) {
    switch (clock) {
    case Settings::GpuClock::Boost:
        return 256;
    case Settings::GpuClock::Overclock:
        return 512;
    default:
        return 1;
    }
}
'@

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

if (-not $text.Contains($namespaceAnchor)) {
    throw 'NX2 coherence telemetry: GPU clock helper anchor missing'
}
$text = $text.Replace($namespaceAnchor, $namespaceAnchor + $profileHelpers)

$oldFrame = @'
    void RendererFrameEndNotify() {
        system.GetPerfStats().EndGameFrame();
    }
'@
$newFrame = @'
    void RendererFrameEndNotify() {
        system.GetPerfStats().EndGameFrame();
        Nx2CoherenceReportFrame();
    }
'@
if (-not $text.Contains($oldFrame)) {
    throw 'NX2 coherence telemetry: frame-end anchor missing'
}
$text = $text.Replace($oldFrame, $newFrame)

$oldRead = @'
    VideoCore::RasterizerDownloadArea OnCPURead(DAddr addr, u64 size) {
        auto raster_area = renderer->ReadRasterizer()->GetFlushArea(addr, size);
        if (raster_area.preemtive) {
            return raster_area;
        }
        raster_area.preemtive = true;
        // A guest CPU read of GPU-written memory (reactive flushing): count them, they decide
        // whether buffer data must be copied back at every fence (EDEN_NX2_BUFFER_DOWNLOADS).
        // Reactive readback performs no unconditional diagnostic bookkeeping. The old bring-up
        // counter did an atomic operation on every CPU read of GPU-written memory and emitted an
        // INFO log every 64 reads even in normal gameplay, while no runtime policy consumed it.
const u64 fence = RequestSyncOperation([this, &raster_area]() {
            renderer->ReadRasterizer()->FlushRegion(raster_area.start_address, raster_area.end_address - raster_area.start_address);
        });
        gpu_thread.TickGPU(is_async);
        WaitForSyncOperation(fence);
        return raster_area;
    }
'@
$newRead = @'
    VideoCore::RasterizerDownloadArea OnCPURead(DAddr addr, u64 size) {
        const bool profile = Nx2CoherenceProfileEnabled();
        u64 lookup_start_ns = 0;
        if (profile) {
            lookup_start_ns = Nx2CoherenceNowNs();
            Nx2CoherenceEnsureWindow(lookup_start_ns);
            g_nx2_coherence_profile.cpu_reads.fetch_add(1, std::memory_order_relaxed);
        }

        auto raster_area = renderer->ReadRasterizer()->GetFlushArea(addr, size);
        if (profile) {
            g_nx2_coherence_profile.lookup_ns.fetch_add(Nx2CoherenceNowNs() - lookup_start_ns,
                                                         std::memory_order_relaxed);
        }
        if (raster_area.preemtive) {
            if (profile) {
                g_nx2_coherence_profile.preemptive_reads.fetch_add(1,
                                                                   std::memory_order_relaxed);
            }
            return raster_area;
        }
        raster_area.preemtive = true;

        const u64 reactive_start_ns = profile ? Nx2CoherenceNowNs() : 0;
        const u64 fence = RequestSyncOperation([this, &raster_area]() {
            renderer->ReadRasterizer()->FlushRegion(
                raster_area.start_address, raster_area.end_address - raster_area.start_address);
        });
        gpu_thread.TickGPU(is_async);
        const u64 wait_start_ns = profile ? Nx2CoherenceNowNs() : 0;
        WaitForSyncOperation(fence);
        if (profile) {
            const u64 complete_ns = Nx2CoherenceNowNs();
            g_nx2_coherence_profile.wait_ns.fetch_add(complete_ns - wait_start_ns,
                                                       std::memory_order_relaxed);
            g_nx2_coherence_profile.reactive_ns.fetch_add(complete_ns - reactive_start_ns,
                                                           std::memory_order_relaxed);
            g_nx2_coherence_profile.reactive_syncs.fetch_add(1, std::memory_order_relaxed);
        }
        return raster_area;
    }
'@
if (-not $text.Contains($oldRead)) {
    throw 'NX2 coherence telemetry: OnCPURead anchor missing'
}
$text = $text.Replace($oldRead, $newRead)

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
