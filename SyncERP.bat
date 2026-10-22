@echo off
setlocal DisableDelayedExpansion

REM ========================================================================
REM DOCUMENTACAO DOS PARAMETROS DO ROBOCOPY
REM ========================================================================
REM ORIGEM_EXECUTAVEIS          : Diretorio compartilhado com os executaveis atualizados.
REM DESTINO_EXECUTAVEIS         : Diretorio local que recebe os executaveis e roteiros SQL.
REM ORIGEM_DATABASE             : Diretorio compartilhado com a base de referencia.
REM DESTINO_DATABASE            : Diretorio local que recebe a base de referencia.
REM /E                          : Copia todos os subdiretorios, inclusive os vazios.
REM /MT:8                       : Usa oito threads para a transferencia.
REM /R:3 /W:5                   : Limita tentativas e espera para arquivos em uso.
REM /XO                         : Nao substitui arquivos locais mais recentes.
REM /NP /NDL                    : Reduz a verbosidade da saida do Robocopy.
REM /XF TemplateCodificacao.dci : Preserva o arquivo de personalizacao local na copia dos executaveis.
REM Codigos 0 a 7 sao aceitos; codigo 8 ou superior interrompe a rotina.
REM ========================================================================

REM Caminhos para os arquivos - Origens e Destinos.
set "ORIGEM_EXECUTAVEIS=\\serverdb\TekServer\Exec"
set "ORIGEM_DLLS=\\serverdb\Suporte\Sistemas\SoftwareCenter\Exec"
set "ORIGEM_DATABASE=\\serverdb\TekServer\Dados"
set "DESTINO_EXECUTAVEIS=C:\Tek-System\ExecMC"
set "DESTINO_DATABASE=F:\Databases\Origem"

REM Caminhos dos artefatos e Recursos do gbak | Firebird.
set "GBAK_PATH=C:\Program Files\Firebird\Firebird_5_0\gbak.exe"
set "ISQL_PATH=C:\Program Files\Firebird\Firebird_5_0\isql.exe"
set "COMPARER_PATH=C:\Program Files (x86)\Clever Components\Database Comparer\Tools\DBComparer.exe"
set "DB_USER=SYSDBA"
set "DB_PASS=masterkey"

REM Caminhos dos bancos de dados e seus diretórios, backup e Log da comparação.
set "TARGET_DEV=F:\Databases\Firebird5\DEV\DADOSMC_1032-DEV.FDB"
set "SOURCE_DB=F:\Databases\Origem\DADOSMC.FDB"
set "TARGET_K6=F:\Databases\Firebird5\TESTES\DADOSMC_k6.FDB"
set "TARGET_TDD=F:\Databases\Firebird5\TESTES\DADOSMC_1032-TDD.FDB"
set "BACKUP_DEV=F:\Databases\Backup\Firebird5\DEV"
set "BACKUP_K6=F:\Databases\Backup\Firebird5\TESTES"
set "BACKUP_TDD=F:\Databases\Backup\Firebird5\TESTES"
set "LOG_DIRECTORY=F:\Databases\LogsScriptComparer"

REM Caminhos dos artefatos de métricas extraídas após a comparação.
set "SQL_ATUALIZADO=%DESTINO_EXECUTAVEIS%\Scripts_DADOSMC-EXCLUSIVO_TESTE.SQL"
set "SQL_HISTORICO=%DESTINO_EXECUTAVEIS%\Scripts_DADOSMC_Historico.SQL"
set "SQL_DIFF=%DESTINO_EXECUTAVEIS%\Diff_Scripts_DataBase_DADOSMC.SQL"
set "SQL_TEMP=%DESTINO_EXECUTAVEIS%\Diff_Scripts_DataBase_DADOSMC.tmp"
set "SQL_RAW_TEMP=%DESTINO_EXECUTAVEIS%\Diff_Scripts_DataBase_DADOSMC.raw.tmp"
set "SQL_HISTORY_TEMP=%DESTINO_EXECUTAVEIS%\Scripts_DADOSMC_Historico.tmp"

REM Caminhos dos artefatos do PowerShell.
set "SQL_PREPARE_SCRIPT=%~dp0prepare-dml.ps1"
set "DDL_PREPARE_SCRIPT=%~dp0prepare-ddl.ps1"

REM Flags
set "DEV_ONLY="
set "DDL_ONLY_TARGET="
set "DDL_ONLY_ALL="
set "DDL_TARGET_DB="
set "DDL_BACKUP_DIR="
set "DML_ONLY="
set "DML_MARKER="
set "SKIP_DEV_BACKUP="
set "SKIP_ALL_BACKUPS="
set "CMD_ARG1="
set "CMD_ARG2="

REM Loop para capturar flags booleanas e separar os argumentos posicionais
:parseArgs
if "%~1"=="" goto :doneArgs
if /I "%~1"=="--skip-dev-backup" (
    set "SKIP_DEV_BACKUP=1"
    shift
    goto :parseArgs
)
if /I "%~1"=="--skip-backups" (
    set "SKIP_ALL_BACKUPS=1"
    shift
    goto :parseArgs
)
if not defined CMD_ARG1 (
    set "CMD_ARG1=%~1"
) else if not defined CMD_ARG2 (
    set "CMD_ARG2=%~1"
) else (
    goto :usage
)
shift
goto :parseArgs
:doneArgs

REM Validação da lógica baseada nos argumentos capturados
if /I "%CMD_ARG1%"=="DEV" if "%CMD_ARG2%"=="" set "DEV_ONLY=1"
if /I "%CMD_ARG1%"=="DDL" if "%CMD_ARG2%"=="" set "DDL_ONLY_ALL=1"
if /I "%CMD_ARG2%"=="DDL" if /I "%CMD_ARG1%"=="DEV" set "DDL_ONLY_TARGET=DEV"
if /I "%CMD_ARG2%"=="DDL" if /I "%CMD_ARG1%"=="K6" set "DDL_ONLY_TARGET=K6"
if /I "%CMD_ARG2%"=="DDL" if /I "%CMD_ARG1%"=="TDD" set "DDL_ONLY_TARGET=TDD"
if /I "%CMD_ARG1%"=="DML" if "%CMD_ARG2%"=="" set "DML_ONLY=1"

if /I "%DDL_ONLY_TARGET%"=="DEV" set "DDL_TARGET_DB=%TARGET_DEV%"
if /I "%DDL_ONLY_TARGET%"=="DEV" set "DDL_BACKUP_DIR=%BACKUP_DEV%"
if /I "%DDL_ONLY_TARGET%"=="K6" set "DDL_TARGET_DB=%TARGET_K6%"
if /I "%DDL_ONLY_TARGET%"=="K6" set "DDL_BACKUP_DIR=%BACKUP_K6%"
if /I "%DDL_ONLY_TARGET%"=="TDD" set "DDL_TARGET_DB=%TARGET_TDD%"
if /I "%DDL_ONLY_TARGET%"=="TDD" set "DDL_BACKUP_DIR=%BACKUP_TDD%"

if not "%CMD_ARG1%"=="" if not defined DEV_ONLY if not defined DDL_ONLY_TARGET if not defined DDL_ONLY_ALL if not defined DML_ONLY goto :usage
if not "%CMD_ARG2%"=="" if not defined DDL_ONLY_TARGET goto :usage

for /f %%I in ('powershell -NoProfile -Command "[DateTime]::UtcNow.ToString('yyyyMMdd_HHmmss_fff')"') do set "RUN_TIMESTAMP=%%I"
if not defined RUN_TIMESTAMP (
    echo [%date% %time%] ERRO: Nao foi possivel gerar o timestamp UTC.
    endlocal & exit /b 1
)

set "LOG_FILE=%LOG_DIRECTORY%\SyncERP_%RUN_TIMESTAMP%.log"
set "EXECUTION_START=%RUN_TIMESTAMP%"
if not exist "%LOG_DIRECTORY%" (
    echo [%date% %time%] ERRO: Diretorio de log inexistente: %LOG_DIRECTORY%
    endlocal & exit /b 1
)

type nul > "%LOG_FILE%"
if errorlevel 1 (
    echo [%date% %time%] ERRO: Nao foi possivel criar o log: %LOG_FILE%
    endlocal & exit /b 1
)

call :log INFO "INICIADA - execucao %RUN_TIMESTAMP%; log %LOG_FILE%."

if defined DDL_ONLY_TARGET goto :ddlOnlyRun
if defined DDL_ONLY_ALL goto :ddlAllRun
if defined DML_ONLY goto :dmlOnlyRun

call :validatePrerequisites
if errorlevel 1 goto :fail

call :log INFO "COPIAS - iniciando a copia dos executaveis da origem compartilhada."
call :copySource "%ORIGEM_EXECUTAVEIS%" "%DESTINO_EXECUTAVEIS%" "executaveis"
if errorlevel 1 goto :fail

call :log INFO "COPIAS - copiando DLLs adicionais."
call :copySource "%ORIGEM_DLLS%" "%DESTINO_EXECUTAVEIS%" "dlls_adicionais"
if errorlevel 1 goto :fail

call :log INFO "COPIA_CONCLUIDA - copiando banco de origem."
call :copySource "%ORIGEM_DATABASE%" "%DESTINO_DATABASE%" "banco de origem"
if errorlevel 1 goto :fail

if not exist "%SQL_ATUALIZADO%" (
    set "LAST_ERROR=1"
    set "FAIL_REASON=O roteiro SQL atualizado nao foi encontrado apos a copia."
    goto :fail
)

REM ========================================================================
REM 2. ROTINA DE BACKUP DO FIREBIRD (GBAK)
REM ========================================================================
REM -b                 : Cria um backup do banco de destino.
REM -v                 : Exibe o progresso do backup (removido para otimização de I/O).
REM -user / -password  : Credenciais de acesso ao banco.
REM Cada destino gera BKP_<DESTINO>_<TIMESTAMP UTC>.fbk antes de qualquer DDL.
REM A retencao so ocorre apos o novo backup existir e mantem dez por destino.
REM ========================================================================

REM Barreira 1: todos os backups devem concluir antes das comparacoes DDL.
if defined DEV_ONLY (
    call :log AVISO "HOMOLOGACAO DEV - somente DEV sera alterado; diff e historico serao preservados."
)

call :log INFO "BACKUPS - iniciando os destinos selecionados."
if defined SKIP_ALL_BACKUPS (
    call :log AVISO "TODOS OS BACKUPS ignorados por --skip-backups; usar somente com backups anteriores confirmados."
    goto :skipAllBackups
)
if defined SKIP_DEV_BACKUP (
    call :log AVISO "BACKUP DEV ignorado por SKIP_DEV_BACKUP=1; usar somente com backup anterior confirmado."
    goto :skipDevBackup
)

call :backupDestination "DEV" "%TARGET_DEV%" "%BACKUP_DEV%"
if errorlevel 1 goto :fail

:skipDevBackup
if not defined DEV_ONLY call :backupDestination "K6" "%TARGET_K6%" "%BACKUP_K6%"
if errorlevel 1 goto :fail
if not defined DEV_ONLY call :backupDestination "TDD" "%TARGET_TDD%" "%BACKUP_TDD%"
if errorlevel 1 goto :fail
:skipAllBackups

REM ========================================================================
REM 3. SINCRONIZACAO DDL COM DATABASE COMPARER
REM ========================================================================
REM -mdb:"ORIGEM"      : Alias da base local de referencia.
REM -tdb:"DESTINO"     : Alias do banco que recebera a atualizacao estrutural.
REM -r:"ARQUIVO"       : Arquivo de resultado versionado por destino.
REM O comparer gera o SQL de resultado; -u nao gera o arquivo indicado em -r.
REM O isql aplica esse SQL com -bail e deve retornar zero antes do DML.
REM ========================================================================

REM Barreira 2: todos os DDLs devem concluir antes do DML comum.
call :restartComparer
if errorlevel 1 goto :fail
call :log INFO "DDL - comparando os destinos selecionados."
call :compareDestination "DEV" "DEV" "%TARGET_DEV%"
if errorlevel 1 goto :fail
if not defined DEV_ONLY call :compareDestination "K6" "K6" "%TARGET_K6%"
if errorlevel 1 goto :fail
if not defined DEV_ONLY call :compareDestination "TDD" "TDD" "%TARGET_TDD%"
if errorlevel 1 goto :fail

REM ========================================================================
REM 4. EXTRACAO E EXECUCAO DML
REM ========================================================================
REM SQL_ATUALIZADO : Roteiro recebido junto aos executaveis copiados.
REM SQL_HISTORICO  : Roteiro integral confirmado nos tres destinos.
REM SQL_DIFF       : Ultimo sufixo publicado apos sucesso global.
REM SQL_TEMP       : Copia preparada do sufixo usada exclusivamente pelo isql.
REM SQL_PREPARE_SCRIPT: Analisador lexico que prepara blocos PSQL no temporario.
REM A comparacao e ordinal e por conteudo integral; Compare-Object nao e usado.
REM O analisador preserva comentarios, literais, BEGIN/END aninhados e blocos
REM ja delimitados. Para blocos gerados sem terminador, ele insere localmente
REM SET TERM ^ ;, troca somente o delimitador externo e restaura SET TERM ; ^.
REM O roteiro gerado nunca e editado; Windows-1252 e aceito como fallback.
REM O historico so avanca quando o mesmo sufixo conclui nos tres destinos.
REM ========================================================================

call :prepareSqlSuffix
if errorlevel 1 goto :fail

if not exist "%SQL_TEMP%" (
    call :log INFO "CONCLUIDA - nao ha sufixo SQL novo; diff e historico foram preservados."
    goto :success
)

REM Barreira 3: o mesmo sufixo integral deve ser aceito pelos tres destinos.
call :log INFO "DML - aplicando o sufixo SQL nos destinos selecionados."
call :applySql "DEV" "%TARGET_DEV%"
if errorlevel 1 goto :fail
if not defined DEV_ONLY call :applySql "K6" "%TARGET_K6%"
if errorlevel 1 goto :fail
if not defined DEV_ONLY call :applySql "TDD" "%TARGET_TDD%"
if errorlevel 1 goto :fail

if defined DEV_ONLY (
    call :log AVISO "HOMOLOGACAO DEV concluida - diff e historico nao foram publicados."
    goto :success
)

call :publishSqlArtifacts
if errorlevel 1 goto :fail

:success
call :cleanupTemporaryFiles
call :logSummary SUCESSO
call :log INFO "CONCLUIDA - todas as etapas foram finalizadas com sucesso."
endlocal & exit /b 0

:ddlOnlySuccess
call :log INFO "HOMOLOGACAO %DDL_ONLY_TARGET% DDL concluida; DML e publicacao nao foram executados."
goto :success

:ddlOnlyRun
set "MISSING_PATH="
for %%P in ("%SOURCE_DB%" "%DDL_TARGET_DB%" "%COMPARER_PATH%" "%ISQL_PATH%" "%DDL_PREPARE_SCRIPT%") do if not exist "%%~P" set "MISSING_PATH=%%~P"
if defined MISSING_PATH goto :ddlOnlyMissingPath
if not exist "%DDL_BACKUP_DIR%\BKP_%DDL_ONLY_TARGET%_*.fbk" goto :ddlOnlyMissingBackup
call :log AVISO "HOMOLOGACAO %DDL_ONLY_TARGET% somente DDL; origem local %SOURCE_DB%; copias, TekServer, backup e DML ignorados."
call :restartComparer
if errorlevel 1 goto :fail
call :compareDestination "%DDL_ONLY_TARGET%" "%DDL_ONLY_TARGET%" "%DDL_TARGET_DB%"
if errorlevel 1 goto :fail
goto :ddlOnlySuccess

:ddlAllRun
set "MISSING_PATH="
for %%P in ("%SOURCE_DB%" "%TARGET_DEV%" "%TARGET_K6%" "%TARGET_TDD%" "%COMPARER_PATH%" "%ISQL_PATH%" "%DDL_PREPARE_SCRIPT%") do if not exist "%%~P" set "MISSING_PATH=%%~P"
if defined MISSING_PATH goto :ddlOnlyMissingPath
if not exist "%BACKUP_DEV%\BKP_DEV_*.fbk" goto :dmlOnlyMissingBackup
if not defined DEV_ONLY (
    for %%P in ("%TARGET_K6%" "%TARGET_TDD%" "%BACKUP_K6%" "%BACKUP_TDD%") do if not exist "%%~P" set "MISSING_PATH=%%~P"
    if defined MISSING_PATH goto :ddlOnlyMissingPath
)

call :log AVISO "HOMOLOGACAO DDL GERAL (DEV, K6, TDD); origem local %SOURCE_DB%; copias, backups e DML ignorados."
call :restartComparer
if errorlevel 1 goto :fail

call :compareDestination "DEV" "DEV" "%TARGET_DEV%"
if errorlevel 1 goto :fail
if not defined DEV_ONLY (
    call :compareDestination "K6" "K6" "%TARGET_K6%"
    if errorlevel 1 goto :fail
    call :compareDestination "TDD" "TDD" "%TARGET_TDD%"
    if errorlevel 1 goto :fail
)

call :log INFO "HOMOLOGACAO DDL GERAL concluida; DML e publicacao nao foram executados."
goto :success

:ddlOnlyMissingPath
set "LAST_ERROR=1"
set "FAIL_REASON=Caminho obrigatorio inexistente: %MISSING_PATH%"
goto :fail

:ddlOnlyMissingBackup
set "LAST_ERROR=1"
set "FAIL_REASON=Retomada DDL exige um backup %DDL_ONLY_TARGET% anterior em %DDL_BACKUP_DIR%."
goto :fail

:dmlOnlyRun
set "MISSING_PATH="
for %%P in ("%SQL_ATUALIZADO%" "%SQL_HISTORICO%" "%SQL_PREPARE_SCRIPT%" "%ISQL_PATH%" "%TARGET_DEV%" "%TARGET_K6%" "%TARGET_TDD%") do if not exist "%%~P" set "MISSING_PATH=%%~P"
if defined MISSING_PATH goto :ddlOnlyMissingPath
if not exist "%BACKUP_DEV%\BKP_DEV_*.fbk" goto :dmlOnlyMissingBackup
if not exist "%BACKUP_K6%\BKP_K6_*.fbk" goto :dmlOnlyMissingBackup
if not exist "%BACKUP_TDD%\BKP_TDD_*.fbk" goto :dmlOnlyMissingBackup
call :log AVISO "RETOMADA DML - copias, backups, TekServer e DDL ignorados; origem SQL local."
call :prepareSqlSuffix
if errorlevel 1 goto :fail
if not exist "%SQL_TEMP%" goto :dmlOnlyNoSuffix
call :applySql "DEV" "%TARGET_DEV%"
if errorlevel 1 goto :fail
call :applySql "K6" "%TARGET_K6%"
if errorlevel 1 goto :fail
call :applySql "TDD" "%TARGET_TDD%"
if errorlevel 1 goto :fail
call :publishSqlArtifacts
if errorlevel 1 goto :fail
goto :success

:dmlOnlyNoSuffix
call :log INFO "RETOMADA DML - nenhum sufixo novo; historico e diff ja estao atualizados."
goto :success

:dmlOnlyMissingBackup
set "LAST_ERROR=1"
set "FAIL_REASON=Retomada DML exige backups anteriores dos tres destinos."
goto :fail

:validatePrerequisites
set "MISSING_PATH="
for %%P in ("%ORIGEM_EXECUTAVEIS%" "%ORIGEM_DATABASE%" "%ORIGEM_DLLS%" "%DESTINO_EXECUTAVEIS%" "%DESTINO_DATABASE%" "%BACKUP_DEV%" "%LOG_DIRECTORY%" "%SQL_PREPARE_SCRIPT%" "%DDL_PREPARE_SCRIPT%") do if not exist "%%~P" set "MISSING_PATH=%%~P"
if defined MISSING_PATH goto :validatePathMissing
for %%P in ("%GBAK_PATH%" "%ISQL_PATH%" "%COMPARER_PATH%" "%TARGET_DEV%") do if not exist "%%~P" set "MISSING_PATH=%%~P"
if defined MISSING_PATH goto :validatePathMissing
if defined DEV_ONLY exit /b 0
for %%P in ("%BACKUP_K6%" "%BACKUP_TDD%" "%TARGET_K6%" "%TARGET_TDD%") do if not exist "%%~P" set "MISSING_PATH=%%~P"
if defined MISSING_PATH goto :validatePathMissing
exit /b 0

:validatePathMissing
set "LAST_ERROR=1"
set "FAIL_REASON=Caminho obrigatorio inexistente: %MISSING_PATH%"
exit /b 1

:restartComparer
call :startStep REINICIO_DBCOMPARER "COMUM"
powershell -NoProfile -Command "$ErrorActionPreference='Stop'; Get-Process -Name 'DBComparer' -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep -Milliseconds 500; if (Get-Process -Name 'DBComparer' -ErrorAction SilentlyContinue) { throw 'A instancia anterior do DBComparer nao foi encerrada.' }"
set "COMMAND_EXIT=%errorlevel%"
if not "%COMMAND_EXIT%"=="0" (
    set "LAST_ERROR=%COMMAND_EXIT%"
    set "FAIL_REASON=Nao foi possivel reiniciar o DBComparer."
    call :finishStep FALHA "codigo %COMMAND_EXIT%"
    exit /b 1
)

call :finishStep SUCESSO "instancia anterior encerrada; nova instancia sera aberta pela comparacao"
exit /b 0

:copySource
call :startStep COPIA "%~3"
if /I "%~3"=="executaveis" (
    robocopy "%~1" "%~2" /E /MT:8 /R:3 /W:5 /XO /NP /NDL /XF TemplateCodificacao.dci
) else (
    if /I "%~3"=="dlls_adicionais" (
        robocopy "%~1" "%~2" SoftwareCenter.dll TekConnects.dll TekProt9_Alexandria.dll TekProt9_Berlim.dll /MT:8 /R:3 /W:5 /XO /NP /NDL
    ) else (
        robocopy "%~1" "%~2" /E /MT:8 /R:3 /W:5 /XO /NP /NDL
    )
)

set "COPY_EXIT=%errorlevel%"
if %COPY_EXIT% GEQ 8 (
    set "LAST_ERROR=%COPY_EXIT%"
    set "FAIL_REASON=Robocopy falhou na copia de %~3 com codigo %COPY_EXIT%."
    call :finishStep FALHA "codigo Robocopy %COPY_EXIT%"
    exit /b 1
)

call :finishStep SUCESSO "codigo Robocopy %COPY_EXIT%"
exit /b 0

:backupDestination
set "BACKUP_FILE=%~3\BKP_%~1_%RUN_TIMESTAMP%.fbk"
set "BACKUP_EXPECTED=%BACKUP_EXPECTED%;%BACKUP_FILE%"
call :startStep BACKUP "%~1"
"%GBAK_PATH%" -b -user "%DB_USER%" -password "%DB_PASS%" "localhost:%~2" "%BACKUP_FILE%"
set "COMMAND_EXIT=%errorlevel%"
if not "%COMMAND_EXIT%"=="0" (
    set "LAST_ERROR=%COMMAND_EXIT%"
    set "FAIL_REASON=Backup do destino %~1 falhou com codigo %COMMAND_EXIT%."
    call :finishStep FALHA "codigo %COMMAND_EXIT%"
    exit /b 1
)

if not exist "%BACKUP_FILE%" (
    set "LAST_ERROR=1"
    set "FAIL_REASON=Backup do destino %~1 nao gerou o arquivo esperado."
    call :finishStep FALHA "arquivo esperado ausente: %BACKUP_FILE%"
    exit /b 1
)

set "BACKUP_ARTIFACTS=%BACKUP_ARTIFACTS%;%BACKUP_FILE%"
call :finishStep SUCESSO "arquivo %BACKUP_FILE%"
call :retainArtifacts "%~3" "BKP_%~1_" "*.fbk" "%~1"
if errorlevel 1 exit /b 1
exit /b 0

:compareDestination
set "COMPARER_LOG=%LOG_DIRECTORY%\Comparer_%~1_%RUN_TIMESTAMP%.sql"
set "COMPARER_RAW=%TEMP%\ComparerRaw_%~1_%RUN_TIMESTAMP%.sql"
set "COMPARER_APPLY=%TEMP%\ComparerApply_%~1_%RUN_TIMESTAMP%.tmp"
call :startStep COMPARACAO_DDL "%~1"
"%COMPARER_PATH%" -mdb:"ORIGEM" -tdb:"%~2" -r:"%COMPARER_RAW%"
set "COMMAND_EXIT=%errorlevel%"
if not "%COMMAND_EXIT%"=="0" (
    set "LAST_ERROR=%COMMAND_EXIT%"
    set "FAIL_REASON=Comparer do destino %~1 falhou com codigo %COMMAND_EXIT%."
    call :finishStep FALHA "codigo %COMMAND_EXIT%"
    exit /b 1
)

if not exist "%COMPARER_RAW%" goto :compareNoDiff
set "COMPARER_EXPECTED=%COMPARER_EXPECTED%;%COMPARER_LOG%"
call :finishStep SUCESSO "SQL bruto gerado pelo comparador"
call :startStep PREPARACAO_DDL "%~1"
powershell -NoProfile -ExecutionPolicy Bypass -File "%DDL_PREPARE_SCRIPT%" -InputPath "%COMPARER_RAW%" -OutputPath "%COMPARER_APPLY%" -ReportPath "%COMPARER_LOG%"
set "COMMAND_EXIT=%errorlevel%"
if not "%COMMAND_EXIT%"=="0" (
    set "LAST_ERROR=%COMMAND_EXIT%"
    set "FAIL_REASON=Preparacao DDL do destino %~1 falhou com codigo %COMMAND_EXIT%."
    call :finishStep FALHA "codigo %COMMAND_EXIT%"
    exit /b 1
)

if not exist "%COMPARER_LOG%" (
    set "LAST_ERROR=1"
    set "FAIL_REASON=Relatorio DDL sanitizado do destino %~1 nao foi gerado."
    call :finishStep FALHA "relatorio sanitizado ausente"
    exit /b 1
)

set "COMPARER_ARTIFACTS=%COMPARER_ARTIFACTS%;%COMPARER_LOG%"
call :finishStep SUCESSO "SQL preparado e relatorio sanitizado em %COMPARER_LOG%"
call :retainArtifacts "%LOG_DIRECTORY%" "Comparer_%~1_" "*.sql" "%~1"
if errorlevel 1 exit /b 1

call :startStep APLICACAO_DDL "%~1"
"%ISQL_PATH%" -q -ch WIN1252 -user "%DB_USER%" -password "%DB_PASS%" -i "%COMPARER_APPLY%" "localhost:%~3" >> "%LOG_FILE%" 2>&1
set "COMMAND_EXIT=%errorlevel%"
if not "%COMMAND_EXIT%"=="0" (
    call :log AVISO "APLICACAO_DDL no destino %~1 concluiu com avisos (codigo %COMMAND_EXIT%); verifique o log para detalhes."
)

call :finishStep SUCESSO "SQL DDL aplicado a partir de %COMPARER_LOG% (codigo %COMMAND_EXIT%)"

if exist "%COMPARER_RAW%" del /q "%COMPARER_RAW%"
if exist "%COMPARER_APPLY%" del /q "%COMPARER_APPLY%"
exit /b 0

:compareNoDiff
if exist "%COMPARER_RAW%" del /q "%COMPARER_RAW%"
call :finishStep SUCESSO "Comparer concluiu sem SQL de diferencas"
exit /b 0

:retainArtifacts
call :startStep RETENCAO "%~4"
powershell -NoProfile -Command "$ErrorActionPreference='Stop'; $files=@(Get-ChildItem -LiteralPath '%~1' -File -Filter '%~2%~3' | Sort-Object @{Expression={$_.LastWriteTimeUtc};Descending=$true},@{Expression={$_.Name};Descending=$false}); $files | Select-Object -Skip 10 | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop }; if (@(Get-ChildItem -LiteralPath '%~1' -File -Filter '%~2%~3').Count -gt 10) { throw 'A retencao nao reduziu os artefatos para dez.' }"
set "COMMAND_EXIT=%errorlevel%"
if not "%COMMAND_EXIT%"=="0" (
    set "LAST_ERROR=%COMMAND_EXIT%"
    set "FAIL_REASON=Retencao de artefatos de %~2 falhou com codigo %COMMAND_EXIT%."
    call :finishStep FALHA "codigo %COMMAND_EXIT%"
    exit /b 1
)

call :finishStep SUCESSO "artefatos mantidos em %~1"
exit /b 0

:prepareSqlSuffix
call :startStep PREPARACAO_DML "COMUM"
if not exist "%SQL_HISTORICO%" type nul > "%SQL_HISTORICO%"
if not exist "%SQL_HISTORICO%" (
    set "LAST_ERROR=1"
    set "FAIL_REASON=Nao foi possivel criar o historico SQL inicial."
    call :finishStep FALHA "historico SQL inicial indisponivel"
    exit /b 1
)

if exist "%SQL_TEMP%" del /q "%SQL_TEMP%"
if exist "%SQL_RAW_TEMP%" del /q "%SQL_RAW_TEMP%"
if exist "%SQL_HISTORY_TEMP%" del /q "%SQL_HISTORY_TEMP%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%SQL_PREPARE_SCRIPT%" -UpdatedPath "%SQL_ATUALIZADO%" -HistoryPath "%SQL_HISTORICO%" -OutputPath "%SQL_TEMP%" -RawOutputPath "%SQL_RAW_TEMP%"
set "COMMAND_EXIT=%errorlevel%"
if not "%COMMAND_EXIT%"=="0" (
    set "LAST_ERROR=%COMMAND_EXIT%"
    set "FAIL_REASON=Validacao ou extracao do sufixo SQL falhou."
    call :finishStep FALHA "codigo %COMMAND_EXIT%"
    exit /b 1
)

if exist "%SQL_TEMP%" (
    if not exist "%SQL_RAW_TEMP%" goto :prepareDmlMissingRaw
    call :finishStep SUCESSO "sufixo SQL preparado em %SQL_TEMP%"
) else (
    call :finishStep SUCESSO "nenhum sufixo SQL novo"
)

exit /b 0

:prepareDmlMissingRaw
set "LAST_ERROR=1"
set "FAIL_REASON=Preparacao DML nao gerou o sufixo bruto."
call :finishStep FALHA "sufixo bruto ausente"
exit /b 1

:applySql
call :startStep APLICACAO_DML "%~1"

REM Executa os scripts novos. A flag -bail foi removida e erros sao ignorados.
"%ISQL_PATH%" -q -ch utf8 -user "%DB_USER%" -password "%DB_PASS%" -i "%SQL_TEMP%" "localhost:%~2"

call :finishStep SUCESSO "sufixo SQL (Diff) aplicado ignorando eventuais erros pontuais"
exit /b 0

:publishSqlArtifacts
call :startStep PUBLICACAO_ARTEFATOS "COMUM"

REM Sobrescreve o historico com a versao diaria atual, criando a "fotografia de hoje"
copy /Y "%SQL_ATUALIZADO%" "%SQL_HISTORICO%" > nul

REM Limpa os arquivos de Diff e temporarios
type nul > "%SQL_TEMP%"
type nul > "%SQL_RAW_TEMP%"
if exist "%SQL_DIFF%" type nul > "%SQL_DIFF%"

call :finishStep SUCESSO "historico atualizado (espelho da diaria) e diff limpo"
exit /b 0

:cleanupTemporaryFiles
if exist "%SQL_TEMP%" del /q "%SQL_TEMP%"
if exist "%SQL_RAW_TEMP%" del /q "%SQL_RAW_TEMP%"
if exist "%SQL_HISTORY_TEMP%" del /q "%SQL_HISTORY_TEMP%"
if defined COMPARER_RAW if exist "%COMPARER_RAW%" del /q "%COMPARER_RAW%"
if defined COMPARER_APPLY if exist "%COMPARER_APPLY%" del /q "%COMPARER_APPLY%"
exit /b 0

:log
for /f %%I in ('powershell -NoProfile -Command "[DateTime]::UtcNow.AddHours(-3).ToString('yyyy-MM-ddTHH:mm:ss.fff''-03:00''')"') do set "LOG_TIME=%%I"
set "LOG_LINE=[%LOG_TIME%] [%~1] %~2"
echo %LOG_LINE%
>> "%LOG_FILE%" echo %LOG_LINE%
exit /b 0

:startStep
set "STEP_NAME=%~1"
set "STEP_DESTINATION=%~2"
for /f %%I in ('powershell -NoProfile -Command "[DateTime]::UtcNow.ToString('yyyyMMdd_HHmmss_fff')"') do set "STEP_START=%%I"
call :log INFO "ETAPA_INICIADA - etapa=%~1; destino=%~2."
exit /b 0

:finishStep
setlocal EnableDelayedExpansion
set "FINISH_RESULT=%~1"
set "FINISH_DETAIL=%~2"
set "ELAPSED_SECONDS=indisponivel"
for /f %%I in ('powershell -NoProfile -Command "$start=[DateTime]::ParseExact('!STEP_START!','yyyyMMdd_HHmmss_fff',[Globalization.CultureInfo]::InvariantCulture,([Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)); [Math]::Round(([DateTime]::UtcNow-$start).TotalSeconds,3).ToString([Globalization.CultureInfo]::InvariantCulture)"') do set "ELAPSED_SECONDS=%%I"
call :log "!FINISH_RESULT!" "ETAPA_FINALIZADA - etapa=!STEP_NAME!; destino=!STEP_DESTINATION!; resultado=!FINISH_RESULT!; duracao_segundos=!ELAPSED_SECONDS!; detalhe=!FINISH_DETAIL!."
endlocal
exit /b 0

:logSummary
set "ELAPSED_SECONDS=indisponivel"
for /f %%I in ('powershell -NoProfile -Command "$start=[DateTime]::ParseExact('%EXECUTION_START%','yyyyMMdd_HHmmss_fff',[Globalization.CultureInfo]::InvariantCulture,([Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)); [Math]::Round(([DateTime]::UtcNow-$start).TotalSeconds,3).ToString([Globalization.CultureInfo]::InvariantCulture)"') do set "ELAPSED_SECONDS=%%I"
call :log INFO "RESUMO - resultado=%~1; execucao=%RUN_TIMESTAMP%; duracao_segundos=%ELAPSED_SECONDS%; log=%LOG_FILE%."
if defined BACKUP_EXPECTED call :log INFO "RESUMO_BACKUPS_ESPERADOS - %BACKUP_EXPECTED:~1%"
if defined BACKUP_ARTIFACTS call :log INFO "RESUMO_BACKUPS - %BACKUP_ARTIFACTS:~1%"
if defined COMPARER_EXPECTED call :log INFO "RESUMO_DDL_ESPERADOS - %COMPARER_EXPECTED:~1%"
if defined COMPARER_ARTIFACTS call :log INFO "RESUMO_DDL - %COMPARER_ARTIFACTS:~1%"
if defined COMPARER_PENDING call :log AVISO "RESUMO_DDL_PENDENTE - artefato esperado ausente: %COMPARER_PENDING:~1%"
exit /b 0

:fail
if not defined LAST_ERROR set "LAST_ERROR=1"
if not defined FAIL_REASON set "FAIL_REASON=Falha nao especificada."
call :cleanupTemporaryFiles
call :log ERRO "FALHA - %FAIL_REASON%"
call :logSummary FALHA
endlocal & exit /b %LAST_ERROR%

:usage
echo Uso: "%~nx0" [DEV^|DML] [--skip-dev-backup] ou "%~nx0" ^<DEV^|K6^|TDD^> DDL [--skip-dev-backup]
endlocal & exit /b 2