$ErrorActionPreference = 'Stop'

# Diagnostic-only instrumentation for the serialized Eden pipeline cache (vulkan.bin).
# A non-empty file can still report "Total Pipeline Count: 0" because graphics records are
# deserialized first and then compatibility-filtered before state.total is incremented. Keep the
# loader semantics unchanged; expose header/version, parsed records, each compatibility rejection,
# and reconstruction success/failure so the cold-route bottleneck can be fixed from evidence.

function Write-PatchedText([string]$Path, [string]$Text) {
    $normalized = $Text.TrimEnd("`r", "`n") + "`n"
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText((Resolve-Path $Path).Path, $normalized, $utf8NoBom)
}

$path = 'src/video_core/renderer_vulkan/vk_pipeline_cache.cpp'
if (-not (Test-Path $path -PathType Leaf)) {
    throw "NX2 pipeline-cache diagnostics: missing $path"
}

$text = (Get-Content $path -Raw).Replace("`r`n", "`n")
$marker = 'Pipeline cache load diagnostic:'
if ($text.Contains($marker)) {
    foreach ($needle in @(
        'size_t parsed_compute{};',
        'size_t rejected_dynamic_compat{};',
        'size_t rejected_dynamic_vertex_input{};',
        'size_t restored_graphics{};',
        'pipeline_cache_header_magic_ok',
        'Pipeline cache reconstruction diagnostic:'
    )) {
        if (-not $text.Contains($needle)) {
            throw "NX2 pipeline-cache diagnostics: partial existing implementation; missing $needle"
        }
    }
    Write-Host '[PRESENT] NS2 serialized pipeline-cache restore diagnostics'
    exit 0
}

# Record the file/header state immediately after the serialized cache filename is selected. Keep
# this anchor deliberately narrow: the assembled PokeDinner/build31 stack can place extra Vulkan
# driver-cache setup between this assignment and the LoadDiskResources state block.
$filenameAnchor = '    pipeline_cache_filename = base_dir / "vulkan.bin";'
$filenameReplacement = @'
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
$filenameReplacement = $filenameReplacement.TrimEnd("`r", "`n")
if (-not $text.Contains($filenameAnchor)) {
    throw 'NX2 pipeline-cache diagnostics: pipeline-cache filename anchor changed'
}
if (($text.Split($filenameAnchor).Count - 1) -ne 1) {
    throw 'NX2 pipeline-cache diagnostics: pipeline-cache filename anchor is not unique'
}
$text = $text.Replace($filenameAnchor, $filenameReplacement)

# Only pin the stable state prefix. The assembled donor stack legitimately inserts its own
# statistics fields after built{}, so replacing the whole struct layout was unnecessarily brittle.
$stateAnchor = @'
        std::mutex mutex;
        size_t total{};
        size_t built{};
'@
$stateAnchor = $stateAnchor.TrimEnd("`r", "`n")
$stateReplacement = @'
        std::mutex mutex;
        size_t total{};
        size_t built{};
        size_t parsed_compute{};
        size_t parsed_graphics{};
        size_t rejected_dynamic_compat{};
        size_t rejected_eds1{};
        size_t rejected_eds2{};
        size_t rejected_eds2_logic_op{};
        size_t rejected_eds3_blend{};
        size_t rejected_eds3_enables{};
        size_t rejected_color_write_enable{};
        size_t rejected_dynamic_vertex_input{};
        size_t rejected_provoking_last{};
        size_t rejected_xfb_provoking_preserve{};
        size_t restored_compute{};
        size_t restored_graphics{};
        size_t failed_compute{};
        size_t failed_graphics{};
'@
$stateReplacement = $stateReplacement.TrimEnd("`r", "`n")
if (-not $text.Contains($stateAnchor)) {
    throw 'NX2 pipeline-cache diagnostics: LoadDiskResources state-prefix anchor changed'
}
if (($text.Split($stateAnchor).Count - 1) -ne 1) {
    throw 'NX2 pipeline-cache diagnostics: LoadDiskResources state-prefix anchor is not unique'
}
$text = $text.Replace($stateAnchor, $stateReplacement)

$computeReadAnchor = @'
        ComputePipelineCacheKey key;
        file.read(reinterpret_cast<char*>(&key), sizeof(key));

        workers.QueueWork([this, key, env_ = std::move(env), &state, &callback]() mutable {
'@
$computeReadAnchor = $computeReadAnchor.TrimEnd("`r", "`n")
$computeReadReplacement = @'
        ComputePipelineCacheKey key;
        file.read(reinterpret_cast<char*>(&key), sizeof(key));
        ++state.parsed_compute;

        workers.QueueWork([this, key, env_ = std::move(env), &state, &callback]() mutable {
'@
$computeReadReplacement = $computeReadReplacement.TrimEnd("`r", "`n")
if (-not $text.Contains($computeReadAnchor)) {
    throw 'NX2 pipeline-cache diagnostics: compute cache-read anchor changed'
}
$text = $text.Replace($computeReadAnchor, $computeReadReplacement)

$graphicsReadAnchor = @'
        GraphicsPipelineCacheKey key;
        file.read(reinterpret_cast<char*>(&key), sizeof(key));

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
$graphicsReadAnchor = $graphicsReadAnchor.TrimEnd("`r", "`n")
$graphicsReadReplacement = @'
        GraphicsPipelineCacheKey key;
        file.read(reinterpret_cast<char*>(&key), sizeof(key));
        ++state.parsed_graphics;

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
$graphicsReadReplacement = $graphicsReadReplacement.TrimEnd("`r", "`n")
if (-not $text.Contains($graphicsReadAnchor)) {
    throw 'NX2 pipeline-cache diagnostics: graphics compatibility-filter anchor changed'
}
$text = $text.Replace($graphicsReadAnchor, $graphicsReadReplacement)

$computeBuildAnchor = @'
            if (pipeline) {
                compute_cache.emplace(key, std::move(pipeline));
            }
            ++state.built;
'@
$computeBuildAnchor = $computeBuildAnchor.TrimEnd("`r", "`n")
$computeBuildReplacement = @'
            if (pipeline) {
                compute_cache.emplace(key, std::move(pipeline));
                ++state.restored_compute;
            } else {
                ++state.failed_compute;
            }
            ++state.built;
'@
$computeBuildReplacement = $computeBuildReplacement.TrimEnd("`r", "`n")
if (-not $text.Contains($computeBuildAnchor)) {
    throw 'NX2 pipeline-cache diagnostics: compute reconstruction anchor changed'
}
$text = $text.Replace($computeBuildAnchor, $computeBuildReplacement)

$graphicsBuildAnchor = @'
            if (pipeline) {
                graphics_cache.emplace(key, std::move(pipeline));
            }
            ++state.built;
'@
$graphicsBuildAnchor = $graphicsBuildAnchor.TrimEnd("`r", "`n")
$graphicsBuildReplacement = @'
            if (pipeline) {
                graphics_cache.emplace(key, std::move(pipeline));
                ++state.restored_graphics;
            } else {
                ++state.failed_graphics;
            }
            ++state.built;
'@
$graphicsBuildReplacement = $graphicsBuildReplacement.TrimEnd("`r", "`n")
if (-not $text.Contains($graphicsBuildAnchor)) {
    throw 'NX2 pipeline-cache diagnostics: graphics reconstruction anchor changed'
}
$text = $text.Replace($graphicsBuildAnchor, $graphicsBuildReplacement)

$loadLogAnchor = @'
    VideoCommon::LoadPipelines(stop_loading, pipeline_cache_filename, CACHE_VERSION, load_compute,
                               load_graphics);

    LOG_INFO(Render_Vulkan, "Total Pipeline Count: {}", state.total);
'@
$loadLogAnchor = $loadLogAnchor.TrimEnd("`r", "`n")
$loadLogReplacement = @'
    VideoCommon::LoadPipelines(stop_loading, pipeline_cache_filename, CACHE_VERSION, load_compute,
                               load_graphics);

    bool pipeline_cache_present_after_load{};
    {
        std::ifstream diagnostic_cache_after(pipeline_cache_filename, std::ios::binary);
        pipeline_cache_present_after_load = diagnostic_cache_after.is_open();
    }
    LOG_INFO(Render_Vulkan,
             "Pipeline cache load diagnostic: path={} present_before={} bytes={} header_read={} "
             "magic_ok={} stored_version={} expected_version={} present_after={} stop={} "
             "parsed_compute={} parsed_graphics={} accepted={} rejected_dynamic={} "
             "eds1={} eds2={} eds2_logic={} eds3_blend={} eds3_enables={} color_write={} "
             "dynamic_vertex={} provoking_last={} xfb_provoking_preserve={}",
             Common::FS::PathToUTF8String(pipeline_cache_filename), pipeline_cache_file_present,
             pipeline_cache_file_bytes, pipeline_cache_header_read, pipeline_cache_header_magic_ok,
             pipeline_cache_header_version, CACHE_VERSION, pipeline_cache_present_after_load,
             stop_loading.stop_requested(), state.parsed_compute, state.parsed_graphics, state.total,
             state.rejected_dynamic_compat, state.rejected_eds1, state.rejected_eds2,
             state.rejected_eds2_logic_op, state.rejected_eds3_blend, state.rejected_eds3_enables,
             state.rejected_color_write_enable, state.rejected_dynamic_vertex_input,
             state.rejected_provoking_last, state.rejected_xfb_provoking_preserve);

    LOG_INFO(Render_Vulkan, "Total Pipeline Count: {}", state.total);
'@
$loadLogReplacement = $loadLogReplacement.TrimEnd("`r", "`n")
if (-not $text.Contains($loadLogAnchor)) {
    throw 'NX2 pipeline-cache diagnostics: LoadPipelines summary anchor changed'
}
$text = $text.Replace($loadLogAnchor, $loadLogReplacement)

$waitAnchor = @'
    workers.WaitForRequests(stop_loading);

    if (use_vulkan_pipeline_cache) {
'@
$waitAnchor = $waitAnchor.TrimEnd("`r", "`n")
$waitReplacement = @'
    workers.WaitForRequests(stop_loading);

    {
        std::scoped_lock diagnostic_lock{state.mutex};
        LOG_INFO(Render_Vulkan,
                 "Pipeline cache reconstruction diagnostic: compute restored={} failed={}; "
                 "graphics restored={} failed={}; completed={} accepted={}",
                 state.restored_compute, state.failed_compute, state.restored_graphics,
                 state.failed_graphics, state.built, state.total);
    }

    if (use_vulkan_pipeline_cache) {
'@
$waitReplacement = $waitReplacement.TrimEnd("`r", "`n")
if (-not $text.Contains($waitAnchor)) {
    throw 'NX2 pipeline-cache diagnostics: worker wait anchor changed'
}
$text = $text.Replace($waitAnchor, $waitReplacement)

Write-PatchedText $path $text

$final = Get-Content $path -Raw
foreach ($needle in @(
    'size_t parsed_compute{};',
    'size_t parsed_graphics{};',
    'size_t rejected_dynamic_compat{};',
    'size_t rejected_dynamic_vertex_input{};',
    'size_t rejected_provoking_last{};',
    'size_t rejected_xfb_provoking_preserve{};',
    'size_t restored_compute{};',
    'size_t restored_graphics{};',
    'pipeline_cache_header_magic_ok',
    'Pipeline cache load diagnostic:',
    'Pipeline cache reconstruction diagnostic:'
)) {
    if (-not $final.Contains($needle)) {
        throw "NX2 pipeline-cache diagnostics validation failed: missing $needle"
    }
}

git diff --check
if ($LASTEXITCODE -ne 0) {
    throw 'NX2 pipeline-cache diagnostics introduced diff/whitespace errors'
}

Write-Host '[APPLIED] NS2 serialized pipeline-cache restore diagnostics (observation only)'
