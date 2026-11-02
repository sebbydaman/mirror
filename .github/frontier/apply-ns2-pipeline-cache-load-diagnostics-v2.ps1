$ErrorActionPreference = 'Stop'

# Observation-only serialized pipeline-cache diagnostics. This version deliberately avoids
# pinning the exact LoadDiskResources state layout: the assembled PokeDinner/NS2 stack can add
# fields there without changing cache semantics. We only measure file/header state, records parsed,
# compatibility rejections, and the number accepted into the boot build queue.

function Write-PatchedText([string]$Path, [string]$Text) {
    $normalized = $Text.TrimEnd("`r", "`n") + "`n"
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText((Resolve-Path $Path).Path, $normalized, $utf8NoBom)
}

$path = 'src/video_core/renderer_vulkan/vk_pipeline_cache.cpp'
if (-not (Test-Path $path -PathType Leaf)) {
    throw "NX2 pipeline-cache diagnostics v2: missing $path"
}

$text = (Get-Content $path -Raw).Replace("`r`n", "`n")
$marker = 'Pipeline cache acceptance diagnostic:'
if ($text.Contains($marker)) {
    Write-Host '[PRESENT] structural NS2 serialized pipeline-cache acceptance diagnostics'
    exit 0
}

# Capture vulkan.bin before VideoCommon::LoadPipelines has a chance to reject/remove an old file.
$filenameAnchor = '    pipeline_cache_filename = base_dir / "vulkan.bin";'
if (-not $text.Contains($filenameAnchor) -or ($text.Split($filenameAnchor).Count - 1) -ne 1) {
    throw 'NX2 pipeline-cache diagnostics v2: vulkan.bin filename assignment changed or is ambiguous'
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

# Insert counters after the state member named built{}, but locate it relative to load_compute rather
# than assuming any exact struct prefix/indentation/extra donor fields.
$loadComputeAt = $text.IndexOf('load_compute', [StringComparison]::Ordinal)
if ($loadComputeAt -lt 0) {
    throw 'NX2 pipeline-cache diagnostics v2: load_compute is unavailable'
}
$builtToken = 'size_t built{};'
$builtAt = $text.LastIndexOf($builtToken, $loadComputeAt, [StringComparison]::Ordinal)
if ($builtAt -lt 0 -or ($loadComputeAt - $builtAt) -gt 2200) {
    throw 'NX2 pipeline-cache diagnostics v2: could not structurally locate LoadDiskResources built counter'
}
$lineStart = $text.LastIndexOf("`n", $builtAt)
$lineStart = if ($lineStart -lt 0) { 0 } else { $lineStart + 1 }
$indent = $text.Substring($lineStart, $builtAt - $lineStart)
if ($indent.Trim().Length -ne 0) {
    throw 'NX2 pipeline-cache diagnostics v2: unexpected text before built counter'
}
$counters = @(
    'size_t parsed_compute{};',
    'size_t parsed_graphics{};',
    'size_t rejected_dynamic_compat{};',
    'size_t rejected_eds1{};',
    'size_t rejected_eds2{};',
    'size_t rejected_eds2_logic_op{};',
    'size_t rejected_eds3_blend{};',
    'size_t rejected_eds3_enables{};',
    'size_t rejected_color_write_enable{};',
    'size_t rejected_dynamic_vertex_input{};',
    'size_t rejected_provoking_last{};',
    'size_t rejected_xfb_provoking_preserve{};'
)
$counterText = ($counters | ForEach-Object { "`n$indent$_" }) -join ''
$insertAt = $builtAt + $builtToken.Length
$text = $text.Insert($insertAt, $counterText)

$computeRead = @'
        ComputePipelineCacheKey key;
        file.read(reinterpret_cast<char*>(&key), sizeof(key));
'@
$computeRead = $computeRead.TrimEnd("`r", "`n")
if (-not $text.Contains($computeRead)) {
    throw 'NX2 pipeline-cache diagnostics v2: compute record-read anchor changed'
}
$text = $text.Replace($computeRead, $computeRead + "`n        ++state.parsed_compute;")

$graphicsRead = @'
        GraphicsPipelineCacheKey key;
        file.read(reinterpret_cast<char*>(&key), sizeof(key));
'@
$graphicsRead = $graphicsRead.TrimEnd("`r", "`n")
if (-not $text.Contains($graphicsRead)) {
    throw 'NX2 pipeline-cache diagnostics v2: graphics record-read anchor changed'
}
$text = $text.Replace($graphicsRead, $graphicsRead + "`n        ++state.parsed_graphics;")

$compatOld = @'
        if ((key.state.extended_dynamic_state != 0) !=
                dynamic_features.has_extended_dynamic_state ||
            (key.state.extended_dynamic_state_2 != 0) !=
                dynamic_features.has_extended_dynamic_state_2 ||
            (key.state.extended_dynamic_state_2_logic_op != 0) !=
                dynamic_features.has_extended_dynamic_state_2_logic_op ||
            (key.state.extended_dynamic_state_3_blend != 0) !=
                dynamic_features.has_extended_dynamic_state_3_blend ||
            (key.state.extended_dynamic_state_3_enables != 0) !=
                dynamic_features.has_extended_dynamic_state_3_enables ||
            (key.state.color_write_enable_dynamic != 0) !=
                dynamic_features.has_color_write_enable ||
            (key.state.dynamic_vertex_input != 0) !=
                dynamic_features.has_dynamic_vertex_input) {
            return;
        }

        const bool key_requests_provoking_last = key.state.provoking_vertex_last != 0;
        if (key_requests_provoking_last && !dynamic_features.has_provoking_vertex_last_mode) {
            return;
        }

        const bool key_uses_transform_feedback = key.state.xfb_enabled != 0;
        if (key_uses_transform_feedback && key_requests_provoking_last &&
            !dynamic_features.has_provoking_vertex_tf_preserve) {
            return;
        }
'@
$compatOld = $compatOld.TrimEnd("`r", "`n")
$compatNew = @'
        const bool reject_eds1 = (key.state.extended_dynamic_state != 0) !=
                                 dynamic_features.has_extended_dynamic_state;
        const bool reject_eds2 = (key.state.extended_dynamic_state_2 != 0) !=
                                 dynamic_features.has_extended_dynamic_state_2;
        const bool reject_eds2_logic = (key.state.extended_dynamic_state_2_logic_op != 0) !=
                                       dynamic_features.has_extended_dynamic_state_2_logic_op;
        const bool reject_eds3_blend = (key.state.extended_dynamic_state_3_blend != 0) !=
                                       dynamic_features.has_extended_dynamic_state_3_blend;
        const bool reject_eds3_enables = (key.state.extended_dynamic_state_3_enables != 0) !=
                                         dynamic_features.has_extended_dynamic_state_3_enables;
        const bool reject_color_write = (key.state.color_write_enable_dynamic != 0) !=
                                        dynamic_features.has_color_write_enable;
        const bool reject_dynamic_vertex = (key.state.dynamic_vertex_input != 0) !=
                                           dynamic_features.has_dynamic_vertex_input;
        if (reject_eds1 || reject_eds2 || reject_eds2_logic || reject_eds3_blend ||
            reject_eds3_enables || reject_color_write || reject_dynamic_vertex) {
            ++state.rejected_dynamic_compat;
            state.rejected_eds1 += reject_eds1;
            state.rejected_eds2 += reject_eds2;
            state.rejected_eds2_logic_op += reject_eds2_logic;
            state.rejected_eds3_blend += reject_eds3_blend;
            state.rejected_eds3_enables += reject_eds3_enables;
            state.rejected_color_write_enable += reject_color_write;
            state.rejected_dynamic_vertex_input += reject_dynamic_vertex;
            return;
        }

        const bool key_requests_provoking_last = key.state.provoking_vertex_last != 0;
        if (key_requests_provoking_last && !dynamic_features.has_provoking_vertex_last_mode) {
            ++state.rejected_provoking_last;
            return;
        }

        const bool key_uses_transform_feedback = key.state.xfb_enabled != 0;
        if (key_uses_transform_feedback && key_requests_provoking_last &&
            !dynamic_features.has_provoking_vertex_tf_preserve) {
            ++state.rejected_xfb_provoking_preserve;
            return;
        }
'@
$compatNew = $compatNew.TrimEnd("`r", "`n")
if (-not $text.Contains($compatOld)) {
    throw 'NX2 pipeline-cache diagnostics v2: graphics compatibility-filter semantics changed'
}
$text = $text.Replace($compatOld, $compatNew)

$summaryOld = @'
    VideoCommon::LoadPipelines(stop_loading, pipeline_cache_filename, CACHE_VERSION, load_compute,
                               load_graphics);

    LOG_INFO(Render_Vulkan, "Total Pipeline Count: {}", state.total);
'@
$summaryOld = $summaryOld.TrimEnd("`r", "`n")
$summaryNew = @'
    VideoCommon::LoadPipelines(stop_loading, pipeline_cache_filename, CACHE_VERSION, load_compute,
                               load_graphics);

    bool pipeline_cache_present_after_load{};
    {
        std::ifstream diagnostic_cache_after(pipeline_cache_filename, std::ios::binary);
        pipeline_cache_present_after_load = diagnostic_cache_after.is_open();
    }
    LOG_INFO(Render_Vulkan,
             "Pipeline cache acceptance diagnostic: present_before={} bytes={} header_read={} "
             "magic_ok={} stored_version={} expected_version={} present_after={} stop={} "
             "parsed_compute={} parsed_graphics={} accepted={} rejected_dynamic={} "
             "eds1={} eds2={} eds2_logic={} eds3_blend={} eds3_enables={} color_write={} "
             "dynamic_vertex={} provoking_last={} xfb_provoking_preserve={}",
             pipeline_cache_file_present, pipeline_cache_file_bytes, pipeline_cache_header_read,
             pipeline_cache_header_magic_ok, pipeline_cache_header_version, CACHE_VERSION,
             pipeline_cache_present_after_load, stop_loading.stop_requested(), state.parsed_compute,
             state.parsed_graphics, state.total, state.rejected_dynamic_compat, state.rejected_eds1,
             state.rejected_eds2, state.rejected_eds2_logic_op, state.rejected_eds3_blend,
             state.rejected_eds3_enables, state.rejected_color_write_enable,
             state.rejected_dynamic_vertex_input, state.rejected_provoking_last,
             state.rejected_xfb_provoking_preserve);

    LOG_INFO(Render_Vulkan, "Total Pipeline Count: {}", state.total);
'@
$summaryNew = $summaryNew.TrimEnd("`r", "`n")
if (-not $text.Contains($summaryOld)) {
    throw 'NX2 pipeline-cache diagnostics v2: LoadPipelines summary anchor changed'
}
$text = $text.Replace($summaryOld, $summaryNew)

Write-PatchedText $path $text

$final = Get-Content $path -Raw
foreach ($needle in @(
    'Pipeline cache acceptance diagnostic:',
    'size_t parsed_compute{};',
    'size_t parsed_graphics{};',
    'size_t rejected_dynamic_vertex_input{};',
    'pipeline_cache_header_magic_ok'
)) {
    if (-not $final.Contains($needle)) {
        throw "NX2 pipeline-cache diagnostics v2 validation failed: missing $needle"
    }
}

git diff --check
if ($LASTEXITCODE -ne 0) {
    throw 'NX2 pipeline-cache diagnostics v2 introduced diff/whitespace errors'
}

Write-Host '[APPLIED] structural NS2 serialized pipeline-cache acceptance diagnostics (observation only)'
