$ErrorActionPreference = 'Stop'
$patch = Join-Path $PSScriptRoot 'build142-runtime.patch'
if (-not (Test-Path $patch -PathType Leaf)) { throw 'Missing build142 runtime patch' }
# Existing adapters produce mixed line endings on Windows; normalize patch targets.
$patchText = [IO.File]::ReadAllText($patch).Replace("`r`n", "`n")
$normalizedPatch = Join-Path ([IO.Path]::GetTempPath()) 'ns2-build142-runtime-lf.patch'
[IO.File]::WriteAllText($normalizedPatch, $patchText, [Text.UTF8Encoding]::new($false))
foreach ($match in [regex]::Matches($patchText, '(?m)^\+\+\+ b/(.+)$')) {
    $path = $match.Groups[1].Value.TrimEnd("`r")
    $text = [IO.File]::ReadAllText((Resolve-Path $path)).Replace("`r`n", "`n")
    [IO.File]::WriteAllText((Resolve-Path $path), $text, [Text.UTF8Encoding]::new($false))
}
$patch = $normalizedPatch
$dma = Get-Content 'src/video_core/dma_pusher.cpp' -Raw
if ($dma.Contains('EDEN_NX2_COMMAND_LIST_COPIES')) {
    git -c core.autocrlf=false apply --reverse --check $patch
    if ($LASTEXITCODE -ne 0) { throw 'Partial or changed build142 runtime patch detected' }
} else {
    git -c core.autocrlf=false apply --check --whitespace=error-all $patch
    if ($LASTEXITCODE -ne 0) { throw 'Build142 runtime patch does not match the assembled source' }
    git -c core.autocrlf=false apply --whitespace=error-all $patch
    if ($LASTEXITCODE -ne 0) { throw 'Build142 runtime patch failed' }
}
& (Join-Path $PSScriptRoot 'test-build142-runtime.ps1')
