$ErrorActionPreference = "Stop"

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

# Eglantine changed this diagnostic from INFO to DEBUG after the original integration.
# Match either spelling so the functional cache patch remains source-version tolerant.
$logInfoNeedle = @'
    LOG_INFO(Shader, "Lowered native shader at {:#x}: {} source bytes, {} instructions",
             program_base, native_source_size, lowered.instructions.size());
'@
$logDebugNeedle = @'
    LOG_DEBUG(Shader, "Lowered native shader at {:#x}: {} source bytes, {} instructions",
             program_base, native_source_size, lowered.instructions.size());
'@
$logReplacement = @'
    if (lowered_from_positive_cache) {
        LOG_DEBUG(Shader, "Reused positive native shader cache at {:#x}: {} source bytes, {} instructions",
                  program_base, native_source_size, lowered.instructions.size());
    } else {
        LOG_DEBUG(Shader, "Lowered native shader at {:#x}: {} source bytes, {} instructions",
                  program_base, native_source_size, lowered.instructions.size());
    }
'@
$matchedLog = $null
foreach ($candidate in @($logInfoNeedle, $logDebugNeedle)) {
    $candidate = $candidate.TrimEnd("`r", "`n")
    if ($text.Contains($candidate)) {
        $matchedLog = $candidate
        break
    }
}
if (-not $matchedLog) {
    throw "Could not locate native shader lowering log"
}
$text = $text.Replace($matchedLog, $logReplacement.TrimEnd("`r", "`n"))

Set-Content -Path $path -Value $text -Encoding utf8 -NoNewline
Write-Host "Enabled collision-safe positive native shader lowering cache."
git diff -- src/video_core/shader_environment.cpp