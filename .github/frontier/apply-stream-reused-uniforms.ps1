$ErrorActionPreference = 'Stop'

# Citron a8ef09e: a cached uniform buffer that the GPU has already consumed can become CPU-modified
# again. When the region is CPU-dirty, not GPU-dirty, and already used by the current Vulkan buffer,
# stream the current guest bytes directly into the mapped uniform stream instead of synchronizing and
# uploading the cached GPU buffer again. This is distinct from the existing small-UBO byte/tick reuse:
# that path handles small buffers before the classic cache path; this one handles reused cached regions.
# OpenGL remains unchanged.

function Write-PatchedText([string]$Path, [string]$Text) {
    $normalized = $Text.Replace("`r`n", "`n").TrimEnd("`r", "`n") + "`n"
    [IO.File]::WriteAllText((Resolve-Path $Path).Path, $normalized, [Text.UTF8Encoding]::new($false))
}

function Replace-Once([string]$Text, [string]$Old, [string]$New, [string]$Name) {
    $Text = $Text.Replace("`r`n", "`n")
    $Old = $Old.Replace("`r`n", "`n")
    $New = $New.Replace("`r`n", "`n")
    $first = $Text.IndexOf($Old, [StringComparison]::Ordinal)
    if ($first -lt 0) { throw "Stream reused uniforms: missing anchor $Name" }
    if ($Text.IndexOf($Old, $first + $Old.Length, [StringComparison]::Ordinal) -ge 0) {
        throw "Stream reused uniforms: ambiguous anchor $Name"
    }
    return $Text.Substring(0, $first) + $New + $Text.Substring($first + $Old.Length)
}

$basePath = 'src/video_core/buffer_cache/buffer_cache_base.h'
$cachePath = 'src/video_core/buffer_cache/buffer_cache.h'
foreach ($path in @($basePath, $cachePath)) {
    if (-not (Test-Path $path -PathType Leaf)) { throw "Stream reused uniforms: missing $path" }
}

$base = (Get-Content $basePath -Raw).Replace("`r`n", "`n")
if (-not $base.Contains('bool StreamReusedUniform(Buffer& buffer, DAddr device_addr, u32 size);')) {
    $oldDecl = @'
    void BindHostTransformFeedbackBuffers();

    void BindHostVertexBuffer(u32 index, Buffer& buffer, u32 offset, u32 size, u32 stride);

    void BindHostComputeUniformBuffers();
'@
    $newDecl = @'
    void BindHostTransformFeedbackBuffers();

    void BindHostVertexBuffer(u32 index, Buffer& buffer, u32 offset, u32 size, u32 stride);

    bool StreamReusedUniform(Buffer& buffer, DAddr device_addr, u32 size);

    void BindHostComputeUniformBuffers();
'@
    $base = Replace-Once $base $oldDecl.TrimEnd("`r", "`n") $newDecl.TrimEnd("`r", "`n") `
        'StreamReusedUniform declaration'
    Write-PatchedText $basePath $base
}

$cache = (Get-Content $cachePath -Raw).Replace("`r`n", "`n")
if (-not $cache.Contains('bool BufferCache<P>::StreamReusedUniform(')) {
    $anchor = @'
template <class P>
void BufferCache<P>::BindHostComputeUniformBuffers() {
'@
    $anchor = $anchor.Replace("`r`n", "`n").TrimEnd("`r", "`n")
    $idx = $cache.IndexOf($anchor, [StringComparison]::Ordinal)
    if ($idx -lt 0) { throw 'Stream reused uniforms: compute-uniform insertion anchor missing' }
    $helper = @'
template <class P>
bool BufferCache<P>::StreamReusedUniform(Buffer& buffer, DAddr device_addr, u32 size) {
    if constexpr (requires { buffer.IsRegionUsed(u64{}, u64{}); }) {
        if (memory_tracker.IsRegionGpuModified(device_addr, size) ||
            !memory_tracker.IsRegionCpuModified(device_addr, size)) {
            return false;
        }
        const u64 offset = buffer.Offset(device_addr);
        const u64 begin = Common::AlignDown(offset, Core::DEVICE_PAGESIZE);
        const u64 end = (std::min)(Common::AlignUp(offset + size, Core::DEVICE_PAGESIZE),
                                   buffer.SizeBytes());
        return buffer.IsRegionUsed(begin, end - begin);
    }
    return false;
}

'@
    $cache = $cache.Insert($idx, $helper.Replace("`r`n", "`n"))
}

if (-not $cache.Contains('StreamReusedUniform(buffer, device_addr, size)')) {
    $oldGraphics = @'
    // Classic cached path
    if (SynchronizeBuffer(buffer, device_addr, size)) {
        ++channel_state->uniform_cache_hits[0];
    }
'@
    $newGraphics = @'
    // Classic cached path. If Vulkan has already consumed this cached region and the guest CPU
    // rewrote it since, stream the new bytes directly instead of synchronizing/uploading the old
    // cached GPU buffer again. The small-UBO fast path above remains independent.
    if constexpr (!IS_OPENGL) {
        if (binding.buffer_id != NULL_BUFFER_ID && StreamReusedUniform(buffer, device_addr, size)) {
            channel_state->fast_bound_uniform_buffers[stage] |= 1u << binding_index;
            channel_state->uniform_buffer_binding_sizes[stage][binding_index] = size;
            const std::span<u8> span = runtime.BindMappedUniformBuffer(stage, binding_index, size);
            device_memory.ReadBlockUnsafe(device_addr, span.data(), size,
                                          "BufferCache.BindMappedUniformBuffer", false);
            return;
        }
    }
    if (SynchronizeBuffer(buffer, device_addr, size)) {
        ++channel_state->uniform_cache_hits[0];
    }
'@
    $cache = Replace-Once $cache $oldGraphics.TrimEnd("`r", "`n") $newGraphics.TrimEnd("`r", "`n") `
        'graphics classic uniform cache path'
}

if (-not $cache.Contains('StreamReusedUniform(buffer, binding.device_addr, size)')) {
    $oldCompute = @'
        SynchronizeBuffer(buffer, binding.device_addr, size);

        buffer.MarkUsage(offset, size);
'@
    $newCompute = @'
        if constexpr (!IS_OPENGL) {
            if (binding.buffer_id != NULL_BUFFER_ID &&
                StreamReusedUniform(buffer, binding.device_addr, size)) {
                const std::span<u8> span =
                    runtime.BindMappedUniformBuffer(0, binding_index, size);
                device_memory.ReadBlockUnsafe(binding.device_addr, span.data(), size,
                                              "BufferCache.BindMappedUniformBuffer", false);
                ++binding_index;
                return;
            }
        }

        SynchronizeBuffer(buffer, binding.device_addr, size);

        buffer.MarkUsage(offset, size);
'@
    $cache = Replace-Once $cache $oldCompute.TrimEnd("`r", "`n") $newCompute.TrimEnd("`r", "`n") `
        'compute classic uniform cache path'
}

Write-PatchedText $cachePath $cache

$baseFinal = Get-Content $basePath -Raw
$cacheFinal = Get-Content $cachePath -Raw
foreach ($needle in @(
    'bool StreamReusedUniform(Buffer& buffer, DAddr device_addr, u32 size);'
)) {
    if (-not $baseFinal.Contains($needle)) { throw "Stream reused uniforms validation failed: $needle" }
}
foreach ($needle in @(
    'bool BufferCache<P>::StreamReusedUniform(Buffer& buffer, DAddr device_addr, u32 size)',
    'memory_tracker.IsRegionGpuModified(device_addr, size)',
    '!memory_tracker.IsRegionCpuModified(device_addr, size)',
    'buffer.IsRegionUsed(begin, end - begin)',
    'StreamReusedUniform(buffer, device_addr, size)',
    'StreamReusedUniform(buffer, binding.device_addr, size)',
    'runtime.BindMappedUniformBuffer(stage, binding_index, size)',
    'runtime.BindMappedUniformBuffer(0, binding_index, size)',
    'VideoCommon::BindSmallUniformReusing('
)) {
    if (-not $cacheFinal.Contains($needle)) { throw "Stream reused uniforms validation failed: $needle" }
}

& git diff --check
if ($LASTEXITCODE -ne 0) { throw 'Stream reused uniforms introduced diff/whitespace errors' }
Write-Host 'Stream reused uniforms validated: Vulkan reused CPU-dirty regions stream directly; existing small-UBO reuse and OpenGL paths preserved.'
