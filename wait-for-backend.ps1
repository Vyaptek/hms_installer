<#
  Waits for the backend after the installer starts it (backend plan 24 section 11, OP2). Asks its
  readiness probe (started, and the database answers) every 5 seconds for up to 10 minutes. A first
  start after an upgrade can take minutes.

  Leaves one line in -ResultFile for hms.iss:
    status=UP        the backend answers.
    status=STOPPED   the service stayed stopped for 40 seconds, longer than the longest restart delay in
                     hms-service.xml (30 s), so it failed to start; the cause is in backend\logs.
    status=STARTING  10 minutes passed and it is still starting; not a failure. Nothing is rolled back.
#>
param(
  [Parameter(Mandatory = $true)][string]$ResultFile,
  [string]$ServiceName = 'VyaptekHMS',
  [string]$Url = 'http://127.0.0.1:8080/actuator/health/readiness',
  [int]$TimeoutSeconds = 600,
  [int]$IntervalSeconds = 5
)
$ErrorActionPreference = 'Stop'

function Get-Status {
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $stoppedSince = $null
  while ((Get-Date) -lt $deadline) {
    try {
      $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5
      if ($response.StatusCode -eq 200) { return 'UP' }
    } catch {
      # Not listening yet, or 503 while it starts.
    }
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    # Between a crash and Windows' restart (10, 20 then 30 s, hms-service.xml) the service shows Stopped
    # too, so only a longer stop counts.
    if (-not $service -or $service.Status -eq 'Stopped') {
      if (-not $stoppedSince) { $stoppedSince = Get-Date }
      if (((Get-Date) - $stoppedSince).TotalSeconds -ge 40) { return 'STOPPED' }
    } else {
      $stoppedSince = $null
    }
    Start-Sleep -Seconds $IntervalSeconds
  }
  return 'STARTING'
}

Set-Content -Path $ResultFile -Encoding ASCII -Value ('status=' + (Get-Status))
