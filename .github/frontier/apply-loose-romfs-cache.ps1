$ErrorActionPreference = 'Stop'

function Write-PatchedText([string]$Path, [string]$Text) {
    $normalized = $Text.TrimEnd("`r", "`n") + "`n"
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText((Resolve-Path $Path).Path, $normalized, $utf8NoBom)
}

$path = 'src/core/loader/deconstructed_rom_directory.cpp'
if (-not (Test-Path $path -PathType Leaf)) {
    throw "Loose RomFS cache: missing $path"
}

$text = (Get-Content $path -Raw).Replace("`r`n", "`n")
$marker = 'EDEN_LOOSE_ROMFS_CACHE'
if ($text.Contains($marker)) {
    foreach ($needle in @(
        'std::unordered_map<std::string, FileSys::VirtualFile> loose_romfs_cache',
        'romfs_dir->GetFullPath()',
        'Reusing cached RomFS directory next to the ExeFS'
    )) {
        if (-not $text.Contains($needle)) {
            throw "Loose RomFS cache: partial existing implementation; missing $needle"
        }
    }
    Write-Host '[PRESENT] Loose RomFS process cache'
    exit 0
}

$includeAnchor = '#include <cstring>'
if (-not $text.Contains($includeAnchor)) {
    throw 'Loose RomFS cache: include anchor changed'
}
if (-not $text.Contains('#include <mutex>')) {
    $text = $text.Replace($includeAnchor, "$includeAnchor`n#include <mutex>")
}
if (-not $text.Contains('#include <unordered_map>')) {
    $text = $text.Replace('#include <mutex>', "#include <mutex>`n#include <unordered_map>")
}

$old = @'
FileSys::VirtualFile FindLooseRomFS(const FileSys::VirtualDir& exefs_dir) {
    if (exefs_dir == nullptr) {
        return nullptr;
    }
    for (const auto& f : exefs_dir->GetFiles()) {
        if (f->GetExtension() == "romfs") {
            return f;
        }
    }
    if (const auto parent = exefs_dir->GetParentDirectory()) {
        if (const auto romfs_dir = parent->GetSubdirectory("romfs")) {
            LOG_INFO(Loader, "Using RomFS directory next to the ExeFS");
            return FileSys::CreateRomFS(romfs_dir);
        }
    }
    return nullptr;
}
'@
$old = $old.Replace("`r`n", "`n")
if (-not $text.Contains($old)) {
    throw 'Loose RomFS cache: FindLooseRomFS source block changed'
}

$new = @'
// EDEN_LOOSE_ROMFS_CACHE: constructing a RomFS view from a large extracted directory can take
// tens of seconds. The frontend may instantiate the loose-directory loader several times during
// one launch, so reuse the already-built read-only view for the same directory path.
FileSys::VirtualFile FindLooseRomFS(const FileSys::VirtualDir& exefs_dir) {
    if (exefs_dir == nullptr) {
        return nullptr;
    }
    for (const auto& f : exefs_dir->GetFiles()) {
        if (f->GetExtension() == "romfs") {
            return f;
        }
    }
    if (const auto parent = exefs_dir->GetParentDirectory()) {
        if (const auto romfs_dir = parent->GetSubdirectory("romfs")) {
            static std::mutex loose_romfs_cache_mutex;
            static std::unordered_map<std::string, FileSys::VirtualFile> loose_romfs_cache;
            const std::string cache_key = romfs_dir->GetFullPath();

            {
                std::scoped_lock lock{loose_romfs_cache_mutex};
                if (const auto it = loose_romfs_cache.find(cache_key);
                    it != loose_romfs_cache.end()) {
                    LOG_INFO(Loader, "Reusing cached RomFS directory next to the ExeFS");
                    return it->second;
                }
            }

            LOG_INFO(Loader, "Using RomFS directory next to the ExeFS");
            auto created = FileSys::CreateRomFS(romfs_dir);
            if (created == nullptr) {
                return nullptr;
            }

            std::scoped_lock lock{loose_romfs_cache_mutex};
            const auto [it, inserted] = loose_romfs_cache.emplace(cache_key, created);
            return it->second;
        }
    }
    return nullptr;
}
'@
$new = $new.Replace("`r`n", "`n")
$text = $text.Replace($old, $new)
Write-PatchedText $path $text

$final = Get-Content $path -Raw
foreach ($needle in @(
    'EDEN_LOOSE_ROMFS_CACHE',
    '#include <mutex>',
    '#include <unordered_map>',
    'romfs_dir->GetFullPath()',
    'loose_romfs_cache.emplace(cache_key, created)'
)) {
    if (-not $final.Contains($needle)) {
        throw "Loose RomFS cache validation failed: missing $needle"
    }
}

git diff --check
if ($LASTEXITCODE -ne 0) {
    throw 'Loose RomFS cache introduced diff/whitespace errors'
}

Write-Host '[APPLIED] Loose RomFS process cache (avoids rebuilding the same extracted RomFS on repeated loader probes)'
