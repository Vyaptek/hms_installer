; Set by the CI workflow (/DAppVersion, /DLibreOfficeVersion, /DDotNetVersion); these defaults are for
; local builds.
#ifndef AppVersion
  #define AppVersion "0.0.0-local"
#endif
; The bundled libreoffice.msi's version, as soffice.exe reports it.
#ifndef LibreOfficeVersion
  #define LibreOfficeVersion "26.2.6.3"
#endif
; The bundled .NET runtime's version (dotnet-runtime.exe), which Garnet, the cache server, runs on.
#ifndef DotNetVersion
  #define DotNetVersion "10.0.12"
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
; The bundled pg.exe's PostgreSQL release (major.minor, e.g. 18.3), set by CI from its version info. An
; upgrade brings an older 18.x on the box up to it. Blank on a local build, which never patches.
#ifndef PostgresVersion
  #define PostgresVersion ""
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
OutputBaseFilename=HMSSetup-v{#AppVersion}
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
  // The box's PostgreSQL release (e.g. 18.1, from postgres.exe -V), worked out once; '' when unknown.
  PGVersionChecked: Boolean;
  PGVersion: String;
  // Shown on the last page: the PostgreSQL update, and the backup before the upgrade (OP11).
  PGPatchResult, BackupResult: String;
  LibreOfficeChecked, LibreOfficeNeeded: Boolean;
  DotNetChecked, DotNetNeeded: Boolean;
  // Set when the person gave up on Retry: the box's secrets, or the database update, are missing, so
  // the backend is not started (plan 24 §11, OP8: there is no fallback password any more).
  SecretsFailed, DatabaseFailed: Boolean;
  // Shown on the last page: the service accounts (OP2) and whether the backend came up after start.
  AccountsResult, BackendResult: String;
  // Shown on the last page: HTTPS on the hospital network, and where each PC trusts it (OP5).
  LanTlsResult: String;
  AppBrowserChecked: Boolean;
  AppBrowserPath: String;
  DBPage: TInputOptionWizardPage;
  AdminPage: TInputQueryWizardPage;
  LicensePage: TInputQueryWizardPage;
  // From validate-license.ps1 on the license page: who the key belongs to, and whether it includes ABDM.
  LicenseCustomer: String;
  LicenseIncludesAbdm: Boolean;
  // The ABDM relay box the key sets up ('' without ABDM, or from an older license server).
  LicenseAbdmBox: String;
  // Whether this computer was connected to ABDM before this run, and as another box than the key's
  // (a new key, or a reinstall that kept an older settings file): both worked out at install time.
  AbdmWasEnrolled, AbdmBoxChanged: Boolean;
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

  // Two choices, not a third "update PostgreSQL only": an upgrade brings everything bundled up to this
  // release, PostgreSQL's minor release included, and its explanation (CurPageChanged) says when it does.
  DBPage := CreateInputOptionPage(wpSelectDir,
    'Existing Installation Detected',
    'HMS and the hospital database are already installed on this computer.',
    '',
    True, False);
  DBPage.Add('Upgrade (recommended): keep all hospital data and bring HMS up to this version');
  DBPage.Add('Fresh install: delete ALL hospital data and start with an empty HMS (cannot be undone)');
  DBPage.SelectedValueIndex := 0;

  // A new database seeds one administrator (admin@hms.com since backend V154) with a password that is
  // public (it is in the backend's migrations). The email and password chosen here replace both at the
  // backend's first start (hms.bootstrap.admin-username and -password, 2026-10-03).
  AdminPage := CreateInputQueryPage(DBPage.ID,
    'Administrator Account',
    'Choose how the hospital''s administrator signs in.',
    'The hospital database is new, so its administrator account needs a sign-in email and a password. ' +
    'Use the hospital''s own email address. The password needs at least 10 characters: letters, digits ' +
    'and symbols, no spaces. It is not shown again.');
  AdminPage.Add('Administrator email (used to sign in):', False);
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

// The value of Key= in this computer's settings file, or ''.
function ConfigValue(const Key: String): String;
var
  Lines: TArrayOfString;
  I: Integer;
begin
  Result := '';
  if not LoadStringsFromFile(ConfigFile, Lines) then
    Exit;
  for I := 0 to GetArrayLength(Lines) - 1 do
    if Pos(Key + '=', Lines[I]) = 1 then
    begin
      Result := Trim(Copy(Lines[I], Length(Key) + 2, Length(Lines[I])));
      Exit;
    end;
end;

// True once this computer holds a relay token (a previous install, or enroll-abdm.ps1 in this run).
function IsAbdmEnrolled: Boolean;
begin
  Result := ConfigValue('abdm.relay.pull.token') <> '';
end;

// The ABDM relay box this computer runs as, or '' when it is not connected.
function EnrolledAbdmBox: String;
begin
  Result := ConfigValue('abdm.relay.pull.box-id');
end;

// Connected as another box than the key's: the key was changed, or a reinstall kept an older settings
// file. Setting ABDM up again then gives this computer the key's box (backend doc 26 §13).
function IsOtherAbdmBox: Boolean;
begin
  Result := IsAbdmEnrolled and (LicenseAbdmBox <> '') and (EnrolledAbdmBox <> LicenseAbdmBox);
end;

function LicenseKey: String;
begin
  Result := Trim(LicensePage.Values[0]);
end;

function HasLicenseKey: Boolean;
begin
  Result := LicenseKey <> '';
end;

// A computer already connected as the key's own box is left alone: setting ABDM up again would only
// issue a new token. The License page offers Reconnect ABDM if that token has stopped working.
function ShouldEnrollAbdm: Boolean;
begin
  Result := HasLicenseKey and LicenseIncludesAbdm and (not AbdmWasEnrolled or AbdmBoxChanged);
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
  LicenseAbdmBox := ResultValue(Lines, 'abdmBox');
  Seats := ResultValue(Lines, 'seats');
  Msg := 'This product key belongs to ' + LicenseCustomer + ' (' + ResultValue(Lines, 'licenseId') + ').';
  if Seats <> '' then
    Msg := Msg + #13#10 + Seats + ' workstations can use HMS at the same time.';
  if LicenseIncludesAbdm and IsOtherAbdmBox then
    Msg := Msg + #13#10 + 'ABDM is included. This computer is connected to ABDM as ' + EnrolledAbdmBox +
      ', not as this key''s ' + LicenseAbdmBox + ', so the key sets ABDM up again for ' + LicenseAbdmBox + '.'
  else if LicenseIncludesAbdm then
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

// The release postgres.exe -V names ("postgres (PostgreSQL) 18.1" -> "18.1"), or '' when it can't be read.
function InstalledPostgresVersion: String;
var
  Output: TExecOutput;
  Code, I: Integer;
  S: String;
begin
  if not PGVersionChecked then
  begin
    PGVersion := '';
    if ExecAndCaptureOutput(AddBackslash(WizardDirValue) + 'pgsql\bin\postgres.exe', '-V', '', SW_HIDE,
         ewWaitUntilTerminated, Code, Output) and (Code = 0) and (GetArrayLength(Output.StdOut) > 0) then
    begin
      S := Trim(Output.StdOut[0]);
      I := Pos(') ', S);
      if I > 0 then
      begin
        S := Copy(S, I + 2, Length(S));
        I := Pos(' ', S);
        if I > 0 then
          S := Copy(S, 1, I - 1);
        PGVersion := S;
      end;
    end;
    PGVersionChecked := True;
  end;
  Result := PGVersion;
end;

// An upgrade that keeps the data, on a box with an older minor release of the same PostgreSQL major
// (18) as the bundled pg.exe. EDB's installer, run over an existing installation of the same major,
// updates it in place: same folder, same data directory, its settings kept, the command line's options
// ignored (EDB's docs). A minor release never changes the data's format, so nothing is migrated; this
// release's own migrations run afterwards as on every upgrade (setup-database.bat).
function ShouldPatchPG: Boolean;
var
  Installed, Bundled: String;
  InstalledPacked, BundledPacked: Int64;
begin
  Result := False;
  Bundled := '{#PostgresVersion}';
  if not PGInstalled or (DBPage.SelectedValueIndex <> 0) or (Bundled = '') then
    Exit;
  Installed := InstalledPostgresVersion;
  if (Pos('18.', Installed) <> 1) or (Pos('18.', Bundled) <> 1) then
    Exit;
  Result := StrToVersion(Installed, InstalledPacked) and StrToVersion(Bundled, BundledPacked) and
    (ComparePackedVersion(InstalledPacked, BundledPacked) < 0);
end;

// A new computer, or Fresh install. Not an upgrade: that is ShouldPatchPG.
function ShouldInstallPG: Boolean;
begin
  if PGInstalled then
    Result := DBPage.SelectedValueIndex = 1
  else
    Result := True;
end;

// [Files]: pg.exe comes along for either.
function NeedsPgInstaller: Boolean;
begin
  Result := ShouldInstallPG or ShouldPatchPG;
end;

// After the update: did postgres.exe move to the bundled release? If not, the data is untouched and HMS
// carries on with the old release; the next upgrade tries again.
procedure CheckPostgresPatched;
begin
  PGVersionChecked := False;
  if InstalledPostgresVersion = '{#PostgresVersion}' then
    PGPatchResult := 'PostgreSQL was updated to {#PostgresVersion}.'
  else
  begin
    PGPatchResult := 'PostgreSQL could not be updated to {#PostgresVersion} and is still ' + InstalledPostgresVersion +
      '. The hospital data is unchanged and HMS works; run this installer again, or tell Vyaptek.';
    SuppressibleMsgBox(PGPatchResult, mbError, MB_OK, IDOK);
  end;
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

function AdminEmail: String;
begin
  Result := Trim(AdminPage.Values[0]);
end;

// Who to sign in as: on a new database, the email chosen on the administrator page; on a kept database
// the existing accounts are unchanged, so an upgrade names no account.
function AdminSignIn: String;
begin
  if NeedsAdminPassword and (AdminEmail <> '') then
    Result := AdminEmail
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

// One @ with something before it, a dot in the part after it, printable ASCII without spaces, and at
// most 100 characters (users.username). The backend checks the same and keeps admin@hms.com if not.
function LooksLikeEmail(const S: String): Boolean;
var
  At, I: Integer;
  Domain: String;
begin
  Result := False;
  if (Length(S) < 5) or (Length(S) > 100) or not IsPrintableAsciiWithoutSpace(S) then
    Exit;
  At := Pos('@', S);
  if At < 2 then
    Exit;
  Domain := Copy(S, At + 1, Length(S));
  if Pos('@', Domain) > 0 then
    Exit;
  I := Pos('.', Domain);
  Result := (I > 1) and (I < Length(Domain));
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
  Pw := AdminPage.Values[1];
  Problem := '';
  if not LooksLikeEmail(AdminEmail) then
    Problem := 'Enter the email address the administrator will sign in with, for example it@cityhospital.in.'
  else if Pw <> AdminPage.Values[2] then
    Problem := 'The two passwords do not match.'
  else if Length(Pw) < 10 then
    Problem := 'The password must be at least 10 characters.'
  else if Length(Pw) > 72 then
    Problem := 'The password must be at most 72 characters.'
  else if not IsPrintableAsciiWithoutSpace(Pw) then
    Problem := 'Use English letters, digits and symbols only, without spaces.'
  else if CompareText(Pw, AdminEmail) = 0 then
    Problem := 'The password must not be the email address.';
  if Problem <> '' then
  begin
    MsgBox(Problem, mbError, MB_OK);
    Result := False;
  end;
end;

// Handed to write-secrets.ps1 through a file in {tmp}, never on a command line: other users can read
// process command lines. {tmp} is private to this run and deleted when it ends. The script deletes
// them once read, so a retry writes them again.
procedure SaveAdminFiles;
begin
  if NeedsAdminPassword and (AdminPage.Values[1] <> '') then
  begin
    SaveStringToFile(ExpandConstant('{tmp}\admin-password.txt'), AdminPage.Values[1], False);
    SaveStringToFile(ExpandConstant('{tmp}\admin-email.txt'), AdminEmail, False);
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssInstall then
    SaveAdminFiles;
  // Same for the product key: once for the backend to activate, once for ABDM when the license has it
  // and this computer is not connected yet, or is connected as another box than the key's (each script
  // deletes its copy).
  if CurStep = ssInstall then
  begin
    AbdmWasEnrolled := IsAbdmEnrolled;
    AbdmBoxChanged := IsOtherAbdmBox;
    if HasLicenseKey then
      SaveStringToFile(ExpandConstant('{tmp}\license-key.txt'), LicenseKey, False);
    if ShouldEnrollAbdm then
      SaveStringToFile(ExpandConstant('{tmp}\abdm-product-key.txt'), LicenseKey, False);
  end;
end;

procedure CurPageChanged(CurPageID: Integer);
var
  Pg: String;
begin
  if CurPageID = DBPage.ID then
  begin
    Pg := InstalledPostgresVersion;
    DBPage.SubCaptionLabel.Caption :=
      'Upgrade first backs up the hospital data (encrypted; only Vyaptek can read it), then installs this ' +
      'version and updates the database to it. HMS is unavailable for a few minutes, so upgrade outside ' +
      'busy hours.';
    if ('{#PostgresVersion}' <> '') and (Pos('18.', Pg) = 1) and (Pg <> '{#PostgresVersion}') then
      DBPage.SubCaptionLabel.Caption := DBPage.SubCaptionLabel.Caption + #13#10#13#10 +
        'The database server, PostgreSQL ' + Pg + ', is also updated to {#PostgresVersion}: a security and ' +
        'bug-fix release that keeps the data as it is.';
  end;
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
    if NeedsAdminPassword and (AdminPage.Values[1] <> '') then
      WizardForm.FinishedLabel.Caption := WizardForm.FinishedLabel.Caption + #13#10#13#10 +
        'Sign in as ' + AdminEmail + ' with the administrator password you chose.';
    if LicenseResult <> '' then
      WizardForm.FinishedLabel.Caption := WizardForm.FinishedLabel.Caption + #13#10#13#10 + LicenseResult;
    if AbdmResult <> '' then
      WizardForm.FinishedLabel.Caption := WizardForm.FinishedLabel.Caption + #13#10#13#10 + AbdmResult;
    if BackupResult <> '' then
      WizardForm.FinishedLabel.Caption := WizardForm.FinishedLabel.Caption + #13#10#13#10 + BackupResult;
    if PGPatchResult <> '' then
      WizardForm.FinishedLabel.Caption := WizardForm.FinishedLabel.Caption + #13#10#13#10 + PGPatchResult;
    if AccountsResult <> '' then
      WizardForm.FinishedLabel.Caption := WizardForm.FinishedLabel.Caption + #13#10#13#10 + AccountsResult;
    if BackendResult <> '' then
      WizardForm.FinishedLabel.Caption := WizardForm.FinishedLabel.Caption + #13#10#13#10 + BackendResult;
    if LanTlsResult <> '' then
      WizardForm.FinishedLabel.Caption := WizardForm.FinishedLabel.Caption + #13#10#13#10 + LanTlsResult;
    if SecretsFailed or DatabaseFailed then
      WizardForm.FinishedLabel.Caption := WizardForm.FinishedLabel.Caption + #13#10#13#10 +
        'HMS was NOT started: the database could not be secured or updated. Run this installer again.';
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

function GarnetConf: String;
begin
  Result := ExpandConstant('{app}\garnet\garnet.conf');
end;

// The password in garnet.conf, or ''. write-secrets.ps1 writes it on a line of its own:
//   "Password": "<letters and digits>",
function GarnetPassword(const Conf: TArrayOfString): String;
var
  I, Q: Integer;
  S: String;
begin
  Result := '';
  for I := 0 to GetArrayLength(Conf) - 1 do
  begin
    S := Trim(Conf[I]);
    if Pos('"Password":', S) <> 1 then
      Continue;
    S := Trim(Copy(S, Length('"Password":') + 1, Length(S)));
    if Pos('"', S) <> 1 then
      Exit;
    S := Copy(S, 2, Length(S));
    Q := Pos('"', S);
    if Q > 0 then
      Result := Copy(S, 1, Q - 1);
    Exit;
  end;
end;

// write-secrets.ps1's arguments, for [Run] and for a retry alike. -NewDatabase when this run created the
// database: the admin account is new, and the superuser password is changed again.
function WriteSecretsParams(Param: String): String;
begin
  Result := '-NoProfile -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}\write-secrets.ps1') +
    '" -ConfigDir "' + ExpandConstant('{app}\backend\config') + '" -PgBin "' + ExpandConstant('{app}\pgsql\bin') +
    '" -GarnetConf "' + GarnetConf + '"';
  if NeedsAdminPassword then
    Result := Result + ' -AdminPasswordFile "' + ExpandConstant('{tmp}\admin-password.txt') +
      '" -AdminEmailFile "' + ExpandConstant('{tmp}\admin-email.txt') + '" -NewDatabase';
end;

// What is missing from what write-secrets.ps1 should have left, or '' when nothing is. Without the
// secret file, or without the backend's own database account (OP1), the backend cannot start. A cache
// password that garnet.conf does not carry turns every sign-in into "Sign-in is temporarily
// unavailable": seen 2026-09-30 with the old Redis, on a box whose Redis config had no requirepass while
// application.properties had a password. write-secrets.ps1 runs hidden, so a failed run went unnoticed.
function SecretsProblem: String;
var
  Props, Conf: TArrayOfString;
  CachePw: String;
begin
  Result := '';
  if not LoadStringsFromFile(ExpandConstant('{app}\backend\config\application.properties'), Props) then
  begin
    Result := 'the sign-in key file could not be created in ' + ExpandConstant('{app}\backend\config');
    Exit;
  end;
  if not FileExists(ExpandConstant('{app}\backend\config\pg-superuser.secret')) or
     (ResultValue(Props, 'spring.datasource.username') <> 'hospital_erp_user') then
  begin
    Result := 'the database password could not be set. Check that the postgresql-x64-18 service is running';
    Exit;
  end;
  // The backend still names it spring.data.redis.password: it talks to Garnet as to Redis.
  CachePw := ResultValue(Props, 'spring.data.redis.password');
  if not LoadStringsFromFile(GarnetConf, Conf) then
    SetArrayLength(Conf, 0);
  if (CachePw = '') or (GarnetPassword(Conf) <> CachePw) then
    Result := 'the cache server password was not set up (application.properties and garnet.conf do not agree)';
end;

// Retry until the secrets are in place. Cancel (also the answer in a silent install) leaves HMS stopped
// rather than running it on a fallback password, which hms-service.xml no longer carries (OP8).
procedure CheckSecretsWritten;
var
  Problem: String;
  Code: Integer;
begin
  Problem := SecretsProblem;
  while Problem <> '' do
  begin
    if SuppressibleMsgBox('Setup couldn''t secure the database: ' + Problem + '.' + #13#10#13#10 +
         'Click Retry to try again. Cancel finishes without starting HMS; run this installer again to finish.',
         mbError, MB_RETRYCANCEL, IDCANCEL) <> IDRETRY then
    begin
      SecretsFailed := True;
      Exit;
    end;
    SaveAdminFiles;
    Exec('powershell.exe', WriteSecretsParams(''), '', SW_HIDE, ewWaitUntilTerminated, Code);
    Problem := SecretsProblem;
  end;
end;

function DatabaseSetupLog: String;
begin
  Result := ExpandConstant('{app}\backend\logs\database-setup.log');
end;

// setup-database.bat rewrites its log on every run; BoxDatabaseSetup ends it with "Database ready:"
// only when the migrations and the accounts are done.
function DatabaseIsSetUp: Boolean;
var
  Lines: TArrayOfString;
  I: Integer;
begin
  Result := False;
  if LoadStringsFromFile(DatabaseSetupLog, Lines) then
    for I := 0 to GetArrayLength(Lines) - 1 do
      if Pos('Database ready:', Lines[I]) = 1 then
        Result := True;
end;

// The backend would refuse to start on a database this release has not migrated, and its account
// cannot migrate it (OP1), so the same Retry as for the secrets.
procedure CheckDatabaseSetUp;
var
  Code: Integer;
begin
  while not DatabaseIsSetUp do
  begin
    if SuppressibleMsgBox('Setup couldn''t update the hospital database, so HMS was not started. The ' +
         'details are in ' + DatabaseSetupLog + '.' + #13#10#13#10 +
         'Click Retry to try again. Cancel finishes without starting HMS; run this installer again, or send ' +
         'that file to Vyaptek.', mbError, MB_RETRYCANCEL, IDCANCEL) <> IDRETRY then
    begin
      DatabaseFailed := True;
      Exit;
    end;
    Exec(ExpandConstant('{cmd}'), '/C ""' + ExpandConstant('{app}\setup-database.bat') + '" "' +
      ExpandConstant('{app}') + '""', '', SW_HIDE, ewWaitUntilTerminated, Code);
  end;
end;

function ServiceAccountsLog: String;
begin
  Result := ExpandConstant('{app}\backend\logs\service-accounts.log');
end;

// service-accounts.ps1 sets the folder permissions before it changes either service's account, so when
// it fails the services still run as LocalSystem, as before OP2: HMS works, and the next run tries again.
procedure CheckServiceAccounts;
var
  Lines: TArrayOfString;
  I: Integer;
begin
  if not LoadStringsFromFile(ServiceAccountsLog, Lines) then
    SetArrayLength(Lines, 0);
  for I := 0 to GetArrayLength(Lines) - 1 do
    if Pos('Could not set up the service accounts', Lines[I]) > 0 then
    begin
      AccountsResult := 'HMS still runs as the Windows system account: its own accounts could not be set ' +
        'up. HMS works; run this installer again, or send ' + ServiceAccountsLog + ' to Vyaptek.';
      Exit;
    end;
end;

// lan-tls.ps1 leaves status=https|http and a message for the last page. Without HTTPS HMS still works
// over plain HTTP, as before OP5, and the scheduled task tries again every hour, so no message box.
procedure CheckLanTls;
var
  Lines: TArrayOfString;
begin
  if LoadStringsFromFile(ExpandConstant('{tmp}\lan-tls-result.txt'), Lines) then
    LanTlsResult := ResultValue(Lines, 'message');
  if LanTlsResult = '' then
    LanTlsResult := 'HTTPS on the hospital network could not be set up; HMS works over plain HTTP. Send ' +
      ExpandConstant('{app}\backend\logs\lan-tls.log') + ' to Vyaptek.';
end;

// wait-for-backend.ps1's one line: UP, STOPPED or STARTING. Nothing is rolled back in any case: an
// upgraded database cannot go back to the old version.
procedure CheckBackendStarted;
var
  Lines: TArrayOfString;
  Status, Logs: String;
begin
  if LoadStringsFromFile(ExpandConstant('{tmp}\backend-status.txt'), Lines) then
    Status := ResultValue(Lines, 'status')
  else
    Status := '';
  Logs := ExpandConstant('{app}\backend\logs');
  if Status = 'UP' then
    Exit;
  if Status = 'STOPPED' then
  begin
    BackendResult := 'HMS did not start: the Vyaptek HMS service stopped. Send the newest files in ' + Logs +
      ' to Vyaptek.';
    SuppressibleMsgBox(BackendResult, mbError, MB_OK, IDOK);
  end
  else
    BackendResult := 'HMS is still starting. Check again in a few minutes; if it does not open, send the ' +
      'newest files in ' + Logs + ' to Vyaptek.';
end;

function SecretsReady: Boolean;
begin
  Result := not SecretsFailed;
end;

function DatabaseReady: Boolean;
begin
  Result := not SecretsFailed and not DatabaseFailed;
end;

// The .NET runtime Garnet needs: install the bundled one unless this computer already has the same
// 10.0 line at this patch or later (a newer one the hospital or Windows Update put in is left alone).
// Worked out once, because [Files] and [Run] both ask.
function ShouldInstallDotNet: Boolean;
var
  Dir, Bundled: String;
  FindRec: TFindRec;
  InstalledPacked, BundledPacked: Int64;
begin
  if not DotNetChecked then
  begin
    DotNetNeeded := True;
    Bundled := '{#DotNetVersion}';
    Dir := ExpandConstant('{commonpf64}\dotnet\shared\Microsoft.NETCore.App\');
    // Only the same major.minor counts (10.0.12 -> 10.0.*): a framework-dependent app rolls forward
    // across patches, not across minor versions.
    if StrToVersion(Bundled, BundledPacked) and FindFirst(Dir + ChangeFileExt(Bundled, '.*'), FindRec) then
    begin
      try
        repeat
          if (FindRec.Attributes and FILE_ATTRIBUTE_DIRECTORY <> 0) and
             StrToVersion(FindRec.Name, InstalledPacked) and
             (ComparePackedVersion(InstalledPacked, BundledPacked) >= 0) then
            DotNetNeeded := False;
        until not FindNext(FindRec);
      finally
        FindClose(FindRec);
      end;
    end;
    DotNetChecked := True;
  end;
  Result := DotNetNeeded;
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

// The message backup-database.ps1 left in last-backup.txt, or a general one.
function BackupMessage: String;
var
  Lines: TArrayOfString;
begin
  Result := '';
  if LoadStringsFromFile(ExpandConstant('{commonappdata}\Vyaptek\HMS\backups\last-backup.txt'), Lines) then
    Result := ResultValue(Lines, 'message');
  if Result = '' then
    Result := 'the backup script did not report back';
end;

// Before an upgrade changes anything (OP11): this release's migrations cannot be undone, and PostgreSQL
// may be updated too. With HMS stopped, so nothing changes during the backup. This release's own script
// and age (from {tmp}): the box may not have them yet.
function BackupBeforeUpgrade: String;
var
  Code: Integer;
begin
  Result := '';
  if not PGInstalled or (DBPage.SelectedValueIndex <> 0) then
    Exit;
  ExtractTemporaryFile('backup-database.ps1');
  ExtractTemporaryFile('age.exe');
  ExtractTemporaryFile('age-keygen.exe');
  ExtractTemporaryFile('backup-master-key.txt');
  WizardForm.PreparingLabel.Caption := 'Backing up the hospital data before the upgrade...';
  WizardForm.PreparingLabel.Visible := True;
  if Exec('powershell.exe', '-NoProfile -ExecutionPolicy Bypass -File "' + ExpandConstant('{tmp}\backup-database.ps1') +
       '" -AppDir "' + RemoveBackslashUnlessRoot(WizardDirValue) + '" -Reason upgrade -ToolsDir "' + ExpandConstant('{tmp}') + '"',
       '', SW_HIDE, ewWaitUntilTerminated, Code) and (Code = 0) then
  begin
    BackupResult := 'The hospital data was backed up before the upgrade, in ' +
      ExpandConstant('{commonappdata}\Vyaptek\HMS\backups') + '.';
    Exit;
  end;
  // A silent install answers No: it never upgrades without a backup.
  if SuppressibleMsgBox('Setup couldn''t back up the hospital data before upgrading: ' + BackupMessage + '.' + #13#10#13#10 +
       'Upgrade anyway, without a backup? An upgrade cannot be undone.', mbError, MB_YESNO or MB_DEFBUTTON2, IDNO) = IDYES then
    BackupResult := 'The upgrade went ahead WITHOUT a backup (' + BackupMessage + ').'
  else
    Result := 'The upgrade was cancelled because the hospital data could not be backed up (' + BackupMessage +
      '). Nothing was changed. Send this message to Vyaptek.';
end;

// Stops a service and waits until it reports Stopped. True when it did, or when it is not installed.
// sc.exe stop only sends the request and returns while the service is still stopping, and Windows
// refuses it outright (1051) while a service that depends on it is still running. VyaptekHMS depends on
// VyaptekGarnet, so Garnet's stop went out while the backend was still stopping, was refused, and
// GarnetServer.exe was still running when [Files] came to replace it ("Skip this file").
// ServiceController.Stop() stops the dependents first; WinSW kills its process after 15 s by default.
function StopServiceAndWait(const Name: String): Boolean;
var
  Code: Integer;
begin
  Result := Exec('powershell.exe', '-NoProfile -ExecutionPolicy Bypass -Command "' +
    '$s = Get-Service -Name ''' + Name + ''' -ErrorAction SilentlyContinue; if (-not $s) { exit 0 }; ' +
    'if ($s.Status -notin ''Stopped'', ''StopPending'') { try { $s.Stop() } catch {} }; ' +
    'try { $s.WaitForStatus(''Stopped'', ''00:01:00''); exit 0 } catch { exit 1 }"',
    '', SW_HIDE, ewWaitUntilTerminated, Code) and (Code = 0);
end;

// Stops HMS's services, dependents first, so their files can be replaced. '' when all stopped, else
// why not. PostgreSQL stays up: the backup needs it.
function StopHMSServices: String;
var
  Names: TArrayOfString;
  I: Integer;
begin
  Result := '';
  WizardForm.PreparingLabel.Caption := 'Stopping HMS...';
  WizardForm.PreparingLabel.Visible := True;
  // VyaptekRedis: boxes installed before Garnet; garnet-install.bat removes it once Garnet is in place.
  SetArrayLength(Names, 4);
  Names[0] := 'VyaptekHMS';
  Names[1] := 'NginxWebProxy';
  Names[2] := 'VyaptekGarnet';
  Names[3] := 'VyaptekRedis';
  for I := 0 to GetArrayLength(Names) - 1 do
    if not StopServiceAndWait(Names[I]) then
    begin
      Result := 'Setup couldn''t stop the ' + Names[I] + ' service, so its files could not be replaced. ' +
        'Nothing was changed. Restart the computer and run setup again; if this happens again, send this ' +
        'message to Vyaptek.';
      Exit;
    end;
  // The process can hold its files for a moment after the service reports Stopped.
  Sleep(2000);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := StopHMSServices;
  if Result = '' then
    Result := BackupBeforeUpgrade;
  // Cancelled: start HMS again as it was, since nothing was replaced.
  if Result <> '' then
  begin
    Exec('sc.exe', 'start VyaptekGarnet', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    Exec('sc.exe', 'start VyaptekRedis',  '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    Exec('sc.exe', 'start VyaptekHMS',    '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    Exec('sc.exe', 'start NginxWebProxy', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  end;
end;

[InstallDelete]
; Wipe entire frontend dir so stale Vite-hashed assets don't accumulate
Type: filesandordirs; Name: "{app}\frontend"
; Remove old backend JAR before copying new one
Type: files; Name: "{app}\backend\hms.jar"
; Replace the Java runtime whole, so files a newer JRE dropped don't linger
Type: filesandordirs; Name: "{app}\jre"
; The same for Garnet's binaries; its logs folder and garnet.conf (rewritten every run) stay
Type: files; Name: "{app}\garnet\*.exe"
Type: files; Name: "{app}\garnet\*.dll"
Type: filesandordirs; Name: "{app}\garnet\extensions"
; The Windows Redis port that Garnet replaced (backend plan 24 §11, OP4)
Type: filesandordirs; Name: "{app}\redis"

[Files]
; 1. Java runtime — a private Temurin JRE that only the backend service uses (hms-service.xml).
;    It is not put on PATH or JAVA_HOME. Boxes installed before 2026-09 keep the Temurin 17 JDK the
;    old installer put there; HMS no longer uses it.
Source: "jre\*"; DestDir: "{app}\jre"; Flags: recursesubdirs createallsubdirs ignoreversion

;    Installers — extracted to temp and deleted after use
Source: "libreoffice.msi"; DestDir: "{tmp}"; Flags: deleteafterinstall nocompression; Check: ShouldInstallLibreOffice
Source: "pg.exe";   DestDir: "{tmp}"; Flags: deleteafterinstall; Check: NeedsPgInstaller

; 2. Pre-flight SQL (extensions + role only — Flyway migrates on first backend start)
Source: "setup_database.sql"; DestDir: "{app}"
Source: "init_db.bat";        DestDir: "{app}"; Flags: deleteafterinstall
Source: "clean_db.bat";       DestDir: "{app}"; Flags: deleteafterinstall
Source: "free-port-80.bat";   DestDir: "{app}"
;    Migrates the database and sets the backend's accounts, as the superuser (plan 24 §11, OP1).
Source: "setup-database.bat"; DestDir: "{app}"
;    PostgreSQL on this computer only (OP7), the services' own accounts and folders (OP2, OP3), and the
;    wait for the backend after it starts (OP2).
Source: "secure-postgres.ps1";  DestDir: "{app}"
Source: "service-accounts.ps1"; DestDir: "{app}"
Source: "wait-for-backend.ps1"; DestDir: "{app}"
;    Support without manual steps (OP1, OP8): a 4-hour pgAdmin login, and Vyaptek-signed one-box fixes.
;    Both ask for administrator rights; only Administrators can read the superuser's password.
Source: "HMS-DB-Support.bat"; DestDir: "{app}"
Source: "hms-db-support.ps1"; DestDir: "{app}"
Source: "Run-HMS-Fix.bat";    DestDir: "{app}"
Source: "run-hms-fix.ps1";    DestDir: "{app}"
Source: "fix-signing-key.xml"; DestDir: "{app}"
;    Host evidence for an audit (OP12): BitLocker, antivirus, firewall, updates, services, ports.
Source: "Check-HMS-Host.bat"; DestDir: "{app}"
Source: "check-host.ps1";     DestDir: "{app}"
;    Encrypted backups (OP11): nightly, and before every upgrade, which runs this release's copies from
;    {tmp} (the dontcopy lines) before anything is replaced. age encrypts them; only Vyaptek's key opens
;    them. Restore-HMS-Backup.bat puts one back.
Source: "backup-database.ps1";   DestDir: "{app}"
Source: "restore-backup.ps1";    DestDir: "{app}"
Source: "Restore-HMS-Backup.bat"; DestDir: "{app}"
Source: "backup-master-key.txt"; DestDir: "{app}"
Source: "age\age.exe";           DestDir: "{app}"; Flags: ignoreversion
Source: "age\age-keygen.exe";    DestDir: "{app}"; Flags: ignoreversion
Source: "backup-database.ps1";   Flags: dontcopy
Source: "backup-master-key.txt"; Flags: dontcopy
Source: "age\age.exe";           Flags: dontcopy
Source: "age\age-keygen.exe";    Flags: dontcopy

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
;    HTTPS on the hospital network (backend plan 24 section 11, OP5): the trust page (http://<box>/trust),
;    and the script that keeps this computer's certificate (at install, start, hourly, on a network
;    change). lan-site.conf (in conf above) arrives as plain HTTP; lan-tls.ps1 switches it to HTTPS once
;    nginx accepts that.
Source: "nginx\trust\*";   DestDir: "{app}\nginx\trust"; Flags: recursesubdirs createallsubdirs
Source: "lan-tls.ps1";     DestDir: "{app}"
Source: "nginx-service.exe"; DestDir: "{app}"
Source: "nginx-service.xml"; DestDir: "{app}"

; 6. Garnet, the cache server that holds sessions: Microsoft's, speaking the Redis protocol, in place of
;    the archived Windows Redis 5 port (backend plan 24 §11, OP4). CI stages the pinned release into
;    garnet\bin (without its sample garnet.conf; write-secrets.ps1 writes this box's). WinSW runs it,
;    as it runs nginx and the backend.
Source: "garnet\bin\*";              DestDir: "{app}\garnet"; Flags: recursesubdirs createallsubdirs ignoreversion
Source: "garnet\garnet-service.xml"; DestDir: "{app}\garnet"
Source: "garnet\garnet-install.bat"; DestDir: "{app}\garnet"
Source: "nginx-service.exe";         DestDir: "{app}\garnet"; DestName: "garnet-service.exe"
;    The .NET runtime Garnet runs on, when this computer lacks it.
Source: "dotnet-runtime.exe"; DestDir: "{tmp}"; Flags: deleteafterinstall nocompression; Check: ShouldInstallDotNet

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
; 1'. An upgrade on a box with an older 18.x: the same installer updates it in place, keeping its data and
;     settings (it ignores these options then). After the backup in PrepareToInstall.
Filename: "{tmp}\pg.exe"; Parameters: "--mode unattended --unattendedmodeui none --prefix ""{app}\pgsql"""; Flags: runhidden waituntilterminated; StatusMsg: "Updating PostgreSQL to {#PostgresVersion}..."; Check: ShouldPatchPG; AfterInstall: CheckPostgresPatched

; 2a. Clean install — drop existing DB, recreate, run SQL
Filename: "{app}\clean_db.bat"; Parameters: """{app}\pgsql\bin"" ""{app}\setup_database.sql"" ""{app}\backend\config"""; Flags: runhidden; StatusMsg: "Resetting database..."; Check: ShouldCleanDB

; 2b. Fresh install only — create DB and run setup SQL (skipped on upgrades)
Filename: "{app}\init_db.bat"; Parameters: """{app}\pgsql\bin"" ""{app}\setup_database.sql"" ""{app}\backend\config"""; Flags: runhidden; StatusMsg: "Initializing database..."; Check: ShouldInitDB

; 3. The box's own secrets (backend plan 24, C2, C6, I3): the sign-in key (kept on upgrade; a box that
;    never had one gets one, which logs everyone out once), the admin password on a new database, a
;    random PostgreSQL superuser password instead of "admin" (again when the database is new), kept in
;    pg-superuser.secret, the backend's own database accounts (OP1) and a cache (Garnet) password with
;    Garnet's whole config. Before Garnet is (re)registered, so it starts with its password.
Filename: "powershell.exe"; Parameters: "{code:WriteSecretsParams}"; Flags: runhidden waituntilterminated; StatusMsg: "Securing this computer's keys and database accounts..."; AfterInstall: CheckSecretsWritten

; 3a. The product key, when one was entered: into the locked config folder from step 3, for the backend
;     to activate at its first start (it then deletes the file and writes license-activated).
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\validate-license.ps1"" -Mode Install -KeyFile ""{tmp}\license-key.txt"" -ConfigDir ""{app}\backend\config"" -ResultFile ""{tmp}\license-install-result.txt"""; Flags: runhidden waituntilterminated; StatusMsg: "Saving the product key..."; Check: HasLicenseKey; AfterInstall: CheckLicenseInstalled
; 3a'. No key entered on a computer without one: HMS opens read-only until an administrator enters it.
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\validate-license.ps1"" -Mode RequireKey -ConfigDir ""{app}\backend\config"" -ResultFile ""{tmp}\license-install-result.txt"""; Flags: runhidden waituntilterminated; StatusMsg: "Recording that the product key is still to be entered..."; Check: KeyWasSkipped; AfterInstall: CheckKeyRequired
; 3b. ABDM, when the license includes it and this computer is not connected yet, or is connected as
;     another box than the key's (a new key, or a reinstall that kept old settings): redeem the product key
;     with Vyaptek and write this box's ABDM settings into the secret file from step 3. Before the
;     backend starts, so it starts with them.
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\enroll-abdm.ps1"" -ConfigDir ""{app}\backend\config"" -RelayUrl ""{#AbdmRelayUrl}"" -ProductKeyFile ""{tmp}\abdm-product-key.txt"" -ResultFile ""{tmp}\abdm-enroll-result.txt"""; Flags: runhidden waituntilterminated; StatusMsg: "Connecting to ABDM..."; Check: ShouldEnrollAbdm; AfterInstall: CheckAbdmEnrolled
; 3c. ABDM refuses replies stamped more than ~15 minutes off, so keep the clock synced.
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\time-sync.ps1"""; Flags: runhidden waituntilterminated; StatusMsg: "Setting up time sync..."; Check: IsAbdmEnrolled

; 4. Garnet: the .NET runtime first when missing, then the service (which also removes the old
;    VyaptekRedis, on the same port).
Filename: "{tmp}\dotnet-runtime.exe"; Parameters: "/install /quiet /norestart"; Flags: runhidden waituntilterminated; StatusMsg: "Installing the .NET runtime (cache server)..."; Check: ShouldInstallDotNet
Filename: "{app}\garnet\garnet-install.bat"; Parameters: """{app}\garnet"""; Flags: runhidden waituntilterminated; StatusMsg: "Registering and starting the cache server..."
 
; 5. LibreOffice, for PDF reports. Without it the backend still runs, but every PDF fails.
;    REGISTER_NO_MSO_TYPES=1 leaves .docx/.xlsx opening in MS Office on PCs that have it.
Filename: "msiexec.exe"; Parameters: "/i ""{tmp}\libreoffice.msi"" /qn /norestart ADDLOCAL=ALL REMOVE=gm_o_Onlineupdate REGISTER_NO_MSO_TYPES=1 QUICKSTART=0 ISCHECKFORPRODUCTUPDATES=0 CREATEDESKTOPLINK=0 RebootYesNo=No UI_LANGS=en_US"; Flags: runhidden; StatusMsg: "Installing LibreOffice (PDF reports)..."; Check: ShouldInstallLibreOffice

; 6. PostgreSQL listens on this computer only and takes SCRAM passwords only (OP7), before anything
;    signs in to it below.
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\secure-postgres.ps1"" -ConfigDir ""{app}\backend\config"" -PgBin ""{app}\pgsql\bin"" -LogFile ""{app}\backend\logs\secure-postgres.log"""; Flags: runhidden waituntilterminated; StatusMsg: "Updating the hospital database..."; Check: SecretsReady
;    The database: this release's migrations and the backend's accounts, as the superuser (OP1). The
;    backend's own account cannot change the schema, so this runs before it starts, on every run.
Filename: "{app}\setup-database.bat"; Parameters: """{app}"""; Flags: runhidden waituntilterminated; StatusMsg: "Updating the hospital database..."; Check: SecretsReady; AfterInstall: CheckDatabaseSetUp
;    Support logins (HMS-DB-Support.bat) whose 4 hours are over: they can no longer sign in; this removes them.
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\hms-db-support.ps1"" -CleanupOnly"; Flags: runhidden waituntilterminated; StatusMsg: "Updating the hospital database..."; Check: DatabaseReady

; 7. Register the backend and nginx, then run each as its own account (OP2) before either starts.
Filename: "{app}\backend\hms-service.exe"; Parameters: "install"; Flags: runhidden; StatusMsg: "Registering Backend Service..."
;    On every run: "install" fails on a service that already exists, and the XMLs turn WinSW's own
;    refresh-at-start off (the service accounts cannot do it), so apply them here, as an administrator.
;    Without this a box upgraded from Redis would keep waiting on the removed VyaptekRedis and the backend
;    would never start. "refresh" leaves the account alone (service-accounts.ps1 sets it below).
Filename: "{app}\backend\hms-service.exe"; Parameters: "refresh"; Flags: runhidden; StatusMsg: "Registering Backend Service..."
;    Free port 80 first -- stop & disable the IIS/HTTP stack (W3SVC/WAS) that
;    otherwise squats on port 80 and prevents Nginx from binding.
Filename: "{app}\free-port-80.bat"; Flags: runhidden; StatusMsg: "Freeing web port 80..."
Filename: "{app}\nginx-service.exe"; Parameters: "install"; Flags: runhidden; StatusMsg: "Registering Web Server..."
Filename: "{app}\nginx-service.exe"; Parameters: "refresh"; Flags: runhidden; StatusMsg: "Registering Web Server..."
;    Their own Windows accounts and folders; the uploads move from C:\data\uploads once (OP3).
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\service-accounts.ps1"" -AppDir ""{app}"" -LogFile ""{app}\backend\logs\service-accounts.log"""; Flags: runhidden waituntilterminated; StatusMsg: "Setting up the HMS service accounts..."; AfterInstall: CheckServiceAccounts
;    HTTPS (OP5): this computer's certificate, trusted on this computer, nginx switched to HTTPS, and the
;    task that keeps it current. After nginx's account exists (it is given the certificate) and before
;    nginx starts.
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\lan-tls.ps1"" -AppDir ""{app}"" -Install -ResultFile ""{tmp}\lan-tls-result.txt"""; Flags: runhidden waituntilterminated; StatusMsg: "Setting up HTTPS for the hospital network..."; AfterInstall: CheckLanTls

; 8. Start the backend and nginx (the React frontend), then wait up to 10 minutes for the backend to
;    answer (OP2).
Filename: "{app}\backend\hms-service.exe"; Parameters: "start";   Flags: runhidden; StatusMsg: "Starting Backend API..."; Check: DatabaseReady
Filename: "{app}\nginx-service.exe"; Parameters: "start";   Flags: runhidden; StatusMsg: "Starting User Interface..."
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\wait-for-backend.ps1"" -ResultFile ""{tmp}\backend-status.txt"""; Flags: runhidden waituntilterminated; StatusMsg: "Starting HMS -- this can take a few minutes..."; Check: DatabaseReady; AfterInstall: CheckBackendStarted

; 8a. The nightly encrypted backup (OP11), registered again on every run.
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\backup-database.ps1"" -Schedule"; Flags: runhidden waituntilterminated; StatusMsg: "Scheduling the nightly backup..."

; 9. Firewall: ports 80 and 443 (HTTPS, OP5) from the hospital's own network only (OP6): this computer's subnets and the
;    private address ranges (routed VLANs between wards use them), never the internet. Every network
;    profile, because Windows marks a network nobody classified as Public. Deleted first: "add rule"
;    added another copy on every run. Garnet 6379 and the backend 8080 listen on 127.0.0.1 only, and
;    PostgreSQL does too (OP7).
Filename: "{cmd}"; Parameters: "/c ""netsh advfirewall firewall delete rule name=""Vyaptek HMS Web"" >nul 2>&1 & netsh advfirewall firewall add rule name=""Vyaptek HMS Web"" dir=in action=allow protocol=TCP localport=80,443 profile=any remoteip=LocalSubnet,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"""; Flags: runhidden; StatusMsg: "Configuring Windows Firewall..."

[UninstallRun]
; Stop and remove in reverse startup order
Filename: "{app}\nginx-service.exe";         Parameters: "stop";      Flags: runhidden
Filename: "{app}\nginx-service.exe";         Parameters: "uninstall"; Flags: runhidden
Filename: "{app}\backend\hms-service.exe";   Parameters: "stop";      Flags: runhidden
Filename: "{app}\backend\hms-service.exe";   Parameters: "uninstall"; Flags: runhidden
Filename: "{app}\garnet\garnet-service.exe"; Parameters: "stop";      Flags: runhidden
Filename: "{app}\garnet\garnet-service.exe"; Parameters: "uninstall"; Flags: runhidden
;    A box never upgraded since Garnet still has the old Redis service.
Filename: "{sys}\sc.exe"; Parameters: "stop VyaptekRedis";   Flags: runhidden
Filename: "{sys}\sc.exe"; Parameters: "delete VyaptekRedis"; Flags: runhidden
Filename: "{cmd}"; Parameters: "/c ""netsh advfirewall firewall delete rule name=""Vyaptek HMS Web"""""; Flags: runhidden; RunOnceId: "RemoveFirewallRule"
;    The nightly backup. The backups themselves (%ProgramData%\Vyaptek\HMS\backups) are the hospital's
;    data and stay.
Filename: "{sys}\schtasks.exe"; Parameters: "/Delete /TN ""\Vyaptek\Vyaptek HMS Backup"" /F"; Flags: runhidden; RunOnceId: "RemoveBackupTask"
;    HTTPS (OP5): the certificate task, and this computer's own trust in the CA. The CA itself
;    (%ProgramData%\Vyaptek\HMS\lan-ca) stays, like the box's other secrets, so a reinstall keeps every
;    PC's trust.
Filename: "{sys}\schtasks.exe"; Parameters: "/Delete /TN ""\Vyaptek\Vyaptek HMS HTTPS Certificate"" /F"; Flags: runhidden; RunOnceId: "RemoveLanTlsTask"
Filename: "powershell.exe"; Parameters: "-NoProfile -Command ""Get-ChildItem Cert:\LocalMachine\Root | Where-Object {{ $_.Subject -like '*O=Vyaptek HMS*' -and $_.Subject -like '*LAN CA*' } | Remove-Item"""; Flags: runhidden; RunOnceId: "RemoveLanCaTrust"

; backend\config (the box's secrets) is kept on uninstall on purpose: PostgreSQL is not uninstalled,
; and that file holds the only copy of its superuser password (backend plan 24, I3). The folder is
; readable by SYSTEM and Administrators only. Delete it by hand after removing PostgreSQL.

[UninstallDelete]
; Written by write-secrets.ps1 and the service, not by [Files], so not removed otherwise. garnet.conf holds
; only the cache password, which nothing needs once HMS is gone.
Type: files; Name: "{app}\garnet\garnet.conf"
Type: filesandordirs; Name: "{app}\garnet\logs"
; The server certificate and the trust page's files, written by lan-tls.ps1 (OP5).
Type: filesandordirs; Name: "{app}\nginx\conf\tls"
Type: filesandordirs; Name: "{app}\nginx\trust"
; The backend's temp folder (OP2). Its uploads folder next to it is the hospital's data and stays.
Type: filesandordirs; Name: "{commonappdata}\Vyaptek\HMS\temp"
