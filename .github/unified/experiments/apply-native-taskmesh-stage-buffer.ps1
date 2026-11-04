$ErrorActionPreference = 'Stop'
# Isolated second-phase shader candidate for Orchid v0.7.0, NOT applied to initial unified build.
# Task/Mesh ISBERD/ISBEWR uses Orchid's already-present ISBE_nx2 pseudo instruction,
# IR stage-buffer read/write, SPIR-V lowering, and Vulkan stage-buffer binding.
# Donor semantics: Eglantine build212 lower_to_maxwell.h and Orchid's unused
# lower_to_maxwell_upstream.h at v0.7.0. Preserve the active geometry/tessellation 0x923 path.
$path = 'src/shader_recompiler/frontend/ampere/lower_to_maxwell.h'
$backend = 'src/shader_recompiler/frontend/maxwell/translate/impl/internal_stage_buffer_entry_read.cpp'
$matcher = 'src/shader_recompiler/frontend/maxwell/maxwell.inc'
foreach ($f in @($path, $backend, $matcher)) {
    if (-not (Test-Path $f -PathType Leaf)) { throw "Missing Task/Mesh preflight source: $f" }
}
if (-not (Select-String -Path $backend -SimpleMatch 'void TranslatorVisitor::ISBE_nx2(u64 insn)' -Quiet) -or
    -not (Select-String -Path $backend -SimpleMatch 'stage != Stage::Task && stage != Stage::Mesh' -Quiet) -or
    -not (Select-String -Path $matcher -SimpleMatch 'INST(ISBE_nx2,' -Quiet)) {
    throw 'Backend Task/Mesh ISBE pseudo instruction is not available; aborting donor port'
}
$raw = [IO.File]::ReadAllText((Resolve-Path $path).Path).Replace([string][char]13 + [string][char]10, [string][char]10)
$old = @'
        case 0x923:
            // The map region turns a vertex ordinal into its handle, as for geometry programs.
            if (!geometry_stage && !tessellation_stage)
                return fail(index, "native stage buffer read outside geometry stage");
            if (insn.words[1] || insn.words[2] || insn.Bits(24, 8) == 255)
                return fail(index, "native stage buffer read mode");
            emit(base(0x5c98000000000000ULL) | (u64{15} << 39) | (u64{insn.Bits(24, 8)} << 20));
            break;
'@
$new = @'
        case 0x923: case 0x927: { // ISBERD / ISBEWR, native Task/Mesh stage buffer.
            // Keep Orchid's original geometry/tessellation map-region read exactly as it was.
            if (geometry_stage || tessellation_stage) {
                if (opcode != 0x923)
                    return fail(index, "native geometry stage buffer write mode");
                if (insn.words[1] || insn.words[2] || insn.Bits(24, 8) == 255)
                    return fail(index, "native stage buffer read mode");
                emit(base(0x5c98000000000000ULL) | (u64{15} << 39) |
                     (u64{insn.Bits(24, 8)} << 20));
                break;
            }

            // The existing backend consumes a Maxwell 0xefc0 ISBE_nx2 pseudo instruction.
            // Ampere: Ra 24-31, offset 40-63, read dest 16-23, write data 32-39.
            // 75=.32; 76-77=.ATTR (3 attribute, 0 map); 78=.SKEW; 79=.O (output).
            const bool write = opcode == 0x927;
            const u32 region = insn.Bits(76, 2);
            const bool output = insn.Bits(79, 1) != 0;
            if ((insn.words[2] & ~0xf800U) != 0 || (region != 0 && region != 3) ||
                write != output || (!write && region != 3) || (!write && dest == 255))
                return fail(index, "native stage buffer access mode");

            emit(0xefc0000000000000ULL | predicate |
                 (write ? u64{insn.Bits(32, 8)} : dest) |
                 (u64{insn.Bits(24, 8)} << 8) |
                 (u64{insn.Bits(40, 24)} << 20) |
                 (u64{insn.Bits(75, 1)} << 44) |
                 (u64{region == 3} << 45) |
                 (u64{insn.Bits(78, 1)} << 46) |
                 (u64{output} << 47) | (u64{write} << 48));
            break;
        }
'@
$old = $old.TrimEnd([char[]]@([char]13,[char]10))
$new = $new.TrimEnd([char[]]@([char]13,[char]10))
if ($raw.Contains($new)) { Write-Host '[ALREADY] Task/Mesh stage-buffer lowering'; exit 0 }
$offset = $raw.IndexOf($old, [StringComparison]::Ordinal)
if ($offset -lt 0 -or $raw.IndexOf($old, $offset + $old.Length, [StringComparison]::Ordinal) -ge 0) {
    $caseAt = $raw.IndexOf("case 0x923:", [StringComparison]::Ordinal)
    $secondAt = if ($offset -ge 0) { $raw.IndexOf($old, $offset + $old.Length, [StringComparison]::Ordinal) } else { -1 }
    throw "Orchid stage buffer anchor mismatch (fullMatch=$offset, secondMatch=$secondAt, caseAt=$caseAt, anchorLength=$($old.Length))."
}
$raw = $raw.Substring(0,$offset) + $new + $raw.Substring($offset + $old.Length)
[IO.File]::WriteAllText((Resolve-Path $path).Path,$raw,[Text.UTF8Encoding]::new($false))
if (-not $raw.Contains('case 0x923: case 0x927:') -or
    -not $raw.Contains('if (geometry_stage || tessellation_stage)') -or
    -not $raw.Contains('0xefc0000000000000ULL')) {
    throw 'Task/Mesh source invariant absent after patch'
}
git diff --check -- $path
if ($LASTEXITCODE -ne 0) { throw 'Task/Mesh integration whitespace check failed' }
Write-Host '[PASS] Isolated Task/Mesh pseudo lowering ready for shader-recompiler + full Windows build validation'
