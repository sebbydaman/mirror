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
