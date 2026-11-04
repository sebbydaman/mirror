$ErrorActionPreference = 'Stop'
# Pinned donors: Eglantine build212 77952c8d8c, 9279b24e4c; Lichii build70 0aabd552a2.
# Do not apply any unverified PokeDinner binary patch over the newer Orchid source.
function Edit-Exact([string]$Path, [string]$Old, [string]$New, [string]$Name) {
    $eol = [string][char]13 + [string][char]10
    $lf = [string][char]10
    $raw = [IO.File]::ReadAllText((Resolve-Path $Path).Path).Replace($eol, $lf)
    $oldNorm = $Old.Replace($eol, $lf).TrimEnd([char[]]@([char]13, [char]10))
    $newNorm = $New.Replace($eol, $lf).TrimEnd([char[]]@([char]13, [char]10))
    if ($raw.Contains($newNorm)) { Write-Host "[ALREADY] $Name"; return }
    $i = $raw.IndexOf($oldNorm, [StringComparison]::Ordinal)
    if ($i -lt 0 -or $raw.IndexOf($oldNorm, $i + $oldNorm.Length, [StringComparison]::Ordinal) -ge 0) {
        throw "Anchor missing or ambiguous ($Name); refusing to overwrite Orchid semantics"
    }
    $next = $raw.Substring(0, $i) + $newNorm + $raw.Substring($i + $oldNorm.Length)
    [IO.File]::WriteAllText((Resolve-Path $Path).Path, $next, [Text.UTF8Encoding]::new($false))
    Write-Host "[PORTED] $Name"
}
$shader = 'src/shader_recompiler/frontend/ampere/lower_to_maxwell.h'
$oldHalf = @'
            if (insn.Bits(86, 1)) { // H0_NH1: negate only the upper packed component.
                if (b.swizzle != 0 || b.absolute || b.reg >= 250)
                    return fail(index, "native half mixed-sign source mode");
                emit(0x0400000000000000ULL | predicate | 251 | (u64{b.reg} << 8) |
                     (u64{0x80000000} << 20) | (u64{2} << 53));
                b.reg = 251;
            }
'@
$newHalf = @'
            if (insn.Bits(86, 1)) {
                if (b.swizzle != 0 || b.absolute || b.reg >= 250)
                    return fail(index, "native half mixed-sign source mode");

                // Eglantine build-212: H0_NH1 swaps the FP16 halves and negates the new low half.
                emit(0x36f8000000000000ULL | predicate | 251 | (u64{b.reg} << 8) |
                     (u64{16} << 20) | (u64{b.reg} << 39));
                emit(0x0400000000000000ULL | predicate | 251 | (u64{251} << 8) |
                     (u64{0x8000} << 20) | (u64{2} << 53));
                b.reg = 251;
            }
'@
Edit-Exact $shader $oldHalf $newHalf 'Eglantine-212 mixed-sign half source'
$nup = 'src/core/file_sys/nup_container.cpp'
$oldNup = @'
    if (exefs_dir_cache[package_index] == nullptr) {
        exefs_dir_cache[package_index] = BuildPackageDir(packages[package_index].exefs_dir);
    }
    return exefs_dir_cache[package_index];
'@
$newNup = @'
    if (exefs_dir_cache[package_index] == nullptr) {
        auto dir = BuildPackageDir(packages[package_index].exefs_dir);
        if (dir->GetFiles().empty() && dir->GetSubdirectories().empty()) {
            // Eglantine build-212: contentless ExeFS is not a valid Switch 1 program.
            return nullptr;
        }
        exefs_dir_cache[package_index] = std::move(dir);
    }
    return exefs_dir_cache[package_index];
'@
Edit-Exact $nup $oldNup $newNup 'Eglantine-212 contentless NUP ExeFS'
$pos = 'src/shader_recompiler/ir_opt/position_pass.cpp'
$oldHelper = @'
using PositionInstVector = boost::container::small_vector<PositionInst, 24>;
} // Anonymous namespace
'@
$newHelper = @'
using PositionInstVector = boost::container::small_vector<PositionInst, 24>;

/// Lichii build-70: a phi is float-derived only if every incoming operand is a float bit pattern.
bool IsFloatBits(const IR::Value& value, int depth) {
    const IR::Inst* const inst = value.TryInstRecursive();
    if (!inst) {
        return false;
    }
    if (inst->GetOpcode() == IR::Opcode::BitCastU32F32) {
        return true;
    }
    if (inst->GetOpcode() != IR::Opcode::Phi || depth == 4) {
        return false;
    }
    for (size_t arg = 0; arg < inst->NumArgs(); ++arg) {
        if (!IsFloatBits(inst->Arg(arg), depth + 1)) {
            return false;
        }
    }
    return true;
}
} // Anonymous namespace
'@
Edit-Exact $pos $oldHelper $newHelper 'Lichii-70 Kirby float-phi predicate'
$oldDither = @'
    if (!reads_nonzero_word) {
        return;
    }
    bool used{};
'@
$newDither = @'
    if (!reads_nonzero_word) {
        return;
    }
    // Lichii build-70: Kirby's SMAA resolve adds bank-17 dither bias to a phi
    // of float-encoded colors. Preserve Orchid's Fast Fusion HDR guard below.
    if (env.ShaderStage() == Stage::Fragment && env.HasNativeInstructions()) {
        for (IR::Block* const block : program.post_order_blocks) {
            for (IR::Inst& inst : block->Instructions()) {
                if (inst.GetOpcode() != IR::Opcode::BitCastF32U32) {
                    continue;
                }
                const IR::Inst* const arithmetic = inst.Arg(0).TryInstRecursive();
                if (!arithmetic || (arithmetic->GetOpcode() != IR::Opcode::IAdd32 &&
                                    arithmetic->GetOpcode() != IR::Opcode::ISub32)) {
                    continue;
                }
                for (size_t bias_arg = 0; bias_arg < 2; ++bias_arg) {
                    if (bias_arg == 0 && arithmetic->GetOpcode() == IR::Opcode::ISub32) {
                        continue;
                    }
                    const IR::Inst* const bias = arithmetic->Arg(bias_arg).TryInstRecursive();
                    if (!bias || bias->GetOpcode() != IR::Opcode::GetCbufU32 ||
                        !IsFloatBits(arithmetic->Arg(1 - bias_arg), 0) ||
                        !bias->Arg(0).IsImmediate() || bias->Arg(0).U32() != 17 ||
                        !bias->Arg(1).IsImmediate()) {
                        continue;
                    }
                    const u32 offset = bias->Arg(1).U32();
                    if (offset == 0x10 || offset == 0x14 || offset == 0x18) {
                        inst.SetArg(0, arithmetic->Arg(1 - bias_arg));
                        break;
                    }
                }
            }
        }
    }
    bool used{};
'@
Edit-Exact $pos $oldDither $newDither 'Lichii-70 Kirby SMAA dither through phi'
foreach ($pair in @(
    @($shader, 'H0_NH1 swaps the FP16 halves'),
    @($nup, 'GetFiles().empty() && dir->GetSubdirectories().empty()'),
    @($pos, 'IsFloatBits(arithmetic->Arg(1 - bias_arg), 0)'),
    @($pos, 'env.ShaderStage() == Stage::Fragment && inst.Arg(1).U32() < 0x30')
)) {
    if (-not (Select-String -Path $pair[0] -SimpleMatch $pair[1] -Quiet)) {
        throw "Missing post-integration invariant: $($pair[1])"
    }
}
git diff --check
if ($LASTEXITCODE -ne 0) { throw 'Donor ports introduced whitespace errors' }
Write-Host '[PASS] Verified Eglantine H0/NUP and Lichii Kirby shader ports; Fast Fusion HDR guard intact'
