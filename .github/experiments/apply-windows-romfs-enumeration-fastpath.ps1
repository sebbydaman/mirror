$ErrorActionPreference = 'Stop'

# Clang/MinGW's std::filesystem directory walk is dramatically slower than the older MSVC build
# for large extracted NS2 RomFS trees. Keep the final Zen4/PGO runtime intact, but give loose RomFS
# construction a Windows-native one-pass enumerator that obtains name/type/size from FindFirstFileExW.
# This is deliberately isolated to RomFS construction; normal VFS semantics stay unchanged.

$vfsBase = 'src/core/file_sys/vfs/vfs.h'
$header  = 'src/core/file_sys/vfs/vfs_real.h'
$source  = 'src/core/file_sys/vfs/vfs_real.cpp'
$romfs   = 'src/core/file_sys/fsmitm_romfsbuild.cpp'

foreach ($path in @($vfsBase, $header, $source, $romfs)) {
    if (-not (Test-Path $path -PathType Leaf)) {
        throw "Windows RomFS enumeration fast path: missing $path"
    }
}

function Normalize([string]$text) {
    return $text.Replace("`r`n", "`n")
}

# ---- Generic VFS fallback --------------------------------------------------------------------
# Eden intentionally builds with -fno-rtti, so do not dynamic_cast the physical directory. Add a
# tiny virtual hook with a correctness-preserving default; RealVfsDirectory overrides only this
# RomFS-build operation with the native Win32 enumerator.
$v = Normalize (Get-Content $vfsBase -Raw)
if (-not $v.Contains('GetEntriesForRomFSBuild() const')) {
    if (-not $v.Contains('#include <utility>')) {
        $includeAnchor = '#include <type_traits>'
        if (-not $v.Contains($includeAnchor)) {
            throw 'Windows RomFS enumeration fast path: VFS utility include anchor missing'
        }
        $v = $v.Replace($includeAnchor, "$includeAnchor`n#include <utility>")
    }

    $anchor = '    virtual std::vector<VirtualDir> GetSubdirectories() const = 0;'
    if (-not $v.Contains($anchor)) {
        throw 'Windows RomFS enumeration fast path: VfsDirectory subdirectory anchor missing'
    }
    $replacement = @'
    virtual std::vector<VirtualDir> GetSubdirectories() const = 0;

    // RomFS builders often need files and directories together. The generic implementation keeps
    // existing VFS behavior; physical Windows directories override this to enumerate once and to
    // reuse Win32-provided file sizes instead of issuing per-entry std::filesystem queries.
    virtual std::pair<std::vector<VirtualFile>, std::vector<VirtualDir>>
    GetEntriesForRomFSBuild() const {
        return {GetFiles(), GetSubdirectories()};
    }
'@
    $v = $v.Replace($anchor, $replacement.TrimEnd("`r", "`n"))
}
[IO.File]::WriteAllText((Resolve-Path $vfsBase).Path,
    $v.TrimEnd("`r", "`n") + "`n", [Text.UTF8Encoding]::new($false))

# ---- RealVfsDirectory override declaration ---------------------------------------------------
$h = Normalize (Get-Content $header -Raw)
if (-not $h.Contains('GetEntriesForRomFSBuild() const override;')) {
    $anchor = '    std::vector<VirtualDir> GetSubdirectories() const override;'
    if (-not $h.Contains($anchor)) {
        throw 'Windows RomFS enumeration fast path: RealVfsDirectory header anchor missing'
    }
    $replacement = @'
    std::vector<VirtualDir> GetSubdirectories() const override;
    std::pair<std::vector<VirtualFile>, std::vector<VirtualDir>>
    GetEntriesForRomFSBuild() const override;
'@
    $h = $h.Replace($anchor, $replacement.TrimEnd("`r", "`n"))
}
[IO.File]::WriteAllText((Resolve-Path $header).Path,
    $h.TrimEnd("`r", "`n") + "`n", [Text.UTF8Encoding]::new($false))

# ---- Windows-native RealVfsDirectory enumeration ---------------------------------------------
$s = Normalize (Get-Content $source -Raw)
if (-not $s.Contains('FindFirstFileExW(')) {
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
        if ((entry.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
            FindClose(handle);
            return {GetFiles(), GetSubdirectories()};
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

# ---- Route RomFS construction through the pair-enumeration hook -------------------------------
$r = Normalize (Get-Content $romfs -Raw)
if (-not $r.Contains('GetEntriesForRomFSBuild();')) {
    # Match the loop itself rather than the whole VisitDirectory signature. Earlier compatibility
    # layers may reflow the function declaration without changing this semantic anchor.
    $fileLoopPattern = '(?m)^(?<indent>[ \t]*)for \(auto& child_romfs_file : romfs_dir->GetFiles\(\)\) \{[ \t]*$'
    $fileLoopMatches = [regex]::Matches($r, $fileLoopPattern)
    if ($fileLoopMatches.Count -ne 1) {
        throw "Windows RomFS enumeration fast path: expected exactly one VisitDirectory file loop, found $($fileLoopMatches.Count)"
    }
    $indent = $fileLoopMatches[0].Groups['indent'].Value
    $fileLoopReplacement = $indent + 'auto [child_files, child_directories] = romfs_dir->GetEntriesForRomFSBuild();' + "`n`n" +
                           $indent + 'for (auto& child_romfs_file : child_files) {'
    $r = [regex]::Replace($r, $fileLoopPattern, $fileLoopReplacement, 1)

    $dirLoopPattern = '(?m)^(?<indent>[ \t]*)for \(auto& child_romfs_dir : romfs_dir->GetSubdirectories\(\)\) \{[ \t]*$'
    $dirLoopMatches = [regex]::Matches($r, $dirLoopPattern)
    if ($dirLoopMatches.Count -ne 1) {
        throw "Windows RomFS enumeration fast path: expected exactly one VisitDirectory directory loop, found $($dirLoopMatches.Count)"
    }
    $r = [regex]::Replace($r, $dirLoopPattern, '${indent}for (auto& child_romfs_dir : child_directories) {', 1)
}
[IO.File]::WriteAllText((Resolve-Path $romfs).Path,
    $r.TrimEnd("`r", "`n") + "`n", [Text.UTF8Encoding]::new($false))

# ---- Structural verification ----------------------------------------------------------------
git diff --check -- $vfsBase $header $source $romfs
if ($LASTEXITCODE -ne 0) {
    throw 'Windows RomFS enumeration fast path introduced diff/whitespace errors'
}

$verifyBase   = Normalize (Get-Content $vfsBase -Raw)
$verifyHeader = Normalize (Get-Content $header -Raw)
$verifySource = Normalize (Get-Content $source -Raw)
$verifyRomfs  = Normalize (Get-Content $romfs -Raw)

if (-not $verifyBase.Contains('GetEntriesForRomFSBuild() const') -or
    -not $verifyHeader.Contains('GetEntriesForRomFSBuild() const override;') -or
    -not $verifySource.Contains('FindFirstFileExW(') -or
    -not $verifySource.Contains('FIND_FIRST_EX_LARGE_FETCH') -or
    -not $verifyRomfs.Contains('auto [child_files, child_directories] = romfs_dir->GetEntriesForRomFSBuild();')) {
    throw 'Windows RomFS enumeration fast path verification failed'
}
if ($verifyRomfs.Contains('dynamic_pointer_cast') -or $verifySource.Contains('dynamic_cast<')) {
    throw 'Windows RomFS enumeration fast path must remain compatible with Eden -fno-rtti builds'
}

Write-Host '[APPLIED] RTTI-free Windows-native one-pass loose RomFS enumeration fast path'
Write-Host '          Goal: restore the older MSVC build''s ~1-3 s RomFS walk while keeping Zen4/PGO gameplay.'