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

# -----------------------------------------------------------------------------
# PokeDinner 2.0 batch: correctness + shader lifetime + MKW predicate fold.
# Keep these source-verified fixes together so one CI cycle exercises the batch.
# -----------------------------------------------------------------------------

# 2.0 session correctness: sparse-region written-state is global and must not leak into the next
# game launched in the same Eden process. Otherwise the next title can classify an image as
# unwritten and create it without backing memory.
$nx2Path = 'src/video_core/nx2.h'
$nx2 = Read-Lf $nx2Path
if (-not $nx2.Contains('inline void Nx2ClearSparseRegions()')) {
    $oldSparse = @'
inline void Nx2SparseRegionDestroyed(u64 gpu_address) {
    std::scoped_lock lk{g_nx2_sparse_state_mutex};
    g_nx2_sparse_state.erase(gpu_address);
}

inline void Nx2SparseBlockWritten(u64 region_address, u64 block) {
'@
    $newSparse = @'
inline void Nx2SparseRegionDestroyed(u64 gpu_address) {
    std::scoped_lock lk{g_nx2_sparse_state_mutex};
    g_nx2_sparse_state.erase(gpu_address);
}

/// A new emulation session: the previous game's regions are gone (nvdrv's Module clears them).
inline void Nx2ClearSparseRegions() {
    std::scoped_lock lk{g_nx2_sparse_state_mutex};
    g_nx2_sparse_state.clear();
}

inline void Nx2SparseBlockWritten(u64 region_address, u64 block) {
'@
    $nx2 = Replace-Once $nx2 $oldSparse $newSparse 'PokeDinner 2.0 sparse-session reset helper'
    Write-Utf8 $nx2Path $nx2
}

$nvdrvPath = 'src/core/hle/service/nvdrv/nvdrv.cpp'
$nvdrv = Read-Lf $nvdrvPath
if (-not $nvdrv.Contains('Tegra::Nx2ClearSparseRegions();')) {
    $nvdrv = Replace-Once $nvdrv `
        '    Tegra::Nx2ClearSemaphoreRegions();' `
        "    Tegra::Nx2ClearSemaphoreRegions();`n    Tegra::Nx2ClearSparseRegions();" `
        'PokeDinner 2.0 nvdrv sparse-session reset'
    Write-Utf8 $nvdrvPath $nvdrv
}

# 2.0 shader-lifetime correctness/performance: ObjectPool::Storage intentionally has an empty
# destructor, so destroying Storage skipped the live T destructors and leaked per-shader owned
# allocations (notably phi operand lists). Destroy each live object itself.
$poolPath = 'src/shader_recompiler/object_pool.h'
$pool = Read-Lf $poolPath
if (-not $pool.Contains('std::destroy_at(&storage[index].object);')) {
    $oldPool = @'
        void Release() {
            std::destroy_n(storage.get(), used_objects);
            used_objects = 0;
        }
'@
    $newPool = @'
        // Destroy the objects themselves: Storage's destructor is empty on purpose (the union
        // also holds unused slots), so destroying Storage would skip T's destructor and leak
        // what IR instructions own (for example phi operand lists).
        void Release() {
            for (size_t index = 0; index < used_objects; ++index) {
                std::destroy_at(&storage[index].object);
            }
            used_objects = 0;
        }
'@
    $pool = Replace-Once $pool $oldPool $newPool 'PokeDinner 2.0 shader ObjectPool lifetime fix'
    Write-Utf8 $poolPath $pool
}

# Mario Kart World / NVIDIA correctness from the 2.0-era shader work. Predicate masks merged
# through selects/phis can reach SMax32 as max(x,-x); recognize the proven -1/0/1 domain and
# lower it to x&1 instead of handing the problematic expression to the driver.
$constPath = 'src/shader_recompiler/ir_opt/constant_propagation_pass.cpp'
$const = Read-Lf $constPath
if (-not $const.Contains('u32 MaskValues(const IR::Value& value, u32 depth = 0)')) {
    $oldFold = @'
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
    $newFold = @'
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
    $const = Replace-Once $const $oldFold $newFold 'PokeDinner 2.0 MKW predicate-mask fold'
    Write-Utf8 $constPath $const
}

# #113 compile blocker: GLSL is another legacy backend with no Task/Mesh execution model. Make the
# shared Stage enum exhaustive, but reject these stages explicitly rather than fabricating GLSL
# semantics. Runtime-v9 adds the enum identities later in this same patch chain.
$glslPath = 'src/shader_recompiler/backend/glsl/glsl_emit_context.cpp'
$glsl = Read-Lf $glslPath
if (-not $glsl.Contains('#include "shader_recompiler/exception.h"')) {
    $glsl = Replace-Once $glsl `
        '#include "shader_recompiler/backend/glsl/glsl_emit_context.h"' `
        "#include `"shader_recompiler/backend/glsl/glsl_emit_context.h`"`n#include `"shader_recompiler/exception.h`"" `
        'GLSL exception include'
}
if (-not $glsl.Contains('GLSL does not support shader stage')) {
    $oldGlsl = @'
    case Stage::Compute:
        stage_name = "cs";
        const u32 local_x{(std::max)(program.workgroup_size[0], 1u)};
        const u32 local_y{(std::max)(program.workgroup_size[1], 1u)};
        const u32 local_z{(std::max)(program.workgroup_size[2], 1u)};
        header += fmt::format("layout(local_size_x={},local_size_y={},local_size_z={}) in;",
                              local_x, local_y, local_z);
        break;
    }
    SetupOutPerVertex(*this, header);
'@
    $newGlsl = @'
    case Stage::Compute:
        stage_name = "cs";
        const u32 local_x{(std::max)(program.workgroup_size[0], 1u)};
        const u32 local_y{(std::max)(program.workgroup_size[1], 1u)};
        const u32 local_z{(std::max)(program.workgroup_size[2], 1u)};
        header += fmt::format("layout(local_size_x={},local_size_y={},local_size_z={}) in;",
                              local_x, local_y, local_z);
        break;
    case Stage::Task:
    case Stage::Mesh:
        throw InvalidArgument("GLSL does not support shader stage {}", program.stage);
    }
    SetupOutPerVertex(*this, header);
'@
    $glsl = Replace-Once $glsl $oldGlsl $newGlsl '#113 GLSL Task/Mesh exhaustive-stage guard'
    Write-Utf8 $glslPath $glsl
}

# Batch regression guards: validate every PokeDinner 2.0 piece before runtime-v9/v10 continue.
$nx2Check = Read-Lf $nx2Path
$nvdrvCheck = Read-Lf $nvdrvPath
$poolCheck = Read-Lf $poolPath
$constCheck = Read-Lf $constPath
$glslCheck = Read-Lf $glslPath
foreach ($needle in @(
    'inline void Nx2ClearSparseRegions()',
    'g_nx2_sparse_state.clear();'
)) {
    if (-not $nx2Check.Contains($needle)) { throw "PokeDinner 2.0 sparse reset regression: missing $needle" }
}
if (-not $nvdrvCheck.Contains('Tegra::Nx2ClearSparseRegions();')) {
    throw 'PokeDinner 2.0 sparse reset regression: nvdrv reset call missing'
}
if (-not $poolCheck.Contains('std::destroy_at(&storage[index].object);')) {
    throw 'PokeDinner 2.0 ObjectPool regression: live-object destruction missing'
}
foreach ($needle in @(
    'u32 MaskValues(const IR::Value& value, u32 depth = 0)',
    'case IR::Opcode::Phi:',
    'ir.BitwiseAnd(IR::U32{value}, ir.Imm32(1))'
)) {
    if (-not $constCheck.Contains($needle)) { throw "PokeDinner 2.0 predicate fold regression: missing $needle" }
}
foreach ($needle in @(
    '#include "shader_recompiler/exception.h"',
    'case Stage::Task:',
    'case Stage::Mesh:',
    'throw InvalidArgument("GLSL does not support shader stage {}", program.stage);'
)) {
    if (-not $glslCheck.Contains($needle)) { throw "#113 GLSL regression: missing $needle" }
}

Write-Host 'Applied PokeDinner 2.0 batch: sparse session reset, shader pool lifetime fix, MKW predicate fold, and #113 GLSL Task/Mesh guard.'

# Task/Mesh layer B: stage identities and Vulkan flags, deliberately outside legacy indexing.
$runtimeV9Script = Join-Path $PSScriptRoot 'apply-ns2-runtime-blockers-v9.ps1'
& $runtimeV9Script

# Task/Mesh layer C: reject the new stages in the remaining legacy GLASM EmitContext switch.
$runtimeV10Script = Join-Path $PSScriptRoot 'apply-ns2-runtime-blockers-v10.ps1'
& $runtimeV10Script

git diff -- $path $nx2Path $nvdrvPath $poolPath $constPath $glslPath
