@echo off
rem The superuser password: this box's own once write-secrets.ps1 has changed it (backend plan 24, I3),
rem else the installer's old fixed one. Arg 3 is the backend's config folder: the password is in
rem pg-superuser.secret (plan 24 section 11, OP1), or, on a box set up before that, in application.properties.
set PGPASSWORD=admin
set PG_BIN=%~1
set SQL_FILE=%~2
set "BOX_CONF_DIR=%~3"
set "BOX_PW="
if not "%BOX_CONF_DIR%"=="" if exist "%BOX_CONF_DIR%\pg-superuser.secret" (
  set /p BOX_PW=<"%BOX_CONF_DIR%\pg-superuser.secret"
) else if not "%BOX_CONF_DIR%"=="" if exist "%BOX_CONF_DIR%\application.properties" (
  for /f "usebackq tokens=1,* delims==" %%a in ("%BOX_CONF_DIR%\application.properties") do if "%%a"=="spring.datasource.password" set "BOX_PW=%%b"
)
set MAX_RETRIES=30
set ATTEMPT=0

:wait_loop
"%PG_BIN%\pg_isready.exe" -U postgres -h 127.0.0.1 -p 5432
if %errorlevel% equ 0 goto ready
set /a ATTEMPT+=1
if %ATTEMPT% geq %MAX_RETRIES% goto ready
timeout /t 2 /nobreak >nul
goto wait_loop

:ready
if defined BOX_PW (
  set "PGPASSWORD=%BOX_PW%"
  "%PG_BIN%\psql.exe" -h 127.0.0.1 -U postgres -d postgres -w -c "select 1" >nul 2>&1
  if errorlevel 1 set PGPASSWORD=admin
)
"%PG_BIN%\dropdb.exe"  -U postgres --if-exists hospital_erp
"%PG_BIN%\createdb.exe" -U postgres hospital_erp
"%PG_BIN%\psql.exe"    -U postgres -d hospital_erp -f "%SQL_FILE%"
