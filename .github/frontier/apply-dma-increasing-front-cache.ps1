$ErrorActionPreference = 'Stop'

# Second-stage Switch 2 DmaDispatch optimization. Cache split routing once per pure Increasing run.
# Production composition intentionally excludes telemetry/diagnostic adapters, so this patch must
# not depend on Profile or g_semaphore_watch symbols supplied only by those adapters.

function Write-PatchedText([string]$Path, [string]$Text) {
    $normalized = $Text.Replace("`r`n", "`n").TrimEnd("`r", "`n") + "`n"
    [IO.File]::WriteAllText((Resolve-Path $Path).Path, $normalized, [Text.UTF8Encoding]::new($false))
}

function Replace-Once([string]$Text, [string]$Old, [string]$New, [string]$Name) {
    $Text = $Text.Replace("`r`n", "`n")
    $Old = $Old.Replace("`r`n", "`n")
    $New = $New.Replace("`r`n", "`n")
    $first = $Text.IndexOf($Old, [StringComparison]::Ordinal)
    if ($first -lt 0) { throw "DMA increasing run-cache: missing anchor $Name" }
    if ($Text.IndexOf($Old, $first + $Old.Length, [StringComparison]::Ordinal) -ge 0) {
        throw "DMA increasing run-cache: ambiguous anchor $Name"
    }
    return $Text.Substring(0, $first) + $New + $Text.Substring($first + $Old.Length)
}

$path = 'src/video_core/dma_pusher.cpp'
if (-not (Test-Path $path -PathType Leaf)) { throw "DMA increasing run-cache: missing $path" }

$text = (Get-Content $path -Raw).Replace("`r`n", "`n")
$marker = 'run_split_engine'
if (-not $text.Contains($marker)) {
    $old = @'
                const size_t end_index = index + available_words;
                do {
                    dma_state.dma_word_offset = u64((word_offset + index) * sizeof(u32));
                    dma_state.is_last_call = dma_state.method_count <= 1;
                    CallMethod(commands[index].argument);
                    ++dma_state.method;
                    --dma_state.method_count;
                    ++index;
                } while (index < end_index);
'@
    $new = @'
                const size_t end_index = index + available_words;
                auto& run_split = VideoCommon::GpuSplit::Get();
                const bool run_split_active = run_split.Active();

                Engines::EngineInterface* run_split_engine = nullptr;
                Engines::Maxwell3D* front_run_maxwell = nullptr;
                Engines::KeplerCompute* front_run_compute = nullptr;
                bool run_compute_segment = false;
                bool run_maxwell_segment = false;
                if (run_split_active) {
                    if (auto* const run_engine = subchannels[dma_state.subchannel];
                        run_engine != nullptr) {
                        const auto run_type = subchannel_type[dma_state.subchannel];
                        if (run_split.FrontMacros() && run_type == Engines::EngineTypes::Maxwell3D) {
                            auto* const maxwell3d = static_cast<Engines::Maxwell3D*>(run_engine);
                            if (maxwell3d->GetNativeMacroEngine().native_turing) {
                                front_run_maxwell = maxwell3d;
                            }
                        } else if (run_split.FrontMacros() &&
                                   run_type == Engines::EngineTypes::KeplerCompute) {
                            auto* const compute = static_cast<Engines::KeplerCompute*>(run_engine);
                            if (compute->FrontRunsMacros()) {
                                front_run_compute = compute;
                            }
                        }
                        if (front_run_maxwell == nullptr && front_run_compute == nullptr) {
                            run_split_engine = run_engine;
                            run_compute_segment = run_type == Engines::EngineTypes::KeplerCompute;
                            run_maxwell_segment = run_type == Engines::EngineTypes::Maxwell3D;
                        }
                    }
                }

                do {
                    dma_state.dma_word_offset = u64((word_offset + index) * sizeof(u32));
                    dma_state.is_last_call = dma_state.method_count <= 1;
                    const u32 argument = commands[index].argument;
                    if (front_run_maxwell != nullptr) {
                        front_run_maxwell->FrontCallMethod(system, run_split, dma_state.method,
                                                           argument, dma_state.is_last_call);
                    } else if (front_run_compute != nullptr) {
                        const GPUVAddr segment = dma_state.dma_get + dma_state.dma_word_offset;
                        front_run_compute->FrontCallMethod(system, run_split, dma_state.method,
                                                           argument, dma_state.is_last_call,
                                                           &segment);
                    } else if (run_split_engine != nullptr) {
                        const GPUVAddr segment = dma_state.dma_get + dma_state.dma_word_offset;
                        const bool wants_segment =
                            run_compute_segment ||
                            (run_maxwell_segment && dma_state.method >= MacroRegistersStart);
                        run_split.Method(run_split_engine, dma_state.method, argument,
                                         dma_state.is_last_call,
                                         wants_segment ? &segment : nullptr);
                    } else {
                        CallMethod(argument);
                    }
                    ++dma_state.method;
                    --dma_state.method_count;
                    ++index;
                } while (index < end_index);
'@
    $text = Replace-Once $text $old.TrimEnd("`r", "`n") $new.TrimEnd("`r", "`n") 'tight Increasing-run loop'
    Write-PatchedText $path $text
    Write-Host '[APPLIED] cached split routing for pure Increasing engine runs'
} else {
    Write-Host '[PRESENT] cached split routing for pure Increasing engine runs'
}

$final = (Get-Content $path -Raw).Replace("`r`n", "`n")
foreach ($needle in @(
    'Engines::EngineInterface* run_split_engine = nullptr;',
    'Engines::Maxwell3D* front_run_maxwell = nullptr;',
    'Engines::KeplerCompute* front_run_compute = nullptr;',
    'if (run_split_active)',
    'maxwell3d->GetNativeMacroEngine().native_turing',
    'compute->FrontRunsMacros()',
    'front_run_maxwell->FrontCallMethod(system, run_split, dma_state.method,',
    'front_run_compute->FrontCallMethod(system, run_split, dma_state.method,',
    'run_compute_segment ||',
    '(run_maxwell_segment && dma_state.method >= MacroRegistersStart)',
    'run_split.Method(run_split_engine, dma_state.method, argument,',
    'wants_segment ? &segment : nullptr',
    'CallMethod(argument);',
    '++dma_state.method;',
    '--dma_state.method_count;'
)) {
    if (-not $final.Contains($needle)) { throw "DMA increasing run-cache validation failed: missing $needle" }
}

& git diff --check
if ($LASTEXITCODE -ne 0) { throw 'DMA increasing run-cache introduced diff/whitespace errors' }
Write-Host 'DMA increasing run-cache validated: production path is independent of telemetry-only symbols.'
