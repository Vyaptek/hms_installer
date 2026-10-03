@echo off
rem Puts an HMS backup back (backend plan 24 section 11, OP11): replaces this computer's HMS data with a
rem backup set, using the key Vyaptek gives for it. Double-click it; it asks for administrator rights
rem and walks through each step.
net session >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
  exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0restore-backup.ps1" %*
pause
