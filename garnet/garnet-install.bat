@echo off
rem Registers and starts the VyaptekGarnet service (garnet-service.exe is WinSW, garnet-service.xml its
rem config). Run by the installer on every install and upgrade, after write-secrets.ps1 wrote garnet.conf.
setlocal

set "GARNET_DIR=%~1"
if "%GARNET_DIR%"=="" set "GARNET_DIR=%~dp0"
if "%GARNET_DIR:~-1%"=="\" set "GARNET_DIR=%GARNET_DIR:~0,-1%"

cd /d "%GARNET_DIR%"

rem A box installed before Garnet ran the Windows Redis port as VyaptekRedis, on the same port. The
rem installer stopped it and deleted its files; remove the service too.
sc query VyaptekRedis >nul 2>&1
if %ERRORLEVEL% EQU 0 (
  sc stop VyaptekRedis >nul 2>&1
  sc delete VyaptekRedis >nul 2>&1
  timeout /t 3 /nobreak >nul
)

rem Re-register from scratch, so a changed garnet-service.xml always applies.
sc query VyaptekGarnet >nul 2>&1
if %ERRORLEVEL% EQU 0 (
  garnet-service.exe stop >nul 2>&1
  garnet-service.exe uninstall >nul 2>&1
  timeout /t 3 /nobreak >nul
)

garnet-service.exe install
if %ERRORLEVEL% NEQ 0 exit /b %ERRORLEVEL%

rem Not LocalSystem: the Network Service account, as the old Redis service ran. It reads garnet.conf
rem (write-secrets.ps1 grants it) and writes only its own logs folder.
if not exist "%GARNET_DIR%\logs" mkdir "%GARNET_DIR%\logs"
icacls "%GARNET_DIR%\logs" /grant "*S-1-5-20:(OI)(CI)M" >nul
sc config VyaptekGarnet obj= "NT AUTHORITY\NetworkService" password= "" >nul
if %ERRORLEVEL% NEQ 0 exit /b %ERRORLEVEL%

garnet-service.exe start
exit /b %ERRORLEVEL%
