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
    $at = $Text.IndexOf($Old)
    if ($at -lt 0) { throw "Could not locate $Label" }
    if ($Text.IndexOf($Old, $at + $Old.Length) -ge 0) { throw "Ambiguous anchor for $Label" }
    return $Text.Substring(0, $at) + $New + $Text.Substring($at + $Old.Length)
}

$stagePath = 'src/shader_recompiler/stage.h'
$stage = Read-Lf $stagePath
if (-not $stage.Contains('    Task,')) {
    $old = @'
    Compute,

    VertexA,
};
constexpr u32 MaxStageTypes = 6;
'@
    $new = @'
    Compute,

    VertexA,

    // Switch 2 native pre-raster stages. These deliberately live outside the legacy
    // StageFromIndex/MaxStageTypes range until the dedicated mesh pipeline owns them.
    Task,
    Mesh,
};
constexpr u32 MaxStageTypes = 6;
'@
    $stage = Replace-Once $stage $old $new 'isolated Task/Mesh shader identities'
    Write-Utf8 $stagePath $stage
}

$vkPath = 'src/video_core/renderer_vulkan/maxwell_to_vk.cpp'
$vk = Read-Lf $vkPath
if (-not $vk.Contains('case Shader::Stage::Task:')) {
    $old = @'
    case Shader::Stage::Compute:
        return VK_SHADER_STAGE_COMPUTE_BIT;
'@
    $new = @'
    case Shader::Stage::Compute:
        return VK_SHADER_STAGE_COMPUTE_BIT;
    case Shader::Stage::Task:
        return VK_SHADER_STAGE_TASK_BIT_EXT;
    case Shader::Stage::Mesh:
        return VK_SHADER_STAGE_MESH_BIT_EXT;
'@
    $vk = Replace-Once $vk $old $new 'Vulkan Task/Mesh stage mapping'
    Write-Utf8 $vkPath $vk
}

$stageCheck = Read-Lf $stagePath
$vkCheck = Read-Lf $vkPath
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

Write-Host 'Added isolated Task/Mesh shader identities and Vulkan stage mapping; legacy stage indexing remains unchanged.'
git diff -- $stagePath $vkPath
