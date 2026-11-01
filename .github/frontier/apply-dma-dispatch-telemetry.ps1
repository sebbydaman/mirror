$ErrorActionPreference = 'Stop'

# Profiling-only classification of the remaining DmaDispatch CPU bucket. All counter updates stay
# behind the existing opt-in EDEN_NX2_GPU_PROFILE gate. This measures command traffic before we
# change any ordering-sensitive GPU command semantics.

function Normalize-Lf([string]$Text) {
    return $Text.Replace("`r`n", "`n")
}

function Write-PatchedText([string]$Path, [string]$Text) {
    $normalized = (Normalize-Lf $Text).TrimEnd("`r", "`n") + "`n"
    [IO.File]::WriteAllText((Resolve-Path $Path).Path, $normalized, [Text.UTF8Encoding]::new($false))
}

function Replace-Once([string]$Text, [string]$Old, [string]$New, [string]$Name) {
    # GitHub's Windows runners check scripts out with CRLF while the integrated source is normalized
    # to LF before patching. Normalize the here-string anchors too or every multi-line match fails.
    $Text = Normalize-Lf $Text
    $Old = Normalize-Lf $Old
    $New = Normalize-Lf $New
    $first = $Text.IndexOf($Old, [StringComparison]::Ordinal)
    if ($first -lt 0) { throw "DMA dispatch telemetry: missing anchor $Name" }
    $second = $Text.IndexOf($Old, $first + $Old.Length, [StringComparison]::Ordinal)
    if ($second -ge 0) { throw "DMA dispatch telemetry: ambiguous anchor $Name" }
    return $Text.Substring(0, $first) + $New + $Text.Substring($first + $Old.Length)
}

function Insert-AfterOnce([string]$Text, [string]$Anchor, [string]$Insertion, [string]$Name) {
    $Text = Normalize-Lf $Text
    $Anchor = Normalize-Lf $Anchor
    $Insertion = Normalize-Lf $Insertion
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

$profile = Normalize-Lf (Get-Content $profilePath -Raw)
$dma = Normalize-Lf (Get-Content $dmaPath -Raw)

if ($profile.Contains('DmaIncreasingRuns') -or $dma.Contains('Counter::DmaSplitEngineWords')) {
    foreach ($needle in @(
        'DmaIncreasingRuns', 'DmaIncreasingWords', 'DmaNonIncreasingRuns',
        'DmaNonIncreasingWords', 'DmaIncreaseOnceRuns', 'DmaIncreaseOnceWords',
        'DmaInlineCommands', 'DmaPullerWords', 'DmaSplitEngineWords'
    )) {
        if (-not $profile.Contains($needle)) {
            throw "DMA dispatch telemetry: partial profile implementation; missing $needle"
        }
    }
    foreach ($needle in @(
        'namespace Profile = VideoCommon::Nx2Profile;',
        'Counter::DmaPullerWords', 'Counter::DmaSplitEngineWords'
    )) {
        if (-not $dma.Contains($needle)) {
            throw "DMA dispatch telemetry: partial DMA implementation; missing $needle"
        }
    }
    Write-Host '[PRESENT] opt-in DmaDispatch traffic-shape telemetry'
    exit 0
}

# Insert after stable semantic profiler entries rather than replacing the complete enum/report block.
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
$profile = Insert-AfterOnce $profile '    PipelineMisses,' ("`n" + $counterInsertion.TrimEnd("`r", "`n")) 'PipelineMisses counter insertion point'

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
$profile = Insert-AfterOnce $profile `
    '    line += fmt::format(" | pipeline cache misses {:.0f}", rate(Counter::PipelineMisses));' `
    ("`n" + $reportInsertion.TrimEnd("`r", "`n")) `
    'PipelineMisses report insertion point'
Write-PatchedText $profilePath $profile

# Namespace aliases are namespace-scope declarations in C++. Keep the alias at Tegra scope rather
# than putting it inside ProcessCommands; the existing DmaDispatch Scope itself remains unchanged.
$dma = Insert-AfterOnce $dma 'namespace Tegra {' `
    "`n`nnamespace Profile = VideoCommon::Nx2Profile;" `
    'Tegra namespace profiler alias'

$nonIncOld = @'
            if (g_nx2_ampere && dma_state.method < non_puller_methods) {
                max_write = 1; // a semaphore acquire may suspend the channel after any word
            }
            CallMultiMethod(&command_header.argument, max_write);
'@
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
$dma = Replace-Once $dma $nonIncOld.TrimEnd("`r", "`n") $nonIncNew.TrimEnd("`r", "`n") 'non-increasing actual-word classification'

$incWordOld = @'
            dma_state.is_last_call = dma_state.method_count <= 1;
            const u32 curr_method = dma_state.method;
            CallMethod(command_header.argument);
'@
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
$dma = Replace-Once $dma $incWordOld.TrimEnd("`r", "`n") $incWordNew.TrimEnd("`r", "`n") 'increasing actual-word classification'

$increasingOld = @'
            case SubmissionMode::Increasing:
                SetState(command_header);
                dma_state.non_incrementing = false;
                dma_increment_once = false;
                break;
'@
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
$dma = Replace-Once $dma $increasingOld.TrimEnd("`r", "`n") $increasingNew.TrimEnd("`r", "`n") 'Increasing header telemetry'

$nonIncreasingOld = @'
            case SubmissionMode::NonIncreasing:
                SetState(command_header);
                dma_state.non_incrementing = true;
                dma_increment_once = false;
                break;
'@
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
$dma = Replace-Once $dma $nonIncreasingOld.TrimEnd("`r", "`n") $nonIncreasingNew.TrimEnd("`r", "`n") 'NonIncreasing header telemetry'

$inlineOld = @'
            case SubmissionMode::Inline:
                dma_state.method = command_header.method;
                dma_state.subchannel = command_header.subchannel;
                dma_state.dma_word_offset = u64(-s64(dma_state.dma_get)); // negate to set address as 0
                CallMethod(command_header.arg_count);
'@
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
$dma = Replace-Once $dma $inlineOld.TrimEnd("`r", "`n") $inlineNew.TrimEnd("`r", "`n") 'Inline command telemetry'

$increaseOnceOld = @'
            case SubmissionMode::IncreaseOnce:
                SetState(command_header);
                dma_state.non_incrementing = false;
                dma_increment_once = true;
                break;
'@
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
$dma = Replace-Once $dma $increaseOnceOld.TrimEnd("`r", "`n") $increaseOnceNew.TrimEnd("`r", "`n") 'IncreaseOnce header telemetry'

Write-PatchedText $dmaPath $dma

$finalProfile = Normalize-Lf (Get-Content $profilePath -Raw)
$finalDma = Normalize-Lf (Get-Content $dmaPath -Raw)
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
    'namespace Profile = VideoCommon::Nx2Profile;',
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
