$ErrorActionPreference = "Stop"

# Keep the compatibility/build fixes that produced the green #24 executable
# isolated from newer runtime experiments. This makes each new shader/GPU fix
# easy to bisect or revert without disturbing the proven foundation.
$baseScript = Join-Path $PSScriptRoot "apply-ns2-build-fixes-base.ps1"
if (-not (Test-Path $baseScript)) {
    throw "Missing preserved NS2 compatibility patch base: $baseScript"
}
& $baseScript

# SM70-SM90 bindless TEX uses opcode 0x361 (.B) instead of the cbuf descriptor
# opcode 0xb60. Lower the conservative scalar 2D/cube implicit-LOD subset to
# Maxwell TEX_b, whose frontend already consumes the texture handle from the
# metadata register. Mesa NAK packs non-array cube sampling as three consecutive
# coordinates in src0 and the bindless handle in src1, matching TEX_b's cube
# layout. Sample into scratch registers first, then scatter the packed selected
# channels back to the native split destinations. Unsupported texture modes keep
# failing instead of being approximated.
$amperePath = "src/shader_recompiler/frontend/ampere/lower_to_maxwell.h"
$ampereText = Get-Content $amperePath -Raw
if (-not $ampereText.Contains('case 0x361:')) {
    $bindlessNeedle = '        case 0xb60: { // TEX, scalar 2D implicit-LOD sample'
    if (-not $ampereText.Contains($bindlessNeedle)) {
        throw "Could not locate native TEX insertion point for bindless sampling"
    }

    $bindlessBlock = @'
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
            // Maxwell TEX_b: coord base in bits 8..15, bindless handle/meta base in
            // bits 20..27, texture type in bits 28..30, and packed selected channels.
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

    $ampereText = $ampereText.Replace(
        $bindlessNeedle,
        $bindlessBlock.TrimEnd("`r", "`n") + "`n" + $bindlessNeedle)
    Set-Content -Path $amperePath -Value $ampereText -Encoding utf8 -NoNewline
    Write-Host "Added conservative native bindless 2D/cube TEX lowering."
} else {
    Write-Host "Native bindless 2D/cube TEX lowering already present."
}

# Broaden the native TXQ dimension-query lowering. The baseline only accepts a
# fixed XY query from descriptor buffer 2. Maxwell TXQ already supports a 4-bit
# component mask (X/Y/Z/mip-count), so preserve the native mask, validate the
# packed destination span, and accept any descriptor buffer the existing
# environment can bind. Keep descriptor-buffer conflicts explicit.
$ampereText = Get-Content $amperePath -Raw
$oldTxq = @'
        case 0xb6f: { // TXQ texture dimensions, two packed scalar outputs.
            if (insn.Bits(59, 5) || insn.Bits(64, 8) != 255 || insn.Bits(72, 4) != 3 ||
                insn.Bits(76, 14) || insn.Bits(91, 1) || insn.Bits(54, 5) != 2 ||
                insn.Bits(40, 14) > 0x1fff || (dest & 1) || dest >= 254)
                return fail(index, "native texture dimension query mode");
            result.required_texture_buffer = 2;
            emit(0xdf48000000000000ULL | predicate | dest | (u64{insn.Bits(24, 8)} << 8) |
                 (u64{1} << 22) | (u64{3} << 31) | (u64{insn.Bits(40, 14)} << 36) |
                 (u64{insn.Bits(90, 1)} << 49));
            break;
        }
'@
$newTxq = @'
        case 0xb6f: { // TXQ texture dimensions, packed X/Y/Z/mip-count outputs.
            const u32 binding = insn.Bits(54, 5);
            const u32 mask = insn.Bits(72, 4);
            const u32 outputs = (mask & 1U) + ((mask >> 1) & 1U) +
                                ((mask >> 2) & 1U) + ((mask >> 3) & 1U);
            if (insn.Bits(59, 5) || insn.Bits(64, 8) != 255 || mask == 0 ||
                insn.Bits(76, 14) || insn.Bits(91, 1) || binding >= 18 ||
                insn.Bits(40, 14) > 0x1fff || (dest & 1) || dest + outputs > 250)
                return fail(index, "native texture dimension query mode");
            if (result.required_texture_buffer != ~0U &&
                result.required_texture_buffer != binding)
                return fail(index, "native texture descriptor buffer conflict");
            result.required_texture_buffer = binding;
            emit(0xdf48000000000000ULL | predicate | dest | (u64{insn.Bits(24, 8)} << 8) |
                 (u64{1} << 22) | (u64{mask} << 31) | (u64{insn.Bits(40, 14)} << 36) |
                 (u64{insn.Bits(90, 1)} << 49));
            break;
        }
'@
if ($ampereText.Contains($oldTxq)) {
    $ampereText = $ampereText.Replace($oldTxq, $newTxq)
    Set-Content -Path $amperePath -Value $ampereText -Encoding utf8 -NoNewline
    Write-Host "Extended native TXQ dimension-query lowering."
} elseif ($ampereText.Contains('case 0xb6f: { // TXQ texture dimensions, packed X/Y/Z/mip-count outputs.')) {
    Write-Host "Extended native TXQ dimension-query lowering already present."
} else {
    throw "Could not locate baseline native TXQ dimension-query lowering"
}

# Turing/Ampere TLD4 texture gather. The 0x2593 cross-game baseline does not
# implement opcode 0xb63. This conservative 2D cbuf-descriptor subset matches
# STORM's generic lowering and Mesa NAK's SM70 encoding. Unsupported modes keep
# failing normally rather than being guessed or silently misrendered.
$ampereText = Get-Content $amperePath -Raw
if (-not $ampereText.Contains('case 0xb63:')) {
    $tld4Needle = '        case 0x816: { // Captured PRMT half-word concatenation'
    if (-not $ampereText.Contains($tld4Needle)) {
        throw "Could not locate PRMT insertion point for native TLD4"
    }

    $tld4Block = @'
        case 0xb63: { // TLD4, 2D gather of one component into split RG/BA destinations: TLD4S
            const u32 second_dest = insn.Bits(64, 8), mask = insn.Bits(72, 4);
            const bool partial = mask != 15;
            if (!insn.Bits(60, 1) || insn.Bits(61, 3) != 1 || mask == 0 ||
                insn.Bits(76, 3) || insn.Bits(81, 3) != 7 || insn.Bits(59, 1) ||
                insn.Bits(40, 14) > 0x1fff || insn.Bits(54, 5) >= 18 ||
                dest >= 254 || second_dest >= 254 ||
                (partial && (insn.Bits(79, 1) || dest == 255)) ||
                insn.Bits(24, 8) >= 250 || insn.Bits(32, 8) >= 250) {
                return fail(index, "native gather mode or descriptor binding");
            }
            if (result.required_texture_buffer != ~0U &&
                result.required_texture_buffer != insn.Bits(54, 5)) {
                return fail(index, "native texture descriptor buffer conflict");
            }
            result.required_texture_buffer = insn.Bits(54, 5);
            emit(0xdf00000000000000ULL | predicate | (partial ? 250 : dest) |
                 (u64{insn.Bits(24, 8)} << 8) | (u64{insn.Bits(79, 1)} << 55) |
                 (u64{insn.Bits(32, 8)} << 20) |
                 (u64{partial ? 252 : second_dest} << 28) |
                 (u64{insn.Bits(40, 14)} << 36) |
                 (u64{insn.Bits(90, 1)} << 49) |
                 (u64{insn.Bits(87, 2)} << 52));
            if (partial) {
                const std::array<u32, 4> targets{
                    static_cast<u32>(dest), static_cast<u32>(dest) + 1,
                    second_dest, second_dest == 255 ? 255U : second_dest + 1};
                u32 next = 0;
                for (u32 component = 0; component < 4; ++component) {
                    if (!(mask & (1U << component))) {
                        continue;
                    }
                    if (targets[next] != 255) {
                        emit(0x5c98000000000000ULL | predicate | targets[next] |
                             (u64{15} << 39) | (u64{250 + component} << 20));
                    }
                    ++next;
                }
            }
            break;
        }
'@

    $ampereText = $ampereText.Replace(
        $tld4Needle,
        $tld4Block.TrimEnd("`r", "`n") + "`n" + $tld4Needle)
    Set-Content -Path $amperePath -Value $ampereText -Encoding utf8 -NoNewline
    Write-Host "Added native TLD4 2D texture-gather lowering."
} else {
    Write-Host "Native TLD4 texture-gather lowering already present."
}

git diff -- src/shader_recompiler/frontend/ampere/lower_to_maxwell.h
