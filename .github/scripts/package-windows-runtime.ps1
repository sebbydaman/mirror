param(
    [string]$BinDir = "build/bin"
)

$ErrorActionPreference = "Stop"

$bin = Resolve-Path $BinDir
$exe = Join-Path $bin "eglantine.exe"
if (-not (Test-Path $exe)) { throw "Portable packaging: missing $exe" }

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw "Portable packaging: Visual Studio C++ toolchain not found" }
$devcmd = Join-Path $vs "Common7\Tools\VsDevCmd.bat"

$workspaceDlls = @{}
Get-ChildItem $env:GITHUB_WORKSPACE -Filter *.dll -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
    $key = $_.Name.ToLowerInvariant()
    if (-not $workspaceDlls.ContainsKey($key)) { $workspaceDlls[$key] = $_.FullName }
}
$redistRoot = Join-Path $vs "VC\Redist\MSVC"
if (Test-Path $redistRoot) {
    Get-ChildItem $redistRoot -Filter *.dll -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        $key = $_.Name.ToLowerInvariant()
        if ($key -like 'msvcp*.dll' -or $key -like 'vcruntime*.dll') { $workspaceDlls[$key] = $_.FullName }
        elseif (-not $workspaceDlls.ContainsKey($key)) { $workspaceDlls[$key] = $_.FullName }
    }
}
foreach ($dir in ($env:PATH -split ';')) {
    if (-not $dir -or -not (Test-Path $dir)) { continue }
    Get-ChildItem $dir -Filter *.dll -File -ErrorAction SilentlyContinue | ForEach-Object {
        $key = $_.Name.ToLowerInvariant()
        if (-not $workspaceDlls.ContainsKey($key)) { $workspaceDlls[$key] = $_.FullName }
    }
}
function Get-Imports([string]$Path) {
    $escaped = $Path.Replace('"', '""')
    $output = cmd /c "`"$devcmd`" -arch=x64 -host_arch=x64 >nul && dumpbin /nologo /dependents `"$escaped`"" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Portable packaging: dumpbin failed for $Path" }
    return @($output | ForEach-Object { if ($_ -match '^\s+([^\s]+\.dll)\s*$') { $matches[1] } } | Where-Object { $_ } | Sort-Object -Unique)
}
$copied = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$visited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$queue = [System.Collections.Generic.Queue[string]]::new()
$manifest = [System.Collections.Generic.List[string]]::new()
function Queue-Binary([string]$Path) { if (Test-Path $Path) { $queue.Enqueue((Resolve-Path $Path).Path) } }
function Resolve-QueuedDependencies {
    while ($queue.Count -gt 0) {
        $binary = $queue.Dequeue(); if (-not $visited.Add($binary)) { continue }
        foreach ($dll in (Get-Imports $binary)) {
            $systemPath = Join-Path $env:WINDIR "System32\$dll"
            $isMsvcRuntime = $dll -like 'MSVCP*.dll' -or $dll -like 'VCRUNTIME*.dll'
            if (-not $isMsvcRuntime -and ($dll -like 'api-ms-win-*' -or (Test-Path $systemPath))) { $manifest.Add("SYSTEM  $dll"); continue }
            $dest = Join-Path $bin $dll
            if (Test-Path $dest) { $manifest.Add("BUNDLED $dll (already present)"); Queue-Binary $dest; continue }
            $key = $dll.ToLowerInvariant()
            if (-not $workspaceDlls.ContainsKey($key)) { throw "Portable packaging: unresolved non-system dependency $dll required by $binary" }
            $source = $workspaceDlls[$key]; Copy-Item $source $dest -Force; $copied.Add($dll) | Out-Null
            $manifest.Add("BUNDLED $dll <= $source"); Write-Host "Bundled runtime dependency: $dll"; Queue-Binary $dest
        }
    }
}
$exeImports = Get-Imports $exe; Queue-Binary $exe; Resolve-QueuedDependencies
$dynamicQtImports = @($exeImports | Where-Object { $_ -match '^Qt6.*\.dll$' })
if ($dynamicQtImports.Count -gt 0) {
    $manifest.Add('QT      dynamic Qt detected'); $windeploy = Get-Command windeployqt -ErrorAction SilentlyContinue
    if (-not $windeploy) { throw "Portable packaging: dynamic Qt imports detected but windeployqt is unavailable" }
    & $windeploy.Source --release --no-translations $exe
    if ($LASTEXITCODE -ne 0) { throw "Portable packaging: windeployqt failed" }
    $manifest.Add('QT      windeployqt deployment completed')
    Get-ChildItem $bin -Filter *.dll -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object { Queue-Binary $_.FullName }
    Resolve-QueuedDependencies
} else { $manifest.Add('QT      no Qt6 DLL imports; bundled/static Qt layout does not require deployment folders') }
Get-ChildItem $bin -Include *.exe,*.dll -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
    foreach ($dll in (Get-Imports $_.FullName)) {
        $systemPath = Join-Path $env:WINDIR "System32\$dll"; $isMsvcRuntime = $dll -like 'MSVCP*.dll' -or $dll -like 'VCRUNTIME*.dll'
        $local = Get-ChildItem $bin -Filter $dll -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($isMsvcRuntime -and -not $local) { throw "Portable packaging verification: MSVC runtime $dll not bundled for $($_.Name)" }
        if (-not $local -and -not ($dll -like 'api-ms-win-*') -and -not (Test-Path $systemPath)) { throw "Portable packaging verification: unresolved dependency $dll required by $($_.FullName)" }
    }
}
@("Portable runtime dependency audit","Generated from dumpbin /dependents; non-system dependencies are bundled recursively.","") + ($manifest | Sort-Object -Unique) | Set-Content (Join-Path $bin "RUNTIME_DEPENDENCIES.txt") -Encoding UTF8
$binPath = $bin.Path.TrimEnd('\')
@("Eden NS2 Pokopia portable package layout","Files and folders are listed relative to build/bin.","") + (Get-ChildItem $bin -Recurse -Force | ForEach-Object { $relative = $_.FullName.Substring($binPath.Length).TrimStart('\'); if ($_.PSIsContainer) { "DIR   $relative\" } else { "FILE  $relative  $($_.Length) bytes" } } | Sort-Object) | Set-Content (Join-Path $bin "PACKAGE_LAYOUT.txt") -Encoding UTF8

# Ship a small generic diagnostic launcher beside the portable executable. It follows Eden's newest
# log, keeps only high-signal GPU/Vulkan/NX2/critical lines plus a short tail, suppresses known
# repetitive nx2:vi2 function-107 noise, and redacts local Windows paths before writing reports.
$watcher = @'
param([string]$LogPath = "", [string[]]$EdenArgs = @())
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$exe = Join-Path $root "eglantine.exe"
if (-not (Test-Path $exe)) { throw "eglantine.exe must be beside this script" }
$reports = Join-Path $root "diagnostic-reports"; New-Item -ItemType Directory -Force $reports | Out-Null
function Find-Log {
  if ($LogPath -and (Test-Path $LogPath)) { return (Resolve-Path $LogPath).Path }
  $roots = @((Join-Path $env:APPDATA "Eden"),(Join-Path $env:LOCALAPPDATA "Eden"),$root) | Where-Object { $_ -and (Test-Path $_) }
  return $roots | ForEach-Object { Get-ChildItem $_ -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(eden|eglantine).*\.log$|^log\.txt$' } } | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
}
function Sanitize([string]$s) {
  if (-not $s) { return $s }
  $s = $s -replace [regex]::Escape($env:USERPROFILE), '<USERPROFILE>'
  if ($env:USERNAME) { $s = $s -replace "(?i)C:\\Users\\$([regex]::Escape($env:USERNAME))", '<USERPROFILE>' }
  $s = $s -replace '(?i)[A-Z]:\\Users\\[^\\\s]+', '<USERPROFILE>'
  $s = $s -replace '(?i)(?:title|game|rom|xci|nsp)\s*[=:]\s*[^\r\n]+', '$1=<redacted>'
  return $s
}
function Is-Signal([string]$line) { return $line -match '(?i)<(Fatal|Critical|Error)>|shader.*(reject|unsupported|fail)|Vulkan.*(error|fail)|Native (graphics|compute).*rejected|QMD failed|unmapped device|pipeline.*(fail|skip)|nx2:.*(stub|unknown|unimplemented)' }
function Is-Noise([string]$line) { return $line -match "(?i)nx2:vi2.*(?:function )?'?107|port='nx2:vi2'.*107" }
$proc = Start-Process $exe -ArgumentList $EdenArgs -PassThru
Write-Host "Eden started (PID $($proc.Id)). Diagnostic watcher is active. Close Eden to write the final report."
$seen = [System.Collections.Generic.HashSet[string]]::new(); $events = [System.Collections.Generic.List[string]]::new(); $tail = [System.Collections.Generic.Queue[string]]::new(); $pos = 0L; $active = $null
while (-not $proc.HasExited) {
  $candidate = Find-Log
  if ($candidate -and $candidate -ne $active) { $active = $candidate; $pos = 0L }
  if ($active -and (Test-Path $active)) {
    $f = Get-Item $active
    if ($f.Length -lt $pos) { $pos = 0L }
    $fs = [IO.File]::Open($active,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite); $fs.Seek($pos,[IO.SeekOrigin]::Begin) | Out-Null
    $sr = New-Object IO.StreamReader($fs)
    while (($line = $sr.ReadLine()) -ne $null) {
      $clean = Sanitize $line; $tail.Enqueue($clean); while ($tail.Count -gt 80) { $tail.Dequeue() | Out-Null }
      if ((Is-Signal $clean) -and -not (Is-Noise $clean)) { $key = $clean -replace '^\[\s*[0-9.]+\]\s*',''; if ($seen.Add($key)) { $events.Add($clean) } }
    }
    $pos = $fs.Position; $sr.Dispose(); $fs.Dispose()
  }
  Start-Sleep -Milliseconds 500; $proc.Refresh()
}
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'; $out = Join-Path $reports "eden-diagnostic-$stamp.txt"
@("Eden sanitized runtime diagnostic","Generated: $(Get-Date -Format o)","Raw log is NOT included.","Local profile paths are redacted; known nx2:vi2/107 spam is suppressed.","","=== New unique high-signal events ===") + $events + @("","=== Last useful log tail (80 lines) ===") + $tail.ToArray() | Set-Content $out -Encoding UTF8
Write-Host "Diagnostic report written to: $out"
'@
$watcher | Set-Content (Join-Path $bin "Run-Eden-Diagnostics.ps1") -Encoding UTF8
@'
EDEN NS2 DIAGNOSTIC WATCHER
===========================
1. Right-click Run-Eden-Diagnostics.ps1 and choose Run with PowerShell, or run:
   powershell -ExecutionPolicy Bypass -File .\Run-Eden-Diagnostics.ps1
2. Use Eden normally and reproduce the rendering/crash problem.
3. Close Eden. A small sanitized report is written under diagnostic-reports\.
4. Share that report for GitHub inspection; do not upload the full raw Eden log unless specifically needed.

Optional: pass -LogPath "C:\path\to\eden_log.txt" if auto-detection selects the wrong log.
The watcher is generic: it records new fatal/critical/GPU shader/Vulkan/NX2/compute/memory failures,
deduplicates repeats, suppresses the known nx2:vi2 function 107 spam, and redacts Windows profile paths.
'@ | Set-Content (Join-Path $bin "DIAGNOSTICS_README.txt") -Encoding UTF8

Write-Host "Portable dependency packaging complete. Copied $($copied.Count) DLL(s)."
Write-Host "Diagnostic launcher packaged: Run-Eden-Diagnostics.ps1"
Write-Host "Qt mode: $(if ($dynamicQtImports.Count -gt 0) { 'dynamic/deployed' } else { 'bundled/static' })"
Get-ChildItem $bin | Select-Object Name, Length | Format-Table -AutoSize
