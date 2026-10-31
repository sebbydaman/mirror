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

    # PipelineStats overlaps our geometry-enabled shader environment. Commit all preceding
    # no-commit donor work first so the conflict's "ours" side includes detached environments,
    # async translation and shared shader modules. Resolve only the two expected files and splice
    # the instrumentation by symbol/position, not whitespace-sensitive regexes.
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
            git checkout --ours -- src/video_core/shader_environment.cpp src/video_core/shader_environment.h
            if ($LASTEXITCODE -ne 0) { throw 'Could not preserve integrated shader environment for c404060' }

            $cppPath = 'src/video_core/shader_environment.cpp'
            $cppText = Get-Content $cppPath -Raw
            $statsInclude = '#include "video_core/renderer_vulkan/pipeline_stats.h"'
            if (-not $cppText.Contains($statsInclude)) {
                $memoryInclude = '#include "video_core/memory_manager.h"'
                if (-not $cppText.Contains($memoryInclude)) { throw 'Could not locate PipelineStats include point' }
                $cppText = $cppText.Replace($memoryInclude, "$memoryInclude`n$statsInclude")
            }

            $fnMarker = 'GenericEnvironment::InitializeNativeCode'
            $fnStart = $cppText.IndexOf($fnMarker)
            if ($fnStart -lt 0) { throw 'InitializeNativeCode symbol missing after pre-c404 checkpoint' }
            $fnOpen = $cppText.IndexOf('{', $fnStart)
            if ($fnOpen -lt 0) { throw 'InitializeNativeCode opening brace missing' }
            $signature = $cppText.Substring($fnStart, $fnOpen - $fnStart)
            if (-not $signature.Contains('bool is_compute')) {
                $sigClose = $cppText.LastIndexOf(')', $fnOpen)
                if ($sigClose -lt $fnStart) { throw 'InitializeNativeCode signature terminator missing' }
                $cppText = $cppText.Insert($sigClose, ', bool is_compute')
                $fnOpen = $cppText.IndexOf('{', $fnStart)
            }

            $lowerNeedle = 'lowered = LowerNativeCode(source_header_size);'
            $lowerPos = $cppText.IndexOf($lowerNeedle, $fnOpen)
            if ($lowerPos -lt 0) { throw 'InitializeNativeCode lowering call missing' }
            $timerNeedle = 'Vulkan::PipelineStats::ScopedTimer timer'
            $nextFunction = $cppText.IndexOf('std::shared_ptr<const LoweredNativeCode> GenericEnvironment::LowerNativeCode', $fnOpen)
            if ($nextFunction -lt 0) { $nextFunction = $cppText.Length }
            if ($cppText.IndexOf($timerNeedle, $fnOpen, $nextFunction - $fnOpen) -lt 0) {
                $lineStart = $cppText.LastIndexOf("`n", $lowerPos)
                if ($lineStart -lt 0) { $lineStart = 0 } else { ++$lineStart }
                $timerBlock = @'
        const Vulkan::PipelineStats::ScopedTimer timer{
            is_compute ? Vulkan::PipelineStats::Kind::Compute
                       : Vulkan::PipelineStats::Kind::Graphics,
            Vulkan::PipelineStats::Stage::Lower};
'@
                $cppText = $cppText.Insert($lineStart, $timerBlock.TrimEnd("`r", "`n") + "`n")
            }

            $computeOld = 'InitializeNativeCode(std::move(lowered_native_), 0);'
            $computeNew = 'InitializeNativeCode(std::move(lowered_native_), 0, true);'
            if ($cppText.Contains($computeOld)) {
                $cppText = $cppText.Replace($computeOld, $computeNew)
            } elseif (-not $cppText.Contains($computeNew)) {
                throw 'Could not mark native compute lowering for PipelineStats'
            }
            Set-Content -Path $cppPath -Value $cppText -Encoding utf8 -NoNewline

            $headerPath = 'src/video_core/shader_environment.h'
            $headerText = Get-Content $headerPath -Raw
            $headerMarker = 'InitializeNativeCode'
            $headerStart = $headerText.IndexOf($headerMarker)
            if ($headerStart -lt 0) { throw 'InitializeNativeCode declaration missing' }
            $headerEnd = $headerText.IndexOf(';', $headerStart)
            if ($headerEnd -lt 0) { throw 'InitializeNativeCode declaration terminator missing' }
            $headerDecl = $headerText.Substring($headerStart, $headerEnd - $headerStart)
            if (-not $headerDecl.Contains('bool is_compute')) {
                $headerClose = $headerText.LastIndexOf(')', $headerEnd)
                if ($headerClose -lt $headerStart) { throw 'InitializeNativeCode declaration closing parenthesis missing' }
                $headerText = $headerText.Insert($headerClose, ', bool is_compute = false')
            }
            Set-Content -Path $headerPath -Value $headerText -Encoding utf8 -NoNewline

            git add -A
            git -c user.name='Eden NS2 CI' -c user.email='actions@github.com' commit -m 'CI checkpoint PokeDinner pipeline stats' --no-verify
            if ($LASTEXITCODE -ne 0) { throw 'Could not finalize c404060 PipelineStats merge' }
            Write-Host 'Integrated PipelineStats over geometry + async shader state.'
        }
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

$checks = @{
    'src/video_core/renderer_vulkan/vk_pipeline_cache.cpp' = @('EDEN_NX2_SHADER_REUSE', 'EDEN_NX2_ASYNC_TRANSLATION')
    'src/video_core/renderer_vulkan/vk_rasterizer.cpp' = @('EDEN_NX2_RESETFIX')
    'src/video_core/dma_pusher.cpp' = @('EDEN_NX2_PBFLUSH')
    'src/video_core/renderer_vulkan/vk_texture_cache.cpp' = @('EDEN_NX2_VRAM_LIMIT_MIB')
    'src/video_core/renderer_vulkan/pipeline_stats.h' = @('EDEN_NX2_PIPELINE_STATS')
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
