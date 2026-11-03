$ErrorActionPreference = 'Stop'
$patch = Join-Path $PSScriptRoot 'build142-runtime.patch'
if (-not (Test-Path $patch -PathType Leaf)) { throw 'Missing build142 runtime patch' }
# Existing adapters produce mixed line endings on Windows; normalize patch targets.
$patchText = [IO.File]::ReadAllText($patch).Replace("`r`n", "`n")

# Build 158 follow-up 8556e270 fixes the build-142 uniform-buffer fast guard. BufferId{0}
# (NULL_BUFFER_ID) is a valid SlotId value, so `!current.buffer_id` never identifies the null
# binding. Adapt the donor patch before applying it and fail closed if the donor text drifts.
$oldUniformGuard = 'current.device_addr == 0 && current.size == 0 && !current.buffer_id'
$newUniformGuard = 'current.device_addr == 0 && current.size == 0 && current.buffer_id == NULL_BUFFER_ID'
$uniformGuardMatches = [regex]::Matches($patchText, [regex]::Escape($oldUniformGuard)).Count
if ($uniformGuardMatches -ne 1) {
    throw "Expected exactly one build-142 uniform-buffer guard to normalize, found $uniformGuardMatches"
}
$patchText = $patchText.Replace($oldUniformGuard, $newUniformGuard)

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
