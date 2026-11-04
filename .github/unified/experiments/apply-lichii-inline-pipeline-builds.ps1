$ErrorActionPreference = 'Stop'
# Staged Lichii build70 PR71 inline waited-on Vulkan pipelines (457a32de0a).
# Preserve Orchid's default unless independent video_core build and game tests pass.
function Edit-Exact([string]$Path,[string]$Old,[string]$New,[string]$Name) {
    $eol = [string][char]13 + [string][char]10
    $lf = [string][char]10
    $raw = [IO.File]::ReadAllText((Resolve-Path $Path).Path).Replace($eol,$lf)
    $before = $Old.Replace($eol,$lf).TrimEnd([char[]]@([char]13,[char]10))
    $after = $New.Replace($eol,$lf).TrimEnd([char[]]@([char]13,[char]10))
    if ($raw.Contains($after)) { Write-Host "[ALREADY] $Name"; return }
    $at = $raw.IndexOf($before,[StringComparison]::Ordinal)
    if ($at -lt 0 -or $raw.IndexOf($before,$at+$before.Length,[StringComparison]::Ordinal) -ge 0) {
        throw "Missing or nonunique Lichii waited-on pipeline source anchor: $Name"
    }
    $output = $raw.Substring(0,$at) + $after + $raw.Substring($at+$before.Length)
    [IO.File]::WriteAllText((Resolve-Path $Path).Path,$output,[Text.UTF8Encoding]::new($false))
    Write-Host "[PORTED] $Name"
}

$old0 = @'
    if (thread_worker) {
        thread_worker->QueueWork(std::move(func));
    } else {
        func();
    }
}
'@
$new0 = @'
    build_task = std::move(func);
    if (thread_worker) {
        thread_worker->QueueWork([this] { RunBuild(); });
    } else {
        RunBuild();
    }
}

void ComputePipeline::RunBuild() {
    // A draw or dispatch that needs the pipeline builds it on the scheduler thread instead of
    // waiting for the worker queue, which can hold hundreds of builds, to reach it.
    if (build_claimed.exchange(true)) {
        return;
    }
    build_task();
    build_task = nullptr;
}
'@
Edit-Exact 'src/video_core/renderer_vulkan/vk_compute_pipeline.cpp' $old0 $new0 'Compute claimed pipeline inline build'

$old1 = @'
        scheduler.Record([this](vk::CommandBuffer) {
            std::unique_lock lock{build_mutex};
'@
$new1 = @'
        scheduler.Record([this](vk::CommandBuffer) {
            RunBuild();
            std::unique_lock lock{build_mutex};
'@
Edit-Exact 'src/video_core/renderer_vulkan/vk_compute_pipeline.cpp' $old1 $new1 'Compute compile missing pipeline on first wait'

$old2 = @'
#include <condition_variable>
'@
$new2 = @'
#include <condition_variable>
#include <functional>
'@
Edit-Exact 'src/video_core/renderer_vulkan/vk_compute_pipeline.h' $old2 $new2 'Compute functional include'

$old3 = @'
private:
'@
$new3 = @'
private:
    void RunBuild();
'@
Edit-Exact 'src/video_core/renderer_vulkan/vk_compute_pipeline.h' $old3 $new3 'Compute inline build method declaration'

$old4 = @'
    std::condition_variable build_condvar;
'@
$new4 = @'
    std::function<void()> build_task;
    std::atomic_bool build_claimed{false};
    std::condition_variable build_condvar;
'@
Edit-Exact 'src/video_core/renderer_vulkan/vk_compute_pipeline.h' $old4 $new4 'Compute one-shot build fields'

$old5 = @'
    if (worker_thread) {
        worker_thread->QueueWork(std::move(func));
    } else {
        func();
    }
}
'@
$new5 = @'
    build_task = std::move(func);
    if (worker_thread) {
        worker_thread->QueueWork([this] { RunBuild(); });
    } else {
        RunBuild();
    }
}

void GraphicsPipeline::RunBuild() {
    // A draw or dispatch that needs the pipeline builds it on the scheduler thread instead of
    // waiting for the worker queue, which can hold hundreds of builds, to reach it.
    if (build_claimed.exchange(true)) {
        return;
    }
    build_task();
    build_task = nullptr;
}
'@
Edit-Exact 'src/video_core/renderer_vulkan/vk_graphics_pipeline.cpp' $old5 $new5 'Graphics claimed pipeline inline build'

$old6 = @'
        scheduler.Record([this](vk::CommandBuffer) {
            std::unique_lock lock{build_mutex};
'@
$new6 = @'
        scheduler.Record([this](vk::CommandBuffer) {
            RunBuild();
            std::unique_lock lock{build_mutex};
'@
Edit-Exact 'src/video_core/renderer_vulkan/vk_graphics_pipeline.cpp' $old6 $new6 'Graphics compile missing pipeline on first wait'

$old7 = @'
#include <condition_variable>
'@
$new7 = @'
#include <condition_variable>
#include <functional>
'@
Edit-Exact 'src/video_core/renderer_vulkan/vk_graphics_pipeline.h' $old7 $new7 'Graphics functional include'

$old8 = @'
private:
'@
$new8 = @'
private:
    void RunBuild();
'@
Edit-Exact 'src/video_core/renderer_vulkan/vk_graphics_pipeline.h' $old8 $new8 'Graphics inline build method declaration'

$old9 = @'
    std::condition_variable build_condvar;
'@
$new9 = @'
    std::function<void()> build_task;
    std::atomic_bool build_claimed{false};
    std::condition_variable build_condvar;
'@
Edit-Exact 'src/video_core/renderer_vulkan/vk_graphics_pipeline.h' $old9 $new9 'Graphics one-shot build fields'

foreach ($file in @('src/video_core/renderer_vulkan/vk_compute_pipeline.cpp',
                    'src/video_core/renderer_vulkan/vk_graphics_pipeline.cpp')) {
    if (-not (Select-String -Path $file -SimpleMatch 'build_claimed.exchange(true)' -Quiet) -or
        -not (Select-String -Path $file -SimpleMatch 'RunBuild();' -Quiet)) {
        throw "Waited-on pipeline donor incomplete: $file"
    }
}
git diff --check
if ($LASTEXITCODE -ne 0) { throw 'Lichii pipeline source diff check failed' }
Write-Host '[PASS] Optional Lichii waited-on pipeline build candidate staged'
