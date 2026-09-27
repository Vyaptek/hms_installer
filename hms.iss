; Set by the CI workflow (/DAppVersion, /DLibreOfficeVersion); these defaults are for local builds.
#ifndef AppVersion
  #define AppVersion "0.0.0-local"
#endif
; The bundled libreoffice.msi's version, as soffice.exe reports it.
#ifndef LibreOfficeVersion
  #define LibreOfficeVersion "26.2.6.3"
#endif

[Setup]
ArchitecturesInstallIn64BitMode=x64compatible
AppId={{010389d7-9c59-4047-b368-0da2344ea258}}
AppName=Vyaptek HMS
AppVersion={#AppVersion}
VersionInfoProductTextVersion={#AppVersion}
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
  PGInstalled: Boolean;
  LibreOfficeChecked, LibreOfficeNeeded: Boolean;
  DBPage: TInputOptionWizardPage;
  AdminPage: TInputQueryWizardPage;

procedure InitializeWizard;
begin
  // Detect an existing postgres installation via its Windows service registry key.
  // This runs before any wizard page is shown so it is never affected by
  // WizardDirValue timing issues that plagued the earlier FileExists approach.
  PGInstalled := RegKeyExists(HKLM,
    'SYSTEM\CurrentControlSet\Services\postgresql-x64-18');

  DBPage := CreateInputOptionPage(wpSelectDir,
    'Existing Installation Detected',
    'PostgreSQL and the hospital database are already installed.',
    'How would you like to proceed?',
    True, False);
  DBPage.Add('Keep existing data (recommended — upgrades without data loss)');
  DBPage.Add('Fresh install — reinstall PostgreSQL and delete ALL hospital data (cannot be undone)');
  DBPage.SelectedValueIndex := 0;

  // A new database seeds admin@example.com with a password that is public (it is in the backend's
  // migrations). The password chosen here replaces it at the backend's first start.
  AdminPage := CreateInputQueryPage(DBPage.ID,
    'Administrator Password',
    'Choose the password for the admin@example.com account.',
    'The hospital database is new, so its administrator account needs a password. ' +
    'Use at least 10 characters: letters, digits and symbols, no spaces. It is not shown again.');
  AdminPage.Add('Administrator password:', True);
  AdminPage.Add('Confirm password:', True);
end;

function ShouldInstallPG: Boolean;
begin
  if PGInstalled then
    Result := DBPage.SelectedValueIndex = 1  // upgrade: reinstall only if user chose fresh install
  else
    Result := True;  // fresh machine — always install PG
end;

function ShouldCleanDB: Boolean;
begin
  Result := DBPage.SelectedValueIndex = 1;
end;

function ShouldInitDB: Boolean;
begin
  Result := not PGInstalled;  // only needed on a fresh install; upgrades preserve existing data
end;

// True when this run creates the database, so the seeded admin account is new.
function NeedsAdminPassword: Boolean;
begin
  Result := ShouldInitDB or ShouldCleanDB;
end;

function KeepsDatabase: Boolean;
begin
  Result := not NeedsAdminPassword;
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  if PageID = DBPage.ID then
    Result := not PGInstalled
  else if PageID = AdminPage.ID then
    Result := not NeedsAdminPassword
  else
    Result := False;
end;

function IsPrintableAsciiWithoutSpace(const S: String): Boolean;
var
  I: Integer;
begin
  Result := True;
  for I := 1 to Length(S) do
    if (Ord(S[I]) < $21) or (Ord(S[I]) > $7E) then
    begin
      Result := False;
      Exit;
    end;
end;

// Mirrors the backend's rules (PasswordPolicy) as far as the installer can check them. The backend
// also refuses the seeded password itself; it then logs "was not applied" and asks for a change at
// the first sign-in.
function NextButtonClick(CurPageID: Integer): Boolean;
var
  Pw, Problem: String;
begin
  Result := True;
  if CurPageID <> AdminPage.ID then
    Exit;
  Pw := AdminPage.Values[0];
  Problem := '';
  if Pw <> AdminPage.Values[1] then
    Problem := 'The two passwords do not match.'
  else if Length(Pw) < 10 then
    Problem := 'The password must be at least 10 characters.'
  else if Length(Pw) > 72 then
    Problem := 'The password must be at most 72 characters.'
  else if not IsPrintableAsciiWithoutSpace(Pw) then
    Problem := 'Use English letters, digits and symbols only, without spaces.'
  else if CompareText(Pw, 'admin@example.com') = 0 then
    Problem := 'The password must not be the user name.';
  if Problem <> '' then
  begin
    MsgBox(Problem, mbError, MB_OK);
    Result := False;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  // Handed to write-secrets.ps1 through a file in {tmp}, never on a command line: other users can
  // read process command lines. {tmp} is private to this run and deleted when it ends.
  if (CurStep = ssInstall) and NeedsAdminPassword and (AdminPage.Values[0] <> '') then
    SaveStringToFile(ExpandConstant('{tmp}\admin-password.txt'), AdminPage.Values[0], False);
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if (CurPageID = wpFinished) and NeedsAdminPassword and (AdminPage.Values[0] <> '') then
    WizardForm.FinishedLabel.Caption := WizardForm.FinishedLabel.Caption + #13#10#13#10 +
      'Sign in as admin@example.com with the administrator password you chose.';
end;

// Without the secret file the backend refuses to start, so say so rather than finish quietly.
procedure CheckSecretsWritten;
begin
  if not FileExists(ExpandConstant('{app}\backend\config\application.properties')) then
    SuppressibleMsgBox('The sign-in key file could not be created in ' +
      ExpandConstant('{app}\backend\config') + '. The HMS backend will not start until it exists. ' +
      'As an administrator run: powershell -ExecutionPolicy Bypass -File "' +
      ExpandConstant('{app}\write-secrets.ps1') + '" -ConfigDir "' + ExpandConstant('{app}\backend\config') +
      '", then start the VyaptekHMS service.',
      mbCriticalError, MB_OK, IDOK);
end;

// nginx answers only for host names it knows (backend plan 24, L5): localhost, IPv4 addresses (in
// nginx.conf) and this computer's name, written here. A name with other characters is left out, so it
// can never break the config; the hospital can list it in server-names-extra.conf.
procedure WriteServerNames;
var
  Name, Line: String;
  I: Integer;
  Valid: Boolean;
begin
  Name := Lowercase(GetComputerNameString);
  Valid := Name <> '';
  for I := 1 to Length(Name) do
    if not (((Name[I] >= 'a') and (Name[I] <= 'z')) or ((Name[I] >= '0') and (Name[I] <= '9')) or (Name[I] = '-')) then
      Valid := False;
  Line := '# Written by the installer: this computer''s name. Replaced on every install and upgrade.' + #13#10;
  if Valid then
    Line := Line + 'server_name ' + Name + ';' + #13#10;
  SaveStringToFile(ExpandConstant('{app}\nginx\conf\server-names.conf'), Line, False);
end;

// The backend turns reports into PDF with LibreOffice (backend optimization/21). Install the bundled
// one when the box has none or an older one; a newer one the hospital installed is left alone.
// Worked out once, because [Files] and [Run] both ask and [Run] comes after the copy.
function ShouldInstallLibreOffice: Boolean;
var
  Installed: String;
  InstalledPacked, BundledPacked: Int64;
begin
  if not LibreOfficeChecked then
  begin
    LibreOfficeNeeded := True;
    if GetVersionNumbersString(ExpandConstant('{commonpf64}\LibreOffice\program\soffice.exe'), Installed) and
       StrToVersion(Installed, InstalledPacked) and
       StrToVersion('{#LibreOfficeVersion}', BundledPacked) then
      LibreOfficeNeeded := ComparePackedVersion(InstalledPacked, BundledPacked) < 0;
    LibreOfficeChecked := True;
  end;
  Result := LibreOfficeNeeded;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Exec('sc.exe', 'stop VyaptekHMS',    '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec('sc.exe', 'stop NginxWebProxy', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec('sc.exe', 'stop VyaptekRedis',  '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Sleep(3000);
  Result := '';
end;

[InstallDelete]
; Wipe entire frontend dir so stale Vite-hashed assets don't accumulate
Type: filesandordirs; Name: "{app}\frontend"
; Remove old backend JAR before copying new one
Type: files; Name: "{app}\backend\hms.jar"
; Replace the Java runtime whole, so files a newer JRE dropped don't linger
Type: filesandordirs; Name: "{app}\jre"

[Files]
; 1. Java runtime — a private Temurin JRE that only the backend service uses (hms-service.xml).
;    It is not put on PATH or JAVA_HOME. Boxes installed before 2026-09 keep the Temurin 17 JDK the
;    old installer put there; HMS no longer uses it.
Source: "jre\*"; DestDir: "{app}\jre"; Flags: recursesubdirs createallsubdirs ignoreversion

;    Installers — extracted to temp and deleted after use
Source: "libreoffice.msi"; DestDir: "{tmp}"; Flags: deleteafterinstall nocompression; Check: ShouldInstallLibreOffice
Source: "pg.exe";   DestDir: "{tmp}"; Flags: deleteafterinstall; Check: ShouldInstallPG

; 2. Pre-flight SQL (extensions + role only — Flyway migrates on first backend start)
Source: "setup_database.sql"; DestDir: "{app}"
Source: "init_db.bat";        DestDir: "{app}"; Flags: deleteafterinstall
Source: "clean_db.bat";       DestDir: "{app}"; Flags: deleteafterinstall
Source: "free-port-80.bat";   DestDir: "{app}"

; 3. Backend (Spring Boot JAR + WinSW)
;    Never ship backend\config: it holds each box's own secrets, and copying one over an install
;    would replace that box's secret on every upgrade.
Source: "backend\*"; DestDir: "{app}\backend"; Excludes: "\config,\config\*"; Flags: recursesubdirs createallsubdirs
;    Kept on the box: it also gives an already-installed box its own secret (backend plan 24 §10).
Source: "write-secrets.ps1"; DestDir: "{app}"

; 4. Frontend (React/Vite build — assets/, index.html, etc.)
Source: "frontend\*"; DestDir: "{app}\frontend"; Excludes: "*.map"; Flags: recursesubdirs createallsubdirs

; 5. Nginx — skip contrib (editor plugins) and docs; logs\ and temp\ created by [Dirs]
Source: "nginx\nginx.exe"; DestDir: "{app}\nginx"
Source: "nginx\conf\*";    DestDir: "{app}\nginx\conf"; Excludes: "server-names.conf,server-names-extra.conf"; Flags: recursesubdirs createallsubdirs
;    This computer's name, written over the placeholder on every run (plan 24, L5).
Source: "nginx\conf\server-names.conf"; DestDir: "{app}\nginx\conf"; AfterInstall: WriteServerNames
;    The hospital's own host names for this box; theirs to edit, so never replaced.
Source: "nginx\conf\server-names-extra.conf"; DestDir: "{app}\nginx\conf"; Flags: onlyifdoesntexist uninsneveruninstall
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
; 1. PostgreSQL 18 — skipped if already installed and user chose to keep it
Filename: "{tmp}\pg.exe"; Parameters: "--mode unattended --unattendedmodeui none --superpassword ""admin"" --serverport 5432 --prefix ""{app}\pgsql"""; Flags: runhidden; StatusMsg: "Installing PostgreSQL 18..."; Check: ShouldInstallPG

; 2a. Clean install — drop existing DB, recreate, run SQL
Filename: "{app}\clean_db.bat"; Parameters: """{app}\pgsql\bin"" ""{app}\setup_database.sql"" ""{app}\backend\config\application.properties"""; Flags: runhidden; StatusMsg: "Resetting database..."; Check: ShouldCleanDB

; 2b. Fresh install only — create DB and run setup SQL (skipped on upgrades)
Filename: "{app}\init_db.bat"; Parameters: """{app}\pgsql\bin"" ""{app}\setup_database.sql"" ""{app}\backend\config\application.properties"""; Flags: runhidden; StatusMsg: "Initializing database..."; Check: ShouldInitDB

; 3. The box's own secrets (backend plan 24, C2, C6, I3): the sign-in key (kept on upgrade; a box that
;    never had one gets one, which logs everyone out once), the admin password on a new database, a
;    random PostgreSQL superuser password instead of "admin" (again when the database is new) and a
;    Redis password. Before Redis is (re)installed, so it starts with its password.
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\write-secrets.ps1"" -ConfigDir ""{app}\backend\config"" -AdminPasswordFile ""{tmp}\admin-password.txt"" -PgBin ""{app}\pgsql\bin"" -RedisConf ""{app}\redis\redis.windows-service.conf"" -NewDatabase"; Flags: runhidden waituntilterminated; StatusMsg: "Generating this computer's keys..."; Check: NeedsAdminPassword; AfterInstall: CheckSecretsWritten
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\write-secrets.ps1"" -ConfigDir ""{app}\backend\config"" -PgBin ""{app}\pgsql\bin"" -RedisConf ""{app}\redis\redis.windows-service.conf"""; Flags: runhidden waituntilterminated; StatusMsg: "Checking this computer's keys..."; Check: KeepsDatabase; AfterInstall: CheckSecretsWritten

; 4. Redis — use Redis native service installer.
;    Do NOT use sc create; Redis console mode is not a valid Windows service entrypoint.
Filename: "{app}\redis\redis-install.bat"; Parameters: """{app}\redis"""; Flags: runhidden; StatusMsg: "Registering and starting Redis..."
 
; 5. LibreOffice, for PDF reports. Without it the backend still runs, but every PDF fails.
;    REGISTER_NO_MSO_TYPES=1 leaves .docx/.xlsx opening in MS Office on PCs that have it.
Filename: "msiexec.exe"; Parameters: "/i ""{tmp}\libreoffice.msi"" /qn /norestart ADDLOCAL=ALL REMOVE=gm_o_Onlineupdate REGISTER_NO_MSO_TYPES=1 QUICKSTART=0 ISCHECKFORPRODUCTUPDATES=0 CREATEDESKTOPLINK=0 RebootYesNo=No UI_LANGS=en_US"; Flags: runhidden; StatusMsg: "Installing LibreOffice (PDF reports)..."; Check: ShouldInstallLibreOffice

; 6. Backend — Flyway migrates on first boot (may take ~30s on first install)
Filename: "{app}\backend\hms-service.exe"; Parameters: "install"; Flags: runhidden; StatusMsg: "Registering Backend Service..."
Filename: "{app}\backend\hms-service.exe"; Parameters: "start";   Flags: runhidden; StatusMsg: "Starting Backend API..."

; 7. Nginx + React frontend
;    Free port 80 first -- stop & disable the IIS/HTTP stack (W3SVC/WAS) that
;    otherwise squats on port 80 and prevents Nginx from binding.
Filename: "{app}\free-port-80.bat"; Flags: runhidden; StatusMsg: "Freeing web port 80..."
Filename: "{app}\nginx-service.exe"; Parameters: "install"; Flags: runhidden; StatusMsg: "Registering Web Server..."
Filename: "{app}\nginx-service.exe"; Parameters: "start";   Flags: runhidden; StatusMsg: "Starting User Interface..."

; 8. Firewall — port 80 only (Redis 6379, PG 5432, backend 8080 are localhost-only)
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

; backend\config (the box's secrets) is kept on uninstall on purpose: PostgreSQL is not uninstalled,
; and that file holds the only copy of its superuser password (backend plan 24, I3). The folder is
; readable by SYSTEM and Administrators only. Delete it by hand after removing PostgreSQL.