$ErrorActionPreference = "Stop"

# Bananza reaches this surface after the startup/menu path: native F2I to byte/short
# destinations and compute shaders that bind storage-buffer slots above 15.
# Port the exact generic semantics from the Bananza-capable Eden-NS2 path without
# weakening shader validation or suppressing binding errors.

# -----------------------------------------------------------------------------
# Ampere native F2I: 8-bit / 16-bit destination modes
# -----------------------------------------------------------------------------
$amperePath = "src/shader_recompiler/frontend/ampere/lower_to_maxwell.h"
$ampereText = Get-Content $amperePath -Raw
$startNeedle = '        case 0x305: case 0xb05: case 0xd05: { // F2I NTZ, register/constant-buffer/uniform source'
$endNeedle = '        case 0xb6f:'
$start = $ampereText.IndexOf($startNeedle)
if ($start -lt 0) { throw "Could not locate native F2I lowering block" }
$end = $ampereText.IndexOf($endNeedle, $start)
if ($end -lt 0) { throw "Could not locate end of native F2I lowering block" }
$section = $ampereText.Substring($start, $end - $start)

if (-not $section.Contains('const bool byte = (mode & ~0x100U) == 0x0021e000;')) {
    $nearest = '            const bool nearest = (mode & ~0x10100U) == 0x00203000;'
    if (-not $section.Contains($nearest)) { throw "Could not locate F2I mode classification" }
    $section = $section.Replace(
        $nearest,
        $nearest + "`n" +
        '            // Destination size 0/1: truncate to 8/16-bit integer.' + "`n" +
        '            const bool byte = (mode & ~0x100U) == 0x0021e000;' + "`n" +
        '            const bool short_word = (mode & ~0x100U) == 0x0021e800;')

    $oldReject = '            if ((!half && !small && !floor && !nearest && (mode & ~0x100U) != 0x0021f000) ||'
    $newReject = '            if ((!half && !small && !floor && !nearest && !byte && !short_word && (mode & ~0x100U) != 0x0021f000) ||'
    if (-not $section.Contains($oldReject)) { throw "Could not locate F2I rejection guard" }
    $section = $section.Replace($oldReject, $newReject)

    $oldClamp = '                if (!small) {'
    $newClamp = '                if (!small && !byte && !short_word) {'
    if (-not $section.Contains($oldClamp)) { throw "Could not locate unsigned F2I clamp guard" }
    $section = $section.Replace($oldClamp, $newClamp)

    $oldWidth = '            emit(base(0x5cb0000000000000ULL) | (u64{small ? 1U : 2U} << 8) | (u64{2} << 10) |'
    $newWidth = '            emit(base(0x5cb0000000000000ULL) | (u64{byte ? 0U : small || short_word ? 1U : 2U} << 8) | (u64{2} << 10) |'
    if (-not $section.Contains($oldWidth)) { throw "Could not locate F2I destination-width encoding" }
    $section = $section.Replace($oldWidth, $newWidth)

    $oldUnsignedTail = '            if (!is_signed && !small) {'
    $newUnsignedTail = '            if (!is_signed && !small && !byte && !short_word) {'
    if (-not $section.Contains($oldUnsignedTail)) { throw "Could not locate unsigned F2I saturation tail" }
    $section = $section.Replace($oldUnsignedTail, $newUnsignedTail)

    $ampereText = $ampereText.Substring(0, $start) + $section + $ampereText.Substring($end)
    Set-Content -Path $amperePath -Value $ampereText -Encoding utf8 -NoNewline
    Write-Host "Added native F2I 8/16-bit destination lowering."
}

# -----------------------------------------------------------------------------
# Native compute storage buffers: indices 0..31
# -----------------------------------------------------------------------------
$bufferBasePath = "src/video_core/buffer_cache/buffer_cache_base.h"
$bufferBaseText = Get-Content $bufferBasePath -Raw
$oldCount = 'constexpr u32 NUM_STORAGE_BUFFERS = 16;'
$newCount = "// Native Switch 2 compute shaders bind more than 16 global-memory ranges; masks are u32.`nconstexpr u32 NUM_STORAGE_BUFFERS = 32;"
if ($bufferBaseText.Contains($oldCount)) {
    $bufferBaseText = $bufferBaseText.Replace($oldCount, $newCount)
    Set-Content -Path $bufferBasePath -Value $bufferBaseText -Encoding utf8 -NoNewline
    Write-Host "Expanded native compute storage-buffer capacity from 16 to 32."
} elseif (-not $bufferBaseText.Contains('constexpr u32 NUM_STORAGE_BUFFERS = 32;')) {
    throw "Unexpected storage-buffer capacity; refusing to patch blindly"
}

# -----------------------------------------------------------------------------
# Regression guards for the exact Bananza failure captured after Normal Mode.
# -----------------------------------------------------------------------------
$ampereCheck = Get-Content $amperePath -Raw
$bufferCheck = Get-Content $bufferBasePath -Raw
foreach ($needle in @(
    'const bool byte = (mode & ~0x100U) == 0x0021e000;',
    'const bool short_word = (mode & ~0x100U) == 0x0021e800;',
    'byte ? 0U : small || short_word ? 1U : 2U'
)) {
    if (-not $ampereCheck.Contains($needle)) { throw "Bananza post-menu regression: missing $needle" }
}
if (-not $bufferCheck.Contains('constexpr u32 NUM_STORAGE_BUFFERS = 32;')) {
    throw "Bananza post-menu regression: 32 storage buffers not enabled"
}

Write-Host "Bananza post-menu GPU patch applied and validated."

# The next gameplay phase can keep running with HUD/audio/input while world draws are skipped.
# Apply the exact shader forms captured in that blue-screen log after the byte/short F2I patch,
# because the follow-up extends this same F2I block.
$blueScreenScript = Join-Path $PSScriptRoot "apply-bananza-blue-screen-gpu.ps1"
& $blueScreenScript

git diff -- src/shader_recompiler/frontend/ampere/lower_to_maxwell.h `
            src/video_core/buffer_cache/buffer_cache_base.h
