$ErrorActionPreference = 'Stop'

$path = 'src/core/loader/deconstructed_rom_directory.cpp'
if (-not (Test-Path $path -PathType Leaf)) {
    throw "Loose RomFS memoization: missing $path"
}

$text = (Get-Content $path -Raw).Replace("`r`n", "`n")

if ($text.Contains('Reusing cached loose RomFS')) {
    Write-Host '[PRESENT] loose RomFS memoization already applied'
    exit 0
}

$includeAnchor = "#include <cstring>`n#include <string_view>"
$includeReplacement = "#include <cstring>`n#include <mutex>`n#include <string_view>`n#include <unordered_map>"
if (-not $text.Contains($includeAnchor)) {
    throw 'Loose RomFS memoization: include anchor missing'
}
$text = $text.Replace($includeAnchor, $includeReplacement)

$loaderMarker = 'LOG_INFO(Loader, "Using RomFS directory next to the ExeFS");'
if (-not $text.Contains($loaderMarker)) {
    throw 'Loose RomFS memoization: loose-directory loader marker missing'
}

$createPattern = '(?m)^(?<indent>[ \t]*)return FileSys::CreateRomFS\(romfs_dir\);[ \t]*$'
$matches = [regex]::Matches($text, $createPattern)
if ($matches.Count -ne 1) {
    throw "Loose RomFS memoization: expected exactly one CreateRomFS return, found $($matches.Count)"
}

$indent = $matches[0].Groups['indent'].Value
$replacementLines = @(
    '// Building a RomFS from a loose directory recursively walks the extracted title and is',
    '// expensive for large NS2 dumps. Frontend probing constructs this loader more than once',
    '// before the real boot, so retain the immutable base RomFS per source path and let each',
    '// loader apply its own LayeredFS wrapper afterward.',
    'static std::mutex cache_mutex;',
    'static std::unordered_map<std::string, FileSys::VirtualFile> cache;',
    'const std::string cache_key = romfs_dir->GetFullPath();',
    'std::scoped_lock lock{cache_mutex};',
    'if (const auto it = cache.find(cache_key); it != cache.end()) {',
    '    LOG_INFO(Loader, "Reusing cached loose RomFS for {}", cache_key);',
    '    return it->second;',
    '}',
    'LOG_INFO(Loader, "Building loose RomFS once for {}", cache_key);',
    'auto packed = FileSys::CreateRomFS(romfs_dir);',
    'if (packed != nullptr) {',
    '    cache.emplace(cache_key, packed);',
    '}',
    'return packed;'
)
$replacement = ($replacementLines | ForEach-Object { $indent + $_ }) -join "`n"
$text = [regex]::Replace($text, $createPattern, [System.Text.RegularExpressions.MatchEvaluator]{
    param($match)
    return $replacement
}, 1)

[IO.File]::WriteAllText((Resolve-Path $path).Path,
    $text.TrimEnd("`r", "`n") + "`n", [Text.UTF8Encoding]::new($false))

git diff --check -- $path
if ($LASTEXITCODE -ne 0) {
    throw 'Loose RomFS memoization introduced diff/whitespace errors'
}

$verify = (Get-Content $path -Raw).Replace("`r`n", "`n")
if (-not $verify.Contains('static std::unordered_map<std::string, FileSys::VirtualFile> cache;') -or
    -not $verify.Contains('Reusing cached loose RomFS') -or
    -not $verify.Contains('Building loose RomFS once')) {
    throw 'Loose RomFS memoization verification failed'
}

Write-Host '[APPLIED] memoized packed loose RomFS by source path to avoid repeated full-directory builds during loader probing'
