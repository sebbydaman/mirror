$ErrorActionPreference = "Stop"

# Import only generic 0x2593/Eden-NS2 improvements that are still absent from
# the pinned Eglantine base. Do not duplicate Eglantine's broader LSE/service
# implementations or replace our TXQ/BRX/geometry-stage work.

# -----------------------------------------------------------------------------
# Maxwell PRMT implementation
# -----------------------------------------------------------------------------
$prmtPath = "src/shader_recompiler/frontend/maxwell/translate/impl/integer_byte_permute.cpp"
if (-not (Test-Path $prmtPath)) {
@'
// SPDX-FileCopyrightText: Copyright 2026 Eden Emulator Project
// SPDX-License-Identifier: GPL-3.0-or-later

#include "common/bit_field.h"
#include "common/common_types.h"
#include "shader_recompiler/frontend/maxwell/translate/impl/impl.h"

namespace Shader::Maxwell {
namespace {
// PRMT in its default mode: each result byte is picked by a selector nibble from the eight bytes
// {c, a} (0-3 from a, 4-7 from c); bit 3 of the nibble replicates the picked byte's sign bit.
void PRMT(TranslatorVisitor& v, u64 insn, const IR::U32& selector, const IR::U32& src_c) {
    union {
        u64 raw;
        BitField<0, 8, IR::Reg> dest_reg;
        BitField<8, 8, IR::Reg> src_a_reg;
        BitField<48, 3, u64> mode;
    } const prmt{insn};
    if (prmt.mode != 0) {
        throw NotImplementedException("PRMT mode {}", prmt.mode.Value());
    }
    const IR::U32 src_a{v.X(prmt.src_a_reg)};
    IR::U32 result{v.ir.Imm32(0)};
    for (u32 byte = 0; byte < 4; ++byte) {
        const IR::U32 nibble{v.ir.BitFieldExtract(selector, v.ir.Imm32(byte * 4), v.ir.Imm32(4))};
        const IR::U32 index{v.ir.BitwiseAnd(nibble, v.ir.Imm32(7))};
        const IR::U32 source{
            IR::U32{v.ir.Select(v.ir.ILessThan(index, v.ir.Imm32(4), false), src_a, src_c)}};
        const IR::U32 offset{v.ir.ShiftLeftLogical(v.ir.BitwiseAnd(index, v.ir.Imm32(3)), v.ir.Imm32(3))};
        const IR::U32 value{v.ir.BitFieldExtract(source, offset, v.ir.Imm32(8))};
        const IR::U32 sign{v.ir.BitFieldExtract(source, v.ir.IAdd(offset, v.ir.Imm32(7)), v.ir.Imm32(1), true)};
        const IR::U1 replicate{v.ir.INotEqual(v.ir.BitwiseAnd(nibble, v.ir.Imm32(8)), v.ir.Imm32(0))};
        const IR::U32 picked{IR::U32{v.ir.Select(replicate, sign, value)}};
        result = v.ir.BitFieldInsert(result, picked, v.ir.Imm32(byte * 8), v.ir.Imm32(8));
    }
    v.X(prmt.dest_reg, result);
}
} // Anonymous namespace

void TranslatorVisitor::PRMT_reg(u64 insn) {
    PRMT(*this, insn, GetReg20(insn), GetReg39(insn));
}

void TranslatorVisitor::PRMT_rc(u64 insn) {
    PRMT(*this, insn, GetReg39(insn), GetCbuf(insn));
}

void TranslatorVisitor::PRMT_cr(u64 insn) {
    PRMT(*this, insn, GetCbuf(insn), GetReg39(insn));
}

void TranslatorVisitor::PRMT_imm(u64 insn) {
    PRMT(*this, insn, GetImm20(insn), GetReg39(insn));
}

} // namespace Shader::Maxwell
'@ | Set-Content -Path $prmtPath -Encoding utf8 -NoNewline
    Write-Host "Added Maxwell PRMT implementation."
}

$cmakePath = "src/shader_recompiler/CMakeLists.txt"
$cmakeText = Get-Content $cmakePath -Raw
$prmtEntry = "    frontend/maxwell/translate/impl/integer_byte_permute.cpp"
if (-not $cmakeText.Contains($prmtEntry)) {
    $needle = "    frontend/maxwell/translate/impl/integer_add_three_input.cpp"
    if (-not $cmakeText.Contains($needle)) { throw "Could not locate shader CMake insertion point" }
    $cmakeText = $cmakeText.Replace($needle, "$needle`n$prmtEntry")
    Set-Content -Path $cmakePath -Value $cmakeText -Encoding utf8 -NoNewline
}

$notImplPath = "src/shader_recompiler/frontend/maxwell/translate/impl/not_implemented.cpp"
$notImplText = Get-Content $notImplPath -Raw
$prmtStubPattern = '(?s)void TranslatorVisitor::PRMT_reg\(u64\) \{.*?\}\r?\n\r?\nvoid TranslatorVisitor::PRMT_rc\(u64\) \{.*?\}\r?\n\r?\nvoid TranslatorVisitor::PRMT_cr\(u64\) \{.*?\}\r?\n\r?\nvoid TranslatorVisitor::PRMT_imm\(u64\) \{.*?\}\r?\n\r?\n'
$notImplNew = [regex]::Replace($notImplText, $prmtStubPattern, '', 1)
if ($notImplNew -ne $notImplText) {
    Set-Content -Path $notImplPath -Value $notImplNew -Encoding utf8 -NoNewline
    Write-Host "Removed Maxwell PRMT not-implemented stubs."
}

# -----------------------------------------------------------------------------
# Maxwell F2I 8-bit destination support
# -----------------------------------------------------------------------------
$f2iPath = "src/shader_recompiler/frontend/maxwell/translate/impl/floating_point_conversion_integer.cpp"
$f2iText = Get-Content $f2iPath -Raw
if (-not $f2iText.Contains('DestFormat::I8')) {
    # Destination encoding 0 is the captured 8-bit form. Eglantine labels it Invalid;
    # the Bananza implementation identifies that encoding as I8.
    $new = [regex]::Replace(
        $f2iText,
        'enum class DestFormat : u64 \{\r?\n\s*Invalid,\r?\n\s*I16,',
        "enum class DestFormat : u64 {`n    I8,`n    I16,",
        1)
    if ($new -eq $f2iText) { throw "Could not patch F2I DestFormat enum for I8" }
    $f2iText = $new

    $new = [regex]::Replace(
        $f2iText,
        'switch \(dest_format\) \{\r?\n\s*case DestFormat::I16:',
        "switch (dest_format) {`n    case DestFormat::I8:`n        return 8;`n    case DestFormat::I16:",
        1)
    if ($new -eq $f2iText) { throw "Could not patch F2I BitSize for I8" }
    $f2iText = $new

    $signedPattern = 'if \(is_signed\) \{\r?\n\s*switch \(format\) \{\r?\n\s*case DestFormat::I16:'
    $signedReplacement = "if (is_signed) {`n        switch (format) {`n        case DestFormat::I8:`n            return {static_cast<f64>((std::numeric_limits<s8>::max)()),`n                    static_cast<f64>((std::numeric_limits<s8>::min)())};`n        case DestFormat::I16:"
    $new = [regex]::Replace($f2iText, $signedPattern, $signedReplacement, 1)
    if ($new -eq $f2iText) { throw "Could not patch signed F2I I8 bounds" }
    $f2iText = $new

    $unsignedPattern = '\} else \{\r?\n\s*switch \(format\) \{\r?\n\s*case DestFormat::I16:'
    $unsignedReplacement = "} else {`n        switch (format) {`n        case DestFormat::I8:`n            return {static_cast<f64>((std::numeric_limits<u8>::max)()),`n                    static_cast<f64>((std::numeric_limits<u8>::min)())};`n        case DestFormat::I16:"
    $new = [regex]::Replace($f2iText, $unsignedPattern, $unsignedReplacement, 1)
    if ($new -eq $f2iText) { throw "Could not patch unsigned F2I I8 bounds" }
    $f2iText = $new

    Set-Content -Path $f2iPath -Value $f2iText -Encoding utf8 -NoNewline
    Write-Host "Added Maxwell F2I 8-bit destination support."
}

# -----------------------------------------------------------------------------
# Native geometry helper lowering from the Bananza path
# -----------------------------------------------------------------------------
$amperePath = "src/shader_recompiler/frontend/ampere/lower_to_maxwell.h"
$ampereText = Get-Content $amperePath -Raw
if (-not $ampereText.Contains('case 0x923: // ISBERD map read')) {
    $needle = '        case 0x419: { // SHF.L.W.U32.HI Rd, RZ, Rb, imm (high word of imm:0 << Rb) = imm << (Rb & 31)'
    if (-not $ampereText.Contains($needle)) { throw "Could not locate native geometry helper insertion point" }
    $block = @'
        case 0x923: // ISBERD map read: geometry vertex index to attribute handle. Eden's ALD takes the
                    // index itself (Maxwell ISBERD in this mode is a copy), so this is a move.
            if (insn.Bits(32, 32) || insn.words[2] || insn.Bits(24, 8) == 255)
                return fail(index, "native stage buffer read mode");
            emit(base(0x5c98000000000000ULL) | (u64{15} << 39) | (u64{insn.Bits(24, 8)} << 20));
            break;
        case 0x34e: { // LEPC: 64-bit address of the next instruction
            // Seen in geometry shader prologues; native code addresses have no meaning after lowering.
            if (insn.Bits(24, 8) || insn.words[1] || insn.words[2] || dest >= 254)
                return fail(index, "native program counter load mode");
            mov_imm(static_cast<u32>(dest), 0);
            mov_imm(static_cast<u32>(dest) + 1, 0);
            break;
        }
        case 0x357: // Consumes the LEPC-derived address in geometry shader prologues.
            if (insn.Bits(16, 8) || insn.Bits(32, 32) || insn.words[2] || native_predicate != 7)
                return fail(index, "native geometry prologue mode");
            break;
'@
    $ampereText = $ampereText.Replace($needle, $block.TrimEnd("`r", "`n") + "`n" + $needle)
    Set-Content -Path $amperePath -Value $ampereText -Encoding utf8 -NoNewline
    Write-Host "Added native geometry ISBERD/LEPC/prologue lowering."
}

git diff -- src/shader_recompiler/CMakeLists.txt `
            src/shader_recompiler/frontend/maxwell/translate/impl/integer_byte_permute.cpp `
            src/shader_recompiler/frontend/maxwell/translate/impl/not_implemented.cpp `
            src/shader_recompiler/frontend/maxwell/translate/impl/floating_point_conversion_integer.cpp `
            src/shader_recompiler/frontend/ampere/lower_to_maxwell.h