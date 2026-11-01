$ErrorActionPreference = 'Stop'

# Third-stage Switch 2 DmaDispatch optimization. For a pure Increasing run handled by the default
# split=2 front-macro path, preserve the exact existing one-Method-entry-per-write ring format but
# reserve the run's maximum ring space once and Commit once. Maxwell same-value skips may emit fewer
# entries, so EndMethodBatch commits only the words actually written. Runs that reach the macro
# register range stay on the ordinary path because a front-run macro can emit extra MacroWrite work.
# Experimental for now: EDEN_NX2_DMA_RING_BATCH=1 explicitly enables it; unset/0 keeps it off.

function Write-PatchedText([string]$Path, [string]$Text) {
    $normalized = $Text.Replace("`r`n", "`n").TrimEnd("`r", "`n") + "`n"
    [IO.File]::WriteAllText((Resolve-Path $Path).Path, $normalized, [Text.UTF8Encoding]::new($false))
}

function Replace-Once([string]$Text, [string]$Old, [string]$New, [string]$Name) {
    $Text = $Text.Replace("`r`n", "`n")
    $Old = $Old.Replace("`r`n", "`n")
    $New = $New.Replace("`r`n", "`n")
    $first = $Text.IndexOf($Old, [StringComparison]::Ordinal)
    if ($first -lt 0) { throw "DMA split-ring batch: missing anchor $Name" }
    if ($Text.IndexOf($Old, $first + $Old.Length, [StringComparison]::Ordinal) -ge 0) {
        throw "DMA split-ring batch: ambiguous anchor $Name"
    }
    return $Text.Substring(0, $first) + $New + $Text.Substring($first + $Old.Length)
}

$splitHeaderPath = 'src/video_core/gpu_split.h'
$splitCppPath = 'src/video_core/gpu_split.cpp'
$dmaPath = 'src/video_core/dma_pusher.cpp'
foreach ($path in @($splitHeaderPath, $splitCppPath, $dmaPath)) {
    if (-not (Test-Path $path -PathType Leaf)) { throw "DMA split-ring batch: missing $path" }
}

$header = (Get-Content $splitHeaderPath -Raw).Replace("`r`n", "`n")
if (-not $header.Contains('method_batch_base')) {
    $frontMacrosOld = @'
    [[nodiscard]] bool FrontMacros() const {
        return front_macros;
    }
'@
    $frontMacrosNew = @'
    [[nodiscard]] bool FrontMacros() const {
        return front_macros;
    }

    /// Reserve a contiguous maximum-sized region for a run of ordinary Method entries. The
    /// existing Method encoder still writes each entry in exact order; EndMethodBatch publishes
    /// only the words actually emitted (Maxwell may skip same-value writes on the front).
    void BeginMethodBatch(Tegra::Engines::EngineInterface* engine, size_t max_words) {
        EndMethodBatch();
        SelectEngine(engine);
        method_batch_base = Reserve(max_words);
        method_batch_capacity = max_words;
        method_batch_used = 0;
    }
    void EndMethodBatch() {
        if (method_batch_base == nullptr) {
            return;
        }
        if (method_batch_used != 0) {
            Commit(method_batch_used);
        }
        method_batch_base = nullptr;
        method_batch_capacity = 0;
        method_batch_used = 0;
    }
'@
    $header = Replace-Once $header $frontMacrosOld.TrimEnd("`r", "`n") `
        $frontMacrosNew.TrimEnd("`r", "`n") 'front-macro accessor / batch API'

    $methodOld = @'
    void Method(Tegra::Engines::EngineInterface* engine, u32 method, u32 argument, bool is_last,
                const GPUVAddr* segment) {
        SelectEngine(engine);
        const size_t words = segment != nullptr ? 2 : 1;
        u64* const entry = Reserve(words);
        entry[0] = static_cast<u64>(Kind::Method) | (is_last ? IsLast : 0) |
                   (segment != nullptr ? HasSegment : 0) | (u64{method & 0xffff} << 8) |
                   (u64{argument} << 32);
        if (segment != nullptr) {
            entry[1] = *segment;
        }
        Commit(words);
    }
'@
    $methodNew = @'
    void Method(Tegra::Engines::EngineInterface* engine, u32 method, u32 argument, bool is_last,
                const GPUVAddr* segment) {
        const size_t words = segment != nullptr ? 2 : 1;
        if (method_batch_base != nullptr && engine == front_engine &&
            method_batch_used + words <= method_batch_capacity) {
            u64* const entry = method_batch_base + method_batch_used;
            method_batch_used += words;
            entry[0] = static_cast<u64>(Kind::Method) | (is_last ? IsLast : 0) |
                       (segment != nullptr ? HasSegment : 0) | (u64{method & 0xffff} << 8) |
                       (u64{argument} << 32);
            if (segment != nullptr) {
                entry[1] = *segment;
            }
            return;
        }
        // An unexpected engine/entry shape must never overrun the reserved block. Flush the exact
        // entries already encoded, then use the ordinary path for this write.
        EndMethodBatch();
        SelectEngine(engine);
        u64* const entry = Reserve(words);
        entry[0] = static_cast<u64>(Kind::Method) | (is_last ? IsLast : 0) |
                   (segment != nullptr ? HasSegment : 0) | (u64{method & 0xffff} << 8) |
                   (u64{argument} << 32);
        if (segment != nullptr) {
            entry[1] = *segment;
        }
        Commit(words);
    }
'@
    $header = Replace-Once $header $methodOld.TrimEnd("`r", "`n") $methodNew.TrimEnd("`r", "`n") `
        'GpuSplit::Method'

    $macroOld = @'
    void MacroWrite(Tegra::Engines::EngineInterface* engine, u32 method, u32 argument) {
        SelectEngine(engine);
'@
    $macroNew = @'
    void MacroWrite(Tegra::Engines::EngineInterface* engine, u32 method, u32 argument) {
        EndMethodBatch();
        SelectEngine(engine);
'@
    $header = Replace-Once $header $macroOld.TrimEnd("`r", "`n") $macroNew.TrimEnd("`r", "`n") `
        'MacroWrite batch flush'

    $deferOld = @'
    template <typename Func>
    void Defer(const Func& func) {
        static_assert(std::is_trivially_copyable_v<Func> && alignof(Func) <= alignof(u64));
'@
    $deferNew = @'
    template <typename Func>
    void Defer(const Func& func) {
        EndMethodBatch();
        static_assert(std::is_trivially_copyable_v<Func> && alignof(Func) <= alignof(u64));
'@
    $header = Replace-Once $header $deferOld.TrimEnd("`r", "`n") $deferNew.TrimEnd("`r", "`n") `
        'Defer batch flush'

    $fieldsOld = @'
    Tegra::Engines::EngineInterface* front_engine{};

    // Back side.
'@
    $fieldsNew = @'
    Tegra::Engines::EngineInterface* front_engine{};
    u64* method_batch_base{};
    size_t method_batch_capacity{};
    size_t method_batch_used{};

    // Back side.
'@
    $header = Replace-Once $header $fieldsOld.TrimEnd("`r", "`n") $fieldsNew.TrimEnd("`r", "`n") `
        'front-side batch fields'
    Write-PatchedText $splitHeaderPath $header
}

$splitCpp = (Get-Content $splitCppPath -Raw).Replace("`r`n", "`n")
if (-not $splitCpp.Contains('method_batch_base = nullptr;')) {
    $stopOld = @'
    publish_every = PublishEvery;
    front_engine = nullptr;
    back_engine = nullptr;
'@
    $stopNew = @'
    publish_every = PublishEvery;
    front_engine = nullptr;
    method_batch_base = nullptr;
    method_batch_capacity = 0;
    method_batch_used = 0;
    back_engine = nullptr;
'@
    $splitCpp = Replace-Once $splitCpp $stopOld.TrimEnd("`r", "`n") $stopNew.TrimEnd("`r", "`n") `
        'split session batch reset'

    $multiOld = @'
void GpuSplit::MultiMethod(Tegra::Engines::EngineInterface* engine, u32 method, const u32* words,
                           u32 amount, u32 methods_pending, const GPUVAddr* segment) {
    SelectEngine(engine);
'@
    $multiNew = @'
void GpuSplit::MultiMethod(Tegra::Engines::EngineInterface* engine, u32 method, const u32* words,
                           u32 amount, u32 methods_pending, const GPUVAddr* segment) {
    EndMethodBatch();
    SelectEngine(engine);
'@
    $splitCpp = Replace-Once $splitCpp $multiOld.TrimEnd("`r", "`n") $multiNew.TrimEnd("`r", "`n") `
        'MultiMethod batch flush'
    Write-PatchedText $splitCppPath $splitCpp
}

$dma = (Get-Content $dmaPath -Raw).Replace("`r`n", "`n")
if (-not $dma.Contains('EDEN_NX2_DMA_RING_BATCH')) {
    $flagOld = @'
static const bool g_nx2_dma_increasing_run = [] {
    const char* value = std::getenv("EDEN_NX2_DMA_INC_RUN");
    return value == nullptr || value[0] != '0';
}();
'@
    $flagNew = @'
static const bool g_nx2_dma_increasing_run = [] {
    const char* value = std::getenv("EDEN_NX2_DMA_INC_RUN");
    return value == nullptr || value[0] != '0';
}();
static const bool g_nx2_dma_ring_batch = [] {
    const char* value = std::getenv("EDEN_NX2_DMA_RING_BATCH");
    return value != nullptr && value[0] != '0';
}();
'@
    $dma = Replace-Once $dma $flagOld.TrimEnd("`r", "`n") $flagNew.TrimEnd("`r", "`n") `
        'DMA ring-batch opt-in flag'

    $beginOld = @'
                do {
                    dma_state.dma_word_offset = u64((word_offset + index) * sizeof(u32));
'@
    $beginNew = @'
                Engines::EngineInterface* run_batch_engine = front_run_maxwell;
                if (run_batch_engine == nullptr) {
                    run_batch_engine = front_run_compute;
                }
                const bool run_ring_batch = g_nx2_dma_ring_batch && run_batch_engine != nullptr &&
                                            dma_state.method + available_words <= MacroRegistersStart;
                if (run_ring_batch) {
                    const size_t words_per_method = front_run_compute != nullptr ? 2 : 1;
                    run_split.BeginMethodBatch(run_batch_engine,
                                               size_t{available_words} * words_per_method);
                }
                do {
                    dma_state.dma_word_offset = u64((word_offset + index) * sizeof(u32));
'@
    $dma = Replace-Once $dma $beginOld.TrimEnd("`r", "`n") $beginNew.TrimEnd("`r", "`n") `
        'Increasing-run batch begin'

    $endOld = @'
                } while (index < end_index);
                continue;
'@
    $endNew = @'
                } while (index < end_index);
                if (run_ring_batch) {
                    run_split.EndMethodBatch();
                }
                continue;
'@
    $dma = Replace-Once $dma $endOld.TrimEnd("`r", "`n") $endNew.TrimEnd("`r", "`n") `
        'Increasing-run batch end'
    Write-PatchedText $dmaPath $dma
}

$checks = @(
    @($splitHeaderPath, 'void BeginMethodBatch(Tegra::Engines::EngineInterface* engine, size_t max_words)', 'batch begin API'),
    @($splitHeaderPath, 'method_batch_used + words <= method_batch_capacity', 'bounded batch encoder'),
    @($splitHeaderPath, 'if (method_batch_used != 0)', 'empty-batch commit avoidance'),
    @($splitHeaderPath, 'Commit(method_batch_used);', 'actual-size batch commit'),
    @($splitHeaderPath, 'EndMethodBatch();', 'unexpected-entry batch flush'),
    @($splitCppPath, 'method_batch_base = nullptr;', 'session batch reset'),
    @($splitCppPath, 'void GpuSplit::MultiMethod', 'existing multimethod path'),
    @($dmaPath, 'EDEN_NX2_DMA_RING_BATCH', 'ring-batch opt-in switch'),
    @($dmaPath, "return value != nullptr && value[0] != '0';", 'ring-batch default-off gate'),
    @($dmaPath, 'dma_state.method + available_words <= MacroRegistersStart', 'macro-range exclusion'),
    @($dmaPath, 'run_split.BeginMethodBatch(run_batch_engine,', 'Increasing-run batch begin'),
    @($dmaPath, 'run_split.EndMethodBatch();', 'Increasing-run batch end')
)
foreach ($check in $checks) {
    $body = (Get-Content $check[0] -Raw)
    if (-not $body.Contains($check[1])) {
        throw "DMA split-ring batch validation failed: $($check[2]) missing from $($check[0])"
    }
}

& git diff --check
if ($LASTEXITCODE -ne 0) { throw 'DMA split-ring batch introduced diff/whitespace errors' }
Write-Host 'DMA split-ring batch validated: existing Method encoding preserved; macro-range runs excluded; default off until profiled.'
