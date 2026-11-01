$ErrorActionPreference = 'Stop'

# Our PR157 adaptation caches a raw host pointer for a contiguous live pushbuffer span. The donor
# invalidates it at submission/safe-read boundaries, but a GMMU map/unmap between uses can change
# the backing while the GPU virtual address stays identical. Add an even/odd mapping epoch:
#   even = stable mapping state, odd = map/unmap mutation in progress.
# A cached span is retained only when translation begins and ends in the same stable epoch.
$markers = @(
    @{ Path = 'src/video_core/memory_manager.h'; Text = 'u64 MappingGeneration() const noexcept' },
    @{ Path = 'src/video_core/memory_manager.h'; Text = 'std::atomic<u64> mapping_generation{0};' },
    @{ Path = 'src/video_core/memory_manager.cpp'; Text = 'class MappingGenerationWrite' },
    @{ Path = 'src/video_core/dma_pusher.h'; Text = 'u64 pb_cached_mapping_generation{~u64{0}};' },
    @{ Path = 'src/video_core/dma_pusher.cpp'; Text = 'const bool mapping_stable = (mapping_generation & 1) == 0;' },
    @{ Path = 'src/video_core/dma_pusher.cpp'; Text = 'if (after_translation == mapping_generation)' }
)
$present = 0
foreach ($marker in $markers) {
    if ((Test-Path $marker.Path -PathType Leaf) -and (Get-Content $marker.Path -Raw).Contains($marker.Text)) {
        ++$present
    }
}
if ($present -eq $markers.Count) {
    Write-Host '[PRESENT] GMMU mapping-generation guard for pushbuffer span cache'
    exit 0
}
if ($present -ne 0) {
    throw "Partial pushbuffer mapping-generation hardening detected ($present/$($markers.Count)); refusing mixed apply"
}

$encoded = @'
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
'@
$encoded = $encoded -replace '\s', ''
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

$patchPath = Join-Path $env:RUNNER_TEMP 'ns2-pushbuffer-mapgen-hardening.patch'
[IO.File]::WriteAllBytes($patchPath, $patchBytes)
git apply --check --whitespace=error-all $patchPath
if ($LASTEXITCODE -ne 0) { throw 'Pushbuffer mapping-generation hardening no longer applies to the final frontier source' }
git apply --whitespace=error-all $patchPath
if ($LASTEXITCODE -ne 0) { throw 'Failed to apply pushbuffer mapping-generation hardening' }
git diff --check
if ($LASTEXITCODE -ne 0) { throw 'Pushbuffer mapping-generation hardening introduced diff errors' }

foreach ($marker in $markers) {
    if (-not (Get-Content $marker.Path -Raw).Contains($marker.Text)) {
        throw "Pushbuffer mapping-generation validation failed: missing '$($marker.Text)' in $($marker.Path)"
    }
}
Write-Host '[APPLIED] GMMU mapping-generation guard for pushbuffer span cache'
