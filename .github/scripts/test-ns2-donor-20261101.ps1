$ErrorActionPreference = 'Stop'

function Require-Text([string]$Path, [string]$Needle, [string]$Name) {
    if (-not (Test-Path $Path -PathType Leaf)) {
        throw "November donor regression: missing required file $Path"
    }
    $text = Get-Content $Path -Raw
    if (-not $text.Contains($Needle)) {
        throw "November donor regression: $Name missing from $Path"
    }
    Write-Host "[PASS] $Name"
}

$objectPool = 'src/shader_recompiler/object_pool.h'
$undef = 'src/shader_recompiler/backend/spirv/emit_spirv_undefined.cpp'
$ampere = 'src/shader_recompiler/frontend/ampere/lower_to_maxwell.h'
$constProp = 'src/shader_recompiler/ir_opt/constant_propagation_pass.cpp'
$vkTexture = 'src/video_core/renderer_vulkan/vk_texture_cache.cpp'

Require-Text $objectPool 'std::destroy_at(&storage[index].object);' 'shader object-pool lifetime fix'
Require-Text $undef 'EDEN_NX2_UNDEF_ZERO' 'AMD undefined-register rollback switch'
Require-Text $undef 'UndefIsZero() ? ctx.u32_zero_value' 'AMD U32 undefined-register zeroing'
Require-Text $ampere 'active_link && opcode != 0x950' 'Ampere RET reserved-destination fix'
Require-Text $ampere 'FSEL: the sources keep their .NEG/.ABS' 'FSEL floating source modifier preservation'
Require-Text $constProp 'u32 MaskValues(const IR::Value& value' 'predicate-mask value analysis'
Require-Text $constProp 'ir.BitwiseAnd(IR::U32{value}, ir.Imm32(1))' 'predicate-mask SMax driver-safe folding'
Require-Text $vkTexture 'memory >= 20_GiB' '20 GiB Switch 2 ASTC/BC3 threshold'

# Make sure the old known-bad forms did not survive beside the replacements.
$ampereText = Get-Content $ampere -Raw
if ($ampereText.Contains('case 0x207: case 0x807: case 0xa07:' + "`n" +
                         '        case 0x208: case 0x808: case 0xa08: { // Bitwise SEL / FSEL')) {
    throw 'November donor regression: combined SEL/FSEL path still drops FSEL .NEG/.ABS modifiers'
}
$objectText = Get-Content $objectPool -Raw
if ($objectText.Contains('std::destroy_n(storage.get(), used_objects);')) {
    throw 'November donor regression: object pool still destroys union wrappers instead of live objects'
}

Write-Host 'November NX2 donor regression validation passed.'

# Apply the host-CPU worker budget after the PokeDinner donor batch has established its pipeline and
# translation pools. Build31 runs immediately after this and does not replace GetTotalPipelineWorkers.
$pipelineWorkerBudget = Join-Path $PSScriptRoot '..\frontier\apply-ns2-pipeline-worker-budget.ps1'
if (-not (Test-Path $pipelineWorkerBudget -PathType Leaf)) {
    throw "November donor regression: missing pipeline-worker frontier layer $pipelineWorkerBudget"
}
& $pipelineWorkerBudget