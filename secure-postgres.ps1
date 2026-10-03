<#
  Keeps PostgreSQL to this computer (backend plan 24 section 11, OP7). Run by the installer on every
  install and upgrade, after write-secrets.ps1 (it signs in as the superuser, whose password is in
  config\pg-superuser.secret) and before setup-database.bat.

  - listen_addresses = 'localhost' (ALTER SYSTEM, so PostgreSQL's own postgresql.conf is left alone).
    The EDB installer leaves '*', which relied on the firewall alone. A change needs a restart, done here.
  - pg_hba.conf: loopback only, scram-sha-256 only. Rewritten when it differs, then reloaded.
  - A superuser password still stored as md5 is stored again as SCRAM first, or the new pg_hba.conf
    would refuse it. The backend's two accounts get their passwords again from setup-database.bat.
  - Inbound firewall rules that open port 5432 are removed: nothing outside this computer may reach the
    database any more, and HMS-DB-Support.bat is for pgAdmin on this computer.

  Exit code 0 when PostgreSQL ends up local-only and running; 1 otherwise (the installer logs it; the
  database update after it then reports any real problem).
#>
param(
  [Parameter(Mandatory = $true)][string]$ConfigDir,
  [Parameter(Mandatory = $true)][string]$PgBin,
  [string]$ServiceName = 'postgresql-x64-18',
  # Rewritten on every run; never holds a password.
  [string]$LogFile,
  # For a test outside Windows: no service restart and no firewall.
  [switch]$NoService
)
$ErrorActionPreference = 'Stop'
$secretFile = Join-Path $ConfigDir 'pg-superuser.secret'
$exe = if ($IsLinux -or $IsMacOS) { '' } else { '.exe' }
$psql = Join-Path $PgBin "psql$exe"
$isReady = Join-Path $PgBin "pg_isready$exe"

function Log([string]$text) {
  Write-Output $text
  if ($LogFile) { Add-Content -Path $LogFile -Encoding ASCII -Value ((Get-Date -Format s) + ' ' + $text) }
}
if ($LogFile) {
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LogFile) | Out-Null
  Set-Content -Path $LogFile -Encoding ASCII -Value @()
}

$hba = @(
  '# Written by the Vyaptek HMS installer (backend plan 24 section 11, OP7) on every install and upgrade;',
  '# changes made here are replaced. PostgreSQL listens on this computer only, and every account signs',
  '# in with a SCRAM password.',
  '# TYPE  DATABASE  USER  ADDRESS       METHOD',
  'host    all       all   127.0.0.1/32  scram-sha-256',
  'host    all       all   ::1/128       scram-sha-256'
)

# SQL through stdin, so the password is never on a command line. Returns psql's output lines.
function Invoke-Superuser([string]$sql) {
  $env:PGPASSWORD = $script:superPw
  $ErrorActionPreference = 'Continue'
  try {
    $out = $sql | & $psql -h 127.0.0.1 -p 5432 -U postgres -d postgres -v ON_ERROR_STOP=1 -q -At -w 2>&1
    if ($LASTEXITCODE -ne 0) { throw "PostgreSQL refused: $($out -join ' ')" }
    return $out
  } finally {
    Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue
    $ErrorActionPreference = 'Stop'
  }
}

function Wait-Ready {
  for ($i = 0; $i -lt 30; $i++) {
    & $isReady -h 127.0.0.1 -p 5432 -q
    if ($LASTEXITCODE -eq 0) { return }
    Start-Sleep -Seconds 2
  }
  throw 'PostgreSQL did not come back within 60 seconds.'
}

try {
  if (-not (Test-Path $secretFile)) { throw "$secretFile is missing." }
  $script:superPw = (Get-Content -Raw $secretFile).Trim()
  Wait-Ready

  if ((Invoke-Superuser "SELECT rolpassword LIKE 'md5%' FROM pg_authid WHERE rolname = 'postgres';") -contains 't') {
    Invoke-Superuser "SET password_encryption = 'scram-sha-256'; ALTER ROLE postgres PASSWORD '$($script:superPw)';" | Out-Null
    Log 'The superuser password is now stored as SCRAM.'
  }

  $hbaFile = @(Invoke-Superuser 'SHOW hba_file;')[0]
  $current = if (Test-Path $hbaFile) { @(Get-Content $hbaFile) } else { @() }
  $reload = $false
  if (($current -join "`n") -ne ($hba -join "`n")) {
    Set-Content -Path $hbaFile -Encoding ASCII -Value $hba
    $reload = $true
    Log "Rewrote $hbaFile (loopback, scram-sha-256)."
  }

  $restart = $false
  if (@(Invoke-Superuser 'SHOW listen_addresses;')[0] -ne 'localhost') {
    Invoke-Superuser "ALTER SYSTEM SET listen_addresses = 'localhost';" | Out-Null
    $restart = $true
    Log "listen_addresses set to 'localhost'."
  }

  if ($restart -and -not $NoService) {
    # -Force: the backend depends on PostgreSQL; the installer has stopped it already.
    Restart-Service -Name $ServiceName -Force
    Wait-Ready
    Log 'PostgreSQL restarted.'
  } elseif ($reload) {
    Invoke-Superuser 'SELECT pg_reload_conf();' | Out-Null
  }

  if (-not $NoService) {
    $rules = @(Get-NetFirewallPortFilter -Protocol TCP -ErrorAction SilentlyContinue |
        Where-Object { @($_.LocalPort) -contains '5432' } |
        Get-NetFirewallRule -ErrorAction SilentlyContinue |
        Where-Object { $_.Direction -eq 'Inbound' -and $_.Action -eq 'Allow' })
    foreach ($rule in $rules) {
      Remove-NetFirewallRule -Name $rule.Name
      Log "Removed the firewall rule '$($rule.DisplayName)' (port 5432)."
    }
  }
  Log 'PostgreSQL is local-only.'
  exit 0
} catch {
  Log "Could not make PostgreSQL local-only: $($_.Exception.Message)"
  exit 1
}
