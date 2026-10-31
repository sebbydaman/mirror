$ErrorActionPreference = 'Stop'

# Reapply sebbydaman/mirror's native Ampere-to-Maxwell extensions after taking a donor
# lower_to_maxwell.h wholesale for a conflict resolution. Keep this idempotent so it can be
# safely used after future PokeDinner native-lowering updates without duplicating cases.
$path = 'src/shader_recompiler/frontend/ampere/lower_to_maxwell.h'
$text = Get-Content $path -Raw

# Bindless 2D/cube TEX.B (SM70+ opcode 0x361).
if (-not $text.Contains('case 0x361: { // TEX.B, scalar bindless 2D/cube implicit-LOD sample')) {
    $needle = '        case 0xb60: { // TEX, scalar 2D implicit-LOD sample'
    if (-not $text.Contains($needle)) { throw 'Could not locate TEX.B overlay insertion point' }
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
    $text = $text.Replace($needle, $block.TrimEnd("`r", "`n") + "`n" + $needle)
    Write-Host 'Restored bindless 2D/cube TEX.B overlay.'
}

# Extended TXQ: descriptor buffers 0..17 and X/Y/Z/mip-count masks.
if (-not $text.Contains('case 0xb6f: { // TXQ texture dimensions, packed X/Y/Z/mip-count outputs.')) {
    $pattern = '(?s)        case 0xb6f: \{ // TXQ texture dimensions, two packed scalar outputs\..*?            break;\r?\n        \}'
    $replacement = @'
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
    $newText = [regex]::Replace($text, $pattern, $replacement.TrimEnd("`r", "`n"), 1)
    if ($newText -eq $text) { throw 'Could not restore extended TXQ overlay' }
    $text = $newText
    Write-Host 'Restored extended TXQ overlay.'
}

# Generalized BRX/BRXU native-PC relative base.
if (-not $text.Contains('case 0x949: case 0x958: { // Captured BRX / BRXU with native-PC jump-table values')) {
    $pattern = '(?s)        case 0x949: case 0x958: \{ // Captured BRX / BRXU with absolute native-PC table values.*?            break;\r?\n        \}'
    $replacement = @'
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
    $newText = [regex]::Replace($text, $pattern, $replacement.TrimEnd("`r", "`n"), 1)
    if ($newText -eq $text) { throw 'Could not restore generalized BRX/BRXU overlay' }
    $text = $newText
    Write-Host 'Restored generalized BRX/BRXU overlay.'
}

# Geometry OUT immediate stream form: EMIT / EMIT_THEN_CUT. Newer donor lowerings may already
# provide opcode 0x924, including grouped switch labels such as `case X: case 0x924:`. Opcode
# identity, not formatting/comment/source shape, is the idempotence boundary. Match the label
# anywhere in the switch line so grouped donor labels are recognized too.
if (-not [regex]::IsMatch($text, '\bcase\s+0x924\s*:')) {
    $needle = '        case 0x949: case 0x958: { // Captured BRX / BRXU with native-PC jump-table values'
    if (-not $text.Contains($needle)) { throw 'Could not locate geometry OUT overlay insertion point' }
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
    $text = $text.Replace($needle, $block.TrimEnd("`r", "`n") + "`n" + $needle)
    Write-Host 'Restored geometry OUT overlay.'
} else {
    Write-Host 'Geometry OUT opcode 0x924 already present; preserving existing donor lowering.'
}

Set-Content -Path $path -Value $text -Encoding utf8 -NoNewline
Write-Host 'Native lowering overlays are present.'
