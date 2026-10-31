$ErrorActionPreference = 'Stop'

# Task/Mesh layer C: the GLASM EmitContext still has one exhaustive legacy-stage switch.
# GLASM has no Task/Mesh execution model, so acknowledge the enum values for /we4062 but
# reject them explicitly rather than assigning a bogus legacy attribute namespace.
function Read-Lf([string]$Path) {
    if (-not (Test-Path $Path)) { throw "Missing required source file: $Path" }
    return (Get-Content $Path -Raw).Replace("`r`n", "`n")
}
function Write-Utf8([string]$Path, [string]$Text) {
    Set-Content -Path $Path -Value $Text -Encoding utf8 -NoNewline
}
function Replace-Once([string]$Text, [string]$Old, [string]$New, [string]$Label) {
    $Old = $Old.Replace("`r`n", "`n")
    $New = $New.Replace("`r`n", "`n")
    $at = $Text.IndexOf($Old)
    if ($at -lt 0) { throw "Could not locate $Label" }
    if ($Text.IndexOf($Old, $at + $Old.Length) -ge 0) { throw "Ambiguous anchor for $Label" }
    return $Text.Substring(0, $at) + $New + $Text.Substring($at + $Old.Length)
}

$path = 'src/shader_recompiler/backend/glasm/glasm_emit_context.cpp'
$text = Read-Lf $path
$marker = 'throw InvalidArgument("GLASM does not support shader stage {}", program.stage);'

if (-not $text.Contains($marker)) {
    $old = @'
    case Stage::Compute:
        stage_name = "invocation";
        break;
    }
    const std::string_view attr_stage{stage == Stage::Fragment ? "fragment" : "vertex"};
'@
    $new = @'
    case Stage::Compute:
        stage_name = "invocation";
        break;
    case Stage::Task:
    case Stage::Mesh:
        throw InvalidArgument("GLASM does not support shader stage {}", program.stage);
    }
    const std::string_view attr_stage{stage == Stage::Fragment ? "fragment" : "vertex"};
'@
    $text = Replace-Once $text $old $new 'GLASM EmitContext Task/Mesh exhaustive stage guard'
    Write-Utf8 $path $text
}

$check = Read-Lf $path
foreach ($needle in @(
    'case Stage::Task:',
    'case Stage::Mesh:',
    $marker
)) {
    if (-not $check.Contains($needle)) { throw "Runtime-v10 GLASM EmitContext regression: missing $needle" }
}

Write-Host 'Added explicit Task/Mesh rejection to the legacy GLASM EmitContext stage switch.'
git diff -- $path
