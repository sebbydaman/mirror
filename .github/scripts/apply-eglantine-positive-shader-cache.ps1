$ErrorActionPreference = "Stop"

# The earlier integration step intentionally edits the detached Eglantine worktree in place.
# PokeDinner is applied with cherry-pick --no-commit, so give Git a clean CI-only checkpoint
# first. This checkpoint exists only inside the ephemeral Actions checkout; it prevents Git from
# rejecting the donor batch just because our already-validated local integration is dirty.
if (git status --porcelain) {
    git add -A
    git -c user.name="Eden NS2 CI" -c user.email="actions@github.com" commit -m "CI checkpoint before PokeDinner 2.0 batch" --no-verify
    if ($LASTEXITCODE -ne 0) { throw "Could not checkpoint local NS2 integration before PokeDinner batch" }
}

# Apply the curated PokeDinner 2.0 correctness/performance batch as one CI unit before
# the local positive shader cache. This deliberately batches many source-proven donor
# improvements into the same long Windows build.
$pokedinnerV2Script = Join-Path $PSScriptRoot "apply-pokedinner-v2-batch.ps1"
& $pokedinnerV2Script

# PokeDinner's async-translation/reuse commits assume bebdff8c ("lower each native program once"),
# which predates the curated 31-commit batch. Eglantine 01effa does not have that prerequisite.
# The later c404 conflict resolution already restores the donor's LoweredNativeCode environment
# machinery, so layer the remaining cache/pipeline pieces here instead of cherry-picking the old
# commit wholesale over our geometry-stage edits.
function Read-NativeReuseFile([string]$Path) {
    if (-not (Test-Path $Path)) { throw "Missing PokeDinner native-reuse prerequisite file: $Path" }
    return (Get-Content $Path -Raw).Replace("`r`n", "`n")
}
function Write-NativeReuseFile([string]$Path, [string]$Text) {
    Set-Content -Path $Path -Value $Text -Encoding utf8 -NoNewline
}

$environmentHeaderPath = 'src/video_core/shader_environment.h'
$environmentHeader = Read-NativeReuseFile $environmentHeaderPath
foreach ($needle in @(
    'struct LoweredNativeCode {',
    'LoweredNative() const noexcept',
    'std::shared_ptr<const LoweredNativeCode> lowered_native;',
    'std::shared_ptr<const LoweredNativeCode> lowered_native_ = {}'
)) {
    if (-not $environmentHeader.Contains($needle)) {
        throw "PokeDinner native-reuse prerequisite missing environment support: $needle"
    }
}

$shaderCacheHeaderPath = 'src/video_core/shader_cache.h'
$shaderCacheHeader = Read-NativeReuseFile $shaderCacheHeaderPath
if (-not $shaderCacheHeader.Contains('std::shared_ptr<const LoweredNativeCode> lowered_native;')) {
    # 6d8f95 moves device_memory visibility and can alter surrounding formatting. Anchor only
    # inside ShaderInfo itself instead of requiring the entire struct to match byte-for-byte.
    $shaderInfoStart = $shaderCacheHeader.IndexOf('struct ShaderInfo {')
    if ($shaderInfoStart -lt 0) {
        throw 'Could not locate ShaderInfo start for PokeDinner native-lowering reuse prerequisite'
    }
    $shaderInfoEnd = $shaderCacheHeader.IndexOf('};', $shaderInfoStart)
    if ($shaderInfoEnd -lt 0) {
        throw 'Could not locate ShaderInfo end for PokeDinner native-lowering reuse prerequisite'
    }
    $sizeMarker = '    size_t size_bytes{};'
    $sizeAt = $shaderCacheHeader.IndexOf($sizeMarker, $shaderInfoStart)
    if ($sizeAt -lt 0 -or $sizeAt -gt $shaderInfoEnd) {
        throw 'Could not locate ShaderInfo size_bytes member for PokeDinner native-lowering reuse prerequisite'
    }
    $insertAt = $sizeAt + $sizeMarker.Length
    $field = @'

    /// Lowered code of a native program, reused when its pipelines are built.
    std::shared_ptr<const LoweredNativeCode> lowered_native;
'@
    $shaderCacheHeader = $shaderCacheHeader.Substring(0, $insertAt) +
                         $field.TrimEnd("`r", "`n") +
                         $shaderCacheHeader.Substring($insertAt)
    Write-NativeReuseFile $shaderCacheHeaderPath $shaderCacheHeader
}

$shaderCachePath = 'src/video_core/shader_cache.cpp'
$shaderCache = Read-NativeReuseFile $shaderCachePath
if (-not $shaderCache.Contains('shader_infos[index]->lowered_native')) {
    $old = '        env = GraphicsEnvironment{*maxwell3d, *gpu_memory, program, address, start_address};'
    $new = @'
        env = GraphicsEnvironment{*maxwell3d, *gpu_memory, program, address, start_address,
                                  shader_infos[index]->lowered_native};
'@
    $new = $new.TrimEnd("`r", "`n")
    if (-not $shaderCache.Contains($old)) {
        throw 'Could not locate graphics environment construction for PokeDinner native reuse'
    }
    $shaderCache = $shaderCache.Replace($old, $new)
}
if (-not $shaderCache.Contains('info->lowered_native = env.LoweredNative();')) {
    $old = '    const size_t size_bytes{env.SourceSizeBytes() ? env.SourceSizeBytes() : info->size_bytes};'
    $new = "    info->lowered_native = env.LoweredNative();`n$old"
    if (-not $shaderCache.Contains($old)) {
        throw 'Could not locate ShaderInfo finalization for PokeDinner native reuse'
    }
    $shaderCache = $shaderCache.Replace($old, $new)
}
Write-NativeReuseFile $shaderCachePath $shaderCache

$vkPath = 'src/video_core/renderer_vulkan/vk_pipeline_cache.cpp'
$vk = Read-NativeReuseFile $vkPath
if (-not $vk.Contains('shader->lowered_native};')) {
    $old = '    ComputeEnvironment env{*kepler_compute, *gpu_memory, program_base, qmd.program_start};'
    $new = @'
    ComputeEnvironment env{*kepler_compute, *gpu_memory, program_base, qmd.program_start,
                           shader->lowered_native};
'@
    $new = $new.TrimEnd("`r", "`n")
    if (-not $vk.Contains($old)) {
        throw 'Could not locate Vulkan compute environment for PokeDinner native reuse'
    }
    $vk = $vk.Replace($old, $new)
    Write-NativeReuseFile $vkPath $vk
}

$glPath = 'src/video_core/renderer_opengl/gl_shader_cache.cpp'
$gl = Read-NativeReuseFile $glPath
if (-not $gl.Contains('shader->lowered_native};')) {
    $old = '    ComputeEnvironment env{*kepler_compute, *gpu_memory, program_base, qmd.program_start};'
    $new = @'
    ComputeEnvironment env{*kepler_compute, *gpu_memory, program_base, qmd.program_start,
                           shader->lowered_native};
'@
    $new = $new.TrimEnd("`r", "`n")
    if (-not $gl.Contains($old)) {
        throw 'Could not locate OpenGL compute environment for PokeDinner native reuse'
    }
    $gl = $gl.Replace($old, $new)
    Write-NativeReuseFile $glPath $gl
}

$reuseChecks = @(
    @($shaderCacheHeaderPath, 'std::shared_ptr<const LoweredNativeCode> lowered_native;'),
    @($shaderCachePath, 'shader_infos[index]->lowered_native'),
    @($shaderCachePath, 'info->lowered_native = env.LoweredNative();'),
    @($vkPath, 'shader->lowered_native};'),
    @($glPath, 'shader->lowered_native};')
)
foreach ($check in $reuseChecks) {
    if (-not (Read-NativeReuseFile $check[0]).Contains($check[1])) {
        throw "PokeDinner native-lowering reuse regression: missing $($check[1]) in $($check[0])"
    }
}
Write-Host 'Restored PokeDinner pre-batch native-lowering reuse prerequisite (bebdff8c semantics).'

$path = "src/video_core/shader_environment.cpp"
$text = Get-Content $path -Raw

if ($text.Contains('native_shader_positive_cache_mutex')) {
    Write-Host "Positive native shader cache already present."
    exit 0
}

if (-not $text.Contains('#include <mutex>')) {
    $needle = '#include <memory>'
    if (-not $text.Contains($needle)) { throw "Could not locate shader_environment include insertion point" }
    $text = $text.Replace($needle, "#include <memory>`n#include <mutex>`n#include <unordered_map>")
} elseif (-not $text.Contains('#include <unordered_map>')) {
    $needle = '#include <mutex>'
    $text = $text.Replace($needle, "#include <mutex>`n#include <unordered_map>")
}

$namespaceNeedle = "namespace VideoCommon {`n`nconstexpr std::array<char, 8> MAGIC_NUMBER"
if (-not $text.Contains($namespaceNeedle)) {
    $namespaceNeedle = "namespace VideoCommon {`r`n`r`nconstexpr std::array<char, 8> MAGIC_NUMBER"
}
if (-not $text.Contains($namespaceNeedle)) { throw "Could not locate VideoCommon cache insertion point" }

$cacheBlock = @'
namespace VideoCommon {

namespace {

constexpr size_t NativeShaderPositiveCacheMaxEntries = 4096;

struct NativeShaderPositiveCacheEntry {
    std::vector<Shader::Ampere::Instruction> source;
    Shader::Ampere::LoweredProgram lowered;
};

std::mutex native_shader_positive_cache_mutex;
std::unordered_map<u64, std::vector<NativeShaderPositiveCacheEntry>> native_shader_positive_cache;
size_t native_shader_positive_cache_entries{};

bool SameNativeShader(std::span<const Shader::Ampere::Instruction> source,
                      const NativeShaderPositiveCacheEntry& entry) {
    if (source.size() != entry.source.size()) {
        return false;
    }
    return std::equal(source.begin(), source.end(), entry.source.begin(), entry.source.end(),
                      [](const auto& lhs, const auto& rhs) { return lhs.words == rhs.words; });
}

std::optional<Shader::Ampere::LoweredProgram> FindPositiveNativeShaderCache(
    std::span<const Shader::Ampere::Instruction> source) {
    const u64 key = Shader::Ampere::NativeProgramKey(source);
    std::scoped_lock lock{native_shader_positive_cache_mutex};
    const auto it = native_shader_positive_cache.find(key);
    if (it == native_shader_positive_cache.end()) {
        return std::nullopt;
    }
    for (const auto& entry : it->second) {
        if (SameNativeShader(source, entry)) {
            return entry.lowered;
        }
    }
    return std::nullopt;
}

void StorePositiveNativeShaderCache(std::span<const Shader::Ampere::Instruction> source,
                                    const Shader::Ampere::LoweredProgram& lowered) {
    if (!lowered) {
        return;
    }
    const u64 key = Shader::Ampere::NativeProgramKey(source);
    std::scoped_lock lock{native_shader_positive_cache_mutex};
    auto& bucket = native_shader_positive_cache[key];
    for (auto& entry : bucket) {
        if (SameNativeShader(source, entry)) {
            entry.lowered = lowered;
            return;
        }
    }
    if (native_shader_positive_cache_entries >= NativeShaderPositiveCacheMaxEntries) {
        native_shader_positive_cache.clear();
        native_shader_positive_cache_entries = 0;
    }
    native_shader_positive_cache[key].push_back(
        NativeShaderPositiveCacheEntry{std::vector<Shader::Ampere::Instruction>{source.begin(), source.end()}, lowered});
    ++native_shader_positive_cache_entries;
}

} // namespace

constexpr std::array<char, 8> MAGIC_NUMBER
'@
$text = $text.Replace($namespaceNeedle, $cacheBlock.TrimEnd("`r", "`n"))

# PokeDinner 2.0 still lowers through this exact call inside LowerNativeCode(), beneath its
# detached-environment / async-translation / shared-module pipeline. Cache the lowering result
# here without interfering with those higher-level reuse layers.
$lowerNeedle = '    auto lowered = Shader::Ampere::LowerToMaxwell(native);'
if (-not $text.Contains($lowerNeedle)) { throw "Could not locate native lowering call" }
$lowerReplacement = @'
    auto cached_lowered = FindPositiveNativeShaderCache(native);
    auto lowered = cached_lowered ? std::move(*cached_lowered)
                                  : Shader::Ampere::LowerToMaxwell(native);
    const bool lowered_from_positive_cache = cached_lowered.has_value();
    if (!lowered_from_positive_cache && lowered) {
        StorePositiveNativeShaderCache(native, lowered);
    }
'@
$text = $text.Replace($lowerNeedle, $lowerReplacement.TrimEnd("`r", "`n"))

# The diagnostic around LowerNativeCode has changed across Eglantine/PokeDinner revisions.
# It is observability only, not part of the cache semantics. Upgrade a known legacy diagnostic
# when present, but never reject a valid newer source tree merely because its log now reports
# result->source_size or otherwise changed wording.
$legacyLogs = @(
@'
    LOG_INFO(Shader, "Lowered native shader at {:#x}: {} source bytes, {} instructions",
             program_base, native_source_size, lowered.instructions.size());
'@,
@'
    LOG_DEBUG(Shader, "Lowered native shader at {:#x}: {} source bytes, {} instructions",
             program_base, native_source_size, lowered.instructions.size());
'@
)
$legacyLogReplacement = @'
    if (lowered_from_positive_cache) {
        LOG_DEBUG(Shader, "Reused positive native shader cache at {:#x}: {} source bytes, {} instructions",
                  program_base, native_source_size, lowered.instructions.size());
    } else {
        LOG_DEBUG(Shader, "Lowered native shader at {:#x}: {} source bytes, {} instructions",
                  program_base, native_source_size, lowered.instructions.size());
    }
'@
$diagnosticUpgraded = $false
foreach ($candidate in $legacyLogs) {
    $candidate = $candidate.TrimEnd("`r", "`n")
    if ($text.Contains($candidate)) {
        $text = $text.Replace($candidate, $legacyLogReplacement.TrimEnd("`r", "`n"))
        $diagnosticUpgraded = $true
        break
    }
}
if (-not $diagnosticUpgraded) {
    Write-Host "Native lowering diagnostic uses newer PokeDinner form; leaving observability text unchanged."
}

Set-Content -Path $path -Value $text -Encoding utf8 -NoNewline
Write-Host "Enabled collision-safe positive native shader lowering cache."
git diff -- src/video_core/shader_environment.cpp src/video_core/shader_cache.h src/video_core/shader_cache.cpp src/video_core/renderer_vulkan/vk_pipeline_cache.cpp src/video_core/renderer_opengl/gl_shader_cache.cpp
