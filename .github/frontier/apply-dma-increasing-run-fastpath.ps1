$ErrorActionPreference = 'Stop'

# Switch 2 DmaDispatch fast path: pure Increasing engine runs currently re-enter the outer parser
# once per data word even though they cannot suspend on a puller acquire and do not switch method
# mode mid-run. Keep every CallMethod, DMA byte offset and is_last_call transition exactly in order,
# but consume the available run in one tight loop. Puller methods, IncreaseOnce and non-incrementing
# commands stay on the existing paths. EDEN_NX2_DMA_INC_RUN=0 is a rollback/A-B switch.

function Write-PatchedText([string]$Path, [string]$Text) {
    $normalized = $Text.Replace("`r`n", "`n").TrimEnd("`r", "`n") + "`n"
    [IO.File]::WriteAllText((Resolve-Path $Path).Path, $normalized, [Text.UTF8Encoding]::new($false))
}

function Replace-Once([string]$Text, [string]$Old, [string]$New, [string]$Name) {
    $Text = $Text.Replace("`r`n", "`n")
    $Old = $Old.Replace("`r`n", "`n")
    $New = $New.Replace("`r`n", "`n")
    $first = $Text.IndexOf($Old, [StringComparison]::Ordinal)
    if ($first -lt 0) { throw "DMA increasing-run fast path: missing anchor $Name" }
    if ($Text.IndexOf($Old, $first + $Old.Length, [StringComparison]::Ordinal) -ge 0) {
        throw "DMA increasing-run fast path: ambiguous anchor $Name"
    }
    return $Text.Substring(0, $first) + $New + $Text.Substring($first + $Old.Length)
}

$path = 'src/video_core/dma_pusher.cpp'
if (-not (Test-Path $path -PathType Leaf)) {
    throw "DMA increasing-run fast path: missing $path"
}

$text = (Get-Content $path -Raw).Replace("`r`n", "`n")
$marker = 'EDEN_NX2_DMA_INC_RUN'
if (-not $text.Contains($marker)) {
    $constantAnchor = @'
constexpr u32 MacroRegistersStart = 0xE00;
constexpr u32 ComputeInline = 0x6D;
'@
    $constantReplacement = @'
constexpr u32 MacroRegistersStart = 0xE00;
constexpr u32 ComputeInline = 0x6D;

// Pure Increasing engine-run parser fast path. This is Switch-2-only and can be disabled for
// correctness/performance A-B testing without rebuilding.
static const bool g_nx2_dma_increasing_run = [] {
    const char* value = std::getenv("EDEN_NX2_DMA_INC_RUN");
    return value == nullptr || value[0] != '0';
}();
'@
    $text = Replace-Once $text $constantAnchor.TrimEnd("`r", "`n") `
        $constantReplacement.TrimEnd("`r", "`n") 'DMA constants'

    $branchAnchor = @'
        } else if (dma_state.method_count) {
            auto const command_header = commands[index]; //can copy
'@
    $branchReplacement = @'
        } else if (dma_state.method_count) {
            // A pure Increasing engine run cannot suspend in the puller and never flips to the
            // non-incrementing mode. Consume the available data words in one parser pass while
            // preserving the exact per-method engine calls and current-DMA-segment offsets.
            const u32 available_words = static_cast<u32>(std::min<std::size_t>(
                dma_state.method_count, commands.size() - index));
            if (g_nx2_ampere && g_nx2_dma_increasing_run && !dma_increment_once &&
                dma_state.method >= non_puller_methods && available_words > 1) {
                const size_t end_index = index + available_words;
                do {
                    dma_state.dma_word_offset = u64((word_offset + index) * sizeof(u32));
                    dma_state.is_last_call = dma_state.method_count <= 1;
                    CallMethod(commands[index].argument);
                    ++dma_state.method;
                    --dma_state.method_count;
                    ++index;
                } while (index < end_index);
                continue;
            }
            auto const command_header = commands[index]; //can copy
'@
    $text = Replace-Once $text $branchAnchor.TrimEnd("`r", "`n") `
        $branchReplacement.TrimEnd("`r", "`n") 'increasing engine data-word branch'

    Write-PatchedText $path $text
    Write-Host '[APPLIED] Switch 2 tight-loop DmaDispatch fast path for pure Increasing engine runs'
} else {
    Write-Host '[PRESENT] Switch 2 tight-loop DmaDispatch fast path for pure Increasing engine runs'
}

$final = (Get-Content $path -Raw).Replace("`r`n", "`n")
foreach ($needle in @(
    'std::getenv("EDEN_NX2_DMA_INC_RUN")',
    'g_nx2_ampere && g_nx2_dma_increasing_run && !dma_increment_once',
    'dma_state.method >= non_puller_methods && available_words > 1',
    'const size_t end_index = index + available_words;',
    'CallMethod(commands[index].argument);',
    '++dma_state.method;',
    '--dma_state.method_count;',
    '} while (index < end_index);',
    'if (curr_method < non_puller_methods && puller.HasPendingAcquire())'
)) {
    if (-not $final.Contains($needle)) {
        throw "DMA increasing-run fast path validation failed: missing $needle"
    }
}

& git diff --check
if ($LASTEXITCODE -ne 0) {
    throw 'DMA increasing-run fast path introduced diff/whitespace errors'
}

Write-Host 'DMA increasing-run fast path validated: engine ordering preserved; puller/IncreaseOnce paths unchanged.'
