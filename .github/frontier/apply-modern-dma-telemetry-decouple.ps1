$ErrorActionPreference = 'Stop'

# The DMA increasing-run front-cache is a production hot-path optimization, but its donor version
# also contains optional profiler/semaphore-watch hooks. The modern 60 FPS composition intentionally
# omits those telemetry layers, so keep the routing cache while removing only those dependencies.

function Write-PatchedText([string]$Path, [string]$Text) {
    $normalized = $Text.Replace("`r`n", "`n").TrimEnd("`r", "`n") + "`n"
    [IO.File]::WriteAllText((Resolve-Path $Path).Path, $normalized, [Text.UTF8Encoding]::new($false))
}

$path = 'src/video_core/dma_pusher.cpp'
if (-not (Test-Path $path -PathType Leaf)) {
    throw "Modern DMA telemetry decouple: missing $path"
}

$text = (Get-Content $path -Raw).Replace("`r`n", "`n")
$marker = 'Modern60 telemetry-free DMA run cache'

if (-not $text.Contains($marker)) {
    $profileBlock = @'
                const bool run_profile_enabled = Profile::Enabled();
                if (run_profile_enabled && run_split_active) [[unlikely]] {
                    Profile::Add(Profile::Counter::DmaSplitEngineWords, available_words);
                }

'@
    $profileBlock = $profileBlock.Replace("`r`n", "`n")
    if (-not $text.Contains($profileBlock)) {
        throw 'Modern DMA telemetry decouple: expected DMA run profiling block is missing'
    }
    $replacement = @'
                // Modern60 telemetry-free DMA run cache: routing does not depend on optional
                // profiler/semaphore-watch layers that are intentionally absent from this stack.
'@
    $replacement = $replacement.Replace("`r`n", "`n").TrimEnd("`r", "`n") + "`n"
    $text = $text.Replace($profileBlock, $replacement)

    $watchGuard = '                if (g_semaphore_watch == 0 && run_split_active) {'
    $productionGuard = '                if (run_split_active) {'
    if (-not $text.Contains($watchGuard)) {
        throw 'Modern DMA telemetry decouple: expected semaphore-watch guard is missing'
    }
    $text = $text.Replace($watchGuard, $productionGuard)

    Write-PatchedText $path $text
    Write-Host '[APPLIED] Modern60 DMA run cache decoupled from optional telemetry hooks'
} else {
    Write-Host '[PRESENT] Modern60 DMA run cache already decoupled from optional telemetry hooks'
}

$final = (Get-Content $path -Raw).Replace("`r`n", "`n")
foreach ($forbidden in @(
    'const bool run_profile_enabled = Profile::Enabled();',
    'Profile::Add(Profile::Counter::DmaSplitEngineWords, available_words);',
    'g_semaphore_watch == 0 && run_split_active'
)) {
    if ($final.Contains($forbidden)) {
        throw "Modern DMA telemetry decouple validation failed: stale dependency $forbidden"
    }
}
foreach ($required in @(
    'Modern60 telemetry-free DMA run cache',
    'if (run_split_active) {',
    'Engines::EngineInterface* run_split_engine = nullptr;',
    'run_split.Method(run_split_engine, dma_state.method, argument,'
)) {
    if (-not $final.Contains($required)) {
        throw "Modern DMA telemetry decouple validation failed: missing $required"
    }
}

& git diff --check
if ($LASTEXITCODE -ne 0) {
    throw 'Modern DMA telemetry decouple introduced diff/whitespace errors'
}

Write-Host 'Modern DMA telemetry decouple validated: production routing cache preserved without profiler/watch dependencies.'
