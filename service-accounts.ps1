<#
  Runs the backend and nginx as their own Windows accounts instead of LocalSystem, and gives each one
  only the folders it writes (backend plan 24 section 11, OP2 and OP3). Run by the installer on every
  install and upgrade, after both services are registered (an "NT SERVICE\<name>" account exists only
  once its service does) and before they start.

  Accounts: virtual service accounts, which Windows manages itself (no password, nothing to rotate).
    VyaptekHMS     -> NT SERVICE\VyaptekHMS
    NginxWebProxy  -> NT SERVICE\NginxWebProxy
  Both are members of Users, so they read Program Files (the jar, the Java runtime, LibreOffice, nginx's
  html and conf) as before. Garnet already ran as Network Service (OP4).

  What the backend writes, and nothing else:
    backend\config      the ABDM token rotation and the license marker rewrite files here. Modify, not
                        Full: pg-superuser.secret keeps its own Administrators-only entry (write-secrets.ps1)
                        and the backend can neither read nor delete it.
    backend\logs        WinSW's logs.
    %ProgramData%\Vyaptek\HMS\uploads   uploaded report files (FILE_STORAGE_DIR in hms-service.xml).
    %ProgramData%\Vyaptek\HMS\temp      java.io.tmpdir (hms-service.xml), which also holds LibreOffice's
                                        per-process profiles (JODConverter puts them under the temp folder).
  nginx writes its logs and temp folders only.

  The two ProgramData folders and backend\logs lose the entries they inherited (a folder under C:\ or
  Program Files gives local users read, or Authenticated Users modify): SYSTEM, Administrators and the
  service account only.

  OP3: uploads used to go to C:\data\uploads (the installer never set FILE_STORAGE_DIR, so the backend's
  default /data/uploads). Its files are moved to the new folder once; the database keeps paths relative
  to the folder, so nothing in it changes. C:\data is removed when nothing else is left in it.

  Exit code 0 on success, 1 on any failure; details in -LogFile.
#>
param(
  [Parameter(Mandatory = $true)][string]$AppDir,
  [string]$DataDir = (Join-Path $env:ProgramData 'Vyaptek\HMS'),
  [string]$OldUploads = 'C:\data\uploads',
  [string]$LogFile
)
$ErrorActionPreference = 'Stop'

function Log([string]$text) {
  Write-Output $text
  if ($LogFile) { Add-Content -Path $LogFile -Encoding ASCII -Value ((Get-Date -Format s) + ' ' + $text) }
}
if ($LogFile) {
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LogFile) | Out-Null
  Set-Content -Path $LogFile -Encoding ASCII -Value @()
}

function Invoke-Checked([string]$what, [scriptblock]$command) {
  $out = & $command 2>&1
  if ($LASTEXITCODE -ne 0) { throw "$what failed ($LASTEXITCODE): $($out -join ' ')" }
}

# SIDs, not names, for the built-in groups: their names are localised on non-English Windows.
$system = '*S-1-5-18'
$admins = '*S-1-5-32-544'

# Only SYSTEM, Administrators and the one account, inherited by everything below; existing files and
# folders below are reset to inherit it.
function Set-Private([string]$dir, [string]$account) {
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  Invoke-Checked "icacls $dir" { icacls $dir /inheritance:r /grant:r "${system}:(OI)(CI)F" "${admins}:(OI)(CI)F" "${account}:(OI)(CI)M" }
  if (Get-ChildItem -Force $dir) {
    Invoke-Checked "icacls $dir\*" { icacls (Join-Path $dir '*') /reset /T /C /Q }
  }
}

function Set-ServiceAccount([string]$service) {
  # No password: Windows manages a virtual account's. (Windows PowerShell drops an empty '' argument, so
  # "password= ''" would not reach sc.exe as written anyway.)
  Invoke-Checked "sc config $service" { sc.exe config $service obj= "NT SERVICE\$service" }
  Log "$service runs as NT SERVICE\$service."
}

try {
  $hms = 'NT SERVICE\VyaptekHMS'
  $nginx = 'NT SERVICE\NginxWebProxy'
  $uploads = Join-Path $DataDir 'uploads'
  $temp = Join-Path $DataDir 'temp'

  # The parent first: Administrators and SYSTEM only, so the two folders below cannot be reached around.
  New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
  Invoke-Checked "icacls $DataDir" { icacls $DataDir /inheritance:r /grant:r "${system}:(OI)(CI)F" "${admins}:(OI)(CI)F" }

  Set-Private $uploads $hms
  Set-Private $temp $hms
  Set-Private (Join-Path $AppDir 'backend\logs') $hms

  # backend\config: write-secrets.ps1 has just reset it to SYSTEM and Administrators; add the backend.
  # pg-superuser.secret does not inherit (write-secrets.ps1 removed that), so this never reaches it.
  $config = Join-Path $AppDir 'backend\config'
  Invoke-Checked "icacls $config" { icacls $config /grant "${hms}:(OI)(CI)M" }
  $superFile = Join-Path $config 'pg-superuser.secret'
  if ((Test-Path $superFile) -and ((icacls $superFile) -match 'VyaptekHMS')) {
    throw "$superFile is readable by the backend's account."
  }

  foreach ($dir in @('nginx\logs', 'nginx\temp')) {
    $path = Join-Path $AppDir $dir
    New-Item -ItemType Directory -Force -Path $path | Out-Null
    Invoke-Checked "icacls $path" { icacls $path /grant "${nginx}:(OI)(CI)M" }
  }

  # OP3: move the files the backend wrote under C:\data\uploads. robocopy /MOVE deletes each source file
  # once copied; /COPY:DAT leaves its old permissions behind, so it inherits the new folder's. Exit
  # codes below 8 are success.
  if ((Test-Path $OldUploads) -and ((Resolve-Path $OldUploads).Path -ne (Resolve-Path $uploads).Path)) {
    $out = robocopy $OldUploads $uploads /E /MOVE /COPY:DAT /DCOPY:T /R:2 /W:2 /NP /NJH 2>&1
    if ($LASTEXITCODE -ge 8) { throw "Moving $OldUploads failed ($LASTEXITCODE): $($out -join ' ')" }
    if (Test-Path $OldUploads) { Remove-Item -Recurse -Force $OldUploads }
    $parent = Split-Path -Parent $OldUploads
    if ((Test-Path $parent) -and -not (Get-ChildItem -Force $parent)) { Remove-Item -Force $parent }
    Invoke-Checked "icacls $uploads\*" { icacls (Join-Path $uploads '*') /reset /T /C /Q }
    Log "Moved the uploaded files from $OldUploads to $uploads."
  }

  Set-ServiceAccount 'VyaptekHMS'
  Set-ServiceAccount 'NginxWebProxy'
  exit 0
} catch {
  Log "Could not set up the service accounts: $($_.Exception.Message)"
  exit 1
}
