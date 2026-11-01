$ErrorActionPreference = 'Stop'

# Keep the large batch's exact replacements deterministic across Windows CRLF checkouts.
# The batch normalizes C++ source to LF; PowerShell here-strings parsed on Windows otherwise keep
# CRLF, so normalize the helper's Old/New strings too before any multi-line comparison.
$batchScript = Join-Path $PSScriptRoot 'apply-ns2-general-compat-batch-v2.ps1'
$batch = Get-Content $batchScript -Raw
$helper = 'function Replace-Once([string]$Text, [string]$Old, [string]$New, [string]$Label) {'
$normalizedHelper = @'
function Replace-Once([string]$Text, [string]$Old, [string]$New, [string]$Label) {
    $Old = $Old.Replace("`r`n", "`n")
    $New = $New.Replace("`r`n", "`n")
'@.TrimEnd("`r", "`n")
if ($batch.Contains($helper) -and -not $batch.Contains('$Old = $Old.Replace("`r`n", "`n")')) {
    $batch = $batch.Replace($helper, $normalizedHelper)
    Set-Content -Path $batchScript -Value $batch -Encoding utf8 -NoNewline
    Write-Host 'Normalized multi-line PowerShell replacement anchors to LF.'
} elseif (-not $batch.Contains('$Old = $Old.Replace("`r`n", "`n")')) {
    throw 'Could not normalize Replace-Once helper in generalized batch'
}

# Runtime-v8 is the PokeDinner 2.0 multi-feature batch. It also reads C++ as LF while PowerShell
# here-strings are CRLF on the Windows runner. Normalize its replacement helper up front so all
# source-verified edits can be exercised in one build rather than failing on line-ending-only
# anchor mismatches.
$runtimeV8Script = Join-Path $PSScriptRoot 'apply-ns2-runtime-blockers-v8.ps1'
$runtimeV8 = Get-Content $runtimeV8Script -Raw
if ($runtimeV8.Contains($helper) -and -not $runtimeV8.Contains('$Old = $Old.Replace("`r`n", "`n")')) {
    $runtimeV8 = $runtimeV8.Replace($helper, $normalizedHelper)
    Set-Content -Path $runtimeV8Script -Value $runtimeV8 -Encoding utf8 -NoNewline
    Write-Host 'Normalized PokeDinner 2.0 runtime-v8 replacement anchors to LF.'
} elseif (-not $runtimeV8.Contains('$Old = $Old.Replace("`r`n", "`n")')) {
    throw 'Could not normalize Replace-Once helper in PokeDinner 2.0 runtime-v8 batch'
}

# One 01effa signature differs only by legal C++ whitespace from the general batch's exact
# replacement. Normalize it before applying the compatibility batch.
$path = 'src/video_core/buffer_cache/buffer_cache.h'
$text = (Get-Content $path -Raw).Replace("`r`n", "`n")
$old = 'BufferId BufferCache<P>::FindBuffer(DAddr device_addr'
$new = "BufferId BufferCache<P>::FindBuffer`n(DAddr device_addr"
if ($text.Contains($old)) {
    $text = $text.Replace($old, $new)
    Set-Content -Path $path -Value $text -Encoding utf8 -NoNewline
    Write-Host 'Normalized FindBuffer signature anchor for combined batch.'
} elseif (-not $text.Contains($new)) {
    throw 'Could not normalize FindBuffer signature anchor'
}

# PokeDinner 2.0 sparse written-state belongs to one emulation session. Prepare the helper with a
# stable single-function boundary so runtime-v8 only needs to add the nvdrv reset call. Legacy
# GLSL Task/Mesh handling deliberately stays out of this preflight: runtime-v10 is the canonical
# final normalization layer for those backend switches.
$nx2Path = 'src/video_core/nx2.h'
$nx2 = (Get-Content $nx2Path -Raw).Replace("`r`n", "`n")
$sparseMarker = 'inline void Nx2ClearSparseRegions()'
if (-not $nx2.Contains($sparseMarker)) {
    $sparseAnchor = 'inline void Nx2SparseBlockWritten(u64 region_address, u64 block) {'
    $at = $nx2.IndexOf($sparseAnchor)
    if ($at -lt 0) { throw 'Could not locate stable Nx2SparseBlockWritten preflight anchor' }
    if ($nx2.IndexOf($sparseAnchor, $at + $sparseAnchor.Length) -ge 0) {
        throw 'Ambiguous Nx2SparseBlockWritten preflight anchor'
    }
    $sparseReset = @'
/// A new emulation session: the previous game's regions are gone (nvdrv's Module clears them).
inline void Nx2ClearSparseRegions() {
    std::scoped_lock lk{g_nx2_sparse_state_mutex};
    g_nx2_sparse_state.clear();
}

'@
    $sparseReset = $sparseReset.Replace("`r`n", "`n")
    $nx2 = $nx2.Substring(0, $at) + $sparseReset + $nx2.Substring($at)
    Set-Content -Path $nx2Path -Value $nx2 -Encoding utf8 -NoNewline
    Write-Host 'Prepared PokeDinner 2.0 sparse-session reset with stable function anchor.'
}

# PokeDinner 2.0 shader ObjectPool lifetime fix. Storage's destructor is intentionally empty, so
# destroying the Storage wrappers skips T's destructor. Patch the one destructor line instead of
# matching the whole Release() function; this remains stable across harmless formatting changes.
$poolPath = 'src/shader_recompiler/object_pool.h'
$pool = (Get-Content $poolPath -Raw).Replace("`r`n", "`n")
$poolMarker = 'std::destroy_at(&storage[index].object);'
if (-not $pool.Contains($poolMarker)) {
    $oldPoolLine = '            std::destroy_n(storage.get(), used_objects);'
    $poolAt = $pool.IndexOf($oldPoolLine)
    if ($poolAt -lt 0) { throw 'Could not locate ObjectPool destroy_n preflight anchor' }
    if ($pool.IndexOf($oldPoolLine, $poolAt + $oldPoolLine.Length) -ge 0) {
        throw 'Ambiguous ObjectPool destroy_n preflight anchor'
    }
    $newPoolLines = "            for (size_t index = 0; index < used_objects; ++index) {`n" +
                    "                std::destroy_at(&storage[index].object);`n" +
                    "            }"
    $pool = $pool.Substring(0, $poolAt) + $newPoolLines +
            $pool.Substring($poolAt + $oldPoolLine.Length)
    Set-Content -Path $poolPath -Value $pool -Encoding utf8 -NoNewline
    Write-Host 'Prepared PokeDinner 2.0 ObjectPool live-object destructor fix.'
}

# Mario Kart World/NVIDIA predicate-mask correctness. Replace FoldSMax32 by function boundaries,
# not by its complete old body, so the 2.0 fix survives nearby constant-propagation edits. The
# donor-proven MaskValues analysis follows selects, negations, +/-1 and phis whose domain stays
# within {-1,0,1}; max(x,-x) can then safely become x&1.
$constPath = 'src/shader_recompiler/ir_opt/constant_propagation_pass.cpp'
$const = (Get-Content $constPath -Raw).Replace("`r`n", "`n")
$maskMarker = 'u32 MaskValues(const IR::Value& value, u32 depth = 0)'
if (-not $const.Contains($maskMarker)) {
    $foldStartMarker = 'void FoldSMax32(IR::Block& block, IR::Inst& inst) {'
    $foldEndMarker = 'void ConstantPropagation(Environment& env, IR::Block& block, IR::Inst& inst) {'
    $foldStart = $const.IndexOf($foldStartMarker)
    if ($foldStart -lt 0) { throw 'Could not locate FoldSMax32 preflight start' }
    $foldEnd = $const.IndexOf($foldEndMarker, $foldStart)
    if ($foldEnd -lt 0) { throw 'Could not locate FoldSMax32 preflight end' }
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
    $newFold = $newFold.Replace("`r`n", "`n").TrimEnd("`r", "`n") + "`n"
    $const = $const.Substring(0, $foldStart) + $newFold + $const.Substring($foldEnd)
    Set-Content -Path $constPath -Value $const -Encoding utf8 -NoNewline
    Write-Host 'Prepared PokeDinner 2.0 MKW predicate-mask fold with function-boundary anchor.'
}
