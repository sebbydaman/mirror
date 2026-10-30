$ErrorActionPreference = 'Stop'

# Keep the large batch's exact replacement deterministic across the 01effa source formatting.
# A newline between a C++ function name and its parameter list is ordinary whitespace.
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
