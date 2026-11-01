$ErrorActionPreference = 'Stop'

# The normal Vulkan safety path forces known-broken parallel-compiling drivers to one pipeline
# worker. For Switch 2 only, allow a deliberately small two-worker budget so MKW/Pokopia can overlap
# native pipeline compilation without opening the floodgates to hardware_concurrency()-1 workers.
# Switch 1 and every non-Switch-2 broken-driver path remain at one worker.

function Write-PatchedText([string]$Path, [string]$Text) {
    $normalized = $Text.TrimEnd("`r", "`n") + "`n"
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText((Resolve-Path $Path).Path, $normalized, $utf8NoBom)
}

$path = 'src/video_core/renderer_vulkan/vk_pipeline_cache.cpp'
if (-not (Test-Path $path -PathType Leaf)) {
    throw "NX2 broken-driver worker budget: missing $path"
}

$text = (Get-Content $path -Raw).Replace("`r`n", "`n")
$marker = 'EDEN_NX2_BROKEN_PARALLEL_WORKERS'
if ($text.Contains($marker)) {
    Write-Host '[PRESENT] Switch 2 broken-driver two-worker pipeline budget'
    exit 0
}

$old = '      workers(device.HasBrokenParallelShaderCompiling() ? 1ULL : GetTotalPipelineWorkers(),'
$new = @'
      // EDEN_NX2_BROKEN_PARALLEL_WORKERS: keep the global safety fallback at one worker, but permit
      // a tightly bounded two-worker exception for Switch 2. This avoids the 11-worker desktop
      // oversubscription path while letting the second compiler overlap with the GPU/front-end.
      workers(device.HasBrokenParallelShaderCompiling()
                  ? (Settings::CurrentProgramIsSwitch2() ? 2ULL : 1ULL)
                  : GetTotalPipelineWorkers(),
'@
$new = $new.TrimEnd("`r", "`n")

if (-not $text.Contains($old)) {
    throw 'NX2 broken-driver worker budget: PipelineCache worker constructor anchor changed'
}
$text = $text.Replace($old, $new)
Write-PatchedText $path $text

$final = Get-Content $path -Raw
foreach ($needle in @(
    'EDEN_NX2_BROKEN_PARALLEL_WORKERS',
    'Settings::CurrentProgramIsSwitch2() ? 2ULL : 1ULL',
    ': GetTotalPipelineWorkers()'
)) {
    if (-not $final.Contains($needle)) {
        throw "NX2 broken-driver worker budget validation failed: missing $needle"
    }
}

git diff --check
if ($LASTEXITCODE -ne 0) {
    throw 'NX2 broken-driver worker budget introduced diff/whitespace errors'
}

Write-Host '[APPLIED] Switch 2 broken-driver pipeline workers: 1 -> 2 (all other broken-driver paths remain 1)'
