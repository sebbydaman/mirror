$ErrorActionPreference = 'Stop'
# Orchid v0.7.0 consolidated Windows candidate, after the three proven source ports.
# Individually compiled Windows gates: GitHub run 41891471057 (all four success).
# This combines the ports in one tree; full GUI compilation and gameplay remain separate gates.
$root = Join-Path $PSScriptRoot 'experiments'
$ports = @(
    @{ Name = 'native Task/Mesh 0x923/0x927'; File = 'apply-native-taskmesh-stage-buffer.ps1' },
    @{ Name = 'PokeDinner Mario Kart World 30/dynamic FPS'; File = 'apply-pokedinner-mkw-fps.ps1' },
    @{ Name = 'Lichii Star Fox/GameShare HID'; File = 'apply-lichii-streamplay-hid.ps1' },
    @{ Name = 'Lichii waited-on Vulkan pipeline build'; File = 'apply-lichii-inline-pipeline-builds.ps1' }
)
foreach ($entry in $ports) {
    $port = Join-Path $root $entry.File
    if (-not (Test-Path $port -PathType Leaf)) { throw "Missing pinned donor adapter: $port" }
    Write-Host "[BEGIN] $($entry.Name)"
    & $port
    if (-not $?) { throw "Donor script did not complete: $($entry.Name)" }
    Write-Host "[APPLIED] $($entry.Name)"
}
# Include newly created guest_hid.h in provenance diff and repeatability checks.
$guestHid = 'src/core/hle/service/ngc/guest_hid.h'
if (-not (Test-Path $guestHid -PathType Leaf)) { throw 'Lichii guest HID shared-memory helper is missing' }
git add -N -- $guestHid
if ($LASTEXITCODE -ne 0) { throw 'Could not include new HID header in integration diff' }
git diff --check
if ($LASTEXITCODE -ne 0) { throw 'Combined donor patch introduced whitespace errors' }
$before = (git diff --binary | Out-String)
foreach ($entry in $ports) {
    & (Join-Path $root $entry.File)
    if (-not $?) { throw "Donor patch not idempotent: $($entry.Name)" }
}
git diff --check
if ($LASTEXITCODE -ne 0) { throw 'Repeated combined donor patch fails whitespace gate' }
$after = (git diff --binary | Out-String)
if ($before -cne $after) { throw 'Combined donor patch changes source after second application' }

$required = @(
    @('src/shader_recompiler/frontend/ampere/lower_to_maxwell.h', 'case 0x923: case 0x927:'),
    @('src/shader_recompiler/frontend/maxwell/translate/impl/internal_stage_buffer_entry_read.cpp', 'void TranslatorVisitor::ISBE_nx2(u64 insn)'),
    @('src/core/loader/nso.cpp', 'Mario Kart World: dynamic FPS not applied'),
    @('src/common/settings.h', 'mkw_dynamic_fps'),
    @('src/core/hle/service/nx2_gsv.h', 'Settings::GetCurrentProgramID() == 0x0400C3F00006E000ULL'),
    @('src/core/hle/service/nx2_streamplay.h', 'NGC::ReplyGuestHidSharedMemory(ctx, system, guest_hid_memory)'),
    @('src/core/hle/service/ngc/ngc.cpp', 'ReplyGuestHidSharedMemory(ctx, system, guest_hid_memory)'),
    @('src/core/hle/service/ngc/guest_hid.h', 'GuestHidMemorySize = 0x9b000'),
    @('src/video_core/renderer_vulkan/vk_compute_pipeline.cpp', 'void ComputePipeline::RunBuild()'),
    @('src/video_core/renderer_vulkan/vk_graphics_pipeline.cpp', 'void GraphicsPipeline::RunBuild()'),
    @('src/video_core/renderer_vulkan/vk_compute_pipeline.h', 'std::atomic_bool build_claimed{false};'),
    @('src/video_core/renderer_vulkan/vk_graphics_pipeline.h', 'std::atomic_bool build_claimed{false};'),
    @('src/shader_recompiler/ir_opt/position_pass.cpp', 'IsFloatBits(arithmetic->Arg(1 - bias_arg), 0)'),
    @('src/core/file_sys/nup_container.cpp', 'GetFiles().empty() && dir->GetSubdirectories().empty()')
)
foreach ($pair in $required) {
    if (-not (Select-String -Path $pair[0] -SimpleMatch $pair[1] -Quiet)) {
        throw "Combined Orchid source invariant missing: $($pair[0]) => $($pair[1])"
    }
}
Write-Host '[PASS] All four separately compiled donor ports coexist and remain idempotent in one Orchid source tree'
git diff --stat
if ($LASTEXITCODE -ne 0) { throw 'Could not obtain combined donor diff statistics' }
