$ErrorActionPreference = 'Stop'
# Narrow Orchid-specific lifetime fix for same-start GPU-only 214 region replacements.
# Real MKW log: repeated 214 memory backing, 0x16ad80000 / 0x5ad80000 failures.
# Source comparison: Lichii build70@286117c7e0d89ab0384e896489128fdd88a424f8
# records MKW 300 MiB -> 600 MiB -> 1 GiB repeated same GPU-address regions.
# Keep Orchid's own deferred-release callback and memory-accounting semantics.
$path = 'src/core/hle/service/nx2_gsv.h'
if (-not (Test-Path $path -PathType Leaf)) { throw "Missing pinned Orchid service: $path" }
$crlf = [string][char]13 + [string][char]10
$lf = [string][char]10
$raw = [IO.File]::ReadAllText((Resolve-Path $path).Path).Replace($crlf, $lf)
$old = @'
    // Records a mapped backing for the region at gpu_address. Needs m_region_mutex.
    void RegisterGpuOnlyBacking(u64 gpu_address, MappedBacking&& backing) {
        m_gpu_only_regions[gpu_address] = {backing.address, backing.size, std::move(backing.pages)};
        m_gpu_only_bytes += backing.size;
        m_gpu_only_peak = (std::max)(m_gpu_only_peak, m_gpu_only_bytes);
    }
'@
$new = @'
    // Records a mapped backing for the region at gpu_address. Needs m_region_mutex.
    void RegisterGpuOnlyBacking(u64 gpu_address, MappedBacking&& backing) {
        // MKW recreates a GPU-only region at the same GPU address with increasing sizes.
        // Overwriting its map entry directly loses the former page group's lifetime and leaks
        // the mapping. Retire the old entry exactly as SubDestroySparseRegion does: unmap GPU
        // address, detach backing, then unmap/close kernel pages only after the GPU has passed it.
        if (auto old = m_gpu_only_regions.find(gpu_address); old != m_gpu_only_regions.end()) {
            auto& registry = Nvidia::Devices::Nx2GpuMemoryRegistry::Get();
            registry.Unmap(gpu_address, old->second.size);
            auto done = std::make_shared<std::atomic<bool>>(false);
            registry.ReleaseBacking(old->second.cpu_address, old->second.size,
                                    [&sys = system, done] {
                                        GpuCommands::Run(sys.GPU(), [done] {
                                            done->store(true, std::memory_order_release);
                                        });
                                    });
            m_released_regions.push_back({std::move(old->second), done});
            m_gpu_only_regions.erase(old);
            // FreeReleasedRegions() decrements m_gpu_only_bytes after the old pages are
            // actually unmapped. Do not decrement here or double-account their lifetime.
        }
        m_gpu_only_regions[gpu_address] = {backing.address, backing.size, std::move(backing.pages)};
        m_gpu_only_bytes += backing.size;
        m_gpu_only_peak = (std::max)(m_gpu_only_peak, m_gpu_only_bytes);
    }
'@
$old = $old.Replace($crlf, $lf).TrimEnd([char[]]@([char]13,[char]10))
$new = $new.Replace($crlf, $lf).TrimEnd([char[]]@([char]13,[char]10))
if ($raw.Contains($new)) { Write-Host '[ALREADY] GPU-only 214 same-start lifetime release'; return }
$at = $raw.IndexOf($old, [StringComparison]::Ordinal)
if ($at -lt 0 -or $raw.IndexOf($old,$at+$old.Length,[StringComparison]::Ordinal) -ge 0) {
    throw 'Orchid GPU backing lifetime anchor missing or ambiguous; refusing speculative edit'
}
$updated = $raw.Substring(0,$at) + $new + $raw.Substring($at+$old.Length)
[IO.File]::WriteAllText((Resolve-Path $path).Path,$updated,[Text.UTF8Encoding]::new($false))
foreach ($required in @('registry.Unmap(gpu_address, old->second.size)', 'registry.ReleaseBacking(old->second.cpu_address', 'm_released_regions.push_back({std::move(old->second), done})',
                              'm_gpu_only_regions.erase(old)', 'FreeReleasedRegions() decrements m_gpu_only_bytes')) {
    if (-not (Select-String -Path $path -SimpleMatch -Pattern $required -Quiet)) {
        throw "MKW GPU-only lifetime repair incomplete: $required"
    }
}
git diff --check -- $path
if ($LASTEXITCODE -ne 0) { throw 'MKW GPU backing repair diff failed' }
Write-Host '[PASS] Orchid native deferred GPU-only lifetime repair; C++ and actual MKW runtime verification still required'
