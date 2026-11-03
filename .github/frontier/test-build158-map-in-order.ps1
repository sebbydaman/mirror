$ErrorActionPreference = 'Stop'

function Need([string]$Path, [string]$Text, [string]$Label) {
    if (-not (Test-Path $Path -PathType Leaf)) { throw "Missing $Path for $Label" }
    $content = (Get-Content $Path -Raw).Replace("`r`n", "`n")
    if (-not $content.Contains($Text)) { throw "Missing invariant: $Label" }
    Write-Host "[PASS] $Label"
}

function Need-Count([string]$Path, [string]$Text, [int]$Expected, [string]$Label) {
    $content = (Get-Content $Path -Raw).Replace("`r`n", "`n")
    $count = ([regex]::Matches($content, [regex]::Escape($Text))).Count
    if ($count -ne $Expected) { throw "$Label count=$count expected=$Expected" }
    Write-Host "[PASS] $Label ($count)"
}

Need-Count 'src/core/hle/service/nvdrv/devices/nvhost_as_gpu.cpp' `
    'system.GPU().MapInOrder([gmmu = gmmu.get(), gpu_address, device_address, size] {' 2 `
    'Nx2Map and Nx2Sparse use MapInOrder'
Need-Count 'src/core/hle/service/nvdrv/devices/nvhost_as_gpu.cpp' `
    'system.GPU().MapInOrder([&smmu, device, cpu_address, size, asid = session->asid] {' 1 `
    'Nx2SparseTile uses MapInOrder'

Need 'src/video_core/gpu.h' 'void MapInOrder(std::function<void()>&& func);' `
    'GPU exposes MapInOrder'
Need 'src/video_core/gpu.cpp' 'gpu_thread.Run(std::move(func), is_async, true);' `
    'GPU MapInOrder selects front-side ordered flag'
Need 'src/video_core/gpu.cpp' 'void GPU::MapInOrder(std::function<void()>&& func)' `
    'GPU MapInOrder public implementation'

Need 'src/video_core/gpu_thread.h' 'bool before_later_reads{};' `
    'RunCommand carries before_later_reads state'
Need 'src/video_core/gpu_thread.h' `
    'void Run(std::function<void()>&& func, bool is_async, bool before_later_reads = false);' `
    'ThreadManager Run keeps legacy callers default-compatible'
Need 'src/video_core/gpu_thread.cpp' 'if (run->before_later_reads) {' `
    'GPU split distinguishes mapping-order commands'
Need 'src/video_core/gpu_thread.cpp' 'split.Drain();' `
    'ordered map drains deferred GPU back work first'
Need 'src/video_core/gpu_thread.cpp' 'run->func();' `
    'ordered map executes on split front before later reads'
Need 'src/video_core/gpu_thread.cpp' `
    'PushCommand(RunCommand{std::move(func), before_later_reads}, false, is_async);' `
    'ordered-read flag reaches RunCommand queue entry'
Need 'src/video_core/gpu_thread.cpp' 'split.DeferFunction(std::move(run->func));' `
    'ordinary RunInOrder work remains deferred to GPU back'

# The three map sites must no longer use the old ordering path.
$nv = (Get-Content 'src/core/hle/service/nvdrv/devices/nvhost_as_gpu.cpp' -Raw).Replace("`r`n", "`n")
if ($nv.Contains('system.GPU().RunInOrder([gmmu = gmmu.get(), gpu_address, device_address, size] {') -or
    $nv.Contains('system.GPU().RunInOrder([&smmu, device, cpu_address, size, asid = session->asid] {')) {
    throw 'Obsolete RunInOrder mapping path remains after MapInOrder adapter'
}
Write-Host '[PASS] obsolete mapping RunInOrder calls removed'

Write-Host '[PASS] Build158/167 MapInOrder source invariants are complete.'
