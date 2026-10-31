$ErrorActionPreference = 'Stop'

# Native Ampere SURED support recovered from the SM80 machine description and the exact
# post-#73 Bananza compute instruction. Keep the first implementation deliberately narrow:
# bound/immediate descriptor, 2D coordinates, U32 ADD reduction, IGN clamp, and the observed
# default memory semantics. Unsupported SURED variants must remain rejected.
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

$amperePath = 'src/shader_recompiler/frontend/ampere/lower_to_maxwell.h'
$ampere = Read-Lf $amperePath
$marker = 'case 0x59f: { // SURED bound/immediate 2D U32 ADD, IGN clamp.'

if (-not $ampere.Contains($marker)) {
    $anchor = '        case 0x95b: // Fragment discard; execution predicate is preserved.'
    $block = @'
        case 0x59f: { // SURED bound/immediate 2D U32 ADD, IGN clamp.
            // SM80 sured_imm_: Ra is the consecutive coordinate register list, Rb is the
            // reduction operand, bank5 selects the descriptor constant-buffer binding and
            // tsPtrIdx is the descriptor-table offset. Lower to Eden's existing Maxwell SURED
            // path so the operation becomes a real image atomic rather than a shader-specific no-op.
            const u32 coordinate = insn.Bits(24, 8);
            const u32 data = insn.Bits(32, 8);
            const u32 offset = insn.Bits(40, 14);
            const u32 binding = insn.Bits(54, 5);
            const u32 clamp = insn.Bits(59, 2);
            const u32 dimension = insn.Bits(61, 3);
            const u32 size = insn.Bits(73, 3);
            const u32 memory = insn.Bits(77, 4);
            const u32 cop = insn.Bits(84, 3);
            const u32 operation = insn.Bits(87, 3);
            const u32 reserved = uses_uniform_bank ? 216U : 250U;

            // Proven SM80 form from 0400759f 60000c00 0010e000 000fe200:
            // PT SURED.ADD.U32.2D.IGN [R4], R0, descriptor bank 0 / table offset 12.
            // The checks describe the instruction class, not that one shader address/word.
            if (insn.Bits(72, 1) || insn.Bits(76, 1) || insn.Bits(81, 3) || insn.Bits(90, 2) ||
                dimension != 3 || size != 0 || operation != 0 || cop != 1 || clamp != 0 || memory != 7 ||
                binding >= 18 || offset > 0x1fff || (coordinate & 1) || coordinate + 1 >= reserved ||
                (data != 255 && data >= reserved))
                return fail(index, "native surface reduction mode");
            if (result.required_texture_buffer != ~0U && result.required_texture_buffer != binding)
                return fail(index, "native surface descriptor buffer conflict");
            result.required_texture_buffer = binding;

            // Maxwell SURED fields: operand Rb[0:7], coordinate Ra[8:15], size[20:22],
            // atomic op[24:26], dimension[33:35], bound descriptor offset[36:48],
            // clamp[49:50], is_bound[51]. Predicate is preserved independently.
            emit(0xeb40000000000000ULL | predicate | data | (u64{coordinate} << 8) |
                 (u64{size} << 20) | (u64{operation} << 24) | (u64{dimension} << 33) |
                 (u64{offset} << 36) | (u64{clamp} << 49) | (u64{1} << 51));
            break;
        }
'@
    $ampere = Replace-Once $ampere $anchor ($block + $anchor) 'SURED insertion point'
    Write-Utf8 $amperePath $ampere
}

$check = Read-Lf $amperePath
foreach ($needle in @(
    $marker,
    'const u32 memory = insn.Bits(77, 4);',
    'dimension != 3 || size != 0 || operation != 0 || cop != 1 || clamp != 0 || memory != 7',
    'result.required_texture_buffer = binding;',
    '0xeb40000000000000ULL | predicate | data',
    '(u64{1} << 51)'
)) {
    if (-not $check.Contains($needle)) { throw "Runtime-v4 SURED regression: missing $needle" }
}
if ($check.Contains('case 0x59f:') -and -not $check.Contains('native surface reduction mode')) {
    throw 'Runtime-v4 regression: 0x59f exists without semantic validation'
}

Write-Host 'Applied native Ampere SURED 0x59f lowering through Maxwell image-atomic semantics.'
