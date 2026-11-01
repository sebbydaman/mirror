$ErrorActionPreference = 'Stop'

# Safe subset of zortos293/Eglantine build 31 (badc91e): reduce CPU/JIT/cache bookkeeping and
# move native driver compilation off the translation workers. The donor's texture partial-page
# batching is intentionally excluded here because it depends on a newer readback-coherence layer
# that this branch does not currently carry in the same form.

function Write-PatchedText([string]$Path, [string]$Text) {
    $normalized = $Text.TrimEnd("`r", "`n") + "`n"
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText((Resolve-Path $Path).Path, $normalized, $utf8NoBom)
}

function Require-Text([string]$Path, [string]$Needle, [string]$Name) {
    if (-not (Test-Path $Path -PathType Leaf)) {
        throw "Build31 frontier: missing required file $Path"
    }
    if (-not (Get-Content $Path -Raw).Contains($Needle)) {
        throw "Build31 frontier: $Name missing from $Path"
    }
    Write-Host "[PASS] $Name"
}

# 1) Preserve the ASID that owns the currently coalesced cache-count run. Without this assignment,
# later contiguous pages from the new ASID can keep being compared against the stale owner.
$deviceMemory = 'src/core/device_memory_manager.inc'
$deviceText = Get-Content $deviceMemory -Raw
if (-not $deviceText.Contains('            asid = asid_2;')) {
    $old = @'
        if (asid.id != asid_2.id) [[unlikely]] {
            release_pending();
            memory_device_inter = registered_processes[asid_2.id];
        }
'@
    $new = @'
        if (asid.id != asid_2.id) [[unlikely]] {
            release_pending();
            asid = asid_2;
            memory_device_inter = registered_processes[asid_2.id];
        }
'@
    $old = $old.TrimEnd("`r", "`n")
    if (-not $deviceText.Contains($old)) {
        throw 'Build31 frontier: mixed-ASID cache tracking anchor changed'
    }
    Write-PatchedText $deviceMemory ($deviceText.Replace($old, $new.TrimEnd("`r", "`n")))
    Write-Host '[APPLIED] mixed-ASID cache ownership preservation'
} else {
    Write-Host '[PRESENT] mixed-ASID cache ownership preservation'
}

# 2) Dynarmic JIT invalidation: index translated ranges by start address instead of scanning every
# translated block for every invalidated interval. max_span bounds how far back a possible overlap
# can begin, preserving correctness for long translated ranges while shrinking normal invalidation.
$rangeHeader = 'src/dynarmic/src/dynarmic/backend/block_range_information.h'
$rangeCpp = 'src/dynarmic/src/dynarmic/backend/block_range_information.cpp'
$header = Get-Content $rangeHeader -Raw
if (-not $header.Contains('std::multimap<P, Range> ranges;')) {
    if (-not $header.Contains('#include <vector>')) {
        throw 'Build31 frontier: Dynarmic range container include changed'
    }
    $header = $header.Replace('#include <vector>', '#include <map>')
    $old = @'
    /// The guest code [first, last] a block was translated from. Code is invalidated rarely (when
    /// it is unmapped or reprotected), so a list scanned then costs least: an interval map of
    /// block sets held ~300 bytes per block.
    struct Range {
        P first;
        P last;
        IR::LocationDescriptor location;
    };
    std::vector<Range> ranges;
'@
    $new = @'
    /// Guest code ranges indexed by first address. Invalidation walks only entries whose start can
    /// overlap the invalidated interval, bounded backwards by the largest translated span seen.
    struct Range {
        P last;
        IR::LocationDescriptor location;
    };
    std::multimap<P, Range> ranges;
    P max_span{};
'@
    $old = $old.TrimEnd("`r", "`n")
    if (-not $header.Contains($old)) {
        throw 'Build31 frontier: Dynarmic range storage anchor changed'
    }
    Write-PatchedText $rangeHeader ($header.Replace($old, $new.TrimEnd("`r", "`n")))

    $cpp = Get-Content $rangeCpp -Raw
    $oldCpp = @'
template<typename P>
void BlockRangeInformation<P>::AddRange(boost::icl::discrete_interval<P> range, IR::LocationDescriptor location) {
    if (!boost::icl::is_empty(range)) {
        ranges.push_back({boost::icl::first(range), boost::icl::last(range), location});
    }
}

template<typename P>
void BlockRangeInformation<P>::ClearCache() {
    ranges.clear();
}

template<typename P>
::Common::unordered_set<IR::LocationDescriptor> BlockRangeInformation<P>::InvalidateRanges(const boost::icl::interval_set<P>& invalidated) {
    ::Common::unordered_set<IR::LocationDescriptor> erase_locations;
    std::erase_if(ranges, [&](const Range& range) {
        for (const auto& interval : invalidated) {
            if (range.first <= boost::icl::last(interval) && boost::icl::first(interval) <= range.last) {
                erase_locations.insert(range.location);
                return true;
            }
        }
        return false;
    });
    return erase_locations;
}
'@
    $newCpp = @'
template<typename P>
void BlockRangeInformation<P>::AddRange(boost::icl::discrete_interval<P> range, IR::LocationDescriptor location) {
    if (boost::icl::is_empty(range)) {
        return;
    }
    const P first = boost::icl::first(range);
    const P last = boost::icl::last(range);
    ranges.emplace(first, Range{last, location});
    max_span = (std::max)(max_span, P(last - first));
}

template<typename P>
void BlockRangeInformation<P>::ClearCache() {
    ranges.clear();
    max_span = 0;
}

template<typename P>
::Common::unordered_set<IR::LocationDescriptor> BlockRangeInformation<P>::InvalidateRanges(const boost::icl::interval_set<P>& invalidated) {
    ::Common::unordered_set<IR::LocationDescriptor> erase_locations;
    for (const auto& interval : invalidated) {
        const P first = boost::icl::first(interval);
        const P last = boost::icl::last(interval);
        const P search_begin = first > max_span ? P(first - max_span) : P(0);
        auto it = ranges.lower_bound(search_begin);
        while (it != ranges.end() && it->first <= last) {
            if (it->second.last < first) {
                ++it;
                continue;
            }
            erase_locations.insert(it->second.location);
            it = ranges.erase(it);
        }
    }
    return erase_locations;
}
'@
    $oldCpp = $oldCpp.TrimEnd("`r", "`n")
    if (-not $cpp.Contains($oldCpp)) {
        throw 'Build31 frontier: Dynarmic invalidation implementation anchor changed'
    }
    Write-PatchedText $rangeCpp ($cpp.Replace($oldCpp, $newCpp.TrimEnd("`r", "`n")))
    Write-Host '[APPLIED] indexed Dynarmic invalidation ranges'
} else {
    Write-Host '[PRESENT] indexed Dynarmic invalidation ranges'
}

# 3) GPU-written tracking: set up to 64 page bits with one atomic OR per bitmap word rather than one
# atomic operation per 4-KiB page. Large GPU writes and command buffers hit this path frequently.
$nx2 = 'src/video_core/nx2.h'
$nx2Text = Get-Content $nx2 -Raw
if (-not $nx2Text.Contains('word.fetch_or(bits, std::memory_order_relaxed);')) {
    $old = @'
    for (u64 page = device_address >> Nx2WrittenPageBits; page <= last; ++page) {
        auto& word = g_nx2_gpu_written_pages[page / 64];
        const u64 bit = u64{1} << (page % 64);
        if ((word.load(std::memory_order_relaxed) & bit) == 0) {
            word.fetch_or(bit, std::memory_order_relaxed);
        }
    }
'@
    $new = @'
    const u64 first = device_address >> Nx2WrittenPageBits;
    for (u64 index = first / 64; first <= last && index <= last / 64; ++index) {
        const u64 low = index == first / 64 ? first % 64 : 0;
        const u64 high = index == last / 64 ? last % 64 : 63;
        const u64 bits = (~u64{0} >> (63 - high)) & (~u64{0} << low);
        auto& word = g_nx2_gpu_written_pages[index];
        if ((word.load(std::memory_order_relaxed) & bits) != bits) {
            word.fetch_or(bits, std::memory_order_relaxed);
        }
    }
'@
    $old = $old.TrimEnd("`r", "`n")
    if (-not $nx2Text.Contains($old)) {
        throw 'Build31 frontier: GPU-written page bitmap anchor changed'
    }
    Write-PatchedText $nx2 ($nx2Text.Replace($old, $new.TrimEnd("`r", "`n")))
    Write-Host '[APPLIED] batched GPU-written page bitmap updates'
} else {
    Write-Host '[PRESENT] batched GPU-written page bitmap updates'
}

# 4) Async native pipeline path: translation workers should stop after translation/SPIR-V. Queue the
# expensive host-driver pipeline compilation on the normal pipeline workers, preserving our existing
# bounded wait/skip/adopt policy on the GPU thread.
$pipelineCache = 'src/video_core/renderer_vulkan/vk_pipeline_cache.cpp'
$pipeline = Get-Content $pipelineCache -Raw
$parallelCall = 'pipeline = CreateGraphicsPipeline(pools, key, MakeSpan(env_ptrs), nullptr, true);'
if (-not $pipeline.Contains($parallelCall)) {
    $oldCall = 'pipeline = CreateGraphicsPipeline(pools, key, MakeSpan(env_ptrs), nullptr, false);'
    if (-not $pipeline.Contains($oldCall)) {
        throw 'Build31 frontier: async native pipeline driver-compile call changed'
    }
    $pipeline = $pipeline.Replace($oldCall, $parallelCall)
    $pipeline = $pipeline.Replace(
        '// Not built in parallel: the driver compile runs here too, so the pipeline can be drawn' + "`n" +
        '        // with as soon as the GPU thread adopts it.',
        '// Translation workers stop at SPIR-V; native driver compilation is queued on the existing' + "`n" +
        '        // pipeline workers. The first draw may still wait/skip according to the normal scheduler.')
    Write-PatchedText $pipelineCache $pipeline
    Write-Host '[APPLIED] native driver compile handoff to pipeline workers'
} else {
    Write-Host '[PRESENT] native driver compile handoff to pipeline workers'
}

# 5) PrepareDraw sees the same indirect-reset macro program repeatedly. Keep the full map for program
# changes, but make the common same-program path two scalar checks rather than an unordered_map probe.
$rasterizer = 'src/video_core/renderer_vulkan/vk_rasterizer.cpp'
$raster = Get-Content $rasterizer -Raw
if (-not $raster.Contains('static GPUVAddr last_program = ~GPUVAddr{0};')) {
    $old = @'
        static std::unordered_map<GPUVAddr, bool> reset_programs;
        auto [entry, inserted] = reset_programs.try_emplace(program, false);
        if (inserted) {
            std::array<u32, 44> code{};
            const GPUVAddr code_address = program + 128;
            if (gpu_memory->IsFullyMappedRange(code_address, sizeof(code))) {
                gpu_memory->ReadBlockUnsafe(code_address, code.data(), sizeof(code));
                entry->second = code == NX2_INDIRECT_RESET_PROGRAM;
            }
            if (entry->second) {
                LOG_INFO(HW_GPU, "Indirect draw reset program at {:#x}: its stores are done here",
                         program);
            }
        }
        if (entry->second) {
'@
    $new = @'
        static std::unordered_map<GPUVAddr, bool> reset_programs;
        static GPUVAddr last_program = ~GPUVAddr{0};
        static bool last_is_reset = false;
        if (program != last_program) {
            auto [entry, inserted] = reset_programs.try_emplace(program, false);
            if (inserted) {
                std::array<u32, 44> code{};
                const GPUVAddr code_address = program + 128;
                if (gpu_memory->IsFullyMappedRange(code_address, sizeof(code))) {
                    gpu_memory->ReadBlockUnsafe(code_address, code.data(), sizeof(code));
                    entry->second = code == NX2_INDIRECT_RESET_PROGRAM;
                }
                if (entry->second) {
                    LOG_INFO(HW_GPU, "Indirect draw reset program at {:#x}: its stores are done here",
                             program);
                }
            }
            last_program = program;
            last_is_reset = entry->second;
        }
        if (last_is_reset) {
'@
    $old = $old.TrimEnd("`r", "`n")
    if (-not $raster.Contains($old)) {
        throw 'Build31 frontier: indirect-reset program lookup anchor changed'
    }
    Write-PatchedText $rasterizer ($raster.Replace($old, $new.TrimEnd("`r", "`n")))
    Write-Host '[APPLIED] last indirect-reset program fast lookup'
} else {
    Write-Host '[PRESENT] last indirect-reset program fast lookup'
}

git diff --check
if ($LASTEXITCODE -ne 0) {
    throw 'Build31 frontier introduced diff/whitespace errors'
}

Require-Text $deviceMemory '            asid = asid_2;' 'mixed-ASID cache owner update'
Require-Text $rangeHeader 'std::multimap<P, Range> ranges;' 'indexed Dynarmic range container'
Require-Text $rangeHeader 'P max_span{};' 'Dynarmic invalidation overlap bound'
Require-Text $rangeCpp 'auto it = ranges.lower_bound(search_begin);' 'bounded Dynarmic invalidation lookup'
Require-Text $nx2 'word.fetch_or(bits, std::memory_order_relaxed);' 'batched GPU-written bitmap OR'
Require-Text $pipelineCache $parallelCall 'pipeline-worker native driver compilation'
Require-Text $rasterizer 'static GPUVAddr last_program = ~GPUVAddr{0};' 'indirect-reset last-program cache'
Require-Text $rasterizer 'if (last_is_reset) {' 'indirect-reset scalar fast path'

Write-Host 'Zortos build31 safe performance layer applied and validated.'
