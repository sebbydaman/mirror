$ErrorActionPreference = 'Stop'

# Build-158 / build-167 Pokopia regression fix.
# Donor: Djihads80/Eglantine@9f4f01f76e8556941c0c0c3f57edc1d600ed23ea
# Prerequisite donor: 837133792d5651a896bc018f13acd8eaabcd8e81
#
# Build158 assumes 837133 already moved Nx2Map/Nx2Sparse GMMU maps from the
# service thread to GPU::RunInOrder. Our pinned NS2 base predates 837133, so
# compose that prerequisite locally and immediately upgrade it to MapInOrder.
# Nx2SparseTile (216 sparse remap) was added by a later donor commit and is not
# present on every production stack; when present, upgrade its RunInOrder too.

function Read-Text([string]$Path) {
    if (-not (Test-Path $Path -PathType Leaf)) { throw "Missing source file: $Path" }
    return (Get-Content $Path -Raw).Replace("`r`n", "`n")
}

function Write-Text([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText((Resolve-Path $Path), $Text.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
}

function Replace-ExactlyOnce([string]$Path, [string]$Old, [string]$New, [string]$Label) {
    $text = Read-Text $Path
    if ($text.Contains($New)) {
        Write-Host "[PRESENT] $Label"
        return
    }
    $count = ([regex]::Matches($text, [regex]::Escape($Old))).Count
    if ($count -ne 1) {
        throw "$Label anchor count is $count (expected exactly 1) in $Path"
    }
    Write-Text $Path ($text.Replace($Old, $New))
    Write-Host "[APPLIED] $Label"
}

function Insert-AfterExactlyOnce([string]$Path, [string]$Anchor, [string]$Block,
                                 [string]$PresentMarker, [string]$Label) {
    $text = Read-Text $Path
    if ($text.Contains($PresentMarker)) {
        Write-Host "[PRESENT] $Label"
        return
    }
    $count = ([regex]::Matches($text, [regex]::Escape($Anchor))).Count
    if ($count -ne 1) {
        throw "$Label anchor count is $count (expected exactly 1) in $Path"
    }
    $replacement = $Anchor + "`n`n" + $Block.TrimEnd("`r", "`n")
    Write-Text $Path ($text.Replace($Anchor, $replacement))
    Write-Host "[APPLIED] $Label"
}

function Insert-AfterFunctionExactlyOnce([string]$Path, [string]$Signature, [string]$Block,
                                         [string]$PresentMarker, [string]$Label) {
    $text = Read-Text $Path
    if ($text.Contains($PresentMarker)) {
        Write-Host "[PRESENT] $Label"
        return
    }

    $count = ([regex]::Matches($text, [regex]::Escape($Signature))).Count
    if ($count -ne 1) {
        throw "$Label function signature count is $count (expected exactly 1) in $Path"
    }

    $signatureStart = $text.IndexOf($Signature, [StringComparison]::Ordinal)
    $openBrace = $text.IndexOf('{', $signatureStart + $Signature.Length)
    if ($openBrace -lt 0) {
        throw "$Label could not locate opening brace after function signature in $Path"
    }

    $depth = 0
    $closeBrace = -1
    for ($i = $openBrace; $i -lt $text.Length; ++$i) {
        if ($text[$i] -eq '{') {
            ++$depth
        } elseif ($text[$i] -eq '}') {
            --$depth
            if ($depth -eq 0) {
                $closeBrace = $i
                break
            }
        }
    }
    if ($closeBrace -lt 0) {
        throw "$Label could not locate balanced function terminator in $Path"
    }

    $insertion = "`n`n" + $Block.TrimEnd("`r", "`n")
    Write-Text $Path ($text.Insert($closeBrace + 1, $insertion))
    Write-Host "[APPLIED] $Label"
}

$nvPath = 'src/core/hle/service/nvdrv/devices/nvhost_as_gpu.cpp'
$nv = Read-Text $nvPath
$runGmmu = 'system.GPU().RunInOrder([gmmu = gmmu.get(), gpu_address, device_address, size] {'
$mapGmmu = 'system.GPU().MapInOrder([gmmu = gmmu.get(), gpu_address, device_address, size] {'
$directGmmu = '    gmmu->Map(gpu_address, device_address, size, Tegra::PTEKind::PITCH, false);'

$runGmmuCount = ([regex]::Matches($nv, [regex]::Escape($runGmmu))).Count
$mapGmmuCount = ([regex]::Matches($nv, [regex]::Escape($mapGmmu))).Count
$directGmmuCount = ([regex]::Matches($nv, [regex]::Escape($directGmmu))).Count

if ($mapGmmuCount -eq 2 -and $runGmmuCount -eq 0) {
    Write-Host '[PRESENT] Nx2Map/Nx2Sparse already use GPU::MapInOrder'
} elseif ($runGmmuCount -eq 2 -and $mapGmmuCount -eq 0) {
    $nv = $nv.Replace($runGmmu, $mapGmmu)
    Write-Host '[APPLIED] build158 upgrade: Nx2Map/Nx2Sparse RunInOrder -> MapInOrder'
} elseif ($runGmmuCount -eq 0 -and $mapGmmuCount -eq 0 -and $directGmmuCount -eq 2) {
    # Our 01effa/PokeDinner generation predates 837133. Move exactly the two direct
    # GMMU maps (Nx2Map and sparse-region creation) onto the ordered GPU front.
    $queued = @'
    system.GPU().MapInOrder([gmmu = gmmu.get(), gpu_address, device_address, size] {
        gmmu->Map(gpu_address, device_address, size, Tegra::PTEKind::PITCH, false);
    });
'@
    $nv = $nv.Replace($directGmmu, $queued.TrimEnd("`n"))
    Write-Host '[APPLIED] 837133 prerequisite + build158 ordering for two direct GMMU map sites'
} else {
    throw "Unexpected Nx2Map/Nx2Sparse mapping state in ${nvPath}: direct=$directGmmuCount run=$runGmmuCount map=$mapGmmuCount"
}

# Sparse tile remapping arrived after our pinned base. If another integration layer has
# already added it, build158 requires that remap to execute before later command-list reads.
$runSparseTile = 'system.GPU().RunInOrder([&smmu, device, cpu_address, size, asid = session->asid] {'
$mapSparseTile = 'system.GPU().MapInOrder([&smmu, device, cpu_address, size, asid = session->asid] {'
$hasSparseTile = $nv.Contains('void nvhost_as_gpu::Nx2SparseTile(')
$runSparseTileCount = ([regex]::Matches($nv, [regex]::Escape($runSparseTile))).Count
$mapSparseTileCount = ([regex]::Matches($nv, [regex]::Escape($mapSparseTile))).Count
if ($hasSparseTile) {
    if ($mapSparseTileCount -eq 1 -and $runSparseTileCount -eq 0) {
        Write-Host '[PRESENT] Nx2SparseTile already uses GPU::MapInOrder'
    } elseif ($runSparseTileCount -eq 1 -and $mapSparseTileCount -eq 0) {
        $nv = $nv.Replace($runSparseTile, $mapSparseTile)
        Write-Host '[APPLIED] build158 upgrade: Nx2SparseTile RunInOrder -> MapInOrder'
    } else {
        throw "Unexpected Nx2SparseTile mapping state: run=$runSparseTileCount map=$mapSparseTileCount"
    }
} elseif ($runSparseTileCount -ne 0 -or $mapSparseTileCount -ne 0) {
    throw 'Sparse-tile mapping lambda exists without Nx2SparseTile function marker'
} else {
    Write-Host '[SKIP] Nx2SparseTile/216 prerequisite is not present on this production source generation'
}
Write-Text $nvPath $nv

# The integrated production stack can rewrite the RunInOrder body while preserving its API.
# Locate each function structurally and insert after its balanced closing brace rather than
# requiring donor-era body text or neighboring comments to remain byte-for-byte identical.
$gpuImplMap = @'
    void MapInOrder(std::function<void()>&& func) {
        gpu_thread.Run(std::move(func), is_async, true);
    }
'@
Insert-AfterFunctionExactlyOnce 'src/video_core/gpu.cpp' `
    '    void RunInOrder(std::function<void()>&& func)' `
    $gpuImplMap 'gpu_thread.Run(std::move(func), is_async, true);' 'GPU::Impl MapInOrder handoff'

$gpuPublicMap = @'
void GPU::MapInOrder(std::function<void()>&& func) {
    impl->MapInOrder(std::move(func));
}
'@
Insert-AfterFunctionExactlyOnce 'src/video_core/gpu.cpp' `
    'void GPU::RunInOrder(std::function<void()>&& func)' `
    $gpuPublicMap 'void GPU::MapInOrder(std::function<void()>&& func)' 'GPU::MapInOrder implementation'

$gpuHeaderPath = 'src/video_core/gpu.h'
$gpuRunDecl = '    void RunInOrder(std::function<void()>&& func);'
$gpuMapDecl = @'
    /// RunInOrder for GPU memory maps: also done before the GPU thread reads the command lists
    /// submitted later (with the GPU split, on its front rather than its back).
    void MapInOrder(std::function<void()>&& func);
'@
Insert-AfterExactlyOnce $gpuHeaderPath $gpuRunDecl $gpuMapDecl `
    'void MapInOrder(std::function<void()>&& func);' 'GPU::MapInOrder declaration'

$threadCppOld = @'
                } else if (auto* run = std::get_if<RunCommand>(&next.data)) {
                    split.DeferFunction(std::move(run->func));
                } else if (const auto* flush = std::get_if<FlushRegionCommand>(&next.data)) {
'@
$threadCppNew = @'
                } else if (auto* run = std::get_if<RunCommand>(&next.data)) {
                    if (run->before_later_reads) {
                        split.Drain();
                        run->func();
                    } else {
                        split.DeferFunction(std::move(run->func));
                    }
                } else if (const auto* flush = std::get_if<FlushRegionCommand>(&next.data)) {
'@
Replace-ExactlyOnce 'src/video_core/gpu_thread.cpp' $threadCppOld $threadCppNew 'GPU split front-side ordered map execution'

$threadRunOld = @'
void ThreadManager::Run(std::function<void()>&& func, bool is_async) {
    PushCommand(RunCommand{std::move(func)}, false, is_async);
}
'@
$threadRunNew = @'
void ThreadManager::Run(std::function<void()>&& func, bool is_async, bool before_later_reads) {
    PushCommand(RunCommand{std::move(func), before_later_reads}, false, is_async);
}
'@
Replace-ExactlyOnce 'src/video_core/gpu_thread.cpp' $threadRunOld $threadRunNew 'ThreadManager::Run ordered-read flag propagation'

$threadHeader = 'src/video_core/gpu_thread.h'
$header = Read-Text $threadHeader
if (-not $header.Contains('bool before_later_reads{};')) {
    $runStart = $header.IndexOf('struct RunCommand final {')
    if ($runStart -lt 0) { throw 'RunCommand struct marker is missing from gpu_thread.h' }
    $runEnd = $header.IndexOf("};", $runStart)
    if ($runEnd -lt 0) { throw 'RunCommand struct terminator is missing from gpu_thread.h' }
    $block = $header.Substring($runStart, $runEnd + 2 - $runStart)
    $funcNeedle = '    std::function<void()> func;'
    if (([regex]::Matches($block, [regex]::Escape($funcNeedle))).Count -ne 1) {
        throw 'RunCommand function field changed; refusing speculative gpu_thread.h edit'
    }
    $funcReplacement = @'
    std::function<void()> func;
    /// With the GPU split, run on its front (after draining the back) instead of deferring to the
    /// back, so command lists read after this one see what func did (GMMU maps).
    bool before_later_reads{};
'@
    $newBlock = $block.Replace($funcNeedle, $funcReplacement.TrimEnd("`n"))
    $header = $header.Remove($runStart, $block.Length).Insert($runStart, $newBlock)
    Write-Text $threadHeader $header
    Write-Host '[APPLIED] RunCommand before_later_reads state while preserving local struct fields'
} else {
    Write-Host '[PRESENT] RunCommand before_later_reads state'
}

$threadDeclOld = '    void Run(std::function<void()>&& func, bool is_async);'
$threadDeclNew = '    void Run(std::function<void()>&& func, bool is_async, bool before_later_reads = false);'
Replace-ExactlyOnce $threadHeader $threadDeclOld $threadDeclNew 'ThreadManager::Run declaration with ordered-read flag'

& (Join-Path $PSScriptRoot 'test-build158-map-in-order.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Build158 MapInOrder invariant test failed' }

git diff --check
if ($LASTEXITCODE -ne 0) { throw 'Build158 MapInOrder adapter introduced diff/whitespace errors' }

Write-Host '[PASS] Build158/167 Pokopia MapInOrder semantics applied without replacing current GPU-split state.'
