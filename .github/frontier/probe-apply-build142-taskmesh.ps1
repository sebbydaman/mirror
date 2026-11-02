$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

function Require-NativeSuccess([string]$Label) {
    if ($LASTEXITCODE -ne 0) { throw "$Label failed with exit $LASTEXITCODE" }
}

# Diagnostic-only coherent application of the two build-142 Task/Mesh donors over the exact
# assembled Pokopia stack. This helper deliberately commits only inside the ephemeral CI checkout.
# It must not be added to the production final-performance stack until compile/runtime gates pass.

git add -A
Require-NativeSuccess 'git add assembled stack'
if (git status --porcelain) {
    git -c user.name='Eden NS2 CI' -c user.email='actions@github.com' commit -m 'CI checkpoint exact assembled stack before build142 task-mesh probe' --no-verify
    Require-NativeSuccess 'assembled-stack checkpoint commit'
}
$checkpoint = (git rev-parse HEAD).Trim()
Write-Host "Task/Mesh diagnostic checkpoint: $checkpoint"

if (-not (git remote | Select-String -SimpleMatch 'eglantine-taskmesh')) {
    git remote add eglantine-taskmesh https://github.com/Djihads80/Eglantine.git
    Require-NativeSuccess 'add taskmesh donor remote'
}
git fetch --no-tags --depth=8 eglantine-taskmesh eb02d1dd53a03d0bb6ce541694243579a4c10c6f 310dd596d0f6d48de3517cfb1bdc90a366817405
Require-NativeSuccess 'fetch build142 task-mesh donors'

$amperePath = 'src/shader_recompiler/frontend/ampere/lower_to_maxwell.h'
$ampere = (Get-Content $amperePath -Raw).Replace("`r`n", "`n")

if (-not [regex]::IsMatch($ampere, '\bcase\s+0x2bf\s*:')) {
    $anchor = '        case 0x3a1:'
    if (-not $ampere.Contains($anchor)) { throw 'UPOPC insertion anchor changed' }
    $upopc = @'
        case 0x2bf: // UPOPC, as POPC of the uniform's register.
            if (dest >= 16 || insn.words[1] >= 16 || insn.words[2] != 0x08000000 || native_predicate != 7)
                return fail(index, "native uniform population count mode");
            emit(0x5c08000000000000ULL | predicate | (dest + 216) | (u64{insn.words[1] + 216} << 20));
            break;
'@
    $ampere = $ampere.Replace($anchor, $upopc.TrimEnd("`r", "`n") + "`n" + $anchor)
    Write-Host 'Added donor UPOPC lowering.'
}

$oldPattern = '(?s)        case 0x923: \{ // ISBERD indexed task/mesh attribute read / direct map read\..*?        case 0x34e: \{ // LEPC:'
if (-not [regex]::IsMatch($ampere, $oldPattern)) { throw 'Could not locate current custom ISBERD/ISBEWR pair' }
$isbe = @'
        case 0x923: case 0x927: { // ISBERD / ISBEWR: task and mesh programs' stage buffer.
            // Ampere: Ra 24-31, offset 40-63, ISBERD dest 16-23, ISBEWR data 32-39; 75 = .32 (else
            // U8), 76-77 = 3 .ATTR (0 the map region), 78 = .SKEW, 79 = .O (the output buffer).
            // Kept as an nx2 pseudo instruction (Maxwell 0xefc0, free there) that the frontend
            // reads for the task or mesh stage: data/dest 0-7, Ra 8-15, offset 20-43, .32 44,
            // .ATTR 45, .SKEW 46, .O 47, write 48. Addresses are linear bytes in the region.
            const bool write = opcode == 0x927;
            const u32 region = insn.Bits(76, 2);
            const bool output = insn.Bits(79, 1) != 0;
            if ((insn.words[2] & ~0xf800U) != 0 || (region != 0 && region != 3) || write != output ||
                (!write && region != 3) || (!write && dest == 255))
                return fail(index, "native stage buffer access mode");
            emit(0xefc0000000000000ULL | predicate | (write ? u64{insn.Bits(32, 8)} : dest) |
                 (u64{insn.Bits(24, 8)} << 8) | (u64{insn.Bits(40, 24)} << 20) |
                 (u64{insn.Bits(75, 1)} << 44) | (u64{region == 3} << 45) |
                 (u64{insn.Bits(78, 1)} << 46) | (u64{output} << 47) | (u64{write} << 48));
            break;
        }
        case 0x34e: { // LEPC:
'@
$ampere = ([regex]::new($oldPattern)).Replace($ampere, $isbe.TrimEnd("`r", "`n"), 1)
[IO.File]::WriteAllText((Resolve-Path $amperePath).Path, $ampere.TrimEnd("`r", "`n") + "`n", [Text.UTF8Encoding]::new($false))

$resolvedText = Get-Content $amperePath -Raw
foreach ($needle in @('case 0x923: case 0x927:', '0xefc0000000000000ULL', '(region != 0 && region != 3)', 'case 0x2bf:')) {
    if (-not $resolvedText.Contains($needle)) { throw "Manual donor-1 semantic resolution missing $needle" }
}
git diff --check -- $amperePath
Require-NativeSuccess 'donor-1 diff check'
git add $amperePath
Require-NativeSuccess 'stage donor-1 semantics'
git -c user.name='Eden NS2 CI' -c user.email='actions@github.com' commit -m 'Probe: resolve build142 ISBE lowering over current Pokopia lowerer' --no-verify
Require-NativeSuccess 'donor-1 checkpoint commit'

# The assembled Pokopia stack already has the four stage-admission hunks touched by donor 2.
# Preserve those local equivalents, but only when Git reports this exact known conflict set.
git cherry-pick --no-commit 310dd596d0f6d48de3517cfb1bdc90a366817405
$pickCode = $LASTEXITCODE
$expectedConflicts = @(
    'src/shader_recompiler/backend/glasm/emit_glasm.cpp',
    'src/shader_recompiler/backend/glasm/glasm_emit_context.cpp',
    'src/shader_recompiler/backend/glsl/glsl_emit_context.cpp',
    'src/shader_recompiler/stage.h'
)
$conflicts = @(git diff --name-only --diff-filter=U)
if ($pickCode -ne 0) {
    $delta = @(Compare-Object ($expectedConflicts | Sort-Object) ($conflicts | Sort-Object))
    if ($delta.Count -ne 0) {
        $conflicts | ForEach-Object { Write-Host "Observed conflict: $_" }
        throw 'Donor-2 conflict set changed; refusing permissive resolution'
    }
    foreach ($file in $expectedConflicts) {
        git checkout --ours -- $file
        Require-NativeSuccess "preserve local semantics for $file"
        git add -- $file
        Require-NativeSuccess "stage resolved conflict $file"
    }
} elseif ($conflicts.Count -ne 0) {
    throw 'Donor-2 returned success while leaving unresolved files'
}

$remaining = @(git diff --name-only --diff-filter=U)
if ($remaining.Count -ne 0) { throw "Donor-2 unresolved conflicts remain: $($remaining -join ', ')" }

$localChecks = @{
    'src/shader_recompiler/stage.h' = @('Task,', 'Mesh,')
    'src/shader_recompiler/backend/glasm/emit_glasm.cpp' = @('case Stage::Task:', 'case Stage::Mesh:')
    'src/shader_recompiler/backend/glasm/glasm_emit_context.cpp' = @('case Stage::Task:', 'case Stage::Mesh:')
    'src/shader_recompiler/backend/glsl/glsl_emit_context.cpp' = @('case Stage::Task:', 'case Stage::Mesh:')
}
foreach ($file in $localChecks.Keys) {
    $text = Get-Content $file -Raw
    foreach ($needle in $localChecks[$file]) {
        if (-not $text.Contains($needle)) { throw "Resolved local stage semantics missing $needle in $file" }
    }
}

foreach ($pattern in @('ISBE_nx2','IsbeRead','IsbeWriteMapU32','EmitMeshPrologue','ExecutionModel::TaskEXT','ExecutionModel::MeshEXT')) {
    $hits = @(git grep -n -I $pattern -- src/shader_recompiler src/video_core 2>$null)
    if (-not $hits.Count) { throw "Missing required connected donor symbol: $pattern" }
}

git diff --check
Require-NativeSuccess 'resolved donor-2 diff check'
Write-Host 'Build142 Task/Mesh diagnostic donor tree applied coherently.'
