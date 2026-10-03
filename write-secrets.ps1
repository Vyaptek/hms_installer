<#
  Writes the box's secret file, backend\config\application.properties (backend plan 24, C2, C6 and I3).
  Spring Boot reads ./config/application.properties from the service's working directory
  (hms-service.xml sets it) ahead of the settings inside hms.jar.

  - security.jwt.secret: 48 random bytes. Created once and kept by every later run, so an upgrade does
    not log everyone out. Without it the backend refuses to start.
  - hms.bootstrap.admin-password: written only when -AdminPasswordFile holds a password (the wizard
    asks for one when the database is new). The backend applies it once, to USR0001, while that account
    still has the seeded password. Any copy left by an earlier run is dropped, because by then it is
    only a plaintext copy.
  - hms.bootstrap.admin-username: the email the hospital chose to sign in with (-AdminEmailFile, asked
    with the password since 2026-10-03). Applied with the password and under the same rule; an earlier
    run's copy is dropped the same way.
  - pg-superuser.secret (with -PgBin): the PostgreSQL superuser's password, changed from the installer's
    old fixed one to a random one, once, and again with -NewDatabase (this run created the database).
    Administrators only. A box set up before plan 24 OP1 had it as spring.datasource.password; it is
    moved here. If the change fails the script fails: there is no fallback password (OP8).
  - spring.datasource.* and reporting.datasource.* (with -PgBin): the backend's own accounts,
    hospital_erp_user and hms_reporting, with random passwords created once. setup-database.bat sets
    them in the database.
  - spring.data.redis.password: with -GarnetConf, a random password for the cache server (Garnet), created
    once, and Garnet's whole config written with it. Restart VyaptekGarnet afterwards (the installer
    re-registers the service right after this script).

  Only SYSTEM (the service account) and Administrators can read the folder.

  Also run by hand on an already-installed box: see plan 24 §10 in the backend repo.
#>
param(
  [Parameter(Mandatory = $true)][string]$ConfigDir,
  [string]$AdminPasswordFile,
  [string]$AdminEmailFile,
  [string]$PgBin,
  [switch]$NewDatabase,
  [string]$GarnetConf
)
$ErrorActionPreference = 'Stop'
$file = Join-Path $ConfigDir 'application.properties'

# Letters and digits only, so the value needs no escaping in a .properties file, a batch file, SQL or
# Garnet's JSON config.
function New-Secret([int]$bytes) {
  $buf = New-Object byte[] $bytes
  $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
  $rng.GetBytes($buf)
  $rng.Dispose()
  return -join ($buf | ForEach-Object { $_.ToString('x2') })
}

function Get-Prop([string[]]$lines, [string]$key) {
  $hit = $lines | Where-Object { $_.StartsWith("$key=") } | Select-Object -First 1
  if ($hit) { return $hit.Substring($key.Length + 1) } else { return $null }
}

function Set-Prop([string[]]$lines, [string]$key, [string]$value) {
  return @($lines | Where-Object { -not $_.StartsWith("$key=") }) + "$key=$value"
}

New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
# Lock the folder before any secret is written into it. SIDs, not names: "Administrators" is localised
# on non-English Windows. The folder only, not /T: on a file that already existed, /inheritance:r
# stripped its inherited entries and the (OI)(CI) grants gave it none back, so an upgrade left
# application.properties readable by no one and the service failed with "Access is denied"
# (2026-10-02). Files an earlier run left are reset to inherit the folder's entries instead; taking
# ownership first lets that repair a file already emptied that way.
icacls $ConfigDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw "icacls failed on $ConfigDir" }
if (Get-ChildItem -Force -File $ConfigDir) {
  takeown /f (Join-Path $ConfigDir '*') /a | Out-Null
  icacls (Join-Path $ConfigDir '*') /reset | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "icacls failed on the files in $ConfigDir" }
}

$lines = @()
if (Test-Path $file) {
  $lines = @(Get-Content $file | Where-Object { $_ -notmatch '^hms\.bootstrap\.admin-(password|username)=' })
}
if (-not (Get-Prop $lines 'security.jwt.secret')) {
  $bytes = New-Object byte[] 48
  $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
  $rng.GetBytes($bytes)
  $rng.Dispose()
  $lines += 'security.jwt.secret=' + [Convert]::ToBase64String($bytes)
}
if ($AdminPasswordFile -and (Test-Path $AdminPasswordFile)) {
  $raw = Get-Content -Raw $AdminPasswordFile   # $null for an empty file
  $pw = if ($raw) { $raw.Trim() } else { '' }
  Remove-Item -Force $AdminPasswordFile
  # The wizard allows printable ASCII without spaces only, so '\' is the one character a
  # .properties value needs escaped.
  if ($pw) { $lines += 'hms.bootstrap.admin-password=' + $pw.Replace('\', '\\') }
}
if ($AdminEmailFile -and (Test-Path $AdminEmailFile)) {
  $raw = Get-Content -Raw $AdminEmailFile
  $email = if ($raw) { $raw.Trim() } else { '' }
  Remove-Item -Force $AdminEmailFile
  # The wizard allows printable ASCII without spaces only, like the password.
  if ($email) { $lines += 'hms.bootstrap.admin-username=' + $email.Replace('\', '\\') }
}

# I3: the PostgreSQL superuser had the password "admin" on every box. OP1 (plan 24 §11): its password is
# kept in pg-superuser.secret, for the installer and the support scripts; the backend never uses it.
# Before OP1 the backend signed in as the superuser, so its password was spring.datasource.password.
$superFile = Join-Path $ConfigDir 'pg-superuser.secret'

# Administrators only, re-applied every run (the reset at the top of this script gave it the folder's
# entries). Until the backend runs as its own service account (OP2) SYSTEM still reads it: LocalSystem
# is a member of Administrators.
function Save-Superuser([string]$pw) {
  Set-Content -Path $superFile -Encoding ASCII -Value $pw
  Protect-Superuser
}
function Protect-Superuser {
  icacls $superFile /inheritance:r /grant:r '*S-1-5-32-544:F' | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "icacls failed on $superFile" }
}

if ($PgBin) {
  $current = $null
  if (Test-Path $superFile) {
    $current = (Get-Content -Raw $superFile).Trim()
  } elseif (@($null, '', 'postgres') -contains (Get-Prop $lines 'spring.datasource.username')) {
    $current = Get-Prop $lines 'spring.datasource.password'
    # Moved out before the backend's own password takes its place below.
    if ($current) { Save-Superuser $current }
  }
  if ($NewDatabase -or -not $current) {
    $new = New-Secret 24
    $psql = Join-Path $PgBin 'psql.exe'
    $changed = $false
    if (Test-Path $psql) {
      # Windows PowerShell turns a native command's stderr into terminating errors under 'Stop'.
      $ErrorActionPreference = 'Continue'
      # The password the cluster has now: this box's own if a reinstall kept the cluster, else the
      # installer's old fixed one.
      foreach ($candidate in @($current, 'admin') | Where-Object { $_ }) {
        $env:PGPASSWORD = $candidate
        # Through stdin, so the new password never appears on a command line.
        "ALTER ROLE postgres PASSWORD '$new';" | & $psql -h 127.0.0.1 -p 5432 -U postgres -d postgres -v ON_ERROR_STOP=1 -q -w 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $changed = $true; break }
      }
      Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue
      $ErrorActionPreference = 'Stop'
    }
    # OP8: no fallback password any more, so fail, and the installer offers Retry.
    if (-not $changed) { throw 'The PostgreSQL superuser password could not be set. Is the postgresql-x64-18 service running?' }
    # Saved at once: the database already has the new password, so nothing below may lose it.
    Save-Superuser $new
  } elseif (Test-Path $superFile) {
    Protect-Superuser
  }

  # The backend's own accounts (OP1). setup-database.bat gives them these passwords in the database
  # on every run, so a new password here needs nothing else.
  foreach ($account in @(
      @{ Prefix = 'spring.datasource'; User = 'hospital_erp_user' },
      @{ Prefix = 'reporting.datasource'; User = 'hms_reporting' })) {
    if ((Get-Prop $lines "$($account.Prefix).username") -ne $account.User -or -not (Get-Prop $lines "$($account.Prefix).password")) {
      $lines = Set-Prop $lines "$($account.Prefix).username" $account.User
      $lines = Set-Prop $lines "$($account.Prefix).password" (New-Secret 24)
    }
  }
}

# I3: the cache server had no password. Garnet (which replaced the archived Windows Redis port) is
# written a whole config every run: 127.0.0.1 only, this password, memory limits. The password keeps
# its old name in application.properties, because the backend talks to Garnet as to Redis.
if ($GarnetConf) {
  $cachePw = Get-Prop $lines 'spring.data.redis.password'
  if (-not $cachePw) {
    $cachePw = New-Secret 24
    $lines = Set-Prop $lines 'spring.data.redis.password' $cachePw
  }
  # One setting per line: hms.iss reads the Password line back to check it matches.
  # Garnet ignores a key it does not know without a word, so the names are checked against 2.2.0's own
  # defaults (2.2.0 calls the index IndexMemorySize, not IndexSize).
  # LogMemorySize caps memory (Garnet's default is 16g); nothing is written to disk, as with the old
  # Redis ("save" off), so a restart signs everyone out. Expired keys are swept every 5 minutes
  # (Garnet's default only drops them when read).
  $conf = @(
    '{',
    '  "Address": "127.0.0.1",',
    '  "Port": 6379,',
    '  "AuthenticationMode": "Password",',
    ('  "Password": "' + $cachePw + '",'),
    '  "LogMemorySize": "512m",',
    '  "IndexMemorySize": "64m",',
    '  "ExpiredKeyDeletionScanFrequencySecs": 300,',
    '  "EnableLua": false',
    '}'
  )
  Set-Content -Path $GarnetConf -Encoding ASCII -Value $conf
  # Readable by SYSTEM, Administrators and Network Service (the account VyaptekGarnet runs as), not by
  # other users.
  icacls $GarnetConf /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' '*S-1-5-20:R' | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "icacls failed on $GarnetConf" }
}

Set-Content -Path $file -Encoding ASCII -Value $lines
