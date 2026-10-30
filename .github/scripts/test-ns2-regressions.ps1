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

# The integration script deliberately switches the workflow's bootstrap checkout to
# the newer nx2-experimental source before any local patches are applied.
$expectedBase = '01effa81ab0e151f8cfd674bf4da952d24645943'
$actualBase = (git rev-parse HEAD).Trim()
if ($actualBase -ne $expectedBase) {
    throw "NS2 regression: expected effective Eglantine base $expectedBase, got $actualBase"
}
Write-Host "[PASS] effective Eglantine base $actualBase"

$ampere = "src/shader_recompiler/frontend/ampere/lower_to_maxwell.h"
$shaderEnv = "src/video_core/shader_environment.cpp"
$shaderCacheCpp = "src/video_core/shader_cache.cpp"
$notImpl = "src/shader_recompiler/frontend/maxwell/translate/impl/not_implemented.cpp"
$prmt = "src/shader_recompiler/frontend/maxwell/translate/impl/integer_byte_permute.cpp"
$f2i = "src/shader_recompiler/frontend/maxwell/translate/impl/floating_point_conversion_integer.cpp"
$cmake = "src/shader_recompiler/CMakeLists.txt"
$vkGraphics = "src/video_core/renderer_vulkan/vk_graphics_pipeline.cpp"
$vkTexture = "src/video_core/renderer_vulkan/vk_texture_cache.cpp"
$textureCache = "src/video_core/texture_cache/texture_cache.h"
$nx2 = "src/video_core/nx2.h"
$bufferBase = "src/video_core/buffer_cache/buffer_cache_base.h"

# New 01effa Mario Kart World memory/texture path.
Require-Text $nx2 'Nx2SparseBlockWritten' 'NX2 sparse written-block tracking'
Require-Text $vkTexture 'SparseLayers' 'Vulkan sparse layered-image support'
Require-Text $vkTexture 'BindLayers' 'Vulkan per-layer sparse binding'
Require-Text $textureCache 'UploadsByLayer' 'per-layer large texture upload path'

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

# Bananza post-menu and blue-world runtime surfaces captured from the user's logs.
Require-Text $bufferBase 'constexpr u32 NUM_STORAGE_BUFFERS = 32;' '32 native storage-buffer slots'
Require-Text $ampere '(width != 0 && width != 4 && width != 5)' 'B82 32-bit indexed constant load'
Require-Text $ampere '(target >= 28 && target != 63)' 'VOTEU extended uniform target range'
Require-Text $ampere 'const bool word = (mode & ~0x1c100U) == 0x00203000;' 'F2I 32-bit rounding family'
Require-Text $ampere 'case 0x308: case 0xb08: case 0xd08: { // MUFU' 'D08 uniform-source MUFU lowering'

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
