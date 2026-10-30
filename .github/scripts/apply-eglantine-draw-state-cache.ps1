$ErrorActionPreference = "Stop"

$path = "src/video_core/renderer_vulkan/vk_graphics_pipeline.cpp"
$text = Get-Content $path -Raw

# Push descriptors are command-buffer state. Reuse is safe only while the exact same pipeline is
# still bound in the current scheduler context and the complete descriptor payload is unchanged.
# Scheduler::InvalidateState clears graphics_pipeline on every submission, making bind_pipeline=true
# after a command-buffer reset and forcing a fresh push.
if (-not $text.Contains('const bool update_push_descriptors')) {
    $needle = @'
    bool update_descriptors = true;
    if (descriptor_set_layout && !uses_push_descriptor && !uses_descriptor_buffer) {
        const auto* const entries = static_cast<const DescriptorUpdateEntry*>(descriptor_data);
        update_descriptors =
            bind_pipeline || last_descriptor_payload.size() != num_descriptor_entries ||
            std::memcmp(last_descriptor_payload.data(), entries,
                        num_descriptor_entries * sizeof(DescriptorUpdateEntry)) != 0;
        if (update_descriptors) {
            last_descriptor_payload.assign(entries, entries + num_descriptor_entries);
        }
    }
'@
    if (-not $text.Contains($needle.TrimStart("`r", "`n"))) {
        throw "Could not locate Vulkan descriptor payload cache block"
    }
    $replacement = @'
    bool update_descriptors = true;
    if (descriptor_set_layout && !uses_push_descriptor && !uses_descriptor_buffer) {
        const auto* const entries = static_cast<const DescriptorUpdateEntry*>(descriptor_data);
        update_descriptors =
            bind_pipeline || last_descriptor_payload.size() != num_descriptor_entries ||
            std::memcmp(last_descriptor_payload.data(), entries,
                        num_descriptor_entries * sizeof(DescriptorUpdateEntry)) != 0;
        if (update_descriptors) {
            last_descriptor_payload.assign(entries, entries + num_descriptor_entries);
        }
    }
    bool update_push_descriptors = true;
    if (descriptor_set_layout && uses_push_descriptor) {
        const auto* const entries = static_cast<const DescriptorUpdateEntry*>(descriptor_data);
        update_push_descriptors =
            bind_pipeline || last_descriptor_payload.size() != num_descriptor_entries ||
            std::memcmp(last_descriptor_payload.data(), entries,
                        num_descriptor_entries * sizeof(DescriptorUpdateEntry)) != 0;
        if (update_push_descriptors) {
            last_descriptor_payload.assign(entries, entries + num_descriptor_entries);
        }
    }
'@
    $text = $text.Replace($needle.TrimStart("`r", "`n"), $replacement.TrimStart("`r", "`n"))

    $captureNeedle = 'scheduler.Record([this, descriptor_data, bind_pipeline, update_descriptors,'
    if (-not $text.Contains($captureNeedle)) { throw "Could not locate Vulkan draw record capture" }
    $text = $text.Replace(
        $captureNeedle,
        'scheduler.Record([this, descriptor_data, bind_pipeline, update_descriptors, update_push_descriptors,')

    $pushNeedle = @'
        } else if (uses_push_descriptor) {
            cmdbuf.PushDescriptorSetWithTemplateKHR(*descriptor_update_template, *pipeline_layout,
                                                    0, descriptor_data);
        } else if (update_descriptors) {
'@
    if (-not $text.Contains($pushNeedle.TrimStart("`r", "`n"))) {
        throw "Could not locate Vulkan push descriptor submission"
    }
    $pushReplacement = @'
        } else if (uses_push_descriptor) {
            if (update_push_descriptors) {
                cmdbuf.PushDescriptorSetWithTemplateKHR(*descriptor_update_template, *pipeline_layout,
                                                        0, descriptor_data);
            }
        } else if (update_descriptors) {
'@
    $text = $text.Replace($pushNeedle.TrimStart("`r", "`n"), $pushReplacement.TrimStart("`r", "`n"))

    Set-Content -Path $path -Value $text -Encoding utf8 -NoNewline
    Write-Host "Enabled exact-payload Vulkan push-descriptor reuse."
}

git diff -- $path
