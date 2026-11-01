$ErrorActionPreference = 'Stop'

# Small late-Eglantine stability batch, generated and git-apply --checked against the exact
# captured integrated source after PokeDinner 2.0, read traps, sparse/VRAM fixes and handheld mode:
#   * AMD/NX2: undefined U1/U32 shader registers read as zero instead of driver-dependent OpUndef.
#     EDEN_NX2_UNDEF_ZERO=0 restores OpUndef for diagnosis.
#   * Game-list worker/content-provider lifetime: defer worker destruction when nested event loops
#     can still be executing it, and do not rebuild content providers underneath a running game.

$markers = @(
    @{ Path = 'src/shader_recompiler/backend/spirv/emit_spirv_undefined.cpp'; Text = 'bool UndefIsZero()' },
    @{ Path = 'src/shader_recompiler/backend/spirv/emit_spirv_undefined.cpp'; Text = 'EDEN_NX2_UNDEF_ZERO' },
    @{ Path = 'src/qt_common/game_list/model.cpp'; Text = 'void GameListModel::StopWorker()' },
    @{ Path = 'src/qt_common/game_list/model.cpp'; Text = 'Emulation is running, deferring game list reload.' },
    @{ Path = 'src/qt_common/game_list/worker.cpp'; Text = 'void GameListWorker::Stop()' },
    @{ Path = 'src/qt_common/game_list/worker.cpp'; Text = 'while (model->current_worker.get() == this)' }
)

$present = 0
foreach ($marker in $markers) {
    if ((Get-Content $marker.Path -Raw).Contains($marker.Text)) { ++$present }
}
if ($present -eq $markers.Count) {
    Write-Host 'Late NS2 stability batch is already present.'
    & "$PSScriptRoot\apply-ns2-donor-20261101.ps1"
    & "$PSScriptRoot\apply-ns2-donor-safe-perf.ps1"
    & "$PSScriptRoot\prep-pr142-kmemory-reset.ps1"
    & "$PSScriptRoot\apply-eglantine-pr142-memory-stutter.ps1"
    exit 0
}
if ($present -ne 0) {
    throw "Partial late-NS2 stability state detected ($present/$($markers.Count) markers); refusing mixed apply"
}

$payload = Join-Path $PSScriptRoot '..\patches\ns2-late-stability.patch.gz.b64'
if (-not (Test-Path $payload)) { throw "Missing late NS2 stability patch payload: $payload" }

$encoded = (Get-Content $payload -Raw) -replace '\s', ''
$compressed = [Convert]::FromBase64String($encoded)
$input = [IO.MemoryStream]::new($compressed, $false)
$gzip = [IO.Compression.GZipStream]::new($input, [IO.Compression.CompressionMode]::Decompress)
$output = [IO.MemoryStream]::new()
try {
    $gzip.CopyTo($output)
    $patchBytes = $output.ToArray()
} finally {
    $output.Dispose(); $gzip.Dispose(); $input.Dispose()
}

$patchPath = Join-Path $env:RUNNER_TEMP 'ns2-late-stability.patch'
[IO.File]::WriteAllBytes($patchPath, $patchBytes)

# Refuse to mutate the tree if our exact-source assumptions changed.
git apply --check --whitespace=error-all $patchPath
if ($LASTEXITCODE -ne 0) { throw 'Late NS2 stability patch no longer applies cleanly to the integrated source' }

git apply --whitespace=error-all $patchPath
if ($LASTEXITCODE -ne 0) { throw 'Failed to apply late NS2 stability patch' }

git diff --check
if ($LASTEXITCODE -ne 0) { throw 'Late NS2 stability patch introduced whitespace/diff errors' }

foreach ($marker in $markers) {
    if (-not (Get-Content $marker.Path -Raw).Contains($marker.Text)) {
        throw "Late NS2 stability validation failed: missing '$($marker.Text)' in $($marker.Path)"
    }
}

# Semantic guards beyond marker presence.
$undef = Get-Content 'src/shader_recompiler/backend/spirv/emit_spirv_undefined.cpp' -Raw
if (-not ($undef.Contains('return UndefIsZero() ? ctx.false_value : ctx.OpUndef(ctx.U1);') -and
          $undef.Contains('return UndefIsZero() ? ctx.u32_zero_value : ctx.OpUndef(ctx.U32[1]);'))) {
    throw 'AMD/NX2 undefined-register zeroing is incomplete'
}
$model = Get-Content 'src/qt_common/game_list/model.cpp' -Raw
if (-not ($model.Contains('if (QtCommon::system->IsPoweredOn())') -and
          $model.Contains('current_worker.release()->deleteLater();'))) {
    throw 'Game-list content-provider/worker lifetime protection is incomplete'
}
$worker = Get-Content 'src/qt_common/game_list/worker.cpp' -Raw
if (-not ($worker.Contains('stop_requested.exchange(true)') -and
          $worker.Contains('while (model->current_worker.get() == this)'))) {
    throw 'Game-list worker nested-event lifetime protection is incomplete'
}

Write-Host 'Applied late NS2 stability batch: AMD undefined-register zeroing + safe game-list/content-provider lifetime.'

# Apply the newer targeted donor layers only after the stable PokeDinner/Eglantine stack exists.
& "$PSScriptRoot\apply-ns2-donor-20261101.ps1"
& "$PSScriptRoot\apply-ns2-donor-safe-perf.ps1"
& "$PSScriptRoot\prep-pr142-kmemory-reset.ps1"
& "$PSScriptRoot\apply-eglantine-pr142-memory-stutter.ps1"
