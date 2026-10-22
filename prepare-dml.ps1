param(
    [Parameter(Mandatory = $true)]
    [string]$UpdatedPath,

    [Parameter(Mandatory = $true)]
    [string]$HistoryPath,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [Parameter(Mandatory = $true)]
    [string]$RawOutputPath
)

$ErrorActionPreference = 'Stop'

function Read-SqlText {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [IO.File]::ReadAllBytes($Path)

    if ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) {
        return (New-Object Text.UTF8Encoding($false, $true)).GetString($bytes, 3, $bytes.Length - 3)
    }

    if ($bytes.Length -ge 2 -and $bytes[0] -eq 255 -and $bytes[1] -eq 254) {
        return [Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
    }

    if ($bytes.Length -ge 2 -and $bytes[0] -eq 254 -and $bytes[1] -eq 255) {
        return [Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2)
    }

    try {
        return (New-Object Text.UTF8Encoding($false, $true)).GetString($bytes)
    }
    catch [Text.DecoderFallbackException] {
        return [Text.Encoding]::GetEncoding(1252).GetString($bytes)
    }
}

function Test-WordAt {
    param(
        [string]$Text,
        [int]$Index,
        [string]$Word
    )

    if ($Index + $Word.Length -gt $Text.Length) {
        return $false
    }

    if (-not $Text.Substring($Index, $Word.Length).Equals($Word, [StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }

    $beforeIsWord = $Index -gt 0 -and ($Text[$Index - 1] -match '[A-Za-z0-9_$]')
    $afterIndex = $Index + $Word.Length
    $afterIsWord = $afterIndex -lt $Text.Length -and ($Text[$afterIndex] -match '[A-Za-z0-9_$]')
    return -not $beforeIsWord -and -not $afterIsWord
}

function Skip-Whitespace {
    param([string]$Text, [int]$Index)

    while ($Index -lt $Text.Length -and [char]::IsWhiteSpace($Text[$Index])) {
        $Index++
    }

    return $Index
}

function Skip-CommentOrLiteral {
    param([string]$Text, [int]$Index)

    if ($Text[$Index] -eq '-' -and $Index + 1 -lt $Text.Length -and $Text[$Index + 1] -eq '-') {
        $lineEnd = $Text.IndexOf("`n", $Index + 2)
        return $(if ($lineEnd -lt 0) { $Text.Length } else { $lineEnd + 1 })
    }

    if ($Text[$Index] -eq '/' -and $Index + 1 -lt $Text.Length -and $Text[$Index + 1] -eq '*') {
        $commentEnd = $Text.IndexOf('*/', $Index + 2, [StringComparison]::Ordinal)
        if ($commentEnd -lt 0) {
            return $Text.Length
        }
        return $commentEnd + 2
    }

    if ($Text[$Index] -eq "'" -or $Text[$Index] -eq '"') {
        $quote = $Text[$Index]
        $Index++
        while ($Index -lt $Text.Length) {
            if ($Text[$Index] -eq $quote) {
                if ($Index + 1 -lt $Text.Length -and $Text[$Index + 1] -eq $quote) {
                    $Index += 2
                    continue
                }
                return $Index + 1
            }
            $Index++
        }
        return $Text.Length
    }

    return $Index
}

function Find-BlockTerminator {
    param([string]$Text, [int]$BlockStart)

    $index = $BlockStart
    $depth = 0
    $started = $false

    while ($index -lt $Text.Length) {
        $skipped = Skip-CommentOrLiteral $Text $index
        if ($skipped -ne $index) {
            $index = $skipped
            continue
        }

        if (Test-WordAt $Text $index 'BEGIN') {
            $depth++
            $started = $true
            $index += 5
            continue
        }

        if (Test-WordAt $Text $index 'END') {
            if (-not $started -or $depth -le 0) {
                return -1
            }

            $depth--
            $index += 3
            if ($depth -eq 0) {
                $terminator = Skip-Whitespace $Text $index
                if ($terminator -lt $Text.Length -and $Text[$terminator] -eq ';') {
                    return @{ EndIndex = $terminator; HasSemicolon = $true }
                }
                return @{ EndIndex = $index; HasSemicolon = $false }
            }
            continue
        }

        $index++
    }

    return -1
}

function Convert-UnpreparedBlocks {
    param([string]$Sql)

    $output = New-Object Text.StringBuilder
    $index = 0
    $alternativeTermActive = $false

    while ($index -lt $Sql.Length) {
        $skipped = Skip-CommentOrLiteral $Sql $index
        if ($skipped -ne $index) {
            [void]$output.Append($Sql.Substring($index, $skipped - $index))
            $index = $skipped
            continue
        }

        if (Test-WordAt $Sql $index 'SET') {
            $termIndex = Skip-Whitespace $Sql ($index + 3)
            if (Test-WordAt $Sql $termIndex 'TERM') {
                $newTermIndex = Skip-Whitespace $Sql ($termIndex + 4)
                if ($newTermIndex -lt $Sql.Length) {
                    $alternativeTermActive = $Sql[$newTermIndex] -ne ';'
                }
            }
        }

        if (-not $alternativeTermActive -and (Test-WordAt $Sql $index 'EXECUTE')) {
            $blockIndex = Skip-Whitespace $Sql ($index + 7)
            if (Test-WordAt $Sql $blockIndex 'BLOCK') {
                $termResult = Find-BlockTerminator $Sql $index
                if ($termResult -ne -1) {
                    $termPos = $termResult.EndIndex
                    [void]$output.Append("SET TERM ^ ;`r`n")
                    [void]$output.Append($Sql.Substring($index, $termPos - $index))
                    [void]$output.Append("^`r`nSET TERM ; ^`r`n")
                    
                    $nextPos = $(if ($termResult.HasSemicolon) { $termPos + 1 } else { $termPos })
                    while ($nextPos -lt $Sql.Length) {
                        $ws = Skip-Whitespace $Sql $nextPos
                        if ($ws -lt $Sql.Length -and $Sql[$ws] -eq ';') {
                            $nextPos = $ws + 1
                        } else {
                            break
                        }
                    }
                    $index = $nextPos
                    continue
                }
            }
        }

        [void]$output.Append($Sql[$index])
        $index++
    }

    return $output.ToString()
}

# 1. Lê ambos os arquivos e grava temporários em UTF-8 sem BOM
$history = Read-SqlText $HistoryPath
$updated = Read-SqlText $UpdatedPath

$tempHist = [IO.Path]::GetTempFileName()
$tempUpd  = [IO.Path]::GetTempFileName()
$tempDiff = [IO.Path]::GetTempFileName()
$utf8NoBom = New-Object Text.UTF8Encoding($false)

try {
    [IO.File]::WriteAllText($tempHist, $history.Replace("`r`n", "`n").Replace("`r", "`n"), $utf8NoBom)
    [IO.File]::WriteAllText($tempUpd,  $updated.Replace("`r`n", "`n").Replace("`r", "`n"), $utf8NoBom)

    $gitExe = "git"
    if (-not (Get-Command "git" -ErrorAction SilentlyContinue)) {
        if (Test-Path "C:\Program Files\Git\cmd\git.exe") {
            $gitExe = "C:\Program Files\Git\cmd\git.exe"
        } else {
            throw "Executavel do Git nao encontrado."
        }
    }

    # 2. Usa --output para gravar direto no disco em UTF-8 puro (evita corromper acentos no console)
    & $gitExe -c core.autocrlf=false diff --no-index --unified=0 --ignore-space-at-eol "--output=$tempDiff" $tempHist $tempUpd 2>$null
    $diffLines = [IO.File]::ReadAllLines($tempDiff, $utf8NoBom)
}
finally {
    if (Test-Path $tempHist) { Remove-Item $tempHist -Force }
    if (Test-Path $tempUpd)  { Remove-Item $tempUpd -Force }
    if (Test-Path $tempDiff) { Remove-Item $tempDiff -Force }
}

if ($null -eq $diffLines -or $diffLines.Count -eq 0) {
    exit 0
}

# 3. Filtra apenas as linhas adicionadas (+)
$addedLines = New-Object Collections.Generic.List[string]
foreach ($line in $diffLines) {
    if ($line.StartsWith("+") -and -not $line.StartsWith("+++")) {
        $addedLines.Add($line.Substring(1))
    }
}

if ($addedLines.Count -eq 0) {
    exit 0
}

$suffix = ($addedLines -join "`r`n") + "`r`n"
if ([string]::IsNullOrWhiteSpace($suffix)) {
    exit 0
}

# 4. Prepara blocos e ativa AUTODDL ON para que ALTER TABLE dentro do script entre em vigor na hora
$prepared = Convert-UnpreparedBlocks $suffix

$conditionalDrop = @'
SET TERM ^ ;
EXECUTE BLOCK AS
BEGIN
  IF (EXISTS (SELECT 1 FROM RDB$RELATIONS WHERE RDB$RELATION_NAME = 'TEMPORARIO_TOKEN')) THEN
    EXECUTE STATEMENT 'DROP TABLE TEMPORARIO_TOKEN';
END^
SET TERM ; ^
'@
$dropPattern = [regex]::new('(?im)^[ \t]*DROP[ \t]+TABLE[ \t]+TEMPORARIO_TOKEN[ \t]*;')
$prepared = $dropPattern.Replace($prepared, [Text.RegularExpressions.MatchEvaluator]{ param($match) $conditionalDrop })

$maintenancePattern = [regex]::new('(?ims)^[ \t]*update[ \t]+MAQ_MANUTENCAO\s+set\s+MAQ_MANUTENCAO\.DESCRICAO_MANMAQ[ \t]*=[^;]*?\bwhere\s+MAQ_MANUTENCAO\.DESCRICAO_MANMAQ\s+is\s+null[ \t]*;')
$prepared = $maintenancePattern.Replace($prepared, [Text.RegularExpressions.MatchEvaluator]{
    param($match)
    return ($match.Value -replace '(?i)\bis[ \t]+null[ \t]*;$', 'IS NULL AND MAQ_MANUTENCAO.PRIORIDADE_MANMAQ IN (1,2,3);')
})

# Converte /*commit_work*/ em COMMIT; reais para confirmar cada servico individualmente
$prepared = $prepared -replace '(?i)/\*commit_work\*/', 'COMMIT;'
$prepared = "SET NAMES UTF8;`r`nSET AUTODDL ON;`r`n" + $prepared + "`r`nCOMMIT;`r`n"

# 5. Salva os artefatos finais
[IO.File]::WriteAllText($RawOutputPath, $suffix, $utf8NoBom)
[IO.File]::WriteAllText($OutputPath, $prepared, $utf8NoBom)
exit 0