$ErrorActionPreference = 'Stop'

# Pokopia's warmed runs still queue substantial native graphics translation work even after the
# transferable pipeline cache is fully restored. PipelineStats shows a large fraction of those jobs
# are shader-reuse rejections. PokeDinner retains only four environment-answer variants per
# ShaderTranslationKey, so a fifth legitimate variant can never be remembered and must translate
# again whenever it reappears.
#
# Keep the original four-variant behavior for non-Switch-2 titles. Switch 2 uses a bounded default
# of eight variants, with EDEN_NX2_SHADER_REUSE_VARIANTS=<N> (1..16) for controlled A/B testing.
# Setting it to 4 restores the current behavior without rebuilding.

function Write-PatchedText([string]$Path, [string]$Text) {
    $normalized = $Text.TrimEnd("`r", "`n") + "`n"
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText((Resolve-Path $Path).Path, $normalized, $utf8NoBom)
}

$headerPath = 'src/video_core/renderer_vulkan/vk_shader_reuse.h'
$cppPath = 'src/video_core/renderer_vulkan/vk_shader_reuse.cpp'
foreach ($path in @($headerPath, $cppPath)) {
    if (-not (Test-Path $path -PathType Leaf)) {
        throw "NX2 shader-reuse variants: missing $path"
    }
}

$header = (Get-Content $headerPath -Raw).Replace("`r`n", "`n")
$cpp = (Get-Content $cppPath -Raw).Replace("`r`n", "`n")
$marker = 'EDEN_NX2_SHADER_REUSE_VARIANTS'

if ($cpp.Contains($marker)) {
    foreach ($needle in @(
        'static size_t MaxVariants();',
        'constexpr size_t LegacyMaxVariants = 4;',
        'constexpr size_t DefaultNx2MaxVariants = 8;',
        'constexpr size_t MaxNx2MaxVariants = 16;',
        'Tegra::g_nx2_ampere.load(std::memory_order_relaxed)',
        'MaxVariants()'
    )) {
        $combined = $header + "`n" + $cpp
        if (-not $combined.Contains($needle)) {
            throw "NX2 shader-reuse variants: partial existing implementation; missing $needle"
        }
    }
    Write-Host '[PRESENT] bounded Switch 2 shader-reuse variant retention'
    exit 0
}

$headerNeedle = 'static constexpr size_t MaxVariants = 4;'
if (-not $header.Contains($headerNeedle)) {
    throw 'NX2 shader-reuse variants: PokeDinner MaxVariants declaration changed'
}
$header = $header.Replace($headerNeedle, 'static size_t MaxVariants();')

if (-not $cpp.Contains('#include <cstdlib>')) {
    $includeAnchor = '#include <cstring>'
    if (-not $cpp.Contains($includeAnchor)) {
        throw 'NX2 shader-reuse variants: cstdlib include anchor changed'
    }
    $cpp = $cpp.Replace($includeAnchor, "$includeAnchor`n#include <cstdlib>")
}
if (-not $cpp.Contains('#include "video_core/nx2.h"')) {
    $includeAnchor = '#include "video_core/renderer_vulkan/vk_shader_reuse.h"'
    if (-not $cpp.Contains($includeAnchor)) {
        throw 'NX2 shader-reuse variants: nx2 include anchor changed'
    }
    $cpp = $cpp.Replace($includeAnchor, "$includeAnchor`n#include `"video_core/nx2.h`"")
}

$namespaceAnchor = "namespace Vulkan {`n"
if (-not $cpp.Contains($namespaceAnchor)) {
    throw 'NX2 shader-reuse variants: Vulkan namespace anchor changed'
}
$helper = @'

size_t ShaderReuseCache::MaxVariants() {
    constexpr size_t LegacyMaxVariants = 4;
    if (!Tegra::g_nx2_ampere.load(std::memory_order_relaxed)) {
        return LegacyMaxVariants;
    }

    static const size_t nx2_max_variants = [] {
        constexpr size_t DefaultNx2MaxVariants = 8;
        constexpr size_t MaxNx2MaxVariants = 16;
        const char* const value = std::getenv("EDEN_NX2_SHADER_REUSE_VARIANTS");
        if (value == nullptr || value[0] == '\0') {
            return DefaultNx2MaxVariants;
        }
        char* end = nullptr;
        const unsigned long requested = std::strtoul(value, &end, 10);
        if (end == value || *end != '\0' || requested == 0) {
            return DefaultNx2MaxVariants;
        }
        return std::clamp<size_t>(static_cast<size_t>(requested), size_t{1},
                                  MaxNx2MaxVariants);
    }();
    return nx2_max_variants;
}
'@
$helper = $helper.TrimEnd("`r", "`n")
$cpp = $cpp.Replace($namespaceAnchor, $namespaceAnchor + $helper + "`n")

$addNeedle = 'if (variants.size() >= MaxVariants) {'
if (-not $cpp.Contains($addNeedle)) {
    throw 'NX2 shader-reuse variants: Add capacity guard changed'
}
$cpp = $cpp.Replace($addNeedle, 'if (variants.size() >= MaxVariants()) {')

Write-PatchedText $headerPath $header
Write-PatchedText $cppPath $cpp

$finalHeader = Get-Content $headerPath -Raw
$finalCpp = Get-Content $cppPath -Raw
foreach ($needle in @(
    'static size_t MaxVariants();',
    'EDEN_NX2_SHADER_REUSE_VARIANTS',
    'constexpr size_t LegacyMaxVariants = 4;',
    'constexpr size_t DefaultNx2MaxVariants = 8;',
    'constexpr size_t MaxNx2MaxVariants = 16;',
    'Tegra::g_nx2_ampere.load(std::memory_order_relaxed)',
    'if (variants.size() >= MaxVariants()) {'
)) {
    if (-not (($finalHeader + "`n" + $finalCpp).Contains($needle))) {
        throw "NX2 shader-reuse variants validation failed: missing $needle"
    }
}

git diff --check
if ($LASTEXITCODE -ne 0) {
    throw 'NX2 shader-reuse variants introduced diff/whitespace errors'
}

Write-Host '[APPLIED] Switch 2 shader-reuse retention: 4 -> 8 variants per key by default (bounded at 16)'
Write-Host '[INFO] EDEN_NX2_SHADER_REUSE_VARIANTS=4 restores the prior retention limit for A/B testing.'
