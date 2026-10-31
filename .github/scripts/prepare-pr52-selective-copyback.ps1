$ErrorActionPreference = 'Stop'

# PokeDinner 2.0 replaces the old inline async-download block in MarkWrittenBuffer with
# QueueDownload(device_addr, size). PR52's command-page history should layer on top of that
# selective copyback policy, not replace it. Seed the marker before the legacy PR52 script runs;
# that script will then add Nx2MarkGpuWritten/Nx2WrittenPageBits and skip its old source anchor.
$path = 'src/video_core/buffer_cache/buffer_cache.h'
$text = (Get-Content $path -Raw).Replace("`r`n", "`n")
$marker = 'Tegra::Nx2MarkGpuWritten(device_addr, size);'
if ($text.Contains($marker)) {
    Write-Host 'PR52 shader/copy write marker already present.'
    exit 0
}

$functionMarker = 'void BufferCache<P>::MarkWrittenBuffer('
$start = $text.IndexOf($functionMarker)
if ($start -lt 0) { throw 'Could not locate MarkWrittenBuffer for PR52 selective-copyback preparation' }
$next = $text.IndexOf("`ntemplate <class P>", $start + $functionMarker.Length)
if ($next -lt 0) { throw 'Could not locate end of MarkWrittenBuffer for PR52 preparation' }
$body = $text.Substring($start, $next - $start)
$queue = '    QueueDownload(device_addr, size);'
if (-not $body.Contains($queue)) {
    throw 'PokeDinner selective QueueDownload call missing from MarkWrittenBuffer'
}
$replacement = @'
    QueueDownload(device_addr, size);
    if (Tegra::g_nx2_ampere.load(std::memory_order_relaxed)) {
        Tegra::Nx2MarkGpuWritten(device_addr, size);
    }
'@
$body = $body.Replace($queue, $replacement.TrimEnd("`r", "`n"))
$text = $text.Substring(0, $start) + $body + $text.Substring($next)
Set-Content -Path $path -Value $text -Encoding utf8 -NoNewline
Write-Host 'Prepared PR52 GPU-written page tracking on top of PokeDinner selective copyback.'
