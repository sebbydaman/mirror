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

# All selected commits are recent descendants on the public PokeDinner master lineage.
git fetch --no-tags --depth=96 $donorRemote master
if ($LASTEXITCODE -ne 0) { throw 'Could not fetch PokeDinner 2.0 donor history' }

$commits = @(
    # Correctness / memory / texture-cache foundations.
    '9abbf8296d0c8e3d8234047db9247fa96b8738d2', # pooled shader objects run destructors
    'f42b9186ca1110722b396206e0af55f13818dd79', # main-heap VRAM thresholds / unbacked images
    '78bc9aa114c339dcc017c41c15831bddb63d99f0', # nx2_switches.txt runtime controls
    '07c017f1d3c71c8da579909dfa31cf2ac4ac207f', # FSEL modifiers + array-cube vector samples
    '5a9573121ec99a63e7c842df09cbbcd499143515', # DK GPU-written macro parameter flush
    '76df4591a7474c5f775ae4b60eaadd7602804acc', # DK indirect-draw reset stores
    'f2851204978e2cd66123fef27487fe5718f587fa', # native tiling view header correctness
    'ba11b6d3990920c63cca4dbe1b95e2b08cca22bd', # remove guessed NX2 image-size multiplier
    '800f7feaf6fd0897fa07bb2370e0f557554c1ddc', # MKW R0 RET/text correctness

    # Measured shader-recompiler / pipeline hot-path series. These preserve emitted SPIR-V
    # while cutting first-use translation work and allow native graphics translation off-thread.
    'a3c4ce20a109658c570e686d812da0232ea27b7c', # drop unused SSA identities
    'ce9686500660a478562e49971eaeaa1bf4661ef7', # prune repeated failed storage searches
    '981247484fe1c5e7fe513ebef4e16b3af483398f', # block-local predicate/flag SSA defs
    '8b32fcb6298b3caf825df70dca26f4a6e947ed89', # scalar SPIR-V constant id cache
    '692780fab92c07e18d57af72adcddd725cdbfd59', # CFG visited-block lookup
    '2b1eda0eb1e0f505db2307625c682ee16b4ef091', # create sealed-block phis only when needed
    '6d8f95f08e4dc214bdc686c0440776878dc6b5bb', # detach graphics shader environments
    '9a876a744e1dcd92b6d0bd884cfbf68e0633fe2c', # async native graphics translation workers
    '452dc27367e4396fb8969368c70ce4403b905fbf', # share shader modules between pipelines
    'c404060104d2fcc3e4e17bd89c1d964cddf03348', # pipeline timing/stats infrastructure
    'b59fd995b708b272d477ca29698f31394b97d834', # translated shader reuse across pipelines

    # Later 2.0 gameplay correctness fixes.
    'bbdc15f650d8a40929ea86d1a2ecd2f97cabae09', # LEA.HI constant base + carry
    '2d53aac0a1e1a6de56b9c27903149340b10e9a9f', # inverted uniform predicates
    '303b20eb5c290df6623ac25ff83d1ef79945b174', # reject unencodable atomic offset
    '5116272a17388d7c0f2ce51f295df01628e89032', # Pokopia guarded uniform arithmetic/predicates
    '0b31adfe7d71d9b4acd9130d0966933bbdbff515', # sign-LOD gradient texture
    '91ec32e6681831eb2e9cd5988fe5392cea394c46', # MKW end-of-stream fence / GP black screen
    '06c9f77a59f159524103a7c67f4438e247cd05d0', # unmapped WalkBlock stale-run fix
    'c3be47da94e4916dd02454b2d8f86b78301bbde0', # selective CPU-read buffer copyback / held writes
    '73f25533ade27874bec02d0bfa171802e7be7a63', # backend PendingSemaphoreRelease interface
    'fdb3d904478fc546eb36a0416ff4c1e0ed6e6dcb', # TLD4 .PTP per-texel offsets
    '70ecb39ef0383eec95f8e1bc11c39f7f4dd9e4b2'  # clear sparse-region state between games
)

foreach ($commit in $commits) {
    Write-Host "Applying PokeDinner 2.0 commit $commit"

    # f285120 overlaps Eglantine's newer sparse/per-layer ASTC util.cpp. The donor change itself
    # is small and independent, so port the three semantic edits directly instead of accepting
    # either side of a whole-file cherry-pick conflict. This preserves both the Eglantine ASTC
    # work and PokeDinner's native-tiling view-size correctness.
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
        } elseif (-not $utilText.Contains($newLayer)) {
            throw 'Could not locate per-layer segment offset cast for native tiling fix'
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

# High-value regression needles. The full compile remains authoritative, but these make it
# obvious if a later local patch silently removes a 2.0 feature before a 40+ minute build.
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
