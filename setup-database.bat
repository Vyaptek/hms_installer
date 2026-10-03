@echo off
rem Brings the hospital database up to this release's schema and sets the backend's accounts (backend
rem plan 24 section 11, OP1). Runs the jar's BoxDatabaseSetup as the PostgreSQL superuser, whose password it
rem reads from backend\config\pg-superuser.secret itself; nothing secret is on this command line or in
rem the log. The backend then signs in as hospital_erp_user, which can only read and write rows.
rem Run by the installer on every install and upgrade, with the backend stopped. Arg 1: the HMS folder.
setlocal

set "APP=%~1"
if "%APP%"=="" set "APP=%~dp0"
if "%APP:~-1%"=="\" set "APP=%APP:~0,-1%"
set "LOG=%APP%\backend\logs\database-setup.log"
if not exist "%APP%\backend\logs" mkdir "%APP%\backend\logs"

rem PostgreSQL may still be starting (a fresh install, or a reboot just before): wait up to 60 seconds.
set ATTEMPT=0
:wait_loop
if not exist "%APP%\pgsql\bin\pg_isready.exe" goto ready
"%APP%\pgsql\bin\pg_isready.exe" -h 127.0.0.1 -p 5432 -q
if %ERRORLEVEL% EQU 0 goto ready
set /a ATTEMPT+=1
if %ATTEMPT% GEQ 30 goto ready
timeout /t 2 /nobreak >nul
goto wait_loop

:ready
"%APP%\jre\bin\java.exe" -cp "%APP%\backend\hms.jar" -Dloader.main=com.hospitalerp.common.boxdb.BoxDatabaseSetup org.springframework.boot.loader.launch.PropertiesLauncher --config-dir "%APP%\backend\config" > "%LOG%" 2>&1
exit /b %ERRORLEVEL%
