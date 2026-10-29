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

git diff -- src/core/device_memory_manager.inc src/video_core/macro.h