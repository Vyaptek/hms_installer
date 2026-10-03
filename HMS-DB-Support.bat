@echo off
rem Break-glass database login for Vyaptek support (backend plan 24 section 11, OP8): a pgAdmin login on
rem this computer for 4 hours. Double-click it; "HMS-DB-Support.bat -Superuser" gives full rights,
rem "HMS-DB-Support.bat -End" removes the logins. Asks for administrator rights.
net session >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
  exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0hms-db-support.ps1" %*
pause
