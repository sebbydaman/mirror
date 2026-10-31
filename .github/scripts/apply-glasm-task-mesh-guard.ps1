$ErrorActionPreference = "Stop"

# Eglantine is checked out separately by the workflow, so fixes committed to the
# automation repository's src/ tree do not affect the compiled eden/ tree.
# Keep GLASM exhaustive for the shared Stage enum without pretending that this
# legacy backend implements native Task/Mesh shaders. Vulkan remains the native
# Task/Mesh path.
$path = "src/shader_recompiler/backend/glasm/glasm_emit_context.cpp"
$text = Get-Content $path -Raw

if (-not $text.Contains('#include <stdexcept>')) {
    $anchor = '#include "shader_recompiler/backend/bindings.h"'
    if (-not $text.Contains($anchor)) { throw "Could not locate GLASM include anchor" }
    $text = $text.Replace($anchor, "#include <stdexcept>`n`n$anchor")
}

if (-not $text.Contains('case Stage::Task:')) {
    $old = @'
    case Stage::Compute:
        stage_name = "invocation";
        break;
'@
    $new = @'
    case Stage::Compute:
        stage_name = "invocation";
        break;
    case Stage::Task:
    case Stage::Mesh:
        throw std::logic_error("Task/Mesh shaders are not supported by the GLASM backend");
'@
    if (-not $text.Contains($old)) { throw "Could not locate GLASM Compute stage switch anchor" }
    $text = $text.Replace($old, $new)
}

if (-not $text.Contains('case Stage::Task:') -or
    -not $text.Contains('case Stage::Mesh:') -or
    -not $text.Contains('Task/Mesh shaders are not supported by the GLASM backend')) {
    throw "GLASM Task/Mesh guard regression"
}

Set-Content -Path $path -Value $text -Encoding utf8 -NoNewline
Write-Host "Added explicit unsupported Task/Mesh handling to Eglantine GLASM backend."
