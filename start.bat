@echo off
title Zero Company MP
cd /d "%~dp0"
chcp 65001 >nul 2>&1

echo.
echo  +======================================+
echo     STAR WARS ZERO COMPANY MP
echo  +======================================+
echo.

:: Verificar Python
python --version >nul 2>&1
if errorlevel 1 (
    echo  [ERRO] Python nao encontrado.
    echo  Instala Python 3.10+ em https://python.org
    echo  Marca "Add to PATH" durante a instalacao.
    echo.
    pause
    exit /b 1
)

:: Instalar dependencias
python -c "import websockets" >nul 2>&1
if errorlevel 1 (
    echo  Instalando websockets...
    python -m pip install websockets -q
    if errorlevel 1 (
        echo  [ERRO] Nao foi possivel instalar websockets.
        pause
        exit /b 1
    )
)

:: Matar instancia anterior
taskkill /F /FI "WINDOWTITLE eq ZeroCompanyMP-Server*" /IM python.exe >nul 2>&1
timeout /t 1 /nobreak >nul

:: Lancar servidor com watchdog
echo  Iniciando servidor...
start "ZeroCompanyMP-Server" /min cmd /c "title ZeroCompanyMP-Server && :loop && python server.py && timeout /t 3 /nobreak >nul && goto loop"

:: Aguardar servidor ficar pronto
set TRIES=0
:wait_loop
set /a TRIES+=1
python -c "import urllib.request,sys; urllib.request.urlopen('http://localhost:8766/api/config',timeout=2); sys.exit(0)" >nul 2>&1
if not errorlevel 1 goto server_ok
if %TRIES% GEQ 10 (
    echo  [ERRO] Servidor nao respondeu apos 10 tentativas.
    echo  Verifica se ha erros na janela ZeroCompanyMP-Server.
    pause
    exit /b 1
)
timeout /t 1 /nobreak >nul
goto wait_loop

:server_ok
echo  [OK] Servidor pronto em http://localhost:8766
echo.
echo  Abrindo interface do host...
start http://localhost:8766
echo.
echo  IPs locais (so funciona na mesma rede):
for /f "tokens=2 delims=:" %%a in ('ipconfig ^| findstr /c:"IPv4"') do (
    for /f "tokens=1" %%b in ("%%a") do echo     http://%%b:8766
)
echo.
echo  Servidor a correr em background. Fecha esta janela para parar.
echo  Para reiniciar: executa start.bat novamente.
pause
