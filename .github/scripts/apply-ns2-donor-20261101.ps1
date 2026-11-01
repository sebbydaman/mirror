$ErrorActionPreference = 'Stop'

# Small, independently-understood fixes collected after the PokeDinner 2.0 / Eglantine integration.
# Keep this as a targeted post-integration layer rather than rebasing the whole donor tree: the
# current branch has newer command-coherency and GPU-split work that must not be overwritten.

function Replace-Exact {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Old,
        [Parameter(Mandatory = $true)][string]$New,
        [Parameter(Mandatory = $true)][string]$Marker,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $text = Get-Content $Path -Raw
    if ($text.Contains($Marker)) {
        Write-Host "[PRESENT] $Name"
        return
    }
    if (-not $text.Contains($Old)) {
        throw "Donor fix '$Name' no longer matches $Path"
    }
    $updated = $text.Replace($Old, $New)
    [IO.File]::WriteAllText((Resolve-Path $Path), $updated, [Text.UTF8Encoding]::new($false))
    Write-Host "[APPLIED] $Name"
}

# 1) Shader object-pool lifetime: destroy T, not the empty union wrapper. This fixes accumulated
# allocations owned by IR instructions (notably phi operands) across repeated shader builds.
$objectPool = 'src/shader_recompiler/object_pool.h'
$objectOld = @'
        void Release() {
            std::destroy_n(storage.get(), used_objects);
            used_objects = 0;
        }
'@
$objectNew = @'
        // Storage's destructor is intentionally empty because the union also represents unused
        // slots. Destroy the live object itself so IR-owned allocations do not leak per shader.
        void Release() {
            for (size_t index = 0; index < used_objects; ++index) {
                std::destroy_at(&storage[index].object);
            }
            used_objects = 0;
        }
'@
Replace-Exact $objectPool $objectOld $objectNew 'std::destroy_at(&storage[index].object);' 'shader object-pool destructor/lifetime fix'

# 2) AMD shader correctness: native registers read before any write behave as zero for the NX2
# shaders observed by the donor. Keep a rollback switch because this changes undefined-value policy.
$undef = 'src/shader_recompiler/backend/spirv/emit_spirv_undefined.cpp'
$undefOld = @'
// SPDX-FileCopyrightText: Copyright 2021 yuzu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "shader_recompiler/backend/spirv/emit_spirv_instructions.h"
#include "shader_recompiler/backend/spirv/spirv_emit_context.h"

namespace Shader::Backend::SPIRV {

Id EmitUndefU1(EmitContext& ctx) {
    return ctx.OpUndef(ctx.U1);
}

Id EmitUndefU8(EmitContext&) {
    throw NotImplementedException("SPIR-V Instruction");
}

Id EmitUndefU16(EmitContext&) {
    throw NotImplementedException("SPIR-V Instruction");
}

Id EmitUndefU32(EmitContext& ctx) {
    return ctx.OpUndef(ctx.U32[1]);
}

Id EmitUndefU64(EmitContext&) {
    throw NotImplementedException("SPIR-V Instruction");
}

} // namespace Shader::Backend::SPIRV
'@
$undefNew = @'
// SPDX-FileCopyrightText: Copyright 2026 Eden Emulator Project
// SPDX-License-Identifier: GPL-3.0-or-later

// SPDX-FileCopyrightText: Copyright 2021 yuzu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include <cstdlib>

#include "shader_recompiler/backend/spirv/emit_spirv_instructions.h"
#include "shader_recompiler/backend/spirv/spirv_emit_context.h"

namespace Shader::Backend::SPIRV {
namespace {
bool UndefIsZero() {
    static const bool zero = [] {
        const char* const value = std::getenv("EDEN_NX2_UNDEF_ZERO");
        return value == nullptr || value[0] != '0';
    }();
    return zero;
}
} // Anonymous namespace

Id EmitUndefU1(EmitContext& ctx) {
    return UndefIsZero() ? ctx.false_value : ctx.OpUndef(ctx.U1);
}

Id EmitUndefU8(EmitContext&) {
    throw NotImplementedException("SPIR-V Instruction");
}

Id EmitUndefU16(EmitContext&) {
    throw NotImplementedException("SPIR-V Instruction");
}

Id EmitUndefU32(EmitContext& ctx) {
    return UndefIsZero() ? ctx.u32_zero_value : ctx.OpUndef(ctx.U32[1]);
}

Id EmitUndefU64(EmitContext&) {
    throw NotImplementedException("SPIR-V Instruction");
}

} // namespace Shader::Backend::SPIRV
'@
Replace-Exact $undef $undefOld $undefNew 'EDEN_NX2_UNDEF_ZERO' 'AMD undefined-register zeroing with rollback switch'

# 3) Ampere RET correctness. RET's bits 16..23 are reserved; they are not a destination-register
# write. Treating them as one rejects valid R0-link shaders and loses text in Mario Kart World.
$ampere = 'src/shader_recompiler/frontend/ampere/lower_to_maxwell.h'
Replace-Exact $ampere `
    '            if (active_link && insn.Bits(16, 8) == *active_link)' `
    '            if (active_link && opcode != 0x950 && insn.Bits(16, 8) == *active_link)' `
    'active_link && opcode != 0x950' `
    'Ampere RET reserved-destination/link-register fix'

# 4) FSEL is floating-point and its two sources retain .NEG/.ABS modifiers. Bitwise SEL must keep
# the old integer behavior. This improves effects such as MKW drifting/tricking without collapsing.
$fselOld = @'
        case 0x207: case 0x807: case 0xa07:
        case 0x208: case 0x808: case 0xa08: { // Bitwise SEL / FSEL
            const u32 a = operand(0, false), b = operand(1, false);
            emit(base(0x5ca0000000000000ULL) | (u64{a} << 8) | (u64{b} << 20) |
                (u64{insn.Bits(87, 3)} << 39) | (u64{insn.Bits(90, 1)} << 42));
            break;
        }
'@
$fselNew = @'
        case 0x207: case 0x807: case 0xa07: { // Bitwise SEL
            const u32 a = operand(0, false), b = operand(1, false);
            emit(base(0x5ca0000000000000ULL) | (u64{a} << 8) | (u64{b} << 20) |
                (u64{insn.Bits(87, 3)} << 39) | (u64{insn.Bits(90, 1)} << 42));
            break;
        }
        case 0x208: case 0x808: case 0xa08: { // FSEL: the sources keep their .NEG/.ABS
            const u32 a = operand(0), b = operand(1);
            emit(base(0x5ca0000000000000ULL) | (u64{a} << 8) | (u64{b} << 20) |
                (u64{insn.Bits(87, 3)} << 39) | (u64{insn.Bits(90, 1)} << 42));
            break;
        }
'@
Replace-Exact $ampere $fselOld $fselNew 'FSEL: the sources keep their .NEG/.ABS' 'Ampere FSEL source modifier preservation'

# 5) NVIDIA device-loss avoidance for predicate masks. Guest compilers form abs(mask) as
# max(x, -x), sometimes after merging masks through selects/phis. If x can only be -1/0/1,
# lower the expression to x & 1 instead of leaving the problematic SMax form for the driver.
$constProp = 'src/shader_recompiler/ir_opt/constant_propagation_pass.cpp'
$foldOld = @'
void FoldSMax32(IR::Block& block, IR::Inst& inst) {
    for (size_t index = 0; index < 2; ++index) {
        const IR::Value value{inst.Arg(index).Resolve()};
        const IR::Inst* const negation{inst.Arg(1 - index).TryInstRecursive()};
        if (!negation || negation->GetOpcode() != IR::Opcode::INeg32 ||
            negation->Arg(0).Resolve() != value) {
            continue;
        }
        const IR::Inst* const select{value.TryInstRecursive()};
        if (!select || select->GetOpcode() != IR::Opcode::SelectU32) {
            continue;
        }
        const IR::Value true_value{select->Arg(1).Resolve()};
        const IR::Value false_value{select->Arg(2).Resolve()};
        const auto is_mask = [](const IR::Value& candidate) {
            return candidate.IsImmediate() &&
                   (candidate.U32() == 0 || candidate.U32() == 1 ||
                    candidate.U32() == 0xffffffffU);
        };
        if (!is_mask(true_value) || !is_mask(false_value)) {
            continue;
        }
        // max(x, -x) is 0 or 1 for boolean and predicate-mask constants.
        IR::IREmitter ir{block, IR::Block::InstructionList::s_iterator_to(inst)};
        inst.ReplaceUsesWith(ir.Select(IR::U1{select->Arg(0)},
                                      ir.Imm32(true_value.U32() != 0 ? 1U : 0U),
                                      ir.Imm32(false_value.U32() != 0 ? 1U : 0U)));
        return;
    }
}
'@
$foldNew = @'
/// Values a predicate mask can take, as bits for -1 (1), 0 (2) and 1 (4); 0 when it can take any
/// other value. Follows the selects, negations, +/-1 and phis guest compilers build masks from.
u32 MaskValues(const IR::Value& value, u32 depth = 0) {
    constexpr u32 minus_one{1}, zero{2}, one{4};
    const IR::Value resolved{value.Resolve()};
    if (resolved.IsImmediate()) {
        if (resolved.Type() != IR::Type::U32) {
            return 0;
        }
        switch (resolved.U32()) {
        case 0xffffffffU:
            return minus_one;
        case 0:
            return zero;
        case 1:
            return one;
        default:
            return 0;
        }
    }
    if (depth >= 8) {
        return 0;
    }
    const IR::Inst* const inst{resolved.InstRecursive()};
    switch (inst->GetOpcode()) {
    case IR::Opcode::SelectU32: {
        const u32 true_values{MaskValues(inst->Arg(1), depth + 1)};
        const u32 false_values{MaskValues(inst->Arg(2), depth + 1)};
        return true_values != 0 && false_values != 0 ? true_values | false_values : 0;
    }
    case IR::Opcode::INeg32: {
        const u32 values{MaskValues(inst->Arg(0), depth + 1)};
        return (values & zero) | ((values & minus_one) << 2) | ((values & one) >> 2);
    }
    case IR::Opcode::IAdd32:
        for (size_t index = 0; index < 2; ++index) {
            const IR::Value step{inst->Arg(1 - index).Resolve()};
            if (!step.IsImmediate()) {
                continue;
            }
            const u32 values{MaskValues(inst->Arg(index), depth + 1)};
            if (step.U32() == 1 && (values & one) == 0) {
                return values << 1;
            }
            if (step.U32() == 0xffffffffU && (values & minus_one) == 0) {
                return values >> 1;
            }
            return 0;
        }
        return 0;
    case IR::Opcode::Phi: {
        u32 values{};
        for (size_t index = 0; index < inst->NumArgs(); ++index) {
            const u32 arg_values{MaskValues(inst->Arg(index), depth + 1)};
            if (arg_values == 0) {
                return 0;
            }
            values |= arg_values;
        }
        return values;
    }
    default:
        return 0;
    }
}

void FoldSMax32(IR::Block& block, IR::Inst& inst) {
    const auto is_mask = [](const IR::Value& candidate) {
        return candidate.IsImmediate() &&
               (candidate.U32() == 0 || candidate.U32() == 1 || candidate.U32() == 0xffffffffU);
    };
    for (size_t index = 0; index < 2; ++index) {
        const IR::Value value{inst.Arg(index).Resolve()};
        const IR::Inst* const negation{inst.Arg(1 - index).TryInstRecursive()};
        if (!negation || negation->GetOpcode() != IR::Opcode::INeg32 ||
            negation->Arg(0).Resolve() != value) {
            continue;
        }
        IR::IREmitter ir{block, IR::Block::InstructionList::s_iterator_to(inst)};
        const IR::Inst* const select{value.TryInstRecursive()};
        if (select && select->GetOpcode() == IR::Opcode::SelectU32 &&
            is_mask(select->Arg(1).Resolve()) && is_mask(select->Arg(2).Resolve())) {
            const IR::Value true_value{select->Arg(1).Resolve()};
            const IR::Value false_value{select->Arg(2).Resolve()};
            inst.ReplaceUsesWith(ir.Select(IR::U1{select->Arg(0)},
                                           ir.Imm32(true_value.U32() != 0 ? 1U : 0U),
                                           ir.Imm32(false_value.U32() != 0 ? 1U : 0U)));
            return;
        }
        if (MaskValues(value) != 0) {
            inst.ReplaceUsesWith(ir.BitwiseAnd(IR::U32{value}, ir.Imm32(1)));
            return;
        }
    }
}
'@
Replace-Exact $constProp $foldOld $foldNew 'u32 MaskValues(const IR::Value& value' 'predicate-mask SMax folding / Special Cup device-loss fix'

# 6) Switch 2 ASTC policy. 12-16 GiB cards can still thrash badly with uncompressed ASTC; keep
# session-only BC3 recompression enabled below 20 GiB. EDEN_NX2_KEEP_ASTC=1 remains the override.
$vkTexture = 'src/video_core/renderer_vulkan/vk_texture_cache.cpp'
$vkText = Get-Content $vkTexture -Raw
if ($vkText.Contains('memory >= 20_GiB')) {
    Write-Host '[PRESENT] Switch 2 20 GiB ASTC/BC3 threshold'
} elseif ($vkText.Contains('memory >= 12_GiB')) {
    $vkText = $vkText.Replace('memory >= 12_GiB', 'memory >= 20_GiB')
    $vkText = $vkText.Replace('uncompressed ASTC needs a 12 GiB budget', 'uncompressed ASTC needs a 20 GiB budget')
    [IO.File]::WriteAllText((Resolve-Path $vkTexture), $vkText, [Text.UTF8Encoding]::new($false))
    Write-Host '[APPLIED] Switch 2 20 GiB ASTC/BC3 threshold'
} else {
    throw 'Switch 2 ASTC policy was expected after the late-runtime patch, but no 12/20 GiB threshold was found'
}

git diff --check
if ($LASTEXITCODE -ne 0) {
    throw 'November donor fix batch introduced whitespace/diff errors'
}

Write-Host 'Applied targeted November NX2 donor batch: shader lifetime + AMD undef + RET/FSEL + predicate-mask driver fix + 20 GiB ASTC policy.'
