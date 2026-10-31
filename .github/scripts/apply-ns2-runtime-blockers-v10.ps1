$ErrorActionPreference = 'Stop'

# Task/Mesh layer C: legacy GLASM/GLSL backends share the Stage enum but do not implement
# native Task/Mesh execution. Keep their switches exhaustive for /we4062 while rejecting the
# unsupported stages explicitly. Vulkan remains the native Task/Mesh path.
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

$glasmPath = 'src/shader_recompiler/backend/glasm/glasm_emit_context.cpp'
$glasm = Read-Lf $glasmPath
$glasmMarker = 'throw InvalidArgument("GLASM does not support shader stage {}", program.stage);'

if (-not $glasm.Contains($glasmMarker)) {
    $glasmOld = @'
    case Stage::Compute:
        stage_name = "invocation";
        break;
    }
    const std::string_view attr_stage{stage == Stage::Fragment ? "fragment" : "vertex"};
'@
    $glasmNew = @'
    case Stage::Compute:
        stage_name = "invocation";
        break;
    case Stage::Task:
    case Stage::Mesh:
        throw InvalidArgument("GLASM does not support shader stage {}", program.stage);
    }
    const std::string_view attr_stage{stage == Stage::Fragment ? "fragment" : "vertex"};
'@
    $glasm = Replace-Once $glasm $glasmOld $glasmNew 'GLASM EmitContext Task/Mesh exhaustive stage guard'
    Write-Utf8 $glasmPath $glasm
}

$glasmCheck = Read-Lf $glasmPath
foreach ($needle in @(
    'case Stage::Task:',
    'case Stage::Mesh:',
    $glasmMarker
)) {
    if (-not $glasmCheck.Contains($needle)) { throw "Runtime-v10 GLASM EmitContext regression: missing $needle" }
}

# GLSL's Compute case declares local_x/local_y/local_z. Braces are required before adding later
# case labels, otherwise MSVC C2360 rejects a jump across those initialized declarations.
# Runtime-v8 may already have inserted the Task/Mesh rejection while applying the PokeDinner 2.0
# batch, so normalize that intermediate form here instead of making two scripts fight over it.
$glslPath = 'src/shader_recompiler/backend/glsl/glsl_emit_context.cpp'
$glsl = Read-Lf $glslPath
$glslMarker = 'throw InvalidArgument("GLSL does not support shader stage {}", program.stage);'
$glslScopedMarker = 'case Stage::Compute: {'

if ($glsl.Contains($glslMarker) -and -not $glsl.Contains($glslScopedMarker)) {
    $glslIntermediate = @'
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
'@
    $glslScoped = @'
    case Stage::Compute: {
        stage_name = "cs";
        const u32 local_x{(std::max)(program.workgroup_size[0], 1u)};
        const u32 local_y{(std::max)(program.workgroup_size[1], 1u)};
        const u32 local_z{(std::max)(program.workgroup_size[2], 1u)};
        header += fmt::format("layout(local_size_x={},local_size_y={},local_size_z={}) in;",
                              local_x, local_y, local_z);
        break;
    }
    case Stage::Task:
    case Stage::Mesh:
        throw InvalidArgument("GLSL does not support shader stage {}", program.stage);
'@
    $glsl = Replace-Once $glsl $glslIntermediate $glslScoped 'runtime-v8 GLSL Compute scope normalization'
    Write-Utf8 $glslPath $glsl
} elseif (-not $glsl.Contains($glslMarker)) {
    $glslOld = @'
    case Stage::Compute:
        stage_name = "cs";
        const u32 local_x{(std::max)(program.workgroup_size[0], 1u)};
        const u32 local_y{(std::max)(program.workgroup_size[1], 1u)};
        const u32 local_z{(std::max)(program.workgroup_size[2], 1u)};
        header += fmt::format("layout(local_size_x={},local_size_y={},local_size_z={}) in;",
                              local_x, local_y, local_z);
        break;
    }
'@
    $glslNew = @'
    case Stage::Compute: {
        stage_name = "cs";
        const u32 local_x{(std::max)(program.workgroup_size[0], 1u)};
        const u32 local_y{(std::max)(program.workgroup_size[1], 1u)};
        const u32 local_z{(std::max)(program.workgroup_size[2], 1u)};
        header += fmt::format("layout(local_size_x={},local_size_y={},local_size_z={}) in;",
                              local_x, local_y, local_z);
        break;
    }
    case Stage::Task:
    case Stage::Mesh:
        throw InvalidArgument("GLSL does not support shader stage {}", program.stage);
    }
'@
    $glsl = Replace-Once $glsl $glslOld $glslNew 'GLSL EmitContext Task/Mesh exhaustive stage guard'
    Write-Utf8 $glslPath $glsl
}

$glslCheck = Read-Lf $glslPath
foreach ($needle in @(
    'case Stage::Compute: {',
    'case Stage::Task:',
    'case Stage::Mesh:',
    $glslMarker
)) {
    if (-not $glslCheck.Contains($needle)) { throw "Runtime-v10 GLSL EmitContext regression: missing $needle" }
}

Write-Host 'Added explicit Task/Mesh rejection to legacy GLASM and normalized GLSL Compute scope.'
git diff -- $glasmPath $glslPath
