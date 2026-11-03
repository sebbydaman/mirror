$ErrorActionPreference = 'Stop'

# Build-158 / build-167 Pokopia regression fix.
# Donor: Djihads80/Eglantine@9f4f01f76e8556941c0c0c3f57edc1d600ed23ea
#
# The donor makes GMMU maps execute on the GPU split front, after draining the back,
# before later command lists are read.  The clean transplant probe showed only
# gpu_thread.h overlaps our integrated stack, so apply the donor semantics directly
# and fail closed if any of the expected anchors have drifted.

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

$nvPath = 'src/core/hle/service/nvdrv/devices/nvhost_as_gpu.cpp'
$nv = Read-Text $nvPath
$oldMapCalls = @(
    'system.GPU().RunInOrder([gmmu = gmmu.get(), gpu_address, device_address, size] {',
    'system.GPU().RunInOrder([&smmu, device, cpu_address, size, asid = session->asid] {'
)
$newMapCalls = @(
    'system.GPU().MapInOrder([gmmu = gmmu.get(), gpu_address, device_address, size] {',
    'system.GPU().MapInOrder([&smmu, device, cpu_address, size, asid = session->asid] {'
)
$oldGmmu = ([regex]::Matches($nv, [regex]::Escape($oldMapCalls[0]))).Count
$newGmmu = ([regex]::Matches($nv, [regex]::Escape($newMapCalls[0]))).Count
$oldSparseTile = ([regex]::Matches($nv, [regex]::Escape($oldMapCalls[1]))).Count
$newSparseTile = ([regex]::Matches($nv, [regex]::Escape($newMapCalls[1]))).Count
if ($newGmmu -eq 2 -and $newSparseTile -eq 1 -and $oldGmmu -eq 0 -and $oldSparseTile -eq 0) {
    Write-Host '[PRESENT] three NX2 map paths already use GPU::MapInOrder'
} elseif ($oldGmmu -eq 2 -and $oldSparseTile -eq 1 -and $newGmmu -eq 0 -and $newSparseTile -eq 0) {
    $nv = $nv.Replace($oldMapCalls[0], $newMapCalls[0]).Replace($oldMapCalls[1], $newMapCalls[1])
    Write-Text $nvPath $nv
    Write-Host '[APPLIED] Nx2Map/Nx2Sparse/Nx2SparseTile now use GPU::MapInOrder'
} else {
    throw "Unexpected partial MapInOrder state in ${nvPath}: oldGmmu=$oldGmmu newGmmu=$newGmmu oldSparseTile=$oldSparseTile newSparseTile=$newSparseTile"
}

$gpuImplOld = @'
    void RunInOrder(std::function<void()>&& func) {
        gpu_thread.Run(std::move(func), is_async);
    }

    /// Notify rasterizer that any caches of the specified region should be flushed to Switch memory
'@
$gpuImplNew = @'
    void RunInOrder(std::function<void()>&& func) {
        gpu_thread.Run(std::move(func), is_async);
    }

    void MapInOrder(std::function<void()>&& func) {
        gpu_thread.Run(std::move(func), is_async, true);
    }

    /// Notify rasterizer that any caches of the specified region should be flushed to Switch memory
'@
Replace-ExactlyOnce 'src/video_core/gpu.cpp' $gpuImplOld $gpuImplNew 'GPU::Impl MapInOrder handoff'

$gpuPublicOld = @'
void GPU::RunInOrder(std::function<void()>&& func) {
    impl->RunInOrder(std::move(func));
}

void GPU::InvalidateRegion(DAddr addr, u64 size, bool preserve_gpu_writes) {
'@
$gpuPublicNew = @'
void GPU::RunInOrder(std::function<void()>&& func) {
    impl->RunInOrder(std::move(func));
}

void GPU::MapInOrder(std::function<void()>&& func) {
    impl->MapInOrder(std::move(func));
}

void GPU::InvalidateRegion(DAddr addr, u64 size, bool preserve_gpu_writes) {
'@
Replace-ExactlyOnce 'src/video_core/gpu.cpp' $gpuPublicOld $gpuPublicNew 'GPU::MapInOrder implementation'

$gpuHeaderOld = @'
    /// Runs func on the GPU thread after the command lists submitted so far.
    void RunInOrder(std::function<void()>&& func);

    /// Notify rasterizer that any caches of the specified region should be invalidated
'@
$gpuHeaderNew = @'
    /// Runs func on the GPU thread after the command lists submitted so far.
    void RunInOrder(std::function<void()>&& func);

    /// RunInOrder for GPU memory maps: also done before the GPU thread reads the command lists
    /// submitted later (with the GPU split, on its front rather than its back).
    void MapInOrder(std::function<void()>&& func);

    /// Notify rasterizer that any caches of the specified region should be invalidated
'@
Replace-ExactlyOnce 'src/video_core/gpu.h' $gpuHeaderOld $gpuHeaderNew 'GPU::MapInOrder declaration'

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
