$ErrorActionPreference = 'Stop'
# Targeted Star Fox rendering repair. Source: zortos293/Lichii build70
# 286117c7e0d89ab0384e896489128fdd88a424f8,
# src/shader_recompiler/frontend/ampere/lower_to_maxwell.h, case 0xf6c.
# 2026-11-04 Star Fox log contains 13 rejected native 0xf6c TXD.B graphics shaders.
# This ports ONLY the guarded native uniform-gradient lowering, not a donor fork.
function Edit-Unique([string]$Path, [string]$Old, [string]$New, [string]$Name) {
    $eol = [string][char]13 + [string][char]10
    $lf = [string][char]10
    $raw = [IO.File]::ReadAllText((Resolve-Path $Path).Path).Replace($eol, $lf)
    $oldNorm = $Old.Replace($eol, $lf).TrimEnd([char[]]@([char]13, [char]10))
    $newNorm = $New.Replace($eol, $lf).TrimEnd([char[]]@([char]13, [char]10))
    if ($raw.Contains($newNorm)) { Write-Host "[ALREADY] $Name"; return }
    $at = $raw.IndexOf($oldNorm, [StringComparison]::Ordinal)
    if ($at -lt 0 -or $raw.IndexOf($oldNorm, $at + $oldNorm.Length, [StringComparison]::Ordinal) -ge 0) {
        throw "Non-unique Orchid shader anchor ($Name); refusing to overwrite"
    }
    $updated = $raw.Substring(0, $at) + $newNorm + $raw.Substring($at + $oldNorm.Length)
    [IO.File]::WriteAllText((Resolve-Path $Path).Path, $updated, [Text.UTF8Encoding]::new($false))
    Write-Host "[PORT] $Name"
}
$path = 'src/shader_recompiler/frontend/ampere/lower_to_maxwell.h'
if (-not (Test-Path $path -PathType Leaf)) { throw "Missing Orchid shader lowering: $path" }
# Reserve uniform registers for this opcode before the translator encounters it.
Edit-Unique $path 'op == 0xf60 || (op == 0x81c &&' 'op == 0xf60 || op == 0xf6c || (op == 0x81c &&' 'Native gradient uses uniform register bank'
# A TXD gradient has a second GPR source even without the general source-mode bit.
Edit-Unique $path 'opcode != 0x988) continue;' 'opcode != 0x988 && opcode != 0xf6c) continue;' 'Native gradient tracks derivative GPR range'
$anchor = '        case 0xb6c: { // TXD 2D or ARRAY_2D, four channels; the two destination pairs anywhere.'
$port = @'
        case 0xf6c: { // Lichii build70: uniform-handle TXD.B, 2D/ARRAY_2D.
            const u32 handle = uniform_register(insn.Bits(40, 6));
            const u32 coordinates = insn.Bits(24, 8), derivatives = insn.Bits(32, 8);
            const u32 dimension = insn.Bits(61, 3), second_dest = insn.Bits(64, 8);
            const u32 mask = insn.Bits(72, 4), channels = static_cast<u32>(std::popcount(mask));
            // Orchid reserves R180-R214 for high uniform registers; never overlap them.
            const u32 register_limit = high_uniform_bank ? 180U : 216U;
            if ((dimension != 1 && dimension != 5) || insn.Bits(46, 15) ||
                (insn.words[2] & ~0x04000fffU) != 0x081e0000U || mask == 0 ||
                (insn.words[3] & 0xc00001ffU) || handle == ~0U || handle == 255 ||
                coordinates + (dimension == 5 ? 3U : 2U) > register_limit ||
                derivatives + 4 > register_limit ||
                dest + (std::min)(channels, 2U) > register_limit || (channels > 1 && (dest & 1)) ||
                (channels > 2 ? second_dest != 255 &&
                    (second_dest + channels - 2 > register_limit ||
                     (channels == 4 && (second_dest & 1)) ||
                     (second_dest < dest + 2 && dest < second_dest + channels - 2))
                              : second_dest != 255))
                return fail(index, "native uniform gradient texture mode");
            // Maxwell TXD.B takes its bindless handle and coordinates in the leading registers.
            emit(0x5c98000000000000ULL | predicate | 248 | (u64{15} << 39) | (u64{handle} << 20));
            for (u32 i = 0; i < (dimension == 5 ? 3U : 2U); ++i)
                emit(0x5c98000000000000ULL | predicate | (249 + i) | (u64{15} << 39) |
                     (u64{coordinates + i} << 20));
            emit(0xde40000000000000ULL | predicate | 248 | (u64{248} << 8) |
                 (u64{derivatives} << 20) | (u64{dimension == 5 ? 3U : 2U} << 28) |
                 (u64{mask} << 31) | (u64{insn.Bits(90, 1)} << 49) | (u64{7} << 51));
            for (u32 i = 0; i < channels; ++i) {
                if (i >= 2 && second_dest == 255) break;
                emit(0x5c98000000000000ULL | predicate | (i < 2 ? dest + i : second_dest + i - 2) |
                     (u64{15} << 39) | (u64{248 + i} << 20));
            }
            break;
        }
'@
Edit-Unique $path $anchor ($port + [string][char]10 + $anchor) 'Star Fox native 0xf6c gradient'
foreach ($required in @('case 0xf6c:', '0xde40000000000000ULL', 'opcode != 0x988 && opcode != 0xf6c', 'op == 0xf60 || op == 0xf6c')) {
    if (-not (Select-String -Path $path -SimpleMatch $required -Quiet)) {
        throw "Star Fox native gradient invariant missing: $required"
    }
}
if (-not (Select-String -Path 'src/shader_recompiler/frontend/maxwell/maxwell.inc' -SimpleMatch 'INST(TXD_b,' -Quiet)) {
    throw 'Orchid Maxwell TXD.B backend missing; do not lower native 0xf6c'
}
git diff --check -- $path
if ($LASTEXITCODE -ne 0) { throw 'Star Fox gradient lowering source diff check failed' }
Write-Host '[PASS] Star Fox 0xf6c source repair staged, with full register and encoding guards; C++/gameplay not yet verified'
