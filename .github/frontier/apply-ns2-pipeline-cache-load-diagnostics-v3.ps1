$ErrorActionPreference = 'Stop'

# Observation-only serialized pipeline-cache diagnostics. Keep this intentionally narrow and
# source-shape tolerant: measure vulkan.bin validity, how many compute/graphics records are parsed,
# and how many records survive the existing compatibility filters into state.total. Do not alter
# loader acceptance, async translation, draw-skip policy, or pipeline build behavior.

function Write-PatchedText([string]$Path, [string]$Text) {
    $normalized = $Text.TrimEnd("`r", "`n") + "`n"
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText((Resolve-Path $Path).Path, $normalized, $utf8NoBom)
}

function Insert-AfterRecordRead(
    [string]$Text,
    [string]$TypeToken,
    [string]$CounterMember,
    [int]$SearchStart,
    [int]$SearchEnd
) {
    $typeAt = $Text.IndexOf($TypeToken, $SearchStart, [StringComparison]::Ordinal)
    if ($typeAt -lt 0 -or $typeAt -ge $SearchEnd) {
        throw "NX2 pipeline-cache diagnostics v3: could not locate $TypeToken in LoadDiskResources"
    }

    $readAt = $Text.IndexOf('file.read(', $typeAt, [StringComparison]::Ordinal)
    if ($readAt -lt 0 -or $readAt -ge $SearchEnd -or ($readAt - $typeAt) -gt 900) {
        throw "NX2 pipeline-cache diagnostics v3: could not locate file.read after $TypeToken"
    }

    $semicolonAt = $Text.IndexOf(';', $readAt)
    if ($semicolonAt -lt 0 -or $semicolonAt -ge $SearchEnd -or ($semicolonAt - $readAt) -gt 700) {
        throw "NX2 pipeline-cache diagnostics v3: could not bound file.read statement for $TypeToken"
    }

    $lineStart = $Text.LastIndexOf("`n", $readAt)
    $lineStart = if ($lineStart -lt 0) { 0 } else { $lineStart + 1 }
    $prefix = $Text.Substring($lineStart, $readAt - $lineStart)
    $indentMatch = [regex]::Match($prefix, '^\s*')
    $indent = $indentMatch.Value
    $probe = "`n${indent}++state.${CounterMember};"

    return $Text.Insert($semicolonAt + 1, $probe)
}

$path = 'src/video_core/renderer_vulkan/vk_pipeline_cache.cpp'
if (-not (Test-Path $path -PathType Leaf)) {
    throw "NX2 pipeline-cache diagnostics v3: missing $path"
}

$text = (Get-Content $path -Raw).Replace("`r`n", "`n")
$marker = 'Pipeline cache parse diagnostic:'
if ($text.Contains($marker)) {
    Write-Host '[PRESENT] structural NS2 serialized pipeline-cache parse diagnostics'
    exit 0
}

# Capture the file/header before VideoCommon::LoadPipelines can reject and remove an incompatible
# cache. The assignment is stable across the current donor composition and unique in this TU.
$filenameAnchor = '    pipeline_cache_filename = base_dir / "vulkan.bin";'
if (-not $text.Contains($filenameAnchor) -or ($text.Split($filenameAnchor).Count - 1) -ne 1) {
    throw 'NX2 pipeline-cache diagnostics v3: vulkan.bin filename assignment changed or is ambiguous'
}
$filenameProbe = @'
    pipeline_cache_filename = base_dir / "vulkan.bin";

    bool pipeline_cache_file_present{};
    size_t pipeline_cache_file_bytes{};
    bool pipeline_cache_header_read{};
    bool pipeline_cache_header_magic_ok{};
    u32 pipeline_cache_header_version{};
    {
        std::ifstream diagnostic_cache(pipeline_cache_filename, std::ios::binary | std::ios::ate);
        if (diagnostic_cache.is_open()) {
            pipeline_cache_file_present = true;
            const std::streamoff end = diagnostic_cache.tellg();
            if (end >= 0) {
                pipeline_cache_file_bytes = static_cast<size_t>(end);
            }
            constexpr size_t SerializedHeaderBytes = 8 + sizeof(u32);
            if (pipeline_cache_file_bytes >= SerializedHeaderBytes) {
                diagnostic_cache.seekg(0, std::ios::beg);
                std::array<char, 8> magic{};
                diagnostic_cache.read(magic.data(), magic.size())
                    .read(reinterpret_cast<char*>(&pipeline_cache_header_version),
                          sizeof(pipeline_cache_header_version));
                pipeline_cache_header_read = static_cast<bool>(diagnostic_cache);
                pipeline_cache_header_magic_ok =
                    pipeline_cache_header_read &&
                    magic == std::array<char, 8>{'y', 'u', 'z', 'u', 'c', 'a', 'c', 'h'};
            }
        }
    }
'@
$text = $text.Replace($filenameAnchor, $filenameProbe.TrimEnd("`r", "`n"))

# Locate the LoadDiskResources state structurally. The prior probe proved this built{} member is
# present even when donor overlays add other fields around it.
$loadComputeAt = $text.IndexOf('load_compute', [StringComparison]::Ordinal)
if ($loadComputeAt -lt 0) {
    throw 'NX2 pipeline-cache diagnostics v3: load_compute is unavailable'
}
$builtToken = 'size_t built{};'
$builtAt = $text.LastIndexOf($builtToken, $loadComputeAt, [StringComparison]::Ordinal)
if ($builtAt -lt 0 -or ($loadComputeAt - $builtAt) -gt 2400) {
    throw 'NX2 pipeline-cache diagnostics v3: could not structurally locate LoadDiskResources built counter'
}
$lineStart = $text.LastIndexOf("`n", $builtAt)
$lineStart = if ($lineStart -lt 0) { 0 } else { $lineStart + 1 }
$indent = $text.Substring($lineStart, $builtAt - $lineStart)
if ($indent.Trim().Length -ne 0) {
    throw 'NX2 pipeline-cache diagnostics v3: unexpected text before built counter'
}
$text = $text.Insert($builtAt + $builtToken.Length,
                     "`n${indent}size_t parsed_compute{};`n${indent}size_t parsed_graphics{};")

# Bound both record probes to the loader callback region. Find the key type, then the next actual
# file.read statement, rather than depending on declaration formatting such as key vs key{}.
$loadPipelinesAt = $text.IndexOf('VideoCommon::LoadPipelines(', $loadComputeAt,
                                 [StringComparison]::Ordinal)
if ($loadPipelinesAt -lt 0) {
    throw 'NX2 pipeline-cache diagnostics v3: VideoCommon::LoadPipelines call is unavailable'
}
$text = Insert-AfterRecordRead $text 'ComputePipelineCacheKey' 'parsed_compute' $loadComputeAt $loadPipelinesAt

# Recompute bounds because the compute probe changed offsets.
$loadComputeAt = $text.IndexOf('load_compute', [StringComparison]::Ordinal)
$loadPipelinesAt = $text.IndexOf('VideoCommon::LoadPipelines(', $loadComputeAt,
                                 [StringComparison]::Ordinal)
$text = Insert-AfterRecordRead $text 'GraphicsPipelineCacheKey' 'parsed_graphics' $loadComputeAt $loadPipelinesAt

# Insert the summary immediately after the real LoadPipelines statement. Do not depend on how the
# donor stack formats the call or on which logging/statistics lines follow it.
$loadComputeAt = $text.IndexOf('load_compute', [StringComparison]::Ordinal)
$loadPipelinesAt = $text.IndexOf('VideoCommon::LoadPipelines(', $loadComputeAt,
                                 [StringComparison]::Ordinal)
if ($loadPipelinesAt -lt 0) {
    throw 'NX2 pipeline-cache diagnostics v3: final LoadPipelines call is unavailable'
}
$loadPipelinesSemi = $text.IndexOf(';', $loadPipelinesAt)
if ($loadPipelinesSemi -lt 0 -or ($loadPipelinesSemi - $loadPipelinesAt) -gt 900) {
    throw 'NX2 pipeline-cache diagnostics v3: could not bound final LoadPipelines statement'
}
$summaryProbe = @'

    bool pipeline_cache_present_after_load{};
    {
        std::ifstream diagnostic_cache_after(pipeline_cache_filename, std::ios::binary);
        pipeline_cache_present_after_load = diagnostic_cache_after.is_open();
    }
    LOG_INFO(Render_Vulkan,
             "Pipeline cache parse diagnostic: present_before={} bytes={} header_read={} magic_ok={} "
             "stored_version={} expected_version={} present_after={} stop={} parsed_compute={} "
             "parsed_graphics={} accepted={}",
             pipeline_cache_file_present, pipeline_cache_file_bytes, pipeline_cache_header_read,
             pipeline_cache_header_magic_ok, pipeline_cache_header_version, CACHE_VERSION,
             pipeline_cache_present_after_load, stop_loading.stop_requested(), state.parsed_compute,
             state.parsed_graphics, state.total);
'@
$text = $text.Insert($loadPipelinesSemi + 1, $summaryProbe.TrimEnd("`r", "`n"))

Write-PatchedText $path $text

$final = Get-Content $path -Raw
foreach ($needle in @(
    'Pipeline cache parse diagnostic:',
    'size_t parsed_compute{};',
    'size_t parsed_graphics{};',
    '++state.parsed_compute;',
    '++state.parsed_graphics;',
    'pipeline_cache_header_magic_ok'
)) {
    if (-not $final.Contains($needle)) {
        throw "NX2 pipeline-cache diagnostics v3 validation failed: missing $needle"
    }
}

git diff --check
if ($LASTEXITCODE -ne 0) {
    throw 'NX2 pipeline-cache diagnostics v3 introduced diff/whitespace errors'
}

Write-Host '[APPLIED] structural NS2 serialized pipeline-cache parse diagnostics (observation only)'
