$ErrorActionPreference = "Stop"

# Bananza reaches gameplay with HUD/audio/input alive but the world clear-colour only.
# PokeDinner 2.0 now implements several of the originally captured failure modes with newer,
# broader source shapes. Preserve those donor implementations and only add semantics that are
# genuinely still missing instead of requiring the old Eglantine spelling.
$amperePath = "src/shader_recompiler/frontend/ampere/lower_to_maxwell.h"
$text = Get-Content $amperePath -Raw

# -----------------------------------------------------------------------------
# B82 LDC: width 0 is the 32-bit form. Legacy Eglantine admitted only 4/5;
# PokeDinner 2.0's width > 5 guard already admits 0..5 and therefore supersedes this patch.
# -----------------------------------------------------------------------------
$oldB82 = '            if ((width != 4 && width != 5) || insn.Bits(78, 2) || insn.Bits(91, 1) ||'
$newB82 = '            if ((width != 0 && width != 4 && width != 5) || insn.Bits(78, 2) || insn.Bits(91, 1) ||'
$donorB82 = '            if (width > 5 || insn.Bits(78, 2) || insn.Bits(91, 1) ||'
if ($text.Contains($oldB82)) {
    $text = $text.Replace($oldB82, $newB82)
    Write-Host "Added native B82 32-bit indexed constant-load lowering."
} elseif ($text.Contains($newB82)) {
    Write-Host "B82 32-bit indexed constant-load lowering already present."
} elseif ($text.Contains('case 0xb82: { // LDC, 8 to 64 bits, indexed byte offset') -and $text.Contains($donorB82)) {
    Write-Host "PokeDinner 2.0 B82 lowering already admits the 32-bit width=0 form."
} else {
    throw "Could not verify B82 indexed constant-load width semantics"
}

# -----------------------------------------------------------------------------
# VOTEU: legacy code guarded the raw target number. PokeDinner 2.0 instead validates through
# uniform_register(), whose mapping covers UR0..UR27. Both forms satisfy Bananza's UR16 case.
# -----------------------------------------------------------------------------
$oldVote = '            if ((target >= 16 && target != 63) || insn.words[1] ||'
$newVote = '            if ((target >= 28 && target != 63) || insn.words[1] ||'
$donorVote = '            if (uniform_register(target) == ~0U || insn.words[1] ||'
if ($text.Contains($oldVote)) {
    $text = $text.Replace($oldVote, $newVote)
    Write-Host "Extended native VOTEU target range through UR27."
} elseif ($text.Contains($newVote)) {
    Write-Host "Extended native VOTEU target range already present."
} elseif ($text.Contains('case 0x886: { // VOTEU ballot and independent uniform predicate output.') -and
        $text.Contains($donorVote) -and $text.Contains('if (reg < 28) return 218 + reg;')) {
    Write-Host "PokeDinner 2.0 VOTEU already validates through the UR0..UR27 mapping."
} else {
    throw "Could not verify VOTEU UR16+ target semantics"
}

# -----------------------------------------------------------------------------
# F2I: preserve the legacy patch path, but recognize PokeDinner 2.0's newer implementation.
# The donor explicitly classifies the 32-bit family and emits bits 78..79 as Maxwell rounding.
# -----------------------------------------------------------------------------
$nearest = '            const bool nearest = (mode & ~0x10100U) == 0x00203000;'
$word = '            const bool word = (mode & ~0x1c100U) == 0x00203000;'
if (-not $text.Contains($word)) {
    if (-not $text.Contains($nearest)) { throw "Could not locate F2I 32-bit mode classification" }
    $text = $text.Replace($nearest, $nearest + "`n" + '            // 32-bit result with RN/RM/RP/RZ in bits 78..79.' + "`n" + $word)
}

$oldF2IReject = '            if ((!half && !small && !floor && !nearest && !byte && !short_word && (mode & ~0x100U) != 0x0021f000) ||'
$newF2IReject = '            if ((!half && !small && !floor && !nearest && !word && !byte && !short_word && (mode & ~0x100U) != 0x0021f000) ||'
$donorF2IReject = '            if ((!half && !small && !word && !byte && !short_word) ||'
if ($text.Contains($oldF2IReject)) {
    $text = $text.Replace($oldF2IReject, $newF2IReject)
} elseif (-not $text.Contains($newF2IReject) -and -not $text.Contains($donorF2IReject)) {
    throw "Could not verify F2I rejection guard after 32-bit mode classification"
}

$oldRound = '                 (u64{small || nearest ? 0U : floor ? 1U : 3U} << 39) | (u64{insn.Bits(80, 1)} << 44));'
$newRound = '                 (u64{word ? insn.Bits(78, 2) : small || nearest ? 0U : floor ? 1U : 3U} << 39) | (u64{insn.Bits(80, 1)} << 44));'
$donorRound = '                 (u64{insn.Bits(78, 2)} << 39) | (u64{insn.Bits(80, 1)} << 44));'
if ($text.Contains($oldRound)) {
    $text = $text.Replace($oldRound, $newRound)
} elseif (-not $text.Contains($newRound) -and -not $text.Contains($donorRound)) {
    throw "Could not verify F2I 32-bit rounding encoding"
}
Write-Host "Native 32-bit F2I rounding-family lowering is present."

# -----------------------------------------------------------------------------
# MUFU uniform-source D08. PokeDinner 2.0 already includes D08 and an extra 0x908 form.
# Preserve the older Bananza operation-9 allowance where still needed, adapting the donor's
# newer modifiers guard rather than replacing its operand handling.
# -----------------------------------------------------------------------------
$oldUniformUse = 'op == 0x2a5 || op == 0xd06 || op == 0x299'
$newUniformUse = 'op == 0x2a5 || op == 0xd06 || op == 0xd08 || op == 0x299'
if ($text.Contains($oldUniformUse)) {
    $text = $text.Replace($oldUniformUse, $newUniformUse)
} elseif (-not $text.Contains($newUniformUse)) {
    throw "Could not verify uniform-bank detection for D08"
}

$oldMufuCase = '        case 0x308: case 0xb08: { // MUFU'
$newMufuCase = '        case 0x308: case 0xb08: case 0xd08: { // MUFU'
$donorMufuCase = '        case 0x308: case 0x908: case 0xb08: case 0xd08: { // MUFU'
if ($text.Contains($oldMufuCase)) {
    $text = $text.Replace($oldMufuCase, $newMufuCase)
} elseif (-not $text.Contains($newMufuCase) -and -not $text.Contains($donorMufuCase)) {
    throw "Could not verify D08 MUFU lowering case"
}

$legacyMufuGuard = '            if (operation > 8 || operation == 6 || operation == 7 || insn.Bits(80, 12)) return fail(index, "native MUFU mode");'
$legacyMufuGuardNew = @'
            if (operation > 9 || (operation == 9 && insn.Bits(73, 1)) || operation == 6 || operation == 7 || insn.Bits(80, 11) ||
                (opcode == 0xd08 ? !insn.Bits(91, 1) || (insn.words[1] & ~0xc00000ffU) != 0 : insn.Bits(91, 1) != 0))
                return fail(index, "native MUFU mode");
'@
$legacyMufuGuardNew = $legacyMufuGuardNew.TrimEnd("`r", "`n")
$donorMufuGuard = '            if (operation > 8 || operation == 6 || operation == 7 || modifiers) return fail(index, "native MUFU mode");'
$donorMufuGuardNew = '            if (operation > 9 || (operation == 9 && insn.Bits(73, 1)) || operation == 6 || operation == 7 || modifiers) return fail(index, "native MUFU mode");'
if ($text.Contains($legacyMufuGuard)) {
    $text = $text.Replace($legacyMufuGuard, $legacyMufuGuardNew)
} elseif ($text.Contains($donorMufuGuard)) {
    $text = $text.Replace($donorMufuGuard, $donorMufuGuardNew)
} elseif (-not $text.Contains('operation > 9 || (operation == 9 && insn.Bits(73, 1))')) {
    throw "Could not verify MUFU operation-9 compatibility guard"
}
Write-Host "Native D08 uniform-source MUFU lowering and operation-9 compatibility are present."

Set-Content -Path $amperePath -Value $text -Encoding utf8 -NoNewline

# Semantic regression checks that accept both the validated legacy lowering and the broader
# PokeDinner 2.0 implementation.
$check = Get-Content $amperePath -Raw
$b82Ok = $check.Contains('(width != 0 && width != 4 && width != 5)') -or
         ($check.Contains('case 0xb82: { // LDC, 8 to 64 bits, indexed byte offset') -and $check.Contains($donorB82))
$voteOk = $check.Contains('(target >= 28 && target != 63)') -or
          ($check.Contains('case 0x886: { // VOTEU ballot and independent uniform predicate output.') -and
           $check.Contains($donorVote) -and $check.Contains('if (reg < 28) return 218 + reg;'))
$f2iOk = $check.Contains($word) -and ($check.Contains($newRound) -or $check.Contains($donorRound))
$mufuOk = ($check.Contains($newMufuCase) -or $check.Contains($donorMufuCase)) -and
          $check.Contains($newUniformUse) -and
          $check.Contains('operation > 9 || (operation == 9 && insn.Bits(73, 1))')
if (-not $b82Ok) { throw 'Bananza blue-screen regression: B82 32-bit form missing' }
if (-not $voteOk) { throw 'Bananza blue-screen regression: VOTEU UR16+ mapping missing' }
if (-not $f2iOk) { throw 'Bananza blue-screen regression: F2I 32-bit rounding family missing' }
if (-not $mufuOk) { throw 'Bananza blue-screen regression: D08/operation-9 MUFU support missing' }

Write-Host "Bananza blue-screen GPU compatibility applied and validated."
git diff -- src/shader_recompiler/frontend/ampere/lower_to_maxwell.h
