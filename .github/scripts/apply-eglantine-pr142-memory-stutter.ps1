$ErrorActionPreference = 'Stop'

# Targeted subset of Djihads80/Eglantine PR #142. Keep the parts that reduce host RAM/VRAM
# pressure and shader-module lifetime, but deliberately DO NOT take commit 993fae1e (force BC3 on
# every Switch 2 GPU). Our integrated tree already has the newer 20 GiB policy and explicit
# EDEN_NX2_KEEP_ASTC rollback, so overriding it here would make this batch harder to reason about.
#
# Donor commits:
#   bb5eae57 - kernel: don't zero-fill pages that were never freed
#   5f0fc2eb - texture cache: stale-image cleanup + VMA block-slack budget accounting
#   8f2e3ebd - Vulkan: release SPIR-V shader modules after pipeline creation

$donorUrl = 'https://github.com/uwutaube/Eglantine.git'
$donorRef = 'perf/nx2-memory-stutter'
$kernelBase = '9dca3ab2e436e786ab53e862e4d515f620a11669'
$kernelCommit = 'bb5eae57fc8a66aef9f59fef45198176e16f75fd'
$textureBase = '993fae1e8951261b5f436d150da1dfef0b8ef380'
$textureCommit = '5f0fc2eb0ce890068f9baea4bd9db771785f4ce5'
$shaderBase = $textureCommit
$shaderCommit = '8f2e3ebd369f13759d28d62b1b6277e84916b455'

function Test-GitObject([string]$Sha) {
    & git cat-file -e "$Sha`^{commit}" 2>$null
    return $LASTEXITCODE -eq 0
}

# The donor branch is tiny. Fetch enough ancestry to keep the exact pinned commits available even if
# the branch receives a few follow-up fixes; then verify every object before generating any patch.
& git fetch --no-tags --depth=32 $donorUrl $donorRef
if ($LASTEXITCODE -ne 0) { throw 'Failed to fetch the pinned PR #142 donor branch' }

foreach ($sha in @($kernelBase, $kernelCommit, $textureBase, $textureCommit, $shaderCommit)) {
    if (-not (Test-GitObject $sha)) {
        # GitHub normally permits a reachable SHA fetch. This makes the script resilient if the
        # donor branch advances far enough that the shallow branch fetch no longer contains it.
        & git fetch --no-tags --depth=1 $donorUrl $sha
        if ($LASTEXITCODE -ne 0 -or -not (Test-GitObject $sha)) {
            throw "Pinned PR #142 commit is unavailable: $sha"
        }
    }
}

function Apply-DonorFile {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Base,
        [Parameter(Mandatory = $true)][string]$Commit,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Marker,
        [switch]$AllowCheckFailure
    )

    if (-not (Test-Path $Path -PathType Leaf)) { throw "PR #142 target file is missing: $Path" }
    if ((Get-Content $Path -Raw).Contains($Marker)) {
        Write-Host "[PRESENT] $Name"
        return $true
    }

    $diffLines = & git diff --binary $Base $Commit -- $Path
    if ($LASTEXITCODE -ne 0) { throw "Failed to generate donor diff for $Name ($Path)" }
    $patchText = ($diffLines -join "`n")
    if ([string]::IsNullOrWhiteSpace($patchText)) {
        throw "Pinned donor commit did not contain the expected change for $Name ($Path)"
    }
    $patchText += "`n"
    $safeName = $Name -replace '[^A-Za-z0-9_.-]', '_'
    $patchPath = Join-Path $env:RUNNER_TEMP "pr142-$safeName.patch"
    [IO.File]::WriteAllText($patchPath, $patchText, [Text.UTF8Encoding]::new($false))

    & git apply --check --whitespace=error-all $patchPath
    if ($LASTEXITCODE -ne 0) {
        if ($AllowCheckFailure) {
            Write-Warning "Direct donor patch did not match the integrated tree for $Name; using the guarded adapter."
            return $false
        }
        throw "PR #142 donor patch no longer applies cleanly for $Name ($Path)"
    }

    & git apply --whitespace=error-all $patchPath
    if ($LASTEXITCODE -ne 0) { throw "Failed to apply PR #142 donor patch for $Name ($Path)" }
    if (-not (Get-Content $Path -Raw).Contains($Marker)) {
        throw "PR #142 validation failed after applying ${Name}: marker '$Marker' missing from $Path"
    }
    Write-Host "[APPLIED] $Name"
    return $true
}

# Host-RAM pressure: avoid committing/zeroing guest pages that have never been used, while tracking
# freed pages so reused memory still receives the required zero/fill semantics.
Apply-DonorFile -Name 'kernel device-memory reuse flag' -Base $kernelBase -Commit $kernelCommit `
    -Path 'src/core/device_memory.h' -Marker 'bool used_by_kernel{};' | Out-Null
Apply-DonorFile -Name 'kernel freed-page zero-fill implementation' -Base $kernelBase -Commit $kernelCommit `
    -Path 'src/core/hle/kernel/k_memory_manager.cpp' -Marker 'void KMemoryManager::FillAllocatedPages(' | Out-Null
Apply-DonorFile -Name 'kernel freed-page tracking state' -Base $kernelBase -Commit $kernelCommit `
    -Path 'src/core/hle/kernel/k_memory_manager.h' -Marker 'std::unique_ptr<std::atomic<u64>[]> m_freed_pages;' | Out-Null
Apply-DonorFile -Name 'page-table zero-fill routing' -Base $kernelBase -Commit $kernelCommit `
    -Path 'src/core/hle/kernel/k_page_table_base.cpp' -Marker 'system.Kernel().MemoryManager().FillAllocatedPages' | Out-Null

# nx2_gsv is heavily modified by our sparse/deadlock layers. Try the exact donor hunk first; if its
# context moved, replace only the old direct ClearBackingRegion loop and preserve all surrounding
# sparse-state arbitration.
$gsvPath = 'src/core/hle/service/nx2_gsv.h'
$gsvMarker = 'kernel_core.MemoryManager().FillAllocatedPages'
if (-not (Get-Content $gsvPath -Raw).Contains($gsvMarker)) {
    $applied = Apply-DonorFile -Name 'NX2 sparse allocation selective zero-fill' -Base $kernelBase `
        -Commit $kernelCommit -Path $gsvPath -Marker $gsvMarker -AllowCheckFailure
    if (-not $applied) {
        $gsv = Get-Content $gsvPath -Raw
        $pattern = 'for \(const auto& block : \*pg\) \{\s*system\.DeviceMemory\(\)\.buffer\.ClearBackingRegion\(\s*GetInteger\(block\.GetAddress\(\)\) - Core::DramMemoryMap::Base,\s*block\.GetSize\(\), 0\);\s*\}'
        $replacement = @'
for (const auto& block : *pg) {
                kernel_core.MemoryManager().FillAllocatedPages(block.GetAddress(),
                                                               block.GetNumPages(), 0);
            }
'@
        $updated = [regex]::Replace($gsv, $pattern, $replacement, 1)
        if ($updated -eq $gsv) {
            throw 'Could not safely adapt PR #142 sparse zero-fill onto the integrated nx2_gsv path'
        }
        [IO.File]::WriteAllText($gsvPath, $updated, [Text.UTF8Encoding]::new($false))
        if (-not (Get-Content $gsvPath -Raw).Contains($gsvMarker)) {
            throw 'Adapted PR #142 sparse zero-fill marker is missing after replacement'
        }
        Write-Host '[ADAPTED] NX2 sparse allocation selective zero-fill'
    }
}

# VRAM pressure/stutter: count empty bytes already reserved inside VMA blocks against the remaining
# budget, and gradually retire Switch 2 images unused for ~3 minutes instead of waiting until the
# driver is already at its budget and evicting hot textures.
Apply-DonorFile -Name 'Switch 2 stale-image collector constants' -Base $textureBase -Commit $textureCommit `
    -Path 'src/video_core/texture_cache/texture_cache_base.h' -Marker 'STALE_IMAGE_FRAMES = 3 * 60 * 60' | Out-Null
Apply-DonorFile -Name 'Switch 2 stale-image incremental collector' -Base $textureBase -Commit $textureCommit `
    -Path 'src/video_core/texture_cache/texture_cache.h' -Marker 'stale_deletes = STALE_DELETES_PER_FRAME' | Out-Null
Apply-DonorFile -Name 'VMA block-slack budget accounting' -Base $textureBase -Commit $textureCommit `
    -Path 'src/video_core/vulkan_common/vulkan_device.cpp' -Marker 'main_statistics.blockBytes - main_statistics.allocationBytes' | Out-Null

# Shader-pipeline memory: SPIR-V modules are only needed until vkCreate*Pipeline returns. Releasing
# them prevents thousands of disk-cache-created pipelines from retaining module storage all session.
Apply-DonorFile -Name 'compute pipeline shader-module release' -Base $shaderBase -Commit $shaderCommit `
    -Path 'src/video_core/renderer_vulkan/vk_compute_pipeline.cpp' -Marker 'Only needed to create the pipeline.' | Out-Null
Apply-DonorFile -Name 'graphics pipeline shader-module release' -Base $shaderBase -Commit $shaderCommit `
    -Path 'src/video_core/renderer_vulkan/vk_graphics_pipeline.cpp' -Marker 'modules are only needed to create the pipeline' | Out-Null

# Guard our existing ASTC decision. The skipped PR #142 commit changes the helper name and forces BC3
# on every card; that is intentionally not part of this integration.
$vkTexture = Get-Content 'src/video_core/renderer_vulkan/vk_texture_cache.cpp' -Raw
if (-not $vkTexture.Contains('UseBc3ForSwitch2OnSmallCards')) {
    throw 'PR #142 integration unexpectedly replaced the existing 20 GiB ASTC policy helper'
}
if ($vkTexture.Contains('void UseBc3ForSwitch2(const Device& device)')) {
    throw 'PR #142 force-BC3-on-every-card policy leaked into the targeted integration'
}

git diff --check
if ($LASTEXITCODE -ne 0) { throw 'PR #142 targeted integration introduced whitespace/diff errors' }

Write-Host 'Applied targeted PR #142 RAM/stutter batch: freed-page zero-fill + stale VRAM cleanup + shader-module release; preserved 20 GiB ASTC policy.'
