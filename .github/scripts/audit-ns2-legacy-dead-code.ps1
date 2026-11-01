param(
    [switch]$AutomationOnly
)

$ErrorActionPreference = 'Stop'

# Dedicated legacy/dead-code audit for the fully integrated NS2 source tree plus the automation
# repository that assembles it. This has two modes:
#   -AutomationOnly: prove the live script/payload inventory and transitive call graph before any
#                    integration work touches the Eglantine tree.
#   default:          repeat the automation checks, then reject known superseded runtime shapes.
#
# Runtime cleanup policy: old code is only harmful when a superseded path can still execute. Keep
# intentional rollback/debug fallbacks, but reject duplicate active synchronization/readback paths
# that can repeat GPU waits, downloads, invalidations or stale command-memory arbitration.

function Read-Required([string]$Path) {
    if (-not (Test-Path $Path -PathType Leaf)) {
        throw "Legacy audit: missing required file $Path"
    }
    return Get-Content $Path -Raw
}

function Require-Text([string]$Path, [string]$Needle, [string]$Name) {
    $text = Read-Required $Path
    if (-not $text.Contains($Needle)) {
        throw "Legacy audit: current path missing ($Name): '$Needle' in $Path"
    }
    Write-Host "[CURRENT] $Name"
}

function Forbid-Text([string]$Path, [string]$Needle, [string]$Name) {
    $text = Read-Required $Path
    if ($text.Contains($Needle)) {
        throw "Legacy audit: superseded path returned ($Name): '$Needle' in $Path"
    }
    Write-Host "[ABSENT] $Name"
}

function Require-ScriptReference([string]$Parent, [string[]]$Children) {
    $path = Join-Path $PSScriptRoot $Parent
    $text = Read-Required $path
    foreach ($child in $Children) {
        if (-not $text.Contains($child)) {
            throw "Legacy audit: transitive automation edge disappeared: $Parent -> $child"
        }
        if (-not (Test-Path (Join-Path $PSScriptRoot $child) -PathType Leaf)) {
            throw "Legacy audit: $Parent references missing live helper $child"
        }
        Write-Host "[EDGE] $Parent -> $child"
    }
}

function Get-Section([string]$Text, [string]$StartNeedle, [string]$EndNeedle, [string]$Name) {
    $start = $Text.IndexOf($StartNeedle, [StringComparison]::Ordinal)
    if ($start -lt 0) {
        throw "Legacy audit: could not locate start of $Name"
    }
    $end = $Text.IndexOf($EndNeedle, $start + $StartNeedle.Length, [StringComparison]::Ordinal)
    if ($end -lt 0) {
        throw "Legacy audit: could not locate end of $Name"
    }
    return $Text.Substring($start, $end - $start)
}

function Require-ExactlyOne([string]$Text, [string]$Needle, [string]$Name) {
    $count = ([regex]::Matches($Text, [regex]::Escape($Needle))).Count
    if ($count -ne 1) {
        throw "Legacy audit: expected exactly one $Name, found $count"
    }
    Write-Host "[CURRENT] exactly one $Name"
}

# -----------------------------------------------------------------------------
# Automation reachability/inventory
# -----------------------------------------------------------------------------
# This is the closed set reachable from the active build/baseline workflows, including transitive
# compatibility, donor, overlay and test helpers. Old-looking names are not dead if a live parent
# still invokes them; the explicit graph below proves those relationships.
$expectedScripts = @(
    'apply-bananza-blue-screen-gpu.ps1',
    'apply-bananza-generic-overlap.ps1',
    'apply-bananza-post-menu-gpu.ps1',
    'apply-eglantine-draw-state-cache.ps1',
    'apply-eglantine-handheld-mode.ps1',
    'apply-eglantine-integration.ps1',
    'apply-eglantine-late-runtime.ps1',
    'apply-eglantine-late-stability.ps1',
    'apply-eglantine-nso-loader.ps1',
    'apply-eglantine-nx2-memory-layout.ps1',
    'apply-eglantine-positive-shader-cache.ps1',
    'apply-eglantine-pr142-memory-stutter.ps1',
    'apply-eglantine-pr48-device-memory.ps1',
    'apply-ns2-donor-20261101.ps1',
    'apply-ns2-donor-safe-perf.ps1',
    'apply-ns2-general-compat-batch-v2.ps1',
    'apply-ns2-geometry-stage.ps1',
    'apply-ns2-native-lowering-overlays.ps1',
    'apply-ns2-runtime-blockers-v10.ps1',
    'apply-ns2-runtime-blockers-v3-core.ps1',
    'apply-ns2-runtime-blockers-v3.ps1',
    'apply-ns2-runtime-blockers-v4.ps1',
    'apply-ns2-runtime-blockers-v5.ps1',
    'apply-ns2-runtime-blockers-v6.ps1',
    'apply-ns2-runtime-blockers-v7.ps1',
    'apply-ns2-runtime-blockers-v8.ps1',
    'apply-ns2-runtime-blockers-v9.ps1',
    'apply-pokedinner-v2-batch.ps1',
    'audit-ns2-legacy-dead-code.ps1',
    'capture-ns2-baseline.ps1',
    'package-ns2-runtime.ps1',
    'prep-pr142-integrated.ps1',
    'prepare-eglantine-read-trap-selective-copyback.ps1',
    'prepare-ns2-big-batch-anchors.ps1',
    'prepare-pr52-selective-copyback.ps1',
    'stage-ns2-runtime-checkpoint.ps1',
    'test-ns2-donor-20261101.ps1',
    'test-ns2-donor-safe-perf.ps1',
    'test-ns2-late-regressions.ps1',
    'test-ns2-pr142-memory-stutter.ps1',
    'test-ns2-regressions.ps1',
    'test-ns2-stability-regressions.ps1',
    'test-pokedinner-performance.ps1'
) | Sort-Object -Unique

$actualScripts = @(Get-ChildItem -Path $PSScriptRoot -Filter '*.ps1' -File | ForEach-Object Name | Sort-Object -Unique)
$missingScripts = @($expectedScripts | Where-Object { $_ -notin $actualScripts })
$unexpectedScripts = @($actualScripts | Where-Object { $_ -notin $expectedScripts })
if ($missingScripts.Count -gt 0) {
    throw "Legacy audit: live automation script(s) missing: $($missingScripts -join ', ')"
}
if ($unexpectedScripts.Count -gt 0) {
    throw "Legacy audit: unreachable/uncatalogued automation script(s) present: $($unexpectedScripts -join ', ')"
}
Write-Host "[CLEAN] automation inventory: $($actualScripts.Count) live PowerShell scripts"

$patchDir = Join-Path $PSScriptRoot '..\patches'
$expectedPayloads = @(
    'late-eglantine-runtime.patch.gz.b64',
    'ns2-handheld-mode.patch.gz.b64',
    'ns2-late-stability.patch.gz.b64'
) | Sort-Object
$actualPayloads = @(Get-ChildItem -Path $patchDir -Filter '*.b64' -File | ForEach-Object Name | Sort-Object)
$missingPayloads = @($expectedPayloads | Where-Object { $_ -notin $actualPayloads })
$unexpectedPayloads = @($actualPayloads | Where-Object { $_ -notin $expectedPayloads })
if ($missingPayloads.Count -gt 0 -or $unexpectedPayloads.Count -gt 0) {
    throw "Legacy audit: patch payload inventory mismatch; missing=[$($missingPayloads -join ', ')] unexpected=[$($unexpectedPayloads -join ', ')]"
}
Write-Host '[CLEAN] patch payload inventory: only live late-runtime/handheld/stability payloads remain'

Require-ScriptReference 'apply-eglantine-integration.ps1' @('apply-ns2-geometry-stage.ps1')
Require-ScriptReference 'apply-eglantine-positive-shader-cache.ps1' @('apply-pokedinner-v2-batch.ps1')
Require-ScriptReference 'apply-pokedinner-v2-batch.ps1' @(
    'apply-ns2-geometry-stage.ps1',
    'apply-ns2-native-lowering-overlays.ps1'
)
Require-ScriptReference 'apply-bananza-post-menu-gpu.ps1' @(
    'apply-bananza-blue-screen-gpu.ps1',
    'apply-eglantine-pr48-device-memory.ps1',
    'prepare-ns2-big-batch-anchors.ps1',
    'prepare-pr52-selective-copyback.ps1',
    'apply-ns2-general-compat-batch-v2.ps1',
    'apply-ns2-runtime-blockers-v3.ps1'
)
Require-ScriptReference 'apply-eglantine-pr48-device-memory.ps1' @('prepare-eglantine-read-trap-selective-copyback.ps1')
Require-ScriptReference 'apply-ns2-runtime-blockers-v3.ps1' @(
    'apply-ns2-runtime-blockers-v3-core.ps1',
    'apply-ns2-runtime-blockers-v4.ps1'
)
Require-ScriptReference 'apply-ns2-runtime-blockers-v4.ps1' @('apply-ns2-runtime-blockers-v5.ps1')
Require-ScriptReference 'apply-ns2-runtime-blockers-v5.ps1' @('apply-ns2-runtime-blockers-v6.ps1')
Require-ScriptReference 'apply-ns2-runtime-blockers-v6.ps1' @('apply-ns2-runtime-blockers-v7.ps1')
Require-ScriptReference 'apply-ns2-runtime-blockers-v7.ps1' @('apply-ns2-runtime-blockers-v8.ps1')
Require-ScriptReference 'apply-ns2-runtime-blockers-v8.ps1' @(
    'apply-ns2-runtime-blockers-v9.ps1',
    'apply-ns2-runtime-blockers-v10.ps1'
)
Require-ScriptReference 'apply-eglantine-late-stability.ps1' @(
    'apply-ns2-donor-20261101.ps1',
    'apply-ns2-donor-safe-perf.ps1',
    'prep-pr142-integrated.ps1',
    'apply-eglantine-pr142-memory-stutter.ps1'
)
Require-ScriptReference 'test-ns2-stability-regressions.ps1' @(
    'test-ns2-donor-20261101.ps1',
    'test-ns2-donor-safe-perf.ps1',
    'test-ns2-pr142-memory-stutter.ps1',
    'audit-ns2-legacy-dead-code.ps1'
)

# Proven-unreachable generations. These are already removed; fail if a later merge resurrects them
# or adds a reference back to them.
$knownDead = @(
    'apply-glasm-task-mesh-guard.ps1',
    'apply-ns2-build-fixes-base.ps1',
    'apply-ns2-build-fixes.ps1',
    'package-windows-runtime.ps1',
    'prep-pr142-kmemory-reset.ps1',
    'prep-pr142-vma-budget.ps1'
)
$workflowDir = Join-Path $PSScriptRoot '..\workflows'
$referenceFiles = @(
    Get-ChildItem -Path $PSScriptRoot -Filter '*.ps1' -File | Where-Object { $_.FullName -ne $PSCommandPath }
    Get-ChildItem -Path $workflowDir -File | Where-Object { $_.Extension -in @('.yml', '.yaml') }
)
foreach ($dead in $knownDead) {
    if (Test-Path (Join-Path $PSScriptRoot $dead)) {
        throw "Legacy audit: proven-dead helper was reintroduced: $dead"
    }
    foreach ($file in $referenceFiles) {
        if ((Get-Content $file.FullName -Raw).Contains($dead)) {
            throw "Legacy audit: $($file.Name) references deleted legacy helper $dead"
        }
    }
    Write-Host "[DEAD] $dead"
}

if ($AutomationOnly) {
    Write-Host 'NS2 automation reachability audit passed before source integration.'
    return
}

# -----------------------------------------------------------------------------
# Shader lowering/lifetime legacy shapes
# -----------------------------------------------------------------------------
$objectPool = 'src/shader_recompiler/object_pool.h'
Require-Text $objectPool 'std::destroy_at(&storage[index].object);' 'live object destruction in shader object pool'
Forbid-Text $objectPool 'std::destroy_n(storage.get(), used_objects);' 'union-wrapper bulk destruction'

$ampere = 'src/shader_recompiler/frontend/ampere/lower_to_maxwell.h'
Require-Text $ampere 'active_link && opcode != 0x950' 'RET/link-register reserved-destination semantics'
Require-Text $ampere 'FSEL: the sources keep their .NEG/.ABS' 'separate FSEL modifier-preserving path'
$ampereText = Read-Required $ampere
$oldCombinedSel = 'case 0x207: case 0x807: case 0xa07:' + "`n" +
                  '        case 0x208: case 0x808: case 0xa08: { // Bitwise SEL / FSEL'
if ($ampereText.Contains($oldCombinedSel)) {
    throw 'Legacy audit: old combined SEL/FSEL lowering returned and would drop FSEL modifiers'
}
Write-Host '[ABSENT] combined SEL/FSEL legacy lowering'

# -----------------------------------------------------------------------------
# ASTC/VRAM policy: keep the modern threshold path and reject older policy generations.
# -----------------------------------------------------------------------------
$vkTexture = 'src/video_core/renderer_vulkan/vk_texture_cache.cpp'
Require-Text $vkTexture 'UseBc3ForSwitch2OnSmallCards' 'threshold-based Switch 2 ASTC policy'
Require-Text $vkTexture 'memory >= 20_GiB' '20 GiB ASTC keep threshold'
Require-Text $vkTexture 'EDEN_NX2_KEEP_ASTC' 'ASTC rollback/debug override'
Forbid-Text $vkTexture 'memory >= 12_GiB' 'superseded 12 GiB ASTC threshold'
Forbid-Text $vkTexture 'void UseBc3ForSwitch2(const Device& device)' 'PR142 force-BC3-on-every-card policy'
Forbid-Text 'src/video_core/renderer_vulkan/renderer_vulkan.cpp' 'Nx2UncompressedAstcMinimumVram' 'late renderer-level ASTC override'

$vulkanDevice = 'src/video_core/vulkan_common/vulkan_device.cpp'
$vulkanText = Read-Required $vulkanDevice
$vmaMarker = 'main_statistics.blockBytes - main_statistics.allocationBytes'
$vmaCount = ([regex]::Matches($vulkanText, [regex]::Escape($vmaMarker))).Count
if ($vmaCount -ne 1) {
    throw "Legacy audit: expected exactly one main-heap VMA slack subtraction, found $vmaCount"
}
Write-Host '[CURRENT] exactly one main-heap VMA block-slack correction'

# -----------------------------------------------------------------------------
# PR142 host-RAM path: no direct legacy zero-fill remains at AllocateForProcess.
# -----------------------------------------------------------------------------
$kmPath = 'src/core/hle/kernel/k_memory_manager.cpp'
$km = Read-Required $kmPath
foreach ($marker in @(
    'void KMemoryManager::FillAllocatedPages(',
    'std::exchange(m_system.DeviceMemory().used_by_kernel, true)',
    'm_page_reference_counts.resize(size / PageSize);',
    'this->TakeFreed(offset) || fill_pattern != 0'
)) {
    if (-not $km.Contains($marker)) { throw "Legacy audit: PR142 current memory marker missing: $marker" }
}
$allocStart = $km.IndexOf('Result KMemoryManager::AllocateForProcess(', [StringComparison]::Ordinal)
$allocEnd = if ($allocStart -ge 0) { $km.IndexOf('    R_SUCCEED();', $allocStart, [StringComparison]::Ordinal) } else { -1 }
if ($allocStart -lt 0 -or $allocEnd -lt 0) {
    throw 'Legacy audit: could not isolate KMemoryManager::AllocateForProcess'
}
$allocSection = $km.Substring($allocStart, $allocEnd - $allocStart)
if ($allocSection.Contains('m_system.DeviceMemory().buffer.ClearBackingRegion(')) {
    throw 'Legacy audit: AllocateForProcess reverted to direct backing zero-fill instead of FillAllocatedPages'
}
if (-not $allocSection.Contains('this->FillAllocatedPages(block.GetAddress(), block.GetNumPages(), fill_pattern);')) {
    throw 'Legacy audit: AllocateForProcess selective FillAllocatedPages routing disappeared'
}
if ($km.Contains('std::memset(ptr + offset * PageSize, fill_pattern, PageSize);')) {
    throw 'Legacy audit: optimized allocation reverted to the donor raw memset path'
}
Write-Host '[ABSENT] legacy unconditional host-page zero-fill paths'

# -----------------------------------------------------------------------------
# Selective GPU->CPU readback/coherency.
# -----------------------------------------------------------------------------
# A blanket old GPU-write download path layered under the newer first-CPU-read/read-trap policy can
# perform the same transfer or GPU wait twice. Keep one authoritative write notification path, one
# command-page coherency helper, and the intentional async-download fallback only in QueueDownload.
$bufferCachePath = 'src/video_core/buffer_cache/buffer_cache.h'
$bufferCache = Read-Required $bufferCachePath
$markWritten = Get-Section $bufferCache 'void BufferCache<P>::MarkWrittenBuffer(' "`ntemplate <class P>" 'BufferCache::MarkWrittenBuffer'
Require-ExactlyOne $markWritten 'QueueDownload(device_addr, size);' 'MarkWrittenBuffer selective QueueDownload call'
Require-ExactlyOne $markWritten 'Tegra::Nx2MarkGpuWritten(device_addr, size);' 'MarkWrittenBuffer NX2 GPU-write history marker'
if ($markWritten.Contains('uncommitted_gpu_modified_ranges.Add(device_addr')) {
    throw 'Legacy audit: MarkWrittenBuffer still contains a direct blanket download-range add beside QueueDownload'
}
$queuePos = $markWritten.IndexOf('QueueDownload(device_addr, size);', [StringComparison]::Ordinal)
$historyPos = $markWritten.IndexOf('Tegra::Nx2MarkGpuWritten(device_addr, size);', [StringComparison]::Ordinal)
if ($queuePos -lt 0 -or $historyPos -lt $queuePos) {
    throw 'Legacy audit: GPU-write history is no longer layered after the selective QueueDownload path'
}
Write-Host '[ABSENT] duplicate blanket MarkWrittenBuffer download path'

Require-Text $bufferCachePath 'QueueDownload(new_base_address, size);' 'selective DMACopy QueueDownload routing'
$oldDmaCopy = @'
        if (AsyncBufferDownloads()) {
            uncommitted_gpu_modified_ranges.Add(new_base_address, size);
        }
'@
if ($bufferCache.Contains($oldDmaCopy.TrimEnd("`r", "`n"))) {
    throw 'Legacy audit: old inline DMACopy async-download block returned beside selective QueueDownload'
}
Write-Host '[ABSENT] legacy inline DMACopy async-download block'

$bufferBasePath = 'src/video_core/buffer_cache/buffer_cache_base.h'
$bufferBase = Read-Required $bufferBasePath
$queueDownload = Get-Section $bufferBase 'void QueueDownload(DAddr addr, u64 size) {' "`n    // Async Buffers" 'BufferCache::QueueDownload'
foreach ($marker in @(
    'cpu_read_ranges.ForEachInRange(addr, size',
    'covered < size',
    'ArmReadTraps(addr, size);'
)) {
    if (-not $queueDownload.Contains($marker)) {
        throw "Legacy audit: selective QueueDownload marker missing: $marker"
    }
}
$directAdd = 'uncommitted_gpu_modified_ranges.Add(addr, size);'
$directAddCount = ([regex]::Matches($queueDownload, [regex]::Escape($directAdd))).Count
if ($directAddCount -gt 1) {
    throw "Legacy audit: QueueDownload contains $directAddCount blanket range-add sites; expected at most the single async-download fallback"
}
$cpuReadPos = $queueDownload.IndexOf('cpu_read_ranges.ForEachInRange(addr, size', [StringComparison]::Ordinal)
$trapPos = $queueDownload.IndexOf('ArmReadTraps(addr, size);', [StringComparison]::Ordinal)
if ($cpuReadPos -lt 0 -or $trapPos -lt $cpuReadPos) {
    throw 'Legacy audit: QueueDownload no longer resolves known CPU-read ranges before arming first-read traps'
}
Write-Host '[CURRENT] selective QueueDownload/read-trap policy; no duplicate blanket normal-path add'

Require-Text $bufferCachePath 'void BufferCache<P>::NoteCpuRead(DAddr addr, size_t size)' 'CPU-read range learning'
Require-Text $bufferCachePath 'cpu_read_ranges.Add(addr, size);' 'CPU-read range registration'
Require-Text $bufferCachePath 'read_trapped_ranges.Subtract(slot_buffers[buffer_id].CpuAddr()' 'read-trap lifetime cleanup on buffer deletion'
$vkRasterizerPath = 'src/video_core/renderer_vulkan/vk_rasterizer.cpp'
Require-Text $vkRasterizerPath 'buffer_cache.NoteCpuRead' 'Vulkan CPU-read notification'
Require-Text $vkRasterizerPath 'buffer_cache.FlushesOnCpuRead()' 'Vulkan selective CPU-read flush gate'
Require-Text $vkRasterizerPath 'buffer_cache.GetFlushArea(addr, size)' 'Vulkan selective buffer flush-area query'

$dmaPath = 'src/video_core/dma_pusher.cpp'
$dma = Read-Required $dmaPath
Require-ExactlyOne $dma 'bool DmaPusher::FlushGpuWrittenCommands(' 'DmaPusher GPU-written command coherency helper'
$commandFlush = Get-Section $dma 'bool DmaPusher::FlushGpuWrittenCommands(' "`nvoid DmaPusher::ReportUnboundSubchannel()" 'DmaPusher::FlushGpuWrittenCommands'
foreach ($marker in @(
    'VideoCommon::GpuSplit::Get().Drain();',
    'memory_manager.IsMemoryDirty(address, size, VideoCommon::CacheType::BufferCache)',
    'memory_manager.FlushRegion(address, size, VideoCommon::CacheType::BufferCache);'
)) {
    if (-not $commandFlush.Contains($marker)) {
        throw "Legacy audit: GPU-written command coherency marker missing: $marker"
    }
}
$dirtyPos = $commandFlush.IndexOf('memory_manager.IsMemoryDirty(address, size, VideoCommon::CacheType::BufferCache)', [StringComparison]::Ordinal)
$flushRegionPos = $commandFlush.IndexOf('memory_manager.FlushRegion(address, size, VideoCommon::CacheType::BufferCache);', [StringComparison]::Ordinal)
if ($dirtyPos -lt 0 -or $flushRegionPos -lt $dirtyPos) {
    throw 'Legacy audit: command-buffer FlushRegion is no longer guarded by IsMemoryDirty'
}
Require-ExactlyOne $commandFlush 'memory_manager.FlushRegion(address, size, VideoCommon::CacheType::BufferCache);' 'conditional command-buffer FlushRegion call'
Write-Host '[CURRENT] one dirty-guarded GPU-written command readback path'

# PR163 coalesces all BufferCache pieces belonging to one FlushRegion into a single host-GPU wait.
# The detailed donor regression validates every component; keep the critical legacy invariant here.
Require-Text $bufferCachePath 'void BufferCache<P>::BeginDownloadBatch()' 'coalesced buffer download batch begin'
Require-Text $bufferCachePath 'void BufferCache<P>::FinishDownloadBatch()' 'coalesced buffer download batch finish'
$finishBatch = Get-Section $bufferCache 'void BufferCache<P>::FinishDownloadBatch()' "`ntemplate <class P>" 'BufferCache::FinishDownloadBatch'
Require-ExactlyOne $finishBatch 'runtime.Finish();' 'coalesced buffer batch GPU wait'
Require-Text 'src/video_core/memory_manager.cpp' 'const bool is_buffer_only = which == VideoCommon::CacheType::BufferCache;' 'buffer-only FlushRegion batching gate'
Write-Host '[ABSENT] duplicate per-piece GPU wait in the active BufferCache flush batch'

# -----------------------------------------------------------------------------
# Vulkan pipeline lifetime: modules are temporary construction inputs, not session-long baggage.
# -----------------------------------------------------------------------------
Require-Text 'src/video_core/renderer_vulkan/vk_compute_pipeline.cpp' 'spv_module = {};' 'compute SPIR-V module release'
$graphicsPath = 'src/video_core/renderer_vulkan/vk_graphics_pipeline.cpp'
$graphics = Read-Required $graphicsPath
if (-not $graphics.Contains('spv_modules = {};')) {
    throw 'Legacy audit: graphics SPIR-V modules are retained after pipeline creation'
}
$configure = $graphics.IndexOf('configure_func = ConfigureFunc(*spv_modules, stage_infos);', [StringComparison]::Ordinal)
$worker = $graphics.IndexOf('const bool on_parallel_worker', [StringComparison]::Ordinal)
if ($configure -lt 0 -or $worker -lt 0 -or $configure -gt $worker) {
    throw 'Legacy audit: ConfigureFunc moved back behind asynchronous pipeline work'
}
Write-Host '[CURRENT] graphics ConfigureFunc is prepared before async pipeline construction and modules are released'

# Rollback/debug controls are intentional compatibility tools, not dead code.
Require-Text 'src/shader_recompiler/backend/spirv/emit_spirv_undefined.cpp' 'EDEN_NX2_UNDEF_ZERO' 'undefined-register rollback switch'
Require-Text 'src/video_core/gpu_split.h' 'EDEN_NX2_SPLIT' 'GPU split rollback switch'

& git diff --check
if ($LASTEXITCODE -ne 0) { throw 'Legacy audit: integrated source contains whitespace/diff errors' }

Write-Host 'NS2 legacy/dead-code audit passed: one selective readback/coherency path, current runtime paths only, intentional rollback controls preserved, automation graph clean.'
