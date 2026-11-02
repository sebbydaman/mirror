$ErrorActionPreference = 'Stop'

# PokeDinner's native graphics translation pool is derived from half of the Vulkan pipeline-builder
# pool. The Switch 2 CPU-contention budget intentionally reduces a Ryzen 5 7600X from 11 builders to
# 3 builders. A two-translator experiment drained Pokopia race-start translation bursts faster, but
# the user A/B exposed visual regressions, so Phase 1 must keep one native translator as the safe
# correctness baseline.
#
# EDEN_NX2_TRANSLATION_WORKERS=<N> independently overrides the translator count for controlled A/B
# testing after correctness is stable. Switch 1 keeps PokeDinner's original half-builder policy.
# The count is always clamped to the pipeline-builder count so translators cannot outnumber the
# threads that service normal pipeline work.

function Write-PatchedText([string]$Path, [string]$Text) {
    $normalized = $Text.TrimEnd("`r", "`n") + "`n"
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText((Resolve-Path $Path).Path, $normalized, $utf8NoBom)
}

$path = 'src/video_core/renderer_vulkan/vk_pipeline_cache.cpp'
if (-not (Test-Path $path -PathType Leaf)) {
    throw "NX2 translation-worker budget: missing $path"
}

$text = (Get-Content $path -Raw).Replace("`r`n", "`n")
$marker = 'EDEN_NX2_TRANSLATION_WORKERS'
if ($text.Contains($marker)) {
    foreach ($needle in @(
        'Settings::CurrentProgramIsSwitch2()',
        'constexpr size_t DefaultNx2TranslationWorkers = 1ULL;',
        'std::strtoul(value, &end, 10)',
        'std::min(pipeline_workers, DefaultNx2TranslationWorkers)'
    )) {
        if (-not $text.Contains($needle)) {
            throw "NX2 translation-worker budget: partial existing implementation; missing $needle"
        }
    }
    Write-Host '[PRESENT] Switch 2 independent native translation-worker budget'
    exit 0
}

# The preceding pipeline-worker adapter already adds these includes to the composed source, but keep
# this patch independently safe if the order changes during future experiments.
if (-not $text.Contains('#include "common/settings.h"')) {
    $includeAnchor = '#include "common/scope_exit.h"'
    if (-not $text.Contains($includeAnchor)) {
        throw 'NX2 translation-worker budget: common/settings.h include anchor changed'
    }
    $text = $text.Replace($includeAnchor, "$includeAnchor`n#include `"common/settings.h`"")
}
if (-not $text.Contains('#include <cstdlib>')) {
    $includeAnchor = '#include <cstddef>'
    if (-not $text.Contains($includeAnchor)) {
        throw 'NX2 translation-worker budget: cstdlib include anchor changed'
    }
    $text = $text.Replace($includeAnchor, "$includeAnchor`n#include <cstdlib>")
}

# Match the donor semantics structurally rather than byte-for-byte. The PokeDinner batch and nearby
# adapters can legitimately change whitespace or integer literal suffixes without changing the
# half-builder policy we are replacing.
$translationPattern = '(?ms)size_t\s+GetTotalTranslationWorkers\(\)\s*\{\s*return\s+std::max<size_t>\(\s*1(?:ULL)?\s*,\s*GetTotalPipelineWorkers\(\)\s*/\s*2(?:ULL)?\s*\)\s*;\s*\}'
$translationMatch = [regex]::Match($text, $translationPattern)
if (-not $translationMatch.Success) {
    throw 'NX2 translation-worker budget: PokeDinner GetTotalTranslationWorkers semantics changed'
}

$new = @'
size_t GetTotalTranslationWorkers() {
    const size_t pipeline_workers = GetTotalPipelineWorkers();
    if (!Settings::CurrentProgramIsSwitch2()) {
        return std::max<size_t>(1ULL, pipeline_workers / 2ULL);
    }

    // EDEN_NX2_TRANSLATION_WORKERS independently controls the native translation pool. Invalid or
    // zero values use the automatic Switch 2 policy instead of accidentally disabling translation.
    if (const char* const value = std::getenv("EDEN_NX2_TRANSLATION_WORKERS");
        value != nullptr && value[0] != '\0') {
        char* end = nullptr;
        const unsigned long requested = std::strtoul(value, &end, 10);
        if (end != value && *end == '\0' && requested != 0) {
            return std::clamp<size_t>(static_cast<size_t>(requested), 1ULL, pipeline_workers);
        }
    }

    // Phase-1 correctness baseline: the two-translator A/B produced rendering regressions in
    // Pokopia. Keep one translator by default and retain the override for later controlled tests.
    constexpr size_t DefaultNx2TranslationWorkers = 1ULL;
    return std::max<size_t>(1ULL, std::min(pipeline_workers, DefaultNx2TranslationWorkers));
}
'@
$new = $new.TrimEnd("`r", "`n")
$text = $text.Remove($translationMatch.Index, $translationMatch.Length).Insert($translationMatch.Index, $new)
Write-PatchedText $path $text

$final = Get-Content $path -Raw
foreach ($needle in @(
    'EDEN_NX2_TRANSLATION_WORKERS',
    'Settings::CurrentProgramIsSwitch2()',
    'constexpr size_t DefaultNx2TranslationWorkers = 1ULL;',
    'std::strtoul(value, &end, 10)',
    'std::min(pipeline_workers, DefaultNx2TranslationWorkers)'
)) {
    if (-not $final.Contains($needle)) {
        throw "NX2 translation-worker budget validation failed: missing $needle"
    }
}

git diff --check
if ($LASTEXITCODE -ne 0) {
    throw 'NX2 translation-worker budget introduced diff/whitespace errors'
}

Write-Host '[APPLIED] Switch 2 native graphics translators: correctness default 1 worker; builders remain independently budgeted'
Write-Host '[INFO] EDEN_NX2_TRANSLATION_WORKERS=<N> overrides translator count for later controlled A/B testing.'