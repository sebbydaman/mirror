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

$localBlock = @'
    case Stage::Task:
        return "task";
    case Stage::Mesh:
        return "mesh";
'@.Replace('\"', '"').TrimEnd("`r", "`n")
$donorBlock = @'
    case Stage::Task:
        return "ts";
    case Stage::Mesh:
        return "ms";
'@.Replace('\"', '"').TrimEnd("`r", "`n")

function Count-Literal([string]$Haystack, [string]$Needle) {
    return ([regex]::Matches($Haystack, [regex]::Escape($Needle))).Count
}

$localCount = Count-Literal $stage $localBlock
$donorCount = Count-Literal $stage $donorBlock
if ($localCount -ne 1) {
    throw "Expected exactly one assembled Task/Mesh StageName block, found $localCount"
}
if ($donorCount -gt 1) {
    throw "Expected at most one donor Task/Mesh StageName block, found $donorCount"
}

if ($donorCount -eq 1) {
    $normalizedStage = $stage.Replace($donorBlock + "`n", '')
    if ($normalizedStage -eq $stage) {
        $normalizedStage = $stage.Replace($donorBlock, '')
    }
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
    @{ Needle = 'case Stage::Task:'; Expected = 1 },
    @{ Needle = 'case Stage::Mesh:'; Expected = 1 },
    @{ Needle = 'return "task";'.Replace('\"', '"'); Expected = 1 },
    @{ Needle = 'return "mesh";'.Replace('\"', '"'); Expected = 1 },
    @{ Needle = 'return "ts";'.Replace('\"', '"'); Expected = 0 },
    @{ Needle = 'return "ms";'.Replace('\"', '"'); Expected = 0 }
)) {
    $count = Count-Literal $verify $check.Needle
    if ($count -ne $check.Expected) {
        throw "SPIR-V StageName normalization expected $($check.Expected) x '$($check.Needle)', found $count"
    }
}

git diff --check -- $path
if ($LASTEXITCODE -ne 0) { throw 'SPIR-V Task/Mesh StageName normalization failed git diff --check' }
