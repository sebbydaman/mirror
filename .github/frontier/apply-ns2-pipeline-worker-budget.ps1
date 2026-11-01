$ErrorActionPreference = 'Stop'

# PokeDinner 2.0 inherits Eden's desktop Vulkan worker policy of hardware_concurrency()-1 pipeline
# builders, then creates a second native-translation pool at half that size. On SMT desktop CPUs this
# can heavily oversubscribe the host during runtime pipeline churn (a 6C/12T CPU becomes 11 builders
# plus 5 translators) while the emulated CPU and split GPU threads are trying to make the frame.
#
# For Switch 2 sessions, budget the builder pool to roughly half of a typical SMT CPU's physical
# cores (logical_threads / 4, minimum 2). Translation workers remain PokeDinner's half-builder count.
# Switch 1 keeps Eden's original policy. EDEN_NX2_PIPELINE_WORKERS=<N> overrides the Switch 2 budget
# for A/B testing without another rebuild.
#
# Match the worker function structurally rather than pinning its exact whitespace. Several donor
# layers legitimately edit nearby pipeline-cache code; formatting-only drift must not block the
# cheap capture/regression pass before a long Windows compile.

function Write-PatchedText([string]$Path, [string]$Text) {
    $normalized = $Text.TrimEnd("`r", "`n") + "`n"
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText((Resolve-Path $Path).Path, $normalized, $utf8NoBom)
}

$path = 'src/video_core/renderer_vulkan/vk_pipeline_cache.cpp'
$settingsHeader = 'src/common/settings.h'
if (-not (Test-Path $path -PathType Leaf)) {
    throw "NX2 pipeline-worker budget: missing $path"
}
if (-not (Test-Path $settingsHeader -PathType Leaf) -or
    -not (Get-Content $settingsHeader -Raw).Contains('bool CurrentProgramIsSwitch2();')) {
    throw 'NX2 pipeline-worker budget: Switch 2 program-state helper is unavailable'
}

$text = (Get-Content $path -Raw).Replace("`r`n", "`n")
$marker = 'EDEN_NX2_PIPELINE_WORKERS'
if ($text.Contains($marker)) {
    foreach ($needle in @(
        'const size_t hardware_threads =',
        'Settings::CurrentProgramIsSwitch2()',
        'hardware_threads / 4ULL'
    )) {
        if (-not $text.Contains($needle)) {
            throw "NX2 pipeline-worker budget: partial existing implementation; missing $needle"
        }
    }
    Write-Host '[PRESENT] Switch 2 pipeline-worker CPU budget'
    exit 0
}

if (-not $text.Contains('#include "common/settings.h"')) {
    $includeAnchor = '#include "common/scope_exit.h"'
    if (-not $text.Contains($includeAnchor)) {
        throw 'NX2 pipeline-worker budget: common/settings.h include anchor changed'
    }
    $text = $text.Replace($includeAnchor, "$includeAnchor`n#include `"common/settings.h`"")
}
if (-not $text.Contains('#include <cstdlib>')) {
    $includeAnchor = '#include <cstddef>'
    if (-not $text.Contains($includeAnchor)) {
        throw 'NX2 pipeline-worker budget: cstdlib include anchor changed'
    }
    $text = $text.Replace($includeAnchor, "$includeAnchor`n#include <cstdlib>")
}

$functionStart = $text.IndexOf('size_t GetTotalPipelineWorkers() {', [StringComparison]::Ordinal)
if ($functionStart -lt 0) {
    throw 'NX2 pipeline-worker budget: GetTotalPipelineWorkers function is unavailable'
}
$functionEndMarker = "`n// EDEN_NX2_ASYNC_TRANSLATION"
$functionEnd = $text.IndexOf($functionEndMarker, $functionStart, [StringComparison]::Ordinal)
if ($functionEnd -lt 0 -or $functionEnd - $functionStart -gt 2600) {
    throw 'NX2 pipeline-worker budget: could not isolate GetTotalPipelineWorkers safely'
}
$function = $text.Substring($functionStart, $functionEnd - $functionStart)

# Accept the same hardware_concurrency()-1 policy across whitespace/wrapping variants, but refuse a
# semantically different worker calculation. That keeps this adapter resilient without silently
# replacing a future donor policy we have not reviewed.
$maxPattern = '(?ms)    const size_t max_core_threads\s*=\s*std::max<size_t>\(\s*(?:static_cast<size_t>\(\s*)?std::thread::hardware_concurrency\(\)\s*\)?\s*,\s*2ULL\s*\)\s*-\s*1ULL\s*;'
$maxMatch = [regex]::Match($function, $maxPattern)
if (-not $maxMatch.Success) {
    throw 'NX2 pipeline-worker budget: GetTotalPipelineWorkers worker-count semantics changed'
}
$newWorkerCount = @'
    const size_t hardware_threads =
        std::max<size_t>(static_cast<size_t>(std::thread::hardware_concurrency()), 2ULL);
    const size_t max_core_threads = hardware_threads - 1ULL;
'@
$newWorkerCount = $newWorkerCount.TrimEnd("`r", "`n")
$function = $function.Remove($maxMatch.Index, $maxMatch.Length).Insert($maxMatch.Index, $newWorkerCount)

$desktopPattern = '(?ms)#else\s*\n\s*return max_core_threads;\s*\n#endif'
$desktopMatch = [regex]::Match($function, $desktopPattern)
if (-not $desktopMatch.Success) {
    throw 'NX2 pipeline-worker budget: desktop worker-policy semantics changed'
}
$desktopNew = @'
#else
    // Explicit override for CPU-contention A/B tests. Invalid/zero values fall back to the
    // automatic policy rather than accidentally disabling pipeline compilation.
    if (const char* const value = std::getenv("EDEN_NX2_PIPELINE_WORKERS");
        value != nullptr && value[0] != '\0') {
        char* end = nullptr;
        const unsigned long requested = std::strtoul(value, &end, 10);
        if (end != value && *end == '\0' && requested != 0) {
            return std::clamp<size_t>(static_cast<size_t>(requested), 1ULL, max_core_threads);
        }
    }

    // PokeDinner also creates translation_workers at half this count. Keeping the builder pool
    // near half of a typical SMT CPU's physical cores leaves host time for guest CPU execution,
    // the GPU front/back split, Vulkan scheduling and Windows instead of spawning 11+5 workers
    // on a Ryzen 5 7600X. The core sets CurrentProgramIsSwitch2 before the GPU starts.
    if (Settings::CurrentProgramIsSwitch2()) {
        const size_t nx2_budget = std::max<size_t>(2ULL, hardware_threads / 4ULL);
        return std::min(max_core_threads, nx2_budget);
    }
    return max_core_threads;
#endif
'@
$desktopNew = $desktopNew.TrimEnd("`r", "`n")
$function = $function.Remove($desktopMatch.Index, $desktopMatch.Length).Insert($desktopMatch.Index, $desktopNew)
$text = $text.Remove($functionStart, $functionEnd - $functionStart).Insert($functionStart, $function)
Write-PatchedText $path $text

$final = Get-Content $path -Raw
foreach ($needle in @(
    'EDEN_NX2_PIPELINE_WORKERS',
    'const size_t hardware_threads =',
    'Settings::CurrentProgramIsSwitch2()',
    'const size_t nx2_budget = std::max<size_t>(2ULL, hardware_threads / 4ULL);',
    'std::strtoul(value, &end, 10)'
)) {
    if (-not $final.Contains($needle)) {
        throw "NX2 pipeline-worker budget validation failed: missing $needle"
    }
}

git diff --check
if ($LASTEXITCODE -ne 0) {
    throw 'NX2 pipeline-worker budget introduced diff/whitespace errors'
}

Write-Host '[APPLIED] Switch 2 pipeline-worker CPU budget (7600X: 11 builders + 5 translators -> 3 builders + 1 translator)'
Write-Host '[INFO] EDEN_NX2_PIPELINE_WORKERS=<N> overrides the builder count for A/B testing.'