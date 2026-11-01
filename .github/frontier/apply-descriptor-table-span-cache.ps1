$ErrorActionPreference = 'Stop'

$path = 'src/video_core/texture_cache/descriptor_table.h'
if (-not (Test-Path $path -PathType Leaf)) {
    throw "Descriptor span cache: missing $path"
}

$text = (Get-Content $path -Raw).Replace("`r", "")
if ($text.Contains('EDEN_NX2_DESCRIPTOR_SPAN')) {
    Write-Host '[PRESENT] descriptor-table mapping-generation span cache already installed'
    exit 0
}

$includeAnchor = '#include <algorithm>'
if (-not $text.Contains($includeAnchor)) {
    throw 'Descriptor span cache: include anchor missing'
}
$text = $text.Replace($includeAnchor, "#include <algorithm>`n#include <cstdlib>`n#include <cstring>")

$readStartMarker = '    [[nodiscard]] std::pair<T, bool> Read(Tegra::MemoryManager const& gpu_memory, u32 index) noexcept {'
$readEndMarker = '    void Refresh(GPUVAddr gpu_addr, u32 limit) noexcept {'
$readStart = $text.IndexOf($readStartMarker, [StringComparison]::Ordinal)
$readEnd = $text.IndexOf($readEndMarker, $readStart, [StringComparison]::Ordinal)
if ($readStart -lt 0 -or $readEnd -lt 0 -or $readEnd -le $readStart) {
    throw 'Descriptor span cache: Read/Refresh structural anchors missing'
}

$newRead = @'
    [[nodiscard]] std::pair<T, bool> Read(Tegra::MemoryManager const& gpu_memory, u32 index) noexcept {
        DEBUG_ASSERT(index <= current_limit);
        const GPUVAddr gpu_addr = current_gpu_addr + index * sizeof(T);
        std::pair<T, bool> result;

        // Descriptor contents are still reread every time. Only a small translated host span is
        // cached, and only inside one stable even GMMU mapping generation. Keeping the window to
        // 64 descriptors avoids scanning a huge mostly-unused descriptor table just to establish
        // the cache, while sequential descriptor reads still amortize the page-table walk.
        static const bool span_cache_enabled = [] {
            const char* value = std::getenv("EDEN_NX2_DESCRIPTOR_SPAN");
            return value == nullptr || *value != '0';
        }();
        const u64 mapping_generation =
            span_cache_enabled ? gpu_memory.MappingGeneration() : ~u64{0};
        const bool mapping_stable = span_cache_enabled && (mapping_generation & 1) == 0;
        const bool window_matches =
            cached_mapping_generation == mapping_generation &&
            gpu_addr >= cached_span_gpu_addr &&
            gpu_addr + sizeof(T) <= cached_span_gpu_addr + cached_span_size;

        if (mapping_stable && !window_matches) {
            constexpr size_t DescriptorsPerSpan = 64;
            const size_t first_index =
                static_cast<size_t>(index) & ~(DescriptorsPerSpan - 1);
            const size_t descriptor_count = static_cast<size_t>(current_limit) + 1;
            const size_t span_count =
                (std::min)(DescriptorsPerSpan, descriptor_count - first_index);
            const GPUVAddr span_gpu_addr = current_gpu_addr + first_index * sizeof(T);
            const size_t span_size = span_count * sizeof(T);
            const u8* span = gpu_memory.GetSpan(span_gpu_addr, span_size);
            const u64 after_translation = gpu_memory.MappingGeneration();
            if (after_translation == mapping_generation) {
                // Cache the window metadata even when GetSpan returns null. That makes a failed
                // contiguous-span test a once-per-window/per-generation cost while every read in
                // that window safely falls back to the original ReadBlockUnsafe path.
                cached_span = span;
                cached_span_gpu_addr = span_gpu_addr;
                cached_span_size = span_size;
                cached_mapping_generation = mapping_generation;
            } else {
                cached_span = nullptr;
                cached_span_gpu_addr = 0;
                cached_span_size = 0;
                cached_mapping_generation = ~u64{0};
            }
        }

        const bool use_cached_span =
            mapping_stable && cached_span != nullptr &&
            cached_mapping_generation == mapping_generation &&
            gpu_addr >= cached_span_gpu_addr &&
            gpu_addr + sizeof(T) <= cached_span_gpu_addr + cached_span_size;
        if (use_cached_span) {
            const size_t offset = static_cast<size_t>(gpu_addr - cached_span_gpu_addr);
            std::memcpy(std::addressof(result.first), cached_span + offset, sizeof(T));
        } else {
            gpu_memory.ReadBlockUnsafe(gpu_addr, std::addressof(result.first), sizeof(T));
        }

        if ((read_descriptors[index / 64] & (1ULL << (index % 64))) != 0) {
            result.second = result.first != descriptors[index];
        } else {
            read_descriptors[index / 64] |= 1ULL << (index % 64);
            result.second = true;
        }
        if (result.second) {
            descriptors[index] = result.first;
        }
        return result;
    }

'@
$text = $text.Substring(0, $readStart) + $newRead + $text.Substring($readEnd)

$refreshNeedle = "        current_gpu_addr = gpu_addr;`n        current_limit = limit;"
if (-not $text.Contains($refreshNeedle)) {
    throw 'Descriptor span cache: Refresh state anchor missing'
}
$text = $text.Replace(
    $refreshNeedle,
    $refreshNeedle + "`n        cached_span = nullptr;`n        cached_span_gpu_addr = 0;`n" +
    "        cached_span_size = 0;`n        cached_mapping_generation = ~u64{0};")

$memberNeedle = "    GPUVAddr current_gpu_addr{};`n    u32 current_limit{};"
if (-not $text.Contains($memberNeedle)) {
    throw 'Descriptor span cache: member anchor missing'
}
$text = $text.Replace(
    $memberNeedle,
    $memberNeedle + "`n    const u8* cached_span{};`n    GPUVAddr cached_span_gpu_addr{};`n" +
    "    size_t cached_span_size{};`n    u64 cached_mapping_generation{~u64{0}};")

[IO.File]::WriteAllText((Resolve-Path $path).Path, $text.TrimEnd("`r", "`n") + "`n",
    [Text.UTF8Encoding]::new($false))

& git diff --check
if ($LASTEXITCODE -ne 0) {
    throw 'Descriptor span cache introduced diff/whitespace errors'
}

$verify = Get-Content $path -Raw
foreach ($needle in @('EDEN_NX2_DESCRIPTOR_SPAN', 'DescriptorsPerSpan = 64',
                      'cached_mapping_generation', 'gpu_memory.GetSpan(span_gpu_addr, span_size)',
                      'std::memcpy(std::addressof(result.first)', 'const bool window_matches')) {
    if (-not $verify.Contains($needle)) {
        throw "Descriptor span cache verification failed: missing $needle"
    }
}

Write-Host '[APPLIED] 64-descriptor host-span translation cache guarded by GMMU mapping generation'
Write-Host '[INFO] Descriptor contents are still reread every configure; failed spans are memoized per window/generation; EDEN_NX2_DESCRIPTOR_SPAN=0 disables the translation cache for A/B testing.'
