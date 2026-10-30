$ErrorActionPreference = "Stop"

# Bananza reaches gameplay with HUD/audio/input alive but the world clear-colour only.
# The captured log shows repeated pixel-shader rejection for 32-bit indexed LDC (B82),
# plus UR16 VOTEU, a 32-bit F2I rounding form, and uniform-source MUFU. Port only
# semantics already present in the newer Bananza-capable Eden-NS2 lowering path.

$amperePath = "src/shader_recompiler/frontend/ampere/lower_to_maxwell.h"
$text = Get-Content $amperePath -Raw

# -----------------------------------------------------------------------------
# LDC indexed constant load: admit the 32-bit width=0 form.
# This is the dominant blue-screen failure in the captured gameplay log.
# -----------------------------------------------------------------------------
$oldB82 = '            if ((width != 4 && width != 5) || insn.Bits(78, 2) || insn.Bits(91, 1) ||'
$newB82 = '            if ((width != 0 && width != 4 && width != 5) || insn.Bits(78, 2) || insn.Bits(91, 1) ||'
if ($text.Contains($oldB82)) {
    $text = $text.Replace($oldB82, $newB82)
    Write-Host "Added native B82 32-bit indexed constant-load lowering."
} elseif (-not $text.Contains($newB82)) {
    throw "Could not locate B82 indexed constant-load width guard"
}

# -----------------------------------------------------------------------------
# VOTEU: Eglantine's uniform register mapping already covers UR0..UR27, but the
# old guard only admitted UR0..UR15. Bananza's rejected shader writes UR16.
# -----------------------------------------------------------------------------
$oldVote = '            if ((target >= 16 && target != 63) || insn.words[1] ||'
$newVote = '            if ((target >= 28 && target != 63) || insn.words[1] ||'
if ($text.Contains($oldVote)) {
    $text = $text.Replace($oldVote, $newVote)
    Write-Host "Extended native VOTEU target range through UR27."
} elseif (-not $text.Contains($newVote)) {
    throw "Could not locate VOTEU target guard"
}

# -----------------------------------------------------------------------------
# F2I: accept the regular 32-bit result family whose rounding mode is encoded
# in bits 78..79. The captured 0x0020b000 control word normalizes to 0x00203000.
# This runs after apply-bananza-post-menu-gpu.ps1, which added byte/short forms.
# -----------------------------------------------------------------------------
$nearest = '            const bool nearest = (mode & ~0x10100U) == 0x00203000;'
$word = '            const bool word = (mode & ~0x1c100U) == 0x00203000;'
if (-not $text.Contains($word)) {
    if (-not $text.Contains($nearest)) { throw "Could not locate F2I mode classification" }
    $text = $text.Replace($nearest, $nearest + "`n" + '            // 32-bit result with RN/RM/RP/RZ in bits 78..79.' + "`n" + $word)
}
$oldF2IReject = '            if ((!half && !small && !floor && !nearest && !byte && !short_word && (mode & ~0x100U) != 0x0021f000) ||'
$newF2IReject = '            if ((!half && !small && !floor && !nearest && !word && !byte && !short_word && (mode & ~0x100U) != 0x0021f000) ||'
if ($text.Contains($oldF2IReject)) {
    $text = $text.Replace($oldF2IReject, $newF2IReject)
} elseif (-not $text.Contains($newF2IReject)) {
    throw "Could not locate F2I rejection guard after byte/short patch"
}
$oldRound = '                 (u64{small || nearest ? 0U : floor ? 1U : 3U} << 39) | (u64{insn.Bits(80, 1)} << 44));'
$newRound = '                 (u64{word ? insn.Bits(78, 2) : small || nearest ? 0U : floor ? 1U : 3U} << 39) | (u64{insn.Bits(80, 1)} << 44));'
if ($text.Contains($oldRound)) {
    $text = $text.Replace($oldRound, $newRound)
} elseif (-not $text.Contains($newRound)) {
    throw "Could not locate F2I rounding encoding"
}
Write-Host "Added native 32-bit F2I rounding-family lowering."

# -----------------------------------------------------------------------------
# MUFU uniform-source form (D08). The logged Bananza encodings use form 6,
# source UR8/UR7/UR6 and satisfy the newer reference's validation exactly.
# Reserve the uniform bank before lowering so scratch registers cannot alias it.
# -----------------------------------------------------------------------------
$oldUniformUse = 'op == 0x2a5 || op == 0xd06 || op == 0x299'
$newUniformUse = 'op == 0x2a5 || op == 0xd06 || op == 0xd08 || op == 0x299'
if ($text.Contains($oldUniformUse)) {
    $text = $text.Replace($oldUniformUse, $newUniformUse)
} elseif (-not $text.Contains($newUniformUse)) {
    throw "Could not extend uniform-bank detection for D08"
}
$oldMufuCase = '        case 0x308: case 0xb08: { // MUFU'
$newMufuCase = '        case 0x308: case 0xb08: case 0xd08: { // MUFU'
if ($text.Contains($oldMufuCase)) {
    $text = $text.Replace($oldMufuCase, $newMufuCase)
} elseif (-not $text.Contains($newMufuCase)) {
    throw "Could not locate MUFU lowering case"
}
$oldMufuGuard = '            if (operation > 8 || operation == 6 || operation == 7 || insn.Bits(80, 12)) return fail(index, "native MUFU mode");'
$newMufuGuard = @'
            if (operation > 9 || (operation == 9 && insn.Bits(73, 1)) || operation == 6 || operation == 7 || insn.Bits(80, 11) ||
                (opcode == 0xd08 ? !insn.Bits(91, 1) || (insn.words[1] & ~0xc00000ffU) != 0 : insn.Bits(91, 1) != 0))
                return fail(index, "native MUFU mode");
'@.TrimEnd("`r", "`n")
if ($text.Contains($oldMufuGuard)) {
    $text = $text.Replace($oldMufuGuard, $newMufuGuard)
} elseif (-not $text.Contains('opcode == 0xd08 ? !insn.Bits(91, 1)')) {
    throw "Could not locate MUFU validation guard"
}
Write-Host "Added native D08 uniform-source MUFU lowering."

Set-Content -Path $amperePath -Value $text -Encoding utf8 -NoNewline

# Exact regression markers for the blue-screen workload.
$check = Get-Content $amperePath -Raw
foreach ($needle in @(
    '(width != 0 && width != 4 && width != 5)',
    '(target >= 28 && target != 63)',
    'const bool word = (mode & ~0x1c100U) == 0x00203000;',
    'case 0x308: case 0xb08: case 0xd08: { // MUFU',
    'op == 0xd06 || op == 0xd08 || op == 0x299'
)) {
    if (-not $check.Contains($needle)) { throw "Bananza blue-screen regression: missing $needle" }
}

Write-Host "Bananza blue-screen GPU patch applied and validated."
git diff -- src/shader_recompiler/frontend/ampere/lower_to_maxwell.h
