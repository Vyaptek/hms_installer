<#
  Writes the box's secret file, backend\config\application.properties (backend plan 24, C2 and C6).
  Spring Boot reads ./config/application.properties from the service's working directory
  (hms-service.xml sets it) ahead of the settings inside hms.jar.

  - security.jwt.secret: 48 random bytes. Created once and kept by every later run, so an upgrade does
    not log everyone out. Without it the backend refuses to start.
  - hms.bootstrap.admin-password: written only when -AdminPasswordFile holds a password (the wizard
    asks for one when the database is new). The backend applies it once, to USR0001, while that account
    still has the seeded password. Any copy left by an earlier run is dropped, because by then it is
    only a plaintext copy.

  Only SYSTEM (the service account) and Administrators can read the folder.

  Also run by hand to give an already-installed box its own secret: see plan 24 §10 in the backend repo.
#>
param(
  [Parameter(Mandatory = $true)][string]$ConfigDir,
  [string]$AdminPasswordFile
)
$ErrorActionPreference = 'Stop'
$file = Join-Path $ConfigDir 'application.properties'

New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
# Lock the folder before any secret is written into it. SIDs, not names: "Administrators" is localised
# on non-English Windows. /T also re-locks a file an earlier run left.
icacls $ConfigDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' /T | Out-Null
if ($LASTEXITCODE -ne 0) { throw "icacls failed on $ConfigDir" }

$lines = @()
if (Test-Path $file) {
  $lines = @(Get-Content $file | Where-Object { $_ -notmatch '^hms\.bootstrap\.admin-password=' })
}
if (-not ($lines -match '^security\.jwt\.secret=')) {
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
Set-Content -Path $file -Encoding ASCII -Value $lines
