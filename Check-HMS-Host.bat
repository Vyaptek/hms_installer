@echo off
rem Host security report for the HMS server (backend plan 24 section 11, OP12): BitLocker, antivirus,
rem firewall, SMBv1, Remote Desktop, pending updates, the HMS services and listening ports. Reads only.
rem Double-click it; it asks for administrator rights and opens the report when done.
net session >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0check-host.ps1"
