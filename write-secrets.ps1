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
  - spring.datasource.password (and the reporting pool's): with -PgBin, the PostgreSQL superuser's
    password is changed from the installer's old fixed one to a random one, once. With -NewDatabase
    (this run created the database) it is changed again. If the change fails the file keeps what it
    had, and the backend falls back to DB_PASSWORD in hms-service.xml.
  - spring.data.redis.password: with -RedisConf, a random Redis password, created once, written into
    the Redis config as requirepass. Restart Redis afterwards (the installer reinstalls the service
    right after this script).

  Only SYSTEM (the service account) and Administrators can read the folder.

  Also run by hand on an already-installed box: see plan 24 §10 in the backend repo.
#>
param(
  [Parameter(Mandatory = $true)][string]$ConfigDir,
  [string]$AdminPasswordFile,
  [string]$AdminEmailFile,
  [string]$PgBin,
  [switch]$NewDatabase,
  [string]$RedisConf
)
$ErrorActionPreference = 'Stop'
$file = Join-Path $ConfigDir 'application.properties'

# Letters and digits only, so the value needs no escaping in a .properties file, a batch file, SQL or
# the Redis config.
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

# I3: the PostgreSQL superuser had the password "admin" on every box.
if ($PgBin) {
  $current = Get-Prop $lines 'spring.datasource.password'
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
    if ($changed) {
      $lines = Set-Prop $lines 'spring.datasource.password' $new
      $lines = Set-Prop $lines 'reporting.datasource.password' $new
      # Saved at once: the database already has the new password, so nothing below may lose it.
      Set-Content -Path $file -Encoding ASCII -Value $lines
    } else {
      Write-Warning 'The PostgreSQL password was not changed; the backend keeps using the one in hms-service.xml.'
    }
  }
}

# I3: Redis had no password. It listens on 127.0.0.1 only; this keeps other local accounts out.
if ($RedisConf) {
  $redisPw = Get-Prop $lines 'spring.data.redis.password'
  if (-not $redisPw) {
    $redisPw = New-Secret 24
    $lines = Set-Prop $lines 'spring.data.redis.password' $redisPw
  }
  # The installer copies a fresh Redis config on every run, so the line is added every run.
  $conf = @(Get-Content $RedisConf | Where-Object { $_ -notmatch '^\s*requirepass\s' }) + "requirepass $redisPw"
  Set-Content -Path $RedisConf -Encoding ASCII -Value $conf
  # Readable by the accounts a Windows service runs as (SYSTEM, LocalService, NetworkService) and
  # Administrators, not by other users.
  icacls $RedisConf /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' '*S-1-5-19:R' '*S-1-5-20:R' | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "icacls failed on $RedisConf" }
}

Set-Content -Path $file -Encoding ASCII -Value $lines
