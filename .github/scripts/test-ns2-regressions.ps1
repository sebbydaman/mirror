$ErrorActionPreference = "Stop"

function Require-File([string]$Path) {
    if (-not (Test-Path $Path)) { throw "NS2 regression: missing required file $Path" }
}

function Require-Text([string]$Path, [string]$Needle, [string]$Name) {
    Require-File $Path
    $text = Get-Content $Path -Raw
    if (-not $text.Contains($Needle)) {
        throw "NS2 regression: $Name missing from $Path"
    }
    Write-Host "[PASS] $Name"
}

$ampere = "src/shader_recompiler/frontend/ampere/lower_to_maxwell.h"
$shaderEnv = "src/video_core/shader_environment.cpp"
$shaderCacheCpp = "src/video_core/shader_cache.cpp"
$notImpl = "src/shader_recompiler/frontend/maxwell/translate/impl/not_implemented.cpp"
$prmt = "src/shader_recompiler/frontend/maxwell/translate/impl/integer_byte_permute.cpp"
$f2i = "src/shader_recompiler/frontend/maxwell/translate/impl/floating_point_conversion_integer.cpp"
$cmake = "src/shader_recompiler/CMakeLists.txt"
$vkGraphics = "src/video_core/renderer_vulkan/vk_graphics_pipeline.cpp"

# sebbydaman/mirror shader/control-flow improvements.
Require-Text $ampere 'case 0x361: { // TEX.B, scalar bindless 2D/cube implicit-LOD sample' 'bindless 2D/cube TEX.B lowering'
Require-Text $ampere 'case 0xb6f: { // TXQ texture dimensions, packed X/Y/Z/mip-count outputs.' 'extended TXQ lowering'
Require-Text $ampere 'case 0x949: case 0x958: { // Captured BRX / BRXU with native-PC jump-table values' 'generalized BRX/BRXU lowering'
Require-Text $ampere 'case 0x924: { // OUT, immediate geometry stream: EMIT / EMIT_THEN_CUT' 'geometry OUT lowering'
Require-Text $shaderEnv 'Shader::Stage::Geometry' 'native geometry-stage admission'

# Generic overlap imported from the newer Bananza work.
Require-Text $ampere 'case 0x923:' 'geometry ISBERD map-read lowering'
Require-Text $ampere 'case 0x34e:' 'geometry LEPC lowering'
Require-Text $ampere 'case 0x357:' 'geometry prologue lowering'
Require-Text $prmt 'void TranslatorVisitor::PRMT_reg' 'Maxwell PRMT implementation'
Require-Text $cmake 'frontend/maxwell/translate/impl/integer_byte_permute.cpp' 'PRMT source wired into shader_recompiler'
Require-Text $f2i 'case DestFormat::I8:' '8-bit F2I destination decoding'
Require-Text $f2i 'std::numeric_limits<s8>::max' 'signed 8-bit F2I clamp bounds'
Require-Text $f2i 'std::numeric_limits<u8>::max' 'unsigned 8-bit F2I clamp bounds'

# PRMT must no longer be routed through the unimplemented handlers.
Require-File $notImpl
$notImplText = Get-Content $notImpl -Raw
if ($notImplText.Contains('void TranslatorVisitor::PRMT_reg')) {
    throw 'NS2 regression: PRMT_reg is still present in not_implemented.cpp'
}
Write-Host '[PASS] PRMT removed from unimplemented handlers'

# Preserve Eglantine's rejection cache.
Require-Text $shaderCacheCpp 'RememberRejection' 'negative native shader rejection cache'
Require-Text $shaderCacheCpp 'IsRejected' 'negative shader lookup path'

# Collision-safe successful-lowering cache at the native capture/lowering point.
Require-Text $shaderEnv 'NativeShaderPositiveCacheMaxEntries = 4096' 'positive native shader cache capacity'
Require-Text $shaderEnv 'FindPositiveNativeShaderCache' 'positive native shader cache lookup path'
Require-Text $shaderEnv 'StorePositiveNativeShaderCache' 'positive native shader cache store path'
Require-Text $shaderEnv 'SameNativeShader' 'positive shader exact-source collision check'

# Draw-state optimization. Use semantic markers rather than declaration spelling so harmless
# const/formatting changes do not create a false regression failure.
Require-Text $vkGraphics 'update_push_descriptors =' 'push-descriptor exact-payload cache'
Require-Text $vkGraphics 'bind_pipeline || last_descriptor_payload.size() != num_descriptor_entries' 'push-descriptor pipeline/reset guard'
Require-Text $vkGraphics 'if (update_push_descriptors)' 'conditional push-descriptor submission'
Require-Text $vkGraphics 'PushDescriptorSetWithTemplateKHR' 'Vulkan push-descriptor path preserved'

Write-Host "NS2 combined regression validation passed."
