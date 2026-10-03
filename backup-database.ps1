<#
  Encrypted backups of the hospital's data (backend plan 24 section 11, OP11).

  (no switch)  Writes one backup set under %ProgramData%\Vyaptek\HMS\backups: the database (pg_dump,
               custom format) and the uploaded files (tar), each encrypted with age. Keeps the newest
               14 nightly sets and the newest 3 of each other kind; older ones are deleted.
  -Reason      nightly (the scheduled task), upgrade (the installer, before it changes anything) or
               restore (Restore-HMS-Backup.bat, before it replaces the data).
  -Schedule    Only registers the nightly task: 01:30 as SYSTEM, and at the next start when the computer
               was off then. The installer runs this on every install and upgrade.
  -ToolsDir    Where age.exe, age-keygen.exe and backup-master-key.txt are (default: the HMS folder). The
               installer passes its own copies before an upgrade, when the HMS folder may not have them yet.

  Only Vyaptek can read a backup (decided 2026-10-03). Each computer has its own age key pair. Its public
  half (backend\config\backup-recipient.txt) encrypts the backups. Its private half is never stored as
  it is: it goes straight from age-keygen into age, encrypted to Vyaptek's backup key
  (backup-master-key.txt), and is kept as box-key.age in every set. To restore, Vyaptek decrypts that
  one small file (backend scripts/unwrap-box-backup-key.sh) and gives the hospital that computer's key,
  never Vyaptek's own. Restore-HMS-Backup.bat then makes this computer a new key pair.

  Nothing unencrypted reaches the disk: pg_dump and tar stream into age through cmd's pipe.
  Each run's result goes to the Windows Application event log (source VyaptekHMS, 811 written, 812
  failed) and to backups\last-backup.txt, which Check-HMS-Host.bat reports.
#>
param(
  [string]$AppDir = (Split-Path -Parent $MyInvocation.MyCommand.Path),
  [ValidateSet('nightly', 'upgrade', 'restore')][string]$Reason = 'nightly',
  [string]$BackupRoot = (Join-Path $env:ProgramData 'Vyaptek\HMS\backups'),
  [string]$ToolsDir = '',
  [switch]$Schedule,
  [int]$KeepNightly = 14,
  [int]$KeepOther = 3
)
$ErrorActionPreference = 'Stop'
if (-not $ToolsDir) { $ToolsDir = $AppDir }
$age = Join-Path $ToolsDir 'age.exe'
$ageKeygen = Join-Path $ToolsDir 'age-keygen.exe'
$masterFile = Join-Path $ToolsDir 'backup-master-key.txt'
$pgBin = Join-Path $AppDir 'pgsql\bin'
$configDir = Join-Path $AppDir 'backend\config'
$recipientFile = Join-Path $configDir 'backup-recipient.txt'
$boxKeyFile = Join-Path $configDir 'backup-box-key.age'
$uploads = Join-Path $env:ProgramData 'Vyaptek\HMS\uploads'
# Before OP3 the backend wrote uploads here; a box still on such a release has them only here.
$oldUploads = 'C:\data\uploads'
$statusFile = Join-Path $BackupRoot 'last-backup.txt'
$taskName = 'Vyaptek HMS Backup'

function Write-Event([string]$type, [int]$id, [string]$text) {
  & eventcreate /T $type /ID $id /L APPLICATION /SO VyaptekHMS /D $text | Out-Null
}

if ($Schedule) {
  $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -AppDir `"$AppDir`""
  $trigger = New-ScheduledTaskTrigger -Daily -At '01:30'
  $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 4) `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
  $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
  Register-ScheduledTask -TaskName $taskName -TaskPath '\Vyaptek\' -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal -Force | Out-Null
  "Scheduled '$taskName' every night at 01:30."
  exit 0
}

# cmd.exe runs the pipe, so binary data never passes through PowerShell (which would re-encode it).
# Secrets go in through the environment, never on the command line. Returns the exit code and stderr.
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

# The first part of a pipe fails silently (cmd reports only the last command's exit code), so it
# leaves a marker on stderr instead.
function Get-PipeFailure($result, [string]$what) {
  if ($result.Error -match 'HMS_PIPE_SOURCE_FAILED') { return "$what failed: $($result.Error -replace 'HMS_PIPE_SOURCE_FAILED', '')" }
  if ($result.Code -ne 0) { return "encrypting $what failed ($($result.Code)): $($result.Error)" }
  return $null
}

# The superuser password: this box's own (pg-superuser.secret, OP1); on a box set up before OP1, the
# backend's (it signed in as postgres); before plan 24 I3, "admin". The first that signs in.
function Get-SuperuserPassword {
  $candidates = @()
  $secret = Join-Path $configDir 'pg-superuser.secret'
  if (Test-Path $secret) { $candidates += (Get-Content -Raw $secret).Trim() }
  $props = Join-Path $configDir 'application.properties'
  if (Test-Path $props) {
    $lines = Get-Content $props
    $user = ($lines | Where-Object { $_ -like 'spring.datasource.username=*' } | Select-Object -First 1) -replace '^[^=]*=', ''
    if (@('', 'postgres') -contains $user.Trim()) {
      $pw = ($lines | Where-Object { $_ -like 'spring.datasource.password=*' } | Select-Object -First 1) -replace '^[^=]*=', ''
      if ($pw) { $candidates += $pw.Trim() }
    }
  }
  $candidates += 'admin'
  foreach ($pw in $candidates) {
    $r = Invoke-Pipe "`"$pgBin\psql.exe`" -h 127.0.0.1 -p 5432 -U postgres -d hospital_erp -w -At -c `"select 1`" >nul" @{ PGPASSWORD = $pw }
    if ($r.Code -eq 0) { return $pw }
  }
  throw 'cannot sign in to PostgreSQL as the superuser. Is the postgresql-x64-18 service running?'
}

# This computer's key pair, made once (and again after a restore). The private half goes from
# age-keygen straight into age, encrypted to Vyaptek; age-keygen prints the public half on stderr.
function Initialize-BoxKey {
  if ((Test-Path $recipientFile) -and (Test-Path $boxKeyFile)) { return }
  $master = @(Get-Content $masterFile -ErrorAction SilentlyContinue | Where-Object { $_ -match '^age1[0-9a-z]+$' })
  if ($master.Count -eq 0) {
    throw "Vyaptek's backup key is missing from $masterFile, so nothing can be encrypted. Install an HMS release that has it."
  }
  $pending = "$boxKeyFile.new"
  Remove-Item $pending -ErrorAction SilentlyContinue
  $r = Invoke-Pipe "`"$ageKeygen`" | `"$age`" -R `"$masterFile`" -o `"$pending`""
  $public = [regex]::Match($r.Error, 'age1[0-9a-z]+').Value
  if ($r.Code -ne 0 -or -not $public -or -not (Test-Path $pending)) {
    Remove-Item $pending -ErrorAction SilentlyContinue
    throw "could not make this computer's backup key: $($r.Error)"
  }
  Move-Item -Force $pending $boxKeyFile
  Set-Content -Path $recipientFile -Encoding ASCII -Value $public
}

# Administrators and SYSTEM only: the sets are encrypted, but their names and sizes are still nobody
# else's business.
function Protect-BackupRoot {
  New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null
  icacls $BackupRoot /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "icacls failed on $BackupRoot" }
}

# Set folders are named <yyyy-MM-dd_HHmmss>-<reason>; a set still being written ends in .partial.
function Remove-OldSets([string]$kind, [int]$keep) {
  Get-ChildItem $BackupRoot -Directory | Where-Object { $_.Name -match "^\d{4}-\d{2}-\d{2}_\d{6}-$kind$" } |
    Sort-Object Name -Descending | Select-Object -Skip $keep | Remove-Item -Recurse -Force
}

function Get-InstalledHmsVersion {
  $key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{010389d7-9c59-4047-b368-0da2344ea258}_is1'
  try { return (Get-ItemProperty $key -ErrorAction Stop).DisplayVersion } catch { return 'unknown' }
}

$set = $null
try {
  foreach ($tool in @($age, $ageKeygen, "$pgBin\pg_dump.exe", "$pgBin\psql.exe")) {
    if (-not (Test-Path $tool)) { throw "$tool is missing" }
  }
  Protect-BackupRoot
  Initialize-BoxKey
  $password = Get-SuperuserPassword
  $sourceUploads = if (Test-Path $uploads) { $uploads } elseif (Test-Path $oldUploads) { $oldUploads } else { $null }

  # Make room first: the set about to be written counts towards the number kept.
  $keep = if ($Reason -eq 'nightly') { $KeepNightly } else { $KeepOther }
  Remove-OldSets $Reason ([Math]::Max($keep - 1, 0))
  Get-ChildItem $BackupRoot -Directory -Filter '*.partial' | Remove-Item -Recurse -Force

  # Enough space for the database and the files uncompressed, which a set never exceeds.
  $r =Invoke-Pipe "`"$pgBin\psql.exe`" -h 127.0.0.1 -p 5432 -U postgres -d hospital_erp -w -At -c `"select pg_database_size('hospital_erp')`" 1>&2" @{ PGPASSWORD = $password }
  if ($r.Code -ne 0) { throw "could not read the database size: $($r.Error)" }
  $dbBytes = [int64]($r.Error -replace '\D', '')
  $fileBytes = if ($sourceUploads) { [int64](Get-ChildItem $sourceUploads -Recurse -File -Force | Measure-Object Length -Sum).Sum } else { 0 }
  $free = (Get-PSDrive ((Resolve-Path $BackupRoot).Path.Substring(0, 1))).Free
  if ($free -lt ($dbBytes + $fileBytes)) {
    throw ("not enough disk space: {0:N0} MB free, up to {1:N0} MB needed" -f ($free / 1MB), (($dbBytes + $fileBytes) / 1MB))
  }

  $name = (Get-Date -Format 'yyyy-MM-dd_HHmmss') + "-$Reason"
  $set = Join-Path $BackupRoot "$name.partial"
  New-Item -ItemType Directory -Path $set | Out-Null
  Copy-Item $boxKeyFile (Join-Path $set 'box-key.age')

  $dumpOut = Join-Path $set 'database.dump.age'
  $r = Invoke-Pipe ("(`"$pgBin\pg_dump.exe`" -h 127.0.0.1 -p 5432 -U postgres -w -Fc -d hospital_erp || (echo HMS_PIPE_SOURCE_FAILED 1>&2)) | " +
      "`"$age`" -R `"$recipientFile`" -o `"$dumpOut`"") @{ PGPASSWORD = $password }
  $failure = Get-PipeFailure $r 'pg_dump'
  if ($failure) { throw $failure }

  $files = @('box-key.age', 'database.dump.age')
  if ($sourceUploads) {
    $tarOut = Join-Path $set 'uploads.tar.age'
    $r = Invoke-Pipe ("(`"$env:SystemRoot\System32\tar.exe`" -cf - -C `"$sourceUploads`" . || (echo HMS_PIPE_SOURCE_FAILED 1>&2)) | " +
        "`"$age`" -R `"$recipientFile`" -o `"$tarOut`"")
    $failure = Get-PipeFailure $r 'tar of the uploaded files'
    if ($failure) { throw $failure }
    $files += 'uploads.tar.age'
  }

  $pgVersion = (& "$pgBin\postgres.exe" -V) -replace '^.*\) ', ''
  $manifest = @(
    "created=$((Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz'))",
    "reason=$Reason",
    "computer=$env:COMPUTERNAME",
    "installation=$((Get-Content (Join-Path $configDir 'license-activated') -ErrorAction SilentlyContinue | Select-Object -First 1))",
    "hms-version=$(Get-InstalledHmsVersion)",
    "postgresql=$pgVersion",
    "recipient=$((Get-Content $recipientFile).Trim())",
    "uploads-from=$sourceUploads"
  )
  foreach ($f in $files) {
    $item = Get-Item (Join-Path $set $f)
    $manifest += "file=$f $($item.Length) $((Get-FileHash $item.FullName -Algorithm SHA256).Hash.ToLower())"
  }
  Set-Content -Path (Join-Path $set 'backup.txt') -Encoding ASCII -Value $manifest
  $final = Join-Path $BackupRoot $name
  Rename-Item $set $name
  $set = $null

  $size = (Get-ChildItem $final -File | Measure-Object Length -Sum).Sum
  $text = "HMS backup written: $final ({0:N0} MB)." -f ($size / 1MB)
  Set-Content -Path $statusFile -Encoding ASCII -Value @("status=OK", "time=$((Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz'))", "set=$final")
  Write-Event INFORMATION 811 $text
  $text
  exit 0
} catch {
  if ($set -and (Test-Path $set)) { Remove-Item -Recurse -Force $set -ErrorAction SilentlyContinue }
  $text = "HMS backup ($Reason) FAILED: $($_.Exception.Message)"
  try {
    New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null
    Set-Content -Path $statusFile -Encoding ASCII -Value @("status=FAILED", "time=$((Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz'))", "message=$($_.Exception.Message)")
  } catch { }
  Write-Event ERROR 812 $text
  $text
  exit 1
}
