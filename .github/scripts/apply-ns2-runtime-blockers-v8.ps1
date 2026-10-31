$ErrorActionPreference = 'Stop'

# PokeDinner-derived, source-verified policy: on a Switch 2 Vulkan session with less than
# 12 GiB of device-local VRAM, leaving ASTC as RGBA8 can multiply texture memory enough to
# trigger cache churn. Match the donor's session behavior: if the user still has ASTC
# recompression set to Uncompressed, switch it to BC3 unless EDEN_NX2_KEEP_ASTC=1.
# Do not override an explicit BC1/BC3 choice and do not affect ordinary Switch 1 sessions.
function Read-Lf([string]$Path) {
    if (-not (Test-Path $Path)) { throw "Missing required source file: $Path" }
    return (Get-Content $Path -Raw).Replace("`r`n", "`n")
}
function Write-Utf8([string]$Path, [string]$Text) {
    Set-Content -Path $Path -Value $Text -Encoding utf8 -NoNewline
}
function Replace-Once([string]$Text, [string]$Old, [string]$New, [string]$Label) {
    $at = $Text.IndexOf($Old)
    if ($at -lt 0) { throw "Could not locate $Label" }
    if ($Text.IndexOf($Old, $at + $Old.Length) -ge 0) { throw "Ambiguous anchor for $Label" }
    return $Text.Substring(0, $at) + $New + $Text.Substring($at + $Old.Length)
}

$path = 'src/video_core/renderer_vulkan/renderer_vulkan.cpp'
$text = Read-Lf $path
$policyMarker = 'Settings::values.astc_recompression.SetValue(Settings::AstcRecompression::Bc3);'

if (-not $text.Contains($policyMarker)) {
    if (-not $text.Contains('#include <cstdlib>')) {
        $text = Replace-Once $text '#include <cstring>' "#include <cstring>`n#include <cstdlib>" 'cstdlib include'
    }
    if (-not $text.Contains('#include "video_core/nx2.h"')) {
        $oldInclude = '#include "video_core/gpu.h"'
        $newInclude = @'
#include "video_core/gpu.h"
#include "video_core/nx2.h"
'@
        $text = Replace-Once $text $oldInclude $newInclude.TrimEnd("`r", "`n") 'NX2 include'
    }

    $anchor = '    if (Settings::values.renderer_force_max_clock.GetValue() && device.ShouldBoostClocks()) {'
    $policy = @'
    // Switch 2 titles can create hundreds of ASTC textures. On sub-12-GiB cards, decoding
    // those to uncompressed RGBA8 can force the texture collector into an eviction/redecode
    // loop. Keep explicit user BC choices intact; EDEN_NX2_KEEP_ASTC=1 also opts out.
    const char* keep_astc = std::getenv("EDEN_NX2_KEEP_ASTC");
    const bool keep_uncompressed_astc = keep_astc != nullptr && keep_astc[0] == '1';
    constexpr u64 Nx2UncompressedAstcMinimumVram = 12ULL * 1024ULL * 1024ULL * 1024ULL;
    if (Tegra::g_nx2_ampere.load(std::memory_order_relaxed) &&
        !device.IsOptimalAstcSupported() && !keep_uncompressed_astc &&
        Settings::values.astc_recompression.GetValue() ==
            Settings::AstcRecompression::Uncompressed &&
        device.GetDeviceLocalMemory() < Nx2UncompressedAstcMinimumVram) {
        LOG_INFO(Render_Vulkan,
                 "Switch 2 program with {} MiB of video memory: ASTC textures are re-compressed "
                 "to BC3 for this session (uncompressed ASTC needs 12 GiB or more). Set "
                 "EDEN_NX2_KEEP_ASTC=1 to keep them uncompressed",
                 device.GetDeviceLocalMemory() >> 20);
        Settings::values.astc_recompression.SetValue(Settings::AstcRecompression::Bc3);
    }

'@
    $text = Replace-Once $text $anchor ($policy + $anchor) 'RendererVulkan max-clock anchor'
    Write-Utf8 $path $text
}

$check = Read-Lf $path
foreach ($needle in @(
    '#include <cstdlib>',
    '#include "video_core/nx2.h"',
    'Tegra::g_nx2_ampere.load(std::memory_order_relaxed)',
    '!device.IsOptimalAstcSupported()',
    'constexpr u64 Nx2UncompressedAstcMinimumVram = 12ULL * 1024ULL * 1024ULL * 1024ULL;',
    'device.GetDeviceLocalMemory() < Nx2UncompressedAstcMinimumVram',
    'EDEN_NX2_KEEP_ASTC',
    $policyMarker
)) {
    if (-not $check.Contains($needle)) { throw "Runtime-v8 ASTC policy regression: missing $needle" }
}

Write-Host 'Added Switch 2 low-VRAM ASTC policy: sub-12-GiB Vulkan cards use BC3 unless explicitly overridden.'

# Task/Mesh layer B: stage identities and Vulkan flags, deliberately outside legacy indexing.
$runtimeV9Script = Join-Path $PSScriptRoot 'apply-ns2-runtime-blockers-v9.ps1'
& $runtimeV9Script

# Task/Mesh layer C: reject the new stages in the remaining legacy GLASM EmitContext switch.
$runtimeV10Script = Join-Path $PSScriptRoot 'apply-ns2-runtime-blockers-v10.ps1'
& $runtimeV10Script

git diff -- $path
