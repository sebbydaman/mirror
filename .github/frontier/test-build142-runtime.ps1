$ErrorActionPreference = 'Stop'

function Require([string]$Path, [string]$Text) {
    if (-not (Get-Content $Path -Raw).Contains($Text)) {
        throw "Build142 regression: missing '$Text' in $Path"
    }
}

$dmaPath = 'src/video_core/dma_pusher.cpp'
$dma = Get-Content $dmaPath -Raw
Require $dmaPath 'const bool gpu_written = has_copy || FlushGpuWrittenCommands('
Require $dmaPath 'command_resume_offset == 0 && !gpu_written &&'
Require $dmaPath 'return memory_manager.MappingGeneration() == generation;'
Require $dmaPath 'if (!enabled || !VideoCommon::GpuSplit::Get().Active())'
Require $dmaPath "return value != nullptr && value[0] == '1';"
Require $dmaPath 'run_split.NoteWriter();'
if ([regex]::Matches($dma, 'split.NoteWriter\(\);').Count -ne 3) {
    throw 'Build142 regression: writer tracking must cover scalar, multi and Increasing-run dispatch'
}

$buffer = 'src/video_core/buffer_cache/buffer_cache.h'
Require $buffer 'size > (u64{1} << 36) - device_addr'
Require $buffer 'page >= page_table.size()'
Require $buffer 'entry.copy_writes == entry.writes'
Require $buffer 'offset >= entry.copy_begin && offset + out.size() <= entry.copy_end'
Require $buffer 'runtime.WaitSubmittedTick(tick);'
Require $buffer 'it->second.copy_writes != writes'
Require $buffer 'Nx2NoteListWrite(buffer_b, *cpu_dest_address, amount);'
Require $buffer 'Nx2NoteListWrite(buffer, *cpu_dst_address, size);'
Require $buffer 'nx2_list_pages.size() >= 1024'
Require $buffer 'current.device_addr == 0 && current.size == 0 && current.buffer_id == NULL_BUFFER_ID'
$text = Get-Content $buffer -Raw
if ($text.Contains('current.device_addr == 0 && current.size == 0 && !current.buffer_id')) {
    throw 'Build142 regression: obsolete uniform-buffer null guard survived build158 normalization'
}
foreach ($signature in @('void BufferCache<P>::UnmapGPUMemory', 'void BufferCache<P>::DeleteBuffer')) {
    $pos = $text.IndexOf($signature)
    if ($pos -lt 0 -or -not $text.Substring($pos, 200).Contains('Nx2InvalidateListCopies();')) {
        throw "Build142 regression: stale copies can survive $signature"
    }
}

Require 'src/video_core/renderer_vulkan/vk_compute_pass.cpp' "return value == nullptr || value[0] != '0';"
$texture = Get-Content 'src/video_core/renderer_vulkan/vk_texture_cache.cpp' -Raw
$transcode = $texture.Substring($texture.IndexOf('void TextureCacheRuntime::TranscodeAstcToBcn('))
if (-not $transcode.Contains('.wait = true,')) { throw 'ASTC transcode no longer uses ordered submit/wait policy' }
Require 'src/video_core/texture_cache/texture_cache.h' 'high_priority_mode && old_age != 0 && frame_tick > old_age'
Require 'src/video_core/gpu_split.cpp' 'wait_target.store(~u64{0}, std::memory_order_relaxed);'
git diff --check
if ($LASTEXITCODE -ne 0) { throw 'Build142 diff check failed' }
Write-Host '[PASS] Build142 source invariants; runtime performance still requires game A/B testing.'
