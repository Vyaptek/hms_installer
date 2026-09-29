<#
  The installer's product-key steps (backend optimization/26_PRODUCT_KEY_LICENSING.md, phase 7).

  Three modes, each writing key=value lines to -ResultFile for the installer to read:

  -Mode Check     Asks Vyaptek's license server whether the product key in -KeyFile is valid and
                  whether this build (-ReleaseDate, yyyy-MM-dd) may be installed under it. No side
                  effects on either side. Result lines: status, customer, licenseId, abdm, seats,
                  message. status is OK, INVALID, NOT_ENTITLED, OFFLINE or ERROR.
  -Mode Upgrade   The upgrade guard, run before any file is replaced: may this build run on the
                  installation named in -InstallIdFile (config\license-activated, which the backend
                  writes when it activates a key)? status is OK, NOT_ENTITLED, OFFLINE or ERROR.
  -Mode RequireKey  The key was skipped: sets hms.license.enforce=true in -ConfigDir\application.properties,
                  so HMS opens read-only (records viewable and printable) until an administrator enters
                  the key on the License page. Skipping the key therefore never means running unlicensed.
  -Mode Install   Copies the key from -KeyFile into -ConfigDir\license.key (the folder write-secrets.ps1
                  locked to SYSTEM and Administrators, so the copy inherits that) and deletes -KeyFile.
                  The backend activates it within a minute of starting, then deletes it.

  The key travels in files, never on a command line, where other users could read it. Exit codes:
  0 OK, 2 refused (bad key, not entitled), 3 unreachable, 1 anything else.
#>
param(
  [Parameter(Mandatory = $true)][ValidateSet('Check', 'Upgrade', 'Install', 'RequireKey')][string]$Mode,
  [string]$ServerUrl = 'https://api.vyaptek.com',
  [string]$KeyFile,
  [string]$InstallIdFile,
  [string]$ConfigDir,
  [string]$ReleaseDate = '',
  [string]$AppVersion = '',
  [string]$ResultFile
)
$ErrorActionPreference = 'Stop'

function Write-Result([int]$exitCode, [hashtable]$fields) {
  # A comment first: Windows PowerShell writes a UTF-8 byte-order mark, which would otherwise hide the
  # first field from the installer's line matching.
  $lines = @('# validate-license.ps1') + @(foreach ($key in $fields.Keys) {
    # One value per line: line breaks in a server message would start a new field.
    "$key=" + ([string]$fields[$key] -replace '[\r\n]+', ' ')
  })
  if ($ResultFile) { Set-Content -Path $ResultFile -Encoding UTF8 -Value $lines }
  $lines | ForEach-Object { Write-Host $_ }
  exit $exitCode
}

function Read-Key {
  if (-not $KeyFile -or -not (Test-Path $KeyFile)) { Write-Result 1 @{ status = 'ERROR'; message = 'No product key was given.' } }
  $raw = Get-Content -Raw $KeyFile
  if (-not $raw -or -not $raw.Trim()) { Write-Result 1 @{ status = 'ERROR'; message = 'No product key was given.' } }
  return $raw.Trim()
}

function Get-Server {
  $server = $ServerUrl.TrimEnd('/')
  # Only HTTPS, so the key cannot be read on the way. Plain HTTP to this machine is allowed for testing.
  if (-not ($server.StartsWith('https://') -or $server -match '^http://(localhost|127\.0\.0\.1)(:\d+)?$')) {
    Write-Result 1 @{ status = 'ERROR'; message = "The license server address must start with https:// ($ServerUrl)." }
  }
  return $server
}

function Invoke-Server([scriptblock]$call) {
  # Windows PowerShell 5.1 may not offer TLS 1.2 by default.
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  try {
    return & $call
  } catch {
    $status = $null
    if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
    if ($status -eq 429) {
      Write-Result 2 @{ status = 'INVALID'; message = 'Too many attempts from this network. Wait a minute and try again.' }
    }
    if ($status) { Write-Result 1 @{ status = 'ERROR'; message = "The license server answered HTTP $status. Send this message to Vyaptek." } }
    Write-Result 3 @{
      status  = 'OFFLINE'
      message = "Could not reach Vyaptek's license server ($($_.Exception.Message)). Connect this computer to the internet and try again."
    }
  }
}

switch ($Mode) {
  'Check' {
    $server = Get-Server
    $body = @{ productKey = (Read-Key); appVersion = $AppVersion; releaseDate = $ReleaseDate } | ConvertTo-Json -Compress
    $response = Invoke-Server { Invoke-RestMethod -Method Post -Uri "$server/license/v1/validate-key" -ContentType 'application/json' -Body $body -TimeoutSec 30 }
    $d = $response.data
    if (-not $d.valid) {
      Write-Result 2 @{ status = 'INVALID'; message = $(if ($d.reason) { $d.reason } else { 'This product key is not valid. Check it, or ask Vyaptek for a new one.' }) }
    }
    $fields = @{
      customer  = $d.customerName
      licenseId = $d.licenseId
      abdm      = $(if ($d.abdmIncluded) { 'true' } else { 'false' })
      seats     = $d.maxWorkstations
    }
    if (-not $d.entitledToBuild) {
      Write-Result 2 (@{ status = 'NOT_ENTITLED'; message = $d.reason } + $fields)
    }
    Write-Result 0 (@{ status = 'OK'; message = '' } + $fields)
  }
  'Upgrade' {
    if (-not $InstallIdFile -or -not (Test-Path $InstallIdFile)) {
      Write-Result 1 @{ status = 'ERROR'; message = 'This server has not activated a product key yet.' }
    }
    $installId = (Get-Content -Raw $InstallIdFile).Trim()
    $server = Get-Server
    $query = "installId=$([uri]::EscapeDataString($installId))&releaseDate=$([uri]::EscapeDataString($ReleaseDate))"
    $response = Invoke-Server { Invoke-RestMethod -Method Get -Uri "$server/license/v1/entitlement?$query" -TimeoutSec 30 }
    if ($response.data.entitled) { Write-Result 0 @{ status = 'OK'; message = '' } }
    Write-Result 2 @{ status = 'NOT_ENTITLED'; message = $(if ($response.data.reason) { $response.data.reason } else { 'This version is not covered by the license.' }) }
  }
  'RequireKey' {
    $file = Join-Path $ConfigDir 'application.properties'
    if (-not $ConfigDir -or -not (Test-Path $file)) { Write-Result 1 @{ status = 'ERROR'; message = "$file does not exist. Run write-secrets.ps1 first." } }
    $lines = @(Get-Content $file | Where-Object { -not $_.StartsWith('hms.license.enforce=') }) + 'hms.license.enforce=true'
    Set-Content -Path $file -Encoding ASCII -Value $lines
    Write-Result 0 @{ status = 'OK'; message = 'HMS opens read-only until an administrator enters the product key.' }
  }
  'Install' {
    if (-not $ConfigDir -or -not (Test-Path $ConfigDir)) { Write-Result 1 @{ status = 'ERROR'; message = "$ConfigDir does not exist. Run write-secrets.ps1 first." } }
    $key = Read-Key
    # A new file in the locked folder inherits its permissions; moving the temp file would carry the temp folder's.
    Set-Content -Path (Join-Path $ConfigDir 'license.key') -Encoding ASCII -Value $key -NoNewline
    Remove-Item -Force $KeyFile
    Write-Result 0 @{ status = 'OK'; message = 'The product key will be activated when HMS starts.' }
  }
}
