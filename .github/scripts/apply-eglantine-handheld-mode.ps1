$ErrorActionPreference = 'Stop'

# Small late-Eglantine display/mode batch, validated with git apply --check against the exact
# captured tree after read traps + sparse-deadlock/VRAM work:
#   * 0a47ba9: crop every Switch 2 handheld present image to the 1920x1080 panel. This fixes the
#     black-margin/corner-frame behavior seen on Mario Kart World and Splatoon Raiders.
#   * d2ac227 desktop/core pieces: notify the guest when docked/handheld mode changes and expose
#     the Switch 2 operation-mode refresh event instead of returning the generic unknown event.

$markers = @(
    @{ Path = 'src/core/hle/service/nx2_gsv.h'; Text = 'seen on Mario Kart World and Splatoon Raiders' },
    @{ Path = 'src/core/core.cpp'; Text = 'GetAppletManager().OperationModeChanged();' },
    @{ Path = 'src/core/hle/service/am/applet_manager.h'; Text = 'bool m_docked{};' },
    @{ Path = 'src/core/hle/service/am/lifecycle_manager.h'; Text = 'GetOperationModeRefreshEvent();' },
    @{ Path = 'src/core/hle/service/am/lifecycle_manager.cpp'; Text = 'm_operation_mode_refresh_event.Signal(kernel);' },
    @{ Path = 'src/core/hle/service/am/service/application_functions.cpp'; Text = 'process->IsSwitch2()' },
    @{ Path = 'src/core/hle/service/am/service/application_functions.cpp'; Text = 'GetOperationModeRefreshEvent (guessed)' }
)

$present = 0
foreach ($marker in $markers) {
    if ((Get-Content $marker.Path -Raw).Contains($marker.Text)) { ++$present }
}
if ($present -eq $markers.Count) {
    Write-Host 'NS2 handheld/mode batch is already present.'
    exit 0
}
if ($present -ne 0) {
    throw "Partial NS2 handheld/mode state detected ($present/$($markers.Count) markers); refusing mixed apply"
}

$payload = Join-Path $PSScriptRoot '..\patches\ns2-handheld-mode.patch.gz.b64'
if (-not (Test-Path $payload)) { throw "Missing handheld/mode patch payload: $payload" }
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
$patchPath = Join-Path $env:RUNNER_TEMP 'ns2-handheld-mode.patch'
[IO.File]::WriteAllBytes($patchPath, $patchBytes)

git apply --check --whitespace=error-all $patchPath
if ($LASTEXITCODE -ne 0) { throw 'NS2 handheld/mode patch no longer applies to the integrated source' }
git apply --whitespace=error-all $patchPath
if ($LASTEXITCODE -ne 0) { throw 'Failed to apply NS2 handheld/mode patch' }
git diff --check
if ($LASTEXITCODE -ne 0) { throw 'NS2 handheld/mode patch introduced diff/whitespace errors' }

foreach ($marker in $markers) {
    if (-not (Get-Content $marker.Path -Raw).Contains($marker.Text)) {
        throw "NS2 handheld/mode validation failed: missing '$($marker.Text)' in $($marker.Path)"
    }
}

# Ensure the generalized handheld crop is no longer gated behind Mario Kart World's title ID.
$gsv = Get-Content 'src/core/hle/service/nx2_gsv.h' -Raw
$handheld = $gsv.IndexOf('if (!Settings::IsDockedMode())')
$mkwDocked = $gsv.IndexOf('system.GetApplicationProcessProgramID() == 0x0400C3F00006E000ULL', $handheld)
if ($handheld -lt 0 -or $mkwDocked -lt $handheld) {
    throw 'NS2 handheld crop did not retain generic-handheld then MKW-docked ordering'
}

Write-Host 'Applied NS2 handheld presentation + live docked/handheld operation-mode notification batch.'
