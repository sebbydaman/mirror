$ErrorActionPreference = 'Stop'

# Profiling-only classification of the remaining DmaDispatch CPU bucket. This adds no counters to
# normal gameplay: every update is behind the already opt-in EDEN_NX2_GPU_PROFILE flag. The goal is
# to learn whether the remaining dispatch time is dominated by increasing engine runs (a candidate
# for split-ring packetization), non-increasing runs, puller methods, or inline/IncreaseOnce traffic
# before changing command-stream semantics.

function Write-PatchedText([string]$Path, [string]$Text) {
    $normalized = $Text.TrimEnd("`r", "`n") + "`n"
    [IO.File]::WriteAllText((Resolve-Path $Path).Path, $normalized, [Text.UTF8Encoding]::new($false))
}

function Replace-Once([string]$Text, [string]$Old, [string]$New, [string]$Name) {
    $first = $Text.IndexOf($Old, [StringComparison]::Ordinal)
    if ($first -lt 0) { throw "DMA dispatch telemetry: missing anchor $Name" }
    $second = $Text.IndexOf($Old, $first + $Old.Length, [StringComparison]::Ordinal)
    if ($second -ge 0) { throw "DMA dispatch telemetry: ambiguous anchor $Name" }
    return $Text.Substring(0, $first) + $New + $Text.Substring($first + $Old.Length)
}

function Insert-AfterOnce([string]$Text, [string]$Anchor, [string]$Insertion, [string]$Name) {
    $first = $Text.IndexOf($Anchor, [StringComparison]::Ordinal)
    if ($first -lt 0) { throw "DMA dispatch telemetry: missing anchor $Name" }
    $second = $Text.IndexOf($Anchor, $first + $Anchor.Length, [StringComparison]::Ordinal)
    if ($second -ge 0) { throw "DMA dispatch telemetry: ambiguous anchor $Name" }
    $after = $first + $Anchor.Length
    return $Text.Substring(0, $after) + $Insertion + $Text.Substring($after)
}

$profilePath = 'src/video_core/nx2_profile.h'
$dmaPath = 'src/video_core/dma_pusher.cpp'
foreach ($path in @($profilePath, $dmaPath)) {
    if (-not (Test-Path $path -PathType Leaf)) {
        throw "DMA dispatch telemetry: missing $path"
    }
}

$profile = (Get-Content $profilePath -Raw).Replace("`r`n", "`n")
$dma = (Get-Content $dmaPath -Raw).Replace("`r`n", "`n")
$marker = 'DmaIncreasingRuns'
if ($profile.Contains($marker) -or $dma.Contains('Counter::DmaSplitEngineWords')) {
    foreach ($needle in @(
        'DmaIncreasingRuns', 'DmaIncreasingWords', 'DmaNonIncreasingRuns',
        'DmaNonIncreasingWords', 'DmaIncreaseOnceRuns', 'DmaIncreaseOnceWords',
        'DmaInlineCommands', 'DmaPullerWords', 'DmaSplitEngineWords'
    )) {
        if (-not $profile.Contains($needle)) {
            throw "DMA dispatch telemetry: partial profile implementation; missing $needle"
        }
    }
    foreach ($needle in @('Counter::DmaPullerWords', 'Counter::DmaSplitEngineWords')) {
        if (-not $dma.Contains($needle)) {
            throw "DMA dispatch telemetry: partial DMA implementation; missing $needle"
        }
    }
    Write-Host '[PRESENT] opt-in DmaDispatch traffic-shape telemetry'
    exit 0
}

# Do not replace the whole Counter enum. The profiler has gained counters over time; PipelineMisses
# is the stable semantic insertion point validated by the frontier regression suite.
$counterAnchor = '    PipelineMisses,'
$counterInsertion = @'
    DmaIncreasingRuns,
    DmaIncreasingWords,
    DmaNonIncreasingRuns,
    DmaNonIncreasingWords,
    DmaIncreaseOnceRuns,
    DmaIncreaseOnceWords,
    DmaInlineCommands,
    DmaPullerWords,
    DmaSplitEngineWords,
'@
$counterInsertion = "`n" + $counterInsertion.TrimEnd("`r", "`n")
$profile = Insert-AfterOnce $profile $counterAnchor $counterInsertion 'PipelineMisses counter insertion point'

# Likewise append DMA reporting after the existing pipeline-miss report instead of assuming the
# complete report block has a frozen shape.
$reportAnchor = '    line += fmt::format(" | pipeline cache misses {:.0f}", rate(Counter::PipelineMisses));'
$reportInsertion = @'
    const auto average_run = [&](Counter words, Counter runs) {
        const double run_rate = rate(runs);
        return run_rate > 0.0 ? rate(words) / run_rate : 0.0;
    };
    line += fmt::format(
        " | dma inc {:.0f} words/{:.0f} runs ({:.1f}/run) | dma non-inc {:.0f} words/{:.0f} runs ({:.1f}/run)",
        rate(Counter::DmaIncreasingWords), rate(Counter::DmaIncreasingRuns),
        average_run(Counter::DmaIncreasingWords, Counter::DmaIncreasingRuns),
        rate(Counter::DmaNonIncreasingWords), rate(Counter::DmaNonIncreasingRuns),
        average_run(Counter::DmaNonIncreasingWords, Counter::DmaNonIncreasingRuns));
    line += fmt::format(
        " | dma increase-once {:.0f} words/{:.0f} runs | inline {:.0f} | puller words {:.0f} | split engine words {:.0f}",
        rate(Counter::DmaIncreaseOnceWords), rate(Counter::DmaIncreaseOnceRuns),
        rate(Counter::DmaInlineCommands), rate(Counter::DmaPullerWords),
        rate(Counter::DmaSplitEngineWords));
'@
$reportInsertion = "`n" + $reportInsertion.TrimEnd("`r", "`n")
$profile = Insert-AfterOnce $profile $reportAnchor $reportInsertion 'PipelineMisses report insertion point'
Write-PatchedText $profilePath $profile

$functionOld = @'
size_t DmaPusher::ProcessCommands(std::span<const CommandHeader> commands, size_t word_offset) {
    VideoCommon::Nx2Profile::Scope dispatch_scope{VideoCommon::Nx2Profile::Zone::DmaDispatch};
'@
$functionOld = $functionOld.TrimEnd("`r", "`n")
$functionNew = @'
size_t DmaPusher::ProcessCommands(std::span<const CommandHeader> commands, size_t word_offset) {
    namespace Profile = VideoCommon::Nx2Profile;
    Profile::Scope dispatch_scope{Profile::Zone::DmaDispatch};
'@
$functionNew = $functionNew.TrimEnd("`r", "`n")
$dma = Replace-Once $dma $functionOld $functionNew 'ProcessCommands profile alias'

$nonIncOld = @'
            if (g_nx2_ampere && dma_state.method < non_puller_methods) {
                max_write = 1; // a semaphore acquire may suspend the channel after any word
            }
            CallMultiMethod(&command_header.argument, max_write);
'@
$nonIncOld = $nonIncOld.TrimEnd("`r", "`n")
$nonIncNew = @'
            if (g_nx2_ampere && dma_state.method < non_puller_methods) {
                max_write = 1; // a semaphore acquire may suspend the channel after any word
            }
            if (Profile::Enabled()) [[unlikely]] {
                if (dma_state.method < non_puller_methods) {
                    Profile::Add(Profile::Counter::DmaPullerWords, max_write);
                } else if (VideoCommon::GpuSplit::Get().Active()) {
                    Profile::Add(Profile::Counter::DmaSplitEngineWords, max_write);
                }
            }
            CallMultiMethod(&command_header.argument, max_write);
'@
$nonIncNew = $nonIncNew.TrimEnd("`r", "`n")
$dma = Replace-Once $dma $nonIncOld $nonIncNew 'non-increasing actual-word classification'

$incWordOld = @'
            dma_state.is_last_call = dma_state.method_count <= 1;
            const u32 curr_method = dma_state.method;
            CallMethod(command_header.argument);
'@
$incWordOld = $incWordOld.TrimEnd("`r", "`n")
$incWordNew = @'
            dma_state.is_last_call = dma_state.method_count <= 1;
            const u32 curr_method = dma_state.method;
            if (Profile::Enabled()) [[unlikely]] {
                if (curr_method < non_puller_methods) {
                    Profile::Add(Profile::Counter::DmaPullerWords, 1);
                } else if (VideoCommon::GpuSplit::Get().Active()) {
                    Profile::Add(Profile::Counter::DmaSplitEngineWords, 1);
                }
            }
            CallMethod(command_header.argument);
'@
$incWordNew = $incWordNew.TrimEnd("`r", "`n")
$dma = Replace-Once $dma $incWordOld $incWordNew 'increasing actual-word classification'

$increasingOld = @'
            case SubmissionMode::Increasing:
                SetState(command_header);
                dma_state.non_incrementing = false;
                dma_increment_once = false;
                break;
'@
$increasingOld = $increasingOld.TrimEnd("`r", "`n")
$increasingNew = @'
            case SubmissionMode::Increasing:
                SetState(command_header);
                if (Profile::Enabled()) [[unlikely]] {
                    Profile::Add(Profile::Counter::DmaIncreasingRuns, 1);
                    Profile::Add(Profile::Counter::DmaIncreasingWords, command_header.method_count);
                }
                dma_state.non_incrementing = false;
                dma_increment_once = false;
                break;
'@
$increasingNew = $increasingNew.TrimEnd("`r", "`n")
$dma = Replace-Once $dma $increasingOld $increasingNew 'Increasing header telemetry'

$nonIncreasingOld = @'
            case SubmissionMode::NonIncreasing:
                SetState(command_header);
                dma_state.non_incrementing = true;
                dma_increment_once = false;
                break;
'@
$nonIncreasingOld = $nonIncreasingOld.TrimEnd("`r", "`n")
$nonIncreasingNew = @'
            case SubmissionMode::NonIncreasing:
                SetState(command_header);
                if (Profile::Enabled()) [[unlikely]] {
                    Profile::Add(Profile::Counter::DmaNonIncreasingRuns, 1);
                    Profile::Add(Profile::Counter::DmaNonIncreasingWords, command_header.method_count);
                }
                dma_state.non_incrementing = true;
                dma_increment_once = false;
                break;
'@
$nonIncreasingNew = $nonIncreasingNew.TrimEnd("`r", "`n")
$dma = Replace-Once $dma $nonIncreasingOld $nonIncreasingNew 'NonIncreasing header telemetry'

$inlineOld = @'
            case SubmissionMode::Inline:
                dma_state.method = command_header.method;
                dma_state.subchannel = command_header.subchannel;
                dma_state.dma_word_offset = u64(-s64(dma_state.dma_get)); // negate to set address as 0
                CallMethod(command_header.arg_count);
'@
$inlineOld = $inlineOld.TrimEnd("`r", "`n")
$inlineNew = @'
            case SubmissionMode::Inline:
                dma_state.method = command_header.method;
                dma_state.subchannel = command_header.subchannel;
                dma_state.dma_word_offset = u64(-s64(dma_state.dma_get)); // negate to set address as 0
                if (Profile::Enabled()) [[unlikely]] {
                    Profile::Add(Profile::Counter::DmaInlineCommands, 1);
                    if (dma_state.method < non_puller_methods) {
                        Profile::Add(Profile::Counter::DmaPullerWords, 1);
                    } else if (VideoCommon::GpuSplit::Get().Active()) {
                        Profile::Add(Profile::Counter::DmaSplitEngineWords, 1);
                    }
                }
                CallMethod(command_header.arg_count);
'@
$inlineNew = $inlineNew.TrimEnd("`r", "`n")
$dma = Replace-Once $dma $inlineOld $inlineNew 'Inline command telemetry'

$increaseOnceOld = @'
            case SubmissionMode::IncreaseOnce:
                SetState(command_header);
                dma_state.non_incrementing = false;
                dma_increment_once = true;
                break;
'@
$increaseOnceOld = $increaseOnceOld.TrimEnd("`r", "`n")
$increaseOnceNew = @'
            case SubmissionMode::IncreaseOnce:
                SetState(command_header);
                if (Profile::Enabled()) [[unlikely]] {
                    Profile::Add(Profile::Counter::DmaIncreaseOnceRuns, 1);
                    Profile::Add(Profile::Counter::DmaIncreaseOnceWords, command_header.method_count);
                }
                dma_state.non_incrementing = false;
                dma_increment_once = true;
                break;
'@
$increaseOnceNew = $increaseOnceNew.TrimEnd("`r", "`n")
$dma = Replace-Once $dma $increaseOnceOld $increaseOnceNew 'IncreaseOnce header telemetry'

Write-PatchedText $dmaPath $dma

$finalProfile = Get-Content $profilePath -Raw
$finalDma = Get-Content $dmaPath -Raw
foreach ($needle in @(
    'DmaIncreasingRuns', 'DmaIncreasingWords', 'DmaNonIncreasingRuns', 'DmaNonIncreasingWords',
    'DmaIncreaseOnceRuns', 'DmaIncreaseOnceWords', 'DmaInlineCommands', 'DmaPullerWords',
    'DmaSplitEngineWords', 'dma inc {:.0f} words/{:.0f} runs'
)) {
    if (-not $finalProfile.Contains($needle)) {
        throw "DMA dispatch telemetry validation failed: profile missing $needle"
    }
}
foreach ($needle in @(
    'Counter::DmaPullerWords', 'Counter::DmaSplitEngineWords',
    'Counter::DmaIncreasingRuns', 'Counter::DmaNonIncreasingRuns', 'Counter::DmaIncreaseOnceRuns'
)) {
    if (-not $finalDma.Contains($needle)) {
        throw "DMA dispatch telemetry validation failed: DMA pusher missing $needle"
    }
}

& git diff --check
if ($LASTEXITCODE -ne 0) {
    throw 'DMA dispatch telemetry introduced diff/whitespace errors'
}

Write-Host '[APPLIED] Opt-in DmaDispatch traffic-shape telemetry (EDEN_NX2_GPU_PROFILE)'
