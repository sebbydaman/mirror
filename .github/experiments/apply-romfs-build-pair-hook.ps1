$ErrorActionPreference = 'Stop'

$path = 'src/core/file_sys/fsmitm_romfsbuild.cpp'
if (-not (Test-Path $path -PathType Leaf)) {
    throw "RomFS build pair hook: missing $path"
}

$text = (Get-Content $path -Raw).Replace("`r`n", "`n")
if ($text.Contains('auto [child_files, child_directories] = romfs_dir->GetEntriesForRomFSBuild();')) {
    Write-Host '[PRESENT] RomFS build pair-enumeration hook already applied'
    exit 0
}

# The validated NS2 layers can alter whitespace/local loop qualifiers in VisitDirectory. Match the
# semantic function boundary instead of an exact source block, then redirect its two directory walks.
$functionPattern = '(?s)(void\s+RomFSBuildContext::VisitDirectory\s*\(\s*VirtualDir\s+romfs_dir\s*,\s*VirtualDir\s+ext_dir\s*,\s*std::shared_ptr<RomFSBuildDirectoryContext>\s+parent\s*\)\s*\{\s*\n)'
$functionMatch = [regex]::Match($text, $functionPattern)
if (-not $functionMatch.Success) {
    throw 'RomFS build pair hook: VisitDirectory function boundary missing'
}

$insert = $functionMatch.Groups[1].Value +
    "    auto [child_files, child_directories] = romfs_dir->GetEntriesForRomFSBuild();`n`n"
$text = $text.Remove($functionMatch.Index, $functionMatch.Length).Insert($functionMatch.Index, $insert)

$filePattern = 'romfs_dir->GetFiles\s*\(\s*\)'
$fileMatches = [regex]::Matches($text, $filePattern)
if ($fileMatches.Count -lt 1) {
    throw 'RomFS build pair hook: no romfs_dir->GetFiles() use found after VisitDirectory'
}
$text = [regex]::Replace($text, $filePattern, 'child_files', 1)

$dirPattern = 'romfs_dir->GetSubdirectories\s*\(\s*\)'
$dirMatches = [regex]::Matches($text, $dirPattern)
if ($dirMatches.Count -lt 1) {
    throw 'RomFS build pair hook: no romfs_dir->GetSubdirectories() use found after VisitDirectory'
}
$text = [regex]::Replace($text, $dirPattern, 'child_directories', 1)

[IO.File]::WriteAllText((Resolve-Path $path).Path,
    $text.TrimEnd("`r", "`n") + "`n", [Text.UTF8Encoding]::new($false))

git diff --check -- $path
if ($LASTEXITCODE -ne 0) {
    throw 'RomFS build pair hook introduced diff/whitespace errors'
}

$verify = (Get-Content $path -Raw).Replace("`r`n", "`n")
if (-not $verify.Contains('auto [child_files, child_directories] = romfs_dir->GetEntriesForRomFSBuild();') -or
    $verify.Contains('romfs_dir->GetFiles()') -or
    $verify.Contains('romfs_dir->GetSubdirectories()')) {
    throw 'RomFS build pair hook verification failed'
}

Write-Host '[APPLIED] resilient RomFS build pair-enumeration hook'
