$ErrorActionPreference = 'Stop'

# Runtime blockers captured from the post-#73 Bananza logs. Keep this patch narrow:
# - correct RET link-register validation (Eglantine PR #56)
# - allow proven S2R geometry-invocation identities (SR17/SR29)
# - allow scalar TXQ results in odd GPRs
# - lower the observed task/mesh ISBERD/ISBEWR indexed attribute payload forms
#   through Eden's existing Maxwell ALD/AST IR path.
# Unknown opcode 0x59f remains rejected until its semantics are proven.

function Read-Lf([string]$Path) {
    if (-not (Test-Path $Path)) { throw "Missing required source file: $Path" }
    return (Get-Content $Path -Raw).Replace("`r`n", "`n")
}
function Write-Utf8([string]$Path, [string]$Text) {
    Set-Content -Path $Path -Value $Text -Encoding utf8 -NoNewline
}
function Replace-Once([string]$Text, [string]$Old, [string]$New, [string]$Label) {
    $Old = $Old.Replace("`r`n", "`n")
    $New = $New.Replace("`r`n", "`n")
    $at = $Text.IndexOf($Old)
    if ($at -lt 0) { throw "Could not locate $Label" }
    if ($Text.IndexOf($Old, $at + $Old.Length) -ge 0) { throw "Ambiguous anchor for $Label" }
    return $Text.Substring(0, $at) + $New + $Text.Substring($at + $Old.Length)
}

$amperePath = 'src/shader_recompiler/frontend/ampere/lower_to_maxwell.h'
$ampere = Read-Lf $amperePath

# Eglantine PR #56: Ampere RET has no destination GPR. Bits 16..23 are reserved and must not be
# interpreted as a write to the active call-link register (the observed Bananza RET encoded R0).
if (-not $ampere.Contains('active_link && opcode != 0x950')) {
    $ampere = Replace-Once $ampere `
        '            if (active_link && insn.Bits(16, 8) == *active_link)' `
        '            if (active_link && opcode != 0x950 && insn.Bits(16, 8) == *active_link)' `
        'RET link-register validation'
}

# The newer Eden-NS2 lowering admits SR17 and SR29 in addition to thread/workgroup identities.
# SR29 is the exact S2R form captured in the #73 Bananza movement log.
if (-not $ampere.Contains('special != 17 && special != 29')) {
    $old = @'
                (special != 0 && special != 33 && special != 34 && special != 35 &&
                 special != 37 && special != 38 && special != 39 &&
'@
    $new = @'
                (special != 0 && special != 17 && special != 29 && special != 33 && special != 34 && special != 35 &&
                 special != 37 && special != 38 && special != 39 &&
'@
    $ampere = Replace-Once $ampere $old $new 'S2R geometry invocation identities'
}

# A scalar TXQ result does not need an even destination register. #73 rejected mask=1 queries to
# R5/R15/R17, causing full-resolution world draws to lose their pipelines.
if (-not $ampere.Contains('(outputs > 1 && (dest & 1)) || dest + outputs > 246')) {
    $ampere = Replace-Once $ampere `
        '                insn.Bits(40, 14) > 0x1fff || (dest & 1) || dest + outputs > 246)' `
        '                insn.Bits(40, 14) > 0x1fff || (outputs > 1 && (dest & 1)) || dest + outputs > 246)' `
        'scalar TXQ odd-register result'
}

# Replace the narrow ISBERD-as-MOV approximation with the proven Ampere semantics needed by the
# captured task/mesh payload form. Access=ATTR reads a byte address through indexed ALD; SKEW adds
# lane_id*4 for the 32-bit payload. Keep the old direct-map form for access=0.
$start = $ampere.IndexOf('        case 0x923: // ISBERD map read:')
$end = $ampere.IndexOf('        case 0x34e:', $start)
if ($start -lt 0 -or $end -lt 0) { throw 'Could not locate existing ISBERD lowering block' }
$current923 = $ampere.Substring($start, $end - $start)
if (-not $current923.Contains('ISBERD indexed task/mesh attribute read')) {
    $new923 = @'
        case 0x923: { // ISBERD indexed task/mesh attribute read / direct map read.
            const u32 offset_reg = insn.Bits(24, 8);
            const u32 immediate = insn.Bits(40, 16);
            const u32 mem_type = insn.Bits(74, 2);
            const u32 access = insn.Bits(76, 2);
            const bool skew = insn.Bits(78, 1);
            const bool output = insn.Bits(79, 1);
            if (mem_type > 2 || output)
                return fail(index, "native stage buffer read mode");
            if (access == 3) {
                // ATTR mode: byte-addressed indexed varying/payload read. The observed form is
                // .B32.SKEW with RZ+0, which addresses lane_id*4.
                if (mem_type != 2 || dest >= reserved_register ||
                    (offset_reg != 255 && offset_reg >= reserved_register))
                    return fail(index, "native stage buffer attribute read mode");
                if (offset_reg == 255) {
                    mov_imm(250, immediate);
                } else if (immediate) {
                    mov_imm(251, immediate);
                    emit(0x5c10000000000000ULL | predicate | 250 |
                         (u64{offset_reg} << 8) | (u64{251} << 20));
                } else {
                    emit(0x5c98000000000000ULL | predicate | 250 |
                         (u64{15} << 39) | (u64{offset_reg} << 20));
                }
                if (skew) {
                    // SR_LANEID is special register 0 on both the captured Ampere and Maxwell path.
                    emit(0xf0c8000000000000ULL | predicate | 251);
                    emit(0x3848000000000000ULL | predicate | 251 |
                         (u64{251} << 8) | (u64{2} << 20));
                    emit(0x5c10000000000000ULL | predicate | 250 |
                         (u64{250} << 8) | (u64{251} << 20));
                }
                // Maxwell ALD with a non-RZ index is already translated to GetAttributeIndexed.
                emit(0xefd8000000000000ULL | predicate | dest |
                     (u64{250} << 8) | (u64{255} << 39));
                break;
            }
            if (access == 0) {
                if (offset_reg == 255) {
                    mov_imm(static_cast<u32>(dest), 0);
                } else {
                    emit(base(0x5c98000000000000ULL) | (u64{15} << 39) |
                         (u64{offset_reg} << 20));
                }
                if (skew) {
                    emit(0xf0c8000000000000ULL | predicate | 250);
                    emit(base(0x5c10000000000000ULL) |
                         (u64{static_cast<u32>(dest)} << 8) | (u64{250} << 20));
                }
                break;
            }
            return fail(index, "native stage buffer read mode");
        }
        case 0x927: { // ISBEWR indexed task/mesh attribute write.
            const u32 offset_reg = insn.Bits(24, 8);
            const u32 data = insn.Bits(32, 8);
            const u32 immediate = insn.Bits(40, 16);
            const u32 mem_type = insn.Bits(74, 2);
            const u32 access = insn.Bits(76, 2);
            const bool skew = insn.Bits(78, 1);
            const bool output = insn.Bits(79, 1);
            if (mem_type != 2 || access != 3 || !output ||
                (offset_reg != 255 && offset_reg >= reserved_register) ||
                (data != 255 && data >= reserved_register))
                return fail(index, "native stage buffer write mode");
            if (offset_reg == 255) {
                mov_imm(250, immediate);
            } else if (immediate) {
                mov_imm(251, immediate);
                emit(0x5c10000000000000ULL | predicate | 250 |
                     (u64{offset_reg} << 8) | (u64{251} << 20));
            } else {
                emit(0x5c98000000000000ULL | predicate | 250 |
                     (u64{15} << 39) | (u64{offset_reg} << 20));
            }
            if (skew) {
                emit(0xf0c8000000000000ULL | predicate | 251);
                emit(0x3848000000000000ULL | predicate | 251 |
                     (u64{251} << 8) | (u64{2} << 20));
                emit(0x5c10000000000000ULL | predicate | 250 |
                     (u64{250} << 8) | (u64{251} << 20));
            }
            // Maxwell AST indexed-store IR support is enabled below. Vertex RZ matches the Ampere
            // SetAttributeIndexed(entry, value, 0) semantics used by ISBEWR.O.ATTR.
            emit(0xeff0000000000000ULL | predicate | data |
                 (u64{250} << 8) | (u64{255} << 39));
            break;
        }
'@
    $ampere = $ampere.Substring(0, $start) + $new923.TrimEnd("`n") + "`n" + $ampere.Substring($end)
}
Write-Utf8 $amperePath $ampere

# Maxwell's AST translator already contains the indexed-store implementation below this historical
# guard. Remove only the unreachable early throw so ISBEWR can use SetAttributeIndexed.
$attrPath = 'src/shader_recompiler/frontend/maxwell/translate/impl/load_store_attribute.cpp'
$attr = Read-Lf $attrPath
if ($attr.Contains('throw NotImplementedException("Indexed store");')) {
    $old = @'
    if (ast.index_reg != IR::Reg::RZ) {
        throw NotImplementedException("Indexed store");
    }
'@
    $new = @'
    // Indexed AST is required by native Ampere ISBEWR task/mesh payload stores. The implementation
    // below already routes it through SetAttributeIndexed; do not reject it before reaching it.
'@
    $attr = Replace-Once $attr $old $new 'Maxwell indexed AST guard'
}
Write-Utf8 $attrPath $attr

# Regression markers for the exact #73 failures. Do not allow 0x59f through here.
$ampereCheck = Read-Lf $amperePath
$attrCheck = Read-Lf $attrPath
foreach ($needle in @(
    'active_link && opcode != 0x950',
    'special != 17 && special != 29',
    '(outputs > 1 && (dest & 1)) || dest + outputs > 246',
    'case 0x923: { // ISBERD indexed task/mesh attribute read / direct map read.',
    'case 0x927: { // ISBEWR indexed task/mesh attribute write.',
    '0xefd8000000000000ULL | predicate | dest',
    '0xeff0000000000000ULL | predicate | data'
)) {
    if (-not $ampereCheck.Contains($needle)) { throw "Runtime-v3 regression: missing $needle" }
}
if ($attrCheck.Contains('throw NotImplementedException("Indexed store");')) {
    throw 'Runtime-v3 regression: indexed AST is still rejected'
}
if ($ampereCheck.Contains('case 0x59f:')) {
    throw 'Runtime-v3 regression: unknown 0x59f must remain rejected'
}

Write-Host 'Applied post-#73 runtime shader fixes: RET, S2R SR29, scalar TXQ, ISBERD/ISBEWR indexed payloads.'
git diff -- $amperePath $attrPath
