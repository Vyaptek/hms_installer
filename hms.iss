; Set by the CI workflow (/DAppVersion, /DLibreOfficeVersion); these defaults are for local builds.
#ifndef AppVersion
  #define AppVersion "0.0.0-local"
#endif
; The bundled libreoffice.msi's version, as soffice.exe reports it.
#ifndef LibreOfficeVersion
  #define LibreOfficeVersion "26.2.6.3"
#endif
; Vyaptek's ABDM relay. Fixed in the build, not typed at the hospital, so the product key used to set
; ABDM up can only ever be sent to Vyaptek.
#ifndef AbdmRelayUrl
  #define AbdmRelayUrl "https://api.vyaptek.com"
#endif
; Vyaptek's license server (backend optimization/26_PRODUCT_KEY_LICENSING.md), on the same host. Fixed
; in the build for the same reason: a product key is only ever sent to Vyaptek.
#ifndef LicenseServerUrl
  #define LicenseServerUrl AbdmRelayUrl
#endif
; This release's date (yyyy-MM-dd), set by CI (/DAppReleaseDate). A perpetual license covers releases up
; to its AMC end; blank on a local build, which skips that check.
#ifndef AppReleaseDate
  #define AppReleaseDate ""
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
UninstallDisplayIcon={app}\hms.ico
; %TEMP%\Setup Log <date> #<n>.txt: records each [Run] step's exit code, so a hidden script that failed
; (write-secrets.ps1, for one) can be traced afterwards. Secrets go to scripts through files, never on a
; command line; the one exception is pg.exe's fixed "admin", which write-secrets.ps1 replaces at once.
SetupLogging=yes

[Dirs]
; nginx requires these directories to exist before it will start
Name: "{app}\nginx\logs"
Name: "{app}\nginx\temp"

[Code]
var
  ResultCode: Integer;
  PGInstalled: Boolean;
  LibreOfficeChecked, LibreOfficeNeeded: Boolean;
  AppBrowserChecked: Boolean;
  AppBrowserPath: String;
  DBPage: TInputOptionWizardPage;
  AdminPage: TInputQueryWizardPage;
  LicensePage: TInputQueryWizardPage;
  // From validate-license.ps1 on the license page: who the key belongs to, and whether it includes ABDM.
  LicenseCustomer: String;
  LicenseIncludesAbdm: Boolean;
  // Whether this computer was connected to ABDM before this run (worked out at install time).
  AbdmWasEnrolled: Boolean;
  AbdmResult, LicenseResult: String;
  // True when the key was skipped on a computer without one: HMS then opens read-only until an
  // administrator enters it (backend optimization/26 §12; the super admin can always sign in to do so).
  LicenseSkipped: Boolean;

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

  // A new database seeds admin@hms.com (backend V154; admin@example.com before 2026-10-01) with a
  // password that is public (it is in the backend's migrations). The password chosen here replaces it at
  // the backend's first start.
  AdminPage := CreateInputQueryPage(DBPage.ID,
    'Administrator Password',
    'Choose the password for the admin@hms.com account.',
    'The hospital database is new, so its administrator account needs a password. ' +
    'Use at least 10 characters: letters, digits and symbols, no spaces. It is not shown again.');
  AdminPage.Add('Administrator password:', True);
  AdminPage.Add('Confirm password:', True);

  // The product key (backend optimization/26_PRODUCT_KEY_LICENSING.md, phase 7). Checked online on
  // Next. When the license includes ABDM the same key also connects this computer to ABDM (§9), so the
  // hospital types one key; the ABDM client id and secret are never typed here or stored on this computer.
  LicensePage := CreateInputQueryPage(AdminPage.ID,
    'Product Key',
    'Enter the product key Vyaptek gave this hospital.',
    '');
  LicensePage.Add('Product key (for example HMS-ABCDE-FGHJK-MNPQR-STVWX):', False);
end;

function ConfigFile: String;
begin
  Result := AddBackslash(WizardDirValue) + 'backend\config\application.properties';
end;

// True once this computer holds a relay token (a previous install, or enroll-abdm.ps1 in this run).
function IsAbdmEnrolled: Boolean;
var
  Lines: TArrayOfString;
  I: Integer;
begin
  Result := False;
  if not LoadStringsFromFile(ConfigFile, Lines) then
    Exit;
  for I := 0 to GetArrayLength(Lines) - 1 do
    if Pos('abdm.relay.pull.token=', Lines[I]) = 1 then
    begin
      Result := True;
      Exit;
    end;
end;

function LicenseKey: String;
begin
  Result := Trim(LicensePage.Values[0]);
end;

function HasLicenseKey: Boolean;
begin
  Result := LicenseKey <> '';
end;

// The backend writes this (the installation's id) once it has activated a key. The upgrade guard asks
// the license server about that installation.
function ActivatedMarker: String;
begin
  Result := AddBackslash(WizardDirValue) + 'backend\config\license-activated';
end;

function IsLicenseActivated: Boolean;
begin
  Result := FileExists(ActivatedMarker);
end;

// HMS then 20 letters and digits, once dashes and spaces are dropped; the license server does the rest.
function LooksLikeProductKey(const S: String): Boolean;
var
  I: Integer;
  C: Char;
  Compact: String;
begin
  Result := False;
  Compact := '';
  for I := 1 to Length(S) do
  begin
    C := S[I];
    if (C = '-') or (C = ' ') then
      Continue;
    if not (((C >= '0') and (C <= '9')) or ((C >= 'A') and (C <= 'Z')) or ((C >= 'a') and (C <= 'z'))) then
      Exit;
    Compact := Compact + C;
  end;
  Result := (Length(Compact) = 23) and (CompareText(Copy(Compact, 1, 3), 'HMS') = 0);
end;

// The value of key= in validate-license.ps1's result lines, or ''.
function ResultValue(const Lines: TArrayOfString; const Key: String): String;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to GetArrayLength(Lines) - 1 do
    if Pos(Key + '=', Lines[I]) = 1 then
    begin
      Result := Trim(Copy(Lines[I], Length(Key) + 2, Length(Lines[I])));
      Exit;
    end;
end;

// Runs validate-license.ps1 (extracted to {tmp}) and reads its result lines. False when it left none.
function RunLicenseScript(const Params: String; var Lines: TArrayOfString): Boolean;
var
  ResultFile: String;
  Code: Integer;
begin
  ExtractTemporaryFile('validate-license.ps1');
  ResultFile := ExpandConstant('{tmp}\license-result.txt');
  DeleteFile(ResultFile);
  Exec('powershell.exe', '-NoProfile -ExecutionPolicy Bypass -File "' + ExpandConstant('{tmp}\validate-license.ps1') +
    '" -ServerUrl "{#LicenseServerUrl}" -ReleaseDate "{#AppReleaseDate}" -AppVersion "{#AppVersion}" -ResultFile "' +
    ResultFile + '" ' + Params, '', SW_HIDE, ewWaitUntilTerminated, Code);
  Result := LoadStringsFromFile(ResultFile, Lines) and (ResultValue(Lines, 'status') <> '');
  DeleteFile(ResultFile);
end;

// A typed key: valid, and covering this build? Shows whose it is and asks to go on.
function CheckProductKey: Boolean;
var
  KeyFile, Status, Msg, Seats: String;
  Lines: TArrayOfString;
begin
  Result := False;
  if not LooksLikeProductKey(LicenseKey) then
  begin
    MsgBox('A product key looks like HMS-ABCDE-FGHJK-MNPQR-STVWX. Check it and try again.', mbError, MB_OK);
    Exit;
  end;
  // In a file, never on a command line, where other users could read it. {tmp} is private to this run.
  KeyFile := ExpandConstant('{tmp}\license-check.txt');
  SaveStringToFile(KeyFile, LicenseKey, False);
  try
    if not RunLicenseScript('-Mode Check -KeyFile "' + KeyFile + '"', Lines) then
    begin
      MsgBox('The product key could not be checked. Try again, or send this message to Vyaptek.', mbError, MB_OK);
      Exit;
    end;
  finally
    DeleteFile(KeyFile);
  end;
  Status := ResultValue(Lines, 'status');
  Msg := ResultValue(Lines, 'message');
  if Status = 'OFFLINE' then
  begin
    MsgBox(Msg + #13#10#13#10 + 'The product key is checked online once, during installation.', mbError, MB_OK);
    Exit;
  end;
  if Status <> 'OK' then
  begin
    MsgBox(Msg, mbError, MB_OK);
    Exit;
  end;
  LicenseCustomer := ResultValue(Lines, 'customer');
  LicenseIncludesAbdm := ResultValue(Lines, 'abdm') = 'true';
  Seats := ResultValue(Lines, 'seats');
  Msg := 'This product key belongs to ' + LicenseCustomer + ' (' + ResultValue(Lines, 'licenseId') + ').';
  if Seats <> '' then
    Msg := Msg + #13#10 + Seats + ' workstations can use HMS at the same time.';
  if LicenseIncludesAbdm then
    Msg := Msg + #13#10 + 'ABDM is included; this key also connects this computer to ABDM.';
  Result := MsgBox(Msg + #13#10#13#10 + 'Continue?', mbConfirmation, MB_YESNO) = IDYES;
end;

// An upgrade with no new key: may this build run under the license already activated here? Asked
// before any file is replaced, so a hospital whose AMC has ended keeps its working version.
function CheckUpgradeEntitled: Boolean;
var
  Status, Msg: String;
  Lines: TArrayOfString;
begin
  Result := True;
  if not RunLicenseScript('-Mode Upgrade -InstallIdFile "' + ActivatedMarker + '"', Lines) then
    Status := 'ERROR'
  else
    Status := ResultValue(Lines, 'status');
  Msg := ResultValue(Lines, 'message');
  if Status = 'OK' then
    Exit;
  if Status = 'NOT_ENTITLED' then
  begin
    MsgBox(Msg + #13#10#13#10 + 'Nothing was changed; this computer keeps the version it has. Cancel the ' +
      'installation, or enter a renewed product key.', mbError, MB_OK);
    Result := False;
    Exit;
  end;
  Result := MsgBox('Could not confirm with Vyaptek that this version is covered by the license (' + Msg + ').' + #13#10#13#10 +
    'If the update period (AMC) has ended, HMS turns read-only after this upgrade. Continue anyway?',
    mbConfirmation, MB_YESNO) = IDYES;
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

// Who to sign in as. A new database's admin is admin@hms.com (backend V154); on a kept database it
// may still be admin@example.com, so an upgrade names no account.
function AdminSignIn: String;
begin
  if NeedsAdminPassword then
    Result := 'admin@hms.com'
  else
    Result := 'an administrator';
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
  if CurPageID = LicensePage.ID then
  begin
    LicenseIncludesAbdm := False;
    LicenseSkipped := False;
    if HasLicenseKey then
      Result := CheckProductKey
    else if IsLicenseActivated then
      Result := CheckUpgradeEntitled
    else
    begin
      LicenseSkipped := MsgBox('Continue without a product key?' + #13#10#13#10 +
        'HMS will open read-only: records can be viewed and printed, not changed, until you sign in as ' +
        AdminSignIn + ' and enter the key in Utility > License. That needs internet.',
        mbConfirmation, MB_YESNO) = IDYES;
      Result := LicenseSkipped;
    end;
    Exit;
  end;
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
  else if CompareText(Pw, 'admin@hms.com') = 0 then
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
  // Same for the product key: once for the backend to activate, once for ABDM when the license has it
  // and this computer is not connected yet (each script deletes its copy).
  if CurStep = ssInstall then
  begin
    AbdmWasEnrolled := IsAbdmEnrolled;
    if HasLicenseKey then
      SaveStringToFile(ExpandConstant('{tmp}\license-key.txt'), LicenseKey, False);
    if HasLicenseKey and LicenseIncludesAbdm and not AbdmWasEnrolled then
      SaveStringToFile(ExpandConstant('{tmp}\abdm-product-key.txt'), LicenseKey, False);
  end;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if CurPageID = LicensePage.ID then
  begin
    if IsLicenseActivated then
      LicensePage.SubCaptionLabel.Caption :=
        'This computer already has an activated product key. Leave the box empty to keep it; the ' +
        'installer checks with Vyaptek that this version is covered. Enter a key only if Vyaptek gave ' +
        'you a new one.'
    else
      LicensePage.SubCaptionLabel.Caption :=
        'The installer checks the key with Vyaptek, so this computer needs internet now. It decides ' +
        'which modules this hospital can use and how many computers at once. If the license includes ' +
        'ABDM, the same key sets ABDM up. Without a key HMS opens read-only until an administrator ' +
        'enters it in Utility > License.';
  end;
  if CurPageID = wpFinished then
  begin
    if NeedsAdminPassword and (AdminPage.Values[0] <> '') then
      WizardForm.FinishedLabel.Caption := WizardForm.FinishedLabel.Caption + #13#10#13#10 +
        'Sign in as admin@hms.com with the administrator password you chose.';
    if LicenseResult <> '' then
      WizardForm.FinishedLabel.Caption := WizardForm.FinishedLabel.Caption + #13#10#13#10 + LicenseResult;
    if AbdmResult <> '' then
      WizardForm.FinishedLabel.Caption := WizardForm.FinishedLabel.Caption + #13#10#13#10 + AbdmResult;
  end;
end;

// enroll-abdm.ps1 leaves one line in the result file. A failure does not stop the install: the rest
// of HMS works without ABDM, and the script can be run again later.
procedure CheckAbdmEnrolled;
var
  Msg: AnsiString;
begin
  if not LoadStringFromFile(ExpandConstant('{tmp}\abdm-enroll-result.txt'), Msg) then
    Msg := 'The ABDM setup did not report back.';
  AbdmResult := Trim(String(Msg));
  if Pos('This computer is connected to ABDM', AbdmResult) = 1 then
  begin
    AbdmResult := AbdmResult + ' Next, enter the facility id in Utility > ABDM Facility Config and ' +
      'each doctor''s HPR id in Consultant Master.';
    Exit;
  end;
  AbdmResult := 'ABDM was not set up: ' + AbdmResult + ' To try again, as an administrator run (it asks for the product key): ' +
    'powershell -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}\enroll-abdm.ps1') +
    '" -ConfigDir "' + ExpandConstant('{app}\backend\config') + '" -RestartService';
  SuppressibleMsgBox(AbdmResult, mbError, MB_OK, IDOK);
end;

// validate-license.ps1 -Mode Install leaves one status line. A failure does not stop the install: an
// administrator can enter the key in Utility > License after signing in.
procedure CheckLicenseInstalled;
var
  Lines: TArrayOfString;
begin
  if LoadStringsFromFile(ExpandConstant('{tmp}\license-install-result.txt'), Lines) and
     (ResultValue(Lines, 'status') = 'OK') then
    LicenseResult := 'HMS is licensed to ' + LicenseCustomer + '. The product key is activated when HMS starts.'
  else
  begin
    LicenseResult := 'The product key could not be saved for HMS. After signing in, an administrator can enter ' +
      'it in Utility > License.';
    SuppressibleMsgBox(LicenseResult, mbError, MB_OK, IDOK);
  end;
end;

// validate-license.ps1 -Mode RequireKey leaves one status line.
procedure CheckKeyRequired;
var
  Lines: TArrayOfString;
begin
  if LoadStringsFromFile(ExpandConstant('{tmp}\license-install-result.txt'), Lines) and
     (ResultValue(Lines, 'status') = 'OK') then
    LicenseResult := 'No product key was entered, so HMS opens read-only. Sign in as ' + AdminSignIn + ' and ' +
      'enter the key in Utility > License.'
  else
    LicenseResult := 'No product key was entered. Sign in as ' + AdminSignIn + ' and enter it in Utility > License.';
end;

function KeyWasSkipped: Boolean;
begin
  Result := LicenseSkipped;
end;

function ShouldEnrollAbdm: Boolean;
begin
  Result := HasLicenseKey and LicenseIncludesAbdm and not AbdmWasEnrolled;
end;

// The password on the last "requirepass" line of the Redis config (the one Redis uses), or ''.
function RedisRequirePass(const Conf: TArrayOfString): String;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to GetArrayLength(Conf) - 1 do
    if Pos('requirepass ', Conf[I]) = 1 then
      Result := Trim(Copy(Conf[I], Length('requirepass ') + 1, Length(Conf[I])));
end;

// Without the secret file the backend refuses to start, so say so rather than finish quietly. The same
// for a Redis password that the Redis config does not carry: every sign-in then answers "Sign-in is
// temporarily unavailable". Seen 2026-09-30 on a box whose redis.windows-service.conf had no
// requirepass while application.properties had a Redis password; write-secrets.ps1 runs hidden, so
// a run that stopped before its Redis step went unnoticed.
procedure CheckSecretsWritten;
var
  Props, Conf: TArrayOfString;
  RedisPw, Fix: String;
begin
  Fix := 'As an administrator run: powershell -ExecutionPolicy Bypass -File "' +
    ExpandConstant('{app}\write-secrets.ps1') + '" -ConfigDir "' + ExpandConstant('{app}\backend\config') +
    '" -RedisConf "' + ExpandConstant('{app}\redis\redis.windows-service.conf') +
    '", then restart the VyaptekRedis and VyaptekHMS services.';
  if not LoadStringsFromFile(ExpandConstant('{app}\backend\config\application.properties'), Props) then
  begin
    SuppressibleMsgBox('The sign-in key file could not be created in ' +
      ExpandConstant('{app}\backend\config') + '. The HMS backend will not start until it exists. ' + Fix,
      mbCriticalError, MB_OK, IDOK);
    Exit;
  end;
  RedisPw := ResultValue(Props, 'spring.data.redis.password');
  if not LoadStringsFromFile(ExpandConstant('{app}\redis\redis.windows-service.conf'), Conf) then
    SetArrayLength(Conf, 0);
  if (RedisPw = '') or (RedisRequirePass(Conf) <> RedisPw) then
    SuppressibleMsgBox('The Redis password was not set up: application.properties and ' +
      'redis.windows-service.conf do not agree, so nobody will be able to sign in. ' + Fix,
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

// The path a browser registered under App Paths, or '' when it is not installed for all users.
function RegisteredExe(const Exe: String): String;
var
  Path: String;
begin
  Result := '';
  if not RegQueryStringValue(HKLM, 'SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\' + Exe, '', Path) then
    if not RegQueryStringValue(HKLM32, 'SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\' + Exe, '', Path) then
      Exit;
  Path := RemoveQuotes(Path);
  if FileExists(Path) then
    Result := Path;
end;

// The browser the HMS shortcuts open as an app window (--app: no tabs or address bar): Chrome when
// installed, else Edge, which every Windows 10/11 has. '' when neither is found; the shortcuts are
// then plain links that open in the default browser.
function AppBrowser: String;
begin
  if not AppBrowserChecked then
  begin
    AppBrowserPath := RegisteredExe('chrome.exe');
    if AppBrowserPath = '' then
      AppBrowserPath := RegisteredExe('msedge.exe');
    if (AppBrowserPath = '') and FileExists(ExpandConstant('{commonpf32}\Microsoft\Edge\Application\msedge.exe')) then
      AppBrowserPath := ExpandConstant('{commonpf32}\Microsoft\Edge\Application\msedge.exe');
    AppBrowserChecked := True;
  end;
  Result := AppBrowserPath;
end;

function GetAppBrowser(Param: String): String;
begin
  Result := AppBrowser;
end;

function HasAppBrowser: Boolean;
begin
  Result := AppBrowser <> '';
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
;    ABDM: connect with the product key or a one-time code (also run by hand later), and keep the
;    clock right for it.
Source: "enroll-abdm.ps1"; DestDir: "{app}"
Source: "time-sync.ps1";   DestDir: "{app}"
;    The product key: checked on the license page (extracted to {tmp} there), then handed to the backend.
Source: "validate-license.ps1"; Flags: dontcopy
Source: "validate-license.ps1"; DestDir: "{app}"

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

; 7. The HMS icon (made from hms_webapp public/logo.svg) for the shortcuts below and Apps & features.
Source: "hms.ico"; DestDir: "{app}"

[Icons]
; Desktop and Start menu shortcuts for everyone on this computer, opening HMS in its own window rather
; than a browser tab. Recreated on every install and upgrade; removed on uninstall.
Name: "{commondesktop}\Vyaptek HMS";  Filename: "{code:GetAppBrowser}"; Parameters: "--app=http://localhost/"; IconFilename: "{app}\hms.ico"; Comment: "Open Vyaptek HMS"; Check: HasAppBrowser
Name: "{commonprograms}\Vyaptek HMS"; Filename: "{code:GetAppBrowser}"; Parameters: "--app=http://localhost/"; IconFilename: "{app}\hms.ico"; Comment: "Open Vyaptek HMS"; Check: HasAppBrowser
Name: "{commondesktop}\Vyaptek HMS";  Filename: "http://localhost/"; IconFilename: "{app}\hms.ico"; Check: not HasAppBrowser
Name: "{commonprograms}\Vyaptek HMS"; Filename: "http://localhost/"; IconFilename: "{app}\hms.ico"; Check: not HasAppBrowser

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

; 3a. The product key, when one was entered: into the locked config folder from step 3, for the backend
;     to activate at its first start (it then deletes the file and writes license-activated).
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\validate-license.ps1"" -Mode Install -KeyFile ""{tmp}\license-key.txt"" -ConfigDir ""{app}\backend\config"" -ResultFile ""{tmp}\license-install-result.txt"""; Flags: runhidden waituntilterminated; StatusMsg: "Saving the product key..."; Check: HasLicenseKey; AfterInstall: CheckLicenseInstalled
; 3a'. No key entered on a computer without one: HMS opens read-only until an administrator enters it.
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\validate-license.ps1"" -Mode RequireKey -ConfigDir ""{app}\backend\config"" -ResultFile ""{tmp}\license-install-result.txt"""; Flags: runhidden waituntilterminated; StatusMsg: "Recording that the product key is still to be entered..."; Check: KeyWasSkipped; AfterInstall: CheckKeyRequired
; 3b. ABDM, when the license includes it and this computer is not connected yet: redeem the product key
;     with Vyaptek and write this box's ABDM settings into the secret file from step 3. Before the
;     backend starts, so it starts with them.
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\enroll-abdm.ps1"" -ConfigDir ""{app}\backend\config"" -RelayUrl ""{#AbdmRelayUrl}"" -ProductKeyFile ""{tmp}\abdm-product-key.txt"" -ResultFile ""{tmp}\abdm-enroll-result.txt"""; Flags: runhidden waituntilterminated; StatusMsg: "Connecting to ABDM..."; Check: ShouldEnrollAbdm; AfterInstall: CheckAbdmEnrolled
; 3c. ABDM refuses replies stamped more than ~15 minutes off, so keep the clock synced.
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\time-sync.ps1"""; Flags: runhidden waituntilterminated; StatusMsg: "Setting up time sync..."; Check: IsAbdmEnrolled

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