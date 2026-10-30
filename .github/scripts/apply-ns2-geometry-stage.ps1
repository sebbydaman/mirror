$ErrorActionPreference = "Stop"

# Admit native Turing/Ampere geometry shaders only when the 0x50-byte SPH already
# decodes into the fields Eden's existing Maxwell geometry frontend consumes.
# This deliberately keeps tessellation and other native stages rejected and does
# not synthesize or guess header state.
$shaderEnvPath = "src/video_core/shader_environment.cpp"
$shaderEnvText = Get-Content $shaderEnvPath -Raw

$oldGuard = @'
        if (program != Maxwell::ShaderType::VertexB && program != Maxwell::ShaderType::Pixel) {
            throw Shader::RuntimeError("Unsupported native graphics shader stage {}", static_cast<u32>(program));
        }
'@

$newGuard = @'
        const bool native_geometry = program == Maxwell::ShaderType::Geometry;
        if (program != Maxwell::ShaderType::VertexB && program != Maxwell::ShaderType::Pixel &&
            !native_geometry) {
            throw Shader::RuntimeError("Unsupported native graphics shader stage {}", static_cast<u32>(program));
        }
        if (native_geometry) {
            const auto topology = static_cast<Shader::OutputTopology>(sph.common3.output_topology);
            const bool valid_topology = topology == Shader::OutputTopology::PointList ||
                                        topology == Shader::OutputTopology::LineStrip ||
                                        topology == Shader::OutputTopology::TriangleStrip;
            const u32 output_vertices = sph.common4.max_output_vertices;
            const u32 invocations = sph.common2.threads_per_input_primitive;
            if (!valid_topology || output_vertices == 0 || invocations == 0) {
                throw Shader::RuntimeError(
                    "Invalid native geometry SPH: topology={} output_vertices={} invocations={}",
                    static_cast<u32>(topology), output_vertices, invocations);
            }
        }
'@

if ($shaderEnvText.Contains($oldGuard.TrimEnd("`r", "`n"))) {
    $shaderEnvText = $shaderEnvText.Replace(
        $oldGuard.TrimEnd("`r", "`n"),
        $newGuard.TrimEnd("`r", "`n"))
} elseif ($shaderEnvText.Contains('const bool native_geometry = program == Maxwell::ShaderType::Geometry;')) {
    Write-Host "Validated native geometry stage admission already present."
} else {
    throw "Could not locate native graphics stage guard"
}

# Keep optional native diagnostics pointed at the matching per-stage constant
# buffer table when geometry is active (VertexB=0, Geometry=3, Pixel=4).
$oldDiagnosticStage = '            const u32 native_stage = program == Maxwell::ShaderType::Pixel ? 4 : 0;'
$newDiagnosticStage = @'
            const u32 native_stage = program == Maxwell::ShaderType::Pixel
                                         ? 4
                                         : (program == Maxwell::ShaderType::Geometry ? 3 : 0);
'@
if ($shaderEnvText.Contains($oldDiagnosticStage)) {
    $shaderEnvText = $shaderEnvText.Replace(
        $oldDiagnosticStage,
        $newDiagnosticStage.TrimEnd("`r", "`n"))
}

Set-Content -Path $shaderEnvPath -Value $shaderEnvText -Encoding utf8 -NoNewline
Write-Host "Enabled validated native geometry stage admission."

git diff -- src/video_core/shader_environment.cpp
