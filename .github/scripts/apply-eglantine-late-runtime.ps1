$ErrorActionPreference = 'Stop'

# This batch was generated and git-apply --checked against the exact captured integrated source
# after the PokeDinner 2.0 + Bananza/Pokopia + Eglantine read-trap stack. It intentionally ports
# only the late Eglantine semantics that are still missing from that combined tree:
#   * 1051d394: allocate/map sparse GPU-only backing outside the region mutex to avoid a
#     GPU-thread <-> guest page-table deadlock.
#   * missing 2065b143 pieces: account only actually-bound sparse image memory and choose the
#     Switch 2 low-VRAM ASTC policy before texture decoder/view-format setup.
# Most of 2065b143's budget/collector logic is already present in our tree and is not duplicated.

$markers = @(
    @{ Path = 'src/core/hle/service/nx2_gsv.h'; Text = 'struct MappedBacking {' },
    @{ Path = 'src/core/hle/service/nx2_gsv.h'; Text = 'BlockPending = 3' },
    @{ Path = 'src/core/hle/service/nx2_gsv.h'; Text = 'std::condition_variable_any m_region_cv' },
    @{ Path = 'src/common/settings.h'; Text = 'bool CurrentProgramIsSwitch2();' },
    @{ Path = 'src/video_core/renderer_vulkan/vk_texture_cache.cpp'; Text = 'UseBc3ForSwitch2OnSmallCards' },
    @{ Path = 'src/video_core/renderer_vulkan/vk_texture_cache.h'; Text = 'u64 SparseBoundBytes() const noexcept' },
    @{ Path = 'src/video_core/texture_cache/texture_cache.h'; Text = 'u64 TextureCache<P>::ImageMemoryBytes' },
    @{ Path = 'src/video_core/texture_cache/texture_cache.h'; Text = 'TextureCache<P>::BindSparseLayers' }
)

$present = 0
foreach ($marker in $markers) {
    if ((Get-Content $marker.Path -Raw).Contains($marker.Text)) {
        ++$present
    }
}
if ($present -eq $markers.Count) {
    Write-Host 'Late Eglantine runtime batch is already present.'
    exit 0
}
if ($present -ne 0) {
    throw "Partial late-Eglantine runtime state detected ($present/$($markers.Count) markers); refusing a mixed apply"
}

$payload = Join-Path $PSScriptRoot '..\patches\late-eglantine-runtime.patch.gz.b64'
if (-not (Test-Path $payload)) {
    throw "Missing late Eglantine patch payload: $payload"
}

$encoded = (Get-Content $payload -Raw) -replace '\s', ''
$compressed = [Convert]::FromBase64String($encoded)
$input = [IO.MemoryStream]::new($compressed, $false)
$gzip = [IO.Compression.GZipStream]::new($input, [IO.Compression.CompressionMode]::Decompress)
$output = [IO.MemoryStream]::new()
try {
    $gzip.CopyTo($output)
    $patchBytes = $output.ToArray()
} finally {
    $output.Dispose()
    $gzip.Dispose()
    $input.Dispose()
}

$patchPath = Join-Path $env:RUNNER_TEMP 'late-eglantine-runtime.patch'
[IO.File]::WriteAllBytes($patchPath, $patchBytes)

# Fail before mutating the tree if donor assumptions no longer match the exact integrated source.
git apply --check --whitespace=error-all $patchPath
if ($LASTEXITCODE -ne 0) {
    throw 'Late Eglantine runtime patch no longer applies cleanly to the integrated source'
}

git apply --whitespace=error-all $patchPath
if ($LASTEXITCODE -ne 0) {
    throw 'Failed to apply late Eglantine runtime patch'
}

git diff --check
if ($LASTEXITCODE -ne 0) {
    throw 'Late Eglantine runtime patch introduced whitespace/diff errors'
}

foreach ($marker in $markers) {
    if (-not (Get-Content $marker.Path -Raw).Contains($marker.Text)) {
        throw "Late Eglantine runtime validation failed: missing '$($marker.Text)' in $($marker.Path)"
    }
}

# Extra semantic checks: sparse mapping must happen outside the region lock, and ASTC policy must
# be selected in TextureCacheRuntime rather than late in RendererVulkan's constructor body.
$gsv = Get-Content 'src/core/hle/service/nx2_gsv.h' -Raw
if (-not ($gsv.Contains('AllocateGpuOnlyBacking') -and $gsv.Contains('m_region_cv.wait'))) {
    throw 'Late Eglantine sparse-backing deadlock fix is incomplete'
}
$vkTexture = Get-Content 'src/video_core/renderer_vulkan/vk_texture_cache.cpp' -Raw
if (-not $vkTexture.Contains('UseBc3ForSwitch2OnSmallCards(device);')) {
    throw 'Switch 2 ASTC policy is not applied before texture-cache initialization'
}
$renderer = Get-Content 'src/video_core/renderer_vulkan/renderer_vulkan.cpp' -Raw
if ($renderer.Contains('Nx2UncompressedAstcMinimumVram')) {
    throw 'Obsolete late RendererVulkan ASTC override survived the early-policy migration'
}

Write-Host 'Applied validated late Eglantine runtime batch: sparse mapping deadlock fix + precise VRAM accounting/early ASTC policy.'
