$ErrorActionPreference = 'Stop'

# PokeDinner 2.0 source batch (release commit 70ecb39ef0). Keep the large correctness/performance
# group together so one expensive Windows compile validates the whole runtime set. FSR3/frame-gen
# remains deliberately separate from core emulation correctness.
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

    # Eglantine's sparse/per-layer ASTC util.cpp diverges from f285120. Port only the donor's
    # native-tiling semantics instead of choosing one whole-file implementation over the other.
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
            Write-Host 'Eglantine ASTC path no longer uses the donor legacy layer-offset expression; preserving newer implementation.'
        }
        Set-Content -Path $utilPath -Value $utilText -Encoding utf8 -NoNewline

        $cmakePath = 'src/CMakeLists.txt'
        $cmakeText = Get-Content $cmakePath -Raw
        $cmakeText = [regex]::Replace($cmakeText, '(?m)^\s*/we4388.*\r?\n', '')
        $cmakeText = [regex]::Replace($cmakeText, '(?m)^\s*/we4389.*\r?\n', '')
        Set-Content -Path $cmakePath -Value $cmakeText -Encoding utf8 -NoNewline
        Write-Host 'Ported f285120 native-tiling semantics over Eglantine ASTC.'
        continue
    }

    # 01effa already removed the guessed Switch 2 image-size multiplier.
    if ($commit -eq 'ba11b6d3990920c63cca4dbe1b95e2b08cca22bd') {
        $gsvText = Get-Content 'src/core/hle/service/nx2_gsv.h' -Raw
        if (-not $gsvText.Contains('layout.size *= u64{preference[6]} * preference[7];')) {
            Write-Host 'ba11b6d semantics already present on Eglantine.'
            continue
        }
    }

    # PipelineStats overlaps our geometry-enabled shader environment. Take the donor pair as a
    # coherent unit after checkpointing the async/shared-module state, then restore our stricter
    # native-geometry admission and diagnostics on top.
    if ($commit -eq 'c404060104d2fcc3e4e17bd89c1d964cddf03348') {
        git add -A
        if (git status --porcelain) {
            git -c user.name='Eden NS2 CI' -c user.email='actions@github.com' commit -m 'CI checkpoint before PokeDinner pipeline stats' --no-verify
            if ($LASTEXITCODE -ne 0) { throw 'Could not checkpoint PokeDinner batch before PipelineStats' }
        }

        git cherry-pick --no-commit $commit
        if ($LASTEXITCODE -ne 0) {
            $conflicts = @(git diff --name-only --diff-filter=U)
            $expected = @('src/video_core/shader_environment.cpp', 'src/video_core/shader_environment.h')
            $unexpected = @($conflicts | Where-Object { $_ -notin $expected })
            if ($unexpected.Count -gt 0 -or $conflicts.Count -eq 0) {
                git cherry-pick --abort 2>$null
                throw "Unexpected c404060 conflict surface: $($conflicts -join ', ')"
            }
            git checkout --theirs -- src/video_core/shader_environment.cpp src/video_core/shader_environment.h
            if ($LASTEXITCODE -ne 0) { throw 'Could not select PokeDinner c404 shader-environment pair' }
        }

        & (Join-Path $PSScriptRoot 'apply-ns2-geometry-stage.ps1')
        if ($LASTEXITCODE -ne 0) { throw 'Could not restore validated native geometry semantics after c404' }
        git add -A
        git -c user.name='Eden NS2 CI' -c user.email='actions@github.com' commit -m 'CI checkpoint PokeDinner pipeline stats' --no-verify
        if ($LASTEXITCODE -ne 0) { throw 'Could not finalize c404060 PipelineStats merge' }
        Write-Host 'Integrated PipelineStats with PokeDinner async shader state and validated geometry semantics.'
        continue
    }

    # 2d53 widens uniform-arithmetic execution predicates to support UPn/!UPn. Port only that
    # semantic gate so our independent native lowering extensions remain intact, then checkpoint
    # because later donor commits touch the same header.
    if ($commit -eq '2d53aac0a1e1a6de56b9c27903149340b10e9a9f') {
        $amperePath = 'src/shader_recompiler/frontend/ampere/lower_to_maxwell.h'
        $ampereText = Get-Content $amperePath -Raw
        if (-not $ampereText.Contains('native inverted uniform true predicate')) {
            $predicatePattern = '(?m)^            if \(insn\.Bits\(12, 4\) != 7 && opcode != 0x292 && (?:opcode != 0x092 && )?opcode != 0x892\)\r?\n                return fail\(index, "native uniform arithmetic predication"\);'
            $predicateReplacement = @'
            // Any UPn/!UPn execution predicate, including the inverted ones (0xd = !UP5): the
            // guard machinery below swaps UPn into P(6-n). Only !UPT has no slot.
            if (opcode != 0x292 && opcode != 0x092 && opcode != 0x892 &&
                (insn.Bits(12, 4) & 7) == 7 && insn.Bits(12, 4) != 7)
                return fail(index, "native inverted uniform true predicate");
'@
            $newAmpereText = [regex]::Replace($ampereText, $predicatePattern,
                $predicateReplacement.TrimEnd("`r", "`n"), 1)
            if ($newAmpereText -eq $ampereText) { throw 'Could not locate uniform arithmetic predicate gate for 2d53aac' }
            Set-Content -Path $amperePath -Value $newAmpereText -Encoding utf8 -NoNewline
        }
        git add -A
        git -c user.name='Eden NS2 CI' -c user.email='actions@github.com' commit -m 'CI checkpoint PokeDinner shader reuse and uniform predicates' --no-verify
        if ($LASTEXITCODE -ne 0) { throw 'Could not checkpoint shader state after 2d53aac' }
        Write-Host 'Ported 2d53aac inverted uniform predicate support and checkpointed shader state.'
        continue
    }

    # 5116272 is the large Pokopia invisible-items/preview-shader fix. Its lower_to_maxwell.h
    # includes all prerequisite donor predicate/atomic changes, but collides with our TEX.B/TXQ/
    # BRX/geometry extensions. Checkpoint 303b20 first, take the donor shader file as the coherent
    # Pokopia implementation, then reapply our four native-lowering overlays with a reusable script.
    if ($commit -eq '5116272a17388d7c0f2ce51f295df01628e89032') {
        git add -A
        if (git status --porcelain) {
            git -c user.name='Eden NS2 CI' -c user.email='actions@github.com' commit -m 'CI checkpoint before Pokopia guarded uniforms' --no-verify
            if ($LASTEXITCODE -ne 0) { throw 'Could not checkpoint atomic-range fix before Pokopia guarded uniforms' }
        }

        git cherry-pick --no-commit $commit
        if ($LASTEXITCODE -ne 0) {
            $conflicts = @(git diff --name-only --diff-filter=U)
            $expected = @('src/shader_recompiler/frontend/ampere/lower_to_maxwell.h')
            $unexpected = @($conflicts | Where-Object { $_ -notin $expected })
            if ($unexpected.Count -gt 0 -or $conflicts.Count -eq 0) {
                git cherry-pick --abort 2>$null
                throw "Unexpected 5116272 Pokopia conflict surface: $($conflicts -join ', ')"
            }
            git checkout --theirs -- src/shader_recompiler/frontend/ampere/lower_to_maxwell.h
            if ($LASTEXITCODE -ne 0) { throw 'Could not select PokeDinner Pokopia native-lowering implementation' }
        }

        & (Join-Path $PSScriptRoot 'apply-ns2-native-lowering-overlays.ps1')
        if ($LASTEXITCODE -ne 0) { throw 'Could not restore native lowering overlays after 5116272' }
        git add -A
        git -c user.name='Eden NS2 CI' -c user.email='actions@github.com' commit -m 'CI checkpoint Pokopia guarded uniform shaders' --no-verify
        if ($LASTEXITCODE -ne 0) { throw 'Could not finalize 5116272 Pokopia shader merge' }
        Write-Host 'Integrated Pokopia guarded uniform shaders while preserving TEX.B/TXQ/BRX/geometry overlays.'
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

# High-value regression needles before we pay for the long Windows compile.
$checks = @{
    'src/video_core/renderer_vulkan/vk_pipeline_cache.cpp' = @('EDEN_NX2_SHADER_REUSE', 'EDEN_NX2_ASYNC_TRANSLATION')
    'src/video_core/renderer_vulkan/vk_rasterizer.cpp' = @('EDEN_NX2_RESETFIX')
    'src/video_core/dma_pusher.cpp' = @('EDEN_NX2_PBFLUSH')
    'src/video_core/renderer_vulkan/vk_texture_cache.cpp' = @('EDEN_NX2_VRAM_LIMIT_MIB')
    'src/video_core/renderer_vulkan/pipeline_stats.h' = @('EDEN_NX2_PIPELINE_STATS')
    'src/video_core/shader_environment.cpp' = @('const bool native_geometry = program == Maxwell::ShaderType::Geometry;', 'Vulkan::PipelineStats')
    'src/shader_recompiler/frontend/ampere/lower_to_maxwell.h' = @(
        'native inverted uniform true predicate',
        'checked_guard',
        'UIMAD.X carries in UPn',
        'UISETP, signed (bit 73) or unsigned, combined',
        'case 0x361: { // TEX.B, scalar bindless 2D/cube implicit-LOD sample',
        'TXQ texture dimensions, packed X/Y/Z/mip-count outputs',
        'Captured BRX / BRXU with native-PC jump-table values',
        'OUT, immediate geometry stream: EMIT / EMIT_THEN_CUT'
    )
}
foreach ($path in $checks.Keys) {
    if (-not (Test-Path $path)) { throw "PokeDinner 2.0 regression: missing $path" }
    $text = Get-Content $path -Raw
    foreach ($needle in $checks[$path]) {
        if (-not $text.Contains($needle)) { throw "PokeDinner 2.0 regression: $path missing $needle" }
    }
}
Write-Host "PokeDinner 2.0 batch applied: $($commits.Count) commits in one runtime integration pass."
