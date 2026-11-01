$ErrorActionPreference = 'Stop'

function Require-Text([string]$Path, [string]$Needle, [string]$Name) {
    if (-not (Test-Path $Path)) { throw "Late NS2 regression: missing required file $Path" }
    $text = Get-Content $Path -Raw
    if (-not $text.Contains($Needle)) { throw "Late NS2 regression: $Name missing from $Path" }
    Write-Host "[PASS] $Name"
}

$ampere = 'src/shader_recompiler/frontend/ampere/lower_to_maxwell.h'
$deviceMemory = 'src/core/device_memory_manager.inc'
$bufferBase = 'src/video_core/buffer_cache/buffer_cache_base.h'
$bufferCache = 'src/video_core/buffer_cache/buffer_cache.h'
$vkRasterizer = 'src/video_core/renderer_vulkan/vk_rasterizer.cpp'
$vkTexture = 'src/video_core/renderer_vulkan/vk_texture_cache.cpp'
$vkTextureHeader = 'src/video_core/renderer_vulkan/vk_texture_cache.h'
$textureCache = 'src/video_core/texture_cache/texture_cache.h'
$textureBase = 'src/video_core/texture_cache/texture_cache_base.h'
$imageBase = 'src/video_core/texture_cache/image_base.h'
$textureWorkers = 'src/video_core/textures/workers.cpp'
$nx2 = 'src/video_core/nx2.h'
$gsv = 'src/core/hle/service/nx2_gsv.h'
$core = 'src/core/core.cpp'
$lifecycle = 'src/core/hle/service/am/lifecycle_manager.cpp'
$appFunctions = 'src/core/hle/service/am/service/application_functions.cpp'
$gpuSplit = 'src/video_core/gpu_split.cpp'
$pipelineCache = 'src/video_core/renderer_vulkan/vk_pipeline_cache.cpp'

# Splatoon Raiders / Welcome Tour donor correctness. These are explicit because a build that merely
# compiles can silently lose them during future Ampere/device-memory conflict resolution.
Require-Text $deviceMemory 'An unmapped page says nothing about the pages after it' 'Splatoon/Raiders stale WalkBlock page fix'
Require-Text $ampere 'Bit 90 (word 2 bit 26) is the sign of the LOD' 'signed-LOD gradient texture acceptance'
Require-Text $ampere '2D gather with per-texel offsets' 'TLD4 .PTP per-texel gather lowering'
Require-Text $ampere 'TXD 2D or ARRAY_2D, four channels; the two destination pairs anywhere.' 'Splatoon Raiders 2D TXD split-destination lowering'
Require-Text $gsv 'seen on Mario Kart World and Splatoon Raiders' 'generic 1920x1080 Switch 2 handheld crop'

# Title-4/PokeDinner shader forms that are easy to lose in a large lower_to_maxwell conflict. These
# include its high-frequency 64-bit carry chain and the per-primitive hint that has no Maxwell
# attribute equivalent and is deliberately dropped rather than rejecting the whole pipeline.
Require-Text $ampere 'TMML (LOD query), 2D. Results are 8.8 fixed point' 'native TMML 2D LOD query lowering'
Require-Text $ampere 'opcode == 0x322 && address == 0x5c && components == 1' 'Ampere a[0x5c] per-primitive hint drop'
Require-Text $ampere 'carry = (a + b) < a, unsigned' 'IADD3/UIADD3 carry-out lowering'
Require-Text $ampere 'const bool carry_in = insn.Bits(74, 1) != 0;' 'IADD3/UIADD3 carry-in lowering'

# Eglantine first-read traps merged with PokeDinner selective copyback.
Require-Text $bufferBase 'bool FlushesOnCpuRead() const' 'CPU-read buffer flush mode'
Require-Text $bufferBase 'void ArmReadTraps(DAddr device_addr, u64 size)' 'buffer-cache first-read trap arming'
Require-Text $bufferBase 'read_trapped_ranges.Add(begin, end - begin);' 'read-trap lifetime tracking'
Require-Text $bufferCache 'read_trapped_ranges.Subtract(slot_buffers[buffer_id].CpuAddr()' 'read-trap cleanup on buffer deletion'
Require-Text $vkRasterizer 'if (buffer_cache.FlushesOnCpuRead())' 'Vulkan CPU-read readback path'

# Sparse virtual textures: large unwritten pools stay unbacked/zero until the first CPU or GPU write,
# then get replaced. This is distinct from merely accounting their memory correctly.
Require-Text $nx2 'inline bool Nx2SparseUnwritten' 'unwritten sparse-region query'
Require-Text $vkTexture 'bool IsUnwrittenSparse' 'unwritten sparse Vulkan image selection'
Require-Text $imageBase 'UnwrittenSparse = 1 << 21' 'unwritten sparse image lifetime flag'
Require-Text $textureCache 'True(image.flags & ImageFlagBits::UnwrittenSparse)' 'unwritten sparse first-write replacement path'

# Texture-churn performance: unmapped GPU images reuse a stable stand-in address instead of being
# recreated every lookup, and opaque ASTC uses half-sized BC1 rather than BC3 when recompression is
# active. These were a large VRAM/collector win on the donor title-1 attract loop.
Require-Text $textureBase 'The CPU address an image at gpu_addr is keyed by: its backing, or a fixed stand-in.' 'stable unmapped-image stand-in addressing'
Require-Text $textureCache 'fixed by the GPU address' 'unmapped-image reuse implementation'
Require-Text $vkTexture 'EDEN_NX2_ASTC_BC1' 'opaque ASTC-to-BC1 policy and rollback switch'
Require-Text $vkTexture 'IsOpaqueBc1Astc' 'opaque ASTC BC1 Vulkan path'

# Async ASTC decode performance/stability: reserve CPU for the emulated CPU/GPU threads, allow an
# explicit override, never erase a decode while its mutex lock still owns freed storage, and cancel
# decodes whose image is being deleted so stale data cannot land in a reused slot.
Require-Text $textureWorkers 'EDEN_NX2_TRANSCODE_THREADS' 'ASTC transcode-thread override'
Require-Text $textureWorkers 'std::thread::hardware_concurrency() / 4' 'quarter-thread ASTC transcode default'
Require-Text $textureCache 'Release the lock before the context is erased below' 'async decode mutex lifetime fix'
Require-Text $textureCache 'async_decode->cancelled = true;' 'async decode cancellation on image deletion'

# Late sparse-memory deadlock fix and precise VRAM accounting.
Require-Text $gsv 'struct MappedBacking {' 'GPU/guest mapping deadlock separation'
Require-Text $gsv 'BlockPending = 3' 'sparse backing pending-state arbitration'
Require-Text $gsv 'm_region_cv.wait' 'concurrent sparse-backing wait path'
Require-Text $vkTexture 'UseBc3ForSwitch2OnSmallCards(device);' 'early Switch 2 ASTC low-VRAM policy'
Require-Text $vkTextureHeader 'u64 SparseBoundBytes() const noexcept' 'actual sparse Vulkan memory accounting'
Require-Text $textureCache 'u64 TextureCache<P>::ImageMemoryBytes' 'texture collector actual-memory accounting'
Require-Text $textureCache 'TextureCache<P>::BindSparseLayers' 'sparse layer memory delta accounting'

# Live docked/handheld switching must notify the guest, while command 210 exposes the refresh event
# only to Switch 2 processes.
Require-Text $core 'GetAppletManager().OperationModeChanged();' 'running-game operation-mode notification'
Require-Text $lifecycle 'm_operation_mode_refresh_event.Signal(kernel);' 'Switch 2 operation-mode refresh signal'
Require-Text $appFunctions 'process->IsSwitch2()' 'operation-mode refresh event Switch 2 gate'

# Two broad stability fixes that are already in the combined donor lineage and must stay there.
Require-Text $gpuSplit 'if (active && !allowed)' 'mid-game GPU-accuracy split shutdown'
Require-Text $pipelineCache 'temporary += ".tmp";' 'atomic Vulkan pipeline-cache temporary file'
Require-Text $pipelineCache 'std::filesystem::rename(temporary, filename, error);' 'atomic Vulkan pipeline-cache publish'

Write-Host 'Late NS2 / Splatoon-Raiders regression validation passed.'
