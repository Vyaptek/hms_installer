<#
  Connects this box to Vyaptek's ABDM relay (backend docs/ABDM_RELAY_SPEC.md §9.1, decided 2026-09-28),
  with either credential Vyaptek gives a hospital:

  - the hospital's product key (-ProductKeyFile), when its license includes ABDM (backend
    optimization/26_PRODUCT_KEY_LICENSING.md §9, 2026-09-29). The installer uses this, so the hospital
    types one key. Redeemed at {RelayUrl}/license/v1/abdm/enroll.
  - a one-time enrollment code (-CodeFile), which a Vyaptek operator creates on the relay (POST
    /api/relay/boxes/{boxId}/enrollment-code). Redeemed at {RelayUrl}/relay/v1/enroll.

  Either way, what comes back is written into backend\config\application.properties, the file
  write-secrets.ps1 locked to SYSTEM and Administrators:

  - the box id and its relay token (abdm.relay.pull.*), which the box uses to pull ABDM callbacks and
    to borrow ABDM sessions from the relay;
  - the ABDM environment: sandbox or production, the gateway and ABHA URLs, the consent-manager id,
    and the relay's bridge URL as the callback base.

  The ABDM client id and secret are never sent to the box: the relay keeps them and lends the box
  short-lived session tokens. Any abdm.client-id or abdm.client-secret line in the file is removed.
  If this box's token leaks, Vyaptek rotates that one token; no other hospital is affected.

  A code works once and expires (48 hours by default); a product key can be used again, and each use
  gives the box a new relay token, so the server that used it last is the one connected. Either reaches
  this script in a file that is deleted at once, never on the command line, where other users could
  read it.

  Writes a one-line result to -ResultFile (for the installer to show) and exits 0 on success, 2 when
  the relay refused the code, 3 when the relay could not be reached, 1 on anything else.

  By hand, as an administrator (asks for the product key or code, then restarts the backend):
    powershell -ExecutionPolicy Bypass -File enroll-abdm.ps1 -ConfigDir "<HMS>\backend\config" -RestartService
#>
param(
  [Parameter(Mandatory = $true)][string]$ConfigDir,
  [string]$RelayUrl = 'https://api.vyaptek.com',
  [string]$CodeFile,
  [string]$ProductKeyFile,
  [string]$ResultFile,
  [switch]$RestartService
)
$ErrorActionPreference = 'Stop'
$file = Join-Path $ConfigDir 'application.properties'

function Write-Result([int]$exitCode, [string]$message) {
  if ($ResultFile) { Set-Content -Path $ResultFile -Encoding ASCII -Value $message }
  if ($exitCode -eq 0) { Write-Host $message } else { Write-Warning $message }
  exit $exitCode
}

function Set-Prop([string[]]$lines, [string]$key, [string]$value) {
  return @($lines | Where-Object { -not $_.StartsWith("$key=") }) + "$key=$value"
}

function Read-Once([string]$path) {
  if (-not (Test-Path $path)) { return '' }
  $raw = Get-Content -Raw $path
  Remove-Item -Force $path
  if ($raw) { return $raw.Trim() } else { return '' }
}

# The credential: from the installer's file (deleted at once), else asked for. A product key starts
# with HMS-; anything else is taken as an enrollment code.
$code = ''
if ($ProductKeyFile) {
  $code = Read-Once $ProductKeyFile
} elseif ($CodeFile) {
  $code = Read-Once $CodeFile
} else {
  $code = (Read-Host 'Product key (HMS-...) or ABDM enrollment code from Vyaptek').Trim()
}
if (-not $code) { Write-Result 1 'No product key or enrollment code was given, so ABDM was not set up.' }
$isProductKey = $code -match "^HMS[-\s]"


# Only HTTPS, so the token cannot be read or replaced on the way. Plain HTTP to this machine is allowed
# for testing against a local relay.
$relay = $RelayUrl.TrimEnd('/')
if (-not ($relay.StartsWith('https://') -or $relay -match '^http://(localhost|127\.0\.0\.1)(:\d+)?$')) {
  Write-Result 1 "The relay address must start with https:// ($RelayUrl)."
}
if (-not (Test-Path $file)) {
  Write-Result 1 "$file does not exist. Run write-secrets.ps1 first."
}

# Windows PowerShell 5.1 may not offer TLS 1.2 by default.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

try {
  if ($isProductKey) {
    $body = @{ productKey = $code } | ConvertTo-Json -Compress
    $response = Invoke-RestMethod -Method Post -Uri "$relay/license/v1/abdm/enroll" -ContentType 'application/json' -Body $body -TimeoutSec 30
  } else {
    $body = @{ code = $code } | ConvertTo-Json -Compress
    $response = Invoke-RestMethod -Method Post -Uri "$relay/relay/v1/enroll" -ContentType 'application/json' -Body $body -TimeoutSec 30
  }
} catch {
  $status = $null
  if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
  if ($status -eq 401 -and $isProductKey) {
    Write-Result 2 'Vyaptek refused the product key: it is wrong, or the license is suspended.'
  }
  if ($status -eq 422 -and $isProductKey) {
    Write-Result 2 'This license does not include ABDM. Ask Vyaptek to add it.'
  }
  if ($status -eq 401) {
    Write-Result 2 'The relay refused the enrollment code: it is wrong, was already used, or has expired. Ask Vyaptek for a new code.'
  }
  if ($status -eq 429) {
    Write-Result 2 'Too many enrollment attempts from this network. Wait a minute and try again.'
  }
  if ($status) { Write-Result 1 "The relay answered HTTP $status. Send this message to Vyaptek." }
  Write-Result 3 "Could not reach $relay ($($_.Exception.Message)). Check that this computer can open https web sites."
}

$d = $response.data
foreach ($field in 'boxId', 'token', 'abdmMode', 'gatewayUrl', 'abhaBaseUrl', 'cmId', 'callbackBaseUrl') {
  if (-not $d.$field) { Write-Result 1 "The relay's answer had no $field. Send this message to Vyaptek." }
}

$lines = @(Get-Content $file | Where-Object { $_ -notmatch '^abdm\.client-(id|secret)=' })
$settings = [ordered]@{
  'abdm.enabled'                    = 'true'
  'abdm.mode'                       = $d.abdmMode
  'abdm.gateway-url'                = $d.gatewayUrl
  'abdm.base-url'                   = $d.abhaBaseUrl
  'abdm.cm-id'                      = $d.cmId
  'abdm.callback-base-url'          = $d.callbackBaseUrl
  'abdm.relay.pull.enabled'         = 'true'
  'abdm.relay.pull.relay-base-url'  = $relay
  'abdm.relay.pull.box-id'          = $d.boxId
  'abdm.relay.pull.token'           = $d.token
}
foreach ($key in $settings.Keys) {
  # None of these values carries a backslash or a line break, so they need no .properties escaping.
  $lines = Set-Prop $lines $key ([string]$settings[$key])
}
Set-Content -Path $file -Encoding ASCII -Value $lines

if ($RestartService) {
  Restart-Service -Name VyaptekHMS
}

Write-Result 0 "This computer is connected to ABDM ($($d.abdmMode)) as $($d.boxId)."
