$ErrorActionPreference = "Stop"

# Eglantine is checked out separately by the workflow, so fixes committed to the
# automation repository's src/ tree do not affect the compiled eden/ tree.
# Keep legacy shader backends exhaustive for the shared Stage enum without
# pretending they implement native Task/Mesh shaders. Vulkan remains the native
# Task/Mesh path.

function Add-TaskMeshUnsupportedGuard {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ComputeBlock,
        [Parameter(Mandatory = $true)][string]$ReplacementBlock,
        [Parameter(Mandatory = $true)][string]$BackendName,
        [string]$AcceptedExistingGuard = ""
    )

    $text = Get-Content $Path -Raw
    $hasTask = $text.Contains('case Stage::Task:')
    $hasMesh = $text.Contains('case Stage::Mesh:')

    # A newer integration layer may already have installed an explicit rejection for this
    # legacy backend. Treat that as valid rather than trying to replace a second time.
    if ($hasTask -xor $hasMesh) {
        throw "$BackendName Task/Mesh guard regression: only one stage is handled"
    }

    if (-not $hasTask) {
        if (-not $text.Contains('#include <stdexcept>')) {
            $anchor = '#include "shader_recompiler/backend/bindings.h"'
            if (-not $text.Contains($anchor)) { throw "Could not locate $BackendName include anchor" }
            $text = $text.Replace($anchor, "#include <stdexcept>`n`n$anchor")
        }

        if (-not $text.Contains($ComputeBlock)) { throw "Could not locate $BackendName Compute stage switch anchor" }
        $text = $text.Replace($ComputeBlock, $ReplacementBlock)
    }

    $expectedGuard = "Task/Mesh shaders are not supported by the $BackendName backend"
    $hasExpectedGuard = $text.Contains($expectedGuard)
    $hasAcceptedGuard = $AcceptedExistingGuard -ne "" -and $text.Contains($AcceptedExistingGuard)
    if (-not $text.Contains('case Stage::Task:') -or
        -not $text.Contains('case Stage::Mesh:') -or
        (-not $hasExpectedGuard -and -not $hasAcceptedGuard)) {
        throw "$BackendName Task/Mesh guard regression"
    }

    Set-Content -Path $Path -Value $text -Encoding utf8 -NoNewline
    Write-Host "Verified explicit unsupported Task/Mesh handling in Eglantine $BackendName backend."
}

$glasmOld = @'
    case Stage::Compute:
        stage_name = "invocation";
        break;
'@
$glasmNew = @'
    case Stage::Compute:
        stage_name = "invocation";
        break;
    case Stage::Task:
    case Stage::Mesh:
        throw std::logic_error("Task/Mesh shaders are not supported by the GLASM backend");
'@
Add-TaskMeshUnsupportedGuard -Path "src/shader_recompiler/backend/glasm/glasm_emit_context.cpp" `
    -ComputeBlock $glasmOld -ReplacementBlock $glasmNew -BackendName "GLASM" `
    -AcceptedExistingGuard 'GLASM does not support shader stage'

$glslOld = @'
    case Stage::Compute:
        stage_name = "cs";
        const u32 local_x{(std::max)(program.workgroup_size[0], 1u)};
        const u32 local_y{(std::max)(program.workgroup_size[1], 1u)};
        const u32 local_z{(std::max)(program.workgroup_size[2], 1u)};
        header += fmt::format("layout(local_size_x={},local_size_y={},local_size_z={}) in;",
                              local_x, local_y, local_z);
        break;
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
        throw std::logic_error("Task/Mesh shaders are not supported by the GLSL backend");
'@
Add-TaskMeshUnsupportedGuard -Path "src/shader_recompiler/backend/glsl/glsl_emit_context.cpp" `
    -ComputeBlock $glslOld -ReplacementBlock $glslNew -BackendName "GLSL"
