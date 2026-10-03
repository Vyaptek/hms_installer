@echo off
rem Runs a database fix Vyaptek signed for this computer (backend plan 24 section 11, OP1). Drag the
rem fix's .sql file onto this file; its .sig file must be next to it. Asks for administrator rights.
if "%~1"=="" (
  echo Drag the fix's .sql file onto Run-HMS-Fix.bat. Its .sig file must be in the same folder.
  pause
  exit /b 2
)
net session >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '\"%~f1\"' -Verb RunAs"
  exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run-hms-fix.ps1" -SqlFile "%~f1"
pause
