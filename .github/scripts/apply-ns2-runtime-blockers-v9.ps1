$ErrorActionPreference = 'Stop'

# Native task/mesh pipeline layer B: add explicit shader identities and Vulkan stage mapping
# without changing Eden's legacy guest-stage index space. MaxStageTypes remains 6 and
# StageFromIndex continues to map only VertexB..Compute, so OpenGL/device arrays and the
# classic Maxwell five-stage graphics pipeline cannot accidentally index Task/Mesh yet.
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

$stagePath = 'src/shader_recompiler/stage.h'
$stage = Read-Lf $stagePath
if (-not $stage.Contains('    Task,')) {
    # Use VertexA/end-of-enum as the stable anchor. Earlier NS2 patches do not alter this
    # boundary, while whitespace around Compute has varied between Eglantine snapshots.
    $old = "    VertexA,`n};"
    $new = @'
    VertexA,

    // Switch 2 native pre-raster stages. These deliberately live outside the legacy
    // StageFromIndex/MaxStageTypes range until the dedicated mesh pipeline owns them.
    Task,
    Mesh,
};
'@
    $stage = Replace-Once $stage $old $new.TrimEnd("`r", "`n") 'isolated Task/Mesh shader identities'
    Write-Utf8 $stagePath $stage
}

$vkPath = 'src/video_core/renderer_vulkan/maxwell_to_vk.cpp'
$vk = Read-Lf $vkPath
if (-not $vk.Contains('case Shader::Stage::Task:')) {
    # The switch ends directly after Compute in the 01effa base; there is no default case.
    # Anchor on Compute + the closing brace + the existing diagnostic so this cannot match
    # another switch elsewhere in the file.
    $old = @'
    case Shader::Stage::Compute:
        return VK_SHADER_STAGE_COMPUTE_BIT;
    }
    UNIMPLEMENTED_MSG("Unimplemented shader stage={}", stage);
'@
    $new = @'
    case Shader::Stage::Compute:
        return VK_SHADER_STAGE_COMPUTE_BIT;
    case Shader::Stage::Task:
        return VK_SHADER_STAGE_TASK_BIT_EXT;
    case Shader::Stage::Mesh:
        return VK_SHADER_STAGE_MESH_BIT_EXT;
    }
    UNIMPLEMENTED_MSG("Unimplemented shader stage={}", stage);
'@
    $vk = Replace-Once $vk $old $new 'Vulkan Task/Mesh stage mapping'
    Write-Utf8 $vkPath $vk
}

# StageName is compiled with exhaustive-switch warnings enabled. Once Task/Mesh are added to
# Shader::Stage, leaving this switch unchanged makes MSVC C4062 fail the video_core build even
# though the Vulkan mapping itself is valid. Keep the names explicit rather than adding a
# default so future stage additions still trigger the same compile-time integration check.
$spirvPath = 'src/shader_recompiler/backend/spirv/spirv_emit_context.cpp'
$spirv = Read-Lf $spirvPath
if (-not $spirv.Contains('case Stage::Task:')) {
    $old = @'
    case Stage::Geometry:
        return "gs";
    case Stage::Fragment:
        return "fs";
'@
    $new = @'
    case Stage::Geometry:
        return "gs";
    case Stage::Task:
        return "task";
    case Stage::Mesh:
        return "mesh";
    case Stage::Fragment:
        return "fs";
'@
    $spirv = Replace-Once $spirv $old $new 'SPIR-V Task/Mesh stage names'
    Write-Utf8 $spirvPath $spirv
}

# The legacy NVN driver-buffer tables below have descriptor bases only for the original
# Vertex/Tessellation/Geometry/Fragment/Compute stages. Task/Mesh do not own entries in those
# tables yet. Handle the new enum values explicitly so /we4062 remains useful, but fall through
# to the existing InvalidArgument instead of guessing a descriptor base and risking corruption.
$collectPath = 'src/shader_recompiler/ir_opt/collect_shader_info_pass.cpp'
$collect = Read-Lf $collectPath
if (-not $collect.Contains('case Stage::Task: // Task/Mesh have no legacy NVN buffer base.')) {
    $old = @'
        case Stage::Compute:
            return 0x310u;
        }
        throw InvalidArgument("Invalid stage {}", program.stage);
'@
    $new = @'
        case Stage::Compute:
            return 0x310u;
        case Stage::Task: // Task/Mesh have no legacy NVN buffer base.
        case Stage::Mesh:
            break;
        }
        throw InvalidArgument("Invalid stage {}", program.stage);
'@
    $collect = Replace-Once $collect $old $new 'CollectShaderInfo Task/Mesh exhaustive stage handling'
    Write-Utf8 $collectPath $collect
}

$translatePath = 'src/shader_recompiler/frontend/maxwell/translate_program.cpp'
$translate = Read-Lf $translatePath
if (-not $translate.Contains('case Stage::Task: // Task/Mesh have no legacy NVN storage-buffer base.')) {
    $old = @'
        case Stage::Compute:
            return 0x310u;
        }
        throw InvalidArgument("Invalid stage {}", program.stage);
'@
    $new = @'
        case Stage::Compute:
            return 0x310u;
        case Stage::Task: // Task/Mesh have no legacy NVN storage-buffer base.
        case Stage::Mesh:
            break;
        }
        throw InvalidArgument("Invalid stage {}", program.stage);
'@
    $translate = Replace-Once $translate $old $new 'AddNVNStorageBuffers Task/Mesh exhaustive stage handling'
    Write-Utf8 $translatePath $translate
}

$stageCheck = Read-Lf $stagePath
$vkCheck = Read-Lf $vkPath
$spirvCheck = Read-Lf $spirvPath
$collectCheck = Read-Lf $collectPath
$translateCheck = Read-Lf $translatePath
foreach ($needle in @(
    '    Task,',
    '    Mesh,',
    'constexpr u32 MaxStageTypes = 6;',
    'return static_cast<Stage>(static_cast<size_t>(Stage::VertexB) + index);'
)) {
    if (-not $stageCheck.Contains($needle)) { throw "Runtime-v9 stage regression: missing $needle" }
}
foreach ($needle in @(
    'case Shader::Stage::Task:',
    'return VK_SHADER_STAGE_TASK_BIT_EXT;',
    'case Shader::Stage::Mesh:',
    'return VK_SHADER_STAGE_MESH_BIT_EXT;'
)) {
    if (-not $vkCheck.Contains($needle)) { throw "Runtime-v9 Vulkan stage regression: missing $needle" }
}
foreach ($needle in @(
    'case Stage::Task:',
    'return "task";',
    'case Stage::Mesh:',
    'return "mesh";'
)) {
    if (-not $spirvCheck.Contains($needle)) { throw "Runtime-v9 SPIR-V stage-name regression: missing $needle" }
}
foreach ($needle in @(
    'case Stage::Task: // Task/Mesh have no legacy NVN buffer base.',
    'case Stage::Mesh:',
    'throw InvalidArgument("Invalid stage {}", program.stage);'
)) {
    if (-not $collectCheck.Contains($needle)) { throw "Runtime-v9 shader-info exhaustive-stage regression: missing $needle" }
}
foreach ($needle in @(
    'case Stage::Task: // Task/Mesh have no legacy NVN storage-buffer base.',
    'case Stage::Mesh:',
    'throw InvalidArgument("Invalid stage {}", program.stage);'
)) {
    if (-not $translateCheck.Contains($needle)) { throw "Runtime-v9 translate-program exhaustive-stage regression: missing $needle" }
}

Write-Host 'Added isolated Task/Mesh identities, Vulkan/SPIR-V mappings, and exhaustive legacy-stage guards; legacy stage indexing remains unchanged.'
git diff -- $stagePath $vkPath $spirvPath $collectPath $translatePath
