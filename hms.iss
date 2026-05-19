[Setup]
ArchitecturesInstallIn64BitMode=x64compatible
AppId={{010389d7-9c59-4047-b368-0da2344ea258}}
AppName=Vyaptek HMS
AppVersion=1.0
AppPublisher=Vyaptek
DefaultDirName={autopf}\Vyaptek\HMS
OutputDir=userdocs:InnoSetupOutput
OutputBaseFilename=HMSSetup
PrivilegesRequired=admin
MinVersion=10.0
CloseApplications=yes

[Dirs]
; nginx requires these directories to exist before it will start
Name: "{app}\nginx\logs"
Name: "{app}\nginx\temp"

[Code]
var
  ResultCode: Integer;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  // Stop all services before wipe+copy so no files are locked
  Exec('sc.exe', 'stop VyaptekHMS',   '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec('sc.exe', 'stop NginxWebProxy', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec('sc.exe', 'stop VyaptekRedis', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Sleep(3000);
  Result := '';
end;

[InstallDelete]
; Wipe entire frontend dir so stale Vite-hashed assets don't accumulate
Type: filesandordirs; Name: "{app}\frontend"
; Remove old backend JAR before copying new one
Type: files; Name: "{app}\backend\hms.jar"

[Files]
; 1. Installers — extracted to temp and deleted after use
Source: "java.msi"; DestDir: "{tmp}"; Flags: deleteafterinstall
Source: "pg.exe";   DestDir: "{tmp}"; Flags: deleteafterinstall

; 2. Pre-flight SQL (extensions + role only — Flyway runs V1-V32 on first backend start)
Source: "setup_database.sql"; DestDir: "{app}"
Source: "init_db.bat";        DestDir: "{app}"; Flags: deleteafterinstall

; 3. Backend (Spring Boot JAR + WinSW)
Source: "backend\*"; DestDir: "{app}\backend"; Flags: recursesubdirs createallsubdirs

; 4. Frontend (React/Vite build — assets/, index.html, etc.)
Source: "frontend\*"; DestDir: "{app}\frontend"; Flags: recursesubdirs createallsubdirs

; 5. Nginx — skip contrib (editor plugins) and docs; logs\ and temp\ created by [Dirs]
Source: "nginx\nginx.exe"; DestDir: "{app}\nginx"
Source: "nginx\conf\*";    DestDir: "{app}\nginx\conf"; Flags: recursesubdirs createallsubdirs
Source: "nginx\html\*";    DestDir: "{app}\nginx\html"; Flags: recursesubdirs createallsubdirs
Source: "nginx-service.exe"; DestDir: "{app}"
Source: "nginx-service.xml"; DestDir: "{app}"

; 6. Redis — server, config, and install script only
;    No .pdb debug symbols, no benchmark/check tools, no WinSW (using sc create instead)
Source: "redis\redis-server.exe";           DestDir: "{app}\redis"
Source: "redis\EventLog.dll";               DestDir: "{app}\redis"
Source: "redis\redis.windows-service.conf"; DestDir: "{app}\redis"
Source: "redis\redis-install.bat";          DestDir: "{app}\redis"

[Run]
; 1. Java 17
Filename: "msiexec.exe"; Parameters: "/i ""{tmp}\java.msi"" /qn ADDLOCAL=FeatureMain,FeatureEnvironment,FeatureJavaHome"; Flags: runhidden; StatusMsg: "Installing Java Runtime Environment..."

; 2. PostgreSQL 18 — installed into app-local folder
Filename: "{tmp}\pg.exe"; Parameters: "--mode unattended --unattendedmodeui none --superpassword ""admin"" --serverport 5432 --prefix ""{app}\pgsql"""; Flags: runhidden; StatusMsg: "Installing PostgreSQL 18..."

; 3. Database init — waits for PG, creates hospital_erp DB, runs extension SQL
Filename: "{app}\init_db.bat"; Parameters: """{app}\pgsql\bin"" ""{app}\setup_database.sql"""; Flags: runhidden; StatusMsg: "Initializing database..."

; 4. Redis — sc create bypasses WinSW AddAceToObjectsSecurityDescriptor bug on Windows 10/11
;    redis-install.bat registers AND starts the VyaptekRedis service in one call
Filename: "{app}\redis\redis-install.bat"; Parameters: """{app}\redis"""; Flags: runhidden; StatusMsg: "Registering and starting Redis..."

; 5. Backend — Flyway runs V1-V32 on first boot (may take ~30s on first install)
Filename: "{app}\backend\hms-service.exe"; Parameters: "install"; Flags: runhidden; StatusMsg: "Registering Backend Service..."
Filename: "{app}\backend\hms-service.exe"; Parameters: "start";   Flags: runhidden; StatusMsg: "Starting Backend API..."

; 6. Nginx + React frontend
Filename: "{app}\nginx-service.exe"; Parameters: "install"; Flags: runhidden; StatusMsg: "Registering Web Server..."
Filename: "{app}\nginx-service.exe"; Parameters: "start";   Flags: runhidden; StatusMsg: "Starting User Interface..."

; 7. Firewall — port 80 only (Redis 6379, PG 5432, backend 8080 are localhost-only)
Filename: "{cmd}"; Parameters: "/c ""netsh advfirewall firewall add rule name=""Vyaptek HMS Web"" dir=in action=allow protocol=TCP localport=80 profile=any"""; Flags: runhidden; StatusMsg: "Configuring Windows Firewall..."

[UninstallRun]
; Stop and remove in reverse startup order
Filename: "{app}\nginx-service.exe";         Parameters: "stop";      Flags: runhidden
Filename: "{app}\nginx-service.exe";         Parameters: "uninstall"; Flags: runhidden
Filename: "{app}\backend\hms-service.exe";   Parameters: "stop";      Flags: runhidden
Filename: "{app}\backend\hms-service.exe";   Parameters: "uninstall"; Flags: runhidden
Filename: "{sys}\sc.exe"; Parameters: "stop VyaptekRedis";   Flags: runhidden
Filename: "{sys}\sc.exe"; Parameters: "delete VyaptekRedis"; Flags: runhidden
Filename: "{cmd}"; Parameters: "/c ""netsh advfirewall firewall delete rule name=""Vyaptek HMS Web"""""; Flags: runhidden; RunOnceId: "RemoveFirewallRule"