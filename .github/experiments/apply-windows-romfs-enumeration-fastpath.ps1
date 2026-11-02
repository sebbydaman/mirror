$ErrorActionPreference = 'Stop'

# Clang/MinGW's std::filesystem directory walk is dramatically slower than the older MSVC build
# for large extracted NS2 RomFS trees. Keep the final Zen4/PGO runtime intact, but give loose RomFS
# construction a Windows-native one-pass enumerator that obtains name/type/size from FindFirstFileExW.
# This is deliberately isolated to RomFS construction; normal VFS directory semantics remain unchanged.

$header = 'src/core/file_sys/vfs/vfs_real.h'
$source = 'src/core/file_sys/vfs/vfs_real.cpp'
$romfs  = 'src/core/file_sys/fsmitm_romfsbuild.cpp'

foreach ($path in @($header, $source, $romfs)) {
    if (-not (Test-Path $path -PathType Leaf)) {
        throw "Windows RomFS enumeration fast path: missing $path"
    }
}

function Normalize([string]$text) {
    return $text.Replace("`r`n", "`n")
}

# ---- RealVfsDirectory public helper -----------------------------------------------------------
$h = Normalize (Get-Content $header -Raw)
if (-not $h.Contains('GetEntriesForRomFSBuild() const;')) {
    $anchor = '    std::vector<VirtualDir> GetSubdirectories() const override;'
    if (-not $h.Contains($anchor)) {
        throw 'Windows RomFS enumeration fast path: RealVfsDirectory header anchor missing'
    }
    $replacement = @'
    std::vector<VirtualDir> GetSubdirectories() const override;

    // One-pass physical-directory enumeration used only by RomFSBuildContext. On Windows this
    // bypasses std::filesystem::directory_iterator/status/file_size churn while preserving the
    // existing VFS API everywhere else.
    std::pair<std::vector<VirtualFile>, std::vector<VirtualDir>> GetEntriesForRomFSBuild() const;
'@
    $h = $h.Replace($anchor, $replacement.TrimEnd("`r", "`n"))
}

if (-not $h.Contains('#include <utility>')) {
    $anchor = '#include <string_view>'
    if (-not $h.Contains($anchor)) {
        throw 'Windows RomFS enumeration fast path: utility include anchor missing'
    }
    $h = $h.Replace($anchor, "#include <string_view>`n#include <utility>")
}

[IO.File]::WriteAllText((Resolve-Path $header).Path,
    $h.TrimEnd("`r", "`n") + "`n", [Text.UTF8Encoding]::new($false))

# ---- Windows-native RealVfsDirectory enumeration ---------------------------------------------
$s = Normalize (Get-Content $source -Raw)

if (-not $s.Contains('FindFirstFileExW(')) {
    # Match only the stable include itself. Integration scripts are allowed to alter the surrounding
    # preprocessor layout without breaking this startup-only patch.
    $cstdioAnchor = '#include <cstdio> // _getmaxstdio'
    if (-not $s.Contains($cstdioAnchor)) {
        throw 'Windows RomFS enumeration fast path: _getmaxstdio include anchor missing'
    }

    $windowsIncludes = @'
#include <cstdio> // _getmaxstdio
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
// Avoid Win32 A/W macro aliases colliding with VFS method names below.
#ifdef CreateFile
#undef CreateFile
#endif
#ifdef DeleteFile
#undef DeleteFile
#endif
#ifdef MoveFile
#undef MoveFile
#endif
#ifdef CopyFile
#undef CopyFile
#endif
#ifdef CreateDirectory
#undef CreateDirectory
#endif
#ifdef RemoveDirectory
#undef RemoveDirectory
#endif
'@
    $s = $s.Replace($cstdioAnchor, $windowsIncludes.TrimEnd("`r", "`n"))

    # Insert before IsWritable rather than replacing GetSubdirectories. Several NS2 integration
    # layers legitimately touch the directory-iteration functions, so using the following stable
    # method boundary makes the patch insensitive to whitespace/body changes above it.
    $insertAnchor = 'bool RealVfsDirectory::IsWritable() const {'
    $anchorIndex = $s.IndexOf($insertAnchor, [StringComparison]::Ordinal)
    if ($anchorIndex -lt 0) {
        throw 'Windows RomFS enumeration fast path: RealVfsDirectory::IsWritable insertion anchor missing'
    }

    $methodImplementation = @'
std::pair<std::vector<VirtualFile>, std::vector<VirtualDir>>
RealVfsDirectory::GetEntriesForRomFSBuild() const {
#ifdef _WIN32
    if (perms == OpenMode::AllowAppend) {
        return {};
    }

    std::vector<VirtualFile> files;
    std::vector<VirtualDir> directories;

    const std::filesystem::path directory_path{FS::ToU8String(path)};
    const std::filesystem::path search_path = directory_path / L"*";

    WIN32_FIND_DATAW entry{};
    HANDLE handle = FindFirstFileExW(search_path.c_str(), FindExInfoBasic, &entry,
                                     FindExSearchNameMatch, nullptr, FIND_FIRST_EX_LARGE_FETCH);
    if (handle == INVALID_HANDLE_VALUE && GetLastError() == ERROR_INVALID_PARAMETER) {
        // Some filesystems do not accept FIND_FIRST_EX_LARGE_FETCH. Retry the same native path
        // without that advisory flag instead of falling all the way back to std::filesystem.
        handle = FindFirstFileExW(search_path.c_str(), FindExInfoBasic, &entry,
                                  FindExSearchNameMatch, nullptr, 0);
    }
    if (handle == INVALID_HANDLE_VALUE) {
        const DWORD error = GetLastError();
        if (error == ERROR_FILE_NOT_FOUND) {
            return {std::move(files), std::move(directories)};
        }

        LOG_WARNING(Common_Filesystem,
                    "Win32 RomFS enumeration failed for {}, error={}; using std::filesystem fallback",
                    path, error);
        return {GetFiles(), GetSubdirectories()};
    }

    do {
        const std::wstring_view name{entry.cFileName};
        if (name == L"." || name == L"..") {
            continue;
        }

        const std::filesystem::path entry_path = directory_path / entry.cFileName;
        const std::string full_path = FS::PathToUTF8String(entry_path);

        if ((entry.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
            directories.emplace_back(std::make_shared<RealVfsDirectory>(base, full_path, perms));
            continue;
        }

        const u64 file_size = (static_cast<u64>(entry.nFileSizeHigh) << 32) |
                              static_cast<u64>(entry.nFileSizeLow);
        files.emplace_back(base.OpenFileFromEntry(full_path, file_size, path, perms));
    } while (FindNextFileW(handle, &entry) != 0);

    const DWORD final_error = GetLastError();
    FindClose(handle);
    if (final_error != ERROR_NO_MORE_FILES) {
        LOG_WARNING(Common_Filesystem,
                    "Win32 RomFS enumeration ended early for {}, error={}", path, final_error);
    }

    return {std::move(files), std::move(directories)};
#else
    return {GetFiles(), GetSubdirectories()};
#endif
}

'@

    $s = $s.Insert($anchorIndex, $methodImplementation)
}

[IO.File]::WriteAllText((Resolve-Path $source).Path,
    $s.TrimEnd("`r", "`n") + "`n", [Text.UTF8Encoding]::new($false))

# ---- Route physical loose RomFS trees through the one-pass enumerator ------------------------
$r = Normalize (Get-Content $romfs -Raw)
if (-not $r.Contains('GetEntriesForRomFSBuild()')) {
    $includeAnchor = '#include "core/file_sys/vfs/vfs.h"'
    if (-not $r.Contains($includeAnchor)) {
        throw 'Windows RomFS enumeration fast path: RomFS VFS include anchor missing'
    }
    $r = $r.Replace($includeAnchor,
        $includeAnchor + "`n#include `"core/file_sys/vfs/vfs_real.h`"")

    $visitAnchor = @'
void RomFSBuildContext::VisitDirectory(VirtualDir romfs_dir, VirtualDir ext_dir,
                                       std::shared_ptr<RomFSBuildDirectoryContext> parent) {
    for (auto& child_romfs_file : romfs_dir->GetFiles()) {
'@
    if (-not $r.Contains($visitAnchor.TrimEnd("`r", "`n"))) {
        throw 'Windows RomFS enumeration fast path: VisitDirectory file-loop anchor missing'
    }
    $visitReplacement = @'
void RomFSBuildContext::VisitDirectory(VirtualDir romfs_dir, VirtualDir ext_dir,
                                       std::shared_ptr<RomFSBuildDirectoryContext> parent) {
    std::vector<VirtualFile> child_files;
    std::vector<VirtualDir> child_directories;
    if (const auto real_dir = std::dynamic_pointer_cast<RealVfsDirectory>(romfs_dir)) {
        auto entries = real_dir->GetEntriesForRomFSBuild();
        child_files = std::move(entries.first);
        child_directories = std::move(entries.second);
    } else {
        child_files = romfs_dir->GetFiles();
        child_directories = romfs_dir->GetSubdirectories();
    }

    for (auto& child_romfs_file : child_files) {
'@
    $r = $r.Replace($visitAnchor.TrimEnd("`r", "`n"),
                    $visitReplacement.TrimEnd("`r", "`n"))

    $dirLoopAnchor = '    for (auto& child_romfs_dir : romfs_dir->GetSubdirectories()) {'
    if (-not $r.Contains($dirLoopAnchor)) {
        throw 'Windows RomFS enumeration fast path: VisitDirectory directory-loop anchor missing'
    }
    $r = $r.Replace($dirLoopAnchor,
                    '    for (auto& child_romfs_dir : child_directories) {')
}

[IO.File]::WriteAllText((Resolve-Path $romfs).Path,
    $r.TrimEnd("`r", "`n") + "`n", [Text.UTF8Encoding]::new($false))

# ---- Structural verification ----------------------------------------------------------------
git diff --check -- $header $source $romfs
if ($LASTEXITCODE -ne 0) {
    throw 'Windows RomFS enumeration fast path introduced diff/whitespace errors'
}

$verifyHeader = Normalize (Get-Content $header -Raw)
$verifySource = Normalize (Get-Content $source -Raw)
$verifyRomfs  = Normalize (Get-Content $romfs -Raw)

if (-not $verifyHeader.Contains('GetEntriesForRomFSBuild() const;') -or
    -not $verifySource.Contains('FindFirstFileExW(') -or
    -not $verifySource.Contains('FIND_FIRST_EX_LARGE_FETCH') -or
    -not $verifyRomfs.Contains('std::dynamic_pointer_cast<RealVfsDirectory>(romfs_dir)') -or
    -not $verifyRomfs.Contains('child_directories')) {
    throw 'Windows RomFS enumeration fast path verification failed'
}

Write-Host '[APPLIED] Windows-native one-pass loose RomFS enumeration fast path'
Write-Host '          Goal: restore the older MSVC build''s ~1-3 s RomFS walk while keeping Zen4/PGO gameplay.'
