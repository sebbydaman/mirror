$ErrorActionPreference = 'Stop'
$patch = Join-Path $PSScriptRoot 'build142-runtime.patch'
if (-not (Test-Path $patch -PathType Leaf)) { throw 'Missing build142 runtime patch' }
$dma = Get-Content 'src/video_core/dma_pusher.cpp' -Raw
if ($dma.Contains('EDEN_NX2_COMMAND_LIST_COPIES')) {
    git apply --reverse --check $patch
    if ($LASTEXITCODE -ne 0) { throw 'Partial or changed build142 runtime patch detected' }
} else {
    git apply --check --whitespace=error-all $patch
    if ($LASTEXITCODE -ne 0) { throw 'Build142 runtime patch does not match the assembled source' }
    git apply --whitespace=error-all $patch
    if ($LASTEXITCODE -ne 0) { throw 'Build142 runtime patch failed' }
}
& (Join-Path $PSScriptRoot 'test-build142-runtime.ps1')
