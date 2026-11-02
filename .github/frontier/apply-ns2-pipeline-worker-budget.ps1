$ErrorActionPreference = 'Stop'

# Keep PokeDinner/Eden's proven desktop worker policy by default and expose only an explicit
# EDEN_NX2_PIPELINE_WORKERS=<N> override for A/B testing. The earlier automatic Switch 2 budget
# reduced a Ryzen 5 7600X from 11 builders + 5 native translators to 3 builders + 1 translator.
# Real Pokopia logs showed that this did not improve heavy-scene frame time and left only one
# native-translation worker, while the older/faster MSVC build used five. Do not silently throttle
# the production path; let the donor's hardware_concurrency()-1 policy stand unless the user asks
# for a smaller pool through the environment override.

function Write-PatchedText([string]$Path, [string]$Text) {
    $normalized = $Text.TrimEnd("`r", "`n") + "`n"
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText((Resolve-Path $Path).Path, $normalized, $utf8NoBom)
}

$path = 'src/video_core/renderer_vulkan/vk_pipeline_cache.cpp'
if (-not (Test-Path $path -PathType Leaf)) {
    throw "NX2 pipeline-worker override: missing $path"
}

$text = (Get-Content $path -Raw).Replace("`r`n", "`n")
$marker = 'EDEN_NX2_PIPELINE_WORKERS'
if ($text.Contains($marker)) {
    foreach ($needle in @(
        'const size_t hardware_threads =',
        'return max_core_threads;',
        'std::strtoul(value, &end, 10)'
    )) {
        if (-not $text.Contains($needle)) {
            throw "NX2 pipeline-worker override: partial existing implementation; missing $needle"
        }
    }
    if ($text.Contains('hardware_threads / 4ULL')) {
        throw 'NX2 pipeline-worker override: stale automatic Switch 2 throttle is still present'
    }
    Write-Host '[PRESENT] donor-capacity pipeline workers with explicit NX2 override'
    exit 0
}

if (-not $text.Contains('#include <cstdlib>')) {
    $includeAnchor = '#include <cstddef>'
    if (-not $text.Contains($includeAnchor)) {
        throw 'NX2 pipeline-worker override: cstdlib include anchor changed'
    }
    $text = $text.Replace($includeAnchor, "$includeAnchor`n#include <cstdlib>")
}

$functionStart = $text.IndexOf('size_t GetTotalPipelineWorkers() {', [StringComparison]::Ordinal)
if ($functionStart -lt 0) {
    throw 'NX2 pipeline-worker override: GetTotalPipelineWorkers function is unavailable'
}
$functionEndMarker = "`n// EDEN_NX2_ASYNC_TRANSLATION"
$functionEnd = $text.IndexOf($functionEndMarker, $functionStart, [StringComparison]::Ordinal)
if ($functionEnd -lt 0 -or $functionEnd - $functionStart -gt 2600) {
    throw 'NX2 pipeline-worker override: could not isolate GetTotalPipelineWorkers safely'
}
$function = $text.Substring($functionStart, $functionEnd - $functionStart)

# Preserve the donor's hardware_concurrency()-1 policy, but name the hardware count so the
# validation is explicit and the override can clamp safely to the donor maximum.
$maxPattern = '(?ms)    const size_t max_core_threads\s*=\s*std::max<size_t>\(\s*(?:static_cast<size_t>\(\s*)?std::thread::hardware_concurrency\(\)\s*\)?\s*,\s*2ULL\s*\)\s*-\s*1ULL\s*;'
$maxMatch = [regex]::Match($function, $maxPattern)
if (-not $maxMatch.Success) {
    throw 'NX2 pipeline-worker override: GetTotalPipelineWorkers worker-count semantics changed'
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
    throw 'NX2 pipeline-worker override: desktop worker-policy semantics changed'
}
$desktopNew = @'
#else
    // Optional A/B override. Invalid/zero values preserve the donor default instead of
    // accidentally disabling pipeline compilation.
    if (const char* const value = std::getenv("EDEN_NX2_PIPELINE_WORKERS");
        value != nullptr && value[0] != '\0') {
        char* end = nullptr;
        const unsigned long requested = std::strtoul(value, &end, 10);
        if (end != value && *end == '\0' && requested != 0) {
            return std::clamp<size_t>(static_cast<size_t>(requested), 1ULL, max_core_threads);
        }
    }

    // Production default: keep the donor's full hardware_concurrency()-1 builder capacity.
    // On the user's 7600X this restores 11 builders and the donor's 5 translation workers.
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
    'return max_core_threads;',
    'std::strtoul(value, &end, 10)'
)) {
    if (-not $final.Contains($needle)) {
        throw "NX2 pipeline-worker override validation failed: missing $needle"
    }
}
if ($final.Contains('hardware_threads / 4ULL')) {
    throw 'NX2 pipeline-worker override validation failed: stale automatic throttle remains'
}

git diff --check
if ($LASTEXITCODE -ne 0) {
    throw 'NX2 pipeline-worker override introduced diff/whitespace errors'
}

Write-Host '[APPLIED] restored donor pipeline capacity by default (7600X: 11 builders + 5 translators)'
Write-Host '[INFO] EDEN_NX2_PIPELINE_WORKERS=<N> remains available for explicit A/B testing.'