$ErrorActionPreference = 'Stop'

# Preserve the full post-#73 runtime semantic patch in the core script. This wrapper only fixes
# the #74 integration/scoping mistake where the new ISBERD/ISBEWR blocks referred to a
# reserved_register helper that does not exist in this LowerToMaxwell implementation.
$coreScript = Join-Path $PSScriptRoot 'apply-ns2-runtime-blockers-v3-core.ps1'
& $coreScript

$amperePath = 'src/shader_recompiler/frontend/ampere/lower_to_maxwell.h'
if (-not (Test-Path $amperePath)) { throw "Missing required source file: $amperePath" }
$ampere = (Get-Content $amperePath -Raw).Replace("`r`n", "`n")

# LowerToMaxwell already reserves GPR 216+ when the emulated uniform bank is in use, otherwise
# GPR 250+ is the scratch range. Use that same boundary for the new indexed stage-payload guards.
$undefined = [regex]::Matches($ampere, '\breserved_register\b').Count
if ($undefined -eq 4) {
    $ampere = $ampere.Replace('reserved_register', '(uses_uniform_bank ? 216U : 250U)')
    Set-Content -Path $amperePath -Value $ampere -Encoding utf8 -NoNewline
} elseif ($undefined -ne 0) {
    throw "Unexpected reserved_register reference count: $undefined"
}

$check = (Get-Content $amperePath -Raw).Replace("`r`n", "`n")
if ($check.Contains('reserved_register')) {
    throw 'Runtime-v3 compile fix failed: unresolved reserved_register reference remains'
}
foreach ($needle in @(
    'case 0x923: { // ISBERD indexed task/mesh attribute read / direct map read.',
    'case 0x927: { // ISBEWR indexed task/mesh attribute write.',
    'dest >= (uses_uniform_bank ? 216U : 250U)',
    'offset_reg >= (uses_uniform_bank ? 216U : 250U)',
    'data >= (uses_uniform_bank ? 216U : 250U)'
)) {
    if (-not $check.Contains($needle)) { throw "Runtime-v3 compile regression: missing $needle" }
}

Write-Host 'Resolved #74 indexed stage-payload reserved-GPR boundary without removing runtime-v3 semantics.'

# Once the #74 payload/RET/TXQ fixes are applied, add the next proven native ISA operation.
$runtimeV4Script = Join-Path $PSScriptRoot 'apply-ns2-runtime-blockers-v4.ps1'
& $runtimeV4Script

# The workflow compiles a separate Eglantine checkout under eden/, not this automation
# repository's src/ tree. Keep the shared Stage enum exhaustive there as well, while explicitly
# rejecting Task/Mesh on GLASM instead of pretending the legacy backend supports those stages.
$glasmGuardScript = Join-Path $PSScriptRoot 'apply-glasm-task-mesh-guard.ps1'
& $glasmGuardScript
