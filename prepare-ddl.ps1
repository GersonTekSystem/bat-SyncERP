param(
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [Parameter(Mandatory = $true)][string]$ReportPath
)

$ErrorActionPreference = 'Stop'
$encoding = [Text.Encoding]::GetEncoding(1252)
$sql = [IO.File]::ReadAllText($InputPath, $encoding)
$connectionPattern = [regex]::new("(?im)^[ \t]*CONNECT\s+'(?:''|[^'])*'\s+USER\s+'(?:''|[^'])*'\s+PASSWORD\s+(?<password>'(?:''|[^'])*')\s*;")
$connections = $connectionPattern.Matches($sql)
if ($connections.Count -gt 1 -or [regex]::Matches($sql, '(?im)^[ \t]*CONNECT\b').Count -ne $connections.Count) {
    throw 'Instrucao CONNECT do DBComparer fora do formato esperado.'
}
$reportSql = $sql
if ($connections.Count -eq 1) {
    $password = $connections[0].Groups['password']
    $reportSql = $sql.Substring(0, $password.Index) + "'[REDACTED]'" + $sql.Substring($password.Index + $password.Length)
}

function Get-Identifier {
    param([string]$Literal)
    $name = $Literal.Substring(1, $Literal.Length - 2).Replace("''", "'")
    if ($name -cnotmatch '^[A-Za-z_][A-Za-z0-9_$]*$') {
        throw "Nome de objeto fora do formato seguro: $name"
    }
    return $name
}

function Get-StatementEnd {
    param([string]$Text, [int]$Start)
    $inString = $false
    for ($i = $Start; $i -lt $Text.Length; $i++) {
        if ($Text[$i] -eq "'") {
            if ($inString -and $i + 1 -lt $Text.Length -and $Text[$i + 1] -eq "'") {
                $i++
                continue
            }
            $inString = -not $inString
        }
        elseif ($Text[$i] -eq ';' -and -not $inString) {
            return $i
        }
    }
    throw 'UPDATE RDB$ sem terminador seguro.'
}

function Convert-DescriptionUpdate {
    param([string]$Statement)
    $literal = "'(?:''|[^'])*'"
    $pattern = "(?is)^\s*UPDATE\s+RDB\`$(?<kind>RELATIONS|RELATION_FIELDS|INDICES)\s+SET\s+RDB\`$DESCRIPTION\s*=\s*(?<value>NULL|$literal)\s+WHERE\s+(?<where>.*?)\s*;\s*$"
    $match = [regex]::Match($Statement, $pattern)
    if (-not $match.Success) { throw 'UPDATE de tabela de sistema fora do formato suportado.' }

    $where = $match.Groups['where'].Value.Trim()
    $value = $match.Groups['value'].Value
    switch ($match.Groups['kind'].Value.ToUpperInvariant()) {
        'RELATIONS' {
            $condition = [regex]::Match($where, "(?is)^RDB\`$RELATION_NAME\s*=\s*(?<name>$literal)$")
            if (-not $condition.Success) { throw 'Filtro de descricao de tabela desconhecido.' }
            $name = Get-Identifier $condition.Groups['name'].Value
            return "COMMENT ON TABLE $name IS $value;"
        }
        'RELATION_FIELDS' {
            $condition = [regex]::Match($where, "(?is)^RDB\`$RELATION_NAME\s*=\s*(?<relation>$literal)\s+AND\s+RDB\`$FIELD_NAME\s*=\s*(?<field>$literal)$")
            if (-not $condition.Success) { throw 'Filtro de descricao de coluna desconhecido.' }
            $relation = Get-Identifier $condition.Groups['relation'].Value
            $field = Get-Identifier $condition.Groups['field'].Value
            return "COMMENT ON COLUMN $relation.$field IS $value;"
        }
        'INDICES' {
            $condition = [regex]::Match($where, "(?is)^RDB\`$INDEX_NAME\s*=\s*(?<name>$literal)$")
            if (-not $condition.Success) { throw 'Filtro de descricao de indice desconhecido.' }
            $name = Get-Identifier $condition.Groups['name'].Value
            return "COMMENT ON INDEX $name IS $value;"
        }
    }
    throw 'Tipo de descricao desconhecido.'
}

$starts = [regex]::Matches($sql, '(?im)^[ \t]*UPDATE[ \t]+RDB\$')
$output = New-Object Text.StringBuilder
$position = 0
foreach ($start in $starts) {
    if ($start.Index -lt $position) { throw 'Atualizacoes RDB$ sobrepostas.' }
    $end = Get-StatementEnd $sql $start.Index
    [void]$output.Append($sql.Substring($position, $start.Index - $position))
    [void]$output.Append((Convert-DescriptionUpdate $sql.Substring($start.Index, $end - $start.Index + 1)))
    $position = $end + 1
}
[void]$output.Append($sql.Substring($position))

$prepared = $output.ToString()
$names = [regex]::new('(?im)^[ \t]*SET\s+NAMES\s+ISO8859_1\s*;')
$autoDdl = [regex]::new('(?im)^[ \t]*SET\s+AUTODDL\s+ON\s*;')
if ($names.Matches($prepared).Count -ne 1 -or $autoDdl.Matches($prepared).Count -ne 1) {
    throw 'Cabecalho SQL do DBComparer fora do formato esperado.'
}

# Mantem AUTODDL ON para que cada comando DDL seja gravado independentemente
$prepared = $names.Replace($prepared, 'SET NAMES WIN1252;', 1)
$prepared = $autoDdl.Replace($prepared, 'SET AUTODDL ON;', 1)
$reconnect = [regex]::new('(?im)^[ \t]*RECONNECT\s*;')
$prepared = $reconnect.Replace($prepared, 'COMMIT;')
$prepared = $connectionPattern.Replace($prepared, '/* CONNECT omitido: conexao fornecida pelo batch. */', 1)

# Saneamento pre-DDL: resolve duplicatas e chaves orfas antes de criar constraints UNIQUE / FK
$fixExporta = @"
UPDATE EXPORTA_TITULOS SET EXPORTA_TITULOS.DESCRICAO_EXPTIT = SUBSTRING(EXPORTA_TITULOS.DESCRICAO_EXPTIT FROM 1 FOR 56) || ' ' || EXPORTA_TITULOS.CODIGO_EXPTIT WHERE EXPORTA_TITULOS.CODIGOTEKSYSTEM_EXPTIT IS NULL AND ((SELECT COUNT(1) FROM EXPORTA_TITULOS B WHERE B.DESCRICAO_EXPTIT = EXPORTA_TITULOS.DESCRICAO_EXPTIT) > 1);
COMMIT;
"@
$prepared = [regex]::Replace($prepared, '(?im)^[ \t]*ALTER\s+TABLE\s+EXPORTA_TITULOS\s+ADD\s+CONSTRAINT\s+UNQ1_EXPORTA_TITULOS\b', ($fixExporta + "`r`n`$0"))

$fixMotivo = @"
UPDATE MOTIVO M SET DESCRICAO_MOTIVO = DESCRICAO_MOTIVO || RPAD('', (SELECT COUNT(*) FROM MOTIVO M2 WHERE M2.TIPO_MOTIVO = M.TIPO_MOTIVO AND M2.DESCRICAO_MOTIVO = M.DESCRICAO_MOTIVO AND M2.RDB`$DB_KEY < M.RDB`$DB_KEY), '.') WHERE EXISTS (SELECT 1 FROM MOTIVO M3 WHERE M3.TIPO_MOTIVO = M.TIPO_MOTIVO AND M3.DESCRICAO_MOTIVO = M.DESCRICAO_MOTIVO AND M3.RDB`$DB_KEY < M.RDB`$DB_KEY);
COMMIT;
"@
$prepared = [regex]::Replace($prepared, '(?im)^[ \t]*ALTER\s+TABLE\s+MOTIVO\s+ADD\s+CONSTRAINT\s+UNQ1_MOTIVO\b', ($fixMotivo + "`r`n`$0"))

$fixMaq = @"
UPDATE MAQ_MANUTENCAO SET PROGRAMACAO_MANMAQ = NULL WHERE PROGRAMACAO_MANMAQ = 0 OR (PROGRAMACAO_MANMAQ IS NOT NULL AND NOT EXISTS (SELECT 1 FROM MAQ_PROGRAMACAOPARADAS P WHERE P.AUTOINC_PROGPARADA = MAQ_MANUTENCAO.PROGRAMACAO_MANMAQ));
COMMIT;
"@
$prepared = [regex]::Replace($prepared, '(?im)^[ \t]*ALTER\s+TABLE\s+MAQ_MANUTENCAO\s+ADD\s+CONSTRAINT\s+(?:UNQ1_MAQ_MANUTENCAO|FK_MAQ_MANUTENCAO_10)\b', ($fixMaq + "`r`n`$0"))

$prepared += "`r`nCOMMIT;`r`n"
[IO.File]::WriteAllText($ReportPath, $reportSql, $encoding)
[IO.File]::WriteAllText($OutputPath, $prepared, $encoding)