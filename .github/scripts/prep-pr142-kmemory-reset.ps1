$ErrorActionPreference = 'Stop'

$path = 'src/core/hle/kernel/k_memory_manager.cpp'
$marker = 'std::exchange(m_system.DeviceMemory().used_by_kernel, true)'
$text = (Get-Content $path -Raw) -replace "`r`n", "`n"

if ($text.Contains($marker)) {
    Write-Host '[PRESENT] PR142 KMemoryManager cross-session reset'
    exit 0
}

$start = $text.IndexOf('void KMemoryManager::Initialize(', [StringComparison]::Ordinal)
if ($start -lt 0) { throw 'Could not locate KMemoryManager::Initialize for PR142 reset adapter' }
$next = $text.IndexOf('Result KMemoryManager::InitializeOptimizedMemory(', $start, [StringComparison]::Ordinal)
if ($next -lt 0) { throw 'Could not locate function after KMemoryManager::Initialize for PR142 reset adapter' }

# The final closing brace before InitializeOptimizedMemory is Initialize()'s own function boundary.
# This avoids depending on comments/formatting inside the already heavily integrated function.
$close = $text.LastIndexOf('}', $next - 1)
if ($close -le $start) { throw 'Could not locate KMemoryManager::Initialize closing brace' }

$insert = @'
    // The host backing outlives emulation sessions: after an earlier one, no page is known zero.
    if (std::exchange(m_system.DeviceMemory().used_by_kernel, true)) {
        for (size_t i = 0; i < m_num_managers; ++i) {
            m_managers[i].MarkAllFreed();
        }
    }
'@

# Keep one blank line before the inserted block and preserve the existing closing brace/newline.
$prefix = $text.Substring(0, $close).TrimEnd("`n")
$suffix = $text.Substring($close)
$text = $prefix + "`n`n" + $insert.TrimEnd("`r", "`n") + "`n" + $suffix

[IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false))
$check = Get-Content $path -Raw
if (-not $check.Contains($marker)) { throw 'PR142 KMemoryManager reset marker missing after semantic insertion' }

Write-Host '[ADAPTED] PR142 KMemoryManager cross-session reset at Initialize() function boundary'
