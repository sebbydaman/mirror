$ErrorActionPreference = 'Stop'

# Donor-backed texture-cache CPU optimization from Citron: the sampler descriptor table is already
# indexed by descriptor number and reports whether the descriptor changed. Keep one SamplerId vector
# per graphics/compute table instead of hashing a tagged descriptor index on every unchanged sampler
# lookup. Descriptor memory is still read and compared exactly as before; only the redundant
# unordered_map lookup/insert is removed. Table Synchronize resets DescriptorTable read bits, so the
# first access after an address/limit change always refreshes the cached vector entry.

function Write-PatchedText([string]$Path, [string]$Text) {
    $normalized = $Text.Replace("`r`n", "`n").TrimEnd("`r", "`n") + "`n"
    [IO.File]::WriteAllText((Resolve-Path $Path).Path, $normalized, [Text.UTF8Encoding]::new($false))
}

function Replace-Once([string]$Text, [string]$Old, [string]$New, [string]$Name) {
    $Text = $Text.Replace("`r`n", "`n")
    $Old = $Old.Replace("`r`n", "`n")
    $New = $New.Replace("`r`n", "`n")
    $first = $Text.IndexOf($Old, [StringComparison]::Ordinal)
    if ($first -lt 0) { throw "Sampler ID vector cache: missing anchor $Name" }
    if ($Text.IndexOf($Old, $first + $Old.Length, [StringComparison]::Ordinal) -ge 0) {
        throw "Sampler ID vector cache: ambiguous anchor $Name"
    }
    return $Text.Substring(0, $first) + $New + $Text.Substring($first + $Old.Length)
}

$basePath = 'src/video_core/texture_cache/texture_cache_base.h'
$cachePath = 'src/video_core/texture_cache/texture_cache.h'
foreach ($path in @($basePath, $cachePath)) {
    if (-not (Test-Path $path -PathType Leaf)) {
        throw "Sampler ID vector cache: missing $path"
    }
}

$base = (Get-Content $basePath -Raw).Replace("`r`n", "`n")
if (-not $base.Contains('std::vector<SamplerId> graphics_sampler_ids;')) {
    $base = Replace-Once $base `
        '    ::Common::unordered_map<u32, SamplerId> sampler_ids;' `
        "    std::vector<SamplerId> graphics_sampler_ids;`n    std::vector<SamplerId> compute_sampler_ids;" `
        'channel sampler ID cache storage'
    Write-PatchedText $basePath $base
    Write-Host '[APPLIED] indexed graphics/compute sampler ID cache storage'
} else {
    Write-Host '[PRESENT] indexed graphics/compute sampler ID cache storage'
}

$cache = (Get-Content $cachePath -Raw).Replace("`r`n", "`n")
if ($cache.Contains('channel_state->sampler_ids.find(map_index)')) {
    $oldGet = @'
template <class P>
SamplerId TextureCache<P>::GetSamplerId(u32 index, bool compute) {
    auto& table = compute ? channel_state->compute_sampler_table : channel_state->graphics_sampler_table;
    if (index > table.current_limit) {
        LOG_DEBUG(HW_GPU, "Invalid sampler index={}", index);
        return NULL_SAMPLER_ID;
    }
    auto const map_index = index | (compute ? Common::SlotId::TAGGED_VALUE : 0);
    auto const [descriptor, is_new] = table.Read(*gpu_memory, index);
    if (is_new) {
        auto const id = FindSampler(descriptor, compute);
        channel_state->sampler_ids.insert_or_assign(map_index, id);
        return id;
    }
    return channel_state->sampler_ids.find(map_index)->second;
}
'@
    $newGet = @'
template <class P>
SamplerId TextureCache<P>::GetSamplerId(u32 index, bool compute) {
    auto& table = compute ? channel_state->compute_sampler_table : channel_state->graphics_sampler_table;
    auto& ids = compute ? channel_state->compute_sampler_ids : channel_state->graphics_sampler_ids;
    if (index > table.current_limit) {
        LOG_DEBUG(HW_GPU, "Invalid sampler index={}", index);
        return NULL_SAMPLER_ID;
    }
    auto const [descriptor, is_new] = table.Read(*gpu_memory, index);
    SamplerId& id = ids[index];
    if (is_new) {
        id = FindSampler(descriptor, compute);
    }
    return id;
}
'@
    $cache = Replace-Once $cache $oldGet.TrimEnd("`r", "`n") $newGet.TrimEnd("`r", "`n") `
        'GetSamplerId direct indexed cache'
}

if (-not $cache.Contains('compute_sampler_ids.resize(tsc_limit + 1, CORRUPT_ID);')) {
    $oldCompute = @'
        if (channel_state->compute_sampler_table.Synchronize(kepler_compute->regs.tsc.Address(), tsc_limit))
            bindings_changed = true;
'@
    $newCompute = @'
        if (channel_state->compute_sampler_table.Synchronize(kepler_compute->regs.tsc.Address(), tsc_limit)) {
            channel_state->compute_sampler_ids.resize(tsc_limit + 1, CORRUPT_ID);
            bindings_changed = true;
        }
'@
    $cache = Replace-Once $cache $oldCompute.TrimEnd("`r", "`n") $newCompute.TrimEnd("`r", "`n") `
        'compute sampler table synchronization'
}

if (-not $cache.Contains('graphics_sampler_ids.resize(tsc_limit + 1, CORRUPT_ID);')) {
    $oldGraphics = @'
        if (channel_state->graphics_sampler_table.Synchronize(maxwell3d->regs.tex_sampler.Address(), tsc_limit))
            bindings_changed = true;
'@
    $newGraphics = @'
        if (channel_state->graphics_sampler_table.Synchronize(maxwell3d->regs.tex_sampler.Address(), tsc_limit)) {
            channel_state->graphics_sampler_ids.resize(tsc_limit + 1, CORRUPT_ID);
            bindings_changed = true;
        }
'@
    $cache = Replace-Once $cache $oldGraphics.TrimEnd("`r", "`n") $newGraphics.TrimEnd("`r", "`n") `
        'graphics sampler table synchronization'
}

Write-PatchedText $cachePath $cache

$baseFinal = Get-Content $basePath -Raw
$cacheFinal = Get-Content $cachePath -Raw
foreach ($needle in @(
    'std::vector<SamplerId> graphics_sampler_ids;',
    'std::vector<SamplerId> compute_sampler_ids;'
)) {
    if (-not $baseFinal.Contains($needle)) {
        throw "Sampler ID vector cache validation failed: base missing $needle"
    }
}
foreach ($needle in @(
    'auto& ids = compute ? channel_state->compute_sampler_ids : channel_state->graphics_sampler_ids;',
    'SamplerId& id = ids[index];',
    'compute_sampler_ids.resize(tsc_limit + 1, CORRUPT_ID);',
    'graphics_sampler_ids.resize(tsc_limit + 1, CORRUPT_ID);'
)) {
    if (-not $cacheFinal.Contains($needle)) {
        throw "Sampler ID vector cache validation failed: cache missing $needle"
    }
}
foreach ($forbidden in @(
    'channel_state->sampler_ids.find(map_index)',
    'channel_state->sampler_ids.insert_or_assign(map_index',
    '::Common::unordered_map<u32, SamplerId> sampler_ids;'
)) {
    if ($baseFinal.Contains($forbidden) -or $cacheFinal.Contains($forbidden)) {
        throw "Sampler ID vector cache validation failed: old hash path remains: $forbidden"
    }
}

& git diff --check
if ($LASTEXITCODE -ne 0) {
    throw 'Sampler ID vector cache introduced diff/whitespace errors'
}

Write-Host 'Sampler ID vector cache validated: descriptor reads unchanged; hash lookup removed from unchanged sampler hot path.'
