$ErrorActionPreference = 'Stop'

function Require-Text([string]$Path, [string]$Needle, [string]$Name) {
    if (-not (Test-Path $Path)) { throw "NS2 stability regression: missing required file $Path" }
    $text = Get-Content $Path -Raw
    if (-not $text.Contains($Needle)) { throw "NS2 stability regression: $Name missing from $Path" }
    Write-Host "[PASS] $Name"
}

$undef = 'src/shader_recompiler/backend/spirv/emit_spirv_undefined.cpp'
$model = 'src/qt_common/game_list/model.cpp'
$modelHeader = 'src/qt_common/game_list/model.h'
$worker = 'src/qt_common/game_list/worker.cpp'
$workerHeader = 'src/qt_common/game_list/worker.h'

# AMD/NX2 undefined shader registers. Some fragment paths exit before writing colour; leaving U1/U32
# as OpUndef makes the result driver-dependent and produced green/blue garbage on AMD.
Require-Text $undef 'bool UndefIsZero()' 'NX2 undefined-register policy helper'
Require-Text $undef 'EDEN_NX2_UNDEF_ZERO' 'undefined-register rollback switch'
Require-Text $undef 'return UndefIsZero() ? ctx.false_value : ctx.OpUndef(ctx.U1);' 'zero-initialized undefined U1'
Require-Text $undef 'return UndefIsZero() ? ctx.u32_zero_value : ctx.OpUndef(ctx.U32[1]);' 'zero-initialized undefined U32'

# Do not destroy a game-list worker while a nested Qt event loop can still be executing its
# ProcessEvents stack frame, and do not recreate content providers underneath a running title.
Require-Text $modelHeader 'void StopWorker();' 'game-list deferred worker stop declaration'
Require-Text $model 'void GameListModel::StopWorker()' 'game-list deferred worker stop implementation'
Require-Text $model 'current_worker.release()->deleteLater();' 'Qt deferred worker destruction'
Require-Text $model 'if (QtCommon::system->IsPoweredOn())' 'running-game repopulate guard'
Require-Text $model 'Emulation is running, deferring game list reload.' 'running-game content-provider preservation'
Require-Text $workerHeader 'void Stop();' 'game-list worker synchronous stop API'
Require-Text $worker 'stop_requested.exchange(true)' 'idempotent game-list worker shutdown'
Require-Text $worker 'while (model->current_worker.get() == this)' 'nested-event worker replacement guard'

# Reject the old unsafe shapes if a later donor merge accidentally resurrects them. Search for the
# actual controller call rather than the word CreateFactories, because the explanatory comment above
# the guard intentionally mentions that function name too.
$modelText = Get-Content $model -Raw
$repopulateStart = $modelText.IndexOf('void GameListModel::Repopulate()')
if ($repopulateStart -lt 0) { throw 'NS2 stability regression: GameListModel::Repopulate not found' }
$repopulateEnd = $modelText.IndexOf("`n}", $repopulateStart)
if ($repopulateEnd -lt 0) { throw 'NS2 stability regression: end of GameListModel::Repopulate not found' }
$repopulate = $modelText.Substring($repopulateStart, $repopulateEnd - $repopulateStart)
$guard = $repopulate.IndexOf('if (QtCommon::system->IsPoweredOn())')
$factories = $repopulate.IndexOf('GetFileSystemController().CreateFactories')
if ($guard -lt 0 -or $factories -lt 0 -or $guard -gt $factories) {
    throw 'NS2 stability regression: content-provider recreation is no longer guarded while emulation runs'
}

Write-Host 'Late NS2 stability regression validation passed.'

# Validate the newer targeted donor layers chained after this stability stack.
& "$PSScriptRoot\test-ns2-donor-20261101.ps1"
& "$PSScriptRoot\test-ns2-donor-safe-perf.ps1"
& "$PSScriptRoot\test-ns2-pr142-memory-stutter.ps1"
