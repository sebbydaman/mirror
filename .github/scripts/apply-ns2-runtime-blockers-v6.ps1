$ErrorActionPreference = 'Stop'

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

# Strictly validated native tessellation-evaluation admission. Preserve build167 mesh-slot admission.
$shaderEnvPath = 'src/video_core/shader_environment.cpp'
$shaderEnv = Read-Lf $shaderEnvPath
if (-not $shaderEnv.Contains('const bool native_tessellation_eval = program == Maxwell::ShaderType::Tessellation;')) {
    $oldGuard = @'
        const bool native_geometry = program == Maxwell::ShaderType::Geometry;
        if (program != Maxwell::ShaderType::VertexB && program != Maxwell::ShaderType::Pixel &&
            !mesh_slot && !native_geometry) {
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
    $newGuard = @'
        const bool native_geometry = program == Maxwell::ShaderType::Geometry;
        const bool native_tessellation_eval = program == Maxwell::ShaderType::Tessellation;
        if (program != Maxwell::ShaderType::VertexB && program != Maxwell::ShaderType::Pixel &&
            !mesh_slot && !native_geometry && !native_tessellation_eval) {
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
        if (native_tessellation_eval) {
            if (static_cast<u32>(sph.common0.sph_type) != 1 ||
                static_cast<u32>(sph.common0.shader_type) != static_cast<u32>(program)) {
                throw Shader::RuntimeError(
                    "Invalid native tessellation SPH: sph_type={} shader_type={} program={}",
                    static_cast<u32>(sph.common0.sph_type),
                    static_cast<u32>(sph.common0.shader_type), static_cast<u32>(program));
            }
        }
'@
    $shaderEnv = Replace-Once $shaderEnv $oldGuard $newGuard 'native tessellation-eval stage guard'
    $oldDiagnostic = @'
            const u32 native_stage = program == Maxwell::ShaderType::Pixel
                                         ? 4
                                         : (program == Maxwell::ShaderType::Geometry ? 3 : 0);
'@
    $newDiagnostic = @'
            const u32 native_stage = program == Maxwell::ShaderType::Pixel
                                         ? 4
                                         : (program == Maxwell::ShaderType::Geometry
                                                ? 3
                                                : (program == Maxwell::ShaderType::Tessellation ? 2 : 0));
'@
    $shaderEnv = Replace-Once $shaderEnv $oldDiagnostic $newDiagnostic 'native graphics diagnostic stage mapping'
    Write-Utf8 $shaderEnvPath $shaderEnv
}
$check = Read-Lf $shaderEnvPath
foreach ($needle in @('const bool native_tessellation_eval = program == Maxwell::ShaderType::Tessellation;','!mesh_slot && !native_geometry && !native_tessellation_eval','static_cast<u32>(sph.common0.shader_type) != static_cast<u32>(program)','Invalid native tessellation SPH:','program == Maxwell::ShaderType::Tessellation ? 2 : 0')) {
    if (-not $check.Contains($needle)) { throw "Runtime-v6 tessellation regression: missing $needle" }
}
Write-Host 'Enabled strictly validated native Tessellation evaluation-stage admission while preserving build167 mesh-slot admission; unknown task/mesh semantics remain rejected by the Ampere lowering.'

# Native task/mesh capability foundation. Build167 may already provide individual pieces, so every
# addition is independently idempotent; one native feature or accessor must not suppress the rest.
$vkHeaderPath = 'src/video_core/vulkan_common/vulkan_device.h'
$vkHeader = Read-Lf $vkHeaderPath
if (-not $vkHeader.Contains('FEATURE(EXT, MeshShader, MESH_SHADER, mesh_shader)')) {
    $anchor = '    FEATURE(EXT, LineRasterization, LINE_RASTERIZATION, line_rasterization)                        \'
    $vkHeader = Replace-Once $vkHeader $anchor ($anchor + "`n" + '    FEATURE(EXT, MeshShader, MESH_SHADER, mesh_shader)                                        \') 'VK_EXT_mesh_shader feature macro'
}
if (-not $vkHeader.Contains('EXTENSION_NAME(VK_EXT_MESH_SHADER_EXTENSION_NAME)')) {
    $anchor = '    EXTENSION_NAME(VK_EXT_LINE_RASTERIZATION_EXTENSION_NAME)                                       \'
    $vkHeader = Replace-Once $vkHeader $anchor ($anchor + "`n" + '    EXTENSION_NAME(VK_EXT_MESH_SHADER_EXTENSION_NAME)                                              \') 'mesh shader recommended extension'
}
if (-not $vkHeader.Contains('FEATURE_NAME(mesh_shader, meshShader)')) {
    $anchor = '    FEATURE_NAME(index_type_uint8, indexTypeUint8)                                                 \'
    $vkHeader = Replace-Once $vkHeader $anchor ($anchor + "`n" + '    FEATURE_NAME(mesh_shader, meshShader)                                                          \') 'mesh recommended feature'
}
if (-not $vkHeader.Contains('FEATURE_NAME(mesh_shader, taskShader)')) {
    $anchor = '    FEATURE_NAME(mesh_shader, meshShader)                                                          \'
    $vkHeader = Replace-Once $vkHeader $anchor ($anchor + "`n" + '    FEATURE_NAME(mesh_shader, taskShader)                                                          \') 'task recommended feature'
}
if (-not $vkHeader.Contains('bool IsExtMeshShaderSupported() const')) {
    $anchor = @'
    /// Returns true if the device supports VK_EXT_transform_feedback.
    bool IsExtTransformFeedbackSupported() const {
        return extensions.transform_feedback;
    }
'@
    $block = @'
    /// Returns true when a native Vulkan mesh shader stage can be created.
    bool IsExtMeshShaderSupported() const {
        return extensions.mesh_shader && features.mesh_shader.meshShader;
    }

'@
    $vkHeader = Replace-Once $vkHeader $anchor ($block + $anchor) 'mesh shader capability accessor'
}
if (-not $vkHeader.Contains('bool IsExtTaskShaderSupported() const')) {
    $meshAccessor = @'
    bool IsExtMeshShaderSupported() const {
        return extensions.mesh_shader && features.mesh_shader.taskShader &&
               features.mesh_shader.meshShader;
    }
'@
    if (-not $vkHeader.Contains($meshAccessor)) {
        $meshAccessor = @'
    bool IsExtMeshShaderSupported() const {
        return extensions.mesh_shader && features.mesh_shader.meshShader;
    }
'@
    }
    $taskAccessor = @'

    /// Returns true when the optional task shader stage is also available.
    bool IsExtTaskShaderSupported() const {
        return extensions.mesh_shader && features.mesh_shader.meshShader &&
               features.mesh_shader.taskShader;
    }
'@
    $vkHeader = Replace-Once $vkHeader $meshAccessor ($meshAccessor + $taskAccessor) 'task shader capability accessor'
}
if (-not $vkHeader.Contains('const VkPhysicalDeviceMeshShaderPropertiesEXT& GetMeshShaderProperties() const')) {
    $taskAccessor = @'
    /// Returns true when the optional task shader stage is also available.
    bool IsExtTaskShaderSupported() const {
        return extensions.mesh_shader && features.mesh_shader.meshShader &&
               features.mesh_shader.taskShader;
    }
'@
    $propertyAccessor = @'

    /// Host task/mesh workgroup, payload and output limits.
    const VkPhysicalDeviceMeshShaderPropertiesEXT& GetMeshShaderProperties() const {
        return properties.mesh_shader;
    }
'@
    $vkHeader = Replace-Once $vkHeader $taskAccessor ($taskAccessor + $propertyAccessor) 'mesh shader properties accessor'
}
if (-not $vkHeader.Contains('VkPhysicalDeviceMeshShaderPropertiesEXT mesh_shader{};')) {
    $anchor = '        VkPhysicalDeviceTransformFeedbackPropertiesEXT transform_feedback{};'
    $vkHeader = Replace-Once $vkHeader $anchor ($anchor + "`n" + '        VkPhysicalDeviceMeshShaderPropertiesEXT mesh_shader{};') 'mesh shader properties storage'
}
Write-Utf8 $vkHeaderPath $vkHeader

$vkCppPath = 'src/video_core/vulkan_common/vulkan_device.cpp'
$vkCpp = Read-Lf $vkCppPath
if (-not $vkCpp.Contains('VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MESH_SHADER_PROPERTIES_EXT')) {
    $anchor = @'
    if (extensions.transform_feedback) {
        properties.transform_feedback.sType =
            VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TRANSFORM_FEEDBACK_PROPERTIES_EXT;
        SetNext(next, properties.transform_feedback);
    }
'@
    $block = @'
    if (extensions.mesh_shader) {
        properties.mesh_shader.sType =
            VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MESH_SHADER_PROPERTIES_EXT;
        SetNext(next, properties.mesh_shader);
    }
'@
    $vkCpp = Replace-Once $vkCpp $anchor ($anchor + $block) 'mesh shader properties query chain'
}
if (-not $vkCpp.Contains('extensions.mesh_shader = features.mesh_shader.meshShader;')) {
    $anchor = @'
    // VK_EXT_transform_feedback
    extensions.transform_feedback =
        features.transform_feedback.transformFeedback &&
        properties.transform_feedback.maxTransformFeedbackBuffers > 0;
    RemoveExtensionFeatureIfUnsuitable(extensions.transform_feedback, features.transform_feedback,
                                       VK_EXT_TRANSFORM_FEEDBACK_EXTENSION_NAME);
'@
    $block = @'

    // VK_EXT_mesh_shader. Mesh is required for the native path; Task remains optional.
    extensions.mesh_shader = features.mesh_shader.meshShader;
    RemoveExtensionFeatureIfUnsuitable(extensions.mesh_shader, features.mesh_shader,
                                       VK_EXT_MESH_SHADER_EXTENSION_NAME);
'@
    $vkCpp = Replace-Once $vkCpp $anchor ($anchor + $block) 'mesh shader feature suitability'
}
Write-Utf8 $vkCppPath $vkCpp

$vkHeaderCheck = Read-Lf $vkHeaderPath
$vkCppCheck = Read-Lf $vkCppPath
foreach ($needle in @('FEATURE(EXT, MeshShader, MESH_SHADER, mesh_shader)','EXTENSION_NAME(VK_EXT_MESH_SHADER_EXTENSION_NAME)','FEATURE_NAME(mesh_shader, meshShader)','FEATURE_NAME(mesh_shader, taskShader)','bool IsExtMeshShaderSupported() const','bool IsExtTaskShaderSupported() const','const VkPhysicalDeviceMeshShaderPropertiesEXT& GetMeshShaderProperties() const','VkPhysicalDeviceMeshShaderPropertiesEXT mesh_shader{};')) {
    if (-not $vkHeaderCheck.Contains($needle)) { throw "Runtime-v6 mesh capability regression: missing $needle" }
}
foreach ($needle in @('VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MESH_SHADER_PROPERTIES_EXT','extensions.mesh_shader = features.mesh_shader.meshShader;','VK_EXT_MESH_SHADER_EXTENSION_NAME')) {
    if (-not $vkCppCheck.Contains($needle)) { throw "Runtime-v6 mesh device regression: missing $needle" }
}
Write-Host 'Exposed VK_EXT_mesh_shader/taskShader host capabilities and native mesh limits; no mesh execution is enabled yet.'

$runtimeV7Script = Join-Path $PSScriptRoot 'apply-ns2-runtime-blockers-v7.ps1'
& $runtimeV7Script

git diff -- $shaderEnvPath $vkHeaderPath $vkCppPath
