@echo off
REM ---------------------------------------------------------------------------
REM Free TCP port 80 for the Nginx web proxy.
REM
REM Port 80 is routinely held by the Windows IIS/HTTP stack (W3SVC + WAS), which
REM auto-starts at boot and beats Nginx to the port. Stopping is not enough -- the
REM services must also be DISABLED so they do not reclaim the port after a reboot.
REM
REM Runs during install (before Nginx starts) and is safe to re-run manually as a
REM repair tool:  right-click -> Run as administrator.
REM ---------------------------------------------------------------------------

echo Releasing port 80 for the Vyaptek HMS web server...

REM World Wide Web Publishing Service (IIS) -- the most common port 80 squatter.
sc stop   W3SVC                 >nul 2>&1
sc config W3SVC start= disabled >nul 2>&1

REM Windows Process Activation Service -- parent of W3SVC; /y also stops dependents.
net stop  WAS /y               >nul 2>&1
sc config WAS start= disabled  >nul 2>&1

REM SQL Server Reporting Services occasionally reserves port 80 via HTTP.sys too.
sc stop   ReportServer         >nul 2>&1

REM Give HTTP.sys a moment to release the binding before Nginx tries to bind.
ping -n 3 127.0.0.1 >nul

REM Diagnostic: show anything still holding port 80 (visible only if run manually).
echo.
echo Remaining listeners on port 80 (should be empty):
netstat -aon | findstr ":80 " | findstr "LISTENING"

exit /b 0
