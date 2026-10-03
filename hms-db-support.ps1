<#
  Break-glass database access for Vyaptek support (backend plan 24 section 11, OP8). Run through
  HMS-DB-Support.bat, which asks for administrator rights: only Administrators can read the PostgreSQL
  superuser's password (config\pg-superuser.secret, OP1).

  (no switch)  Creates a login that works for 4 hours and shows its name and password, for pgAdmin on
               this computer (127.0.0.1, port 5432, database hospital_erp). It can read and change
               hospital data, as the backend can (hospital_erp_user), and cannot change the schema.
  -Superuser   The same login with full rights, for rare repairs. Logged as such.
  -End         Removes every support login now.

  Every run, and every installer run (-CleanupOnly), first removes the logins whose 4 hours are over.
  A login past its time can no longer sign in anyway (VALID UNTIL); removing it is housekeeping.
  Each login made or removed is written to the Windows Application event log (source VyaptekHMS).
#>
param(
  [string]$AppDir = (Split-Path -Parent $MyInvocation.MyCommand.Path),
  [switch]$Superuser,
  [switch]$End,
  [switch]$CleanupOnly,
  [int]$Hours = 4
)
$ErrorActionPreference = 'Stop'
$psql = Join-Path $AppDir 'pgsql\bin\psql.exe'
$secretFile = Join-Path $AppDir 'backend\config\pg-superuser.secret'
$prefix = 'hms_support_'

function Write-Event([string]$type, [string]$text) {
  # eventcreate needs no event source registered beforehand. IDs: 801 created, 802 removed.
  $id = if ($text -like 'Removed*') { 802 } else { 801 }
  & eventcreate /T $type /ID $id /L APPLICATION /SO VyaptekHMS /D $text | Out-Null
}

# SQL through stdin, so no password is ever on a command line. Returns psql's output lines.
function Invoke-Superuser([string]$sql) {
  if (-not (Test-Path $secretFile)) { throw "$secretFile is missing. Run the HMS installer again." }
  $env:PGPASSWORD = (Get-Content -Raw $secretFile).Trim()
  $ErrorActionPreference = 'Continue'
  try {
    $out = $sql | & $psql -h 127.0.0.1 -p 5432 -U postgres -d hospital_erp -v ON_ERROR_STOP=1 -q -At -w 2>&1
    if ($LASTEXITCODE -ne 0) { throw "PostgreSQL refused: $($out -join ' ')" }
    return $out
  } finally {
    Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue
    $ErrorActionPreference = 'Stop'
  }
}

# A login can own objects (a table made in pgAdmin), which DROP ROLE refuses; hand them to postgres.
function Remove-Logins([string]$where) {
  $names = @(Invoke-Superuser "SELECT rolname FROM pg_roles WHERE rolname LIKE '$prefix%' AND ($where);" |
      Where-Object { $_ -match "^$prefix[a-z0-9_]+$" })
  foreach ($name in $names) {
    Invoke-Superuser "REASSIGN OWNED BY $name TO postgres; DROP OWNED BY $name; DROP ROLE $name;" | Out-Null
    Write-Event INFORMATION "Removed the HMS database support login $name."
  }
  return $names.Count
}

$expired = Remove-Logins 'rolvaliduntil < now()'
if ($CleanupOnly) {
  "Removed $expired expired support login(s)."
  exit 0
}
if ($End) {
  $n = Remove-Logins 'true'
  "Removed $n support login(s)."
  exit 0
}

$name = $prefix + (Get-Date -Format 'yyyyMMdd_HHmmss')
$buf = New-Object byte[] 18
$rng = [Security.Cryptography.RandomNumberGenerator]::Create()
$rng.GetBytes($buf)
$rng.Dispose()
$password = -join ($buf | ForEach-Object { $_.ToString('x2') })
$rights = if ($Superuser) { 'SUPERUSER' } else { 'NOSUPERUSER IN ROLE hospital_erp_user' }
Invoke-Superuser "CREATE ROLE $name LOGIN $rights PASSWORD '$password' VALID UNTIL '$((Get-Date).ToUniversalTime().AddHours($Hours).ToString('yyyy-MM-dd HH:mm:ss'))+00';" | Out-Null
$kind = if ($Superuser) { 'SUPERUSER (full rights)' } else { 'read and change hospital data' }
Write-Event WARNING "Created the HMS database support login $name ($kind) for $Hours hours, by $env:USERDOMAIN\$env:USERNAME."

''
"Support login for pgAdmin on this computer, valid for $Hours hours:"
"  Host:      127.0.0.1    Port: 5432    Database: hospital_erp"
"  Username:  $name"
"  Password:  $password"
"  Rights:    $kind"
''
'Run HMS-DB-Support.bat -End when the work is done.'
