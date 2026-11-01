$ErrorActionPreference = 'Stop'

# Second-stage Switch 2 DmaDispatch optimization. The tight Increasing-run parser already removes
# one outer ProcessCommands iteration per data word, but the default split=2 path still repeats the
# same subchannel/type/front-macro dispatch checks inside DmaPusher::CallMethod for every word.
# Cache that decision once per pure Increasing run and call the same existing FrontCallMethod
# implementation directly for Maxwell3D native Turing and Kepler compute front-macro paths.
# All other engines/states fall back to CallMethod unchanged.

function Write-PatchedText([string]$Path, [string]$Text) {
    $normalized = $Text.Replace("`r`n", "`n").TrimEnd("`r", "`n") + "`n"
    [IO.File]::WriteAllText((Resolve-Path $Path).Path, $normalized, [Text.UTF8Encoding]::new($false))
}

function Replace-Once([string]$Text, [string]$Old, [string]$New, [string]$Name) {
    $Text = $Text.Replace("`r`n", "`n")
    $Old = $Old.Replace("`r`n", "`n")
    $New = $New.Replace("`r`n", "`n")
    $first = $Text.IndexOf($Old, [StringComparison]::Ordinal)
    if ($first -lt 0) { throw "DMA increasing front-cache: missing anchor $Name" }
    if ($Text.IndexOf($Old, $first + $Old.Length, [StringComparison]::Ordinal) -ge 0) {
        throw "DMA increasing front-cache: ambiguous anchor $Name"
    }
    return $Text.Substring(0, $first) + $New + $Text.Substring($first + $Old.Length)
}

$path = 'src/video_core/dma_pusher.cpp'
if (-not (Test-Path $path -PathType Leaf)) {
    throw "DMA increasing front-cache: missing $path"
}

$text = (Get-Content $path -Raw).Replace("`r`n", "`n")
$marker = 'front_run_maxwell'
if (-not $text.Contains($marker)) {
    $old = @'
                const size_t end_index = index + available_words;
                do {
                    dma_state.dma_word_offset = u64((word_offset + index) * sizeof(u32));
                    dma_state.is_last_call = dma_state.method_count <= 1;
                    if (Profile::Enabled()) [[unlikely]] {
                        if (VideoCommon::GpuSplit::Get().Active()) {
                            Profile::Add(Profile::Counter::DmaSplitEngineWords, 1);
                        }
                    }
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
                const bool run_profile_enabled = Profile::Enabled();
                Engines::Maxwell3D* front_run_maxwell = nullptr;
                Engines::KeplerCompute* front_run_compute = nullptr;
                if (run_split_active && run_split.FrontMacros()) {
                    if (auto* const run_engine = subchannels[dma_state.subchannel];
                        run_engine != nullptr) {
                        const auto run_type = subchannel_type[dma_state.subchannel];
                        if (run_type == Engines::EngineTypes::Maxwell3D) {
                            auto* const maxwell3d = static_cast<Engines::Maxwell3D*>(run_engine);
                            if (maxwell3d->GetNativeMacroEngine().native_turing) {
                                front_run_maxwell = maxwell3d;
                            }
                        } else if (run_type == Engines::EngineTypes::KeplerCompute) {
                            auto* const compute = static_cast<Engines::KeplerCompute*>(run_engine);
                            if (compute->FrontRunsMacros()) {
                                front_run_compute = compute;
                            }
                        }
                    }
                }
                do {
                    dma_state.dma_word_offset = u64((word_offset + index) * sizeof(u32));
                    dma_state.is_last_call = dma_state.method_count <= 1;
                    if (run_profile_enabled) [[unlikely]] {
                        if (run_split_active) {
                            Profile::Add(Profile::Counter::DmaSplitEngineWords, 1);
                        }
                    }
                    const u32 argument = commands[index].argument;
                    if (front_run_maxwell != nullptr) {
                        front_run_maxwell->FrontCallMethod(system, run_split, dma_state.method,
                                                           argument, dma_state.is_last_call);
                    } else if (front_run_compute != nullptr) {
                        const GPUVAddr segment = dma_state.dma_get + dma_state.dma_word_offset;
                        front_run_compute->FrontCallMethod(system, run_split, dma_state.method,
                                                           argument, dma_state.is_last_call,
                                                           &segment);
                    } else {
                        CallMethod(argument);
                    }
                    ++dma_state.method;
                    --dma_state.method_count;
                    ++index;
                } while (index < end_index);
'@
    $old = $old.Replace("`r`n", "`n").TrimEnd("`r", "`n")
    $new = $new.Replace("`r`n", "`n").TrimEnd("`r", "`n")
    $text = Replace-Once $text $old $new 'tight Increasing-run loop'
    Write-PatchedText $path $text
    Write-Host '[APPLIED] cached front-macro dispatch for pure Increasing engine runs'
} else {
    Write-Host '[PRESENT] cached front-macro dispatch for pure Increasing engine runs'
}

$final = (Get-Content $path -Raw).Replace("`r`n", "`n")
foreach ($needle in @(
    'Engines::Maxwell3D* front_run_maxwell = nullptr;',
    'Engines::KeplerCompute* front_run_compute = nullptr;',
    'maxwell3d->GetNativeMacroEngine().native_turing',
    'compute->FrontRunsMacros()',
    'front_run_maxwell->FrontCallMethod(system, run_split, dma_state.method,',
    'front_run_compute->FrontCallMethod(system, run_split, dma_state.method,',
    'const GPUVAddr segment = dma_state.dma_get + dma_state.dma_word_offset;',
    'CallMethod(argument);',
    '++dma_state.method;',
    '--dma_state.method_count;'
)) {
    if (-not $final.Contains($needle)) {
        throw "DMA increasing front-cache validation failed: missing $needle"
    }
}

& git diff --check
if ($LASTEXITCODE -ne 0) {
    throw 'DMA increasing front-cache introduced diff/whitespace errors'
}

Write-Host 'DMA increasing front-cache validated: same front-macro implementations, cached once per run.'
