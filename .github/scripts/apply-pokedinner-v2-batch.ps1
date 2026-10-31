$ErrorActionPreference = 'Stop'

# PokeDinner 2.0 source batch (release commit 70ecb39ef0).
# Apply a deliberately curated set of correctness + measured shader-performance changes
# in one integration pass so CI validates them together instead of spending one long Windows
# build per tiny upstream fix. FSR3/frame-generation is intentionally excluded from this batch:
# it is a large presentation feature and should not be mixed with core emulation correctness.

$donorUrl = 'https://github.com/Apollo422/PokeDinner.git'
$donorRemote = 'pokedinner-v2'

if (-not (git remote | Select-String -SimpleMatch $donorRemote)) {
    git remote add $donorRemote $donorUrl
}

git fetch --no-tags --depth=96 $donorRemote master
if ($LASTEXITCODE -ne 0) { throw 'Could not fetch PokeDinner 2.0 donor history' }

$commits = @(
    '9abbf8296d0c8e3d8234047db9247fa96b8738d2',
    'f42b9186ca1110722b396206e0af55f13818dd79',
    '78bc9aa114c339dcc017c41c15831bddb63d99f0',
    '07c017f1d3c71c8da579909dfa31cf2ac4ac207f',
    '5a9573121ec99a63e7c842df09cbbcd499143515',
    '76df4591a7474c5f775ae4b60eaadd7602804acc',
    'f2851204978e2cd66123fef27487fe5718f587fa',
    'ba11b6d3990920c63cca4dbe1b95e2b08cca22bd',
    '800f7feaf6fd0897fa07bb2370e0f557554c1ddc',
    'a3c4ce20a109658c570e686d812da0232ea27b7c',
    'ce9686500660a478562e49971eaeaa1bf4661ef7',
    '981247484fe1c5e7fe513ebef4e16b3af483398f',
    '8b32fcb6298b3caf825df70dca26f4a6e947ed89',
    '692780fab92c07e18d57af72adcddd725cdbfd59',
    '2b1eda0eb1e0f505db2307625c682ee16b4ef091',
    '6d8f95f08e4dc214bdc686c0440776878dc6b5bb',
    '9a876a744e1dcd92b6d0bd884cfbf68e0633fe2c',
    '452dc27367e4396fb8969368c70ce4403b905fbf',
    'c404060104d2fcc3e4e17bd89c1d964cddf03348',
    'b59fd995b708b272d477ca29698f31394b97d834',
    'bbdc15f650d8a40929ea86d1a2ecd2f97cabae09',
    '2d53aac0a1e1a6de56b9c27903149340b10e9a9f',
    '303b20eb5c290df6623ac25ff83d1ef79945b174',
    '5116272a17388d7c0f2ce51f295df01628e89032',
    '0b31adfe7d71d9b4acd9130d0966933bbdbff515',
    '91ec32e6681831eb2e9cd5988fe5392cea394c46',
    '06c9f77a59f159524103a7c67f4438e247cd05d0',
    'c3be47da94e4916dd02454b2d8f86b78301bbde0',
    '73f25533ade27874bec02d0bfa171802e7be7a63',
    'fdb3d904478fc546eb36a0416ff4c1e0ed6e6dcb',
    '70ecb39ef0383eec95f8e1bc11c39f7f4dd9e4b2'
)

foreach ($commit in $commits) {
    Write-Host "Applying PokeDinner 2.0 commit $commit"

    if ($commit -eq 'f2851204978e2cd66123fef27487fe5718f587fa') {
        $utilPath = 'src/video_core/texture_cache/util.cpp'
        $utilText = Get-Content $utilPath -Raw
        $includeNeedle = '#include "video_core/texture_cache/formatter.h"'
        $includeLine = '#include "video_core/texture_cache/image_info.h"'
        if (-not $utilText.Contains($includeLine)) {
            if (-not $utilText.Contains($includeNeedle)) { throw 'Could not locate texture-cache image_info include point' }
            $utilText = $utilText.Replace($includeNeedle, "$includeNeedle`n$includeLine")
        }
        $oldInfo = 'const ImageInfo info{config};'
        $newInfo = 'const ImageInfo info{TextureViewHeader(config, gpu_memory.UsesNativeTiling())};'
        if ($utilText.Contains($oldInfo)) {
            $utilText = $utilText.Replace($oldInfo, $newInfo)
        } elseif (-not $utilText.Contains($newInfo)) {
            throw 'Could not locate IsValidEntry ImageInfo construction for native tiling fix'
        }
        $oldLayer = 'const u64 segment_begin = u64{layer} * layer_stride + level_offset;'
        $newLayer = 'const u64 segment_begin = static_cast<u64>(layer) * layer_stride + level_offset;'
        if ($utilText.Contains($oldLayer)) {
            $utilText = $utilText.Replace($oldLayer, $newLayer)
        } elseif ($utilText.Contains($newLayer)) {
            Write-Host 'Per-layer offset cast from f285120 is already present.'
        } else {
            Write-Host 'Eglantine ASTC path no longer uses f285120 legacy layer-offset expression; preserving newer implementation.'
        }
        Set-Content -Path $utilPath -Value $utilText -Encoding utf8 -NoNewline
        $cmakePath = 'src/CMakeLists.txt'
        $cmakeText = Get-Content $cmakePath -Raw
        $cmakeText = [regex]::Replace($cmakeText, '(?m)^\s*/we4388.*\r?\n', '')
        $cmakeText = [regex]::Replace($cmakeText, '(?m)^\s*/we4389.*\r?\n', '')
        Set-Content -Path $cmakePath -Value $cmakeText -Encoding utf8 -NoNewline
        Write-Host 'Ported f285120 native-tiling view header semantics over Eglantine sparse/ASTC util.cpp.'
        continue
    }

    # Eglantine 01effa already removed the guessed preference[6]*preference[7] image-size
    # multiplier that ba11b6d removes. Detect the desired end state and skip the redundant
    # donor cherry-pick instead of treating an already-fixed newer base as a merge failure.
    if ($commit -eq 'ba11b6d3990920c63cca4dbe1b95e2b08cca22bd') {
        $gsvPath = 'src/core/hle/service/nx2_gsv.h'
        $gsvText = Get-Content $gsvPath -Raw
        if (-not $gsvText.Contains('layout.size *= u64{preference[6]} * preference[7];')) {
            Write-Host 'ba11b6d semantics already present: guessed NX2 image-size multiplier is absent.'
            continue
        }
    }

    git cherry-pick --no-commit $commit
    if ($LASTEXITCODE -ne 0) {
        $conflicts = @(git diff --name-only --diff-filter=U)
        git cherry-pick --abort 2>$null
        if ($conflicts.Count -gt 0) {
            throw "PokeDinner 2.0 batch conflict at $commit in: $($conflicts -join ', ')"
        }
        throw "PokeDinner 2.0 batch could not apply $commit"
    }
}

$checks = @{
    'src/video_core/renderer_vulkan/vk_pipeline_cache.cpp' = @('EDEN_NX2_SHADER_REUSE', 'EDEN_NX2_ASYNC_TRANSLATION')
    'src/video_core/renderer_vulkan/vk_rasterizer.cpp' = @('EDEN_NX2_RESETFIX')
    'src/video_core/dma_pusher.cpp' = @('EDEN_NX2_PBFLUSH')
    'src/video_core/renderer_vulkan/vk_texture_cache.cpp' = @('EDEN_NX2_VRAM_LIMIT_MIB')
    'src/shader_recompiler/frontend/ampere/lower_to_maxwell.h' = @('UISETP', 'IMAD.X')
}
foreach ($path in $checks.Keys) {
    if (-not (Test-Path $path)) { throw "PokeDinner 2.0 regression: missing $path" }
    $text = Get-Content $path -Raw
    foreach ($needle in $checks[$path]) {
        if (-not $text.Contains($needle)) { throw "PokeDinner 2.0 regression: $path missing $needle" }
    }
}

Write-Host "PokeDinner 2.0 batch applied: $($commits.Count) commits in one runtime integration pass."
