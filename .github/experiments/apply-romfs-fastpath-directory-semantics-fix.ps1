$ErrorActionPreference = 'Stop'

# The Win32 RomFS enumerator must preserve RealVfsFilesystem::OpenDirectory() semantics.
# OpenDirectory sanitizes the path before constructing RealVfsDirectory; bypassing it can make
# the accelerated loose-RomFS tree differ subtly from the validated golden path.
$source = 'src/core/file_sys/vfs/vfs_real.cpp'
if (-not (Test-Path $source -PathType Leaf)) {
    throw "RomFS directory semantics fix: missing $source"
}

$text = (Get-Content $source -Raw).Replace("`r`n", "`n")
$old = '            directories.emplace_back(std::make_shared<RealVfsDirectory>(base, full_path, perms));'
$new = '            directories.emplace_back(base.OpenDirectory(full_path, perms));'

if ($text.Contains($old)) {
    $text = $text.Replace($old, $new)
} elseif (-not $text.Contains($new)) {
    throw 'RomFS directory semantics fix: expected Win32 fast-path directory construction not found'
}

[IO.File]::WriteAllText((Resolve-Path $source).Path,
    $text.TrimEnd("`r", "`n") + "`n", [Text.UTF8Encoding]::new($false))

git diff --check -- $source
if ($LASTEXITCODE -ne 0) {
    throw 'RomFS directory semantics fix introduced diff/whitespace errors'
}

$verify = (Get-Content $source -Raw).Replace("`r`n", "`n")
if (-not $verify.Contains($new) -or $verify.Contains($old)) {
    throw 'RomFS directory semantics fix verification failed'
}

Write-Host '[APPLIED] Win32 RomFS fast path now routes subdirectories through base.OpenDirectory()'
Write-Host '          Preserves path sanitization/normalization semantics from the golden VFS path.'
