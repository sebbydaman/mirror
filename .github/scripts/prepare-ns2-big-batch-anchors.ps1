$ErrorActionPreference = 'Stop'

# Keep the large batch's exact replacements deterministic across Windows CRLF checkouts.
# The batch normalizes C++ source to LF; PowerShell here-strings parsed on Windows otherwise keep
# CRLF, so normalize the helper's Old/New strings too before any multi-line comparison.
$batchScript = Join-Path $PSScriptRoot 'apply-ns2-general-compat-batch-v2.ps1'
$batch = Get-Content $batchScript -Raw
$helper = 'function Replace-Once([string]$Text, [string]$Old, [string]$New, [string]$Label) {'
$normalizedHelper = @'
function Replace-Once([string]$Text, [string]$Old, [string]$New, [string]$Label) {
    $Old = $Old.Replace("`r`n", "`n")
    $New = $New.Replace("`r`n", "`n")
'@.TrimEnd("`r", "`n")
if ($batch.Contains($helper) -and -not $batch.Contains('$Old = $Old.Replace("`r`n", "`n")')) {
    $batch = $batch.Replace($helper, $normalizedHelper)
    Set-Content -Path $batchScript -Value $batch -Encoding utf8 -NoNewline
    Write-Host 'Normalized multi-line PowerShell replacement anchors to LF.'
} elseif (-not $batch.Contains('$Old = $Old.Replace("`r`n", "`n")')) {
    throw 'Could not normalize Replace-Once helper in generalized batch'
}

# Runtime-v8 is the PokeDinner 2.0 multi-feature batch. It also reads C++ as LF while PowerShell
# here-strings are CRLF on the Windows runner. Normalize its replacement helper up front so all
# source-verified ObjectPool/predicate/etc. edits can be exercised in one build rather than each
# failing on line-ending-only anchor mismatches.
$runtimeV8Script = Join-Path $PSScriptRoot 'apply-ns2-runtime-blockers-v8.ps1'
$runtimeV8 = Get-Content $runtimeV8Script -Raw
if ($runtimeV8.Contains($helper) -and -not $runtimeV8.Contains('$Old = $Old.Replace("`r`n", "`n")')) {
    $runtimeV8 = $runtimeV8.Replace($helper, $normalizedHelper)
    Set-Content -Path $runtimeV8Script -Value $runtimeV8 -Encoding utf8 -NoNewline
    Write-Host 'Normalized PokeDinner 2.0 runtime-v8 replacement anchors to LF.'
} elseif (-not $runtimeV8.Contains('$Old = $Old.Replace("`r`n", "`n")')) {
    throw 'Could not normalize Replace-Once helper in PokeDinner 2.0 runtime-v8 batch'
}

# One 01effa signature differs only by legal C++ whitespace from the batch's exact replacement.
$path = 'src/video_core/buffer_cache/buffer_cache.h'
$text = (Get-Content $path -Raw).Replace("`r`n", "`n")
$old = 'BufferId BufferCache<P>::FindBuffer(DAddr device_addr'
$new = "BufferId BufferCache<P>::FindBuffer`n(DAddr device_addr"
if ($text.Contains($old)) {
    $text = $text.Replace($old, $new)
    Set-Content -Path $path -Value $text -Encoding utf8 -NoNewline
    Write-Host 'Normalized FindBuffer signature anchor for combined batch.'
} elseif (-not $text.Contains($new)) {
    throw 'Could not normalize FindBuffer signature anchor'
}

# PokeDinner 2.0 sparse written-state belongs to one emulation session. Prepare the helper with a
# stable single-function boundary so runtime-v8 only needs to add the nvdrv reset call. Legacy
# GLSL Task/Mesh handling deliberately stays out of this preflight: runtime-v10 is the canonical
# final normalization layer for those backend switches.
$nx2Path = 'src/video_core/nx2.h'
$nx2 = (Get-Content $nx2Path -Raw).Replace("`r`n", "`n")
$sparseMarker = 'inline void Nx2ClearSparseRegions()'
if (-not $nx2.Contains($sparseMarker)) {
    $sparseAnchor = 'inline void Nx2SparseBlockWritten(u64 region_address, u64 block) {'
    $at = $nx2.IndexOf($sparseAnchor)
    if ($at -lt 0) { throw 'Could not locate stable Nx2SparseBlockWritten preflight anchor' }
    if ($nx2.IndexOf($sparseAnchor, $at + $sparseAnchor.Length) -ge 0) {
        throw 'Ambiguous Nx2SparseBlockWritten preflight anchor'
    }
    $sparseReset = @'
/// A new emulation session: the previous game's regions are gone (nvdrv's Module clears them).
inline void Nx2ClearSparseRegions() {
    std::scoped_lock lk{g_nx2_sparse_state_mutex};
    g_nx2_sparse_state.clear();
}

'@
    $sparseReset = $sparseReset.Replace("`r`n", "`n")
    $nx2 = $nx2.Substring(0, $at) + $sparseReset + $nx2.Substring($at)
    Set-Content -Path $nx2Path -Value $nx2 -Encoding utf8 -NoNewline
    Write-Host 'Prepared PokeDinner 2.0 sparse-session reset with stable function anchor.'
}
