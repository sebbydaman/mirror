$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

# The assembled Pokopia stack already teaches SPIR-V StageName() about Task/Mesh using the
# stable local names "task" and "mesh". Build-142 donor 310dd596 independently adds the same
# switch cases as "ts" and "ms". Git can merge both insertions without a textual conflict, but
# C++ correctly rejects the resulting duplicate case labels. Normalize only this exact overlap.
$path = 'src/shader_recompiler/backend/spirv/spirv_emit_context.cpp'
$text = (Get-Content $path -Raw).Replace("`r`n", "`n")

$stagePattern = '(?s)std::string_view StageName\(Stage stage\) \{.*?throw InvalidArgument\("Invalid stage \{\}", stage\);\n\}'
$match = [regex]::Match($text, $stagePattern)
if (-not $match.Success) {
    throw 'Could not locate SPIR-V StageName() for Task/Mesh overlap normalization'
}
$stage = $match.Value

# Match each case structurally instead of requiring one exact multiline block. The assembled
# function may contain a blank line or formatting change between Task and Mesh while preserving
# identical semantics, which must not make this guard brittle.
$localTaskPattern = '(?m)^[ \t]*case Stage::Task:[ \t]*\n[ \t]*return "task";[ \t]*(?:\n|$)'
$localMeshPattern = '(?m)^[ \t]*case Stage::Mesh:[ \t]*\n[ \t]*return "mesh";[ \t]*(?:\n|$)'
$donorTaskPattern = '(?m)^[ \t]*case Stage::Task:[ \t]*\n[ \t]*return "ts";[ \t]*(?:\n|$)'
$donorMeshPattern = '(?m)^[ \t]*case Stage::Mesh:[ \t]*\n[ \t]*return "ms";[ \t]*(?:\n|$)'

function Count-Regex([string]$Haystack, [string]$Pattern) {
    return ([regex]::Matches($Haystack, $Pattern)).Count
}

$localTaskCount = Count-Regex $stage $localTaskPattern
$localMeshCount = Count-Regex $stage $localMeshPattern
$donorTaskCount = Count-Regex $stage $donorTaskPattern
$donorMeshCount = Count-Regex $stage $donorMeshPattern

if ($localTaskCount -ne 1) {
    throw "Expected exactly one assembled Task StageName case returning task, found $localTaskCount"
}
if ($localMeshCount -ne 1) {
    throw "Expected exactly one assembled Mesh StageName case returning mesh, found $localMeshCount"
}
if ($donorTaskCount -gt 1 -or $donorMeshCount -gt 1) {
    throw "Expected at most one donor Task/Mesh StageName case each, found task=$donorTaskCount mesh=$donorMeshCount"
}
if ($donorTaskCount -ne $donorMeshCount) {
    throw "Refusing partial donor StageName overlap: task=$donorTaskCount mesh=$donorMeshCount"
}

if ($donorTaskCount -eq 1) {
    $normalizedStage = [regex]::Replace($stage, $donorTaskPattern, '', 1)
    $normalizedStage = [regex]::Replace($normalizedStage, $donorMeshPattern, '', 1)
    $text = $text.Substring(0, $match.Index) + $normalizedStage + $text.Substring($match.Index + $match.Length)
    [IO.File]::WriteAllText((Resolve-Path $path).Path, $text.TrimEnd("`r", "`n") + "`n", [Text.UTF8Encoding]::new($false))
    Write-Host '[TASKMESH] Removed duplicate donor SPIR-V StageName Task/Mesh cases; preserved local task/mesh names.'
} else {
    Write-Host '[TASKMESH] SPIR-V StageName Task/Mesh overlap was already normalized.'
}

$verifyText = (Get-Content $path -Raw).Replace("`r`n", "`n")
$verifyMatch = [regex]::Match($verifyText, $stagePattern)
if (-not $verifyMatch.Success) { throw 'SPIR-V StageName() disappeared after normalization' }
$verify = $verifyMatch.Value

foreach ($check in @(
    @{ Pattern = '(?m)^[ \t]*case Stage::Task:[ \t]*$'; Expected = 1; Label = 'case Stage::Task:' },
    @{ Pattern = '(?m)^[ \t]*case Stage::Mesh:[ \t]*$'; Expected = 1; Label = 'case Stage::Mesh:' },
    @{ Pattern = '(?m)^[ \t]*return "task";[ \t]*$'; Expected = 1; Label = 'return "task";' },
    @{ Pattern = '(?m)^[ \t]*return "mesh";[ \t]*$'; Expected = 1; Label = 'return "mesh";' },
    @{ Pattern = '(?m)^[ \t]*return "ts";[ \t]*$'; Expected = 0; Label = 'return "ts";' },
    @{ Pattern = '(?m)^[ \t]*return "ms";[ \t]*$'; Expected = 0; Label = 'return "ms";' }
)) {
    $count = Count-Regex $verify $check.Pattern
    if ($count -ne $check.Expected) {
        throw "SPIR-V StageName normalization expected $($check.Expected) x '$($check.Label)', found $count"
    }
}

git diff --check -- $path
if ($LASTEXITCODE -ne 0) { throw 'SPIR-V Task/Mesh StageName normalization failed git diff --check' }
