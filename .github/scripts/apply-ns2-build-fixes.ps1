$ErrorActionPreference = "Stop"

$devicePath = "src/core/device_memory_manager.inc"
$deviceText = Get-Content $devicePath -Raw
$kernelInclude = '#include "core/hle/kernel/board/nintendo/nx/k_system_control.h"'
if (-not $deviceText.Contains($kernelInclude)) {
    $deviceNeedle = '#include "core/device_memory.h"'
    if (-not $deviceText.Contains($deviceNeedle)) {
        throw "Could not locate device_memory.h include"
    }
    $deviceText = $deviceText.Replace($deviceNeedle, "$deviceNeedle`n$kernelInclude")
    Set-Content -Path $devicePath -Value $deviceText -Encoding utf8 -NoNewline
    Write-Host "Applied KSystemControl include fix."
} else {
    Write-Host "KSystemControl include fix already present."
}

$macroPath = "src/video_core/macro.h"
$macroText = Get-Content $macroPath -Raw
if (-not $macroText.Contains('bool native_turing{};')) {
    $oldTail = "    bool is_interpreted;`n};`n`n} // namespace Tegra"
    if (-not $macroText.Contains($oldTail)) {
        $oldTail = "    bool is_interpreted;`r`n};`r`n`r`n} // namespace Tegra"
    }
    if (-not $macroText.Contains($oldTail)) {
        throw "Could not locate MacroEngine tail"
    }

    $newTail = @'
    bool is_interpreted;
    bool native_turing{};
    bool native_execution_failed{};
    u32 native_write_offset{};
    std::array<u32, 0x3000> native_code{};
    TuringMacroInterpreter native_interpreter;
};

struct NativeMacroContext {
    MacroEngine engine{true};
    std::array<u32, 0x80> positions{};
    MacroEngine compute_engine{true};
    std::array<u32, 0x80> compute_positions{};
};

} // namespace Tegra
'@
    $macroText = $macroText.Replace($oldTail, $newTail.TrimEnd("`r", "`n"))
    Set-Content -Path $macroPath -Value $macroText -Encoding utf8 -NoNewline
    Write-Host "Applied native Turing macro state fix."
} else {
    Write-Host "Native Turing macro state fix already present."
}

$memoryPath = "src/video_core/memory_manager.h"
$memoryText = Get-Content $memoryPath -Raw
if (-not $memoryText.Contains('bool UsesNativeTiling() const')) {
    $destructorNeedle = '    ~MemoryManager();'
    if (-not $memoryText.Contains($destructorNeedle)) {
        throw "Could not locate MemoryManager destructor declaration"
    }
    $nativeApi = @'
    ~MemoryManager();

    void SetNativeSyncpointShim(GPUVAddr address);
    void EnableNativeTiling() { native_tiling = true; }
    bool UsesNativeTiling() const { return native_tiling; }
    bool IsShuttingDown() const;
'@
    $memoryText = $memoryText.Replace($destructorNeedle, $nativeApi.TrimEnd("`r", "`n"))
    Write-Host "Restored native MemoryManager API declarations."
}
if (-not $memoryText.Contains('std::atomic<GPUVAddr> native_syncpoint_shim{};')) {
    $systemNeedle = '    Core::System& system;'
    if (-not $memoryText.Contains($systemNeedle)) {
        throw "Could not locate MemoryManager system member"
    }
    $memoryText = $memoryText.Replace($systemNeedle, "    std::atomic<GPUVAddr> native_syncpoint_shim{};`n$systemNeedle")
    Write-Host "Restored native syncpoint shim state."
}
Set-Content -Path $memoryPath -Value $memoryText -Encoding utf8 -NoNewline

$pullerPath = "src/video_core/engines/puller.cpp"
$pullerText = Get-Content $pullerPath -Raw
if (-not $pullerText.Contains('u32 ReadNativeSemaphoreWord(DmaPusher& dma_pusher, GPUVAddr address)')) {
    $constantsNeedle = 'constexpr u32 Gf100BindValidMask =  0x1f0000 | Gf100BindClassMask;'
    if (-not $pullerText.Contains($constantsNeedle)) {
        throw "Could not locate puller bind constants"
    }
    $nativeSemaphoreHelper = @'
constexpr u32 Gf100BindValidMask =  0x1f0000 | Gf100BindClassMask;

u32 ReadNativeSemaphoreWord(DmaPusher& dma_pusher, GPUVAddr address) {
    const auto cpu_address = dma_pusher.memory_manager.GpuToCpuAddress(address);
    if (cpu_address && dma_pusher.rasterizer->MustFlushRegion(
                           *cpu_address, sizeof(u32), VideoCommon::CacheType::BufferCache)) {
        dma_pusher.rasterizer->FlushRegion(*cpu_address, sizeof(u32),
                                           VideoCommon::CacheType::BufferCache);
        const u32 value = dma_pusher.memory_manager.Read<u32>(address);
        LOG_WARNING(HW_GPU, "Native semaphore buffer readback: address={:#x}, current={}",
                    address, value);
        VideoCommon::TraceNativeQuery(6, dma_pusher.memory_manager.GetID(), address,
                                      *cpu_address, 0, value, 0);
        return value;
    }
    return dma_pusher.memory_manager.Read<u32>(address);
}
'@
    $pullerText = $pullerText.Replace($constantsNeedle, $nativeSemaphoreHelper.TrimEnd("`r", "`n"))
    Write-Host "Restored native semaphore read helper."
}
if (-not $pullerText.Contains('dma_pusher.memory_manager.EnableNativeTiling();')) {
    $engineNeedle = '    const auto engine_id = static_cast<EngineID>(engine);'
    if (-not $pullerText.Contains($engineNeedle)) {
        throw "Could not locate puller engine-id conversion"
    }
    $pullerText = $pullerText.Replace(
        $engineNeedle,
        "    if (dma_pusher.channel_state.native_abi) dma_pusher.memory_manager.EnableNativeTiling();`n$engineNeedle")
    Write-Host "Enabled native tiling for native GPU channels."
}
Set-Content -Path $pullerPath -Value $pullerText -Encoding utf8 -NoNewline

$queryPath = "src/video_core/query_cache/query_cache.h"
$queryText = Get-Content $queryPath -Raw
if (-not $queryText.Contains('pointer, pointer_timestamp, native_trace, trace_asid, addr, cpu_addr,')) {
    $captureNeedle = '                                     pointer, pointer_timestamp] {'
    if (-not $queryText.Contains($captureNeedle)) {
        throw "Could not locate native query deferred-operation capture list"
    }
    $captureReplacement = "                                     pointer, pointer_timestamp, native_trace, trace_asid, addr, cpu_addr,`n                                     counter_type] {"
    $queryText = $queryText.Replace($captureNeedle, $captureReplacement)
    Set-Content -Path $queryPath -Value $queryText -Encoding utf8 -NoNewline
    Write-Host "Captured native query trace state for deferred query operations."
} else {
    Write-Host "Native query trace capture fix already present."
}

$amperePath = "src/shader_recompiler/frontend/ampere/lower_to_maxwell.h"
$ampereText = Get-Content $amperePath -Raw
$oldFmulMode = 'insn.Bits(91, 1) != (opcode == 0xc20)'
$newFmulMode = 'insn.Bits(91, 1) != (opcode == 0xc20 ? 1U : 0U)'
if ($ampereText.Contains($oldFmulMode)) {
    $ampereText = $ampereText.Replace($oldFmulMode, $newFmulMode)
    Write-Host "Fixed native FMUL signed/unsigned mode comparison."
}
$oldFaddMode = 'insn.Bits(91, 1) != (opcode == 0xe21)'
$newFaddMode = 'insn.Bits(91, 1) != (opcode == 0xe21 ? 1U : 0U)'
if ($ampereText.Contains($oldFaddMode)) {
    $ampereText = $ampereText.Replace($oldFaddMode, $newFaddMode)
    Write-Host "Fixed native FADD signed/unsigned mode comparison."
}
Set-Content -Path $amperePath -Value $ampereText -Encoding utf8 -NoNewline

$shaderEnvPath = "src/video_core/shader_environment.h"
$shaderEnvText = Get-Content $shaderEnvPath -Raw
$fileEnvStart = $shaderEnvText.IndexOf('class FileEnvironment final : public Shader::Environment')
if ($fileEnvStart -lt 0) {
    throw "Could not locate FileEnvironment declaration"
}
$fileEnvText = $shaderEnvText.Substring($fileEnvStart)
if (-not $fileEnvText.Contains('TranslateProgramAddress(u32 address) const override;')) {
    $readInstructionNeedle = '    [[nodiscard]] u64 ReadInstruction(u32 address) override;'
    $readInstructionIndex = $shaderEnvText.IndexOf($readInstructionNeedle, $fileEnvStart)
    if ($readInstructionIndex -lt 0) {
        throw "Could not locate FileEnvironment ReadInstruction declaration"
    }
    $insertAt = $readInstructionIndex + $readInstructionNeedle.Length
    $shaderEnvText = $shaderEnvText.Insert($insertAt, "`n`n    [[nodiscard]] u32 TranslateProgramAddress(u32 address) const override;")
    Set-Content -Path $shaderEnvPath -Value $shaderEnvText -Encoding utf8 -NoNewline
    Write-Host "Restored FileEnvironment native program-address translation declaration."
} else {
    Write-Host "FileEnvironment native address translation declaration already present."
}

# Pull two low-risk native-compute stability guards from the newer Windows-tested STORM NS2 lineage.
$keplerPath = "src/video_core/engines/kepler_compute.cpp"
$keplerText = Get-Content $keplerPath -Raw
if (-not $keplerText.Contains('if (method < Regs::NUM_REGS) {')) {
    $sinkOld = @'
void KeplerCompute::ConsumeSinkImpl(Core::System& system) {
    for (auto [method, value] : method_sink) {
        regs.reg_array[method] = value;
    }
    method_sink.clear();
}
'@
    $sinkNew = @'
void KeplerCompute::ConsumeSinkImpl(Core::System& system) {
    for (auto [method, value] : method_sink) {
        if (method < Regs::NUM_REGS) {
            regs.reg_array[method] = value;
        }
    }
    method_sink.clear();
}
'@
    if ($keplerText.Contains($sinkOld.TrimEnd("`r", "`n"))) {
        $keplerText = $keplerText.Replace($sinkOld.TrimEnd("`r", "`n"), $sinkNew.TrimEnd("`r", "`n"))
        Write-Host "Guarded native compute sink register writes."
    } else {
        Write-Host "Native compute sink guard pattern not found; leaving source unchanged."
    }
} else {
    Write-Host "Native compute sink register guard already present."
}

if (-not $keplerText.Contains('if (data.exec_address >= launch_desc_loc) {')) {
    $offsetOld = @'
        for (auto& data : uploads) {
            const GPUVAddr offset = data.exec_address - launch_desc_loc;
            if (offset / sizeof(u32) == LAUNCH_REG_INDEX(grid_dim_x)) {
                const bool source_dirty = memory_manager.IsMemoryDirty(data.upload_address, data.copy_size);
                if (data.was_dirty || source_dirty) {
                    indirect_compute = {data.upload_address};
                }
            }
        }
'@
    $offsetNew = @'
        for (auto& data : uploads) {
            if (data.exec_address >= launch_desc_loc) {
                const GPUVAddr offset = data.exec_address - launch_desc_loc;
                if (offset / sizeof(u32) == LAUNCH_REG_INDEX(grid_dim_x)) {
                    const bool source_dirty = memory_manager.IsMemoryDirty(data.upload_address, data.copy_size);
                    if (data.was_dirty || source_dirty) {
                        indirect_compute = {data.upload_address};
                    }
                }
            }
        }
'@
    if ($keplerText.Contains($offsetOld.TrimEnd("`r", "`n"))) {
        $keplerText = $keplerText.Replace($offsetOld.TrimEnd("`r", "`n"), $offsetNew.TrimEnd("`r", "`n"))
        Write-Host "Guarded native compute launch-address subtraction."
    } else {
        Write-Host "Native compute launch-address guard pattern not found; leaving source unchanged."
    }
} else {
    Write-Host "Native compute launch-address guard already present."
}
Set-Content -Path $keplerPath -Value $keplerText -Encoding utf8 -NoNewline

git diff -- src/core/device_memory_manager.inc src/video_core/macro.h src/video_core/memory_manager.h src/video_core/engines/puller.cpp src/video_core/query_cache/query_cache.h src/shader_recompiler/frontend/ampere/lower_to_maxwell.h src/video_core/shader_environment.h src/video_core/engines/kepler_compute.cpp