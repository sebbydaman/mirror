$ErrorActionPreference = 'Stop'

# Post-01effa Mario Kart World compatibility: Ampere RET has no destination GPR.
# Bits 16..23 are reserved on RET and must not be interpreted as a write to the active
# return-link register. Keep the existing link-flow validation for every instruction that
# really can write a GPR, so corrupted/native callee linkage is still rejected.
function Read-Lf([string]$Path) {
    if (-not (Test-Path $Path)) { throw "Missing required source file: $Path" }
    return (Get-Content $Path -Raw).Replace("`r`n", "`n")
}
function Write-Utf8([string]$Path, [string]$Text) {
    Set-Content -Path $Path -Value $Text -Encoding utf8 -NoNewline
}
function Replace-Once([string]$Text, [string]$Old, [string]$New, [string]$Label) {
    $at = $Text.IndexOf($Old)
    if ($at -lt 0) { throw "Could not locate $Label" }
    if ($Text.IndexOf($Old, $at + $Old.Length) -ge 0) { throw "Ambiguous anchor for $Label" }
    return $Text.Substring(0, $at) + $New + $Text.Substring($at + $Old.Length)
}

$amperePath = 'src/shader_recompiler/frontend/ampere/lower_to_maxwell.h'
$ampere = Read-Lf $amperePath
$newGuard = '            if (active_link && opcode != 0x950 && insn.Bits(16, 8) == *active_link)'
if (-not $ampere.Contains($newGuard)) {
    $oldGuard = '            if (active_link && insn.Bits(16, 8) == *active_link)'
    $ampere = Replace-Once $ampere $oldGuard $newGuard 'Ampere active-link overwrite guard'
    Write-Utf8 $amperePath $ampere
}

$check = Read-Lf $amperePath
if (-not $check.Contains($newGuard)) {
    throw 'Runtime-v7 RET regression: RET is still treated as a destination-GPR write'
}
if (-not $check.Contains('return fail(index, "native callee overwrites link register");')) {
    throw 'Runtime-v7 RET regression: real callee link-register overwrite validation disappeared'
}
if (-not $check.Contains('case 0x950: { // RET')) {
    throw 'Runtime-v7 RET regression: native RET lowering disappeared'
}

Write-Host 'Applied Ampere RET reserved-destination fix: R0/R55 return links remain valid while real overwrites stay rejected.'

# PokeDinner performance donor: use BC3 for Switch 2 ASTC on sub-12-GiB Vulkan cards unless
# explicitly opted out, reducing texture-cache pressure without changing higher-VRAM sessions.
$runtimeV8Script = Join-Path $PSScriptRoot 'apply-ns2-runtime-blockers-v8.ps1'
& $runtimeV8Script

git diff -- $amperePath
