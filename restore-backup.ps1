<#
  Puts a backup from backup-database.ps1 back (backend plan 24 section 11, OP11). Run through
  Restore-HMS-Backup.bat, which asks for administrator rights.

  1. Pick a backup set: one of this computer's, or a folder copied from another computer (a new computer
     after the old one failed works the same way: install HMS, then run this).
  2. Send that set's box-key.age to Vyaptek. Vyaptek sends back the key for that set's computer, a line
     starting AGE-SECRET-KEY-1. Only Vyaptek can produce it.
  3. Paste it, and type RESTORE. HMS stops; the current data is backed up first (as a "restore" set);
     the database is replaced by the backup's, then brought up to this release (setup-database.bat, which
     also sets the backend's accounts and rights); the uploaded files are replaced; HMS starts again.
  4. That key has now been out of the computer, so this computer makes a new backup key pair: the next
     backup uses it.

  Install the same HMS release as the backup's, or a newer one, before restoring: a newer database than
  the installed HMS knows would not start. The decrypted data streams from age into pg_restore and tar;
  only the key is written down, in a folder only Administrators can read, and deleted at the end.
#>
param(
  [string]$AppDir = (Split-Path -Parent $MyInvocation.MyCommand.Path),
  [string]$BackupRoot = (Join-Path $env:ProgramData 'Vyaptek\HMS\backups'),
  [string]$Set = ''
)
$ErrorActionPreference = 'Stop'
$age = Join-Path $AppDir 'age.exe'
$ageKeygen = Join-Path $AppDir 'age-keygen.exe'
$pgBin = Join-Path $AppDir 'pgsql\bin'
$configDir = Join-Path $AppDir 'backend\config'
$uploads = Join-Path $env:ProgramData 'Vyaptek\HMS\uploads'
$work = Join-Path $env:ProgramData 'Vyaptek\HMS\restore-key'

function Write-Event([string]$type, [int]$id, [string]$text) {
  & eventcreate /T $type /ID $id /L APPLICATION /SO VyaptekHMS /D $text | Out-Null
}

# The same as backup-database.ps1's: binary data stays in cmd's pipe, secrets in the environment. cmd
# reports only the last command's exit code, so age, first in each pipe, leaves a marker when it fails.
function Invoke-Pipe([string]$commandLine, [hashtable]$environment = @{}) {
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
  $psi.Arguments = '/d /s /c "' + $commandLine + '"'
  $psi.UseShellExecute = $false
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  foreach ($k in $environment.Keys) { $psi.EnvironmentVariables[$k] = $environment[$k] }
  $p = [Diagnostics.Process]::Start($psi)
  $err = $p.StandardError.ReadToEnd()
  $p.WaitForExit()
  return @{ Code = $p.ExitCode; Error = $err.Trim() }
}

function Read-Manifest([string]$dir) {
  $m = @{ files = @() }
  foreach ($line in Get-Content (Join-Path $dir 'backup.txt')) {
    $k, $v = $line -split '=', 2
    if ($k -eq 'file') { $m.files += $v } else { $m[$k] = $v }
  }
  return $m
}

function Select-Set {
  $sets = @(Get-ChildItem $BackupRoot -Directory -ErrorAction SilentlyContinue |
      Where-Object { Test-Path (Join-Path $_.FullName 'backup.txt') } | Sort-Object Name -Descending)
  Write-Host ''
  if ($sets.Count -eq 0) { Write-Host "No backups in $BackupRoot." }
  for ($i = 0; $i -lt $sets.Count; $i++) {
    $size = (Get-ChildItem $sets[$i].FullName -File | Measure-Object Length -Sum).Sum
    Write-Host ("  {0,2}. {1}  ({2:N0} MB)" -f ($i + 1), $sets[$i].Name, ($size / 1MB))
  }
  Write-Host ''
  $answer = (Read-Host 'Number of the backup to restore, or the full path of a backup folder').Trim().Trim('"')
  if ($answer -match '^\d+$' -and [int]$answer -ge 1 -and [int]$answer -le $sets.Count) { return $sets[[int]$answer - 1].FullName }
  if ($answer -and (Test-Path (Join-Path $answer 'backup.txt'))) { return (Resolve-Path $answer).Path }
  throw "'$answer' is not a backup in the list, nor a folder holding backup.txt."
}

function Get-SuperuserPassword {
  $secret = Join-Path $configDir 'pg-superuser.secret'
  if (-not (Test-Path $secret)) { throw "$secret is missing. Run the HMS installer again first." }
  return (Get-Content -Raw $secret).Trim()
}

function Invoke-Superuser([string]$database, [string]$sql, [string]$password) {
  $r = Invoke-Pipe "`"$pgBin\psql.exe`" -h 127.0.0.1 -p 5432 -U postgres -d $database -w -v ON_ERROR_STOP=1 -q -c `"$sql`"" @{ PGPASSWORD = $password }
  if ($r.Code -ne 0) { throw "PostgreSQL refused '$sql': $($r.Error)" }
}

$keyFile = $null
$stopped = $false
$exitCode = 0
try {
  foreach ($tool in @($age, $ageKeygen, "$pgBin\pg_restore.exe", "$pgBin\psql.exe")) {
    if (-not (Test-Path $tool)) { throw "$tool is missing. Run the HMS installer again first." }
  }
  if (-not $Set) { $Set = Select-Set }
  $m = Read-Manifest $Set
  foreach ($entry in $m.files) {
    $f, $len, $sha = $entry -split ' '
    $path = Join-Path $Set $f
    if (-not (Test-Path $path) -or (Get-FileHash $path -Algorithm SHA256).Hash.ToLower() -ne $sha) {
      throw "$path is missing or damaged (its checksum does not match backup.txt)."
    }
  }
  Write-Host ''
  Write-Host "Backup of $($m.computer), $($m.created) ($($m.reason)), HMS $($m['hms-version'])."
  Write-Host ''
  Write-Host 'Send this file to Vyaptek (it opens in Explorer now):'
  Write-Host "  $(Join-Path $Set 'box-key.age')"
  Write-Host 'Vyaptek sends back this backup''s key: one line starting with AGE-SECRET-KEY-1.'
  Start-Process explorer.exe "/select,`"$(Join-Path $Set 'box-key.age')`""
  Write-Host ''
  $key = (Read-Host 'Paste the key from Vyaptek').Trim()
  if ($key -notmatch '^AGE-SECRET-KEY-1[0-9A-Z]+$') { throw 'That is not a key from Vyaptek: it starts with AGE-SECRET-KEY-1.' }

  # The key in a file age can read, in a folder only Administrators and SYSTEM can open.
  New-Item -ItemType Directory -Force -Path $work | Out-Null
  icacls $work /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "icacls failed on $work" }
  $keyFile = Join-Path $work 'key.txt'
  Set-Content -Path $keyFile -Encoding ASCII -Value $key
  $public = (& $ageKeygen -y $keyFile 2>&1 | Out-String).Trim()
  if ($public -ne $m.recipient) { throw 'This key is not for this backup. Check with Vyaptek that they used this backup''s box-key.age.' }

  $installed = try { (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{010389d7-9c59-4047-b368-0da2344ea258}_is1' -ErrorAction Stop).DisplayVersion } catch { 'unknown' }
  Write-Host ''
  Write-Host "This REPLACES all of this computer's HMS data with the backup from $($m.created)."
  Write-Host "Installed HMS: $installed. The backup's: $($m['hms-version']). The installed one must be the same or newer."
  Write-Host 'HMS stops for everyone until the restore is done. The current data is backed up first.'
  if ((Read-Host 'Type RESTORE to go on') -cne 'RESTORE') { throw 'Nothing was changed.' }

  Write-Host 'Backing up the current data...'
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $AppDir 'backup-database.ps1') -AppDir $AppDir -Reason restore
  if ($LASTEXITCODE -ne 0) {
    if ((Read-Host 'The current data could not be backed up (see above). Type YES to restore anyway') -cne 'YES') { throw 'Nothing was changed.' }
  }

  Write-Host 'Stopping HMS...'
  Stop-Service VyaptekHMS -Force -ErrorAction SilentlyContinue
  $stopped = $true
  $password = Get-SuperuserPassword

  Write-Host 'Restoring the database...'
  Invoke-Superuser postgres 'DROP DATABASE IF EXISTS hospital_erp WITH (FORCE)' $password
  Invoke-Superuser postgres 'CREATE DATABASE hospital_erp' $password
  # Owners and rights are this computer's: setup-database.bat sets them below, as on every install.
  $r = Invoke-Pipe ("(`"$age`" -d -i `"$keyFile`" `"$(Join-Path $Set 'database.dump.age')`" || (echo HMS_PIPE_SOURCE_FAILED 1>&2)) | " +
      "`"$pgBin\pg_restore.exe`" -h 127.0.0.1 -p 5432 -U postgres -w -d hospital_erp --no-owner --no-acl --exit-on-error --single-transaction") @{ PGPASSWORD = $password }
  if ($r.Code -ne 0 -or $r.Error -match 'HMS_PIPE_SOURCE_FAILED') { throw "the database could not be restored: $($r.Error)" }

  Write-Host 'Bringing the database up to this release...'
  & (Join-Path $env:SystemRoot 'System32\cmd.exe') /d /c "`"$(Join-Path $AppDir 'setup-database.bat')`" `"$AppDir`""
  $log = Join-Path $AppDir 'backend\logs\database-setup.log'
  if (-not (Select-String -Path $log -Pattern '^Database ready:' -Quiet)) { throw "the restored database could not be updated; see $log" }

  if (Test-Path (Join-Path $Set 'uploads.tar.age')) {
    Write-Host 'Restoring the uploaded files...'
    New-Item -ItemType Directory -Force -Path $uploads | Out-Null
    Get-ChildItem $uploads -Force | Remove-Item -Recurse -Force
    $r = Invoke-Pipe ("(`"$age`" -d -i `"$keyFile`" `"$(Join-Path $Set 'uploads.tar.age')`" || (echo HMS_PIPE_SOURCE_FAILED 1>&2)) | " +
        "`"$env:SystemRoot\System32\tar.exe`" -xf - -C `"$uploads`"")
    if ($r.Code -ne 0 -or $r.Error -match 'HMS_PIPE_SOURCE_FAILED') { throw "the uploaded files could not be restored: $($r.Error)" }
    # Back to the folder's own rights (SYSTEM, Administrators, the backend's account; service-accounts.ps1).
    icacls (Join-Path $uploads '*') /reset /T /C /Q | Out-Null
  }

  # The key left this computer: the next backup makes a new pair.
  Remove-Item (Join-Path $configDir 'backup-recipient.txt'), (Join-Path $configDir 'backup-box-key.age') -ErrorAction SilentlyContinue

  $text = "HMS data restored from $Set (backup of $($m.computer), $($m.created)) by $env:USERDOMAIN\$env:USERNAME."
  Write-Event WARNING 813 $text
  Write-Host ''
  Write-Host $text
} catch {
  $text = "HMS restore FAILED: $($_.Exception.Message)"
  if ($stopped) {
    Write-Event ERROR 814 $text
    $text += ' The backup taken just before is in ' + $BackupRoot + ' (the newest "restore" set). Send this message to Vyaptek.'
  }
  Write-Host ''
  Write-Host $text -ForegroundColor Red
  $exitCode = 1
} finally {
  if ($keyFile) { Remove-Item -Force $keyFile -ErrorAction SilentlyContinue }
  if (Test-Path $work) { Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue }
  if ($stopped) {
    Write-Host 'Starting HMS...'
    Start-Service VyaptekHMS -ErrorAction SilentlyContinue
  }
}
exit $exitCode
