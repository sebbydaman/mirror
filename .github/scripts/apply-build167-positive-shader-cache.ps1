$ErrorActionPreference = 'Stop'

# Build167 already contains the full native-lowering reuse and the correctness/performance changes
# that the older production tree imported from PokeDinner 2.0. Do not replay those older commits
# over the newer source. Add only our collision-safe in-process positive lowering cache here.
$path = 'src/video_core/shader_environment.cpp'
if (-not (Test-Path $path -PathType Leaf)) { throw "Missing build167 shader environment: $path" }
$text = (Get-Content $path -Raw).Replace("`r`n", "`n")

# Fail closed unless the build167 native-reuse prerequisite is genuinely present.
$header = (Get-Content 'src/video_core/shader_environment.h' -Raw).Replace("`r`n", "`n")
foreach ($needle in @(
    'struct LoweredNativeCode {',
    'LoweredNative() const noexcept',
    'std::shared_ptr<const LoweredNativeCode> lowered_native;',
    'std::shared_ptr<const LoweredNativeCode> lowered_native_ = {}'
)) {
    if (-not $header.Contains($needle)) {
        throw "Build167 native-reuse prerequisite missing: $needle"
    }
}

$shaderCacheHeader = (Get-Content 'src/video_core/shader_cache.h' -Raw).Replace("`r`n", "`n")
if (-not $shaderCacheHeader.Contains('std::shared_ptr<const LoweredNativeCode> lowered_native;')) {
    throw 'Build167 ShaderInfo native-lowering reuse is missing'
}

if ($text.Contains('build167_native_shader_positive_cache_mutex')) {
    Write-Host '[PRESENT] build167 collision-safe positive native shader cache'
    exit 0
}

if (-not $text.Contains('#include <mutex>')) {
    $needle = '#include <memory>'
    if (-not $text.Contains($needle)) { throw 'Could not locate build167 cache include insertion point' }
    $text = $text.Replace($needle, "#include <memory>`n#include <mutex>")
}
if (-not $text.Contains('#include <unordered_map>')) {
    $needle = '#include <utility>'
    if (-not $text.Contains($needle)) { throw 'Could not locate build167 unordered_map include insertion point' }
    $text = $text.Replace($needle, "#include <unordered_map>`n$needle")
}

$namespaceNeedle = "namespace VideoCommon {`n`nconstexpr std::array<char, 8> MAGIC_NUMBER"
if (-not $text.Contains($namespaceNeedle)) {
    throw 'Could not locate VideoCommon insertion point for build167 positive cache'
}

$cacheBlock = @'
namespace VideoCommon {

namespace {

constexpr size_t Build167NativeShaderPositiveCacheMaxEntries = 4096;

struct Build167NativeShaderPositiveCacheEntry {
    std::vector<Shader::Ampere::Instruction> source;
    Shader::Ampere::LoweredProgram lowered;
};

std::mutex build167_native_shader_positive_cache_mutex;
std::unordered_map<u64, std::vector<Build167NativeShaderPositiveCacheEntry>>
    build167_native_shader_positive_cache;
size_t build167_native_shader_positive_cache_entries{};

u64 Build167NativeShaderKey(std::span<const Shader::Ampere::Instruction> source) {
    return Common::CityHash64(reinterpret_cast<const char*>(source.data()), source.size_bytes());
}

bool SameBuild167NativeShader(std::span<const Shader::Ampere::Instruction> source,
                              const Build167NativeShaderPositiveCacheEntry& entry) {
    if (source.size() != entry.source.size()) {
        return false;
    }
    return std::equal(source.begin(), source.end(), entry.source.begin(), entry.source.end(),
                      [](const auto& lhs, const auto& rhs) { return lhs.words == rhs.words; });
}

std::optional<Shader::Ampere::LoweredProgram> FindBuild167PositiveNativeShaderCache(
    std::span<const Shader::Ampere::Instruction> source) {
    const u64 key = Build167NativeShaderKey(source);
    std::scoped_lock lock{build167_native_shader_positive_cache_mutex};
    const auto it = build167_native_shader_positive_cache.find(key);
    if (it == build167_native_shader_positive_cache.end()) {
        return std::nullopt;
    }
    for (const auto& entry : it->second) {
        if (SameBuild167NativeShader(source, entry)) {
            return entry.lowered;
        }
    }
    return std::nullopt;
}

void StoreBuild167PositiveNativeShaderCache(std::span<const Shader::Ampere::Instruction> source,
                                             const Shader::Ampere::LoweredProgram& lowered) {
    if (!lowered) {
        return;
    }
    const u64 key = Build167NativeShaderKey(source);
    std::scoped_lock lock{build167_native_shader_positive_cache_mutex};
    auto& bucket = build167_native_shader_positive_cache[key];
    for (auto& entry : bucket) {
        if (SameBuild167NativeShader(source, entry)) {
            entry.lowered = lowered;
            return;
        }
    }
    if (build167_native_shader_positive_cache_entries >=
        Build167NativeShaderPositiveCacheMaxEntries) {
        build167_native_shader_positive_cache.clear();
        build167_native_shader_positive_cache_entries = 0;
    }
    build167_native_shader_positive_cache[key].push_back(Build167NativeShaderPositiveCacheEntry{
        std::vector<Shader::Ampere::Instruction>{source.begin(), source.end()}, lowered});
    ++build167_native_shader_positive_cache_entries;
}

} // namespace

constexpr std::array<char, 8> MAGIC_NUMBER
'@
$text = $text.Replace($namespaceNeedle, $cacheBlock.TrimEnd("`r", "`n"))

$lowerNeedle = '    auto lowered = Shader::Ampere::LowerToMaxwell(native);'
if (-not $text.Contains($lowerNeedle)) {
    throw 'Could not locate build167 native lowering call for positive cache'
}
$lowerReplacement = @'
    auto cached_lowered = FindBuild167PositiveNativeShaderCache(native);
    auto lowered = cached_lowered ? std::move(*cached_lowered)
                                  : Shader::Ampere::LowerToMaxwell(native);
    if (!cached_lowered && lowered) {
        StoreBuild167PositiveNativeShaderCache(native, lowered);
    }
'@
$text = $text.Replace($lowerNeedle, $lowerReplacement.TrimEnd("`r", "`n"))

[IO.File]::WriteAllText((Resolve-Path $path), $text, [Text.UTF8Encoding]::new($false))

git diff --check
if ($LASTEXITCODE -ne 0) { throw 'Build167 positive cache introduced whitespace errors' }

$check = Get-Content $path -Raw
foreach ($needle in @(
    'build167_native_shader_positive_cache_mutex',
    'Build167NativeShaderKey',
    'FindBuild167PositiveNativeShaderCache(native)',
    'StoreBuild167PositiveNativeShaderCache(native, lowered)'
)) {
    if (-not $check.Contains($needle)) { throw "Build167 positive-cache invariant missing: $needle" }
}
Write-Host 'Build167 collision-safe positive native shader cache applied and validated.'
