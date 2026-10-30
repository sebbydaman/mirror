$ErrorActionPreference = "Stop"

# Build from the newer nx2-experimental merge that contains the Mario Kart World
# sparse-region, sparse-layer and per-layer ASTC upload work. The workflow still
# checks out the older known-good source first; switch before applying any local
# patches so the rest of the patch chain is layered on this exact source commit.
$targetBase = "01effa81ab0e151f8cfd674bf4da952d24645943"
$currentBase = (git rev-parse HEAD).Trim()
if ($currentBase -ne $targetBase) {
    Write-Host "Switching Eglantine base $currentBase -> $targetBase"
    git fetch --depth=1 origin $targetBase
    if ($LASTEXITCODE -ne 0) { throw "Could not fetch Eglantine base $targetBase" }
    git checkout --detach $targetBase
    if ($LASTEXITCODE -ne 0) { throw "Could not checkout Eglantine base $targetBase" }
}
$actualBase = (git rev-parse HEAD).Trim()
if ($actualBase -ne $targetBase) { throw "Unexpected Eglantine base: $actualBase" }
Write-Host "Using Eglantine sparse/ASTC base: $actualBase"

$amperePath = "src/shader_recompiler/frontend/ampere/lower_to_maxwell.h"
$ampereText = Get-Content $amperePath -Raw

# Keep Eglantine's broader TLD4/TMML/general texture coverage, but restore our
# bindless TEX path, extended TXQ mask/binding handling, generalized BRX base
# translation, and geometry OUT lowering.

# Bindless 2D/cube TEX.B (SM70+ opcode 0x361).
if (-not $ampereText.Contains('case 0x361: { // TEX.B, scalar bindless 2D/cube implicit-LOD sample')) {
    $needle = '        case 0xb60: { // TEX, scalar 2D implicit-LOD sample'
    if (-not $ampereText.Contains($needle)) { throw "Could not locate Eglantine TEX insertion point" }
    $block = @'
        case 0x361: { // TEX.B, scalar bindless 2D/cube implicit-LOD sample
            const u32 mask = insn.Bits(72, 4);
            const u32 second_dest = insn.Bits(64, 8);
            const u32 coord_reg = insn.Bits(24, 8);
            const u32 meta_reg = insn.Bits(32, 8);
            const u32 dimension = insn.Bits(61, 3);
            const bool cube = dimension == 3;
            const bool split = second_dest != 255;
            const u32 channels = (mask & 1U) + ((mask >> 1) & 1U) +
                                 ((mask >> 2) & 1U) + ((mask >> 3) & 1U);
            if (!insn.Bits(59, 1) || !insn.Bits(60, 1) || (dimension != 1 && !cube) ||
                mask == 0 || insn.Bits(76, 5) || insn.Bits(81, 3) != 7 ||
                insn.Bits(87, 3) || insn.Bits(91, 1) ||
                coord_reg >= (cube ? 248U : 250U) || meta_reg >= 250 ||
                dest == 255 || channels > (split ? 4U : 2U) ||
                (channels > 1 && (dest >= 254 || (dest & 1))) ||
                (split && (second_dest >= 254 || (channels > 2 && (second_dest & 1))))) {
                return fail(index, "native bindless 2D/cube texture mode");
            }
            emit(0xde80000000000000ULL | predicate | 250 |
                 (u64{coord_reg} << 8) | (u64{meta_reg} << 20) |
                 (u64{cube ? 6U : 2U} << 28) | (u64{mask} << 31) |
                 (u64{insn.Bits(90, 1)} << 49));
            const std::array<u32, 4> targets{
                static_cast<u32>(dest), static_cast<u32>(dest) + 1,
                second_dest, second_dest == 255 ? 255U : second_dest + 1};
            for (u32 packed = 0; packed < channels; ++packed) {
                if (targets[packed] != 255) {
                    emit(0x5c98000000000000ULL | predicate | targets[packed] |
                         (u64{15} << 39) | (u64{250 + packed} << 20));
                }
            }
            break;
        }
'@
    $ampereText = $ampereText.Replace($needle, $block.TrimEnd("`r", "`n") + "`n" + $needle)
    Write-Host "Added bindless 2D/cube TEX.B lowering on Eglantine."
}

# Extend Eglantine TXQ from binding 2 / XY-only masks to all descriptor buffers
# 0..17 and packed X/Y/Z/mip-count outputs.
$txqPattern = '(?s)        case 0xb6f: \{ // TXQ texture dimensions, two packed scalar outputs\..*?            break;\r?\n        \}'
$txqReplacement = @'
        case 0xb6f: { // TXQ texture dimensions, packed X/Y/Z/mip-count outputs.
            const u32 binding = insn.Bits(54, 5);
            const u32 mask = insn.Bits(72, 4);
            const u32 outputs = (mask & 1U) + ((mask >> 1) & 1U) +
                                ((mask >> 2) & 1U) + ((mask >> 3) & 1U);
            if (insn.Bits(59, 5) || insn.Bits(64, 8) != 255 || mask == 0 ||
                insn.Bits(76, 14) || insn.Bits(91, 1) || binding >= 18 ||
                insn.Bits(40, 14) > 0x1fff || (dest & 1) || dest + outputs > 246)
                return fail(index, "native texture dimension query mode");
            if (result.required_texture_buffer != ~0U && result.required_texture_buffer != binding)
                return fail(index, "native texture descriptor buffer conflict");
            result.required_texture_buffer = binding;
            emit(0xdf48000000000000ULL | predicate | dest | (u64{insn.Bits(24, 8)} << 8) |
                 (u64{1} << 22) | (u64{mask} << 31) | (u64{insn.Bits(40, 14)} << 36) |
                 (u64{insn.Bits(90, 1)} << 49));
            break;
        }
'@
if ($ampereText.Contains('case 0xb6f: { // TXQ texture dimensions, two packed scalar outputs.')) {
    $newText = [regex]::Replace($ampereText, $txqPattern, $txqReplacement.TrimEnd("`r", "`n"), 1)
    if ($newText -eq $ampereText) { throw "Could not replace Eglantine TXQ block" }
    $ampereText = $newText
    Write-Host "Extended Eglantine TXQ dimension queries."
}

# Generalize Eglantine BRX/BRXU: preserve the native relative base instead of
# requiring it to collapse to native PC zero.
$brxPattern = '(?s)        case 0x949: case 0x958: \{ // Captured BRX / BRXU with absolute native-PC table values.*?            break;\r?\n        \}'
$brxReplacement = @'
        case 0x949: case 0x958: { // Captured BRX / BRXU with native-PC jump-table values
            if (insn.Bits(12, 4) != 7 || (insn.words[2] & ~0x3ffffU) != (opcode == 0x958 ? 0x0b800000U : 0x03800000U))
                return fail(index, "native computed branch mode");
            const u64 raw = insn.words[1] | (u64{insn.words[2] & 0x3ffff} << 32);
            const s64 relative = static_cast<s64>(raw << 14) >> 14;
            const s64 native_base = s64{index} * 16 + 16 + relative;
            const s64 lowered_pc = s64{address_of(static_cast<u32>(result.instructions.size()))};
            const s64 offset = native_base - lowered_pc - 8;
            if (offset < -0x800000 || offset > 0x7fffff)
                return fail(index, "native computed branch range");
            const u32 source = opcode == 0x958 ? uniform_register(insn.Bits(24, 8)) : insn.Bits(24, 8);
            if (source == ~0U) return fail(index, "native uniform computed branch source");
            emit(0xe25000000000000fULL | predicate | (u64{source} << 8) |
                 ((static_cast<u64>(offset) & 0xffffff) << 20));
            break;
        }
'@
if ($ampereText.Contains('case 0x949: case 0x958: { // Captured BRX / BRXU with absolute native-PC table values')) {
    $newText = [regex]::Replace($ampereText, $brxPattern, $brxReplacement.TrimEnd("`r", "`n"), 1)
    if ($newText -eq $ampereText) { throw "Could not replace Eglantine BRX block" }
    $ampereText = $newText
    Write-Host "Generalized Eglantine BRX/BRXU relative-base lowering."
}

# Geometry OUT immediate stream form: EMIT / EMIT_THEN_CUT.
if (-not $ampereText.Contains('case 0x924: { // OUT, immediate geometry stream')) {
    $needle = '        case 0x949: case 0x958: { // Captured BRX / BRXU with native-PC jump-table values'
    if (-not $ampereText.Contains($needle)) { throw "Could not locate BRX insertion point for geometry OUT" }
    $block = @'
        case 0x924: { // OUT, immediate geometry stream: EMIT / EMIT_THEN_CUT
            const u32 stream = insn.words[1];
            const u32 mode = insn.Bits(78, 2);
            if (stream > 3 || (mode != 1 && mode != 3) ||
                insn.Bits(64, 14) || insn.Bits(80, 25) || insn.Bits(126, 2)) {
                return fail(index, "native geometry OUT immediate mode");
            }
            mov_imm(250, stream);
            emit(0xfbe0000000000000ULL | predicate | dest |
                 (u64{insn.Bits(24, 8)} << 8) | (u64{250} << 20) |
                 (u64{1} << 39) | (u64{mode == 3} << 40));
            break;
        }
'@
    $ampereText = $ampereText.Replace($needle, $block.TrimEnd("`r", "`n") + "`n" + $needle)
    Write-Host "Added geometry OUT lowering on Eglantine."
}

Set-Content -Path $amperePath -Value $ampereText -Encoding utf8 -NoNewline

# Reuse the validated geometry-stage admission patch. The selected NX2 base still
# has the same native stage guard as the previous baseline.
$geometryScript = Join-Path $PSScriptRoot "apply-ns2-geometry-stage.ps1"
& $geometryScript

git diff -- src/shader_recompiler/frontend/ampere/lower_to_maxwell.h src/video_core/shader_environment.cpp
