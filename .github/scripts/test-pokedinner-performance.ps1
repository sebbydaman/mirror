$ErrorActionPreference = "Stop"

function Require-File([string]$Path, [string]$Name) {
    if (-not (Test-Path $Path)) { throw "PokeDinner parity: missing $Name ($Path)" }
    Write-Host "[PASS] $Name"
}

function Require-Text([string]$Path, [string]$Needle, [string]$Name) {
    if (-not (Test-Path $Path)) { throw "PokeDinner parity: missing required file $Path" }
    $text = Get-Content $Path -Raw
    if (-not $text.Contains($Needle)) {
        throw "PokeDinner parity: $Name missing from $Path"
    }
    Write-Host "[PASS] $Name"
}

$videoCmake = 'src/video_core/CMakeLists.txt'
$fenceManager = 'src/video_core/fence_manager.h'
$deviceMemory = 'src/core/device_memory_manager.h'
$deviceMemoryInc = 'src/core/device_memory_manager.inc'
$maxwell3d = 'src/video_core/engines/maxwell_3d.cpp'
$maxwell3dHeader = 'src/video_core/engines/maxwell_3d.h'
$arm64 = 'src/core/arm/dynarmic/arm_dynarmic_64.cpp'
$vkRasterizer = 'src/video_core/renderer_vulkan/vk_rasterizer.cpp'
$vkScheduler = 'src/video_core/renderer_vulkan/vk_scheduler.cpp'
$vkSchedulerHeader = 'src/video_core/renderer_vulkan/vk_scheduler.h'
$vkPresent = 'src/video_core/renderer_vulkan/vk_present_manager.cpp'
$bufferBase = 'src/video_core/buffer_cache/buffer_cache_base.h'
$bufferCache = 'src/video_core/buffer_cache/buffer_cache.h'
$rangeSets = 'src/common/range_sets.inc'
$containerHash = 'src/common/container_hash.h'
$macroMemo = 'src/video_core/macro_memo.h'
$macroCpp = 'src/video_core/macro.cpp'
$keplerCompute = 'src/video_core/engines/kepler_compute.cpp'
$gpuSplit = 'src/video_core/gpu_split.cpp'
$gpuSplitHeader = 'src/video_core/gpu_split.h'
$mmeJit = 'src/video_core/macro_turing_jit.h'

# Fence hot path: skip empty fences, batch already-signaled fences, and keep the one-pass
# overlap subtraction used by buffer downloads.
Require-Text $fenceManager 'SkipEmptyFence()' 'empty-fence skip path'
Require-Text $fenceManager 'EDEN_NX2_FENCE_BATCH' 'fence batching debug toggle'
Require-Text $fenceManager 'size_t{64}' '64-fence default batch size'
Require-Text $rangeSets 'm_split_ranges_set.erase(it++);' 'single-pass overlap range subtraction'

# Thread-safety/per-call CPU wins from the PokeDinner lineage.
Require-Text $deviceMemory 'static inline thread_local TranslationCache t_cache{};' 'per-thread device-memory translation cache'
Require-Text $deviceMemory 'translation_generation{1}' 'translation-cache generation counter'
Require-Text $deviceMemoryInc 'translation_generation.fetch_add(1' 'map/unmap translation invalidation'
Require-Text $maxwell3d 'EDEN_NX2_MACRO_COPY' 'stack macro-parameter fast path toggle'
Require-Text $maxwell3d 'std::array<u32, 64> parameters;' 'stack macro-parameter copy path'
Require-Text $arm64 'EDEN_NX2_CNTPCT_PAUSE' 'CNTVCT/CNTPCT spin-poll pause mitigation'

# Vulkan submission overhead and async-present correctness.
Require-Text $vkRasterizer 'CHECK_MASK = 31;' 'Vulkan worker dispatch every 32 draws'
Require-Text $vkScheduler 'worker_waiting' 'wake Vulkan worker only when waiting'
Require-Text $vkSchedulerHeader 'WaitForSubmission' 'async-present scheduler no-cross-thread-flush guard'
Require-Text $vkPresent 'AcquireNextImage(!use_present_thread)' 'async-present safe acquire path'

# Buffer/inline hot paths. Per-fence downloads stay disabled by default for native-tiled Switch 2
# memory; EDEN_NX2_BUFFER_DOWNLOADS=1 remains a correctness/debug fallback.
Require-Text $bufferBase 'EDEN_NX2_BUFFER_DOWNLOADS' 'Switch 2 per-fence buffer-download toggle'
Require-Text $bufferBase 'return gpu_memory == nullptr || !gpu_memory->UsesNativeTiling();' 'Switch 2 buffer-download optimized default'
Require-Text $containerHash 'struct FastHash<Key>' 'pass-through integer/pointer hash path'
Require-Text $rangeSets 'bool RangeSet<AddressType>::Intersects' 'one-lookup RangeSet intersection path'
Require-Text $bufferCache 'gpu_modified_ranges.Intersects(addr, size)' 'one-lookup GPU-modified buffer query'
Require-Text $vkRasterizer 'EDEN_NX2_INLINE_DEFER' 'deferred inline invalidation toggle'
Require-Text $maxwell3dHeader 'EDEN_NX2_SKIP_SAME' 'same-value register-write skip toggle'
Require-Text $bufferBase 'u64 buffer_bytes = 0;' 'Switch 2 buffer-only collector accounting'
Require-Text $bufferCache 'buffer_bytes >= 1_GiB' 'Switch 2 buffer collector threshold'
Require-Text $bufferCache 'RunGarbageCollector(buffer_bytes >= 2_GiB);' 'Switch 2 aggressive buffer collector threshold'

# Macro execution: memo compaction plus x86-64 Turing MME JIT for both 3D and compute.
Require-Text $macroMemo 'void Compact()' 'macro memo arena compaction'
Require-File $mmeJit 'Turing MME x86-64 JIT source'
Require-Text $macroCpp 'EDEN_NX2_MME_JIT' '3D MME JIT toggle'
Require-Text $keplerCompute 'EDEN_NX2_MME_JIT' 'compute MME JIT toggle'
Require-Text $keplerCompute 'native_registers[method] = argument;' 'native-compute direct register fast path'

# Split GPU front/back pipeline. Mode 2 is the donor default, running macros on the front when safe.
Require-File $gpuSplitHeader 'split GPU front/back interface'
Require-Text $videoCmake 'gpu_split.cpp' 'split GPU source wired into video_core'
Require-Text $gpuSplit 'EDEN_NX2_SPLIT' 'split GPU toggle'
Require-Text $gpuSplit "return value != nullptr ? value[0] : '2';" 'split GPU mode-2 default'
Require-Text $gpuSplit 'EDEN_NX2_MME_JIT' 'split-front compiled macro gate'
Require-Text $gpuSplit 'front_macros = mode == ' 'split-front macro execution mode'

# Session reset fix: launching another Switch 2 game in the same Eden process must start a clean
# ring and must not retain freed engine pointers or stale publication positions.
Require-Text $gpuSplit 'ring.reset();' 'split ring reset on stop'
Require-Text $gpuSplit 'write_position = 0;' 'split write-position reset'
Require-Text $gpuSplit 'front_engine = nullptr;' 'split front-engine reset'
Require-Text $gpuSplit 'back_engine = nullptr;' 'split back-engine reset'
Require-Text $gpuSplit 'front_macros = false;' 'split front-macro reset'
Require-Text $gpuSplit 'published.store(0' 'split published-position reset'
Require-Text $gpuSplit 'consumed.store(0' 'split consumed-position reset'

Write-Host 'PokeDinner performance parity validation passed.'
