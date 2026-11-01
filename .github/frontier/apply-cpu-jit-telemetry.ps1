$ErrorActionPreference = 'Stop'

$path = 'src/dynarmic/src/dynarmic/backend/x64/a64_interface.cpp'
if (-not (Test-Path $path -PathType Leaf)) {
    throw "CPU JIT telemetry source is missing: $path"
}

$text = Get-Content $path -Raw
if ($text.Contains('[NX2 JIT] compile profile:')) {
    Write-Host '[PRESENT] NX2 CPU JIT duplicate-compilation telemetry'
    exit 0
}

$includeAnchor = '#include <cstring>'
if (-not $text.Contains($includeAnchor)) {
    throw 'CPU JIT telemetry: include anchor changed'
}
$extraIncludes = @'
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <unordered_map>
'@
$text = $text.Replace($includeAnchor, $includeAnchor + "`n" + $extraIncludes.TrimEnd("`r", "`n"))

$namespaceAnchor = 'namespace Dynarmic::A64 {'
if (-not $text.Contains($namespaceAnchor)) {
    throw 'CPU JIT telemetry: Dynarmic A64 namespace anchor changed'
}
$tracker = @'
namespace {

struct Nx2JitCompileTracker {
    std::mutex mutex;
    std::unordered_map<std::uint64_t, std::uint64_t> cores_by_location;
    std::array<std::uint64_t, 64> per_core{};
    std::uint64_t total{};
    std::uint64_t unique{};
    std::uint64_t cross_core_duplicates{};
    std::uint64_t same_core_recompiles{};
};

Nx2JitCompileTracker& Nx2JitTracker() {
    static auto* tracker = new Nx2JitCompileTracker{};
    return *tracker;
}

bool Nx2JitProfileEnabled() {
    static const bool enabled = [] {
        const char* value = std::getenv("EDEN_NX2_CPU_JIT_PROFILE");
        return value != nullptr && value[0] != '0';
    }();
    return enabled;
}

void ReportNx2JitCompileProfile() {
    if (!Nx2JitProfileEnabled()) {
        return;
    }
    auto& tracker = Nx2JitTracker();
    std::scoped_lock lock{tracker.mutex};
    const double total = static_cast<double>(tracker.total);
    const double cross_core_pct = total != 0.0 ? (100.0 * static_cast<double>(tracker.cross_core_duplicates) / total) : 0.0;
    const double same_core_pct = total != 0.0 ? (100.0 * static_cast<double>(tracker.same_core_recompiles) / total) : 0.0;
    const double duplicate_pct = cross_core_pct + same_core_pct;
    std::fprintf(stderr,
                 "[NX2 JIT] compile profile: total=%llu unique=%llu cross_core_duplicates=%llu same_core_recompiles=%llu\n",
                 static_cast<unsigned long long>(tracker.total),
                 static_cast<unsigned long long>(tracker.unique),
                 static_cast<unsigned long long>(tracker.cross_core_duplicates),
                 static_cast<unsigned long long>(tracker.same_core_recompiles));
    std::fprintf(stderr,
                 "[NX2 JIT] compile ratios: cross_core_pct=%.2f same_core_pct=%.2f duplicate_pct=%.2f\n",
                 cross_core_pct, same_core_pct, duplicate_pct);
    for (std::size_t core = 0; core < tracker.per_core.size(); ++core) {
        if (tracker.per_core[core] != 0) {
            std::fprintf(stderr, "[NX2 JIT] core %zu compilations=%llu\n", core,
                         static_cast<unsigned long long>(tracker.per_core[core]));
        }
    }
}

void RecordNx2JitCompile(std::uint64_t location, std::uint8_t processor_id) {
    if (!Nx2JitProfileEnabled()) {
        return;
    }
    static const bool registered = [] {
        std::atexit(ReportNx2JitCompileProfile);
        return true;
    }();
    (void)registered;

    auto& tracker = Nx2JitTracker();
    std::scoped_lock lock{tracker.mutex};
    const std::uint64_t core_bit = processor_id < 64 ? (std::uint64_t{1} << processor_id) : 0;
    auto [it, inserted] = tracker.cores_by_location.try_emplace(location, 0);
    if (inserted) {
        ++tracker.unique;
    } else if (core_bit != 0 && (it->second & core_bit) == 0) {
        ++tracker.cross_core_duplicates;
    } else {
        ++tracker.same_core_recompiles;
    }
    if (core_bit != 0) {
        it->second |= core_bit;
        ++tracker.per_core[processor_id];
    }
    ++tracker.total;

    if ((tracker.total % 100000) == 0) {
        std::fprintf(stderr,
                     "[NX2 JIT] compile profile: total=%llu unique=%llu cross_core_duplicates=%llu same_core_recompiles=%llu\n",
                     static_cast<unsigned long long>(tracker.total),
                     static_cast<unsigned long long>(tracker.unique),
                     static_cast<unsigned long long>(tracker.cross_core_duplicates),
                     static_cast<unsigned long long>(tracker.same_core_recompiles));
    }
}

} // namespace

'@
$text = $text.Replace($namespaceAnchor, $tracker + $namespaceAnchor)

$compileAnchor = @'
        // JIT Compile
        const auto get_code = [this](u64 vaddr) { return conf.callbacks->MemoryReadCode(vaddr); };
'@
$compileAnchor = $compileAnchor.TrimEnd("`r", "`n")
if (-not $text.Contains($compileAnchor)) {
    throw 'CPU JIT telemetry: JIT compile anchor changed'
}
$compileReplacement = @'
        // JIT Compile
        RecordNx2JitCompile(descriptor.Value(), conf.processor_id);
        const auto get_code = [this](u64 vaddr) { return conf.callbacks->MemoryReadCode(vaddr); };
'@
$text = $text.Replace($compileAnchor, $compileReplacement.TrimEnd("`r", "`n"))

$normalized = $text.TrimEnd("`r", "`n") + "`n"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText((Resolve-Path $path).Path, $normalized, $utf8NoBom)

$check = Get-Content $path -Raw
foreach ($required in @(
    'EDEN_NX2_CPU_JIT_PROFILE',
    'RecordNx2JitCompile(descriptor.Value(), conf.processor_id);',
    '[NX2 JIT] compile profile:',
    '[NX2 JIT] compile ratios:',
    'cross_core_duplicates',
    'same_core_recompiles',
    'duplicate_pct'
)) {
    if (-not $check.Contains($required)) {
        throw "CPU JIT telemetry marker missing: $required"
    }
}

git diff --check
if ($LASTEXITCODE -ne 0) {
    throw 'CPU JIT telemetry patch introduced diff errors'
}

Write-Host '[APPLIED] NX2 CPU JIT duplicate-compilation telemetry'
