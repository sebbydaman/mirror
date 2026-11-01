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

$old = @'
    if (const auto parent = exefs_dir->GetParentDirectory()) {
        if (const auto romfs_dir = parent->GetSubdirectory("romfs")) {
            LOG_INFO(Loader, "Using RomFS directory next to the ExeFS");
            return FileSys::CreateRomFS(romfs_dir);
        }
    }
'@

$new = @'
    if (const auto parent = exefs_dir->GetParentDirectory()) {
        if (const auto romfs_dir = parent->GetSubdirectory("romfs")) {
            // Building a RomFS from a loose directory recursively walks the extracted title and is
            // expensive for large NS2 dumps. Frontend probing constructs this loader more than once
            // before the real boot, so retain the immutable base RomFS per source path and let each
            // loader apply its own LayeredFS wrapper afterward.
            static std::mutex cache_mutex;
            static std::unordered_map<std::string, FileSys::VirtualFile> cache;
            const std::string cache_key = romfs_dir->GetFullPath();
            std::scoped_lock lock{cache_mutex};
            if (const auto it = cache.find(cache_key); it != cache.end()) {
                LOG_INFO(Loader, "Reusing cached loose RomFS for {}", cache_key);
                return it->second;
            }
            LOG_INFO(Loader, "Building loose RomFS once for {}", cache_key);
            auto packed = FileSys::CreateRomFS(romfs_dir);
            if (packed != nullptr) {
                cache.emplace(cache_key, packed);
            }
            return packed;
        }
    }
'@

if (-not $text.Contains($old.TrimStart("`r", "`n"))) {
    throw 'Loose RomFS memoization: FindLooseRomFS anchor missing'
}
$text = $text.Replace($old.TrimStart("`r", "`n"), $new.TrimStart("`r", "`n"))

[IO.File]::WriteAllText((Resolve-Path $path).Path,
    $text.TrimEnd("`r", "`n") + "`n", [Text.UTF8Encoding]::new($false))

git diff --check -- $path
if ($LASTEXITCODE -ne 0) {
    throw 'Loose RomFS memoization introduced diff/whitespace errors'
}

$verify = (Get-Content $path -Raw).Replace("`r`n", "`n")
if (-not $verify.Contains('static std::unordered_map<std::string, FileSys::VirtualFile> cache;') -or
    -not $verify.Contains('Reusing cached loose RomFS')) {
    throw 'Loose RomFS memoization verification failed'
}

Write-Host '[APPLIED] memoized packed loose RomFS by source path to avoid repeated full-directory builds during loader probing'
