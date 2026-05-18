@echo off
set PGPASSWORD=admin
set PG_BIN=%~1
set SQL_FILE=%~2
set MAX_RETRIES=30
set ATTEMPT=0

:wait_loop
:: 1. Knock on the database door
"%PG_BIN%\pg_isready.exe" -U postgres -h 127.0.0.1 -p 5432
if %errorlevel% equ 0 goto ready

:: 2. If nobody answers, wait 2 seconds and try again (up to 60 seconds)
set /a ATTEMPT+=1
if %ATTEMPT% geq %MAX_RETRIES% goto ready
timeout /t 2 /nobreak >nul
goto wait_loop

:ready
:: 3. The door is open! Build the database immediately.
"%PG_BIN%\createdb.exe" -U postgres hospital_erp
"%PG_BIN%\psql.exe" -U postgres -d hospital_erp -f "%SQL_FILE%"