@echo off
setlocal

set "REDIS_DIR=%~1"
if "%REDIS_DIR%"=="" set "REDIS_DIR=%~dp0"
if "%REDIS_DIR:~-1%"=="\" set "REDIS_DIR=%REDIS_DIR:~0,-1%"

cd /d "%REDIS_DIR%"

rem Stop old Redis service if present
sc query VyaptekRedis >nul 2>&1
if %ERRORLEVEL% EQU 0 (
  net stop VyaptekRedis >nul 2>&1
  redis-server.exe --service-uninstall --service-name VyaptekRedis >nul 2>&1
  sc delete VyaptekRedis >nul 2>&1
  timeout /t 5 /nobreak >nul
)

rem Install using Redis native service installer, not sc create
redis-server.exe --service-install redis.windows-service.conf --service-name VyaptekRedis
if %ERRORLEVEL% NEQ 0 exit /b %ERRORLEVEL%

sc config VyaptekRedis start= auto >nul 2>&1
sc description VyaptekRedis "Redis Cache Server for Vyaptek HMS" >nul 2>&1

net start VyaptekRedis
exit /b %ERRORLEVEL%