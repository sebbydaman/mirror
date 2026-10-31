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
$bufferCache = "src/video_core/buffer_cache/buffer_cache.h"
$drawManager = "src/video_core/engines/draw_manager.cpp"
$maxwell3d = "src/video_core/engines/maxwell_3d.cpp"
$dmaPusher = "src/video_core/dma_pusher.cpp"
$dmaHeader = "src/video_core/dma_pusher.h"
$nvhostGpu = "src/core/hle/service/nvdrv/devices/nvhost_gpu.cpp"
$nvdrv = "src/core/hle/service/nvdrv/nvdrv.cpp"

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

# #71+ generalized compatibility batch.
Require-Text $drawManager 'bool Maxwell3D::DrawManager::IsInstanceLoopMethod' 'PR51 instance-loop method classification'
Require-Text $maxwell3d 'draw_manager.HasDeferredDraw() && !DrawManager::IsInstanceLoopMethod(method)' 'PR51 deferred-instance state flush'
Require-Text $nx2 'Nx2WrittenPageBits = 12' 'PR52 GPU-written command-page tracker'
Require-Text $nx2 'Nx2MarkGpuWritten' 'PR52 GPU-write marking helper'
Require-Text $bufferCache 'Tegra::Nx2MarkGpuWritten(device_addr, size);' 'PR52 shader buffer write tracking'
Require-Text $nvdrv 'Tegra::Nx2ClearGpuWrittenPages();' 'PR52 per-session GPU-write reset'
Require-Text $dmaHeader 'std::vector<CommandHeader> submitted_words;' 'PR28 submitted pushbuffer snapshot storage'
Require-Text $nvhostGpu 'EDEN_NX2_PB_SNAPSHOT' 'PR28 submission snapshot capture'
Require-Text $dmaPusher 'const bool gpu_written = FlushGpuWrittenCommands' 'combined PR52/PR28 command coherency path'
Require-Text $dmaPusher 'IsMemoryDirty(address, size, VideoCommon::CacheType::BufferCache)' 'GPU-written command freshness check'
Require-Text $ampere 'native zero-product carry add source' 'broader 0x224 IMAD carry lowering'
Require-Text $ampere 'case 0x234: { // HSETP2 register form' '0x234 HSETP2 register lowering'
Require-Text $ampere '0x5d20000000000000ULL' 'Maxwell HSETP2 encoding preserved'
Require-Text $vkTexture 'Shader image type {} does not match view type {}' 'build-53 Vulkan image-view dimension guard'

# Ampere 0x59f has proven SURED semantics. Keep the lowering and its safety guards intact.
Require-Text $ampere 'case 0x59f: { // SURED bound/immediate 2D U32 ADD, IGN clamp.' 'Ampere 0x59f SURED lowering'
Require-Text $ampere 'native surface reduction mode' 'SURED mode validation guard'
Require-Text $ampere 'result.required_texture_buffer = binding;' 'SURED descriptor-buffer continuity'
Require-Text $ampere '0xeb40000000000000ULL' 'Maxwell SURED encoding'

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
